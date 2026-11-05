# Spatial Audio and Scene Integration — CoreXEngine

This document describes CoreXEngine's spatial audio layer: the listener/attenuation/
Doppler math and the `AudioSource` component + `AudioSystem` that drive the mixer
from a scene. The code lives in `src/audio/spatial.zig` and `src/audio/system.zig`
and is exposed as `corex.audio`.

> Status: **implemented and tested**. This is the audio counterpart of the render
> extraction layer ([render-extraction.md](render-extraction.md)): it bridges the
> ECS/scene to a device-independent subsystem with pure CPU work, so it is fully
> testable headlessly. It drives the mixer ([audio-mixer.md](audio-mixer.md)) with
> clips decoded from `CXAW` ([asset-audio.md](asset-audio.md)). **OS playback
> backends, HRTF/binaural, occlusion/reverb and effects are planned** and are not
> described here as existing capabilities.

## Overview

```
scene (Transform + AudioSource) ──► world transforms (O(n) snapshot)
                                              │
Listener (pose + velocity) ──► spatialize ────┤
                                              ▼
                                     AudioSystem.update
                                              │ start / update / stop
                                              ▼
                                     Mixer voices ──► render ──► f32 buffer
```

Coupling is one-way: `system.zig` knows the scene's transform math and the mixer;
neither the mixer nor the scene knows about it. The mixer remains usable with no
scene at all, and `spatial.zig` is pure functions with no mixer dependency.

## Coordinate conventions

Matching the render layer: **right-handed** world space, the listener looks down
its **-Z** axis, `+Y` is up, and the right axis is `normalize(forward × up)`.
Distances are in world units; the default attenuation reference distance is 1
unit, so a source 1 unit away plays at unity gain.

## Distance attenuation

`Attenuation { model, min_distance, max_distance, rolloff }`. The distance is
**clamped** to `[min_distance, max_distance]` before the formula — the variant
engines use in practice, because it bounds the gain and freezes attenuation past
the far plane.

| Model | Formula (with `d` clamped) | Notes |
| --- | --- | --- |
| `.none` | `1` | No falloff; for 2D sounds |
| `.linear` | `1 - rolloff · (d - min) / (max - min)` | Reaches silence at `max` |
| `.inverse` (default) | `min / (min + rolloff · (d - min))` | Physically plausible falloff |
| `.exponential` | `(d / min) ^ -rolloff` | Power-law falloff |

Guarantees:

- The result is always in `[0, 1]`; a rolloff above 1 clamps at silence instead of
  going negative.
- `rolloff = 0` disables falloff for every model.
- A zero-width range (`max == min`) has no slope and yields unity — no division by
  zero, no NaN.
- A non-finite distance yields **silence** rather than propagating NaN into a mix.
- `isValid()` requires `min > 0`, `max >= min`, `rolloff >= 0` and all finite. The
  scene rejects an invalid component at `addComponent`/serialize time.

## Panning

Amplitude pan from the azimuth: `pan = clamp(dot(normalize(source - listener),
listener.right), -1, 1)`, i.e. the **sine of the azimuth**. A source abeam pans
hard, a source ahead or behind pans center, elevation does not affect pan, and a
coincident source pans center.

This is a stereo amplitude pan, so **front and back are indistinguishable** — that
is inherent to the technique, not a bug. There is no HRTF, no inter-aural delay
and no head shadowing. The resulting pan feeds the mixer's pan law (`.linear` or
`.equal_power`) directly.

## Doppler

With `dir` pointing from the listener to the source:

```
pitch = (c + factor · dot(listener_velocity, dir)) / (c + factor · dot(source_velocity, dir))
```

- A listener moving toward the source raises the pitch; a source moving toward the
  listener (negative projection) raises it too.
- `factor = 0` disables the effect (the default for a source); `factor = 1` is
  physical. `c` is `Config.speed_of_sound` (343.3 world units/s by default).
- Both numerator and denominator are floored at `c / 100`, so a supersonic source
  cannot divide by zero or flip the sign, and the result is clamped to
  `[1 / max_pitch, max_pitch]`.
- Coincident source and listener have no direction, so there is no shift.
- Velocities are **explicit**: `AudioSource.velocity` and `Listener.velocity` are
  set by the caller. There is no automatic differentiation from position deltas.

## Spatial blend

`spatial_blend` in `[0, 1]` cross-fades between a flat 2D mix and full 3D:

| Blend | Gain | Pan | Doppler |
| --- | --- | --- | --- |
| 0 | 1 (unity) | 0 (center) | 1 (off) |
| 1 | attenuation | azimuth pan | full shift |
| between | `lerp(1, attenuation, blend)` | `pan · blend` | `lerp(1, shift, blend)` |

