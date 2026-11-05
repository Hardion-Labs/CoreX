# Audio Runtime — the Device-Independent Mixer — CoreXEngine

This document describes CoreXEngine's audio runtime: a fixed-capacity voice mixer
that turns borrowed float32 clips into an interleaved output buffer. The code
lives in `src/audio/` and is exposed as `corex.audio`.

> Status: **implemented and tested**. This is the audio counterpart of the render
> extraction layer ([render-extraction.md](render-extraction.md)): pure CPU work
> with **no device dependency**, so it is deterministic and fully testable
> headlessly. It consumes the `CXAW` artifacts produced by the WAV importer
> ([asset-audio.md](asset-audio.md)). Spatialization and the scene bridge are
> implemented one layer up ([audio-spatial.md](audio-spatial.md)), and insert
> effects (biquads, compressor) beside it ([audio-effects.md](audio-effects.md)).
> **OS playback backends (ALSA/WASAPI/CoreAudio), modulated/convolved effects,
> HRTF and streaming are planned** — they are not described here as existing
> capabilities.

## Overview

```
CXAW artifact ──► parse ──► Clip (borrowed f32) ─┐
                                                 ├─► Mixer.render ──► interleaved f32 ──► toPcm16 ──► device (planned)
other f32 buffers ───────────────────────────────┘        ▲
                                          voices · buses · master gain
```

The mixer is the contract a playback backend will consume: the backend asks for a
buffer, the mixer fills it. Nothing in this layer opens a device, spawns a thread
or allocates during rendering.

## Design guarantees

- **Fixed capacity, no hot-path allocation.** Voices, buses and the free-slot
  stack are allocated once in `init`. `play` pops a slot in O(1); `render` takes
  **no allocator at all**, so it cannot allocate, grow or free.
- **Generational voice handles.** A `VoiceHandle` is a slot index plus a
  generation counter. Releasing a voice bumps the generation, so a stale handle
  can never address a recycled voice: setters become safe no-ops and queries
  return `null`. A slot whose generation would wrap is **retired** rather than
  reused, so no handle can ever alias a live voice.
- **Borrowed clips.** A voice stores a `Clip` (pointer + layout), never a copy of
  the samples. The caller must keep the sample buffer alive while the voice
  plays. This is what keeps a 30-second music track from being duplicated per
  voice.
- **Deterministic.** Voices are mixed in ascending slot order and the cursor is a
  `f64`, so the same sequence of calls produces **bit-identical** output on a given
  build. A test drives two independent mixers through the same calls and compares
  every sample. The equal-power pan law uses `@cos`/`@sin`, whose last bit may
  differ across libm implementations; `.linear` is exact everywhere.
- **Single-threaded by contract.** The thread that owns the device callback owns
  the mixer. Other threads must post commands to it or synchronize externally;
  there are no locks or atomics inside.
- **One output pass.** Voices accumulate into the caller's buffer; master gain,
  non-finite sanitizing, clamping and peak metering happen in a single final
  pass. The only scratch in the whole mixer is the opt-in effect submix.
- **Optional insert effects.** `effect_slots > 0` reserves insert slots per bus
  plus a master chain. Only buses with an *active* chain are isolated into a
  preallocated submix; everything else keeps writing straight to the output, so
  an all-bypass configuration is bit-identical to the effect-free path. See
  [audio-effects.md](audio-effects.md).
- **Optional priority stealing.** With `steal_policy = .lowest_priority` a full
  pool recycles the least important voice instead of failing, and
  `terminationOf` still explains why an old handle died after its slot has been
  reused. The default `.none` keeps the pool a hard limit.

## Channel mapping

Resolved once at `play` time, then monomorphized into the mixing loop:

| Source | Output | Rule |
| --- | --- | --- |
| mono | mono | passthrough |
| mono | stereo | duplicated to both channels, then panned |
| stereo | stereo | 1:1, then panned |
| stereo | mono | `(L + R) / 2` |
| N > 2 | mono | equal-weight mean of all N channels |
| N > 2 | stereo | **rejected** — `error.UnsupportedChannelLayout` |

