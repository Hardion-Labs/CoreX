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
- ECS scheduling extensions (`src/ecs/graph.zig`, `src/ecs/frame.zig`,
  re-exported as `corex.ecs.graph`/`corex.ecs.frame` and
  `AutoSchedule`/`FrameSchedule`/`FrameBudget`/`FrameCursor`/`FrameResult`/
  `StopReason`/`SystemStats`): automatic comptime dependency-graph scheduling
  inferred from component access (declaration-order edges, parallel layers,
  exclusive barriers, no runtime graph allocation); allocation-free per-system
  profiling (`FrameProfiler`: runs/errors/monotonic timings, parallel-safe
  per-index slots, text report); cooperative frame budgets (`runBudgeted` +
  resumable `FrameCursor`, time/system-count limits checked between systems,
  never preempting a running system). Additive observer hooks
  (`runObserved`/`runSequentialObserved`, `NoopObserver`) on both `Schedule` and
  `AutoSchedule`; the plain `run`/`runSequential` contracts are unchanged.
- Scene system and versioned scene serialization (`src/scene/`, re-exported as
  `corex.scene`, `docs/scene-format.md`): strict JSON `format_version = 1`,
  stable entity IDs, parent hierarchy with cycle rejection, plain-data component
  schemas, deterministic serialize/parse, file load/save, and ECS-backed startup
  scene loading. The default `EngineScene` schema ships a `Transform` component.
- Scene prefabs (`src/scene/prefab.zig`, re-exported as `corex.scene.Prefab` /
  `corex.scene.EnginePrefab`, `docs/scene-prefabs.md`): reusable single-root
  `.prefab` documents (same strict `format_version = 1` shape as scenes),
  parse/load/save, capture from a live scene subtree (`fromScene`), and
  instantiation into any same-schema scene (`instantiate`). Backed by
  `Scene.cloneSubtree`/`rootIds`: clones entities/components by value, remaps
  stable IDs and parent links deterministically (ascending source-ID order),
  iterative subtree collection for deep hierarchies, and rollback of created
  entities on error. Added `AssetKind.prefab` and a `prefab` importer (v1) to the
  engine registry, so prefabs are validated (single-root), canonicalized and
  cached like other assets. Scene streaming remains planned.
- Asset import pipeline and content-addressed cache (`src/assets/`, re-exported
  as `corex.assets`, `docs/asset-import.md`): incremental, reproducible imports
  keyed by source content hash + importer identity/version + options; atomic
  cache writes with hash-verified, self-healing reads; raw/text/json importers
  plus scene and prefab importers that reuse the scene system; concurrent import over
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
  malformed/truncated sources are rejected. JPEG/audio/model/font remain
  `raw` imports until dedicated decoders exist.
- DEFLATE/zlib decompression (`src/assets/inflate.zig`, re-exported as
  `corex.assets.inflate`, `docs/asset-decoders.md`): complete RFC 1951 inflate
  (stored, fixed-Huffman and dynamic-Huffman blocks, multi-block streams,
  overlapping length/distance copies) plus the RFC 1950 zlib wrapper with
  Adler-32 verification. Canonical Huffman codes are decoded through a flat
  lookup table (O(1) per symbol) rebuilt in place per block; the 64-bit bit
  reader refills whole bytes. Output is bounded by the caller's
  `max_output_bytes` in both length and capacity (`error.OutputTooLarge`), and
  over-subscribed/incomplete code spaces, illegal symbols, reserved block types
  and back-references before the start of output are rejected.
- PNG decoder (`src/assets/png.zig`, re-exported as `corex.assets.png`) and a
  `png` importer (v1) registered for `.png` in the engine registry, producing the
  existing `CXTX` artifact: all non-interlaced color types (grayscale, truecolor,
  indexed, grayscale+alpha, truecolor+alpha) at every legal bit depth
  (1/2/4/8/16), all five row filters, `tRNS` palette alpha and grayscale/RGB color
  keys (compared at source depth), multiple consecutive IDAT chunks (single
  chunks inflated without copying), ancillary chunks skipped and unknown
  critical chunks rejected, with every chunk CRC-32 and the zlib Adler-32
  verified. 16-bit samples keep their high byte and sub-byte grayscale is bit
  replicated, because `CXTX` is RGBA8; Adam7 interlacing is rejected, not
  approximated. Scanline inflation is bounded by the size implied by `IHDR`, and
  images whose RGBA8 output would exceed `max_pixel_bytes` are rejected before
  inflating. Pixel conversion is specialized at comptime per (depth, channels).
