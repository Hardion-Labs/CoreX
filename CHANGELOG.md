# Changelog

Notable changes to CoreXEngine are recorded here. The project intends to use
Semantic Versioning when it begins publishing versions; no released version is
declared yet.

## Unreleased

### Added

- Asset upload and eviction (`src/scene/render_scene.zig`, `src/render/pipeline.zig`):
  the render table is now filled the way a renderer actually consumes it.
  - **Mip chains for uploaded textures.** `loadAssets` builds a chain below level 0 with
    `render.mipmap` (integer box filter, deterministic) and hands it to the texture's
    `mips`. `FrameParams.mipmap` defaulted to `.trilinear` and Medium declares mipmaps,
    but a texture uploaded without levels could only ever sample level 0 — minification
    aliased and the tier capability was decorative. A 1x1 texture generates nothing and
    says so (`report.mipmapped`); a test pins the 4x4 → 2x2 → 1x1 values, not just the
    level count.
  - **Source bytes are released at upload.** A mesh is copied into the table's scratch
    and a texture keeps only level 0 plus its chain, so the file bytes a session decoded
    no longer stay alive for the whole run. `AssetTable.uploadedBytes` reports the
    footprint the renderer actually holds (scratch + every level), and the binary prints
    `Assets uploaded: N meshes, M textures (K mipmapped), S skipped, B bytes`.
  - **Real eviction.** `LoadedAssets.evict(path)` releases the slot and frees the pixel
    blocks; `ResourceTable.release` now bumps every kind's generation itself, so stored
    handles stop resolving immediately instead of waiting for the next `set*`, and
    releasing an already-free slot is a no-op. `ResourceTable.handleOf(slot, kind)` and
    `isLive` expose the authoritative handles, and `LoadedAssets.handleOf` reads them
    instead of rebuilding generation 1 — which is still returned for a planned-but-empty
    slot, because a stored `.scene` cannot be rewritten when one file is broken.
    `AssetReport` gained `evicted` and `mipmapped`. 6 new tests (734 total).
- Frame pacing (`src/runtime/pacing.zig`, `corex.runtime.pacing`,
  `docs/presentation.md`): a `Pacer` that holds a frame loop to a target rate, and the
  frame timing statistics the loop was missing. `FramePacing` reports each frame's
  `work_ns`, `slept_ns` and whether it was `late`; `RunReport` aggregates `slept_ns`,
  `elapsed_ns` and `late_frames`. The budget is the integer reciprocal `1e9 / fps`
  (60 fps = exactly `16_666_666 ns`), the deadline is anchored to
  `previous_deadline + budget` so timer overshoot does not accumulate into a loop that
  slowly runs slower than asked, and a frame that overruns never sleeps and never tries
  to catch up a burst — it is counted and the schedule re-anchors on the instant the
  frame ended. That last detail is pinned by a test: re-anchoring one budget *past* the
  overrun would hand the next frame two budgets of slack and report half the late
  frames the loop really has. A wait beyond `max_wait_ns` (1 s) means the deadline is in
  the wrong epoch, so it re-anchors and counts a resync instead of blocking the process.
  `Pacer.disabled` never reads the clock: the headless default. This is a sleep-based
  pacer and the module, the docs and this entry say so — without a presentable surface
  there is no vsync signal, but the deadline computed is the one `FIFO` would impose, so
  the accounting stays valid when a swapchain lands. Measured on the shipped example in
  `ReleaseFast`: `--frames 60 --fps 60` → 0 late, 16.561 ms/frame; `--fps 120` → 0 late,
  8.225 ms/frame. 10 new tests.
- Launch contract: `--fps <n>` paces the loop; `--fps 0` is a usage error, not a synonym
  for unpaced. A paced run prints a second line,
  `Pacing: <fps> fps — <n> late of <n> frames, <n> resyncs, <ms> slept, <ms> elapsed,
  <ms>/frame`; an unpaced run prints nothing extra, because a line of zeros would look
  like a measurement of something that never happened. `FrameLoop.init/frame/run` gained
  the rate and an `?Io` (`null` renders without reading the clock, which is how the loop
  tests measure work rather than wall-clock time). (729 total)
- Presentation layer (`src/runtime/presentation.zig`, `corex.runtime`,
  `docs/presentation.md`): the engine now has a **frame loop** instead of a single
  frame. `SurfaceTarget` owns the RGBA8 colour and `f32` depth buffers for a whole run
  and reallocates only when the size actually changes — and never destroys the current
  frame on a failed or rejected resize, since both allocations happen before either
  slice is replaced. Zero-sized and oversized surfaces are refused rather than
  accepted. `FrameLoop` drives `EngineRenderer` over a bounded number of frames,
  owning the target, the renderer and a per-frame arena for camera lookup (finding the
  camera resolves a world matrix and would otherwise allocate every frame); its
  `RunReport` counts rendered frames, empty frames (a scene with no camera stops the
  loop rather than repeating an unchangeable answer) and allocating frames. Two
  properties are tested, not asserted in prose: a counting allocator proves
  steady-state frames take **0 calls / 0 bytes**, and five repeated frames of an
  unchanged scene are **pixel-identical** byte for byte while a moved quad changes
  them. Measured on the shipped example: `--frames 120` reports **2 allocating** — one
  per draw-list buffer, the entire warm-up.