This is how a sound is faded from diegetic 3D to a flat mix (music, UI, narration).

## The `AudioSource` component

Plain data, so it is added to a schema with `Component(AudioSource, "audio_source")`
and **serializes like any component** (a test round-trips it through
`Scene.serialize`/`parse`, including the nested attenuation enum).

| Field | Default | Meaning |
| --- | --- | --- |
| `clip` | 0 | Opaque handle into the caller's clip table |
| `bus` | 0 | Mixer bus |
| `gain` | 1 | Linear gain, applied on top of the spatial gain |
| `pitch` | 1 | Base rate; the Doppler multiplier is folded in |
| `looping` | false | Whole-clip looping |
| `playing` | false | Transport request (see below) |
| `spatial_blend` | 1 | 0 = 2D, 1 = fully 3D |
| `attenuation` | inverse, 1..100, rolloff 1 | Distance model |
| `doppler_factor` | 0 | Per-source Doppler strength |
| `velocity` | (0,0,0) | World-space velocity for Doppler |

`clip` is an **opaque handle**, exactly like `Renderable.mesh`: resolving asset
ids to decoded `CXAW` buffers belongs to the asset layer, not to the component.
`isValid()` rejects non-finite gain/pitch/velocity, `pitch <= 0`, a blend outside
`[0, 1]`, a negative Doppler factor and an invalid attenuation.

## Transport semantics

`playing` is a **request**, and `AudioSystem.update` **never writes to the scene**:

- A source starts when `playing` is true and it has no voice yet.
- A non-looping voice that reaches its end is reported once in `Stats.finished`
  and is **not restarted** while `playing` stays true. The caller toggles
  `playing` off and on to replay. This keeps one-shots from silently becoming
  loops and keeps scene documents byte-stable.
- Setting `playing` false stops the voice and forgets the source.
- Changing `clip` while playing restarts the voice on the new clip.
- Changes to `gain`, `pitch`, `bus` and `looping` are applied to the live voice
  every update; position/rotation changes are re-spatialized every update.

## `AudioSystem`

```zig
const A = corex.audio;
const Scene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(A.AudioSource, "audio_source"),
});

var scene = try Scene.init(gpa, "world");
defer scene.deinit();
var mixer = try A.Mixer.init(gpa, .{ .sample_rate = 48_000, .channels = 2 });
defer mixer.deinit();
var system = try A.AudioSystem.init(gpa, &mixer, .{ .speed_of_sound = 343.3 });
defer system.deinit(); // stops the voices it started

const e = try scene.createEntity("emitter", null);
try scene.addComponent(e, corex.scene.Transform{ .position = .{ 0, 0, -2 } });
try scene.addComponent(e, A.AudioSource{ .playing = true, .looping = true });

// The listener usually comes from the camera entity's world matrix.
const world = try scene.worldMatrix(gpa, camera_entity);
const listener = A.Listener.fromMatrix(world);

const stats = try system.update(&scene, listener, &clips);
// stats.sources / .started / .updated / .stopped / .finished
// stats.culled / .unplayed / .invalid

var buffer: [512 * 2]f32 = undefined;
_ = try mixer.render(&buffer);
```

- `init` validates the configuration and returns `error.InvalidConfig` for a
  non-finite/non-positive speed of sound or a Doppler clamp below 1, so an
  inverted clamp range can never reach the mixing path.
- The system **borrows** the mixer; the caller owns it. `deinit` stops the voices
  the system started, so no orphan voice survives it, and the mixer's bus/master
  settings are untouched.
- `Listener.fromMatrix(world)` takes translation from the fourth column, forward
  from -Z and up from +Y, normalizes away scale and re-orthogonalizes the basis. A
  degenerate matrix falls back to the identity basis at the same position, so a
  broken transform silences panning instead of producing NaN.
- Entities without a `Transform` sound from the world origin (identity matrix),
  matching how the render extraction treats them.
- Parent transforms are honored: the world snapshot is the same O(n)
  parents-before-children pass the scene already provides.

### Silent-source culling

With `Config.cull_silent` (default true), a source whose spatialized gain is
**exactly zero** is not started (`Stats.culled`). A voice already playing is never
culled, so a source that moves out of range and back is not cut off, and a culled
source starts as soon as it becomes audible.

### Diagnostics

| Field | Meaning |
| --- | --- |
| `sources` | `AudioSource` components visited |
| `started` | Voices started (including clip-change restarts) |
| `updated` | Live voices refreshed |
| `stopped` | Voices stopped (transport off, invalid source, entity/component gone) |
| `finished` | Voices that reached their end since the previous update |
| `culled` | Sources not started because their gain was zero |
| `unplayed` | Sources that could not start because the pool was full |
| `invalid` | Invalid component or out-of-range clip handle |