- Reproducible decoder test vectors (`tools/gen_png_vectors.py`,
  `src/assets/png_vectors.zig`): 24 valid PNGs with reference RGBA8 output plus
  20 malformed PNGs and four DEFLATE/zlib streams, all generated with Python's
  zlib so the tests compare against an independent encoder.
- Asset change detection (`src/assets/changes.zig`, re-exported as
  `corex.assets.changes` with `Snapshot`/`ChangeSet`/`ChangeKind`,
  `docs/asset-change-detection.md`): a path-sorted snapshot of every indexed
  asset's size, mtime and BLAKE3 hash, and a linear merge join that reports
  added/modified/removed paths deterministically. Detection is two-tier — an
  unchanged size+mtime fingerprint reuses the stored hash without reading the
  file, and only candidates are hashed, so a touch or an identical re-save is not
  reported as a modification. `Options.verify_all` hashes everything for callers
  that cannot trust timestamps (the size+mtime blind spot is documented and
  tested). Change sets own their paths, so they outlive both snapshots.
  `Snapshot.cacheKeys` derives the complete live key set without importing, which
  is what `Cache.gc` needs after a partial run; a test asserts byte-for-byte parity
  with the keys a real pipeline run derives, including the `raw` fallback and a
  non-empty options salt.
- Asset cache garbage collection (`Cache.gc`, `Report.liveKeys`,
  `corex.assets.GcStats`): mark-and-sweep that deletes entries whose key is not in
  a caller-supplied live set (typically the keys of a full pipeline run) and
  reports `scanned`/`kept`/`removed`/`bytes_freed`. Entries are matched strictly by
  their 64-hex filename; temp and foreign files are untouched. O(entries + live),
  idempotent, intended as a maintenance op outside the concurrent import path.
  `Cache.open` now enables directory iteration (additive; existing behavior
  unchanged).
- Backend-independent render extraction layer (`src/render/`, re-exported as
  `corex.render`, `docs/render-extraction.md`): right-handed camera math
  (`perspective`/`orthographic`/`lookAt`, `Camera`), frustum culling
  (Gribb–Hartmann plane extraction, conservative AABB/sphere classification,
  `transformAabb`), and draw-list extraction (`extractDrawList`) that reuses the
  scene's O(n) world-transform snapshot, culls each `Renderable`'s world AABB and
  emits sorted `DrawCommand`s (`front_to_back`/`back_to_front`/`by_material`).
  Adds a plain-data `Renderable` scene component (mesh/material handles + local
  bounds). Pure CPU work with no GPU dependency — the contract the Low/Medium/
  Advanced GPU backends will consume; the backends themselves remain planned.
  Also adds reusable `Vec3` helpers (`dot`/`sub`/`add`/`scale`/`length`/`normalize`,
  public `cross`) to the scene transform math.
- OBJ mesh importer + engine-ready `CXMH` mesh artifact (`src/assets/mesh.zig`,
  re-exported as `corex.assets.mesh`, `docs/mesh-import.md`): decodes the
  Wavefront OBJ geometry subset (`v`/`vn`/`vt`/`f`, fan triangulation, negative
  indices, per-corner `v`/`v/vt`/`v//vn`/`v/vt/vn` forms) into an indexed triangle
  mesh with interleaved position/normal/UV vertices (`p3n3t2`, 32-byte stride),
  vertex deduplication, flat per-face normals when absent, and computed bounds.
  `serialize`/`parse` produce a self-describing little-endian `CXMH` container;
  `parse` is zero-copy, alignment-safe and validates index range + float finiteness
  in one linear pass. Registered in `engineRegistry()` (`.obj` → `obj` importer
  v1, `AssetKind.model`), so the pipeline imports/caches/GCs meshes like any asset.
  Bounded by `max_vertices`/`max_indices`; feeds the render extraction layer
  (`Renderable.bounds`/mesh handles). glTF/FBX/DAE remain `raw` (planned).