Surround-to-stereo needs a downmix matrix (center/LFE/surround coefficients) that
this stage does not implement, so it is refused instead of silently dropping
channels. A mono output **ignores pan** rather than attenuating one side away.

## Pan laws

`Config.pan_law` selects the stereo pan curve; pan is in `[-1, 1]` and clamped.

| Law | Left | Right | Center |
| --- | --- | --- | --- |
| `.linear` | `clamp(1 - pan)` | `clamp(1 + pan)` | unity on both (constant gain) |
| `.equal_power` (default) | `cos(θ)` | `sin(θ)`, `θ = (pan + 1)·π/4` | `-3.01 dB` on both (constant power) |

Equal-power keeps `L² + R² = 1` across the sweep, so a moving sound does not dip
in loudness at the center. Linear is exact at the endpoints and cheaper.

## Resampling and pitch

- The source cursor is a **float64** frame position; the step is
  `(clip.sample_rate / output_sample_rate) * pitch`.
- Two qualities are selectable with `Config.resample`:

  | Quality | Filter | Cost | Aliasing when decimating |
  | --- | --- | --- | --- |
  | `.linear` (default) | two-point interpolation | 2 loads + 1 lerp per sample | **yes** — it is not a low-pass |
  | `.sinc` | Blackman-windowed sinc, 32 taps | one ~33 KiB table at `init`, 32–256 MACs per sample | **no**, up to the support cap |

### Band-limited mode (`.sinc`)

`src/audio/resample.zig` implements the windowed-sinc alternative. It is opt-in
because it costs an order of magnitude more than linear interpolation; the
default stays `.linear` so existing behaviour and bit-exactness are unchanged.

- **Prototype.** `sinc(x) · blackman(x / 16)` over `x ∈ [-16, 16]`, sampled once
  into two views of the same filter: a flat table (`32 × 128 + 1` floats) for
  arbitrary cutoffs, and a **polyphase bank** (`129 × 32` floats) whose rows are
  whole coefficient sets at unity cutoff. Both are built in `Mixer.init` and
  freed in `deinit`; `render` still takes no allocator.
- **Cutoff follows the ratio.** For a step `s` the cutoff scales by
  `min(1, 1/s)` and the support stretches by the same factor, so the signal is
  low-passed **before** it is decimated. That is what removes the aliasing.
- **Support cap.** The support is capped at **256 source samples** per output
  sample to bound the cost. Beyond a 8:1 ratio the anti-aliasing is therefore
  partial — a documented limit, not a silent one.
- **Unity DC gain.** Coefficients are normalized to sum to 1 at every ratio and
  phase, so the filter never drifts the loudness of a signal.
- **Fast paths.** At unity cutoff (upsampling, or unit step with a fractional
  cursor) a kernel is one contiguous **bank row pair** interpolated between
  phases — vectorizable, no gather. The interior read loop is SIMD
  (4 taps/step mono, 8 floats/step stereo); only clip edges take the guarded
  scalar path. Because the weights depend only on the fractional cursor and the
  step, an **exactly repeated fraction reuses the kernel** and just relocates its
  start index, which makes integer ratios (48→24 kHz, 96→48 kHz) nearly free.
- **Edges.** Reads outside the clip clamp to the edge sample, or wrap when the
  voice loops, so looping stays continuous through the boundary.
- **Measured effect.** A 16 kHz tone at 48 kHz resampled to 24 kHz (Nyquist
  12 kHz) keeps **> 0.8** of its amplitude with `.linear` — the alias — and
  **< 0.2** with `.sinc`. A 1 kHz tone through the same 2:1 decimation is
  preserved within 5e-3. Both are tests, not claims.
- `pitch` must be **greater than zero** (zero and negative values are rejected —
  there is no "stopped" or reverse playback through pitch) and is clamped to
  `[min_pitch = 0.01, max_pitch = 100]`.
- Changing pitch mid-flight recomputes the step from the **current cursor**, so
  the voice neither restarts nor jumps.
