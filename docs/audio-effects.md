# Audio Effects — Insert DSP for Buses and the Master — CoreXEngine

This document describes CoreXEngine's insert effects: the pure DSP module in
`src/audio/effects.zig` (exposed as `corex.audio.effects`) and how the mixer
routes buses through it.

> Status: **implemented and tested**. Biquad filters and a stereo-linked
> compressor, on per-bus and master insert chains, allocation-free at render
> time. **Reverb, delay, convolution, lookahead limiting and oversampled
> saturation are planned** — they need delay lines and are not described here as
> existing capabilities. The mixer itself is documented in
> [audio-mixer.md](audio-mixer.md).

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
- **No allocation, ever.** Filter history is a fixed `[2]` array inside the
  effect, so an effect is a plain value in a preallocated slot. `render` still
  takes no allocator.
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

The default `max_buses = 8`, `block_frames = 256`, stereo gives **16 KiB** of
scratch. The scratch is reserved for every bus, not only the processed ones,
because an insert can be added at any time and `render` must never allocate.
Lower `block_frames` to shrink it; the output does not change.

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
- **Determinism**: two identically driven mixers agree bit for bit over five
  buffers; a chain processed in one pass equals the same chain processed in
  64-sample chunks.

## Limitations and next steps

- **No delay-based effects**: no reverb, echo, chorus, flanger or convolution.
  They need delay lines, which is a separate allocation and a separate stage.
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
