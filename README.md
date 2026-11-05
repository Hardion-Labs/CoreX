# CoreXEngine

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
> sparse-set component pools, type-safe world and multi-component views) and the
> scene system (versioned JSON scenes, stable entity IDs, hierarchy, ECS
> load/save) are implemented and tested. The larger subsystems (renderers, GUI,
> editor, Lua, export, native modules) are in scope and either contract-defined
> or planned. See [`docs/architecture.md`](docs/architecture.md) for the
> per-subsystem status.

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

## Project Structure

```text
CoreX/
├── assets/branding/            # Logo and branding
├── docs/
│   ├── scope.md                # Definitive project scope (Engine vs Hub)
│   ├── architecture.md         # Subsystem map and implementation status
│   ├── launch-contract.md      # Stable startup contract (CLI, exit codes)
│   ├── project-format.md       # .corex manifest format
│   ├── scene-format.md         # Versioned .scene format
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
│   ├── ecs/                    # Entities, component pools, world + views
│   ├── scene.zig               # Scene public module (EngineScene)
│   └── scene/                  # Scene components + versioned documents
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
- [ ] ECS system scheduling over the job system.
- [x] Scene system and versioned scene serialization (format v1, ECS load/save).
- [ ] Scene extensions: prefabs, streaming, world-space transforms.
- [ ] Asset import pipeline and cache.
- [ ] Renderer Low / Medium; Advanced contract.
- [ ] GUI library and graphical editor.
- [ ] Lua VM and gameplay scripting.
- [ ] Native Module API loader (C++).
- [ ] Runtime player and export system / Export Templates.
- [ ] CI pipeline.

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