- When the step is exactly 1 and the cursor is integral, the mixer takes an
  **interpolation-free path** (one load per sample instead of two plus a lerp).
  The decision is hoisted out of the loop and specialized at comptime.
- **Looping** wraps the cursor with `@rem`, so even a step larger than the whole
  clip lands inside it, and interpolation across the loop boundary reads frame 0
  as the successor of the last frame. A non-looping clip **holds** its last frame
  (no wrap) and then finishes.

## Voice lifecycle

```
play ──► playing ⇄ paused ──► (end of clip, non-looping) ──► slot recycled  (.finished)
                    │
                    ├── stop ─────────────────────────────► slot recycled  (.stopped)
                    │
                    └── stolen by a new play ─────────────► slot recycled  (.stolen)
```

- A voice that reaches its end is recycled **after** its last samples are mixed,
  so the tail of the buffer is correct and the rest is silence.
  `RenderStats.voices_finished` counts them.
- The pool is a **hard limit by default**: `play` returns
  `error.NoVoiceAvailable` when it is full. Enable `steal_policy` to recycle a
  voice instead (next section).
- A **muted bus** silences its voices but does not stop them: they keep advancing
  and still finish, which is what a mute control should do.
- `stopAll` releases every voice and keeps bus/master settings.

## Voice stealing and priorities

A fixed pool will eventually fill up. What happens then is a policy, not an
accident:

```zig
var mixer = try A.Mixer.init(gpa, .{ .max_voices = 32, .steal_policy = .lowest_priority });

const music    = try mixer.play(track, .{ .looping = true, .priority = 220 });
const ambience = try mixer.play(rain,  .{ .looping = true, .priority = 40 });
// Pool full: the gunshot takes the ambience's slot, not the music's.
const shot     = try mixer.play(gun,   .{ .priority = 180 });

mixer.isLive(ambience);                      // false
mixer.terminationOf(ambience);               // .stolen
mixer.terminationOf(music);                  // null (still live)
mixer.stolenCount();                         // 1
```

Rules, in order:

1. **Only equal-or-lower priority can be taken.** A voice whose priority is
   *higher* than the request is never a candidate; if every live voice outranks
   the request, `play` fails with `NoVoiceAvailable` rather than interrupting
   something more important.
2. **Lowest priority first**, so the least important sound is the one that dies.
3. **Ties break by age** — the smallest start sequence number wins, i.e. the
   oldest voice among equals. The scan is ascending by slot, so the choice is
   fully deterministic for a given call sequence.
4. **Opt out per request** with `.allow_steal = false`: the request then only
   takes a genuinely free slot. This is what a retry should use, so two sources
   cannot steal each other forever.
5. **Paused voices are candidates too.** Pausing holds a slot; it does not
   protect it.

`terminationOf(handle)` answers *why* a handle is dead — `.stopped`, `.finished`
or `.stolen` — and keeps working **after the slot has been reused**, because the
reason is recorded against the generation that died, not against the slot. Each
slot keeps only its most recent termination: once a newer occupancy of the same
slot ends, the older handle returns `null` instead of a wrong reason. Unknown or
forged handles always return `null`.

The scene bridge uses exactly this: `AudioSource.priority` is forwarded to the
mixer, a stolen source is reported once in `Stats.stolen`, and it is retried with
`.allow_steal = false` until a slot is genuinely free — resuming from the last
cursor it observed rather than restarting the clip (see
[audio-spatial.md](audio-spatial.md)).

## API