- WAV audio importer + engine-ready `CXAW` audio artifact (`src/assets/audio.zig`,
  re-exported as `corex.assets.audio` with `Audio`/`AudioView`,
  `docs/asset-audio.md`): decodes the uncompressed RIFF/WAVE subset — PCM 8-bit
  unsigned and 16/24/32-bit signed, IEEE float32, and `WAVE_FORMAT_EXTENSIBLE`
  with a PCM/float subformat GUID — into interleaved float32. Integer samples are
  scaled by `2^(bits-1)` (8-bit re-centered on 128, 24-bit sign-extended); float
  samples pass through unchanged including headroom beyond `[-1, 1]`, while
  NaN/Infinity are rejected. Ancillary chunks are skipped, `fmt ` must precede
  `data`, exactly one of each is required, odd chunks are word-padded and the RIFF
  size must match the file length. `serialize`/`parse` produce a self-describing
  20-byte-header little-endian `CXAW` container; `parse` is zero-copy,
  alignment-safe and validates dimensions, exact length and float finiteness in
  one linear pass. Registered in `engineRegistry()` (`.wav` → `wav` importer v1,
  `AssetKind.audio` already existed), so the pipeline imports/caches/GCs and
  incrementally re-imports audio like any asset. Bounded by `max_channels` (8),
  `max_sample_rate` (384 kHz) and `max_sample_bytes` (256 MiB); conversion is
  specialized at comptime per bit width. No resampling/downmixing/channel
  reordering, and no playback device or mixer yet; ADPCM/µ-law/A-law/GSM, 64-bit
  float and Ogg/MP3/FLAC/Opus/AIFF remain unsupported (rejected or `raw`).
- Reproducible audio test vectors (`tools/gen_wav_vectors.py`,
  `src/assets/audio_vectors.zig`): 15 valid WAVs with their expected interleaved
  f32 output (compared as bit patterns) plus 23 malformed/unsupported WAVs, all
  generated with Python's `struct` so the tests compare against an independent
  encoder.
- Device-independent audio mixer (`src/audio/`, re-exported as `corex.audio`
  with `Mixer`/`VoiceHandle`/`Clip`/`Config`/`PlayOptions`/`RenderStats`/`State`/
  `ChannelMap`/`PanLaw`, `docs/audio-mixer.md`): a fixed-capacity voice pool with
  generational handles (stale handles are inert; a slot whose generation would
  wrap is retired), buses with gain/mute, master gain, stereo pan (linear or
  equal-power), pitch, looping and linear-interpolated resampling with a float64
  cursor. `render` takes **no allocator** and cannot allocate: voices accumulate
  into the caller's interleaved f32 buffer and a single output pass applies
  master gain, replaces non-finite mixes with silence, clamps (optional) and
  meters peak/clipped samples. Channel mapping is explicit (mono/stereo
  passthrough, mono→stereo duplication, stereo→mono and N→mono averaging;
  surround→stereo is rejected rather than guessed). `toPcm16` converts a mix for
  a device and round-trips every i16 value exactly. The mixing core is
  monomorphized per (channel map, resampling mode) pair, with an
  interpolation-free fast path at unit step. Consumes `CXAW` artifacts without
  importing the asset layer, so both stay independently testable. No device
  backend, effects or streaming yet (planned); spatialization, voice stealing and
  band-limited resampling were added on top (below).
- Spatial audio and the scene audio bridge (`src/audio/spatial.zig`,
  `src/audio/system.zig`, re-exported as `corex.audio.spatial` /
  `corex.audio.system` with `Listener`/`Attenuation`/`Doppler`/`SpatialParams`/
  `SpatialResult`/`AudioSource`/`AudioSystem`, `docs/audio-spatial.md`): a
  right-handed listener basis derived from world matrices (scale normalized,
  re-orthogonalized, degenerate matrices fall back safely), four distance
  attenuation models (none/linear/inverse/exponential) with the distance clamped
  to `[min, max]`, azimuth amplitude panning, Doppler with a floored denominator
  and a symmetric pitch clamp, and a 2D/3D `spatial_blend`. `AudioSource` is a
  plain-data scene component (opaque clip handle, bus, gain, pitch, looping,
  transport, attenuation, Doppler factor, velocity) that serializes like
  `Renderable`. `AudioSystem.update` reuses the scene's O(n) world-transform
  snapshot and reconciles voices: start on the `playing` request, refresh
  gain/pan/pitch/bus/looping, restart on clip-handle change, stop on transport
  off, cull fully attenuated sources before starting, and mark-and-sweep entities
  whose entity or component disappeared. It never writes to the scene, reports
  finished one-shots exactly once without restarting them, and reports pool
  exhaustion as `unplayed` instead of hiding it. The system borrows the mixer and
  stops the voices it started on `deinit`. No HRTF, occlusion, reverb or
  automatic velocity derivation yet (planned).
