# CoreXEngine — Definitive Scope

This document records the definitive scope of the project maintained in this
repository. It is the boundary reference between **CoreXEngine** and **CoreXHub**.

## Project identity

The project in this repository is exclusively **CoreXEngine**: a modular game
engine written in Zig 0.17.0, with an independent runtime, its own graphical
editor and content-production tools.

**CoreXHub** is an independent product, maintained in a separate repository.
Nothing from CoreXHub is implemented, embedded or duplicated here.

## Out of scope — CoreXHub

The responsibilities below belong to CoreXHub and must **not** be implemented in
CoreXEngine:

- Creating projects.
- Registering projects.
- Managing recent projects.
- Installing engine versions.
- Selecting engine versions.
- Managing installations.
- Managing Export Templates (installation/acquisition).
- Launching CoreXEngine with the selected project (the Hub is the launcher; the
  engine only accepts being launched).

## In scope — CoreXEngine

CoreXEngine implements:

- Engine Core in Zig 0.17.0.
- Independent runtime.
- Its own graphical editor.
- Its own GUI library.
- Renderer Low.
- Renderer Medium.
- Contracts for Renderer Advanced.
- ECS.
- Scene system.
- Asset system.
- Import and cache.
- Serialization.
- Lua VM.
- Gameplay scripting.
- Native Module API for C++.
- Job system and asynchronous loading.
- Splash screen.
- Engine versioning system.
- Export system.
- Export Templates (format/packaging consumed by the engine).
- Diagnostics and profiling tools.

> Note on Export Templates: **acquisition, installation and management** of
> templates belong to the Hub. The engine defines the **format**, the
> **packaging** and the **consumption** of templates during export.

## Integration with CoreXHub

Integration happens exclusively through:

1. Documented launch arguments.
2. Documented file formats (`.corex`, scenes, assets, templates).
3. Stable contracts (CLI, manifest, exit codes, version).

The engine exposes a launch interface documented in
[launch-contract.md](launch-contract.md). The Hub may launch the engine passing:

- The absolute project path (the `.corex` file).
- The selected engine version (informational; the engine does not install/select
  versions).
- Additional documented arguments.

Example:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --hub-launch
```

The editor also accepts direct command-line launch, without the Hub.
**The engine never depends on the Hub to run.**

## Architectural rules

- Do not create an internal Project Manager.
- Do not create a project catalog.
- Do not implement project creation in the engine.
- Do not install or select versions silently.
- Do not couple the engine to CoreXHub.

The `.corex` file is the project entry point. On receiving a project, the engine
runs the startup sequence defined in [launch-contract.md](launch-contract.md):

1. Initialize essential services.
2. Open the splash screen.
3. Validate the manifest and compatibility.
4. Load configuration in workers.
5. Index assets.
6. Prepare the initial scene.
7. Open the graphical editor.

## Implementation status

This document defines the target scope. The actual status of each subsystem is
recorded in [architecture.md](architecture.md) and in the
[CHANGELOG](../CHANGELOG.md). Features that are not implemented yet are marked as
planned and must not be described as existing.