```zig
const A = corex.audio;

var mixer = try A.Mixer.init(gpa, .{
    .sample_rate = 48_000,
    .channels = 2,          // 1 or 2
    .max_voices = 64,       // 1..4096
    .max_buses = 8,         // 1..64, bus 0 is the default
    .pan_law = .equal_power,
    .master_gain = 1.0,
    .clamp_output = true,
    .steal_policy = .none,  // or .lowest_priority
    .resample = .linear,    // or .sinc (band-limited)
    .effect_slots = 0,      // inserts per bus + master; 0 disables effects
    .block_frames = 256,    // internal block when effects are enabled
});
defer mixer.deinit();

const voice = try mixer.play(.{
    .sample_rate = view.sample_rate,
    .channels = view.channels,
    .frames = view.frames,
    .samples = samples,     // borrowed; must outlive the voice
}, .{
    .gain = 0.8, .pan = -0.25, .pitch = 1.0, .looping = true, .bus = 1,
    .start_frame = 0, .paused = false,
    .priority = 200,        // 0 least .. 255 most important (default 128)
    .allow_steal = true,    // may this request take someone else's slot?
});

try mixer.setGain(voice, 0.5);   // error.InvalidValue on non-finite input
try mixer.setPan(voice, 0.25);   // clamped to [-1, 1]
try mixer.setPitch(voice, 1.5);  // > 0, clamped to [0.01, 100]
try mixer.seek(voice, 44100);    // source frames
try mixer.setBus(voice, 2);
mixer.setPaused(voice, true);
mixer.setLooping(voice, false);

try mixer.setBusGain(1, 0.5);    // e.g. a music bus
try mixer.setBusMuted(1, false);
try mixer.setMasterGain(0.9);

var buffer: [512 * 2]f32 = undefined;
const stats = try mixer.render(&buffer);   // allocation free
// stats.frames / .voices_active / .voices_finished
// stats.peak / .clipped_samples / .non_finite_samples

var pcm: [512 * 2]i16 = undefined;
try A.toPcm16(&pcm, &buffer);              // device-ready conversion

mixer.stop(voice);
```

Queries: `state(handle) ?State`, `isLive(handle) bool`,
`positionFrames(handle) ?f64`, `liveVoices()`, `voiceCapacity()`,
`busGain(bus) ?f32`, `isBusMuted(bus) ?bool`, `masterGain()`,
`terminationOf(handle) ?Termination`, `stolenCount() u64`,
`effectSlots() u8`, `busEffect(bus, slot) ?Effect`, `masterEffect(slot) ?Effect`.

Inserts: `setBusEffect(bus, slot, effect)`, `clearBusEffects(bus)`,
`setMasterEffect(slot, effect)`, `clearMasterEffects()`, `resetEffects()` — all
`error.InvalidValue` on a bad index, a rate mismatch or a disabled chain. See
[audio-effects.md](audio-effects.md).

Errors: `InitError{ InvalidConfig, OutOfMemory }`,
`PlayError{ InvalidClip, InvalidOptions, UnsupportedChannelLayout, NoVoiceAvailable }`,
`ParamError{ InvalidValue }`, and `render`'s `error.InvalidBuffer` (the buffer
length must be a whole number of output frames).

Setters on a **dead handle are no-ops**, not errors — that is the point of the
generational handle. Invalid *values* are always reported.

## Insert effects

Buses and the master accept an ordered chain of inserts. The signal flow is:

```
voices ─► bus chain (only if active) ─┐
voices ─► direct (bus chain bypassed) ─┼─► sum ─► master chain ─► master gain ─► clamp/meter
```

```zig
var mixer = try A.Mixer.init(gpa, .{ .effect_slots = 4 });   // opt-in
try mixer.setBusEffect(1, 0, try A.Effect.biquad(48_000, .{ .kind = .low_pass, .cutoff_hz = 600 }));
try mixer.setMasterEffect(0, try A.Effect.compressor(48_000, .{ .threshold_db = -6, .ratio = 2 }));

// Delay-based inserts borrow caller memory; the mixer allocates nothing for them.
const memory = try gpa.alloc(f32, try A.Reverb.requiredSamples(48_000, 2));
defer gpa.free(memory);
var room = try A.Reverb.init(48_000, 2, .{ .room_size = 0.8 }, memory);
try mixer.setMasterEffect(1, A.Effect.reverb(&room));
```

The guarantees that matter for the mixing contract:

- With `effect_slots = 0` nothing is allocated and `render` is unchanged.
- With slots reserved but every insert bypassed, the output is **bit-identical**
  to the effect-free path: no bus is isolated, so the accumulation order per
  sample is the same.
- The internal `block_frames` chops the work, never the result — the DSP is
  sequential, and a test compares block sizes 16 and 512 bit for bit.
- An isolated bus is processed even when silent, so filter and compressor tails
  ring out after the last voice finishes.
- Master inserts run **before** the master gain and before metering, so a master
  limiter sees the real sum and the reported peak is still honest.

Full parameter reference, measured costs and limitations:
[audio-effects.md](audio-effects.md).

## Gain staging, clamping and metering

```
sample = Σ (voice_sample × voice_gain × bus_gain × pan_gain)
output = sample × master_gain        (then sanitize, then clamp if enabled)
```

- Gains are linear and may exceed 1; a **negative gain inverts phase**.
- Non-finite mixes (NaN/±Infinity) are replaced with **silence** and counted in
  `stats.non_finite_samples`, so a bad buffer can never reach a device. Well-formed
  `CXAW` clips never trigger this (the parser rejects non-finite samples).
- `stats.peak` is the loudest absolute sample **after master gain and before
  clamping**, so it reports how far over full scale the mix went.
- `stats.clipped_samples` counts samples above full scale whether or not clamping
  is enabled. `clamp_output = false` passes the unclamped sum through, which is
  what an offline bounce or a downstream limiter wants.
- Accumulation is float32, which is standard for a playback mixer; summing very
  many loud voices loses low-order precision before the clamp.

## PCM16 conversion

`toPcm16(dst, src)` converts a mixed buffer to signed 16-bit PCM, the format most
device backends accept:

- non-finite input becomes silence;
- values are clamped to `[-1, 1]`, scaled by **32768** and rounded to nearest;
- the result is clamped to the i16 range, so `+1.0` maps to `32767` (32768 is not
  representable) while `-1.0` maps to `-32768` exactly.

Scaling by 32768 in both directions makes a **PCM16 → f32 → PCM16 round trip exact
for every i16 value**, matching the WAV decoder's `value / 32768` rule. A test
verifies all 65,536 values.

## Pipeline integration

The mixer deliberately **does not import the asset layer**. A parsed `CXAW`
artifact maps to a `Clip` field by field, so the two subsystems stay independently
testable:

```zig
const artifact = (try cache.get(gpa, key)).?;
defer gpa.free(artifact);
const view = try corex.assets.audio.parse(artifact);   // zero-copy, validated

// Copy once into an aligned f32 buffer the voice can borrow (the artifact is
// little-endian bytes and may be unaligned).
const samples = try gpa.alloc(f32, view.sampleCount());
defer gpa.free(samples);
for (samples, 0..) |*s, i| s.* = view.sampleAt(i);

const voice = try mixer.play(.{
    .sample_rate = view.sample_rate,
    .channels = view.channels,
    .frames = view.frames,
    .samples = samples,
}, .{ .looping = true });
```

`src/audio/cxaw_playback_test.zig` is the only file that depends on both layers;
it plays real imported fixtures end to end.

## Guarantees and tests

- **Exactness**: mono and stereo passthrough at unity gain are compared
  **bit-exactly**; mono→stereo duplication, stereo→mono averaging and surround→mono
  mean are checked against hand-computed values.
- **Resampling**: 2:1 downsampling lands on whole source frames; 1:2 upsampling
  produces exact midpoints; stereo and 6-channel sources are interpolated on
  every channel; the last frame of a non-looping clip is held, not wrapped.
- **Band-limited resampling**: the prototype is symmetric with zero endpoints
  and a zero crossing at ±1; the polyphase bank agrees with the flat table; DC
  gain is unity at seven ratios and 50 phases each; an upsampled sine matches the
  analytic signal within 2e-3; a 16 kHz tone decimated 2:1 is attenuated below
  0.2 while linear keeps > 0.8; a 1 kHz tone survives the same decimation within
  5e-3; support grows with the ratio and saturates at the cap; edges clamp,
  looping wraps, a one-frame clip is constant under both; interleaved channels
  are filtered independently; kernels depend only on the fraction so `start` can
  be relocated; the unit-rate path stays **bit-exact** against `.linear`; an
  integer step reuses the kernel across four loop wraps; rendering is
  deterministic and allocation-free.