A full voice pool is **reported, not hidden**: `unplayed` counts the sources that
could not start, and they start on a later update once a slot frees. There is no
implicit voice stealing yet.

## Guarantees and tests

- **Attenuation**: every model checked against its formula at the reference
  distance, midpoint and far clamp; rolloff 0 and > 1; a zero-width range;
  non-finite distances; invalid settings rejected.
- **Listener**: right-handed basis, a rotated **and scaled** world matrix stays
  orthonormal, degenerate/parallel bases fall back safely, non-finite poses
  rejected.
- **Pan**: right/left/ahead/behind/above/coincident, 45°, and a rotated listener.
- **Doppler**: approaching and receding source, chasing listener, identical
  velocities (no shift), factor 0, supersonic clamping in both directions,
  coincident case, invalid settings.
- **Blend**: 0 / 0.5 / 1 for gain, pan and pitch; out-of-range blend clamped;
  extreme inputs still produce finite, positive, mixer-safe values.
- **System**: start/stop/replay, one-shot finishes exactly once and is not
  restarted, spatial gain/pan from world transforms, parent transforms, missing
  `Transform`, culling and recovery, clip-handle change restart, gain/pitch/bus/
  looping propagation, Doppler from component velocity, entity destruction and
  component removal, invalid components and clip handles, pool exhaustion and
  recovery, `stopAll`/`deinit` releasing every voice.
- **Serialization**: `AudioSource` round-trips through `.scene` JSON (including
  the attenuation enum), serialization is deterministic, and an invalid
  component is rejected.
- **Memory**: `checkAllAllocationFailures` over three updates (start, refresh,
  stop) with no leaks and no swallowed `OutOfMemory`; a failed map insertion
  stops the voice it just started instead of leaking it.
- **Determinism**: two identical scenes driven identically produce bit-identical
  audio.
- **Integration**: a scene emitter plays a real imported `CXAW` clip and the
  rendered samples equal the decoded samples times the spatial gain, exactly;
  moving the emitter changes gain and pan; clearing `playing` silences the buffer.

## Performance

Measured on this machine, `ReleaseFast`, best of 300 iterations, **1000 entities
with `AudioSource`** (64 of them playing, the rest idle or culled), stereo output
at 48 kHz:

| Work | Time |
| --- | --- |
| `AudioSystem.update` (world snapshot + spatialization + reconciliation) | **172.9 µs** |
| `update` + `Mixer.render` of a 512-frame buffer | **228.4 µs** |

A 512-frame buffer is 10.7 ms of audio, so the whole scene reconciliation plus mix
runs ~47× faster than real time.

- One world-transform snapshot per update (the scene's existing O(n) pass), not
  one matrix computation per source.
- Entity-to-voice state is an `AutoHashMapUnmanaged` keyed by the generational
  entity key: O(1) lookup per source, and a mark-and-sweep over the map reclaims
  sources whose entity or component disappeared. Removal only tombstones a slot
  and never rehashes, so the sweep is safe while iterating.
- The component is copied by value before any mixer call, so no pointer into an
  ECS pool is held across a call that could mutate storage.
- No allocation in the mixer; the only allocations per update are the transform
  snapshot and map growth.

## Limitations and next steps

- **No device backend** — see [audio-mixer.md](audio-mixer.md). This layer ends at
  the same f32 buffer.
- **Amplitude pan only**: no HRTF/binaural, no inter-aural delay, front/back
  ambiguity, no elevation cues.
- **No occlusion, obstruction, reverb zones or reflections**; nothing raycasts the
  scene.
- **No automatic velocity**: Doppler needs explicit velocities; there is no
  finite-difference derivation from transform deltas.
- **No voice stealing or priorities**: a full pool reports `unplayed`.
- **No area/volume emitters**: sources are points; no cones or directional
  emitters yet.
- **No pause per source**: `playing` is a boolean transport, so pausing a source
  stops it (the mixer itself supports pause, but the component does not expose it
  yet).
- **Not wired into startup or the frame loop**: the caller drives `update` and
  `render`, like the render extraction layer.

## Related

- Audio mixer: [audio-mixer.md](audio-mixer.md)
- Audio import / `CXAW`: [asset-audio.md](asset-audio.md)
- Render extraction (the same scene-bridge pattern): [render-extraction.md](render-extraction.md)
- Scene transforms: [scene-transforms.md](scene-transforms.md)
- Scene format: [scene-format.md](scene-format.md)
- Architecture: [architecture.md](architecture.md)
