# Audio Effects — Insert DSP for Buses and the Master — CoreXEngine

This document describes CoreXEngine's insert effects: the pure DSP module in
`src/audio/effects.zig` (exposed as `corex.audio.effects`) and how the mixer
routes buses through it.

> Status: **implemented and tested**. Biquad filters, a stereo-linked
> compressor, a feedback delay and a Freeverb-style reverb, on per-bus and master
> insert chains, allocation-free at render time. **Convolution, modulated delays
> (chorus/flanger), lookahead limiting and oversampled saturation are planned** —
> they are not described here as existing capabilities. The mixer itself is
> documented in [audio-mixer.md](audio-mixer.md).

## Overview

```
voice ─┐
voice ─┼─► bus with an active chain ─► submix ─► [insert 0] ─► [insert 1] ─┐
voice ─┘                                                                   │
                                                                           ├─► sum ─► [master inserts] ─► master gain ─► clamp/meter ─► out
voice ───► bus with no active chain ───────────────────────────────────────┘
```

Effects are **opt-in**. `Config.effect_slots = 0` (the default) reserves nothing,
and `render` keeps exactly the single-pass path it had before — bit for bit.
Above zero, the mixer reserves insert slots per bus plus a master chain, and one
submix buffer per bus so a processed bus can be isolated from the rest.

## Design guarantees

- **Pure module, one-way coupling.** `effects.zig` imports only `std`. It knows
  nothing about voices, buses, scenes or assets, so a filter can be tested
  against its own transfer function. The mixer owns the storage and calls
  `Chain.process`; the DSP never reaches back.
- **Validate once, process cheaply.** `Effect.biquad` and `Effect.compressor`
  compute coefficients and reject invalid parameters. A constructed `Effect` is
  always valid, so the per-sample loop carries no parameter validation and no
  coefficient transcendentals.
- **No allocation, ever.** Inline effects (biquad, compressor) keep their history
  in a fixed `[2]` array, so they are plain values in a preallocated slot.
  Delay-based effects **borrow their memory from the caller**, exactly like a
  `Clip` borrows its samples: `requiredSamples` says how much to allocate, `init`
  carves the lines out of it, and the effect keeps a slice. The mixer allocates
  **nothing** for a reverb, and `render` still takes no allocator.
- **Borrowed memory cannot be claimed twice.** Two slots sharing one instance
  would advance its cursors twice per sample; two instances sharing one buffer
  would overwrite each other. Both are silent corruption rather than a crash, so
  the mixer rejects them at insert time — by instance address and by buffer
  range, including partial overlap. Replacing the slot that already holds the
  claim is allowed, and clearing a bus releases it.
- **Bit-exact when bypassed.** A bus whose chain is all `.bypass` is *not*
  isolated: its voices write straight into the output in slot order, exactly as
  they do without the feature. A test drives two mixers — one with slots
  reserved, one without — and compares every sample.
- **Block-size independent.** The DSP is sample-sequential, so chopping the
  stream differently cannot change the result. A test renders the same material
  with `block_frames = 16` and `512` and compares bit for bit.
- **Robust to bad input.** A non-finite sample is treated as silence instead of
  poisoning a recursive filter forever; both the biquad and the compressor
  recover, and tests assert it.
- **No denormal crawl.** Filter state below ~1e-15 (about -300 dBFS) is flushed to
  zero at each block boundary, so a silent block after a decay does no denormal
  arithmetic at all. A decay can still cross the denormal range *inside* one
  block; the cost is bounded to that single block rather than two comparisons on
  every sample.
- **Rate-checked inserts.** An `Effect` carries the sample rate it was designed
  for. Inserting one built for a different rate is rejected with
  `error.InvalidValue` instead of silently filtering at the wrong frequency.

## Biquad filters

Coefficients follow the RBJ *Audio EQ Cookbook*, computed in double precision and
narrowed to f32. Processing uses **transposed direct form II**, which keeps the
internal signals better scaled than direct form I for the same coefficients.