- **Stealing**: the default policy refuses a full pool and never steals; the
  lowest-priority voice is taken and its slot reused; a request below every live
  voice fails; `.allow_steal = false` fails even when a victim exists; ties break
  by age, deterministically, including a paused victim; `terminationOf`
  distinguishes stop/finish/steal, survives slot reuse, and returns `null` for
  unknown handles and for records a newer occupancy has overwritten.
- **Pitch**: step scaling, mid-flight pitch changes continuing from the cursor,
  clamping into the documented band, rejection of zero/negative pitch.
- **Looping**: wrap-around interpolation across the boundary, steps larger than
  the clip, and switching looping off letting the voice finish.
- **Lifecycle**: exact finish frame with a silent tail, slot recycling with a new
  generation, stale handles inert against a recycled voice, forged/foreign
  handles inert, the pool limit, `stopAll`, pause/resume holding the cursor.
- **Retirement**: a slot driven to the last usable generation is retired and never
  handed out again (white-box test).
- **Gain/metering**: voice × bus × master staging, phase inversion, bus mute, bus
  re-routing, summation, clamping, unclamped mode, peak and clipped counts,
  non-finite sanitizing.
- **Insert routing**: an all-bypass chain is bit-identical to the effect-free
  mixer; block sizes 16 and 512 agree bit for bit; an insert affects only its own
  bus; master inserts affect the sum; tails ring out and `resetEffects` silences
  them; a voice ending inside a block is counted once.
- **Borrowed effect memory**: a delay/reverb instance cannot be inserted twice,
  two instances cannot share or partially overlap a buffer, the layout must match
  the output, replacing the holding slot is allowed, and clearing releases the
  claim. A delay echoes correctly across block boundaries and a master reverb
  tails into a render with no voices at all. The DSP itself is covered in
  [audio-effects.md](audio-effects.md).
- **Determinism and memory**: two mixers driven identically agree bit for bit over
  32 buffers; `checkAllAllocationFailures` on `init` + `play` + `render` with no
  leaks and no swallowed `OutOfMemory`, in both `.linear` and `.sinc` (the extra
  table allocations unwind cleanly); the leak-checked test allocator covers
  every other test.
- **Integration**: WAV → `CXAW` → `Clip` → mixer, mono and stereo bit-exact,
  half-rate resampling, and a PCM16 bounce within one LSB.
- **Clip helpers**: descriptor validation (including an overflowing
  frames × channels product), the channel-map matrix, both pan laws (including
  constant power across a sweep), and the exhaustive PCM16 round trip.

## Performance

Measured on this machine, `ReleaseFast`, best of 300 renders, **64 looping stereo
voices** into a 512-frame stereo buffer (10.7 ms of audio per render). This is a
stress case: every voice resamples on every sample.

| Output / clip rate | Ratio | `.linear` | `.sinc` |
| --- | --- | --- | --- |
| 48,000 / 48,000 Hz | 1:1 (copy path) | **25 µs** (423×) | same path |
| 48,000 / 44,100 Hz | upsampling | **58 µs** (185×) | **864 µs** (12×) |
| 24,000 / 48,000 Hz | 2:1 decimation | **58 µs** (185×) | **411 µs** (26×) |
| 48,000 / 96,000 Hz | 2:1 decimation | — | **419 µs** (25×) |
| 44,100 / 48,000 Hz | 1.088:1 decimation | **61 µs** (175×) | **2,511 µs** (4×) |

Reading the table honestly:

- `.sinc` costs **7× to 40× linear** depending on the ratio. It is opt-in for
  exactly that reason. At 64 simultaneous resampled voices the worst case uses
  about a quarter of one core; at a more typical 8–16 voices it is a few percent.
