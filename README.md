
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
> atomic verified storage, parallel import over
> the job system, mark-and-sweep GC), and the backend-independent render extraction
> layer (camera math, frustum culling, sorted draw lists) are implemented and tested. The larger
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
```

These commands are validated with Zig 0.17.0. The graphical editor, GUI and
renderers are not implemented yet, so editor/runtime sessions currently open
headless and report readiness.

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
guarantees and limitations. Scene streaming remains planned.

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
BMP, TGA and QOI** are decoded to RGBA8 and stored as a self-describing `CXTX`
artifact, and **OBJ** meshes are decoded to indexed triangle meshes stored as a
`CXMH` artifact; other binary formats (JPEG/audio, glTF/FBX) still import as
`raw` until decoders exist.

PNG support covers every non-interlaced color type and bit depth (1/2/4/8/16),
all five row filters, palette and color-key transparency, and multi-chunk IDAT,
with chunk CRC-32 and zlib Adler-32 verification. It is backed by a
dependency-free DEFLATE/zlib inflater (`corex.assets.inflate`) whose output is
bounded by the caller, so a decompression bomb cannot exceed the size declared by
the image header. 16-bit samples are reduced to their high byte (the artifact is
RGBA8) and Adam7-interlaced files are rejected rather than approximated.

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

`pipeline.run` imports concurrently over the job system; `runSequential` is a
single-threaded fallback. The cache format, importer contract and limits are
documented in [`docs/asset-import.md`](docs/asset-import.md); the texture
decoders and `CXTX` artifact are documented in
[`docs/asset-decoders.md`](docs/asset-decoders.md); the OBJ mesh importer and
`CXMH` artifact are documented in [`docs/mesh-import.md`](docs/mesh-import.md).

## Render

The render subsystem (`corex.render`) currently provides the **backend-independent
extraction layer** — the CPU foundation every GPU tier will consume. It builds
camera view/projection matrices, frustum-culls renderables, and produces a sorted
draw list from a scene. It has no GPU dependency, so it runs and is fully tested
headlessly. The Low/Medium GPU backends are planned.

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
```

The design, math conventions and guarantees are documented in
[`docs/render-extraction.md`](docs/render-extraction.md).

## Project Structure

```text
CoreX/
├── assets/branding/            # Logo and branding
├── docs/
│   ├── scope.md                # Definitive project scope (Engine vs Hub)
│   ├── architecture.md         # Subsystem map and implementation status
│   ├── ecs-scheduling.md       # ECS system scheduling guide
│   ├── asset-import.md         # Asset import pipeline + cache
│   ├── asset-decoders.md       # Image decoders (PNG/BMP/TGA/QOI) + CXTX artifact
│   ├── mesh-import.md          # OBJ mesh importer + CXMH artifact
│   ├── launch-contract.md      # Stable startup contract (CLI, exit codes)
│   ├── project-format.md       # .corex manifest format
│   ├── scene-format.md         # Versioned .scene format
│   ├── scene-transforms.md     # World-space transform propagation
│   ├── scene-prefabs.md        # Reusable single-root prefabs (.prefab)
│   ├── render-extraction.md    # Backend-independent render extraction
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
│   ├── assets/                 # Import cache, importers, decoders (PNG/inflate), pipeline
│   ├── render.zig              # Render public module (extraction layer)
│   └── render/                 # Camera, frustum culling, draw-list extraction
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
- [ ] Scene streaming.
- [x] Asset import pipeline and content-addressed cache (raw/text/json/scene).
- [x] Texture decoders (PNG/BMP/TGA/QOI → RGBA8 `CXTX` artifact).
- [x] DEFLATE/zlib inflate (dependency-free, bounded output).
- [x] Asset cache garbage collection (mark-and-sweep of orphan entries).
- [x] Mesh decoder (OBJ → indexed triangle mesh, `CXMH` artifact).
- [ ] Asset decoders (JPEG/audio, other model formats), Adam7 PNG, hot-reload, startup integration.
- [x] Backend-independent render extraction (camera, frustum culling, sorted draw lists).
- [ ] Renderer Low / Medium GPU backends; Advanced contract.
- [ ] GUI library and graphical editor.
- [ ] Lua VM and gameplay scripting.
- [ ] Native Module API loader (C++).
- [ ] Runtime player and export system / Export Templates.
- [x] CI pipeline (build + test + launch-contract smoke on Zig 0.17.0).

## Development

Before contributing, read [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`docs/architecture.md`](docs/architecture.md),
[`docs/development/coding-standards.md`](docs/development/coding-standards.md),
and [`docs/policies/AI_POLICY.md`](docs/policies/AI_POLICY.md). Keep code in Zig,
minimize dependencies, and include tests for new or changed behavior.

Local checks:

```sh
zig build
zig build test
zig fmt --check src/ build.zig
```

## Contributions

Issues and pull requests are welcome. For substantial changes, open an issue
first to discuss the goal, scope, and architectural impact. Also see the
[support](SUPPORT.md) and [security](SECURITY.md) guidelines.

## License

CoreXEngine is distributed under the MIT License. See [`LICENSE`](LICENSE).