| Kind | Behaviour |
| --- | --- |
| `low_pass` | 12 dB/oct above the corner; unity at DC |
| `high_pass` | 12 dB/oct below the corner; unity at Nyquist |
| `band_pass` | Constant peak gain: unity at the center frequency |
| `notch` | Rejects the center frequency |
| `peaking` | Boost/cut of `gain_db` around the center, width set by `q` |
| `low_shelf` | Boost/cut below the corner, `gain_db` at DC, unity at Nyquist |
| `high_shelf` | Boost/cut above the corner, `gain_db` at Nyquist, unity at DC |

```zig
const A = corex.audio;
const underwater = try A.Effect.biquad(mixer.sample_rate, .{
    .kind = .low_pass,
    .cutoff_hz = 600,
    .q = 0.70710678,
});
```

Parameters: `cutoff_hz` must be inside `(0, sample_rate / 2)`, `q > 0`, and
`gain_db` finite (it is ignored by the non-peaking, non-shelving kinds). Beyond
the parameter checks, the coefficients are run through a **Jury stability test**
(`|a2| < 1` and `|a1| < 1 + a2`): the RBJ forms satisfy it by construction, so the
check turns any future formula mistake into an error at insert time instead of a
blow-up at runtime.

`Coefficients.magnitudeAt(rate, freq)` evaluates `|H(e^{jw})|` analytically. The
tests use it as the reference, so the filter is checked against the theory rather
than against itself.

## Compressor

Feed-forward **peak** detector, **stereo linked**: the detector follows the
loudest channel and applies one gain to both, so compression never shifts the
stereo image.

```
level_db = 20·log10(max(|L|, |R|))
over     = level_db − threshold_db

           ⎧ 0                                        2·over ≤ −knee
target_dB =⎨ slope · (over + knee/2)² / (2·knee)      −knee < 2·over ≤ knee
           ⎩ slope · over                             2·over > knee
             where slope = 1/ratio − 1

envelope ← α·envelope + (1−α)·target      α = attack when target < envelope,
                                            release otherwise
gain     = 10^((envelope + makeup_db)/20)
```

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `threshold_db` | -12 | -120..24 | Where reduction starts |
| `ratio` | 4 | 1..1000 | 1 is transparent, high values approach limiting |
| `knee_db` | 6 | 0..60 | Soft-knee width centered on the threshold; 0 is a hard knee |
| `attack_ms` | 5 | >0..10000 | Time to ~63% of an increase in reduction |
| `release_ms` | 80 | >0..10000 | Time to ~63% of the recovery |
| `makeup_db` | 0 | -60..60 | Output gain after compression |

- The attack/release coefficients are `exp(-1 / (seconds · rate))`, computed once
  at construction.
- **Fast path.** When the peak is below the threshold *and* the envelope has
  settled to zero, the detector is skipped entirely and only makeup is applied.
  That is the common case for game audio, and it keeps `@log`/`@exp` off it.
- The envelope is flushed to zero below 1e-6 dB so the fast path re-engages after
  a release instead of chasing an asymptote forever.
- `reductionFor(level_db)` exposes the static curve, which is what the tests
  check (including monotonicity and continuity across both knee edges).

## Feedback delay

A circular delay line per channel with feedback, a wet/dry mix and an optional
one-pole low pass **inside the feedback path**, so repeats darken naturally
instead of staying metallic.

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `delay_ms` | 250 | >0..10000 | Delay time, rounded **up** to whole samples |
| `feedback` | 0.35 | `[0, 1)` | Must be below 1 so the echo always decays |
| `mix` | 0.3 | `[0, 1]` | 0 = dry only (bit-exact), 1 = wet only |
| `damping_hz` | 0 | `[0, Nyquist)` | Feedback low pass; 0 disables it |

```zig
const A = corex.audio;
const params = A.DelayParams{ .delay_ms = 120, .feedback = 0.4, .mix = 0.25, .damping_hz = 4000 };
const memory = try gpa.alloc(f32, try A.Delay.requiredSamples(48_000, 2, params));
defer gpa.free(memory);                       // must outlive the insert
var echo = try A.Delay.init(48_000, 2, params, memory);
try mixer.setBusEffect(3, 0, A.Effect.delay(&echo));
```

Delays are **integer-sample**: `delay_ms` is rounded up, and there is no
fractional interpolation. That is exact and cheap, and it is what makes the
behaviour testable — an impulse with `feedback = 0.5` returns at exactly `D`,
`2D`, `3D` with amplitudes `1`, `0.5`, `0.25`, and nowhere else.

