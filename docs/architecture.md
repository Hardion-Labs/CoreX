# Architecture and Principles — CoreXEngine

This document records the architecture of the CoreXEngine, the subsystem map,
and the implementation status of each part. The definitive project boundary is
in [scope.md](scope.md); the stable startup contract is in
[launch-contract.md](launch-contract.md).

> Status legend: **implemented** = present and tested in this repository;
> **contract defined** = a stable interface/format is documented but the full
> subsystem is not yet built; **planned** = in scope, not yet designed in detail.
> Planned items are not described as existing capabilities.

## Principles

1. **Zig end to end:** engine runtime and tools are written in Zig 0.17.0.
   Native (C/C++) dependencies are adopted only with documented justification,
   through the Native Module API.
2. **Explicit ownership:** APIs make clear who allocates, owns, and releases
   each resource. Allocators are passed explicitly.
3. **Composition:** subsystems are independently usable and testable.
4. **Data before abstractions:** data structures and access patterns fit the
   engine's actual workload; no speculative abstraction.
5. **Visible compatibility:** the supported Zig version is documented and
   changes are validated with builds and tests.
6. **Independence from the Hub:** the engine never depends on the CoreXHub.
   Integration is only via launch arguments, documented formats, and stable
   contracts.

## Architectural rules (from the definitive scope)

- No internal Project Manager.
- No project catalog / recent-projects list.
- No project creation inside the engine.
- No silent installation or selection of engine versions.
- No coupling to the CoreXHub.

Project creation, registration, recent projects, engine installation/version
selection, and installation management belong to the CoreXHub (separate repo).

## Module layout

The public surface is concentrated in `src/corex.zig`. Implemented modules live
under `src/core/` (startup spine), `src/ecs/` (entity-component-system),
`src/scene/` (scene documents), `src/assets/` (import pipeline + cache),
`src/render/` (draw-list extraction + CPU rasterization) and `src/audio/` (playback mixing):

