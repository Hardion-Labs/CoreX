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
- ECS system scheduling (`src/ecs/schedule.zig`, `docs/ecs-scheduling.md`):
  comptime ordered stages, read/write access declarations with compile-time
  conflict rejection, exclusive systems, concurrent dispatch through `std.Io` /
  `JobSystem`, deterministic error propagation, and a `runSequential` fallback.
- Scene system and versioned scene serialization (`src/scene/`, re-exported as
  `corex.scene`, `docs/scene-format.md`): strict JSON `format_version = 1`,
  stable entity IDs, parent hierarchy with cycle rejection, plain-data component
  schemas, deterministic serialize/parse, file load/save, and ECS-backed startup
  scene loading. The default `EngineScene` schema ships a `Transform` component.
- Asset import pipeline and content-addressed cache (`src/assets/`, re-exported
  as `corex.assets`, `docs/asset-import.md`): incremental, reproducible imports
  keyed by source content hash + importer identity/version + options; atomic
  cache writes with hash-verified, self-healing reads; raw/text/json importers
  plus a scene importer that reuses the scene system; concurrent import over
  `std.Io` / `JobSystem` with a `runSequential` fallback and a per-asset report.
  The startup asset index (`src/core/assets.zig`) is unchanged.
- Scene world-space transform propagation (`src/scene/transform.zig`,
  `Scene.computeWorldTransforms` / `Scene.worldMatrix`, `docs/scene-transforms.md`):
  column-major `Mat4` math with quaternion helpers; a deterministic O(n)
  iterative pass (parents before children, no recursion, safe for arbitrarily
  deep hierarchies) producing a generation-safe snapshot keyed by entity handle.
  Entities without a `Transform` use the identity local transform. The `.scene`
  format is unchanged: only local TRS values are serialized, world matrices are
  computed at runtime.
- Texture decoders (`src/assets/image.zig`, `src/assets/texture.zig`,
  re-exported as `corex.assets.image` / `corex.assets.texture`,
  `docs/asset-decoders.md`): dependency-free BMP (uncompressed 24/32-bit),
  TGA (uncompressed + RLE true-color) and QOI (decode + encode) decoders
  normalizing to RGBA8, serialized into a self-describing `CXTX` artifact
  (magic + version + dimensions + pixel format + pixels). Registered in the
  engine import registry for `.bmp`/`.tga`/`.qoi`; `.qoi` added to the texture
  index classification. All reads are bounds-checked and allocations bounded;
  malformed/truncated sources are rejected. PNG/JPEG/audio/model/font remain
  `raw` imports until dedicated decoders exist.
- Asset cache garbage collection (`Cache.gc`, `Report.liveKeys`,
  `corex.assets.GcStats`): mark-and-sweep that deletes entries whose key is not in
  a caller-supplied live set (typically the keys of a full pipeline run) and
  reports `scanned`/`kept`/`removed`/`bytes_freed`. Entries are matched strictly by
  their 64-hex filename; temp and foreign files are untouched. O(entries + live),
  idempotent, intended as a maintenance op outside the concurrent import path.
  `Cache.open` now enables directory iteration (additive; existing behavior
  unchanged).
- Shared display-name validation (`src/core/validation.zig`) used by both the
  `.corex` manifest and scene documents.
- Native Module ABI contract for C++ (`docs/native-module-api.md`,
  `include/corex/native_module.h`); the loader is not implemented yet.
- A minimal example project (`examples/hello-project/`) with a valid versioned
  initial scene.
- Test suite covering the startup spine, ECS, scheduling, scenes, asset
  import/cache, world-space transforms, texture decoders and cache GC (223
  tests), including allocation-failure probes, cache corruption/truncation
  probes, a deep-hierarchy stress test, QOI encode/decode roundtrips, end-to-end
  texture-import-and-cache and import-then-GC tests, and job-system integration
  tests, validated in Debug, ReleaseSafe and ReleaseFast.

### Changed

- Renamed the executable to `corex-engine`.
- README and architecture documentation now reflect the definitive scope and the
  per-subsystem implementation status.
- The public module `src/corex.zig` re-exports the implemented core, ECS
  (including scheduling), scene (including transform math as `corex.scene.transform`,
  `Mat4`/`Vec3`/`Quat`) and asset (import/cache with GC, image decoders and the
  `CXTX` texture artifact as `corex.assets.image`/`corex.assets.texture`,
  `Image`/`Texture`/`GcStats`) subsystems.
- The engine import registry now decodes `.bmp`/`.tga`/`.qoi` textures to `CXTX`
  artifacts instead of copying them verbatim; the cache key includes the importer
  identity/version, so this does not collide with previously cached `raw` entries.
- Startup `editor`/`runtime` now validates and loads the initial scene into the
  ECS (or prepares an empty scene). `validate` mode and the stable CLI/exit-code
  contract are unchanged; scene failures map to exit code 6.
- The example project's initial scene was migrated from an unversioned placeholder
  to the documented `format_version = 1` scene format.

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
- ECS schedules reject conflicting read/write access in the same parallel stage
  at compile time; exclusive systems are isolated, and parallel stages wait for
  all systems before propagating errors.
- Scene documents are strictly validated: unknown/duplicate fields, duplicate or
  zero entity IDs, missing parents, self-parenting, parent cycles, unknown
  components and non-finite transform values are rejected; scene paths stay
  project-relative and scene size/entity counts are bounded.
- The asset import cache writes artifacts atomically (temp + rename) and verifies
  the payload hash and size on read, so corrupt or truncated entries are rejected
  and re-imported rather than trusted. Source reads and cache files are
  size-bounded; importers reject invalid UTF-8 and malformed/duplicate-field JSON.
- Added guidance for responsible vulnerability reporting and secure
  contributions.
