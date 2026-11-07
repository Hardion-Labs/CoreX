
<p align="center">
  <img
    src="assets/branding/LogoBanner_CoreX_1.png"
    alt="CoreX Engine"
    width="100%"
  />
</p>

**A modular game engine written in Zig 0.17.0.**

CoreXEngine provides a clear, extensible foundation for games: an independent
runtime, its own graphical editor and GUI library, tiered renderers, ECS, scenes,
assets, scripting, and production tooling — with a focus on performance, explicit
control, and maintainable code.

> **Scope:** this repository is exclusively the **CoreXEngine**. The
> **CoreXHub** (project creation/registration, recent projects, engine
> installation and version selection) is a separate product in another
> repository and is **not** implemented here. See [`docs/scope.md`](docs/scope.md).

> **Status:** early development. The startup spine (CLI, project manifest,
> compatibility, jobs, configuration, asset indexing, splash contract,
> diagnostics, and the project-open pipeline), the ECS (generational entities,
> sparse-set component pools, type-safe world, multi-component views, comptime
> system scheduling over the job system, automatic dependency graphs, cooperative
> frame budgets and system profiling), the scene system (versioned JSON
> scenes, stable entity IDs, hierarchy, ECS load/save, world-space transform
> propagation, reusable single-root prefabs) and the asset import
> pipeline + content-addressed cache (raw/text/json/scene importers, PNG/BMP/TGA/QOI
> texture decoders over a dependency-free DEFLATE/zlib inflater, OBJ mesh decoder,
> WAV and FLAC audio decoders, atomic verified storage, parallel import over
> the job system, mark-and-sweep GC, change detection with incremental re-import),
> the backend-independent render extraction
> layer (camera math, frustum culling, sorted draw lists) with a CPU software
> rasterizer (fixed-point watertight coverage, depth buffer, textured and
> Lambert-lit shading), and the
> device-independent audio runtime (mixer with voices, buses, pan, pitch,
> linear/band-limited resampling, priority voice stealing and
> biquad/compressor/delay/reverb/limiter/saturator insert chains, plus
> spatialization and the `AudioSource` scene bridge) are
> implemented and tested. The larger
> subsystems (GPU renderer backends, GUI, editor, Lua, export, native modules) are
> in scope and either contract-defined or planned. See
> [`docs/architecture.md`](docs/architecture.md) for the per-subsystem status.

## Overview

- **Language:** Zig 0.17.0
- **License:** MIT — see [`LICENSE`](LICENSE)
- **Approach:** modular, data-oriented, explicit allocators, no external runtime
  dependencies
- **Independence:** the engine never depends on the CoreXHub to run

## Launch contract

The engine is started with a project entry point (a `.corex` file). It accepts
the same arguments whether launched directly or by the CoreXHub:

```sh
# Open the editor for a project:
corex-engine --project "/path/MyGame/MyGame.corex"

# As launched by the CoreXHub:
corex-engine --project "/path/MyGame/MyGame.corex" --hub-launch

# Validate a project without opening the editor:
corex-engine --project "/path/MyGame/MyGame.corex" --mode validate
```

The full argument list, startup sequence, and stable exit codes are documented
in [`docs/launch-contract.md`](docs/launch-contract.md). The `.corex` format is
in [`docs/project-format.md`](docs/project-format.md).

On receiving a project, the engine: initializes essential services, opens the
splash screen, validates the manifest and compatibility, loads configuration in
workers, indexes assets, prepares the initial scene, and opens the editor.

## Requirements

