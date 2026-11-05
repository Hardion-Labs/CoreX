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
│   └── main.scene         # Initial scene (format_version 1, two entities)
├── scripts/
│   └── main.lua           # Gameplay script (Lua VM is planned)
└── assets/
    └── README.md          # Asset directory (indexed at startup)
```

## Run it

From the repository root, after `zig build`:

```sh
# Validate the project (no editor):
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --mode validate

# Open the editor (headless until the GUI exists):
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex

# Simulate a CoreXHub launch:
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --hub-launch --engine-version 0.1.0

# Run the runtime headless with 4 workers:
./zig-out/bin/corex-engine --project examples/hello-project/HelloProject.corex --mode runtime --headless --jobs 4
```