## Reverb

A Freeverb-style network: **eight parallel damped comb filters** feeding **four
series diffusion sections**, per channel, with a 23-sample stereo spread on the
right channel so the two tails decorrelate.

```
        ┌─ comb 1 (damped feedback) ─┐
input ──┼─ ...                       ├─► sum × 1/8 ─► AP1 ─► AP2 ─► AP3 ─► AP4 ─► wet
        └─ comb 8 (damped feedback) ─┘
```

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `room_size` | 0.7 | `[0, 1]` | Maps to comb feedback 0.70..0.98 |
| `damping` | 0.5 | `[0, 1]` | Low pass in the comb feedback; 1 is a soft room |
| `wet` | 0.35 | `[0, 1]` | Level of the reverberated signal |
| `dry` | 1.0 | `[0, 1]` | Level of the dry signal |

```zig
const memory = try gpa.alloc(f32, try A.Reverb.requiredSamples(48_000, 2)); // 108 KiB
defer gpa.free(memory);
var room = try A.Reverb.init(48_000, 2, .{ .room_size = 0.85, .damping = 0.4 }, memory);
try mixer.setMasterEffect(0, A.Effect.reverb(&room));
```

- The diffusion sections use Freeverb's form, `y[n] = v[n-N] - v[n]` with
  `v[n] = x[n] + g*v[n-N]`, i.e. `H(z) = (z^-N - 1)/(1 - g*z^-N)`. That is **not** a
  textbook all pass: it has a null at DC and rises to `2/(1+g) ≈ 1.33` where
  `z^N = -1`. The null is the point. The combs have a DC gain of `1/(1-feedback)`
  — over 13× at `room_size = 1` — so a flat-magnitude all pass would let an impulse
  build a low-frequency rumble that takes seconds to decay. Both properties are
  asserted in tests rather than left as a claim.
- The comb and diffusion lengths are Freeverb's 44.1 kHz tunings scaled to the
  running rate. They are mutually prime-ish, which spreads the resonances out
  instead of stacking them into a metallic ring.
- Comb outputs are summed and normalized by `1/8`, so `wet` means roughly the
  same thing at any `room_size`.
- `feedback <= 0.98` keeps the network **bounded even with damping at 0** — a
  test drives a one-second impulse response at `room_size = 1` and checks every
  sample stays finite and bounded.
- `dry = 1, wet = 0` is bit-exact passthrough; `dry = 0, wet = 0` is silence.
- Nothing is heard before the shortest comb delay (~1215 samples at 48 kHz),
  which is a test assertion rather than a claim.

### Why the memory is borrowed

A reverb carries 752 bytes of line cursors and damping state plus ~108 KiB of
delay memory. Inlining that into `Effect` would inflate **every** insert slot on
**every** bus, including the ones only running a biquad. So `Effect.Kind` holds a
`*Delay` / `*Reverb` and the union stays **48 bytes** (the pointer variants raise its alignment to 8, costing 4 bytes of padding over the inline-only layout — a test pins that). The caller owns both the struct
and its buffer, which also means a reverb can be shared across mixers deliberately
(one instance, one insert) or moved between buses without reallocating.

### Denormals in long tails

A reverb tail decays for seconds. Flushing only at block boundaries (what the
biquad does) would leave values crawling through the denormal range for a long
time, so the delay lines **flush on write**: once a value is below ~1e-15,
feedback below 1 keeps it there, so it becomes an exact zero instead. The cost is
one comparison per write, and it is what makes a long tail cheap rather than
pathologically slow.

## Routing, order and tails

- **Per bus:** slots run in index order, `0 → effect_slots - 1`. Order matters —
  EQ before a compressor is not the same as the compressor before EQ, and a test
  asserts the two differ.
- **Master:** applied in place to the summed mix, **before** the master gain and
  before the clamp/metering stage. A master limiter therefore sees the real sum
  and its output is still metered honestly.
- **Isolation is per bus, per render.** A bus is isolated only while its chain is
  active; clearing the last insert returns it to the direct path immediately.
- **Tails ring out.** An isolated bus is processed even when no voice is feeding
  it, so a filter keeps ringing after its last voice finishes. A test drives a
  one-frame impulse, confirms the voice finished, and still finds energy 64
  frames later that decays towards the end of the buffer.