```text
src/
├── main.zig              # Executable entry point (CLI -> startup pipeline)
├── corex.zig             # Public module; re-exports subsystems
├── core/
│   ├── version.zig       # Engine version + compatibility policy      [implemented]
│   ├── cli.zig           # Launch argument parsing (the Hub contract)  [implemented]
│   ├── manifest.zig      # .corex manifest parsing + validation        [implemented]
│   ├── paths.zig         # Safe relative-path validation + resolution  [implemented]
│   ├── validation.zig    # Shared display-name validation rules        [implemented]
│   ├── jobs.zig          # Job system / async loading foundation       [implemented]
│   ├── config.zig        # Project configuration loading               [implemented]
│   ├── assets.zig        # Asset indexing                              [implemented]
│   ├── splash.zig        # Splash screen contract + headless impl      [implemented]
│   ├── diagnostics.zig   # Timers + stage profiling                    [implemented]
│   └── startup.zig       # The 7-step startup pipeline                 [implemented]
├── ecs.zig               # ECS public module; re-exports entity/pool/world/schedule/graph/frame
├── ecs/
│   ├── entity.zig        # Generational entity handles + lifecycle     [implemented]
│   ├── pool.zig          # Sparse-set component storage                [implemented]
│   ├── world.zig         # Type-safe world + multi-component views     [implemented]
│   ├── schedule.zig      # Comptime stages + parallel system dispatch  [implemented]
│   ├── graph.zig         # AutoSchedule: inferred dependency layers    [implemented]
│   └── frame.zig         # FrameSchedule: budgets + system profiling   [implemented]
├── scene.zig             # Scene public module; EngineScene/Prefab/Stream schema
├── scene/
│   ├── components.zig    # Built-in plain-data scene components        [implemented]
│   ├── transform.zig     # Column-major Mat4 + quaternion math         [implemented]
│   ├── scene.zig         # Versioned scene document + ECS/hierarchy    [implemented]
│   ├── prefab.zig        # Single-root reusable subtrees (.prefab)     [implemented]
│   ├── stream.zig        # Sector residency streaming (.corexstream) [implemented]
│   └── render_scene.zig  # Renderable schema, assets, per-frame engine [implemented]
├── assets.zig            # Asset public module; index + cache + importers + pipeline
├── assets/
│   ├── cache.zig         # Content-addressed derived-data cache + GC   [implemented]
│   ├── importer.zig      # Importer framework + raw/text/json          [implemented]
│   ├── image.zig         # BMP/TGA/QOI decoders -> RGBA8               [implemented]
│   ├── inflate.zig       # DEFLATE/zlib inflate (PNG foundation)       [implemented]
│   ├── png.zig           # PNG decoder -> RGBA8 (all filters)          [implemented]
│   ├── texture.zig       # CXTX texture artifact + texture importers   [implemented]
│   ├── mesh.zig          # OBJ decoder + CXMH mesh artifact/importer   [implemented]
│   ├── audio.zig         # WAV decoder + CXAW audio artifact/importer  [implemented]
│   ├── flac.zig          # FLAC decoder, same Audio/CXAW artifact      [implemented]
│   ├── changes.zig       # Change detection + hot-reload baseline      [implemented]
│   └── pipeline.zig      # Parallel import orchestration + report      [implemented]
├── runtime.zig           # Runtime public module; presentation + frame loop
├── runtime/
│   └── presentation.zig  # Owned frame surface + bounded headless frame loop [implemented]
├── render.zig            # Render public module; extraction + CPU rasterizer
├── render/
│   ├── camera.zig        # View/projection math (right-handed)         [implemented]
│   ├── culling.zig       # Frustum + AABB/sphere classification        [implemented]
│   ├── draw.zig          # Renderable + draw-list extraction + sorting [implemented]
│   ├── backend.zig       # Renderer tier contract + CPU backend driver   [implemented]
│   ├── pipeline.zig      # Scene -> frame pipeline + handle tables       [implemented]
│   ├── mipmap.zig        # Mip-chain construction (integer box filter)   [implemented]
│   └── raster.zig        # Software rasterizer: coverage + depth buffer  [implemented]
├── audio.zig             # Audio public module; device-independent mixing
├── audio/
│   ├── clip.zig          # Clip descriptor, channel maps, pan, PCM16   [implemented]
│   ├── mixer.zig         # Voice pool, buses, allocation-free render   [implemented]
│   ├── spatial.zig       # Listener, attenuation, pan, Doppler math    [implemented]
│   ├── system.zig        # AudioSource component + scene reconciler    [implemented]
│   ├── resample.zig      # Windowed-sinc prototype + polyphase bank    [implemented]
│   └── effects.zig       # Biquads, comp, delay, reverb, limiter, sat    [impl]
├── gui.zig               # GUI public module; the engine's own widget layer
├── gui/
│   ├── font.zig          # Built-in 8x8 bitmap font + measurement      [implemented]
│   ├── text.zig          # Text drawing on a canvas (clip, scale)      [implemented]
│   ├── canvas.zig        # RGBA8 canvas, Rect, clipped primitives      [implemented]
│   ├── layout.zig        # Size/Padding + stacking Layout cursor        [implemented]
│   ├── input.zig         # One frame of pointer/keyboard/text input    [implemented]
│   ├── theme.zig         # Widget colours + metrics (dark and light)   [implemented]
│   └── widgets.zig       # Immediate-mode Context: panel/button/...    [implemented]
├── editor.zig            # Editor public module; the graphical editor
└── editor/
    ├── shell.zig         # Docks, hierarchy, viewport, inspector, status [implemented]
    ├── edit.zig          # Commands, undo/redo, dirty tracking, atomic save [implemented]
    ├── inspector.zig     # Editable numeric rows (fields, parsing, commit)  [implemented]
    └── tree.zig          # Flat rows, folding, tree actions, keyboard nav     [implemented]
```

Planned subsystems will be added as sibling modules (e.g. `src/script/`,
`src/export/`) once an approved change gives them meaningful content. Empty
placeholder modules are not created.

The GUI layer ([gui-foundation.md](gui-foundation.md)) is dependency-free and
headless: it paints into a caller-owned RGBA8 buffer in the same layout as
`assets.image.Image.pixels` and `raster.Target.color`, so a GUI composites onto a
rendered frame with no conversion. `zig build gui-frame -- out.qoi` renders one
frame of real widgets without a window.

The editor shell ([editor-shell.md](editor-shell.md)) composes one editor frame on top
of that GUI — docked hierarchy/viewport/inspector plus a status bar — over a session the
startup pipeline prepared, borrowing the scene, renderer and surface rather than owning
them. `zig build editor-frame -- <project> out.qoi` renders one real editor frame of a
project headlessly.