- Launch contract: `--frames <n>` bounds a run (default `1`, the previous behaviour);
  `--frames 0` is a usage error. The binary now prints
  `Frames: N of N (N allocating) at WxH <tier> — last frame: …` instead of the
  single-frame line. 6 new tests (718 total).

- Per-frame allocator hand-off (`src/render/draw.zig`,
  `corex.render.draw.extractIntoScratch`): the draw list keeps growing in the
  caller's general-purpose allocator (it survives the frame), while every transient
  allocation of a frame — the world-transform snapshot's matrix and entity arrays,
  its two lookup maps and three work arrays — now comes from a **scratch arena** the
  `RenderFrame` owns and resets once per `refill`. Pass the same allocator twice and
  you get the previous `extractInto` exactly. `RenderFrame.allocated_last_frame`
  reports whether a frame had to ask for memory at all, surfaced as
  `EngineFrameReport.allocated`, so "this frame was free" is observable instead of
  assumed. A counting-allocator test asserts **zero** calls and **zero** bytes on a
  steady-state frame — after two warm-up frames, because `refill` extracts into the
  spare buffer and a double-buffered frame reaches its steady size only once *both*
  buffers have grown (paid twice per session, never per frame). The same test grows
  the scene to 68 renderables and confirms the arena simply grows with it (708
  total).