- **`resetEffects()`** clears every insert's history but keeps the settings —
  call it after a seek or a device underrun so an old tail does not bleed into
  new material.
- **State travels with the value.** `setBusEffect` stores the effect as given,
  including its history, so a warm filter can be moved between buses;
  `busEffect` reads a copy back.

## Memory

With `effect_slots > 0` the mixer reserves, once, at `init`:

| Storage | Size |
| --- | --- |
| Bus inserts | `max_buses × effect_slots × sizeof(Effect)` |
| Master inserts | `effect_slots × sizeof(Effect)` |
| Submix scratch | `max_buses × block_frames × channels × 4` bytes |
| Delay / reverb memory | **zero** — the caller owns it (`requiredSamples`) |

The default `max_buses = 8`, `block_frames = 256`, stereo gives **16 KiB** of
scratch. The scratch is reserved for every bus, not only the processed ones,
because an insert can be added at any time and `render` must never allocate.
Lower `block_frames` to shrink it; the output does not change.

Delay-based effects add nothing to that table: their memory is allocated by the
caller. For reference, at 48 kHz a stereo reverb needs **108 KiB** and a 120 ms
stereo delay needs **45 KiB**; both scale linearly with the sample rate.

## API

```zig
const A = corex.audio;

var mixer = try A.Mixer.init(gpa, .{
    .sample_rate = 48_000,
    .channels = 2,
    .max_buses = 8,
    .effect_slots = 4,   // 0 disables the feature entirely
    .block_frames = 256,
});
defer mixer.deinit();

// Bus 1 = "world": muffle it when the player goes underwater.
try mixer.setBusEffect(1, 0, try A.Effect.biquad(48_000, .{
    .kind = .low_pass, .cutoff_hz = 600,
}));
// Bus 2 = "dialogue": keep it present and controlled.
try mixer.setBusEffect(2, 0, try A.Effect.biquad(48_000, .{
    .kind = .high_pass, .cutoff_hz = 120,
}));
try mixer.setBusEffect(2, 1, try A.Effect.compressor(48_000, .{
    .threshold_db = -18, .ratio = 3, .attack_ms = 3, .release_ms = 120,
}));
// Master: gentle glue, then the usual master gain and clamp.
try mixer.setMasterEffect(0, try A.Effect.compressor(48_000, .{
    .threshold_db = -6, .ratio = 2, .makeup_db = 1.5,
}));

var buffer: [512 * 2]f32 = undefined;
_ = try mixer.render(&buffer);   // still allocation free

try mixer.clearBusEffects(1);    // back to the direct path
mixer.resetEffects();            // keep settings, drop history
```

Delay-based inserts follow the same API, with the caller owning the memory:

```zig
const memory = try gpa.alloc(f32, try A.Reverb.requiredSamples(48_000, 2));
defer gpa.free(memory);
var room = try A.Reverb.init(48_000, 2, .{ .room_size = 0.8 }, memory);
try mixer.setMasterEffect(0, A.Effect.reverb(&room));   // borrows &room + memory
```

`Effect.delay(*Delay)` and `Effect.reverb(*Reverb)` are infallible — the instance
already validated its parameters and buffer in `init`. Three extra rules are
enforced by the setters:

| Rule | Why |
| --- | --- |
| The layout must match (`channelCount()`) | Delay lines are allocated per channel and cannot be reinterpreted |
| No two slots may hold the same instance | Its cursors would advance twice per sample |
| No two slots' buffers may overlap (even partially) | They would overwrite each other's history |

Queries: `effectSlots() u8`, `busEffect(bus, slot) ?Effect`,
`masterEffect(slot) ?Effect`.
Errors: every setter returns `error.InvalidValue` for an out-of-range bus or
slot, a rate mismatch, or a disabled chain (`effect_slots == 0`).
`clearBusEffects` on a valid bus, `clearMasterEffects` and `resetEffects` are
safe no-ops when the feature is off.

`Chain` is also usable standalone on any borrowed slot array — the mixer is not
required:

```zig
var slots = [_]A.Effect{ filter, compressor };
A.EffectChain.process(.{ .effects = &slots }, &buffer, 2);
```