- Zig **0.17.0** (the project's target version)
- Git

## Getting Started

Clone the repository and enter the directory:

```sh
git clone https://github.com/Hardion-Labs/CoreX.git
cd CoreX
```

Build, test, and run:

```sh
zig build           # builds zig-out/bin/corex-engine
zig build test      # runs the engine test suite
zig build run -- --help
```

Try the bundled example project:

```sh
zig build run -- --project examples/hello-project/HelloProject.corex --mode validate
zig build run -- --project examples/hello-project/HelloProject.corex --headless
zig build run -- --project examples/hello-project/HelloProject.corex --headless --frames 120
zig build run -- --project examples/hello-project/HelloProject.corex --headless --frames 60 --fps 60
```

These commands are validated with Zig 0.17.0. Editor/runtime sessions open headless,
report readiness, then run a **frame loop** over the project's own scene and print its
accounting:

```text
Assets uploaded: 1 meshes, 0 textures (0 mipmapped), 0 skipped, 144 bytes
Frames: 120 of 120 (2 allocating) at 1280x720 medium — last frame: 1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled
```

The assets line is what the renderer actually holds — the scratch it copied for meshes
plus every mip level it generated for textures — not the size of the source files, which
are released as soon as a slot is filled.

`--frames` bounds the loop (default 1), and "2 allocating" is the whole warm-up: only the
two draw-list buffers ever touch the general-purpose allocator, so every steady-state
frame is allocation-free. `--fps <n>` paces the loop to that rate and adds a second line
of real measurements:

```text
Pacing: 60 fps — 0 late of 60 frames, 0 resyncs, 794.372 ms slept, 993.652 ms elapsed, 16.561 ms/frame
```

The pacer sleeps against the monotonic clock, anchored so overshoot does not accumulate;
it is **not** vsync (there is no swapchain yet), and the docs say so. The example project ships a quad and a camera, so the frames
draw real geometry. The GUI library is implemented headlessly (see [GUI](#gui)); the graphical editor
and the GPU renderers are not, and there is no window — the loop renders into a surface it owns
([docs/presentation.md](docs/presentation.md)).

## ECS

The engine ships a data-oriented ECS (`corex.ecs`): generational entity handles
(use-after-free safe), sparse-set component storage (O(1) add/remove/get/has,
cache-friendly iteration), and a comptime-typed world with multi-component views.

```zig
const corex = @import("corex");
const Transform = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

const World = corex.ecs.World(.{ Transform, Velocity });
var world = World.init(allocator);
defer world.deinit();

const e = try world.create();
try world.add(e, Transform{ .x = 0, .y = 0 });
try world.add(e, Velocity{ .dx = 1, .dy = 0 });

// A "movement system": iterate entities that have both components.
var it = world.view(.{ Transform, Velocity });
while (it.next()) |entry| {
    // entry = { Entity, *Transform, *Velocity }
    entry[1].x += entry[2].dx;
    entry[1].y += entry[2].dy;
}
```

See [`docs/architecture.md`](docs/architecture.md) for the design and status.

### Scheduling systems

Systems declare read/write component access and are grouped into comptime
stages. Non-conflicting systems in a stage run concurrently over the job system;
conflicts are rejected at compile time.

```zig
const Movement = corex.ecs.schedule.system(World, Context, "movement", move, .{
    .reads = .{Velocity},
    .writes = .{Transform},
});
const Schedule = corex.ecs.Schedule(World, Context, .{.{Movement}});

var js: corex.core.jobs.JobSystem = undefined;
js.init(allocator, null);
defer js.deinit();
try Schedule.run(js.io(), &world, &context);
```

`AutoSchedule` infers the parallel layers automatically from the same access
declarations (conflicting systems get declaration-order edges; exclusive systems
become barriers), and `FrameSchedule` adds allocation-free per-system profiling
plus cooperative frame budgets that stop between systems and resume via a cursor:

```zig
const Auto = corex.ecs.AutoSchedule(World, Context, .{ Movement, Animation });
try Auto.run(js.io(), &world, &context);

const Frame = corex.ecs.FrameSchedule(World, Context, .{ Movement, Animation });
var profiler = Frame.Profiler.init();
var cursor = corex.ecs.FrameCursor{};
const r = try Frame.runBudgeted(js.io(), &world, &context, &profiler, &cursor, .{
    .max_nanoseconds = 2_000_000,
});
// r.completed == false -> call again next frame to resume from cursor.
```

See [`docs/ecs-scheduling.md`](docs/ecs-scheduling.md) for the safety model,
exclusive systems, error semantics, observers, dependency graphs, frame budgets
and the sequential fallback.

## Scenes

Scenes are versioned JSON documents (`.scene`, `format_version = 1`) backed by
the ECS. They carry stable entity IDs, a parent hierarchy and plain-data
components. The startup pipeline loads the initial scene in `editor`/`runtime`;
`validate` still checks only the project manifest, config and asset index.

```zig
const corex = @import("corex");
var scene = try corex.scene.EngineScene.init(allocator, "main");
defer scene.deinit();

const root = try scene.createEntity("Root", null);
try scene.addComponent(root, corex.scene.Transform{ .position = .{ 0, 0, 0 } });
const child = try scene.createEntity("Child", scene.idOf(root));

const bytes = try scene.serialize(allocator); // deterministic JSON
defer allocator.free(bytes);
```

The file format, validation rules and limits are documented in
[`docs/scene-format.md`](docs/scene-format.md).

Local transforms are propagated into world space on demand. `computeWorldTransforms`
returns a deterministic snapshot (one O(n) iterative pass, safe for arbitrarily
deep hierarchies); `worldMatrix` computes a single entity by walking its parent
chain. The `.scene` format keeps storing only local TRS values.

```zig
var wt = try scene.computeWorldTransforms(allocator);
defer wt.deinit();
if (wt.get(child)) |world| {
    // world is a column-major Mat4 = parent_world * child_local
}
```

See [`docs/scene-transforms.md`](docs/scene-transforms.md) for the math
conventions, API and performance notes.

### Prefabs

Prefabs (`.prefab`) are reusable single-root entity subtrees built on the same
versioned scene format. They can be parsed from disk, captured from a live scene
subtree, and instantiated into any same-schema scene with deterministic ID
remapping and copied hierarchy/components. Multiple instances are independent,
and failed instantiations roll back created entities. Prefabs are imported and
cached by the asset pipeline (`AssetKind.prefab`, `prefab` importer).

```zig
var prefab = try corex.scene.EnginePrefab.parse(allocator, prefab_bytes);
defer prefab.deinit();
const a = try prefab.instantiate(&scene, scene.idOf(root));
const b = try prefab.instantiate(&scene, scene.idOf(root)); // independent copy
```

See [`docs/scene-prefabs.md`](docs/scene-prefabs.md) for the format, API,
guarantees and limitations.

**Scene streaming** loads and unloads named sectors of a world into a live scene.
A versioned `.corexstream` manifest maps each sector to an ordinary `.scene` file
plus a spherical volume; a `Stream` brings residency in line with a listener
position or an explicit request. A separate, larger unload radius gives hysteresis
so a listener on a boundary cannot thrash, and per-call load/unload budgets plus a
resident-entity ceiling keep a frame from spiking. The stream tracks exactly the
entities it created, so an unload removes precisely that set and reparents any
entities the caller attached underneath. Loading is all-or-nothing: the rollback
path allocates nothing, so it is exact even when the allocator is what failed.
See [`docs/scene-streaming.md`](docs/scene-streaming.md).

## Assets

The asset subsystem (`corex.assets`) indexes source assets and imports them into
a content-addressed cache. The cache key derives from the source content hash +
importer identity/version + options, so imports are incremental and reproducible:
unchanged sources are reused, and bumping an importer version invalidates its
entries. Writes are atomic and reads verify the payload hash (corrupt entries
self-heal). A mark-and-sweep garbage collector (`Cache.gc` + `Report.liveKeys`)
reclaims orphan entries when sources change or are removed. Built-in importers
cover raw binary, text (UTF-8 + line-ending
normalization), JSON (strict validation + lossless minification) and scenes
(validated and canonicalized via the scene system). Texture sources in **PNG,
JPEG, BMP, TGA and QOI** are decoded to RGBA8 and stored as a self-describing `CXTX`
artifact, and **OBJ** meshes are decoded to indexed triangle meshes stored as a
`CXMH` artifact, and **WAV** (uncompressed PCM 8/16/24/32-bit and IEEE float32)
and **FLAC** audio are decoded to interleaved float32 stored as a `CXAW` artifact;
other binary formats (lossy compressed audio, glTF/FBX) still import as `raw`
until decoders exist.

PNG support covers every color type and bit depth (1/2/4/8/16), all five row
filters, palette and color-key transparency, multi-chunk IDAT and Adam7
interlacing, with chunk CRC-32 and zlib Adler-32 verification. It is backed by a
dependency-free DEFLATE/zlib inflater (`corex.assets.inflate`) whose output is
bounded by the caller, so a decompression bomb cannot exceed the size declared by
the image header. 16-bit samples are reduced to their high byte (the artifact is
RGBA8). Interlaced files decode to exactly the same pixels as their
non-interlaced equivalent.

JPEG support covers sequential Huffman frames (`SOF0`/`SOF1`) at 8-bit precision,
grayscale and YCbCr, every common subsampling (4:4:4, 4:4:0, 4:2:2, 4:2:0, 4:1:1),
restart markers and optimized Huffman tables. Colour conversion and chroma
upsampling reproduce libjpeg exactly; only the inverse DCT differs, because JPEG
does not normatively specify it, so output matches a libjpeg decode to within 3
levels per channel over the reference corpus. Progressive, arithmetic-coded,
lossless, 12-bit and CMYK files are rejected rather than approximated.

```zig
const corex = @import("corex");
const A = corex.assets;

var idx = try A.indexDirectories(gpa, io, project_root, &.{"assets"});
defer idx.deinit();
var cache = try A.Cache.open(io, cache_dir);
defer cache.deinit();
var root = try std.Io.Dir.openDirAbsolute(io, project_root, .{});
defer root.close(io);

var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
defer report.deinit();
// report.imported / report.cached / report.failed / report.total_output_bytes
```

**Change detection** (`corex.assets.changes`) is the hot-reload foundation: a
path-sorted `Snapshot` records each asset's size, mtime and BLAKE3 hash, and
`detect` reports added/modified/removed paths. An unchanged size+mtime fingerprint
skips the read entirely; candidates are hashed so a mere touch or identical
re-save is *not* reported as a change (`verify_all` forces hashing when timestamps
cannot be trusted). `pipeline.Options.only` then re-imports just the changed
paths, and `Snapshot.cacheKeys` derives the **complete** live key set for
`Cache.gc` — a filtered report alone would delete every other artifact.

```zig
var baseline = try A.changes.capture(gpa, io, root, idx, .{});
defer baseline.deinit();
// ... later, after re-indexing ...
var detected = try A.changes.detect(gpa, io, root, &baseline, idx, .{});
defer detected.deinit();
const only = try detected.changes.changedPaths(gpa); // added + modified
defer gpa.free(only);
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
    .only = only,
});
defer report.deinit();
const live = try detected.snapshot.cacheKeys(gpa, A.engineRegistry(), "");
defer gpa.free(live);
_ = try cache.gc(gpa, live);
```

`pipeline.run` imports concurrently over the job system; `runSequential` is a
single-threaded fallback. The cache format, importer contract and limits are
documented in [`docs/asset-import.md`](docs/asset-import.md); the texture
decoders and `CXTX` artifact are documented in
[`docs/asset-decoders.md`](docs/asset-decoders.md); the OBJ mesh importer and
`CXMH` artifact are documented in [`docs/mesh-import.md`](docs/mesh-import.md); the
WAV audio importer and `CXAW` artifact are documented in
[`docs/asset-audio.md`](docs/asset-audio.md), and the FLAC decoder that produces
the same artifact in [`docs/asset-flac.md`](docs/asset-flac.md).

FLAC support covers the whole baseline format: `CONSTANT`/`VERBATIM`/`FIXED`/`LPC`
subframes, orders up to 32, both Rice residual methods with escaped partitions,
1..8 channels plus left/side, right/side and mid/side decorrelation, sample sizes
from 4 to 32 bits, fixed and variable block sizes, and CRC-8/CRC-16 verification.
Because FLAC is lossless, the corpus is checked **bit-exactly** against libFLAC —
there is no tolerance. Paths libFLAC's encoder never chooses (mid/side, Rice
method 1, high LPC and partition orders, the odd bit depths) are covered by
hand-built frames that libFLAC itself decodes back before they are committed.

## Render

The render subsystem (`corex.render`) currently provides the **backend-independent
extraction layer** — the CPU foundation every GPU tier will consume. It builds
camera view/projection matrices, frustum-culls renderables, and produces a sorted
draw list from a scene. A **CPU software rasterizer** then turns that list into an
RGBA8 framebuffer with a depth buffer. Neither has a GPU dependency, so both run
and are fully tested headlessly. The Low/Medium GPU backends are planned.

A scene file can author it directly: `corex.scene.render_scene` provides
`EngineRenderScene` (`transform` + `renderable` + `camera`), loads a project's
meshes (`.mesh` artifacts and `.obj` sources) and textures into a renderer table
through a deterministic path-to-handle layout, and drives a frame with the scene's
own camera (`EngineRenderer.render` / `renderSceneFrame`). The engine binary uses it
to render the startup frame, so `renderable`/`camera` in a `.scene` are real, not
documentation.


```zig
const corex = @import("corex");
const R = corex.render;
const MyScene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(R.Renderable, "renderable"),
});
var scene = try MyScene.init(allocator, "main");
defer scene.deinit();
// ... add entities with Transform + Renderable ...

const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, 1.0, 1.6, 0.1, 500);
var frame = try R.extractDrawList(&scene, cam, .front_to_back, allocator);
defer frame.deinit();
// frame.commands: culled + sorted DrawCommands; frame.culled: how many were rejected

// Rasterize on the CPU. `resources` resolves the opaque mesh/material handles.
var target = try R.Target.init(width, height, color_bytes, depth_values);
target.clear(.{ 0, 0, 0, 255 }, 1.0);
const stats = try R.rasterize(&target, frame.commands, cam.view_projection, resources, .{});
// stats.pixels written; target.color is plain RGBA8 (feeds the QOI encoder as-is)
```

Coverage uses 28.4 fixed-point integer edge functions with a top-left fill rule,
so it is bit-exactly reproducible and shared edges are watertight — no cracks and
no double-drawn pixels. The pixel path takes no allocator (only `.edge`
antialiasing allocates, through the caller's allocator). Materials shade flat or
sample a borrowed RGBA8 texture with repeat wrap and nearest/bilinear filtering;
UVs interpolate perspective-correctly and the texel multiplies the material tint.
A single directional Lambert light (`Options.light`) and framebuffer blending
(`Options.blend`: `.none`, straight-alpha, premultiplied, additive) are
supported. `Options.antialias = .edge` supersamples geometry edges 4x4 (16 exact
integer sub-samples per pixel sharing the same top-left rule, accumulated per draw
command so shared edges stay seam-free and full-coverage pixels stay
byte-identical); it needs an allocator for its per-draw scratch, so it goes
through `rasterizeAlloc` / `drawMeshAlloc`. Minification is handled by a **mip
chain** (`Texture.mips`, built by `corex.render.mipmap.Chain.generate` with an
integer box filter) and per-pixel LOD selection from the exact screen-space UV
gradient (`Options.mipmap = .trilinear`, the default; `.level0` keeps the crisp
aliased path); a texture without `mips` samples level 0 exactly as before.
`Options.mipmap = .anisotropic` adds up to eight taps along an elongated pixel
footprint, which stops the over-blur a grazing surface gets from a single level —
free when the footprint is round, ~5x at a full 8:1 grazing footprint, so it is
opt-in. `corex.render.raster.Sampling` adds the two per-material controls a real
renderer exposes — a LOD bias and an anisotropic tap cap — as plain data on
`Options.sampling`, overridable per material by the resource provider's optional
`sampling(handle)`; the default biases and caps nothing, so it changes no existing
frame, and a tier without the capability renders with the uncorrected level.

Extraction is frustum-culled by default and can additionally run a **conservative
tile occlusion pass** (`FrameParams.occlusion`): large visible bounds claim the screen
tiles their projected hull fully covers, and a bound whose entire screen rectangle is
covered by strictly nearer geometry is dropped before it becomes a draw command. It
can only remove hidden geometry, so the frame is byte-identical with it on or off —
only shorter (2,006 of 2,008 commands removed on the benchmark scene, at ~0.16 ms of
extraction cost).

The extraction design and math conventions are documented in
[`docs/render-extraction.md`](docs/render-extraction.md); the rasterizer, its
verification and its limits in [`docs/render-raster.md`](docs/render-raster.md);
the renderer **tier contract** (Low/Medium/Advanced capabilities, the backend
vtable, the frame lifecycle and the CPU driver that implements Medium today) in
[`docs/render-backend.md`](docs/render-backend.md) — including the frame pipeline
that renders a scene through the contract (`renderScene`) and the handle tables
that adapt real `CXMH`/`CXTX` assets to it.

## Audio

The audio subsystem (`corex.audio`) provides the **device-independent mixer** —
the CPU foundation the OS playback backends will consume. It mixes a fixed pool
of voices with gain, stereo pan (linear or equal-power), buses, master gain,
pitch and looping into an interleaved float32 buffer. Resampling is linear by
default or **band-limited windowed-sinc** on request (`.resample = .sinc`), which
low-passes before decimating instead of aliasing. A full voice pool either fails
or, with `.steal_policy = .lowest_priority`, recycles the least important voice —
`priority` ranks sources and `terminationOf` explains why a handle died even after
its slot was reused. `render` takes no allocator: it cannot allocate, and it is
deterministic (bit-identical output for the same call sequence). Voices are
addressed by generational handles, so a stale handle is inert instead of aliasing
a recycled voice. It has no device dependency, so it runs and is fully tested
headlessly; ALSA/WASAPI/CoreAudio backends and modulated/convolved effects are
planned.

Buses and the master accept **insert chains** (`.effect_slots > 0`): RBJ biquad
filters (low/high pass, band pass, notch, peaking, shelves), a stereo-linked
soft-knee compressor, a feedback delay with damping, a Freeverb-style reverb, and
a lookahead brickwall limiter whose cost is flat in the lookahead length and
which can measure true (inter-sample) peaks, and an oversampled saturator. Only buses with an active chain are isolated into a
preallocated submix, so an all-bypass configuration is bit-identical to the
effect-free path and `render` still never allocates. Parameters, measured costs
and limits are in [`docs/audio-effects.md`](docs/audio-effects.md).

```zig
var mixer = try A.Mixer.init(allocator, .{ .effect_slots = 4 });
defer mixer.deinit();
// Muffle the world bus, then glue the master.
try mixer.setBusEffect(1, 0, try A.Effect.biquad(48_000, .{ .kind = .low_pass, .cutoff_hz = 600 }));
try mixer.setMasterEffect(0, try A.Effect.compressor(48_000, .{ .threshold_db = -6, .ratio = 2 }));

// Delay-based effects borrow caller memory, so they cost the mixer nothing.
const memory = try allocator.alloc(f32, try A.Reverb.requiredSamples(48_000, 2)); // 108 KiB
defer allocator.free(memory);
var room = try A.Reverb.init(48_000, 2, .{ .room_size = 0.8 }, memory);
try mixer.setMasterEffect(1, A.Effect.reverb(&room));

// Brickwall ceiling. Runs before master_gain, so keep that at or below 1.
const lim_mem = try allocator.alloc(f32, try A.Limiter.requiredSamples(48_000, 2, .{})); // 3.8 KiB
defer allocator.free(lim_mem);
var limiter = try A.Limiter.init(48_000, 2, .{ .ceiling_db = -1 }, lim_mem);
try mixer.setMasterEffect(2, A.Effect.limiter(&limiter));

// Oversampled drive; all state is inline, so there is no buffer to allocate.
var saturator = try A.Saturator.init(48_000, 2, .{ .drive = 6, .oversample = 2 });
try mixer.setBusEffect(2, 0, A.Effect.saturator(&saturator));
```

```zig
const corex = @import("corex");
const A = corex.audio;
var mixer = try A.Mixer.init(allocator, .{ .sample_rate = 48_000, .channels = 2 });
defer mixer.deinit();

// `samples` is a borrowed interleaved f32 buffer (e.g. from a CXAW artifact).
const voice = try mixer.play(.{
    .sample_rate = 44_100,
    .channels = 2,
    .frames = frame_count,
    .samples = samples,
}, .{ .gain = 0.8, .pan = -0.25, .looping = true, .bus = 1, .priority = 200 });

try mixer.setBusGain(1, 0.5); // music bus
var buffer: [512 * 2]f32 = undefined;
const stats = try mixer.render(&buffer); // stats.peak / .voices_active / .clipped_samples
var pcm: [512 * 2]i16 = undefined;
try A.toPcm16(&pcm, &buffer); // device-ready conversion
mixer.stop(voice);
```

Clips come from the asset pipeline: a `CXAW` artifact parsed with
`corex.assets.audio.parse` maps to `A.Clip` field by field, and the mixer never
imports the asset layer. The mixing contract, channel/pan rules, metering and
limitations are documented in [`docs/audio-mixer.md`](docs/audio-mixer.md).

On top of the mixer, the **spatial layer** (`corex.audio.spatial` +
`corex.audio.AudioSystem`) bridges the scene to the voices, exactly like the
render extraction layer does for draw calls. `AudioSource` is a plain-data scene
component; `AudioSystem.update` computes the world-transform snapshot once,
spatializes each emitter against a `Listener` (distance attenuation, azimuth pan,
Doppler, 2D/3D blend) and reconciles voices: start, refresh, restart on clip
change, stop, cull silent sources and sweep vanished entities. It never writes to
the scene.

```zig
const A = corex.audio;
const Scene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(A.AudioSource, "audio_source"),
});
var world = try Scene.init(allocator, "world");
defer world.deinit();
var audio_system = try A.AudioSystem.init(allocator, &mixer, .{});
defer audio_system.deinit(); // stops the voices it started

const e = try world.createEntity("emitter", null);
try world.addComponent(e, corex.scene.Transform{ .position = .{ 0, 0, -2 } });
try world.addComponent(e, A.AudioSource{ .playing = true, .looping = true });

const listener = A.Listener.fromMatrix(try world.worldMatrix(allocator, camera));
const stats = try audio_system.update(&world, listener, &clips);
// stats.started / .updated / .stopped / .finished / .culled / .unplayed
```

Attenuation models, the pan law, Doppler clamping, transport semantics and
guarantees are documented in [`docs/audio-spatial.md`](docs/audio-spatial.md).

## Project Structure

```text
CoreX/
├── assets/branding/            # Logo and branding
├── docs/
│   ├── scope.md                # Definitive project scope (Engine vs Hub)
│   ├── architecture.md         # Subsystem map and implementation status
│   ├── ecs-scheduling.md       # ECS system scheduling guide
│   ├── asset-import.md         # Asset import pipeline + cache
│   ├── asset-change-detection.md # Change detection + incremental import (hot-reload)
│   ├── asset-decoders.md       # Image decoders (PNG/BMP/TGA/QOI) + CXTX artifact
│   ├── mesh-import.md          # OBJ mesh importer + CXMH artifact
│   ├── asset-audio.md          # WAV audio importer + CXAW artifact
│   ├── asset-flac.md           # FLAC decoder + the same CXAW artifact
│   ├── scene-streaming.md      # .corexstream sectors + residency streaming
│   ├── launch-contract.md      # Stable startup contract (CLI, exit codes)
│   ├── project-format.md       # .corex manifest format
│   ├── scene-format.md         # Versioned .scene format
│   ├── scene-transforms.md     # World-space transform propagation
│   ├── scene-prefabs.md        # Reusable single-root prefabs (.prefab)
│   ├── render-extraction.md    # Backend-independent render extraction
│   ├── render-raster.md        # CPU software rasterizer (coverage + depth)
│   ├── audio-mixer.md          # Device-independent audio mixer (voices/buses)
│   ├── audio-effects.md        # Insert DSP: biquads, compressor, chains
│   ├── audio-spatial.md        # Spatial audio + AudioSource/AudioSystem
│   ├── gui-foundation.md       # Built-in GUI: font, canvas, layout, widgets
│   ├── versioning.md           # Versioning and compatibility policy
│   ├── native-module-api.md    # C++ native module ABI contract
│   ├── development/            # Coding standards, commit guidelines
│   └── policies/               # AI-assisted development policy
├── examples/hello-project/     # Minimal example project (.corex)
├── include/corex/              # Native Module ABI header (C)
├── src/
│   ├── main.zig                # Executable entry point
│   ├── corex.zig               # Public module
│   ├── core/                   # Implemented startup-spine subsystems
│   ├── ecs.zig                 # ECS public module
│   ├── ecs/                    # Entities, pools, world/views, scheduling, frame budgets
│   ├── scene.zig               # Scene public module (EngineScene)
│   ├── scene/                  # Scene components, versioned documents, prefabs
│   ├── assets.zig              # Asset public module (index + import + cache)
│   ├── assets/                 # Import cache, importers, decoders, change detection, pipeline
│   ├── render.zig              # Render public module (extraction layer)
│   ├── render/                 # Camera, culling, draw lists, software rasterizer
│   ├── audio.zig               # Audio public module (mixing runtime)
│   └── audio/                  # Clips, mixer, spatialization, bridge, resampler, DSP
├── tools/                      # Reproducible test-vector generators
├── build.zig                   # Build configuration
└── CHANGELOG.md, CONTRIBUTING.md, LICENSE, README.md, ...
```

## Roadmap

Indicative; subject to change as technical decisions are validated.

- [x] Definitive scope and Engine/Hub boundary.
- [x] Build and tests validated with Zig 0.17.0.
- [x] Launch contract: CLI, `.corex` manifest, compatibility, exit codes.
- [x] Startup pipeline: services, splash, manifest, config, assets, scene, editor.
- [x] Job system and async loading foundation.
- [x] Diagnostics and profiling foundation.
- [x] ECS: generational entities, sparse-set components, type-safe world + views.
- [x] ECS system scheduling over the job system (comptime stages, access validation).
- [x] ECS scheduling extensions: dependency graph, frame budget, profiling.
- [x] Scene system and versioned scene serialization (format v1, ECS load/save).
- [x] Scene world-space transforms (column-major Mat4 propagation, deterministic, iterative).
- [x] Scene prefabs (single-root `.prefab`, capture/instantiate, ID remap, asset import).
- [x] Scene streaming (`.corexstream` sectors, proximity + hysteresis, budgeted, exact unload).
- [x] Asset import pipeline and content-addressed cache (raw/text/json/scene).
- [x] Texture decoders (PNG/BMP/TGA/QOI → RGBA8 `CXTX` artifact).
- [x] DEFLATE/zlib inflate (dependency-free, bounded output).
- [x] Asset cache garbage collection (mark-and-sweep of orphan entries).
- [x] Asset change detection + incremental import (hot-reload foundation).
- [x] Mesh decoder (OBJ → indexed triangle mesh, `CXMH` artifact).
- [x] Audio decoder (WAV/PCM + IEEE float32 → interleaved f32 `CXAW` artifact).
- [x] JPEG decoder (sequential Huffman, grayscale/YCbCr, all common subsamplings).
- [x] FLAC decoder (lossless, bit-exact against libFLAC, same `CXAW` artifact).
- [ ] Asset decoders (progressive JPEG, lossy compressed audio, other model formats).
- [x] Audio mixer (voices, buses, gain/pan, pitch, resampling, allocation-free render).
- [x] Spatial audio (listener, attenuation models, Doppler) + `AudioSource` scene bridge.
- [x] Voice stealing with priorities + band-limited (windowed-sinc) resampling.
- [x] Insert effects: biquad filters + compressor on per-bus and master chains.
- [x] Delay-based effects: feedback delay with damping + Freeverb-style reverb.
- [x] Lookahead brickwall limiter (O(1) sliding maximum, exact ceiling, no overshoot).
- [x] Oversampled saturation + true-peak (inter-sample) limiting.
- [ ] Chorus/flanger, convolution, side-chain.
- [ ] Audio device backends (ALSA/WASAPI/CoreAudio), HRTF/occlusion, effects, streaming.
- [ ] Hot-reload event watcher (inotify/FSEvents), dependency graph, startup/editor integration.
- [x] Backend-independent render extraction (camera, frustum culling, sorted draw lists).
- [x] Extraction occlusion culling: conservative tile depth buffer, opt-in, byte-identical frames.
- [x] CPU software rasterizer (fixed-point watertight coverage, depth buffer, textured shading).
- [x] Rasterizer lighting: single directional Lambert (face normals, CPU reference path).
- [x] Renderer tier contract (Low/Medium/Advanced capabilities + backend vtable, CPU driver).
- [x] Frame pipeline over the contract (`renderScene`, tier selection from `settings.json`, asset handle tables).
- [ ] Renderer Low / Medium GPU backends implementing that contract.
- [x] Rasterizer blending: `.none`, straight-alpha source-over, premultiplied, additive.
- [x] Rasterizer antialiasing: 4x4 sub-sample coverage, per-draw accumulation, `Antialias.edge`.
- [x] Rasterizer mipmaps: integer box-filter chain, per-pixel LOD, trilinear sampling.
- [x] Rasterizer anisotropic filtering: up to 8 footprint-aligned taps, `Mipmap.anisotropic`.
- [x] Per-material LOD bias and anisotropic tap cap (`Sampling`, frame default + per-material override).
- [x] GUI library foundation: built-in font, RGBA8 canvas, text, layout, immediate-mode widgets, headless frame renderer.
- [ ] Graphical editor on top of the GUI library.
- [ ] Lua VM and gameplay scripting.
- [ ] Native Module API loader (C++).
- [ ] Runtime player and export system / Export Templates.
- [x] CI pipeline (build + test + launch-contract smoke on Zig 0.17.0).

## GUI

The engine ships its **own** GUI layer (`corex.gui`), the foundation the graphical
editor will sit on: a built-in 8x8 bitmap font, an RGBA8 canvas, text drawing,
stacking layout, and immediate-mode widgets (panel, label, button, checkbox,
slider, single-line text field) with a theme.

It has no window, no system font and no external toolkit dependency, and it paints
into a caller-owned buffer in the **same layout the engine already speaks**
(row-major, top-down, 4 bytes per pixel — `assets.image.Image.pixels`,
`raster.Target.color`), so a GUI frame composites onto a rendered scene with no
conversion and encodes straight to QOI.

```zig
const corex = @import("corex");
const G = corex.gui;

var pixels: [220 * 132 * 4]u8 = undefined;
var canvas = try G.canvas.Canvas.init(220, 132, &pixels);
canvas.clear(.{ 0x12, 0x12, 0x14, 0xff });

// Two hit-test tables: the widget the pointer is over is resolved from the
// previous frame's paint order, so the last-painted widget on top wins the click.
var entries: [32]G.widgets.Entry = @splat(undefined);
var next: [32]G.widgets.Entry = @splat(undefined);
var ctx = G.widgets.Context.init(canvas, .{}, .{ .pointer = .{ .x = 10, .y = 10 }, .pointer_in_window = true }, &entries, &next);

ctx.beginFrame(.{ .pointer = .{ .x = 10, .y = 10 }, .pointer_in_window = true });
const content = G.widgets.panel(&ctx, G.canvas.Rect.init(8, 8, 204, 116), "Inspector");
var stack = G.layout.Layout.init(content, .vertical).withSpacing(4);
const row = G.layout.Size.init(content.w, 16);

_ = G.widgets.label(&ctx, stack.measure(.{ .w = row.w, .h = 8 }), "immediate mode, no window");
if (G.widgets.button(&ctx, G.widgets.Id.from(1, "apply"), stack.measure(row), "Apply").clicked) {
    // the action fires on release inside the button
}
var snap = false;
_ = G.widgets.checkbox(&ctx, G.widgets.Id.from(2, "snap"), stack.measure(row), "snap to grid", &snap);
var scale: i32 = 35;
_ = G.widgets.slider(&ctx, G.widgets.Id.from(3, "scale"), stack.measure(row), "scale", 0, 100, &scale);
ctx.endFrame();
```

`zig build gui-frame -- frame.qoi` paints one frame of real widgets headlessly and
writes it as QOI — the GUI's smoke test:

![Headless GUI frame rendered by `zig build gui-frame`](gui-frame-preview.png)

The font is printable ASCII in an 8x7 grid with `cell_width = 6`; `measure` returns
the advance (`(len-1)*6 + ink`), so labels are not padded to a fixed grid. The canvas
is allocation-free and clips every primitive; opaque fills are exact stores and
alpha-zero is a no-op. Layout is a forward-only cursor that **truncates** rather than
overflowing, and widget identity is a Wyhash of a caller seed plus a name, so no
widget object has to be retained. `blockBelow` lets a modal block the panel behind it
without disabling its own controls.

Limits: no window/swapchain (blocked in this environment), no text shaping beyond
ASCII, no wrapping, no automatic Tab traversal, bounded hit-test tables. The design,
contracts and limitations are in [`docs/gui-foundation.md`](docs/gui-foundation.md).

## Development

Before contributing, read [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`docs/architecture.md`](docs/architecture.md),
[`docs/development/coding-standards.md`](docs/development/coding-standards.md),
[`docs/policies/AI_POLICY.md`](docs/policies/AI_POLICY.md). For the durable record of
current progress, decisions, pending items and the next priority task, see
[`docs/development/progress.md`](docs/development/progress.md). Keep code in Zig,
minimize dependencies, and include tests for new or changed behavior.

Local checks:

```sh
zig build
zig build test
zig fmt --check src/ build.zig tools/
zig build gui-frame -- frame.qoi   # headless GUI frame, for visual inspection
```

## Contributions

Issues and pull requests are welcome. For substantial changes, open an issue
first to discuss the goal, scope, and architectural impact. Also see the
[support](SUPPORT.md) and [security](SECURITY.md) guidelines.

## License

CoreXEngine is distributed under the MIT License. See [`LICENSE`](LICENSE).
