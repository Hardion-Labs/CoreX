# Project Format — the `.corex` file

The `.corex` file is the **entry point** of a CoreXEngine project. It is a UTF-8
JSON document that describes the project and points at its resources. The engine
receives it via `--project` and validates it before loading any content.

The engine does **not create** `.corex` files. Project creation is CoreXHub's
responsibility (or an external tool's). The engine only reads and validates.

## Structure

```json
{
  "format_version": 1,
  "name": "MyGame",
  "id": "3f2b8c1e-9d4a-4e7b-8c1e-9d4a4e7b8c1e",
  "engine_version": "0.1.0",
  "initial_scene": "scenes/main.scene",
  "asset_directories": ["assets"],
  "script_directories": ["scripts"]
}
```

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `format_version` | integer | yes | Manifest format version. Currently supported: `1`. |
| `name` | string | yes | Project display name. Non-empty, with no path separators or control characters. |
| `id` | string | no | Stable project identifier (e.g. a UUID). Assigned by whoever creates the project (the Hub). The engine does not generate it. |
| `engine_version` | string (semver) | yes | Engine version the project was created for. Used in the compatibility check. |
| `initial_scene` | string | no | Initial scene, relative to the project root. Default: none (the editor/runtime prepares an empty scene). In `editor`/`runtime` modes the file must be a valid scene ([scene-format.md](scene-format.md)); `validate` does not load the scene. |
| `asset_directories` | array of string | no | Asset directories, relative to the root. Default: `["assets"]`. |
| `script_directories` | array of string | no | Script directories, relative to the root. Default: `["scripts"]`. |

Unknown fields are rejected by strict validation to avoid silent typos. Future
format versions may add fields; that always bumps `format_version`.

## Path rules

Every path inside the manifest (`initial_scene`, `asset_directories`,
`script_directories`) must be:

- **Relative** to the project root (the directory containing the `.corex`).
- Free of traversal (`..` is not allowed in any component).
- Free of absolute paths.
- Non-empty.

These rules exist so a project cannot reference files outside its own root. The
engine rejects the manifest (exit code 3) if any path violates them.

The project root is the directory containing the `.corex` file. For example, for
`/path/MyGame/MyGame.corex`, the root is `/path/MyGame`.

## Version compatibility

The `engine_version` field is compared against the running engine version using
the policy in [versioning.md](versioning.md). Incompatible projects are rejected
with exit code 4. The engine does not try to install or select another version.

## Minimal example

```json
{
  "format_version": 1,
  "name": "MyGame",
  "engine_version": "0.1.0"
}
```

With the minimal manifest, the engine uses `asset_directories = ["assets"]`,
`script_directories = ["scripts"]` and no explicit initial scene.

## Stability

`format_version = 1` is the current contract. Incompatible format changes bump
`format_version`. The engine only supports the format versions it explicitly
declares; unknown versions are rejected.