The editing model ([editor-shell.md](editor-shell.md#editing-model)) sits under the shell:
`corex.editor.edit` records each change as a plain `Command` value, snapshots the
entity's prior state before applying it, and undoes by restoring that snapshot — so a
deleted entity comes back with its **stable ID**, its parent and its components. Undo and
redo allocate nothing, a failed edit changes nothing, and `saveScene` stages the document
in a sibling file and renames it over the target, so an interrupted save cannot destroy a
project. A window and real input are still planned.

## The startup spine (implemented)

The engine opens a project through a fixed sequence (see
[launch-contract.md](launch-contract.md)):

1. **Services** — `jobs.JobSystem` (a `std.Io.Threaded` worker pool sized by
   `--jobs`) and `diagnostics.Profiler`.
2. **Splash** — `splash.SplashScreen` interface; `HeadlessSplash` logs progress
   until a graphical splash exists.
3. **Manifest + compatibility** — `manifest.parse` validates the `.corex`
   document; `version.check` enforces the compatibility policy.
4. **Configuration in workers** — `config.load` dispatched on the job system.
5. **Asset indexing** — `assets.indexDirectories` dispatched concurrently with
   configuration.
6. **Initial scene** — resolve the scene path (manifest or `--scene`), validate
   and load the versioned scene document into the ECS. When no scene is
   requested, an empty scene is prepared. Skipped in `validate` mode.
7. **Editor / runtime** — open the session. Headless: the editor shell renders
   frames into an owned surface, and nothing presents them yet. Skipped in
   `validate` mode.

Configuration and asset indexing run concurrently as jobs; both are awaited
before the pipeline proceeds. Errors map to stable exit codes.

## Subsystem map and status

### Engine Core — implemented (spine), evolving
Lifecycle, CLI, logging, configuration, versioning, diagnostics and the startup
pipeline are implemented. Memory policies beyond explicit allocators are still
to be formalized.

### Independent runtime — frame loop implemented, window planned
A standalone runtime that loads and runs an exported project without the
editor. The `runtime` launch mode prepares the session headless and now drives a
real bounded frame loop (`corex.runtime.presentation`, `--frames`); the window,
swapchain and player are planned.

### First-party graphical editor — shell and editing model implemented; window planned
The editor *shell* (`corex.editor.shell`, [editor-shell.md](editor-shell.md)) paints a
docked hierarchy, scene viewport, inspector and status bar over a prepared session,
borrowing the scene, renderer and surface instead of owning them. The *editing model*
(`corex.editor.edit`) adds reversible commands, an undo/redo stack, dirty tracking and an
atomic save, and the inspector edits the name, position and scale through it
(`corex.editor.inspector` owns the numeric fields and their parsing). `zig build
editor-frame` renders one real editor frame of a project headlessly. Still planned: a
window and real input, rotation/camera fields, drag-and-drop reparenting, asset browser,
gizmos and the editor loop.

### First-party GUI library — implemented; text shaping planned
The engine's own GUI toolkit (`corex.gui`, [gui-foundation.md](gui-foundation.md)):
built-in 8x8 bitmap font, RGBA8 canvas, text drawing, stacking layout and immediate-mode
widgets with a theme, painted into any caller-owned buffer in the engine's own pixel
layout. No third-party GUI dependency. Still planned: text shaping beyond ASCII, line
wrapping and automatic focus traversal.

### Renderer — extraction, CPU rasterization and the tier contract implemented; GPU backends planned
Three quality tiers:
- **Low:** minimal feature set, broad hardware reach.
- **Medium:** default tier; modern features with wide compatibility.
- **Advanced:** high-end features; only the *contract* is defined for now.

The project selects a tier via `settings.json` (`config.RendererTier`). **No GPU
backend is chosen yet**, but the tier **contract** and its **frame pipeline** now exist
(`src/render/backend.zig`, `docs/render-backend.md`): `Tier` (`low`/`medium`/
`advanced`), a single `capabilities(tier)` table, `FrameOptions`, a borrowed
`Surface` (RGBA8 + `f32` depth), a runtime `DrawResources` resolver adapted from
the comptime provider, and a `Backend` vtable (`beginFrame` → N × `draw` →
`endFrame`, plus `deinit`). `beginFrame` rejects any option a tier cannot honour
with `UnsupportedFeature` instead of degrading silently, and a texture binding on
a tier without textures is a rejected draw rather than a flat one. The CPU driver
`SoftwareBackend` implements the contract on top of the rasterizer, and a test
proves it is **byte-identical** to calling the rasterizer directly — so a GPU
backend replacing that value must reproduce exactly that behaviour.

The **runtime layer** (`src/runtime/`, re-exported as `corex.runtime`,
`docs/presentation.md`) owns the frame: `presentation.SurfaceTarget` holds the RGBA8
colour and `f32` depth buffers for a whole run and reallocates only when the size
changes, and `presentation.FrameLoop` drives `EngineRenderer` over `--frames` frames
with a per-frame scratch arena for camera lookup. Steady-state frames allocate nothing
(measured: 2 allocating frames out of 120), and repeated frames of an unchanged scene are
pixel-identical. `presentation.FrameLoop` is paced by `pacing.Pacer`, which holds the
loop to a target rate with a deadline anchored so overshoot does not accumulate and
counts frames it cannot keep up with instead of sleeping past them; a paced run reports
`Pacing: …` with real work/sleep/late measurements. It is sleep-based, not vsync — there
is no present to synchronise with yet. A window, swapchain, vsync and input remain the
next platform step.

Asset **upload** runs through the same scene renderer: each texture gets a mip chain
built with `render.mipmap` at upload time, the source bytes are released as soon as the
slot is filled, and `uploadedBytes()` reports the footprint the renderer holds. Eviction
(`LoadedAssets.evict`) releases a slot and its pixel blocks and bumps the slot's
generations, so a stored handle stops resolving instead of aliasing the next upload; it
is an explicit call, not a budget or an LRU. There is no GPU yet, so "upload" is a copy
into CPU scratch.

The **scene renderer** (`src/scene/render_scene.zig`) connects a project to that
pipeline, which was the missing half: the engine's own scene schema
(`EngineScene`) carried only `transform`, so a `.scene` file could not reference a
mesh and nothing owned a camera. `EngineRenderScene` adds `renderable` +
`camera`; `planSlots` gives every renderable asset a deterministic table slot (hash
start, linear probing, single namespace for meshes and textures), so a handle
stored in a scene file is reproducible from the project's content alone;
`loadAssets` loads `.mesh` artifacts, `.obj` sources and PNG/BMP/TGA/QOI textures
into the pipeline's `AssetTable`; `EngineRenderer` owns the reusable `RenderFrame`
and renders a frame with the scene's own camera, reporting commands, draws,
skipped handles, pixels and culling. The binary renders one headless frame at
startup and prints that accounting. See
[render-extraction.md](render-extraction.md) and
[render-backend.md](render-backend.md).

The **backend-independent extraction layer** is implemented (`src/render/`,
re-exported as `corex.render`, `docs/render-extraction.md`): right-handed camera
math (`perspective`/`orthographic`/`lookAt`, `Camera`), frustum culling
(Gribb–Hartmann plane extraction, conservative AABB/sphere classification), and
draw-list extraction (`extractDrawList`) that reuses the scene's O(n) world
transform snapshot, culls each `Renderable`'s world AABB, and emits a sorted
`DrawCommand` list (`front_to_back` / `back_to_front` / `by_material`). It is pure
CPU work with no GPU dependency, so it is fully tested headlessly and is the
contract the Low/Medium/Advanced GPU backends will consume.

A **CPU software rasterizer** (`src/render/raster.zig`,
`docs/render-raster.md`) consumes that draw list and writes an RGBA8 framebuffer
with an `f32` depth buffer: clip-space frustum clipping, perspective divide,
28.4 fixed-point integer edge functions with a top-left fill rule, backface
culling and flat or texture-mapped, optionally Lambert-lit, shading. Coverage
is bit-exactly reproducible and shared edges are watertight. Geometry and
materials arrive through a duck-typed provider, so `render` has no dependency
on the asset layer, and the pixel path takes no allocator (`antialias = .edge`
is the sole exception and only through the caller's allocator). It is a CPU
reference path, **not** a renderer tier: the GPU backends remain planned. Texture-mapped shading: perspective-correct
UVs, repeat wrap, nearest/bilinear sampling of borrowed RGBA8 textures, tint
multiply; `Mesh` carries optional `uvs` and the provider's optional `texture()`
(a `pub` decl, detected at comptime) binds the material — absent, the path
stays flat and byte-identical to before. Directional Lambert lighting:
per-face face-normal shading of the flat and textured paths (`Options.light`,
or an optional `pub fn directionalLight()` on the provider — explicit options
win), alpha never lit, bit-exact against Python reference vectors; callers
without a light stay byte-identical to before. Framebuffer **blending**
(`Options.blend`) composites each shaded fragment with the target as straight-alpha
source-over, premultiplied or additive (`.none` writes verbatim and is the
default, byte-identical to the pre-blending path); alpha composites in every mode,
depth is never blended, and the transparent modes pair with extraction's
`back_to_front` sort. Blended frames are pinned against their own Python
reference corpus. **Antialiasing** (`Options.antialias = .edge`) supersamples
geometry edges with a 4x4 integer sub-sample grid that applies the same top-left
rule to the sub-samples, so a shared edge is partitioned between its two triangles
and coverage still sums to a full pixel; coverage is accumulated per draw command
(never per fragment, which would seam) in caller-owned scratch sized from the
mesh's screen reach, and resolved once through straight-alpha source-over with the
coverage folded into the source alpha. Fully covered pixels take the
un-antialiased path and stay byte-identical; partial pixels never write depth.
Because it needs that scratch, antialiasing is only reachable through
`rasterizeAlloc` / `drawMeshAlloc`; the allocator-free entry points force
`antialias = .none`. **Minification** uses a mip chain (`Texture.mips`, built by
`render.mipmap.Chain` with an integer box filter) plus per-pixel level selection:
the level comes from the exact derivative of the perspective UV mapping, which is
six constants per triangle, and the two neighbouring levels are mixed in `f64`
with one final round (trilinear). A constant perspective denominator — any
orthographic projection — hoists the level to once per triangle, and with
`raster.Mipmap.anisotropic` an elongated footprint is sampled with up to eight
taps along its long axis at the level matching its short one (same fast path when
the footprint is constant). Extraction can additionally run a **tile-based
occlusion pass** (`render/occlusion.zig`, opt-in through `FrameParams.occlusion`):
large visible bounds claim the tiles their projected convex hull fully covers, and a
bound whose whole screen rectangle is claimed by strictly nearer geometry never
becomes a draw command. It is conservative by construction — with it enabled the
frame is byte-identical, only shorter — and it reuses one buffer, so a steady-state
frame still allocates nothing. `raster.Sampling` carries the two per-material knobs
(level bias and tap cap) as plain data: the bias is added after the level rule and
clamped to the chain, the cap only limits the tap count, `{}` reproduces every
pre-existing frame byte for byte, and `pipeline.resolve` zeroes both on a tier that
does not declare `sampling_controls` — quality loss, never a refused frame. Cross-layer
integration tests
(`src/render/raster_image_test.zig`) prove the whole chain — scene, world
transforms, extraction, rasterizer — with a world-rotated face lit
ambient-only and the explicit-options-over-provider priority intact.

### Audio runtime — mixing + spatialization implemented; device backends planned
The device-independent playback layer is implemented (`src/audio/`, re-exported
as `corex.audio`, `docs/audio-mixer.md`): a fixed-capacity voice pool with
generational handles, buses and master gain, stereo pan (linear or equal-power),
pitch, looping and resampling — linear by default, band-limited windowed-sinc on
request — mixed into an interleaved float32 buffer by an **allocation-free**
`render`. A full voice pool either fails (default) or recycles the
lowest-priority voice, with per-generation termination reasons. Opt-in insert
chains (`src/audio/effects.zig`, `docs/audio-effects.md`) add RBJ biquad filters,
a stereo-linked compressor, a feedback delay, a Freeverb-style reverb, a
lookahead brickwall limiter with optional true-peak detection and an oversampled
saturator per bus and on the master; only buses with an active chain are isolated into a
preallocated submix, so an all-bypass configuration stays bit-identical and
allocation-free. Delay-based effects borrow their memory from the caller (like
clips), so they add no mixer allocation, and the mixer rejects two slots claiming
the same instance or overlapping buffers. Channel mapping, clamping,
non-finite sanitizing and peak metering are explicit and documented; `toPcm16`
converts the mix for a device. It consumes `CXAW` artifacts without importing the
asset layer, so both stay independently testable. Pure CPU work with no device
dependency — the contract the OS backends (ALSA/WASAPI/CoreAudio) will consume.
The **spatial layer** is implemented too (`src/audio/spatial.zig`,
`src/audio/system.zig`, `docs/audio-spatial.md`): a listener basis derived from
world matrices, four distance-attenuation models, azimuth amplitude panning,
Doppler with supersonic clamping, a 2D/3D blend, and an `AudioSource` plain-data
scene component reconciled into mixer voices by `AudioSystem.update` (start,
refresh, clip-change restart, stop, silent-source culling, stale-entity sweep).
It mirrors the render extraction bridge and never writes to the scene, forwards
`AudioSource.priority` to the mixer's steal policy, and resumes a stolen source
from its last observed cursor without stealing on its behalf. A source reaches
the insert effects through its `bus`. The backends themselves,
HRTF/occlusion, modulated/convolved effects and streaming remain planned.

### ECS — implemented (storage + queries + scheduling + graph/frame budgets), planned (extensions)
A data-oriented ECS in `src/ecs/`, re-exported as `corex.ecs`:

- **`Entity`** — a generational handle (`index: u32`, `generation: u32`, packed
  into 64 bits). Destroying an entity bumps its slot's generation, so stale
  handles fail liveness checks even when the slot is recycled. Slots whose
  generation would reach the retired sentinel are never recycled, eliminating
  wraparound aliasing. This gives use-after-free safety at the ECS boundary
  without refcounting.
- **`Entities`** — lifecycle with free-list slot recycling, an occupancy bitset
  and O(1) `create` / `destroy` / `alive`. `destroy` is infallible (free-list
  capacity is reserved by `create`).
- **`Pool(T)`** — sparse-set component storage: O(1) `add` / `remove` / `get` /
  `has`, with tightly packed dense arrays for cache-friendly iteration. Removal
  is swap-remove, so dense order is not stable across removals.
- **`World(components)`** — comptime-parameterized by a tuple of component types;
  owns one `Pool` per type and the entity lifecycle. Type-safe `add` / `remove` /
  `get` / `has` reject dead handles (a stale handle can never reach a recycled
  entity's components). `destroy` removes the entity's components from every
  pool. `view(.{ A, B, ... })` iterates entities having all listed components and
  yields `{ Entity, *A, *B, ... }` for system-style passes.

- **`schedule`** — comptime schedules of systems grouped into ordered stages.
  Systems declare read/write component access; the scheduler rejects conflicting
  systems in the same stage at comptime and dispatches non-conflicting systems
  concurrently through `std.Io` (e.g. `JobSystem.io()`). Exclusive systems occupy
  a stage alone. `runSequential` provides a no-Io fallback. Optional observer
  hooks (`runObserved`/`runSequentialObserved`) support profiling without changing
  the plain run contracts. See [ecs-scheduling.md](ecs-scheduling.md).
- **`graph.AutoSchedule`** — infers a deterministic comptime dependency graph
  from read/write/exclusive access: conflicting systems get declaration-order
  edges, non-conflicting systems share parallel layers, exclusive systems become
  barriers. Layer assignment is a comptime longest-path pass; runtime dispatch
  reuses the shared `runLayer` helper with no graph allocation.
- **`frame.FrameSchedule`** — wraps an `AutoSchedule` and adds allocation-free
  per-system profiling (`FrameProfiler`: runs/errors/monotonic timings) and
  cooperative frame budgets (`runBudgeted` + `FrameCursor`), stopping between
  systems and resuming across calls. Budgeted execution is sequential and never
  preempts a running system.

Storage, queries, scheduling, automatic dependency graphs, frame budgets and
system profiling are implemented and tested (including under `ReleaseSafe` and
`ReleaseFast`). Change detection and relation/graph components remain planned
extensions. The world depends only on `entity.zig` and `pool.zig`; the scheduler
depends only on the world and `std.Io`; `frame.zig` additionally reuses the
diagnostics `Timer` (low coupling). Scenes and scripting build on these layers.

### Scene system — implemented (format v1 + ECS load/save + prefabs + sector streaming)
Scenes are versioned JSON documents (`docs/scene-format.md`) backed by the ECS.
`scene.Scene(schema)` owns a typed ECS world, stable monotonic entity IDs and a
parent hierarchy. It supports strict parse/serialize, file load/save,
create/destroy with child reparenting, cycle-safe `setParent`, and plain-data
component schemas (`Component(T, "name")`). The default `EngineScene` schema
currently contains `Transform`; the startup pipeline loads the initial scene in
`editor`/`runtime` and prepares an empty scene when none is requested.

Implemented guarantees: unknown/duplicate JSON fields rejected, duplicate/zero
entity IDs rejected, missing parents/self-parenting/cycles rejected, non-finite
transform values rejected, stale generational handles cannot reach recycled
entities, and allocation-failure paths are tested.

World-space transform propagation is implemented (`src/scene/transform.zig`,
`docs/scene-transforms.md`): `Scene.computeWorldTransforms` builds a deterministic
snapshot in one O(n) iterative pass (parents before children, no recursion, safe
for arbitrarily deep hierarchies), and `Scene.worldMatrix` computes a single
entity by walking its parent chain. Matrices are column-major `Mat4` (`M = T*R*S`,
`world_child = world_parent * local_child`); entities without a `Transform` use
the identity local transform. Snapshots are generation-safe (a recycled slot's
new handle cannot read the previous entity's matrix). The `.scene` format is
unchanged — only local TRS values are serialized.

**Prefabs** are implemented (`src/scene/prefab.zig`, `docs/scene-prefabs.md`):
a `.prefab` is a strict single-root scene document; `Prefab(schemas)` supports
parse/load/save, capture from a live scene subtree (`fromScene`), and
instantiation into any same-schema scene (`instantiate`). `Scene.cloneSubtree`
clones entities/components by value, remaps stable IDs and parent links
deterministically (ascending source-ID order), and rolls back created entities
on error. Prefabs are classified as `AssetKind.prefab` and imported/cached by the
engine registry (`prefab` importer v1). **Sector streaming**
(`src/scene/stream.zig`, `docs/scene-streaming.md`, `stream` importer v1) loads and
unloads named `.scene` sectors into a live scene by proximity or explicit request,
with hysteresis, per-call budgets and exact, allocation-free unload. Change tracking and
multi-scene management remain planned extensions.

### Asset system — implemented (indexing + import/cache + decoders + change detection), planned (more decoders)
`core.assets.indexDirectories` builds a kind/size index at startup (unchanged).
The asset subsystem (`corex.assets`, `src/assets/`) adds a content-addressed
import cache, an importer framework (raw/text/json + a scene importer that reuses
the scene system), a parallel import pipeline over `std.Io`, dependency-free
**texture decoders** (PNG/BMP/TGA/QOI) that normalize to RGBA8 and serialize a
self-describing `CXTX` artifact (`src/assets/image.zig`, `src/assets/png.zig`,
`src/assets/texture.zig`), backed by a dependency-free **DEFLATE/zlib inflater**
(`src/assets/inflate.zig`), and an **OBJ mesh importer** that decodes the geometry
subset to an indexed triangle mesh and serializes a `CXMH` artifact
(`src/assets/mesh.zig`), and a **WAV audio importer** that decodes the
uncompressed RIFF/WAVE subset (PCM 8/16/24/32-bit, IEEE float32, extensible) to
interleaved float32 and serializes a `CXAW` artifact (`src/assets/audio.zig`), and
a **FLAC importer** that decodes the lossless baseline format into the same
`Audio`/`CXAW` artifact (`src/assets/flac.zig`, importing `audio.zig` one way only
so the registry composes both binding lists without an import cycle).
A mark-and-sweep **cache GC** (`Cache.gc` + `Report.liveKeys`) reclaims orphan
entries. **Change detection** (`src/assets/changes.zig`) compares a path-sorted
snapshot against the current index using a size/mtime fingerprint confirmed by
BLAKE3, reports added/modified/removed, and derives the complete live key set for
GC; `pipeline.Options.only` then re-imports just what changed.
Progressive-JPEG/compressed-audio/font and other model-format (glTF/FBX/DAE) decoders, an OS
audio device backend, dependency tracking, temp-file cleanup and hot-reload are
planned extensions. See [asset-import.md](asset-import.md),
[asset-decoders.md](asset-decoders.md), [mesh-import.md](mesh-import.md) and
[asset-audio.md](asset-audio.md).

### Import and cache — implemented
`assets.pipeline` imports an indexed asset set into derived artifacts stored in a
content-addressed cache keyed by source content hash + importer identity/version
+ options. Cache writes are atomic (temp + rename) and reads verify the payload
hash (corrupt entries self-heal as misses). Imports run concurrently through an
`Io.Group` (e.g. `JobSystem.io()`), with a `runSequential` fallback; per-asset
failures are recorded in a report without aborting the batch. Binary assets use
the `raw` (verbatim) importer until decoders exist. `Options.only` restricts a run
to a path set for incremental/hot-reload imports. Startup/editor integration is
a planned next step. See [asset-import.md](asset-import.md).

### Serialization — implemented (scenes + import cache), planned (export)
Scene (de)serialization is versioned (`format_version = 1`), strict and
deterministic (entities sorted by stable ID, optional null fields omitted). It
uses the standard-library JSON parser/stringifier with duplicate-field and
unknown-field rejection, and enforces plain-data components at comptime so ECS
copies cannot dangle. The import cache uses its own versioned on-disk format
(binary header + JSON metadata + payload, `format_version = 1`) with hash
verification. Export-template serialization is planned, aligned with the
format-version policy in [versioning.md](versioning.md).

### Lua VM / gameplay scripting — planned
An embedded Lua VM and a gameplay scripting API. The example project ships a
placeholder `scripts/main.lua`. The VM choice (Lua version, allocator, sandbox)
will be documented before integration.

### Native Module API for C++ — contract defined
A stable C ABI lets C++ modules extend the engine without coupling to Zig
internals. The contract (entry points, versioning, lifetime) will be published
as a C header under `include/corex/` before any module loads. See
[native-module-api.md](native-module-api.md).

### Job system and asynchronous loading — implemented (foundation)
`jobs.JobSystem` wraps `std.Io` concurrency with a configurable worker pool,
`spawn` (future-based) and `Batch` (group-based). Used by the startup pipeline,
by ECS system scheduling (`Schedule.run(js.io(), ...)`) and by the asset import
pipeline (`assets.pipeline.run(gpa, js.io(), ...)`). Priorities, dependencies and
a frame-budget scheduler are planned.

### Splash screen — implemented (contract + headless), planned (graphical)
`splash.SplashScreen` is the interface; `HeadlessSplash` is the current
implementation. A graphical splash will implement the same interface on the GUI
library.

### Engine versioning system — implemented
`version.zig` exposes the engine version and the project compatibility policy.
The engine never installs or selects versions (that is the Hub's role).

### Export system / Export Templates — planned (engine side)
The engine defines the export pipeline, the packaged runtime format and the
Export Template *format/consumption*. Acquisition, installation and management
of templates belong to the Hub. See [scope.md](scope.md).

### Diagnostics and profiling tools — implemented (foundation + ECS frame profiling)
`diagnostics.Timer` and `diagnostics.Profiler` measure startup stages. ECS
system/frame profiling is implemented via `frame.FrameSchedule`/`FrameProfiler`
(allocation-free per-system runs/errors/timings). Engine-wide memory tracking, a
metrics overlay and trace export are planned.

## API guidelines

- Pass allocators explicitly to operations that may allocate.
- Avoid mutable global state; when unavoidable, document its lifecycle and
  synchronization. The executable's runtime log level is the one documented
  exception (set once at startup before workers run).
- Define error behavior and data ownership in public APIs.
- Add tests for rules, invariants, and error cases.
- Keep the public surface concentrated in `src/corex.zig`.

## Current status

The startup spine, the ECS (generational entities, sparse-set component pools,
type-safe world, multi-component views, comptime system scheduling over the job
system, automatic dependency graphs, cooperative frame budgets and system
profiling), the scene system (versioned JSON scenes, stable IDs, hierarchy, ECS
load/save, world-space transforms, reusable single-root prefabs), the asset import pipeline + content-addressed
cache (raw/text/json/scene importers, PNG/BMP/TGA/QOI texture decoders over a
dependency-free DEFLATE/zlib inflater, OBJ mesh
importer, WAV and FLAC audio importers, atomic verified storage, parallel import
over the job system,
mark-and-sweep GC, change detection with incremental re-import), the
backend-independent render extraction layer (camera,
frustum culling, sorted draw lists) with its CPU software rasterizer (watertight
fixed-point coverage, depth buffer, textured shading, directional Lambert
lighting and straight-alpha/premultiplied/additive blending), and the
device-independent audio runtime
(mixer with voices/buses/pan/pitch, linear and band-limited resampling, priority
voice stealing, biquad/compressor/delay/reverb/limiter/saturator insert chains,
plus spatialization
and the `AudioSource` scene bridge) are implemented and tested, and the executable
builds
and runs on Zig 0.17.0. The remaining larger subsystems (GPU renderer
backends, GUI, editor, Lua, export, native modules) are in scope and either
contract-defined or planned, as marked above.
