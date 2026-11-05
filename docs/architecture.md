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
`src/scene/` (scene documents) and `src/assets/` (import pipeline + cache):

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
├── scene.zig             # Scene public module; EngineScene/EnginePrefab schema
├── scene/
│   ├── components.zig    # Built-in plain-data scene components        [implemented]
│   ├── transform.zig     # Column-major Mat4 + quaternion math         [implemented]
│   ├── scene.zig         # Versioned scene document + ECS/hierarchy    [implemented]
│   └── prefab.zig        # Single-root reusable subtrees (.prefab)     [implemented]
├── assets.zig            # Asset public module; index + cache + importers + pipeline
├── assets/
│   ├── cache.zig         # Content-addressed derived-data cache + GC   [implemented]
│   ├── importer.zig      # Importer framework + raw/text/json          [implemented]
│   ├── image.zig         # BMP/TGA/QOI decoders -> RGBA8               [implemented]
│   ├── texture.zig       # CXTX texture artifact + texture importers   [implemented]
│   ├── mesh.zig          # OBJ decoder + CXMH mesh artifact/importer   [implemented]
│   └── pipeline.zig      # Parallel import orchestration + report      [implemented]
├── render.zig            # Render public module; backend-independent extraction
└── render/
    ├── camera.zig        # View/projection math (right-handed)         [implemented]
    ├── culling.zig       # Frustum + AABB/sphere classification        [implemented]
    └── draw.zig          # Renderable + draw-list extraction + sorting [implemented]