- **Integer ratios are the cheap case** (26×): the fractional cursor never
  changes, so the kernel is built once per voice per render and only relocated.
  Non-integer decimation is the expensive case (4×): the stretched filter needs a
  fresh 64-tap kernel every frame, and that construction — not the dot product —
  dominates. Upsampling sits in between (12×) thanks to the contiguous bank rows.
- The mixing core is monomorphized per **(channel map, mode)** pair — `copy`,
  `linear` or `sinc` — so the per-sample work has no layout branch and no
  interpolation branch.
- One load per sample on the copy path; two plus a lerp on linear; a normalized
  32–256 tap dot product on sinc, SIMD in the interior.
- No allocation, no locks and no syscalls during `render` in any mode. The sinc
  tables and the effect submix are built once in `init`.
- Insert effects add ~1% when reserved but bypassed, +11% for a biquad on one of
  eight buses and +37% for a master compressor. A master reverb adds ~66% over an
  unity-rate baseline, and a full eight-bus chain with delays, filters, reverb and
  compression still runs at 103× real time — see the measured tables in
  [audio-effects.md](audio-effects.md).
- Voice state is a contiguous array walked in slot order, so the mix is
  cache-friendly and prefetchable.

## Limitations and next steps

- **No device backend.** Nothing here opens an audio device; `render` fills a
  buffer and `toPcm16` prepares it. ALSA/WASAPI/CoreAudio backends, the callback
  thread and the command queue from the game thread are planned.
- **No spatialization inside the mixer**: distance attenuation, listener-relative
  panning and Doppler live one layer up, in `corex.audio.spatial` /
  `AudioSystem` (see [audio-spatial.md](audio-spatial.md)), which feed this
  mixer's gain/pan/pitch. There is no HRTF or binaural rendering anywhere yet.
- **Effects**: biquads, a stereo-linked compressor, a feedback delay and a
  Freeverb-style reverb on per-bus and master chains
  ([audio-effects.md](audio-effects.md)). No chorus/flanger, convolution,
  lookahead limiting, oversampled saturation, side-chain or per-voice inserts.
  Delay-based effects borrow their memory from the caller, so they add **no mixer
  allocation**; the mixer rejects two slots claiming the same instance or
  overlapping buffers.
- **Resampling trade-offs are explicit.** `.linear` (the default) aliases when
  decimating. `.sinc` removes that, but its support is capped at 256 source
  samples, so beyond an 8:1 ratio the anti-aliasing is partial, and it costs
  7–40× linear (see Performance). There is no asynchronous/offline high-quality
  converter and no per-voice quality selection — quality is per mixer.
- **Stealing is priority-only.** There is no loudness-based or distance-based
  victim scoring, no fade-out on steal (the slot is taken immediately, which can
  click), and no "virtual voice" that keeps advancing silently while it waits.
  The scene bridge resumes a stolen source from the last cursor it observed, so
  the gap is at most one update plus the time spent waiting for a free slot.
- **No streaming**: a clip must be fully resident in memory (the `CXAW` decoder
  has the same limitation).
- **No loop points**: `smpl`/`cue ` markers are not carried by `CXAW` yet, so
  looping is whole-clip only.
- **Mono/stereo output only**; multichannel output layouts are not implemented.
- The scene bridge **is** implemented one layer up (`AudioSource` +
  `AudioSystem`, see [audio-spatial.md](audio-spatial.md)); the mixer itself
  remains scene-agnostic. Neither is wired into startup or the frame loop yet —
  the caller drives them, like the render extraction layer.

## Related

- Insert effects and DSP: [audio-effects.md](audio-effects.md)
- Spatial audio and scene integration: [audio-spatial.md](audio-spatial.md)
- Audio import / `CXAW`: [asset-audio.md](asset-audio.md)
- Import and cache: [asset-import.md](asset-import.md)
- Render extraction (the same device-independent pattern): [render-extraction.md](render-extraction.md)
- Architecture: [architecture.md](architecture.md)
- Coding standards: [development/coding-standards.md](development/coding-standards.md)