- Voice stealing with priorities (`src/audio/mixer.zig`,
  `StealPolicy`/`Termination`, `docs/audio-mixer.md`): an opt-in
  `Config.steal_policy = .lowest_priority` recycles the least important voice
  when the pool is full instead of failing. `PlayOptions.priority` (0..255,
  default 128) ranks voices, ties break by oldest start, a voice of *higher*
  priority is never taken, and `PlayOptions.allow_steal = false` opts a request
  out. `terminationOf(handle)` reports `.stopped`/`.finished`/`.stolen` and keeps
  working after the slot is reused, because the reason is recorded per generation
  rather than per slot; `stolenCount()` totals the steals. The default `.none`
  preserves the previous hard-limit behaviour bit for bit. `AudioSource.priority`
  forwards the ranking through the scene bridge, a stolen source is reported once
  in `Stats.stolen`, and it is retried **without stealing** after the stop sweep
  — resuming from the last observed cursor — so two sources can never ping-pong
  and resuming does not depend on ECS iteration order.
- Band-limited resampling (`src/audio/resample.zig`, re-exported as
  `corex.audio.resample` with `Quality`/`Sinc`/`Kernel`, `docs/audio-mixer.md`):
  an opt-in `Config.resample = .sinc` replaces linear interpolation with a
  32-tap Blackman-windowed sinc whose cutoff follows the decimation ratio, so it
  low-passes **before** decimating instead of aliasing. The prototype is built
  once in `init` as a flat table plus a contiguous polyphase bank (~33 KiB);
  `render` stays allocation-free. Unity DC gain at every ratio and phase, support
  capped at 256 source samples, edge clamp/loop wrap, SIMD interior loops,
  contiguous bank rows at unity cutoff, and kernel reuse when the fractional
  cursor repeats (which makes integer ratios cheap). Measured on 64 looping
  stereo voices: 12× real time upsampling, 26× at 2:1, 4× for non-integer
  decimation, versus 175–222× for `.linear` — the quality/cost trade-off is
  documented, and `.linear` remains the default so existing output is unchanged.
- Insert effects for buses and the master (`src/audio/effects.zig`, re-exported
  as `corex.audio.effects` with `Effect`/`Chain`/`Biquad`/`BiquadKind`/
  `BiquadParams`/`Coefficients`/`Compressor`/`CompressorParams`,
  `docs/audio-effects.md`): a pure DSP module importing only `std`. RBJ biquad
  filters (low/high pass, constant-peak band pass, notch, peaking, low/high
  shelf) computed in double precision, processed in transposed direct form II,
  and checked with a Jury stability test at construction; plus a feed-forward
  stereo-linked peak compressor with a soft knee, separate attack/release
  one-poles and a below-threshold fast path that skips the detector entirely.
  Constructors validate every parameter, so the per-sample loop carries no
  parameter checks; non-finite input is silenced instead of poisoning recursive
  state, and state below ~1e-15 is flushed so silence does no denormal work.
  The mixer gains `Config.effect_slots` (0 = disabled, the default) and
  `Config.block_frames`, `setBusEffect`/`busEffect`/`clearBusEffects`,
  `setMasterEffect`/`masterEffect`/`clearMasterEffects`, `resetEffects` and
  `effectSlots`. Only buses with an *active* chain are isolated into a
  preallocated submix and summed back, so an all-bypass configuration is
  **bit-identical** to the effect-free path and `render` remains allocation-free;
  the block size does not change the output. Inserts are rejected when built for
  a different sample rate. Master inserts run before the master gain and before
  metering, and isolated buses keep ringing their tails after the last voice
  finishes. Measured on 64 looping stereo voices: reserving slots costs ~1%,
  one bus biquad +11%, all eight buses +77%, a master compressor +37% — still
  111-193x real time. No reverb/delay/convolution, lookahead limiting,
  oversampled saturation, side-chain or per-voice inserts yet (planned).
- Shared display-name validation (`src/core/validation.zig`) used by both the
  `.corex` manifest and scene documents.
- Native Module ABI contract for C++ (`docs/native-module-api.md`,
  `include/corex/native_module.h`); the loader is not implemented yet.
- A minimal example project (`examples/hello-project/`) with a valid versioned
  initial scene.
