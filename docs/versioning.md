# Versioning and Compatibility — CoreXEngine

## Engine version

CoreXEngine uses [Semantic Versioning 2.0.0](https://semver.org/):
`MAJOR.MINOR.PATCH[-PRE][+BUILD]`.

The current engine version is exposed by `corex.version` and printed by
`corex-engine --version`. The target compiler version is **Zig 0.17.0**, exposed
by `corex.zig_version`.

During early development the engine uses `0.x.y` versions (e.g. `0.1.0-dev`).
The `-dev` suffix marks development builds.

## Project compatibility policy

A project declares the engine version it was created for in the `engine_version`
field of the `.corex` manifest. The engine checks compatibility before loading
the project:

- **Different MAJOR** → incompatible. MAJOR changes break compatibility.
- **MAJOR == 0** (early phase): `MINOR` must be **equal**. In `0.x`, every MINOR
  increment may break compatibility, so equality is required.
- **MAJOR >= 1**: the project's `MINOR` must be **less than or equal to** the
  engine's (backward compatibility within the same MAJOR). A project requiring a
  newer MINOR than the engine's is incompatible.
- `PATCH`, `PRE` and `BUILD` do not affect compatibility. They are recorded for
  diagnostics.

Check outcome:

- Compatible → startup proceeds.
- Incompatible → the engine rejects the project with exit code **4** and a
  message stating the versions involved.

The engine does **not** install, download, select or switch versions silently.
Version selection is exclusively CoreXHub's responsibility. If the project is
incompatible, it is up to the user (or the Hub) to launch the correct engine
version.

## Version selected by the Hub (`--engine-version`)

When launched by the Hub, the engine may receive `--engine-version <semver>` with
the version the Hub selected. That value is **informational**:

- The engine records the received version.
- If it differs from the actual version of the running binary, the engine emits a
  warning.
- The engine takes no installation/selection action based on that value.

This keeps the boundary clear: the Hub decides which version to launch; the
engine only reports which version it is.

## Format versioning

File formats (the `.corex` manifest, scenes, assets, export templates) have their
own version, independent of the engine version:

- The `.corex` manifest uses `format_version` (currently `1`).
- `.scene` scenes use their own `format_version` (currently `1`), independent of
  the manifest and of the engine version ([scene-format.md](scene-format.md)).
- The asset import cache uses its own `format_version` (currently `1`), embedded
  in every entry; the cache key also incorporates the importer version, so
  bumping either one invalidates the affected entries
  ([asset-import.md](asset-import.md)).
- Unknown format versions are rejected.
- Incompatible format changes bump the format version.

## Stable contracts

The following are part of the stable integration contract:

- Command-line arguments and their meanings ([launch-contract.md](launch-contract.md)).
- Exit codes ([launch-contract.md](launch-contract.md)).
- The `.corex` manifest format and its `format_version` ([project-format.md](project-format.md)).
- The `.scene` scene format and its `format_version` ([scene-format.md](scene-format.md)).
- The compatibility policy in this document.

Changes to these contracts require an appropriate version bump and a note in the
[CHANGELOG](../CHANGELOG.md).