## Performance

Measured on this machine, `ReleaseFast`, best of 300 renders, **64 looping stereo
voices** into a 512-frame stereo buffer at 48 kHz (10.7 ms of audio per render):

| Configuration | Time per render | Real-time factor | vs. baseline |
| --- | --- | --- | --- |
| No effects (`effect_slots = 0`) | **54.5 µs** | **196×** | — |
| Slots reserved, all bypass | **55.2 µs** | **193×** | +1.3% |
| Biquad on 1 of 8 buses | **60.7 µs** | **176×** | +11% |
| Biquad on all 8 buses | **96.2 µs** | **111×** | +77% |
| Master compressor | **74.6 µs** | **143×** | +37% |
| Master shelf + compressor | **79.4 µs** | **134×** | +46% |

Delay-based effects, measured separately with **unity-rate clips** (the copy fast
path, so the baseline is lower and the effect cost is not hidden behind
resampling):

| Configuration | Time per render | Real-time factor | vs. baseline |
| --- | --- | --- | --- |
| No effects | **27.0 µs** | **395×** | — |
| 120 ms delay on 1 of 8 buses | **31.1 µs** | **343×** | +15% |
| 120 ms delay on all 8 buses | **48.3 µs** | **221×** | +79% |
| Reverb on the master | **44.9 µs** | **238×** | +66% |
| Reverb on 1 bus | **44.2 µs** | **241×** | +64% |
| 8 delays + 8 high passes + master reverb + compressor | **103.2 µs** | **103×** | +282% |

A full reverb is 12 delay reads and 12 writes per sample per channel, so it costs
about the same as a handful of biquads — the whole eight-bus chain above still
runs at **103× real time**. Reverb on a bus is slightly cheaper than on the master
because only that bus is isolated.

- Reserving slots and leaving them bypassed costs **about 1%**: the blocked path
  adds a per-block loop, not per-sample work, and no bus is isolated.
- Effects are cheap relative to mixing: a biquad is 5 multiply-adds per sample
  per channel, while a resampled voice costs far more. Processing all eight buses
  still leaves 111× real time.
- The compressor's transcendental calls only run above the threshold or while
  the envelope is releasing.
- Nothing allocates, locks or makes a syscall during `render`, in any
  configuration.

## Guarantees and tests

- **Coefficients**: every kind is measured against `Coefficients.magnitudeAt` at
  three frequencies; low/high pass are additionally swept at five. The estimator
  is RMS over whole periods, not a sample peak — a filter shifts phase, so a peak
  reading would under-report the gain.
- **Limits**: low pass passes DC at unity and kills Nyquist; high pass does the
  reverse; shelves reach their rated boost at the boosted extreme and stay unity
  at the other; a peaking filter at 0 dB is transparent sample for sample.
- **Stability**: the impulse response stays finite and bounded, decays below the
  flush threshold, lands the state on exact zero, and the following silent block
  is exactly silent.
- **Validation**: cutoff at 0, at Nyquist and above it, non-finite cutoff/Q/gain,
  Q ≤ 0, rate 0; compressor ratio < 1, negative knee, zero attack, negative
  release, non-finite threshold, out-of-range makeup.
- **Channels**: stereo history is independent (no crosstalk in either direction);
  the compressor is linked (a loud left channel attenuates the right by the same
  factor, preserving the ratio).
- **Compressor curve**: below the knee, at its center, above it, monotonic and
  continuous across both edges, hard-knee variant, ratio 1 transparent, makeup
  exact, attack is a ramp rather than a jump, release returns to unity and flushes
  the envelope.
- **Robustness**: NaN/±inf inputs are silenced and both effects still work
  afterwards.
- **Routing**: an insert affects only its own bus; clearing it restores that bus;
  master inserts affect the whole sum; a bus tail rings after its voice finishes
  and `resetEffects` silences it.
- **Equivalence**: all-bypass is bit-identical to the effect-free mixer over six
  buffers with three voices on three buses and resampling active; block sizes 16
  and 512 produce identical output.
- **Lifecycle**: a voice ending inside a block is counted exactly once, its tail
  is silent, and the next render reports no further finishes.