- Test suite covering the startup spine, ECS, scheduling (manual stages,
  automatic dependency graphs, observers, frame budgets and profiling), scenes,
  asset import/cache, world-space transforms, texture decoders, cache GC, render
  extraction, OBJ mesh import, scene prefabs, DEFLATE/zlib, PNG, asset change
  detection, WAV audio import, audio mixing, spatial audio, voice stealing,
  band-limited resampling and insert DSP (467 tests),
  including allocation-failure
  probes, cache corruption/truncation probes, a deep-hierarchy stress test, QOI
  encode/decode roundtrips, end-to-end texture-import-and-cache, OBJ-import-and-
  cache and import-then-GC tests, camera/frustum/culling and draw-list extraction
  tests, OBJ decode/artifact roundtrip and malformed-input tests, prefab
  capture/instantiate/rollback and prefab-import-and-cache tests, PNG/inflate
  reference-vector and rejection suites (including a 200 KiB multi-block stream
  and truncation probes), change-detection classification/blind-spot/key-parity
  tests, a full hot-reload cycle (detect, incremental re-import, GC), WAV
  reference-vector/rejection/alignment and WAV-import-and-cache tests, mixer
  exactness/resampling/looping/lifecycle/handle-safety/metering/determinism tests,
  an exhaustive PCM16 round trip, WAV-to-mixer playback integration,
  attenuation/Doppler/listener-basis reference tests, scene-emitter reconciliation
  and serialization tests, a scene-to-CXAW playback integration test, and job-system
  integration tests (including parallel graph/frame profiling over `JobSystem`
  workers), validated in Debug, ReleaseSafe and ReleaseFast.

### Changed

- Renamed the executable to `corex-engine`.
- README and architecture documentation now reflect the definitive scope and the
  per-subsystem implementation status.
- The public module `src/corex.zig` re-exports the implemented core, ECS
  (including scheduling, automatic dependency graphs and frame budgets/profiling),
  scene (including transform math as `corex.scene.transform` and prefabs as
  `corex.scene.Prefab`/`EnginePrefab`,
  `Mat4`/`Vec3`/`Quat`), asset (import/cache with GC, image decoders and the
  `CXTX` texture artifact as `corex.assets.image`/`corex.assets.texture`, PNG
  decoding as `corex.assets.png`, DEFLATE/zlib as `corex.assets.inflate` and change
  detection as `corex.assets.changes`, the OBJ
  mesh importer and `CXMH` artifact as `corex.assets.mesh`, the WAV audio importer
  and `CXAW` artifact as `corex.assets.audio`,
  `Image`/`Texture`/`Mesh`/`MeshView`/`Audio`/`AudioView`/`GcStats`), render
  (backend-independent extraction as `corex.render`) and audio
  (device-independent mixing as `corex.audio`, with spatialization as
  `corex.audio.spatial` and the scene bridge as `corex.audio.system`) subsystems.
- The engine import registry now decodes `.png`/`.bmp`/`.tga`/`.qoi` textures to `CXTX`
  and `.obj` meshes to `CXMH` artifacts instead of copying them verbatim; the cache
  key includes the importer identity/version, so this does not collide with
  previously cached `raw` entries.
- Startup `editor`/`runtime` now validates and loads the initial scene into the
  ECS (or prepares an empty scene). `validate` mode and the stable CLI/exit-code
  contract are unchanged; scene failures map to exit code 6.
- `pipeline.Options.only` (additive, default `null`) restricts a run to a set of
  project-relative paths, so a hot-reload pass imports only what changed. Both
  `run` and `runSequential` honor it; selection sorts the filter once and
  binary-searches each indexed asset (O(n log m)). A filtered `Report` covers only
  the selected assets, so its `liveKeys` is a partial set — use
  `Snapshot.cacheKeys` for garbage collection.
- The example project's initial scene was migrated from an unversioned placeholder
  to the documented `format_version = 1` scene format.
- All project documentation is now written in English. The remaining
  Portuguese pages (`scope`, `versioning`, `project-format`, `launch-contract`,
  `scene-format`, `scene-transforms`, `scene-prefabs`, `asset-import`,
  `asset-decoders`, `mesh-import`, `render-extraction`) were translated, along with
  the Portuguese section headings in `docs/architecture.md`. Technical content,
  tables, code samples, relative links, and the implemented/planned status of every
  subsystem are preserved; no contract, format version, or behavior changed. The
  English-only convention is now recorded in `CONTRIBUTING.md` and
  `docs/development/coding-standards.md`.

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