```

Planned subsystems will be added as sibling modules (e.g. `src/render/`,
`src/gui/`, `src/editor/`, `src/script/`, `src/export/`) once an approved change
gives them meaningful content. Empty placeholder modules are not created.

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
7. **Editor / runtime** — open the session. Headless until the GUI/editor exist.
   Skipped in `validate` mode.

Configuration and asset indexing run concurrently as jobs; both are awaited
before the pipeline proceeds. Errors map to stable exit codes.

## Subsystem map and status

### Engine Core — implemented (spine), evolving
Lifecycle, CLI, logging, configuration, versioning, diagnostics and the startup
pipeline are implemented. Memory policies beyond explicit allocators are still
to be formalized.

### Runtime independente — planned
A standalone runtime that loads and runs an exported project without the
editor. The `runtime` launch mode currently prepares the session headless; the
loop, subsystems and player are planned.

### Editor gráfico próprio — planned
The graphical editor. The startup pipeline already opens an editor *session*
(headless). Panels, inspectors, scene view, asset browser and the editor loop
are planned on top of the GUI library.

### Biblioteca GUI própria — planned
The engine's own GUI toolkit (widgets, layout, input, rendering integration) used
by the editor and the graphical splash. No third-party GUI dependency is planned.

### Renderer — extraction implemented; Low / Medium GPU backends planned
Three quality tiers:
- **Low:** minimal feature set, broad hardware reach.
- **Medium:** default tier; modern features with wide compatibility.
- **Advanced:** high-end features; only the *contract* is defined for now.

The project selects a tier via `settings.json` (`config.RendererTier`). No GPU
backend is chosen yet.

The **backend-independent extraction layer** is implemented (`src/render/`,
re-exported as `corex.render`, `docs/render-extraction.md`): right-handed camera
math (`perspective`/`orthographic`/`lookAt`, `Camera`), frustum culling
(Gribb–Hartmann plane extraction, conservative AABB/sphere classification), and
draw-list extraction (`extractDrawList`) that reuses the scene's O(n) world
transform snapshot, culls each `Renderable`'s world AABB, and emits a sorted
`DrawCommand` list (`front_to_back` / `back_to_front` / `by_material`). It is pure
CPU work with no GPU dependency, so it is fully tested headlessly and is the
contract the Low/Medium/Advanced GPU backends will consume. The GPU backends
themselves remain planned.

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

### Sistema de cenas — implemented (format v1 + ECS load/save + prefabs), planned (streaming)
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
engine registry (`prefab` importer v1). Scene streaming, change tracking and
multi-scene management remain planned extensions.

### Sistema de assets — implemented (indexing + import/cache + texture/mesh decoders), planned (more decoders)
`core.assets.indexDirectories` builds a kind/size index at startup (unchanged).
The asset subsystem (`corex.assets`, `src/assets/`) adds a content-addressed
import cache, an importer framework (raw/text/json + a scene importer that reuses
the scene system), a parallel import pipeline over `std.Io`, dependency-free
**texture decoders** (BMP/TGA/QOI) that normalize to RGBA8 and serialize a
self-describing `CXTX` artifact (`src/assets/image.zig`, `src/assets/texture.zig`),
and an **OBJ mesh importer** that decodes the geometry subset to an indexed
triangle mesh and serializes a `CXMH` artifact (`src/assets/mesh.zig`).
A mark-and-sweep **cache GC** (`Cache.gc` + `Report.liveKeys`) reclaims orphan
entries. PNG/JPEG/audio/font and other model-format (glTF/FBX/DAE) decoders,
dependency tracking, temp-file cleanup and hot-reload are planned extensions. See
[asset-import.md](asset-import.md), [asset-decoders.md](asset-decoders.md) and
[mesh-import.md](mesh-import.md).

### Importação e cache — implemented
`assets.pipeline` imports an indexed asset set into derived artifacts stored in a
content-addressed cache keyed by source content hash + importer identity/version
+ options. Cache writes are atomic (temp + rename) and reads verify the payload
hash (corrupt entries self-heal as misses). Imports run concurrently through an
`Io.Group` (e.g. `JobSystem.io()`), with a `runSequential` fallback; per-asset
failures are recorded in a report without aborting the batch. Binary assets use
the `raw` (verbatim) importer until decoders exist. Startup/editor integration is
a planned next step. See [asset-import.md](asset-import.md).

### Serialização — implemented (scenes + import cache), planned (export)
Scene (de)serialization is versioned (`format_version = 1`), strict and
deterministic (entities sorted by stable ID, optional null fields omitted). It
uses the standard-library JSON parser/stringifier with duplicate-field and
unknown-field rejection, and enforces plain-data components at comptime so ECS
copies cannot dangle. The import cache uses its own versioned on-disk format
(binary header + JSON metadata + payload, `format_version = 1`) with hash
verification. Export-template serialization is planned, aligned with the
format-version policy in [versioning.md](versioning.md).

### VM Lua / Gameplay scripting — planned
An embedded Lua VM and a gameplay scripting API. The example project ships a
placeholder `scripts/main.lua`. The VM choice (Lua version, allocator, sandbox)
will be documented before integration.

### Native Module API para C++ — contract defined
A stable C ABI lets C++ modules extend the engine without coupling to Zig
internals. The contract (entry points, versioning, lifetime) will be published
as a C header under `include/corex/` before any module loads. See
[native-module-api.md](native-module-api.md).

### Sistema de jobs e carregamento assíncrono — implemented (foundation)
`jobs.JobSystem` wraps `std.Io` concurrency with a configurable worker pool,
`spawn` (future-based) and `Batch` (group-based). Used by the startup pipeline,
by ECS system scheduling (`Schedule.run(js.io(), ...)`) and by the asset import
pipeline (`assets.pipeline.run(gpa, js.io(), ...)`). Priorities, dependencies and
a frame-budget scheduler are planned.

### Splash screen — implemented (contract + headless), planned (graphical)
`splash.SplashScreen` is the interface; `HeadlessSplash` is the current
implementation. A graphical splash will implement the same interface on the GUI
library.

### Sistema de versionamento da engine — implemented
`version.zig` exposes the engine version and the project compatibility policy.
The engine never installs or selects versions (that is the Hub's role).

### Sistema de exportação / Export Templates — planned (engine side)
The engine defines the export pipeline, the packaged runtime format and the
Export Template *format/consumption*. Acquisition, installation and management
of templates belong to the Hub. See [scope.md](scope.md).

### Ferramentas de diagnóstico e profiling — implemented (foundation + ECS frame profiling)
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
cache (raw/text/json/scene importers, BMP/TGA/QOI texture decoders, OBJ mesh
importer, atomic verified storage, parallel import over the job system,
mark-and-sweep GC) and the backend-independent render extraction layer (camera,
frustum culling, sorted draw lists) are implemented and tested, and the executable
builds and runs on Zig 0.17.0. The remaining larger subsystems (GPU renderer
backends, GUI, editor, Lua, export, native modules) are in scope and either
contract-defined or planned, as marked above.
