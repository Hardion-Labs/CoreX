# Changelog

Notable changes to CoreXEngine are recorded here. The project intends to use
Semantic Versioning when it begins publishing versions; no released version is
declared yet.

## Unreleased

### Added

- Definitive project scope and the Engine/Hub boundary (`docs/scope.md`).
- Stable launch contract: CLI arguments, startup sequence, and exit codes
  (`docs/launch-contract.md`).
- `.corex` project manifest format with strict validation and safe relative-path
  rules (`docs/project-format.md`, `src/core/manifest.zig`, `src/core/paths.zig`).
- Engine versioning and project compatibility policy (`docs/versioning.md`,
  `src/core/version.zig`).
- Launch argument parsing (`src/core/cli.zig`) with `--project`, `--hub-launch`,
  `--engine-version`, `--mode`, `--scene`, `--headless`, `--jobs`, `--log-level`,
  `--version`, and `--help`.
- Job system / async loading foundation over `std.Io` concurrency
  (`src/core/jobs.zig`).
- Project configuration loading (`src/core/config.zig`).
- Asset indexing by kind and size (`src/core/assets.zig`).
- Splash screen contract with a headless implementation (`src/core/splash.zig`).
- Diagnostics: monotonic timers and a stage profiler (`src/core/diagnostics.zig`).
- The 7-step startup pipeline (`src/core/startup.zig`), running configuration and
  asset indexing concurrently in workers.
- Data-oriented ECS (`src/ecs/`, re-exported as `corex.ecs`): generational entity
  handles with safe slot recycling (`entity.zig`), sparse-set component storage
  with O(1) add/remove/get/has (`pool.zig`), and a comptime-typed world with
  type-safe component access and multi-component views (`world.zig`).
- Native Module ABI contract for C++ (`docs/native-module-api.md`,
  `include/corex/native_module.h`); the loader is not implemented yet.
- A minimal example project (`examples/hello-project/`).
- Test suite covering the startup spine and the ECS (88 tests), validated in
  Debug, ReleaseSafe and ReleaseFast.

### Changed

- Renamed the executable to `corex-engine`.
- README and architecture documentation now reflect the definitive scope and the
  per-subsystem implementation status.
- The public module `src/corex.zig` re-exports the implemented core subsystems.

### Fixed

- Build compatibility with Zig 0.17.0: replaced the removed `Build.args` with
  `Run.addPassthruArgs`, so `zig build`, `zig build run -- ...`, and
  `zig build test` now build and run. Previously the build script failed to
  compile on the target version.

### Removed

- None.

### Security

- Manifest paths are validated to stay within the project root (no absolute
  paths, no `..` traversal, no control characters).
- ECS generational handles prevent use-after-free: a stale handle cannot access a
  recycled entity's components, and slots are retired before generation
  wraparound can alias a live entity.
- Added guidance for responsible vulnerability reporting and secure
  contributions.
