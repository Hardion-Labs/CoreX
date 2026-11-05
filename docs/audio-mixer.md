# Audio Runtime — the Device-Independent Mixer — CoreXEngine

This document describes CoreXEngine's audio runtime: a fixed-capacity voice mixer
that turns borrowed float32 clips into an interleaved output buffer. The code
lives in `src/audio/` and is exposed as `corex.audio`.

> Status: **implemented and tested**. This is the audio counterpart of the render
> extraction layer ([render-extraction.md](render-extraction.md)): pure CPU work
> with **no device dependency**, so it is deterministic and fully testable
> headlessly. It consumes the `CXAW` artifacts produced by the WAV importer
> ([asset-audio.md](asset-audio.md)). **OS playback backends (ALSA/WASAPI/
> CoreAudio), 3D spatialization, effects/DSP and streaming are planned** — they
> are not described here as existing capabilities.

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
  pass. There is no scratch buffer and no second traversal per voice.

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
- Sample rate conversion is **linear interpolation** between the two neighbouring
  source frames. It is cheap and allocation-free, but it is not band-limited:
  large downsampling ratios can alias. A polyphase/sinc resampler is future work.
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
play ──► playing ⇄ paused ──► (end of clip, non-looping) ──► slot recycled
                    │
                    └── stop ─────────────────────────────► slot recycled
```

- A voice that reaches its end is recycled **after** its last samples are mixed,
  so the tail of the buffer is correct and the rest is silence.
  `RenderStats.voices_finished` counts them.
- The pool is a **hard limit**: `play` returns `error.NoVoiceAvailable` when it is
  full. There is no implicit voice stealing (a planned addition).
- A **muted bus** silences its voices but does not stop them: they keep advancing
  and still finish, which is what a mute control should do.
- `stopAll` releases every voice and keeps bus/master settings.

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
});
defer mixer.deinit();

const voice = try mixer.play(.{
    .sample_rate = view.sample_rate,
    .channels = view.channels,
    .frames = view.frames,
    .samples = samples,     // borrowed; must outlive the voice
}, .{ .gain = 0.8, .pan = -0.25, .pitch = 1.0, .looping = true, .bus = 1, .start_frame = 0, .paused = false });

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
`busGain(bus) ?f32`, `isBusMuted(bus) ?bool`, `masterGain()`.

Errors: `InitError{ InvalidConfig, OutOfMemory }`,
`PlayError{ InvalidClip, InvalidOptions, UnsupportedChannelLayout, NoVoiceAvailable }`,
`ParamError{ InvalidValue }`, and `render`'s `error.InvalidBuffer` (the buffer
length must be a whole number of output frames).

Setters on a **dead handle are no-ops**, not errors — that is the point of the
generational handle. Invalid *values* are always reported.

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
- **Determinism and memory**: two mixers driven identically agree bit for bit over
  32 buffers; `checkAllAllocationFailures` on `init` + `play` + `render` with no
  leaks and no swallowed `OutOfMemory`; the leak-checked test allocator covers
  every other test.
- **Integration**: WAV → `CXAW` → `Clip` → mixer, mono and stereo bit-exact,
  half-rate resampling, and a PCM16 bounce within one LSB.
- **Clip helpers**: descriptor validation (including an overflowing
  frames × channels product), the channel-map matrix, both pan laws (including
  constant power across a sweep), and the exhaustive PCM16 round trip.

## Performance

Measured on this machine, `ReleaseFast`, best of 400 renders, **64 looping stereo
voices** into a 512-frame stereo buffer at 48 kHz (10.7 ms of audio per render):

| Source rate | Path | Time per render | Real-time factor |
| --- | --- | --- | --- |
| 44,100 Hz | linear resampling | **68.8 µs** | **155×** |
| 48,000 Hz | interpolation-free | **32.6 µs** | **328×** |

- The mixing core is monomorphized per **(channel map, resampling)** pair, so the
  per-sample work has no layout branch and no interpolation branch. The
  unit-step specialization is ~2.1× faster than the general path.
- One load per sample on the fast path; two plus a lerp when resampling.
- No allocation, no locks, no syscalls and no scratch buffer during `render`.
- Voice state is a contiguous array walked in slot order, so the mix is
  cache-friendly and prefetchable.

## Limitations and next steps

- **No device backend.** Nothing here opens an audio device; `render` fills a
  buffer and `toPcm16` prepares it. ALSA/WASAPI/CoreAudio backends, the callback
  thread and the command queue from the game thread are planned.
- **No 3D audio**: no listener, distance attenuation, Doppler or HRTF. Stereo pan
  only.
- **No effects/DSP**: no filters, reverb, compression or per-bus inserts.
- **Linear resampling only** — no band-limited (polyphase/sinc) conversion, so
  large downsampling ratios can alias.
- **No voice stealing**: a full pool returns `NoVoiceAvailable`.
- **No streaming**: a clip must be fully resident in memory (the `CXAW` decoder
  has the same limitation).
- **No loop points**: `smpl`/`cue ` markers are not carried by `CXAW` yet, so
  looping is whole-clip only.
- **Mono/stereo output only**; multichannel output layouts are not implemented.
- Not wired into startup, the scene system or an `AudioSource` component yet; it
  is an independent public API, like the render extraction layer.

## Related

- Audio import / `CXAW`: [asset-audio.md](asset-audio.md)
- Import and cache: [asset-import.md](asset-import.md)
- Render extraction (the same device-independent pattern): [render-extraction.md](render-extraction.md)
- Architecture: [architecture.md](architecture.md)
- Coding standards: [development/coding-standards.md](development/coding-standards.md)
