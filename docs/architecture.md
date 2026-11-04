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
under `src/core/`:

```text
src/
├── main.zig              # Executable entry point (CLI -> startup pipeline)
├── corex.zig             # Public module; re-exports subsystems
└── core/
    ├── version.zig       # Engine version + compatibility policy      [implemented]
    ├── cli.zig           # Launch argument parsing (the Hub contract)  [implemented]
    ├── manifest.zig      # .corex manifest parsing + validation        [implemented]
    ├── paths.zig         # Safe relative-path validation + resolution  [implemented]
    ├── jobs.zig          # Job system / async loading foundation       [implemented]
    ├── config.zig        # Project configuration loading               [implemented]
    ├── assets.zig        # Asset indexing                              [implemented]
    ├── splash.zig        # Splash screen contract + headless impl      [implemented]
    ├── diagnostics.zig   # Timers + stage profiling                    [implemented]
    └── startup.zig       # The 7-step startup pipeline                 [implemented]
```

Planned subsystems will be added as sibling modules (e.g. `src/ecs/`,
`src/scene/`, `src/render/`, `src/gui/`, `src/editor/`, `src/script/`,
`src/export/`) once an approved change gives them meaningful content. Empty
placeholder modules are not created.

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
6. **Initial scene** — resolve and verify the scene path (manifest or
   `--scene`). Skipped in `validate` mode.
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

### Renderer Low / Medium — planned; Advanced — contract defined
Three quality tiers:
- **Low:** minimal feature set, broad hardware reach.
- **Medium:** default tier; modern features with wide compatibility.
- **Advanced:** high-end features; only the *contract* is defined for now.

The project selects a tier via `settings.json` (`config.RendererTier`). The
backend-independent render API, the Low/Medium implementations and the Advanced
contract will be specified before implementation. No GPU backend is chosen yet.

### ECS — planned
Entities, components and systems with a data-oriented API. Will live in
`src/ecs/` with storage, queries and scheduling designed around the job system.

### Sistema de cenas — contract defined (entry), planned (full)
A scene is referenced by the manifest (`initial_scene`) and resolved at startup.
The full scene format, entity/component serialization, prefab and scene graph
are planned. The example project ships a minimal `scenes/main.scene`.

### Sistema de assets — implemented (indexing), planned (import/cache)
`assets.indexDirectories` builds a kind/size index at startup. Importing,
content-addressed caching, dependency tracking and hot-reload are planned
extensions.

### Importação e cache — planned
Asset import pipeline and a derived-data cache keyed by source content +
importer version. Will integrate with the asset system and the job system.

### Serialização — planned
Versioned (de)serialization for scenes, assets and project data, aligned with
the format-version policy in [versioning.md](versioning.md).

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
`spawn` (future-based) and `Batch` (group-based). Used by the startup pipeline.
Priorities, dependencies and a frame-budget scheduler are planned.

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

### Ferramentas de diagnóstico e profiling — implemented (foundation)
`diagnostics.Timer` and `diagnostics.Profiler` measure startup stages. Frame
profiling, memory tracking, a metrics overlay and trace export are planned.

## API guidelines

- Pass allocators explicitly to operations that may allocate.
- Avoid mutable global state; when unavoidable, document its lifecycle and
  synchronization. The executable's runtime log level is the one documented
  exception (set once at startup before workers run).
- Define error behavior and data ownership in public APIs.
- Add tests for rules, invariants, and error cases.
- Keep the public surface concentrated in `src/corex.zig`.

## Current status

The startup spine is implemented and tested (CLI, manifest, compatibility,
jobs, configuration, asset indexing, splash contract, diagnostics, and the
7-step pipeline), and the executable builds and runs on Zig 0.17.0. The larger
subsystems (ECS, scenes, renderers, GUI, editor, Lua, export, native modules)
are in scope and either contract-defined or planned, as marked above.