- **Memory**: `checkAllAllocationFailures` over `init` + inserts + `play` +
  `render` + `resetEffects` with `.sinc` also enabled — no leaks, no swallowed
  `OutOfMemory`. (This probe caught a real bug: the cleanup was registered after
  the allocations, so a mid-sequence failure leaked the earlier ones.)
- **Delay**: parameter and buffer-size validation (including one sample short);
  dry-only is bit-exact; a wet impulse with feedback 0.5 returns at exactly 48,
  96, 144 and 192 samples with amplitudes 1, 0.5, 0.25, 0.125 and is zero
  everywhere else; damping leaves the first repeat intact and cuts the second by
  more than 5×; the tail lands on exact zero; channels are independent; reset
  replays identically; NaN/inf do not circulate.
- **Diffusion sections**: a constant input decays to below 1e-4 (the DC null that
  keeps the combs from rumbling), and the mid/high-band gain stays inside the
  documented 0.5..1.4 shelving band at five frequencies — no resonant peak.
- **Reverb**: parameter and buffer-size validation, stereo needs more than twice
  mono (the spread), a stereo instance cannot be carved from a mono buffer;
  `dry=1/wet=0` is bit-exact and `dry=0/wet=0` is silence; nothing is heard before
  the shortest comb delay; the tail is bounded, finite and decaying; one second
  at `room_size = 1` with no damping stays bounded; identical impulses still
  produce decorrelated channels; reset silences every line; NaN/inf recover.
- **Borrowed memory**: the same instance is rejected in another bus slot and on
  the master; a *different* instance over the same buffer is rejected; a
  partially overlapping buffer is rejected; replacing the holding slot is
  allowed; clearing a bus or the master releases the claim; a disjoint buffer is
  accepted; a stereo delay/reverb is rejected on a mono mixer while inline
  effects still adapt.
- **Integration**: a delay insert echoes across 16-frame blocks with a 48-sample
  delay; `resetEffects` reaches through the borrowed pointer; a master reverb
  tails after the last voice finished and keeps tailing into the next render;
  `checkAllAllocationFailures` proves the mixer allocates nothing for a reverb at
  insert time or during render.
- **Determinism**: two identically driven mixers agree bit for bit over five
  buffers; a chain processed in one pass equals the same chain processed in
  64-sample chunks, and a delay+reverb chain in one pass equals the same chain in
  97-sample chunks.

## Limitations and next steps

- **No modulated or convolved delays**: no chorus, flanger, pitch shifting or
  impulse-response convolution. The delay taps are static and integer-sample;
  there is no fractional-delay interpolation, so `delay_ms` is rounded up.
- **One reverb algorithm**: the Freeverb-style network is fixed (8 combs, 4
  diffusion sections, 23-sample spread). There is no early-reflection design, no
  modulation to break up metallic tails, and no per-room presets yet.
- **Borrowed memory is the caller's responsibility**: the mixer rejects double
  claims, but it cannot know if you free the buffer while an insert still
  references it — the same contract as borrowed clip samples.
- **No lookahead limiter**: the compressor reacts after the fact, so a fast
  transient can overshoot before the envelope catches it. The output clamp is
  still the last line of defence.
- **No oversampling**: saturation/waveshaping would alias and is deliberately not
  offered yet.
- **No side-chain input, no per-voice inserts**: effects are per bus and on the
  master. A voice reaches them through its bus.
- **No parameter smoothing**: changing coefficients takes effect immediately,
  which can click on a large jump. Ramp the value from the caller, or cross-fade
  between two buses.
- **Mono/stereo only** (`max_channels = 2`), matching the mixer's output contract.
- **No preset/serialization format**: effects are runtime values, not scene
  components. An `AudioEffect` component would be a separate, additive stage.
- **`@exp`/`@log`/`@cos`/`@sin`** are used where the algorithms need them; their
  last bit may differ across libm implementations, the same caveat the
  equal-power pan law already documents.

## Related

- Mixer, voices, buses and routing: [audio-mixer.md](audio-mixer.md)
- Spatial audio and the scene bridge: [audio-spatial.md](audio-spatial.md)
- Audio import / `CXAW`: [asset-audio.md](asset-audio.md)
- Architecture: [architecture.md](architecture.md)
- Coding standards: [development/coding-standards.md](development/coding-standards.md)