- Scene renderer (`src/scene/render_scene.zig`, `corex.scene.render_scene`,
  `docs/scene-format.md`, `docs/render-extraction.md`): the layer that connects a
  project's scene file to the render pipeline, which was the missing half.
  `EngineRenderScene` / `EngineRenderPrefab` are the engine schema with
  `transform` + `renderable` + `camera`, so a `.scene` can finally name a mesh and
  own a camera; `CameraComponent` (`fov`/`near`/`far`, validated) is the lens and the
  entity's world transform the position and basis. `planSlots(gpa, asset_index,
  capacity)` assigns every renderable asset a deterministic table slot (hash start,
  linear probing, **one namespace** for meshes and textures so no slot ever holds
  both and every handle stays at generation 1), which makes a stored handle a pure
  function of the project's content and table capacity — `plan.handleOf(path)` is
  that handle, computable without loading anything. `loadAssets` fills the
  pipeline's `AssetTable` from the plan: `.mesh` artifacts and `.obj` sources become
  meshes, `.png`/`.bmp`/`.tga`/`.qoi` become textures, each slot also gets a white
  base colour so a mesh's own handle is a valid material, and the layout is decided
  **before** any bytes are read so one broken file cannot shift every later handle.
  Failures are explicit and counted (`skipped`, `error.TableFull`), never a silently
  missing mesh. `EngineRenderer` owns the reusable double-buffered `RenderFrame` and
  renders a frame with the scene's own camera and the surface's aspect, reporting
  commands/draws/skipped/pixels/culled and whether the list changed;
  `findCamera`/`renderSceneFrame` are the headless per-frame path. The engine binary
  now renders **one real frame** of the project at startup and prints
  `Frame: WxH <tier> (N commands, N draws, N skipped, N pixels, N culled)`, or says
  `no camera in the scene; nothing to render` when the scene authors none.
  `AssetTable.setDecodedMesh` is the one conversion from a source decoder's owned
  mesh into the table. 10 new tests: schema round-trip, lens validation, probe
  stability, asset loading (mesh + texture + skipped file), OBJ decoding, slot
  exhaustion, a broken file not shifting handles, the renderer's draw/reuse/change/
  cull cycle, and the headless frame path including the no-camera and zero-size
  surface cases (707 total).

- The example project now renders: `examples/hello-project/scenes/main.scene` draws
  a quad from a plain-text `assets/quad.obj` seen by a camera entity, so a checkout
  carries no binary assets and the headless smoke run prints a real frame
  (`1280x720 medium (1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled)`).

- Renderer tier contract (`src/render/backend.zig`, `docs/render-backend.md`,
  `corex.render.backend`): the boundary every renderer tier implements, so a
  backend can be swapped without touching the scene or the extraction layer.
  `Tier` = `low`/`medium`/`advanced` with **one** `capabilities(tier)` table (Low
  is opaque, untextured, unlit geometry with a depth buffer; Medium is the full
  CPU feature set: textures, Lambert lighting, blending, mip selection, edge
  antialiasing; Advanced declares the same set until a backend exists).
  `FrameOptions` (`blend`, `antialias`, `mipmap`, `light`, depth test/write,
  `cull`, `front_face`) converts to the rasterizer's `Options` through
  `rasterOptions()`. `Surface` is a borrowed RGBA8 colour + `f32` depth buffer
  (`validate`/`clear`/`Surface.of(target)`). `DrawResources` is the asset resolver
  as a *runtime* value — a pointer plus `meshFn`/`colorFn` and optional
  `textureFn`/`lightFn` — adapted from any comptime provider by `fromComptime`,
  with absent and private declarations staying invisible exactly as `@hasDecl`
  makes them. `Backend` is an explicit vtable (`beginFrame` → N × `draw` →
  `endFrame` → `deinit`) taking `mvp = view_projection * world`, folded once by
  the caller. `beginFrame` validates the surface and **rejects** any option the
  tier cannot honour (`error.UnsupportedFeature`) instead of degrading silently;
  `unsupported(tier, options)` reports which one. Lifecycle misuse is an error
  (`FrameNotBegun`/`FrameAlreadyBegun`), never undefined behaviour. `SoftwareBackend`
  implements the contract on the existing rasterizer as the reference driver, and
  the tests prove it is **byte-identical** (colour *and* depth) to calling
  `raster.drawMeshAlloc` directly, plus stats accounting, culling, skipped
  handles, light precedence (provider vs explicit vs absent) and the whole
  capability gate — 9 new tests (681 total).

- Frame pipeline over the tier contract (`src/render/pipeline.zig`,
  `corex.render.pipeline`, `docs/render-backend.md`): `renderScene` takes a scene
  and a tier and produces a frame — extraction, `mvp` folding, the
  `beginFrame`/`draw`/`endFrame` loop and a `FrameReport` (tier, commands,
  extraction culling, backend stats and the options that were **accepted**).
  `renderFrame` is the same path for an already extracted draw list.
  `tierFromConfig` maps `settings.json`'s `RendererTier` onto the contract's `Tier`
  with a **comptime** check that no config tier lacks a render tier;
  `backendFor` is the single place a backend is registered, and since Advanced has
  none, a project that names it is refused at startup (exit code 6) instead of
  silently rendering at Medium. `resolve` coerces a `FrameParams` to what the tier
  can honour (antialiasing, mip selection, lighting, blending), so the pipeline
  never trips its own gate and the default blend follows the extraction sort
  (`back_to_front` → `.alpha`). `ResourceTable` is a fixed-capacity,
  allocation-free-after-init handle table with **per-kind generations**, so a
  released or reused slot cannot be aliased by a stale handle and a material does
  not invalidate its slot's mesh; `AssetTable` fills it from zero-copy `CXMH`
  views plus `textureFromAsset` for decoded `CXTX` textures, keeping `render`
  free of an asset-layer dependency. Startup step 7 now selects and logs the tier
  and fails the session when the tier has no backend; the launch summary prints
  the selected tier.

### Fixed

- A frame's draw list was compared **byte by byte** to decide whether it had
  changed, which reported every frame as changed: `DrawCommand` has padding the
  compiler may leave undefined, so two lists identical in every field that is read
  usually differ in the bytes that are not. `draw.commandsEqual` compares field by
  field (`entity`, handles, world matrix, bounds, depth), so `RenderFrame.refill`
  now answers "is this frame different from the last one?" correctly.

- **`DrawResources.fromComptime` returned a dangling pointer.** It took the
  provider by value and stored the address of its own parameter, so every field
  read afterwards came from a dead stack slot: correct at `-O Debug` (nothing
  overwrites it) and wrong at `-O ReleaseSafe`, where the optimizer reuses the
  slot — observed as a conformance failure that made the software backend render a
  different colour than the rasterizer it drives. It now requires a pointer
  (`fromComptime(&provider)`, enforced at comptime with an explicit message), which
  makes the borrow explicit and the lifetime the caller's. Regression test: a
  provider whose mesh/material handles and tint are read through the adapter ends
  up in the framebuffer channel by channel, and the whole suite now runs green in
  Debug, ReleaseSafe and ReleaseFast.

- Software rasterizer: a triangle whose vertices project outside the target could
  panic with an integer overflow in the pixel-box math. The box was clamped before
  the fixed-point→pixel shift, which can leave a negative index; the antialiasing
  halo then widened it by one more and `clip_min - min` overflowed. Both paths now
  clamp to the target after the shift and share the same four clamps, with a
  regression test that fails without the fix.

### Changed

- `Texture` in the render contract is validated before shading
  (`error.InvalidTexture`), and a texture binding on a tier without textures is a
  rejected draw rather than a silently flat one.

- Mipmaps and LOD selection in the software rasterizer (`Texture.mips`,
  `corex.render.MipLevel`, `Options.mipmap` = `trilinear`/`level0`,
  `corex.render.mipmap.Chain`, `docs/render-raster.md`): a texture may now carry
  the levels below level 0, largest first, and `mipmap = .trilinear` (the default)
  picks the level per pixel from the exact derivative of the perspective UV
  mapping — six constants per triangle from the same per-pixel edge steps the
  coverage loop uses — then mixes the two neighbouring levels in `f64` with one
  final round. `mipmap.Chain.generate` builds the chain with an **integer box
  filter** (`(sum + count/2) / count`, one round-half-up, odd axes share their
  last row/column), and `Texture.validate()` rejects any chain that is not exactly
  repeated halving. A constant perspective denominator (any orthographic
  projection) hoists the `log2` to once per triangle, so the orthographic
  benchmark costs ~1.2x over level 0 instead of ~2x; a texture without `mips`, or
  `mipmap = .level0`, stays byte-identical to the pre-mipmap path. Verified by 34
  new reference frames in `src/render/raster_texture_vectors.zig` (78 total,
  1094 covered pixels, all bit-exact) covering minification, anisotropy,
  magnification, perspective, repeat and `.level0`, plus unit tests for the chain
  (odd axes, 1x1, allocation failure), LOD clamps, the analytic gradient, the
  trilinear mix and a checkerboard aliasing test. Benchmarked at 1024x1024
  (128 texels/pixel): level 0 68.6 ms, trilinear 79.8 ms.
- Edge antialiasing in the software rasterizer (`Options.antialias`,
  `corex.render.Antialias` = `none`/`edge`, `docs/render-raster.md`): `edge`
  supersamples each pixel with a 4x4 grid of 16 **exact integer** sub-samples at
  offsets 2/6/10/14 sixteenths, evaluated from the same `i64` edge functions as the
  one-sample path and with the top-left fill rule applied to the sub-samples — so
  two triangles sharing an edge partition its samples (coverage sums to 16, no
  seam) and coverage stays bit-exactly reproducible in every optimization mode.
  Coverage is accumulated **per draw command** in `AccumBuffers` (per-fragment
  compositing was rejected: it seams on shared edges) and resolved once per touched
  pixel, with the fraction folded into the source alpha of a straight-alpha
  source-over; fully covered pixels take the un-antialiased path and are
  byte-identical to it, and partial pixels never write depth but bump the new
  `Stats.antialiased_pixels`. A pixel provably farther than one sub-sample spacing
  from every edge takes a two-comparison full/empty path instead of the grid. The
  scratch is sized from the mesh's conservative screen reach (`reachRect`) and
  comes from the caller's allocator, so `DrawError` gains `OutOfMemory` and the new
  `rasterizeAlloc` / `drawMeshAlloc` entry points are the only ones that
  antialias — `rasterize`, `drawMesh` and `rasterTriangle` force `antialias = .none`
  and keep their exact previous signatures and behaviour. Verified by area
  conservation against the shoelace screen area of a slanted quad (167.40 px vs
  167.04 px, 0.2%), a from-scratch sub-sample cross-check of `coverageCount`, the
  quad-partition property, byte-identity for grid-aligned geometry, the
  no-depth-from-partial-pixels rule, the translucent-composite formula,
  `checkAllAllocationFailures` over the scratch sites, and the four reference
  corpora (206 cases) staying byte-identical. Benchmark at 1024x1024 (1024 sampled
  tiles): one sample 27.3 ms, `.edge` 40.9 ms.
- Framebuffer blending in the software rasterizer (`Options.blend`,
  `corex.render.Blend` = `none`/`alpha`/`premultiplied`/`additive`,
  `docs/render-raster.md`): the shaded fragment is composited with the target as
  straight-alpha source-over (`(src*src.a + dst*dst.a*keep) / out.a`),
  premultiplied source-over (`src*src.a + dst*keep`) or additive
  (`dst + src*src.a`); alpha composites in every mode (`out.a = src.a + dst.a*keep`),
  depth is never blended, and each channel is clamped to `[0, 1]` and quantized
  **once** (`floor(clamp(v,0,1) * 255 + 0.5)`, `f64`, pinned order). The default
  `.none` writes the fragment verbatim and is byte-identical — color and depth —
  to the pre-blending path; a fully transparent source is an exact no-op in every
  mode and a fully transparent `.alpha` result becomes transparent black instead
  of dividing by zero. Correct transparency pairs with the extraction layer's
  `back_to_front` sort (the rasterizer performs no reordering and buffers no
  fragments). Verified by 49 reference frames in
  `src/render/raster_blend_vectors.zig` (generated by
  `tools/gen_raster_blend_vectors.py`; every case starts from a non-empty target,
  full RGBA8 frames bit-exact — 801 covered pixels) plus per-mode unit tests, the
  fallback cases, a byte-identity test for the default path and a cross-layer
  test (scene → `back_to_front` extraction → alpha blend → QOI round-trip). Measured with
  `zig build bench -Doptimize=ReleaseFast` at 1024² (full coverage): flat
  6.601 ms, alpha 20.836 ms, additive 17.437 ms.
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
  cached like other assets.
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
  malformed/truncated sources are rejected. Audio/model/font remain
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
  existing `CXTX` artifact: every color type (grayscale, truecolor,
  indexed, grayscale+alpha, truecolor+alpha) at every legal bit depth
  (1/2/4/8/16), all five row filters, `tRNS` palette alpha and grayscale/RGB color
  keys (compared at source depth), multiple consecutive IDAT chunks (single
  chunks inflated without copying), ancillary chunks skipped and unknown
  critical chunks rejected, with every chunk CRC-32 and the zlib Adler-32
  verified. 16-bit samples keep their high byte and sub-byte grayscale is bit
  replicated, because `CXTX` is RGBA8. Scanline inflation is bounded by the
  size implied by `IHDR`, and
  images whose RGBA8 output would exceed `max_pixel_bytes` are rejected before
  inflating. Pixel conversion is specialized at comptime per (depth, channels).
- Reproducible decoder test vectors (`tools/gen_png_vectors.py`,
  `src/assets/png_vectors.zig`): 24 valid PNGs with reference RGBA8 output plus
  19 malformed PNGs and four DEFLATE/zlib streams, all generated with Python's
  zlib so the tests compare against an independent encoder.
- Adam7 interlaced PNG decoding (`src/assets/png.zig`): the seven passes are
  unfiltered as independent sub-images, each with its own row padding and its own
  filter history, then scattered to their final positions. Empty passes
  contribute no bytes, the inflated size is predicted from `IHDR` as the sum over
  the non-empty passes and must match exactly, and interlace methods other than 0
  and 1 are rejected. The existing unfilter and comptime pixel converter are
  reused unchanged; one scratch row (`width * 4` bytes) is allocated and reused
  across all passes, and the final pass (x-step 1, half the image) converts
  straight into the output row with no copy. Measured at parity with the
  non-interlaced path on a 1024×1024 pair, which decodes to byte-identical output.
- Adam7 test corpus (`tools/gen_png_adam7_vectors.py`,
  `src/assets/png_adam7_vectors.zig`): 34 valid interlaced PNGs, 5 malformed ones
  and a 257×259 interlaced/plain pair. The generator **decodes every file back
  with libpng** before emitting it, so the pass layout is confirmed by an
  independent implementation rather than by this repository's own understanding
  of Adam7. Coverage includes every color type and depth, sizes from 1×1 to 17×13
  that leave passes empty, odd dimensions, per-pass filter rotation, and an
  illegal filter byte in a later pass. Two rejection vectors are deliberately
  stricter than libpng (exact inflated size, interlace method 2).
- JPEG decoder (`src/assets/jpeg.zig`, re-exported as `corex.assets.jpeg`) and a
  `jpeg` importer (v1) bound to `.jpg`/`.jpeg`, producing the existing `CXTX`
  artifact. Previously those extensions were classified as textures but fell back
  to a verbatim `raw` copy. Supports sequential DCT with Huffman coding
  (`SOF0`/`SOF1`), 8-bit samples, grayscale and YCbCr, any legal sampling factors
  in 1..4 (4:4:4, 4:4:0, 4:2:2, 4:2:0, 4:1:1), 8/16-bit quantization tables,
  arbitrary Huffman tables and restart markers with predictor and bit-buffer
  reset. Progressive, hierarchical, lossless, arithmetic-coded, 12-bit and
  4-component CMYK/YCCK frames are rejected, never partially decoded. Colour
  conversion uses libjpeg's exact fixed-point constants and chroma upsampling
  reproduces libjpeg's fancy triangle filters (including the above/below row
  selection, the +8/+7 rounding asymmetry and the two-sample replication
  fallback), so the only divergence from libjpeg is the inverse DCT, which JPEG
  does not normatively specify: measured worst channel 3 levels and worst mean
  0.199 over the corpus. The bit reader un-stuffs `0xFF00`, skips fill bytes and
  stops at markers without consuming them; a scan that runs out of bytes is
  rejected rather than grey-filled. The IDCT skips all-zero coefficient rows and
  fills DC-only blocks with the 2D gain of 1/8. Component planes are bounded by
  `max_plane_bytes` with overflow-checked arithmetic before any allocation, and
  conversion uses one `3 * width` scratch allocation with no per-pixel ratio
  dispatch. Measured 30.6 ms (4:4:4) and 20.5 ms (4:2:0) for 1024x1024 in
  ReleaseFast.
- JPEG test corpus (`tools/gen_jpeg_vectors.py`, `src/assets/jpeg_vectors.zig`):
  36 vectors encoded by libjpeg with libjpeg's own decode as the reference, 19
  malformed files and 7 valid-but-unsupported ones. The `progressive` vector is a
  genuinely valid progressive JPEG that the generator confirms libjpeg reads, so
  the rejection is proven to be a real format case. Focused unit tests pin the
  paths Pillow cannot emit (4:4:0 upsampling), the rounding biases, the
  replication fallback, odd widths, the DC gain, byte un-stuffing, marker stops,
  sign extension, Huffman over-subscription and colour clamping, plus
  allocation-failure probes over the decoder and the importer.
- FLAC decoder (`src/assets/flac.zig`, re-exported as `corex.assets.flac`) and a
  `flac` importer (v1) bound to `.flac`, producing the existing `CXAW` artifact
  from the same `Audio` type as the WAV path (`docs/asset-flac.md`). Covers the
  whole baseline format: `CONSTANT`/`VERBATIM`/`FIXED` (orders 0..4) and `LPC`
  (orders 1..32) subframes, wasted-bit flags, both Rice residual methods with any
  partition order and escaped raw partitions, 1..8 independent channels plus
  left/side, right/side and mid/side decorrelation, sample sizes 4..32 bits, fixed
  and variable block sizes, every block-size and sample-rate code including the
  explicit forms, UTF-8 coded numbers up to 36 bits, and CRC-8/CRC-16
  verification. `audio.zig` keeps its contract; the only change there is that
  `mapDecodeError` is now public so both decoders share one error mapping.
  `flac.zig` imports `audio.zig` in one direction only and `assets.zig` composes
  `audio.bindings ++ flac.bindings`, so there is no import cycle.
- FLAC memory safety and performance: every field is read through a
  bounds-checked bit reader over the frame's own slice; `i64` sample storage makes
  every predictor and decorrelation step overflow-free by construction, including
  `mid * 2` at 32 bits. Frame boundaries are proved by decoding the subframes and
  checking the CRC-16, never by scanning for the next sync code. One block buffer
  is allocated once and reused, the residual decodes straight into its final
  sample slots, and fixed predictors are comptime-specialized per order. Measured
  7.14 ms for 10 s of 44.1 kHz stereo 16-bit in ReleaseFast (123.5 Msamples/s,
  471 MiB/s of output), about 6.1x a WAV decode of the same PCM. A fused
  unary-plus-remainder bit window was measured and rejected: slower with a byte
  loop, parity with a single load, so the simpler reader was kept.
- FLAC test corpus (`tools/gen_flac_vectors.py`, `src/assets/flac_vectors.zig`):
  72 valid streams with libFLAC's own float32 decode as the reference, compared
  **bit-exactly** because FLAC is lossless, plus 16 malformed streams. The
  generator parses every frame it emits and reports which features the corpus
  actually reaches; that report drove 25 hand-built vectors for paths libFLAC's
  encoder never chooses (mid/side, Rice method 1, partition orders up to 5,
  escaped partitions, LPC orders up to 32, maximum coefficient precision,
  variable block size, rate codes 0/12/13/14). Each crafted stream is decoded
  back by libFLAC before it is emitted. The 12/20/32-bit vectors are anchored to
  power-of-two-scaled 16/24-bit streams because libsndfile only exposes 8/16/24.
  Unit tests pin the CRC check values, UTF-8 widths and over-long rejections, bit
  reader bounds, sign extension, bounded unary runs, all fixed predictors, all
  decorrelation modes, 32-bit mid/side extremes, wasted-bit `k-1` coding and the
  header tables; a sweep decodes every proper prefix of a valid stream to prove
  no truncation can trap. Allocation-failure probes and an end-to-end
  pipeline/registry/cache/snapshot-key test complete the coverage.
- CPU software rasterizer (`src/render/raster.zig`, re-exported as
  `corex.render.raster`, `docs/render-raster.md`): the first stage that produces
  pixels. Clip-space Sutherland-Hodgman clipping against all six frustum planes,
  perspective divide, Y-flipped viewport transform, 28.4 fixed-point integer edge
  functions with a top-left fill rule, backface culling, and an `f32` NDC depth
  buffer with independent test/write flags. Caller-owned RGBA8 + depth buffers,
  flat-color or texture-mapped shading, and a duck-typed mesh/material provider so
  `render` keeps no dependency on the asset layer. The pixel path takes no
  allocator and uses only fixed stack scratch. Not a renderer tier: no
  antialiasing or GPU path (lighting and blending were added on top, below).
- Rasterizer benchmark harness (`tools/bench_raster.zig`, run with
  `zig build bench -Doptimize=ReleaseFast`; not executed by CI or the default
  build). The textured-shading path is now measured (nearest ~3.3x and bilinear
  ~9.1x flat fill cost at 1024x1024 on a two-vCPU Xeon @ 2.60GHz) and documented
  in `docs/render-raster.md`, which previously noted the path as unprofiled.
- Texture-mapped shading in the CPU rasterizer (`Texture`, `Filter` in
  `src/render/raster.zig`): perspective-correct UV interpolation (`uw = u/w`,
  `vw = v/w`, `w_inv = 1/w` carried in clip space and through clipping, f64
  evaluation with a pinned operation order), repeat wrap (floor semantics,
  negative UVs supported), nearest and bilinear magnification with the pinned
  `tx = uf*n - 0.5` bilinear origin, RGBA8 multiply by the material's linear
  tint (`floor(t*n/255 + 0.5)`), and alpha written verbatim. The optional
  `texture()` method on the duck-typed `resources` is detected at comptime via
  `@hasDecl` (it must be `pub`); a material resolving a texture against a mesh
  without (or a mismatched) `uvs` is skipped and counted in `skipped_draws`,
  while a malformed texture is a hard `error.InvalidTexture`. `Mesh` carries an
  optional `uvs: []const [2]f32`; texture-less callers are byte-identical to
  before. Verified by 44 reference frames in
  `src/render/raster_texture_vectors.zig` (generated by
  `tools/gen_raster_texture_vectors.py`, bit-exact RGBA including alpha) plus
  unit tests for sampling, tint multiply, degenerate `w` gradients, error
  paths and skip semantics.
- Directional Lambert lighting in the CPU rasterizer (`Light` in
  `src/render/raster.zig`, re-exported as `corex.render.RasterLight`):
  per-face shading of both the flat and the textured path with a single
  directional light. The raw world-space face normal is computed from the
  world-space positions (`world * position` in `f64`, cross product), normalized
  in `f64`; the per-channel multiplier `ambient + max(0, n . l) * color` is
  applied unclamped (HDR-legal) and clamps once at the final byte quantize
  (`floor(min(max(s, 0), 255) + 0.5)`). Alpha is never lit. Lighting is
  configured with `Options.light`, or via an optional `pub fn
  directionalLight(self) ?Light` on the duck-typed `resources` (detected at
  comptime like `texture()`); an explicit `Options.light` wins. A malformed
  light (zero-length/non-finite direction, or any negative/non-finite color or
  ambient channel) is a hard `error.InvalidLight` at the `drawMesh` entry,
  before any draw. Verified by 40 lit reference frames in
  `src/render/raster_light_vectors.zig` (generated by
  `tools/gen_raster_light_vectors.py`, bit-exact RGBA including alpha) plus
  unit tests for validation, facing-away and perpendicular faces, the
  world-transform normal path, provider priority and error paths. Callers
  without a light are byte-identical to before.
- Rasterizer reference corpus (`src/render/raster_vectors.zig`, 73 cases, 866
  covered pixels) generated by `tools/gen_raster_vectors.py`. The Python reference
  recomputes every edge function per pixel with arbitrary-precision integers and
  no bounding box, so it validates the incremental stepping and bbox clamp
  independently; coverage masks and `f32` depth bit patterns match exactly in all
  three optimization modes. A watertightness property test proves shared edges are
  covered exactly once across ten subpixel-perturbed quad splits.
- Cross-layer test proving a rendered frame round-trips through the QOI codec
  unchanged (`src/render/raster_image_test.zig`), wiring scene extraction to image
  encoding at the composition root. A second case covers a textured render
  (nearest-filtered 4x4 sample, material tint multiply on both the near and far
  quads, QOI roundtrip) so the texture path is proven across scene, extraction,
  rasterizer and codec. A third series of cases covers the directional Lambert
  path the same way (`raster_image_test.zig`): the `directionalLight()` provider
  shades the extracted frame (full diffuse, ambient-only and oblique dots
  pinned per channel), a 180-degree world rotation faces the quad away from
  the light (ambient-only with culling off; culled under the default
  back-face rule), and an explicit `Options.light` wins over the provider
  through the full scene -> extraction -> rasterizer path.
- Scene streaming (`src/scene/stream.zig`, re-exported as `corex.scene.stream`
  with `corex.scene.EngineStream`, `docs/scene-streaming.md`) and a `stream`
  importer (v1) bound to `.corexstream`. A versioned, strict manifest lists named
  sectors, each pointing at an ordinary `.scene` document with a spherical volume
  and a separate, larger unload radius. Sectors load and unload explicitly or from
  a listener position, with hysteresis so a listener on the boundary cannot thrash,
  per-call load/unload budgets, a resident-entity ceiling, pinned sectors, and a
  `pending` flag when a budget leaves work. Manifests are canonicalized in name
  order, so serialize and re-import are byte-stable. Sector payloads reuse
  `Scene.load` and `Scene.cloneSubtree`; there is no second scene format.
- Two additive scene primitives, with no change to existing behaviour:
  `Scene.destroySet(ids)` removes a sorted ID set in one pass, reparenting
  survivors to the nearest surviving ancestor exactly as repeated `destroyEntity`
  would (proved by a differential test over a dozen subset shapes). It **does not
  allocate and cannot fail**: membership is a binary search over the caller's
  slice and ancestor resolution is memoized by path-compressing the doomed
  records' own `parent` fields. `Scene.nextStableId()` exposes the monotonic ID
  frontier so a bulk operation can capture the exact set it created as a
  half-open range without allocating.
- Streaming safety and performance: ownership is captured allocation-free from the
  ID range, so a failed load rolls back exactly even when the allocator is what
  failed; allocation-failure probes assert a failed load leaves the entity count,
  residency map, ownership index and accounting untouched. Unloading 40,000 of
  80,000 entities takes 17.8 ms versus 24.1 s for the one-at-a-time equivalent
  (1358x), because the batch is O(records log ids) instead of O(records * ids).
  A 10,000-entity sector loads in 15.4 ms and unloads in 1.24 ms in ReleaseFast.
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
  float and Ogg/MP3/Opus/AIFF remain unsupported (rejected or `raw`); FLAC is
  supported by its own decoder.
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
  111-193x real time. Delay and reverb were added on top (below); convolution,
  lookahead limiting, oversampled saturation, side-chain and per-voice inserts
  remain planned.
- Oversampled saturation and true-peak limiting (`src/audio/effects.zig`:
  `Saturator`/`SaturatorParams`, `Effect.saturator`, `LimiterParams.true_peak`,
  `docs/audio-effects.md`). Both share one polyphase oversampling core built at
  **comptime** from `resample.prototype` — the same Blackman-windowed sinc the
  band-limited resampler uses, now exported so the two can never drift apart.
  No table allocation, no init cost, coefficients in read-only memory.
  Phase 0 of the interpolator is built as an exact delta (`sin(pi*k)` is only
  ~1e-35 in float). The decimator uses an **odd** length so it is exactly
  linear-phase with a whole-frame group delay; the even-length first attempt was
  asymmetric by an eighth of a high-rate sample and a symmetry test caught it.
  Histories mirror every write into a second copy of the buffer, so each dot
  product runs over a contiguous, vectorizable slice instead of paying for
  modular indexing. The saturator needs **no borrowed buffer at all** — 1120
  bytes of inline state, independent of block size — and taps its dry path out of
  the input history at exactly the 11-frame round-trip delay, so `mix < 1` never
  comb-filters. Measured on a hard-driven 5 kHz tone: the far aliases (3 and
  13 kHz) drop by more than 34 dB, while the 5th harmonic at 25 kHz sits one kHz
  above the 24 kHz cutoff and is only partly suppressed (~8 dB) — no practical
  filter separates those, and the test pins both halves of that claim. 4x
  measures within a few percent of 2x at ~40% more cost, so **2x is the default**.
  `true_peak` makes the limiter measure the reconstructed waveform at 4x as
  ITU-R BS.1770 specifies; the audio is delayed by the interpolator's extra 5
  frames so the emitted sample stays inside the detector window and the ceiling
  guarantee is unchanged, including at zero lookahead. Off by default and
  bit-identical when off. Cost: master saturator 2x +196%, true-peak adds ~a third
  to the limiter, and a full drive chain still runs at 74x real time.
- Fixed: `Mixer.validateEffect` returned early when an effect borrowed no buffer,
  skipping the instance-identity check. The saturator is the first effect with an
  instance but no buffer, so it could be inserted into two slots and have its
  histories advanced twice per sample. Identity and buffer overlap are now
  independent claims, and a regression test covers the bufferless case.
- Lookahead brickwall limiter (`src/audio/effects.zig`: `Limiter`/`LimiterParams`,
  `Effect.limiter`, `docs/audio-effects.md`). The detector runs on the input while
  the audio is delayed by the same amount, so the gain is already down when a
  transient reaches the output. The window maximum uses a **sliding-window
  aggregation over two stacks**: each entry is two f32 (value plus the running
  maximum below it), the window maximum is the larger of the two aggregates, and
  entries move at most once, giving **O(1) amortized** — about two comparisons per
  sample. That f32-only layout is deliberate: it lets the detector share the same
  borrowed buffer as the delay lines, where a monotonic deque's integer expiry
  stamps would need an alignment cast the borrowed-memory contract does not allow.
  The gain is `min(target, recovery)`, so overshoot is impossible rather than
  unlikely: the `min` also stops a *recovering* envelope from climbing past a
  target that is still below unity between two peaks. The release state is the
  **distance from unity**, not the gain — accumulating towards 1.0 with
  `env*r + (1-r)` stalls ~7e-5 short in f32 because the increment falls under half
  an ulp, which would leave the limiter attenuating by a hair forever; decaying
  the distance keeps full relative precision and lands on **bit-exact unity**, so
  a quiet mix passes through unchanged. Channels are peak-linked so limiting never
  shifts the stereo image. `latencyFrames()` reports the added delay and
  `gainReductionDb()` the current reduction. Memory follows the same borrowed
  contract (3.8 KiB for 5 ms stereo at 48 kHz, 15 KiB for 20 ms) and the same
  aliasing/overlap/layout checks. Measured cost is **flat in the lookahead**
  (0 ms and 20 ms identical, ~+17% over baseline for a master insert), and four
  full-scale voices that clip an unprotected mixer produce zero clipped samples
  with the limiter engaged. Sample-peak only: true-peak detection needs
  oversampling, and as an insert it runs before `master_gain` (planned).
- Delay-based insert effects (`src/audio/effects.zig`: `Delay`/`DelayParams`,
  `Reverb`/`ReverbParams`, `Effect.delay`/`Effect.reverb`,
  `docs/audio-effects.md`): a feedback delay with an optional one-pole low pass
  in the feedback path, and a Freeverb-style reverb — eight parallel damped comb
  filters into four series diffusion sections per channel, with a 23-sample stereo
  spread so the tails decorrelate. The diffusion sections use Freeverb's form
  (`H(z) = (z^-N - 1)/(1 - g*z^-N)`), whose DC null is deliberate: the combs have a
  DC gain above 13x at maximum room size, and a flat-magnitude all pass would let
  an impulse build a slow low-frequency rumble. Both the null and the bounded
  shelving response are tested. Comb/diffusion lengths are the classic 44.1 kHz
  tunings scaled to the running rate; comb feedback is capped at 0.98, which keeps
  the network bounded even with damping disabled (asserted over a one-second
  impulse response). Delay lines **flush on write**, so a long tail becomes exact
  zeros instead of crawling through the denormal range for seconds.
  The memory is **borrowed from the caller**, exactly like clip samples:
  `requiredSamples` reports the size (108 KiB for a stereo reverb at 48 kHz),
  `init` carves the lines out of the buffer, and the effect keeps a slice. The
  mixer therefore allocates **nothing** for a reverb and `render` stays
  allocation-free. `Effect.Kind` holds `*Delay`/`*Reverb` rather than inlining
  752 bytes of line state into every insert slot, so `Effect` stays 48 bytes
  instead of growing every slot on every bus.
  New insert-time checks reject a layout mismatch, the same instance in two
  slots, and buffers that overlap even partially — all silent-corruption cases
  rather than crashes; replacing the holding slot is allowed and clearing a bus
  releases the claim. Measured on 64 looping stereo voices at unity rate:
  a 120 ms delay on one of eight buses +15%, on all eight +79%, a master reverb
  +66%, and a full chain of eight delays + eight high passes + master reverb +
  compressor still runs at 103x real time. No chorus/flanger, fractional delay
  taps, convolution or reverb presets yet (planned).
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
  band-limited resampling, insert DSP including delay/reverb/limiter/saturator,
  Adam7 interlaced PNG, sequential JPEG, scene streaming and software
  rasterization including blending (651 tests),
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

- Documentation audit of `docs/render-raster.md`: the pipeline now mentions the
  optional per-channel Lambert multiplier applied to the albedo; the provider
  contract documents the optional `directionalLight()` method (`@hasDecl`,
  `pub` required, explicit `Options.light` wins, validation deferred to the
  `drawMesh` entry); the error list includes `InvalidLight`; and the
  performance notes state the lit path is intentionally unbenchmarked. The
  raster-vectors generator (`tools/gen_raster_vectors.py`) is now deterministic
  byte-for-byte: empty and single-element `depths` lists emit exactly what
  `zig fmt` produces, so regenerating the vectors reproduces the committed
  corpus without manual formatting steps.
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
