# HelloProject

A minimal example project for the CoreXEngine. It exists to demonstrate the
[launch contract](../../docs/launch-contract.md), the
[`.corex` project format](../../docs/project-format.md) and the
[`.scene` format](../../docs/scene-format.md). The engine does not create
projects; this example was authored by hand.

## Layout

```text
hello-project/
├── HelloProject.corex     # Project entry point (manifest)
├── settings.json          # Optional project configuration
├── scenes/
│   └── main.scene         # Initial scene: a renderable quad + a camera
├── scripts/
│   └── main.lua           # Gameplay script (Lua VM is planned)
└── assets/
    ├── quad.obj           # A quad in plain text (decoded by the engine)
    └── README.md          # Asset directory (indexed at startup)
```

The scene draws `assets/quad.obj` (a text OBJ — no binary artifact needed) seen by
a camera entity, so the frame loop renders real geometry:

```text
Frames: 120 of 120 (2 allocating) at 1280x720 medium — last frame: 1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled
```

Only the two warm-up frames allocate; every frame after them reuses the surface, the
draw list and the per-frame arenas.

The `renderable.mesh`/`material` handles in `main.scene` come from the project's
deterministic asset layout (`render_scene.planSlots(...).handleOf("assets/quad.obj")`
at the table capacity the engine uses). Adding an asset changes the layout, so
recompute the handles when you add meshes; [scene-format.md](../../docs/scene-format.md)
documents the rule and the components.

## Run it

From the repository root, after `zig build`:

```sh
# Validate the project (no editor):
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --mode validate

# Open the editor (headless until the GUI exists):
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex

# Simulate a CoreXHub launch:
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --hub-launch --engine-version 0.1.0

# Run 120 frames headless (default is one frame):
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --headless --frames 120

# Run the runtime headless with 4 workers:
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --mode runtime --headless --jobs 4
```
