# Launch Contract — CoreXEngine

This is CoreXEngine's stable launch contract. It defines how the editor/runtime
are started, both directly from the command line and from CoreXHub. Integration
with the Hub happens **exclusively** through this contract, the documented
formats and the version contracts.

The engine **never** depends on the Hub to run. `--hub-launch` is only an
informational origin marker; it does not enable any behavior the engine needs in
order to work.

## Executable

The binary is named `corex-engine`.

```sh
corex-engine [options]
```

## Arguments

| Argument | Value | Description |
|---|---|---|
| `--project`, `-p` | path | Path to the `.corex` file (the project entry point). Accepts an absolute or relative path; a relative path is resolved to absolute from the working directory. Required in `editor`, `runtime` and `validate` modes. |
| `--hub-launch` | — | Informational marker that the process was launched by CoreXHub. It creates no dependency and does not change the engine's independence. |
| `--engine-version` | semver | Engine version the Hub selected, informational only. The engine records it and, if it differs from its own version, emits a warning. The engine does **not** install or select versions. |
| `--mode`, `-m` | `editor` \| `runtime` \| `validate` | Launch mode. Default: `editor`. |
| `--scene` | path | Overrides the manifest's initial scene. Path relative to the project, without `..`. |
| `--headless` | — | Forces execution without a graphical window (splash/editor in headless mode, log only). The graphical mode is planned; until the GUI library exists, execution is headless by default. |
| `--frames` | integer > 0 | Frames to render before exiting. Default `1`. A headless run has no window to close, so the count bounds it; `validate` renders nothing regardless. |
| `--jobs` | integer > 0 | Number of job-system workers. Default: logical cores minus one (minimum 1). |
| `--log-level` | `error` \| `warn` \| `info` \| `debug` | Log level. Default: `info`. |
| `--version`, `-v` | — | Prints the engine version and exits with code 0. |
| `--help`, `-h` | — | Prints the help text and exits with code 0. |

Unknown arguments, missing values or invalid modes result in a usage error
(exit code 2).

### Modes

- **`editor`** (default): runs the full startup sequence and opens the editor
  session. Until the graphical editor is implemented, the session is opened in
  headless mode and readiness is reported.
- **`runtime`**: runs startup and prepares the project's runtime session (no
  editor).
- **`validate`**: validates the manifest, compatibility, configuration and asset
  index, then exits. It does not prepare a scene or open the editor. Useful for
  the Hub and for CI.

## Examples

Launch from the Hub:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --hub-launch
```

Launch the editor directly:

```sh
corex-engine --project "/path/MyGame/MyGame.corex"
```

Validate a project (without opening the editor):

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --mode validate
```

Run the runtime headless with 4 workers:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --mode runtime --headless --jobs 4
```

## Startup sequence

On receiving a project, the engine runs, in this order:

1. **Initialize essential services** — jobs, logging, diagnostics.
2. **Open the splash screen** — reports startup progress (headless for now; a
   graphical splash is planned).
3. **Validate the manifest and compatibility** — reads the `.corex`, validates
   format and fields, and checks version compatibility with the engine.
4. **Load configuration in workers** — loads the project configuration
   asynchronously on the job system.
5. **Index assets** — scans the asset directories and builds the index.
6. **Prepare the initial scene** — resolves, validates and loads the initial
   scene (manifest or `--scene`) into the ECS; with no scene specified, prepares
   an empty scene. Does not apply to `validate` mode. Format:
   [scene-format.md](scene-format.md).
7. **Select the renderer and open the graphical editor** — maps the configured
   renderer tier (`settings.json` → `renderer`) onto the render contract and
   verifies a backend exists for it; a tier with no backend (`advanced` in this
   build) fails the session and exits with code 6 instead of silently rendering at
   a lower tier. Then opens the editor session (or prepares the runtime in
   `runtime` mode). Does not apply to `validate` mode, which validates the project
   without preparing a session.

A failure at any stage aborts the sequence and produces the corresponding exit
code. The splash screen is closed on every exit path.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Unexpected internal error. |
| 2 | Invalid command-line usage (unknown argument, missing value, invalid mode, missing project when required). |
| 3 | Invalid project manifest (malformed JSON, missing required field, unsupported `format_version`, unsafe path). |
| 4 | Project version incompatible with the engine. |
| 5 | Project not found or an I/O error while reading it. |
| 6 | Failure preparing configuration, assets, the initial scene or the renderer tier (configured tier has no backend). |

Exit codes are part of the stable contract and must not be reordered or reused
with a different meaning.

## Independence from the Hub

- The engine does not create, register, list or manage projects.
- The engine does not install, select or manage engine versions.
- The engine does not keep a recent-project catalog.
- The engine does not call the Hub, does not read Hub configuration and does not
  require the Hub to be present.
- All communication from the Hub to the engine happens through launch arguments
  and the documented file formats.

## Related

- Project format: [project-format.md](project-format.md)
- Scene format: [scene-format.md](scene-format.md)
- Versioning and compatibility: [versioning.md](versioning.md)
- Scope: [scope.md](scope.md)
