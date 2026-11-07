# Continuity log — CoreXEngine

Permanent record of real progress, decisions, pending items and the next priority
task. Kept in sync with the code and Git; recovered at the start of every
continuation. Newest cycle first.

## Cycle 2026-11-07 (i) — Editor shell on the GUI foundation

**Diagnosis first.** Window/swapchain re-checked: **still blocked** (no
`/usr/include/X11`, no `pkg-config`, no `Xvfb`, `DISPLAY` empty) — not attempted. The
queued next priority was the graphical editor shell over the GUI foundation merged in
cycle (h). Everything an editor *does* with pixels before it can edit anything — docks,
a hierarchy, a viewport showing the rendered scene, an inspector, a status bar — is
headless and verifiable, so that is the coherent step; the editing model (undo, dirty
tracking, save) is a separate, larger change and was **not** bolted on.

**Delivered (validated):**

- **`editor/shell.zig`** (`corex.editor.shell`) — `Dock.compute` splits the canvas into
  hierarchy / viewport / inspector / status with no gap or overlap, admitting a panel
  only when a ≥60 px viewport still fits (both → hierarchy only → neither). `draw(ctx,
  state, scene, frame) -> bool` paints a whole frame and reports selection changes;
  it borrows the scene, renderer and surface and owns none of them.
- **Hierarchy** — depth-first, indented, clickable rows keyed by stable entity ID, bounded
  by `State.rows_per_frame`.
- **`Scene.childIdsInto(parent, out)`** (new, `src/scene/scene.zig`) — allocation-free,
  ascending stable IDs, never overflows `out`, keeps the smallest IDs on a full buffer.
  `Scene.rootIds` is now defined in terms of it, so the two cannot drift.
- **`Canvas.blitScaled(dst, src, w, h)`** (new, `src/gui/canvas.zig`) — nearest-neighbour
  scaled blit clipped to destination and canvas; this is how the rendered frame fills
  the viewport.
- **`shell.projectToViewport`** — world point → viewport pixel through the renderer's own
  `view_projection`; rejects `w <= 0` and points outside the clip volume instead of
  dividing through.
- **Inspector** — read-only: name, stable ID, transform, renderable handles, camera fov,
  parent, clipped per column.
- **Status bar** — project, scene, commands, draws, pixels, viewport size, all from the
  renderer's report.
- **`tools/editor_frame.zig`** + `zig build editor-frame -- <project> out.qoi [id]` — the
  documented startup pipeline, one real rendered frame, the editor painted around it,
  written as QOI. This is the editor's smoke test and its visual reference.

**Decisions:**

- **The shell borrows, never owns.** Scene, renderer and surface belong to the caller, so
  the same `draw` serves a headless tool, a test and (later) a window, with no second
  implementation and no per-frame allocation.
- **Read-only inspector.** Editing without undo/redo and dirty tracking would be a stub
  dressed as a feature. It is the next coherent step instead, deliberately.
- **Panel rules favour the viewport.** Dropping the inspector, then the hierarchy, is
  better than a two-pixel viewport; the docks are fixed width because a scaling panel
  makes a text-heavy surface jump.
- **`childIdsInto` replaces the ad-hoc scan.** One bounded, sorted, allocation-free
  primitive serves the tree and `rootIds`, which removes the possibility of the two
  disagreeing.

**Bugs found by validation (mine, fixed):** the status bar used a `·` separator, which
the ASCII-only font renders as `?` — the first render showed it; the inspector's key
column was 34 px while `parent` is 35 px wide, so the value overlaid the key; the dock
rule as first written dropped the inspector at 240 px width because it reserved both
panels before checking; and `childIdsInto` underflowed on a zero-length buffer.

**Suite:** **816/816** (`zig build test --summary all`, cleared cache), `zig fmt --check
src build.zig tools` clean, `zig build` OK, headless smoke and `--mode validate` OK,
`zig build gui-frame` unchanged, `zig build editor-frame` renders 640x360 / 4 entities /
11,344 bytes for the example project.

**Pending:** window/swapchain/vsync + real input (blocked here); GPU backends; editor
**editing** model (undo/redo, dirty tracking, save back to `.scene`), tree scrolling,
asset browser, gizmos, camera controls, resizable/resizable docks, automatic focus
traversal; text shaping/wrapping in the GUI; Lua VM; native module API; export templates.

**Next priority:** the **editor editing model** — a command/undo stack over the scene
plus dirty tracking and selection-safe save — because it is the first thing that turns
the read-only inspector into an editor, and it is headless and fully testable. The window
stays blocked in this sandbox for the same reason as in every prior cycle.

## Cycle 2026-11-07 (h) — Built-in GUI foundation (font, canvas, layout, widgets)

**Diagnosis first.** Window/swapchain re-checked and **still blocked** (no
`/usr/include/X11`, no `pkg-config`, no `Xvfb`, `DISPLAY` empty) — not attempted.
The queued next priority was the GUI library / graphical editor. The editor needs a
GUI, and everything a GUI needs (font, canvas, layout, widgets) is headless and
purely arithmetic, so the foundation is the coherent, fully verifiable step; the
editor itself comes next on top of it.

**Delivered (validated):**

- **`gui/font.zig`** — built-in 8x8 bitmap font, printable ASCII 0x20–0x7E,
  authored on a 6x7 grid inside the cell (`cell_width 6`, `line_height 8`,
  `glyph_height 7`, empty descender row). `measure` is the **advance**
  (`(len-1)*cell_width + inkWidth(last)`), with a trailing space still advancing so
  a padded label does not measure as if the space were absent; `inkWidth` is the
  inked column count; anything outside the table is `'?'`.
- **`gui/text.zig`** — text on a canvas: newlines, integer pixel scale, clip rect,
  and `width`/`height` that agree with `draw`.
- **`gui/canvas.zig`** — `Color` (straight-alpha RGBA8), `Rect` (extent-based,
  non-inverting slices, `containsRect`), allocation-free clipped `Canvas` with
  `fillRect`, `fillOutside`, `strokeRect` (inside the rect), `hline`, `vline`,
  `plot`, `blit`; source-over quantized once per channel, opaque = exact store,
  alpha 0 = exact no-op; `shade` rounds half up.
- **`gui/layout.zig`** — `Size`, `Padding`, a forward-only stacking `Layout` that
  truncates instead of overflowing, and `textSize`. (A `Scroll` helper was written
  first and **removed**: nothing used it, so it was speculative code.)
- **`gui/input.zig`**, **`gui/theme.zig`** — frame input (`endFrame` clears
  one-frame events), and widget colours/metrics in dark and light.
- **`gui/widgets.zig`** — immediate-mode `Context`/`Id`/`Entry`/`Response` and
  `panel`, `label`, `button`, `checkbox`, `slider`, `textField` (caller-owned fixed
  buffer). Pointer ownership is resolved from the **previous** frame's paint order,
  walking the table from the end, so the last-painted (topmost) widget wins a click
  and everything else it covers is `blocked`; `blockBelow` makes a modal block what
  it covers while its own children stay reachable. Clicks fire on release inside the
  pressed widget; sliders follow the pointer outside their row and pin at the ends.
- **`tools/gui_frame.zig`** + `zig build gui-frame -- out.qoi` — renders one frame
  of real widgets headlessly through the existing QOI encoder; preview in the README.

**Decisions:**

- **Own font, own canvas.** A system font/toolkit would be a new external contract
  for the launch and export pipelines to carry; a bitmap table and an RGBA8 buffer
  are data. The buffer is the engine's existing pixel layout, so compositing over a
  rendered frame needs no conversion.
- **Identity is a hash, not a pointer.** `Id.from(seed, name)` keeps hot/active/
  focus stable across frames without retaining widget objects, so there is no
  widget tree and no per-widget allocation.
- **Pointer ownership from the previous frame.** The winner is the last-painted
  widget, which is only known after the frame is built. Using last frame's table is
  exact, allocation-free and deterministic; the cost is one frame of hover latency,
  which a window pipeline pays before its first input anyway. Documented rather than
  hidden.
- **Truncate, never overflow.** `Layout.measure` and every canvas primitive clamp;
  a caller asking for too much loses pixels, never correctness.
- **No speculative widgets.** Only the five an editor sidebar needs today, plus
  panel/label; no tree view, no tabs, no drag-and-drop until the editor needs them.

**Suite:** **805/805** (`zig build test --summary all`, cleared cache), `zig fmt
--check src build.zig tools` clean, `zig build` OK, headless smoke and `--mode
validate` OK, `zig build gui-frame` renders 220x132 / 5 widgets / 3,253 bytes.

**Pending:** window/swapchain/vsync (blocked here); GPU backend; graphical editor on
top of this GUI (layout persistence, dock panels, viewport, gizmos); text shaping
(proportional faces, kerning, non-Latin), wrapping, automatic Tab traversal, a
scrollbar widget, wheel-wired scrolling; Lua VM; native module API; export templates.

**Next priority:** the **graphical editor shell** — dock/panel layout over this GUI,
a scene viewport that blits `raster.Target.color`, and the inspector wired to the ECS
it just displays — still without a window, rendered through `zig build gui-frame`.

## Cycle 2026-11-07 (g) — Conservative occlusion culling in render extraction

**Diagnosis first.** Window/swapchain re-checked and **still blocked** (no
`/usr/include/X11`, no `pkg-config`, no `Xvfb`, `DISPLAY` empty) — not attempted.
The queued next priority was extraction-level occlusion culling / batching, the last
renderer item before GUI/editor. Batching was already covered in the sense that
`by_material` sorts and `RenderFrame` already double-buffers; the open, documented
gap was that extraction could not reject geometry that is *inside* the frustum but
hidden — the wall in front of the room. That is what this cycle closes.

**Delivered (validated):**

- **`render/occlusion.zig`** — `Buffer` (tile depth buffer), `projectAabb`,
  `tileCoverage`, convex hull + point-in-hull. A bound claims a tile only when **all
  four tile corners** are inside the hull of its 8 projected corners, with the
  **maximum** corner depth as the bound; a bound is culled only when **every** tile of
  its conservative screen rectangle is claimed by strictly nearer geometry.
- **`draw.Occlusion`** (+ `OcclusionScratch`, `RenderFrame.refillWithOcclusion`,
  `extractDrawListOcclusion`, `RenderFrame.culled_occluded`) — the pass inside the
  existing extraction, opt-in, reusing one buffer and two queues for the frame's life.
- **`pipeline.FrameParams.occlusion`**, `FrameReport.occlusion_culled`, wired through
  `renderScene` and `EngineRenderer.render` (which now refills with the pass), plus
  `EngineFrameReport.occlusion_culled`.
- **`tools/bench_extract.zig`** + `zig build bench-extract`.

**Measured** (ReleaseFast, best of five, 2,008 renderables = 8 walls × 250 hidden
objects): frustum only **0.404 ms / 2,008 commands**; occlusion 64×36 **0.561 ms /
2 commands** (2,006 culls); 128×72 → 1 command; 32×18 → 4. The pass costs ~0.16 ms
and removes ~99.9% of the draw list in the shape it exists for.

**A real design bug found by validation, in my own first version.** I first claimed
*every* occluder and then tested the commands. That lets a bound be occluded by the
one behind it (its own tiles are already in the buffer) and lets a farther bound
loosen a tile a nearer one had set. The pipeline test — which asserts the pass never
changes a pixel — caught it on a two-quad scene. Fixed by interleaving: sort nearest
first, **test each command, then claim it**, which also makes the result independent
of ECS iteration order.

**Decisions:**

- **Conservative box bounds, not triangle rasterization.** Claiming only fully covered
  tiles from the projected hull keeps the correctness argument one line long and makes
  "byte-identical frames with the pass on or off" provable and tested. A per-triangle
  software depth raster would cull more and cost more; it is a separate, larger change.
- **Opt-in (`null` default).** Same rule as every other quality knob in this project:
  the caller asks. The pass is safe to enable, but it is extra per-frame work on a
  scene with nothing to hide.
- **No temporal reprojection or hierarchical-Z.** Both need frame history and a much
  larger correctness story; the measured win already comes from this one pass. Listed
  as a limitation instead of half-implemented.
- **Grid is a knob, not a contract.** A zero axis is clamped to one tile in
  `Occlusion.sanitized`, so a quality setting cannot turn a frame into an error;
  `occlusion.Buffer` keeps the strict `InvalidGrid` for direct callers.
- Also fixed on the way: `FrameLoop.init` leaked the renderer when `target_fps` was
  invalid (validation now precedes construction, with an `errdefer`).

**Suite:** **761/761** (`zig build test --summary all`, cleared cache), `zig fmt
--check src build.zig tools` clean, `zig build` OK, headless smoke (1 draw, 43,264
px) and `--mode validate` OK.

**Pending:** window/swapchain/vsync (blocked here); GPU backend; per-triangle
occlusion (software depth raster) or hierarchical-Z if the box bounds prove too loose;
batching/LOD; GUI/editor; Lua VM; native module API; export templates.

**Next priority:** the **GUI library / graphical editor** foundation — the last
renderer-adjacent item is done and the editor is the largest remaining headless-
verifiable subsystem (immediate-mode UI with its own tests). The GPU backend stays
blocked in this sandbox for the same reason as the window.

## Cycle 2026-11-07 (f) — Per-material LOD bias and anisotropic tap cap

**Diagnosis first.** Window/swapchain was re-checked and is **still blocked** (no
`/usr/include/X11`, no `pkg-config`, no `Xvfb`, `DISPLAY` empty), so it was not
attempted. The previous cycle left two named follow-ups; the filtering one was taken
because the anisotropic mode shipped with a documented gap — *the footprint decides
the level, but a material knows better* — and because the whole path is headless and
bit-exactly verifiable. Occlusion culling in extraction stays queued.

**The defect this closes.** After cycle (e) the rasterizer could correct a grazing
footprint, but a **material** had no way to say "sample one level sharper" (a
normal-mapped surface, a UI element that must stay crisp) or "cap the taps for this
draw" (the same scene, a cheaper tier of quality). Both are the two knobs a real
renderer exposes, and both are absent from the docs' limitation list before now.

**Delivered (validated):**

- **`raster.Sampling`** (`src/render/raster.zig`), plain data, `Options.sampling`:
  - `lod_bias: f64 = 0.0` — added to the level **after** the selection rule, clamped
    to `[0, levels-1]`. Trilinear goes through the new `textureLodBiased` (still
    hoisted per triangle via `GradSteps.constantLod(..., bias)`); anisotropic shifts
    both `lod_major` and `lod_minor` inside **one** function (`GradSteps.aniso`), so a
    footprint cannot be biased twice and `constantAniso` stays bit-identical to the
    per-pixel path.
  - `max_samples: u8 = 0` — `0` means "the global default" (8), values above 8 clamp
    to 8 (`tapCap()`). It feeds `anisoFootprintCapped`, so it changes **only** the tap
    count: level and axis are untouched. `max_samples = 1` is therefore exactly
    `Mipmap.trilinear` — asserted byte for byte on a real frame, which is what makes
    the cap a time/quality knob rather than a second filter.
  - `Sampling{}` is the identity, `isIdentity()` is an exact comparison, and an
    untextured or `.level0` draw is unaffected: every pre-existing frame is
    reproduced byte for byte (the 97 pre-existing reference frames were re-generated
    and compared, unchanged).
- **Contract layer:** `Capabilities.sampling_controls` (medium/advanced; Low has no
  textures at all), `FrameOptions.sampling`, `DrawResources.samplingFn` +
  `sampling(handle)`, the `fromComptime` adapter behind `@hasDecl` (a private decl
  stays invisible; absent means null, no invented default) and per-material
  resolution in `drawFn` before any pixel. `pipeline.FrameParams.sampling` forwards
  into the options; `resolve` zeroes it when the tier lacks the capability.
- **Verification:** the generator gained `texture_lod_biased`, `apply_bias`, a
  `tap_cap` on `aniso_footprint` and `bias`/`tap_cap` on `shade`/`rasterize`;
  **18 new cases** (identity, ±bias on trilinear/anisotropic/perspective, both
  clamps, caps 1/2/3/4, six random pairs) bring the corpus to **116 frames /
  1,851 covered pixels**, all bit-exact. 8 new Zig tests (**749/749**) cover
  `tapCap`/`isIdentity`, the bias direction and clamps, the cap's
  level-invariance, both `GradSteps` paths, the pixel-level proof that a bias and a
  cap reach the frame (and that cap 1 equals trilinear), the provider adapter and
  the tier coercion.

**One real bug found while validating, in my own first attempt:** the generator's
per-pixel top-left tie-break was a local named `bias`, which shadowed and then
overwrote the new sampling `bias` parameter inside `rasterize`. Nine pre-existing
reference frames silently changed. Caught by regenerating with the old generator and
diffing byte for byte (all 97 must be unchanged); fixed by renaming the local to
`edge_bias` with a comment, and the "identity reproduces the old frames" property is
now pinned by a dedicated vector case as well as by the diff.

**Decisions:**

- **Two scalar fields on a `Sampling` struct, not a per-`Renderable` field.** The
  previous cycle's plan mentioned threading it through extraction; that would have
  put a renderer knob on the scene contract and forced every command to carry it.
  A frame default plus a per-material provider hook matches how the other optional
  per-material properties (`texture`, `color`) already work, and leaves extraction
  untouched.
- **Bias after the rule, in one place.** Applying it inside `anisoFootprint` *and*
  the caller (or to `lod_major` before deriving `lod_minor`) double-counts. Both
  modes bias exactly once, and the tests compare against `textureLodBiased` and the
  uncapped footprint rather than against themselves.
- **Quality loss, never a refusal.** A tier without `sampling_controls` renders the
  uncorrected level (same rule as anisotropic → trilinear). A cap is a cost knob and
  a bias is a look knob; neither is a capability a frame can be missing.
- **`max_samples = 0` means default, not zero.** A cap of zero taps would mean "do
  not sample", which is not a thing a draw may ask for. Documented on the field.
- Counts in this entry come from a **cleared cache** (`.zig-cache` removed), after the
  stale-binary trap of cycle (e).

**Measured cost of the cap** (`zig build bench -Doptimize=ReleaseFast`, same grazing
draw, best of five): 1024² `graze_aniso` 216.2 ms at the default 8 taps →
**131.7 ms at cap 4 (−39%)** → 42.8 ms at cap 1, which is the trilinear image bit
for bit. 512²: 52.6 → 34.6 (−34%). The saving tracks the tap count, which is what
makes the cap a real knob rather than a flag. `tools/bench_raster.zig` now prints
`graze_cap4`/`graze_cap1` so the claim stays measured, not asserted.

**Suite:** **749/749** (`zig build test --summary all`, clean cache), `zig fmt
--check src build.zig tools` clean, `zig build` OK, headless smoke
(`--headless --frames 2`: 1 draw, 43,264 pixels) and `--mode validate` OK.

**Pending:** window/swapchain/vsync (blocked here); `CXTX` mip levels authored at
build time; sRGB transfer; a weighted (non-uniform) tap kernel; per-material level
*clamp* (both ends); extraction-side occlusion culling / batching; GPU backend;
input/event loop; GUI/editor.

**Next priority:** extraction-level **occlusion culling / batching** (`render/culling.zig`
already has `Frustum`, `classifyAabb`, `classifySphere`, `transformAabb` as the
read-only groundwork) — headless, benchmarkable, and the last renderer item before
the GUI/editor work.

## Cycle 2026-11-07 (e) — Anisotropic minification in the software rasterizer

**Diagnosis first.** The window + swapchain backend was re-checked and is **still
blocked** (no `/usr/include/X11`, no `libX11.so` dev symlink, no `pkg-config`, no
`Xvfb`, `DISPLAY`/`WAYLAND_DISPLAY` empty), so it was not attempted. Of the two
headless-verifiable candidates recorded last cycle (material batching in extraction,
rasterizer filtering quality), the rasterizer was taken: extraction's `by_material`
already sorts, so batching there would be a benchmark-driven change with no contract
gain, while the filtering gap is a documented *quality* limitation with a **measured**
claim to make.

**The defect this closes.** `textureLod` takes `max` of the four gradient components,
so the level follows the pixel footprint's **long** axis and over-blurs its short one.
A floor receding to the horizon therefore loses detail it could still resolve, and the
docs said so plainly ("no anisotropic filtering … over-blurs grazing angles"). This
cycle makes that a mode instead of a limitation.

**Delivered (validated):**

- **`raster.Mipmap.anisotropic`** (+ helpers `AnisoFootprint`, `anisoFootprint`,
  `sampleAnisotropic`, `texelDerivatives`, `max_aniso_samples = 8`,
  `max_aniso_ratio = 8`):
  - The footprint is the Jacobian's two screen-axis columns; the **longer** one is the
    long axis (its length is the same quantity `textureLod` uses) and the ratio of the
    lengths is the anisotropy.
  - `samples = ceil(clamp(aniso, 1, 8))`, `lod_minor = max(lod_major - log2(aniso), 0)`.
    Taps sit at `(i - (n-1)/2)/n` pixels along the unit long axis, each a trilinear
    sample at `lod_minor`, averaged channel-wise in `f64` with **one final round**.
  - **A round footprint is bit-identical to trilinear** (one tap); the constant
    denominator case hoists the whole tap pattern to once per triangle
    (`GradSteps.constantAniso`), so the orthographic/affine case pays nothing extra.
- **Contract:** `Tier::capabilities.anisotropic` (Medium, Advanced; Low has no textures)
  and `pipeline.resolve` coerces the mode to `.trilinear` where the tier lacks it — a
  quality loss, not a wrong frame. `Mipmap.anisotropic` is the additive enum case;
  `.trilinear` stays the default so nothing changes for existing callers.
- **Reference vectors:** the Python generator reimplements the footprint, the tap
  pattern and the averaging independently. **17 new cases** — grazing, the 8:1 clamp,
  a symmetric one that must equal the trilinear frame, mild 2:1, a smaller base, a
  perspective case, and ten deterministic random grazing triangles — take the texture
  corpus from 78 to **97 frames / 1390 covered pixels**, all bit-exact.
  `tools/gen_raster_texture_vectors.py` is reproducible.
- **Unit tests:** the footprint's tap count / axis / levels (round, 2:1, the 8:1 clamp,
  the axis flipping to y for a vertically elongated footprint, the level never going
  below 0), `sampleAnisotropic` reducing to `sampleTrilinear` at one tap, the averaging
  of taps, and — the claim itself, measured — a grazing quad rendered both ways where
  the anisotropic frame keeps **more than twice** the neighbouring-pixel detail.
- **Benchmark:** `tools/bench_raster.zig` gained `minify_aniso`, `graze_tri` and
  `graze_aniso`.

**Measured** (`ReleaseFast`, best of five, 1024 quads, x86-64):

| Target | trilinear (round) | aniso (round) | trilinear (grazing) | aniso (grazing) |
| --- | --- | --- | --- | --- |
| 256² | 2.530 ms | 2.607 ms | 2.708 ms | 11.691 ms (~4.3×) |
| 512² | 9.492 ms | 9.627 ms | 10.284 ms | 46.016 ms (~4.5×) |
| 1024² | 36.752 ms | 36.427 ms | 36.961 ms | 180.490 ms (~4.9×) |

Suite: **741/741** (was 734; 7 new), `zig fmt --check src tools build.zig` clean.

**Merged:** PR **#51** → `main` `8b1c2ec`, CI green (`Build & test (Zig 0.17.0)`, 31 s).
Post-merge re-test on `main` in a clean worktree with a cleared cache: **741/741**,
`zig fmt --check` clean, `zig build` OK, headless smoke prints the assets and frame
lines unchanged.

**Two bugs found while validating, both in my own first attempt:**

1. I first took the long axis from the *x* column unconditionally and the anisotropy
   ratio from the difference of the two column lengths, so a vertically elongated
   footprint reported **one** tap and a 4:1 horizontal error. The kernel is now
   explicitly "the longer Jacobian column, by length, and the ratio of the two
   lengths"; the unit test that caught it stayed.
2. A first fixture for the one-tap test declared `1x2` below `2x2`, which
   `Texture.validate` correctly rejected. The fixture was wrong, not the validator —
   fixed the fixture.
3. A stale `.zig-cache` binary made the suite look green at 734 while the real count
   was 740. Cache was cleared and the counts in this log come from a clean build.

**Decisions:**

- **Opt-in enum case, not a default.** `Mipmap.trilinear` stays the default: the
  grazing case costs ~5x, and silently making every textured draw pay it would be a
  regression pretending to be a feature.
- **Tap count from the ratio, not a fixed 8.** A round footprint must not spend eight
  taps to reproduce the single-tap answer, which is why the round case measures as
  free. The clamp at 8:1 caps the worst case.
- **Explicitly `length`-based axis, not eigen-decomposition.** The exact minor axis
  would need the full singular-value decomposition per pixel; the two-column
  approximation is what the LOD already assumes, is cheap, and is exactly
  reproducible by the reference generator — which is what makes bit-exactness
  possible at all. Documented, with the sub-pixel edge overshoot and the uniform
  tap weighting listed as limitations.
- Coercion lives in `pipeline.resolve` (where every other "asked for X, got Y" rule
  lives), not as a `beginFrame` rejection: a quality refinement must never turn a
  frame into an error.

**Pending:** window/swapchain/vsync (blocked here); `CXTX` levels at authoring time;
per-material LOD bias and a per-material tap cap; sRGB transfer; GPU backend;
input/event loop; GUI/editor.

**Next priority:** the window + swapchain + vsync backend where a display and its dev
headers exist. Still blocked here, so the next verifiable step is **per-material LOD
bias and tap-count cap** (a `Renderable` material parameter threaded through extraction
into `drawMeshAlloc`), or **occlusion culling / batching** in extraction — both
headless and both continuations of work already in flight.

## Cycle 2026-11-07 (d) — Asset upload (mip chains) and eviction

**Diagnosis first.** The logged next priority was the window + swapchain backend.
Re-checked this cycle and **still blocked**: no `/usr/include/X11`, no `libX11.so`
dev symlink, no `pkg-config`, no `Xvfb`, `DISPLAY`/`WAYLAND_DISPLAY` empty. Writing a
window backend here would be unvalidated speculative code, so it was not attempted and
the block is reported again. The next verifiable item on the roadmap was taken instead:
the pending "asset upload/eviction and CXTX mips" entry.

**What the code actually showed (three real defects, not a wish list):**

1. `loadAssets` kept **every source file's bytes alive for the whole session** in
   `blobs`, even though a mesh is copied into the table's own scratch and a texture's
   pixels are read through a separate allocation. The bytes had no reader after upload.
2. Textures were uploaded with **no mip chain**, while `FrameParams.mipmap` defaults to
   `.trilinear` and Medium declares `mipmaps` — so minification aliased and the tier
   capability was decorative. `render.mipmap` already existed and was unused by the
   loader.
3. **Eviction did not exist.** `ResourceTable.release` existed but nothing in the asset
   path called it, `LoadedAssets.handleOf` hard-coded `generation = 1`, and `release`
   did not bump generations itself — so a slot released and refilled could resurrect old
   handles, and a handle rebuilt from a slot index was wrong by construction.

**Delivered (validated):**

- **Mip chains at upload** (`render_scene.loadAssets` + `generateMips`): each texture
  gets a chain built by `render.mipmap.Chain.generate` (integer box filter,
  deterministic), owned as a whole `Chain` in `LoadedAssets.mip_chains`, borrowed by the
  table as `raster.MipLevel`s. A 1x1 texture generates nothing (`mipmapped` stays 0 and
  no allocation happens). Tests pin the **values** of the 4x4 → 2x2 → 1x1 levels and run
  `Texture.validate()` on the result, so a chain that does not halve correctly fails.
- **Source bytes released at upload**: `defer gpa.free(bytes)` per file; the table owns
  a level-0 copy plus its chain. Measured on a test project with an 8x8 PNG:
  `Assets uploaded: 1 meshes, 1 textures (1 mipmapped), 0 skipped, 484 bytes`
  (144 mesh + 256 + 64 + 16 + 4), not the file sizes.
- **`AssetTable.uploadedBytes()`**: the footprint the renderer holds — the scratch
  copied for meshes plus every texture level it borrows — computed from liveness, so it
  drops to 0 for an evicted slot instead of being an estimate. Printed by the binary
  next to the skip count.
- **`LoadedAssets.evict(path)`**: releases the slot and `gpa.free`s the pixel block and
  the chain. The path keeps its slot (the layout is a property of the project), but the
  slot stops resolving. Idempotent: a second call returns false and does not count.
  `AssetReport` gained `evicted` and `mipmapped`.
- **`ResourceTable.release` bumps every kind's generation itself** (and is a no-op on an
  already-free slot), plus `ResourceTable.handleOf(slot, kind)` / `isLive` and
  `AssetTable.handleOf`/`isLive`/`release`. `LoadedAssets.handleOf` now reads the
  table's handle and only falls back to the load-time generation 1 for a
  planned-but-empty slot — the case a `.scene` depends on, since a broken or evicted
  file must not invalidate the handles of its neighbours.
- 6 new tests (734 total): mip chain values + `validate`, the 1x1 case, eviction
  (memory freed, handles dead, idempotent, layout stable, reload gives the same bits),
  `release` generation invariants (including that two releases do not churn them), and
  `uploadedBytes` arithmetic before/after eviction.

**Decisions:**

- **Eviction is explicit, not automatic.** There is no budget, no LRU and no residency
  policy, because there is no GPU: "upload" is a copy into CPU scratch, and an
  automatic policy over CPU memory would evict assets the frame is about to draw. The
  honest shape is a call the caller owns; a budget becomes meaningful when a swapchain
  and a GPU backend exist.
- **`release` bumps the generation, not the next `set*` alone.** Two independent
  bumpers would make generations depend on the order of operations; one owner (the
  release) plus the existing store bump is what the handle contract needs.
- **Mips are generated at upload, not stored in `CXTX`.** The artifact format is a
  documented contract and bumping it would invalidate every cached artifact for a chain
  that the deterministic integer filter reproduces exactly. `docs/render-backend.md`
  says so explicitly.
- `LoadedAssets.handleOf` keeps returning a resolvable-looking bits value for a planned
  but empty slot rather than null, because a stored `.scene` cannot be rewritten when
  one asset in the project fails; the handle simply resolves to nothing. The existing
  test for that behaviour caught my first attempt to return null.

**Measured:** `ReleaseFast`, `--frames 20 --fps 60` on the texture project: 0 late,
16.574 ms/frame, `Assets uploaded: … 484 bytes`; Debug suite **734/734**; `zig build`
OK; `zig fmt --check` clean.

**Merged:** PR **#49** → `main` `657bd0b`, CI green (`Build & test (Zig 0.17.0)`, 22 s).
Post-merge re-test on `main` in a clean worktree: **734/734**, `zig fmt --check` clean,
`zig build` OK, `--frames 5` → `Assets uploaded: 1 meshes, 0 textures (0 mipmapped), 0
skipped, 144 bytes` and the frame line unchanged.

**Pending:** window/surface backend, swapchain, vsync (still blocked here); a texture
budget / automatic residency policy once a GPU backend exists; `CXTX` levels if
authoring-time mips ever beat the deterministic filter; input/event loop; GUI/editor.

**Next priority:** the window + swapchain + vsync backend, in an environment with a
display and its dev headers. Still blocked here, so the next verifiable step is the one
behind it: **scaling/presentation of the finished surface** (nearest/bilinear upscale
from the render size to the window size) is window-dependent too, so the verifiable
candidate is instead **draw-list batching by material** in extraction, or **texture
filtering quality work** in the rasterizer (both testable headless).

## Cycle 2026-11-07 (c) — Frame pacing (`target_fps`) and frame timing statistics

**Diagnosis first (the logged next priority was not implementable here).** Cycle (b)
recorded "next priority: a window + swapchain backend". That was checked before it was
attempted, and it cannot be done or validated in this environment:

| Requirement | Present? |
|---|---|
| X11 headers (`/usr/include/X11`) | **no** |
| `libX11.so` linker symlink | **no** (`libX11.so.6` only) |
| `pkg-config` | **no** |
| `DISPLAY` / `WAYLAND_DISPLAY` | empty |
| `Xvfb` | **no** |
| ALSA headers (`/usr/include/alsa`) | **no** |

Writing a window backend here would be speculative code that no test, no smoke run and
no CI job could exercise — exactly what the working rules forbid. Per the standing
"if blocked, stop and present the diagnosis" rule, the window was **not** attempted.
Instead the second half of the logged pending item was taken, because it is fully
verifiable end to end without a display: `target_fps` pacing plus frame timing
statistics.

**Delivered (validated):**

- `src/runtime/pacing.zig` (new, `corex.runtime.pacing`, 6 tests): `Pacer` +
  `FramePacing{work_ns, slept_ns, late}`.
  - Budget is the integer reciprocal `1e9 / fps` — 60 fps is exactly `16_666_666 ns`,
    the documented rate rather than an approximation (a test asserts the number).
  - Deadline is anchored to `previous_deadline + budget`, so timer overshoot is repaid
    by the next frame instead of accumulating into a loop that slowly runs below its
    requested rate.
  - A frame that overruns its budget never sleeps, is counted (`late_frames`) and
    re-anchors on the instant it actually ended. Getting this wrong is subtle:
    re-anchoring one budget *past* the overrun hands the next frame two budgets of
    slack and halves the reported late frames. A dedicated test pins it.
  - A wait beyond `max_wait_ns` (1 s) means the deadline is in the wrong epoch (clock
    jump, corrupted budget): re-anchor and count a `resync` instead of hanging.
  - `reschedule()` drops a stale schedule; `FrameLoop.run` calls it so a stall between
    runs cannot produce a catch-up burst.
  - `Pacer.disabled` never reads the clock — the headless default.
  - **Honest scope:** this is a *sleep-based* pacer, not vsync. There is no presentable
    surface, so there is no authoritative "display is ready" signal and the wait cannot
    beat the timer resolution. The deadline it computes is the one a `FIFO` swapchain
    would impose, so the accounting stays valid when one lands; only the mechanism
    changes. Module docs, `docs/presentation.md` and the CHANGELOG all say this.
- `presentation.FrameLoop`: `init(gpa, tier, w, h, target_fps: ?u32)`, `targetFps()`,
  `frame(scene, resources, io: ?Io)`, `run(scene, resources, count, io: ?Io)`;
  `RunReport` gained `slept_ns`, `elapsed_ns`, `late_frames`. `Error` gained
  `InvalidTargetFps` and `Canceled`; a zero rate is refused rather than treated as
  "unpaced". `io == null` renders without touching the clock, which is how the loop
  tests measure work instead of wall-clock time.
- `--fps <n>` in the launch contract (`src/core/cli.zig`, `docs/launch-contract.md`):
  `--fps 0` is a usage error (`error.InvalidFps`, exit 2), not a synonym for unpaced.
  The binary passes `io` and prints, only when paced,
  `Pacing: <fps> fps — <n> late of <n> frames, <n> resyncs, <ms> slept, <ms> elapsed,
  <ms>/frame`. 10 new tests (pacer 6, loop 3, cli 1): **729 total**.

**Measured** (`ReleaseFast`, shipped example, 1280x720, one quad):

```console
$ corex-engine --project examples/hello-project/HelloProject.corex --frames 60 --fps 60
Pacing: 60 fps — 0 late of 60 frames, 0 resyncs, 794.372 ms slept, 993.652 ms elapsed, 16.561 ms/frame
$ corex-engine --project examples/hello-project/HelloProject.corex --frames 60 --fps 120
Pacing: 120 fps — 0 late of 60 frames, 0 resyncs, 297.168 ms slept, 493.491 ms elapsed, 8.225 ms/frame
```

Both rates are held for the whole run. In **Debug** the same 60 fps run reports frames as
late at 1280x720 (the CPU rasterizer is not fast enough in an unoptimized build); that is
the honest behaviour — the frames are still drawn and counted, not slept away.

**Decisions:**

- Pacing is a separate module, not folded into `FrameLoop`: the arithmetic is testable on
  its own, and the loop only sequences it (begin before the work, end after it).
- The budget is computed in integers so `targetFps()` returns exactly the requested rate.
- `settings.json`'s `target_fps` is deliberately **not** consulted by the headless loop:
  with no window there is nothing to pace a displayed image for, so the default stays
  unpaced and `--fps` is the explicit per-run override. Once a windowed loop exists, the
  config value becomes its natural default; nothing else has to change.

**Pending:** window/surface backend, swapchain, real vsync (and then `target_fps` from
`settings.json` as the windowed default), input/event loop, a ring of frame timings for
percentiles.

**Merged:** PR **#47** → `main` `e7769c8`, CI green (`Build & test (Zig 0.17.0)`, 22 s).
Post-merge re-test on `main` in a clean worktree: **729/729**, `zig fmt --check` clean,
`zig build` OK, `--frames 30 --fps 30` → `Pacing: 30 fps — 0 late of 30 frames, 0
resyncs, 129.733 ms slept, 996.802 ms elapsed, 33.227 ms/frame`, `--fps 0` → usage
error (exit 2).

**Next priority:** the same one cycle (b) recorded and this sandbox cannot validate —
window + swapchain + vsync, to be attempted where a display and its dev headers exist.
If it is still blocked, the next verifiable step is **asset upload/eviction** in the
render table (and CXTX mips after it).

## Cycle 2026-11-07 (b) — Presentation: owned frame surface + bounded frame loop

**Delivered (validated):**

- `src/runtime/` (new, `corex.runtime`, `docs/presentation.md`): the presentation layer,
  which was the documented next priority.
  - `presentation.SurfaceTarget` — RGBA8 colour + `f32` depth owned for a whole run.
    `resize` returns whether it reallocated (a loop asking for the same size every frame
    is a comparison, not an allocation) and allocates **both** buffers before replacing
    either, so a failed or rejected resize leaves the previous frame intact and
    renderable. Zero-sized and `> raster.max_dimension` requests are refused: a
    zero-pixel surface is what a minimised window reports and rendering into it would
    make every statistic meaninglessly zero. `clear` is explicit and once per frame.
  - `presentation.FrameLoop` — owns the target, the `EngineRenderer` and one scratch
    arena, and runs `--frames` frames. `RunReport{frames, empty_frames,
    allocating_frames, last}`. A scene with no camera stops the loop instead of
    repeating an answer that cannot change.
  - Finding the camera calls `findCamera`, which resolves a world matrix and therefore
    allocates a transform snapshot. Measured: that was **72 bytes per frame**. The loop
    now owns `camera_scratch`, reset once per frame — the same hand-off `RenderFrame`
    already does, applied one level up.
- `--frames <n>` in the launch contract (`src/core/cli.zig`, `docs/launch-contract.md`):
  bounded runs, default 1 (previous behaviour), `0` rejected as `error.InvalidFrames`
  (exit 2). The binary now uses `FrameLoop` instead of the one-shot
  `renderSceneFrame`, and prints
  `Frames: N of N (N allocating) at WxH <tier> — last frame: …`.
- Docs: new `docs/presentation.md`; `architecture.md` (module map + runtime section +
  independent-runtime status), `render-backend.md` (limitations rewritten),
  `launch-contract.md`, `README.md`, `CHANGELOG.md`.

**Validation:**

- `zig build test --summary all` → **718/718** (clean `.zig-cache`); also green with
  `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast`.
- `zig fmt --check src build.zig` clean; `zig build` OK.
- Headless smoke on the example: `--frames 120` →
  `Frames: 120 of 120 (2 allocating) at 1280x720 medium — last frame: 1 commands,
  1 draws, 0 skipped, 43264 pixels, 0 culled`. `--mode runtime --frames 10` same;
  `--mode validate --frames 5` still prepares no session; `--frames 0` exits 2 with a
  usage message.

**Errors found and fixed:**

- `--frames` accepted a duplicate flag (the other options all reject one). Caught by the
  new CLI test, fixed with an explicit `DuplicateArgument`.
- First `FrameLoop` attempt allocated 72 bytes every frame: camera lookup built a world
  transform snapshot per call. Fixed with the loop's own scratch arena, which is why the
  steady-state test can assert 0 calls.
- The failing-allocator test initially failed on `init` rather than on the resize,
  because the allocator's failure index counted from construction. Restructured to fail
  only the resize, in **both** orders (colour allocation fails, depth allocation fails)
  so the rollback path is covered.
- A duplicated block in `main.zig` was caught before it shipped: the binary now calls
  `FrameLoop.run` and formats its report, instead of re-implementing the loop.

**Decisions:**

- No window/swapchain/vsync/input: they need a platform library and inventing the
  abstraction beforehand would be speculative. The bounded `--frames` count is the honest
  form of "run for a while" while nothing can terminate the loop.
- Clearing stays the caller's call (once per frame) rather than moving into `render`,
  which would add a full-surface pass on frames whose depth is already at the far plane.
- `run` stops on a scene with no camera rather than looping to the count, and reports the
  declined frames as `empty_frames` — it does not pretend to have rendered them.

**Pending:** window/surface backend, swapchain and vsync (then `target_fps` can be
honoured), input/event loop, frame timing statistics.

**Merged:** PR **#45** → `main` `78258ae`, CI green (1 m 56 s). Post-merge re-test on
`main` in a clean worktree: **718/718**, `zig fmt --check` clean, `zig build` OK,
`--frames 120` → `Frames: 120 of 120 (2 allocating) …`, `--mode validate` OK,
`--frames 0` rejected with a usage message.

**Next priority:** a window + swapchain backend that presents the surface the loop
already owns, so the loop becomes visible and can be paced by the real present.

## Cycle 2026-11-07 (a) — Merge cleanup, stale-branch sweep, per-frame allocator hand-off

**Delivered (validated):**

- **Housekeeping requested by the user**, nothing merged blindly:
  - No PR was open (all 42 merged), so nothing to merge.
  - The 12 remaining remote `arena/*` branches were each verified as **merged**
    (`gh pr list --state all --head <branch>` → all `MERGED`) *and* empty against
    `main` (`git diff --stat origin/main..origin/<branch>` → nothing). Deleted all
    12; the remote now holds only `main` (plus this session's branch).
  - `main` (`1e6e71f`, PR #42) re-validated in a separate worktree: **707/707**
    Debug, **707/707** ReleaseFast, `zig fmt --check` clean, `zig build` OK,
    headless smoke prints the frame line, CI green on `main`.
- **Per-frame allocator hand-off** (`src/render/draw.zig`):
  - `RenderFrame` owns a `std.heap.ArenaAllocator` reset once per `refill`
    (`.retain_capacity`), and `extractIntoScratch(out, scene, cam, mode, list_gpa,
    scratch)` splits "the list that survives the frame" from "the snapshot that does
    not". `extractInto` is now the same call with one allocator.
  - `RenderFrame.allocated_last_frame` records whether the frame had to allocate
    (scratch capacity or spare-list capacity grew); `EngineFrameReport.allocated`
    carries it out of `EngineRenderer.render`.
  - `unchanged` (content) and `allocated` (memory) are deliberately **independent**:
    a frame can be content-identical and still allocate once while a buffer grows to
    the size the scene now needs. Conflating them broke an existing test — the test
    was right.
- Docs: CHANGELOG, `render-extraction.md` (where a frame's memory comes from + the
  two consequences), `render-backend.md` (limitations: drive `render`, own the
  surface), this log.

**Validation:**

- `zig build test --summary all` → **708/708** (clean `.zig-cache`); **708/708** with
  `-Doptimize=ReleaseFast`; `zig fmt --check src build.zig` clean; `zig build` OK;
  headless smoke unchanged (`Frame: 1280x720 medium (1 commands, 1 draws, 0 skipped,
  43264 pixels, 0 culled)`).
- New test `RenderFrame: a steady-state frame takes no allocation from the general
  allocator`: a wrapping allocator counts bytes/calls and asserts **0/0** on the
  third refill of an unchanged scene, then grows the scene to 68 renderables and
  confirms it still renders. Second assertion added to the `EngineRenderer` test:
  first frame `allocated == true`, settled frames `allocated == false`.

**Errors found and fixed:**

- The steady-state assertion initially failed with "expected 0, found 2" *by
  design*, not by bug: `refill` extracts into the spare buffer, so both buffers need
  one warm-up pass. The test now warms twice and documents why, which is the honest
  shape of a double-buffered frame.
- First attempt folded "did it allocate" into `unchanged`, which made an existing
  renderer test expect `unchanged == false` on an identical frame. Split into two
  fields — a frame's content and its memory cost are different questions.
- Toolchain: this sandbox had no Zig; installed `ziglang==0.17.1` from PyPI
  (`0.17.0` is yanked/missing its binary). CI still pins 0.17.0 and is green, so the
  engine does not depend on the patch version.

**Merged:** PR **#43** → `main` `e90f1cb`, CI green (1 m 55 s). Post-merge on `main`
in a clean worktree: **708/708**, `zig fmt --check` clean, `zig build` OK, smoke
prints the frame line, `--mode validate` OK.

**Next priority:** presentation — a window + event loop driving
`EngineRenderer.render` with owned colour/depth and the now-implemented per-frame
arena (then asset upload/eviction and CXTX mips).

## Cycle 2026-11-06 (f) — A scene file renders: renderable schema, asset layout, headless frame

**Delivered (validated):**

- `src/scene/render_scene.zig` (new, `corex.scene.render_scene`): the layer that was
  missing between the scene document and the frame pipeline. `EngineScene` carried
  only `transform`, so a `.scene` could not name a mesh and nothing owned a camera.
  - `CameraComponent` (`fov`/`near`/`far`, `isValid`) = the lens; the entity's world
    transform is the position and basis (forward `-Z`), so a camera parents and moves
    like any entity.
  - `EngineRenderScene` / `EngineRenderPrefab`: `transform` + `renderable` + `camera`,
    so the whole document round-trips through the real serializer.
  - `planSlots(gpa, index, capacity)` → `SlotPlan`: every renderable asset gets a
    table slot by hash start + linear probing over the **sorted** index, in **one
    namespace** for meshes and textures. Deterministic, content-only, so
    `plan.handleOf(path)` is the handle a `.scene` stores — computable without
    loading a byte. Single namespace was a correctness fix, not a preference: with
    per-kind slots a mesh and a texture could land on one slot, and the second
    `setColor` bumped the generation, so one asset's material handle no longer
    resolved while its mesh handle did.
  - `loadAssets`: loads `.mesh` artifacts (zero-copy) and `.obj` sources (decoded,
    transient) plus PNG/BMP/TGA/QOI textures (artifact round-trip validates CXTX,
    pixels copied into the blob list the table borrows). Every slot also gets a white
    base colour, so a mesh's own handle is a valid material. The layout is planned
    **before** bytes are read, so a broken file cannot shift later handles; decode
    failures are counted in `skipped`, an exhausted table is `error.TableFull`.
  - `EngineRenderer`: owns the reusable double-buffered `RenderFrame`; `render`
    takes the lens + the view from `cameraOf` and rebuilds the projection from the
    **surface aspect** (resizing reframes); `findCamera`/`renderSceneFrame` are the
    headless per-frame path (surface alloc + clear + render) and return null when the
    scene has no camera.
  - `pipeline.AssetTable.setDecodedMesh`: the one conversion from a source decoder's
    owned `Mesh` into the table, next to the existing `CXMH`-view path.
- `src/render/draw.zig`: `RenderFrame` is double-buffered with a `commands` view and
  `refill` reports `{ culled, changed }`. The comparison is `commandsEqual` (field by
  field) after a **byte** compare proved wrong: `DrawCommand` padding is undefined,
  so every frame looked changed. Documented on `refill`.
- `src/core/startup.zig`: `scene_data` is `?EngineRenderScene` (startup loads the
  render schema) and `StartupResult` carries `project_root` (+ the allocator that
  owns it) so the binary can load assets after startup.
- `src/main.zig`: renders one real frame of the project at startup through
  `renderSceneFrame` and prints
  `Frame: WxH <tier> (N commands, N draws, N skipped, N pixels, N culled)`, or
  `no camera in the scene; nothing to render`.
- Example project: `scenes/main.scene` now has a `Quad` with `renderable` and a
  `Camera` entity; `assets/quad.obj` is plain text, so no binary asset is committed
  and OBJ support is exercised by the shipped example.
- Docs: `scene-format.md` (the `renderable` and `camera` components, handle rule,
  accepted formats, a complete example), `render-extraction.md` (`RenderFrame` and
  the authoring/driving API), `render-backend.md` (where it is wired in, the frame
  line, revised limitation), `architecture.md`, `README.md`, `CHANGELOG.md`,
  `examples/hello-project/README.md`.

**Validation:**

- `zig build test --summary all` → **707/707** (clean `.zig-cache`), also
  **707/707** with `-Doptimize=ReleaseFast`.
- `zig fmt --check src build.zig` → clean; `zig build` → OK.
- Headless smoke on `examples/hello-project/HelloProject.corex`:
  `Frame: 1280x720 medium (1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled)`;
  `--mode runtime` same; `--mode validate` still prepares no session.

**Errors found and fixed while doing this:**

- Byte-comparing draw lists: padding makes identical frames "changed".
- Hash-only slot mapping (`hash % capacity`) aliased two assets onto one slot in the
  first test, because a fixed-capacity table cannot be addressed by a pure hash —
  replaced by hash start + linear probing over the sorted index.
- Per-kind slot namespaces let a mesh and a texture share a slot, bumping one
  generation and breaking that asset's colour handle; unified.
- Freeing the trimmed `plan.entries` slice panicked (the allocation was the full
  index length); the plan now keeps `storage` for the free.
- The frame line had escaped quotes (`\"medium\"`) from a multi-line format literal.
- Zig 0.17 notes: a function-style struct literal needs a `const` binding before
  `.method()`; `&resources.color(...).?` is a temporary (bind it first); `x ++ y`
  requires symmetric whitespace.

**Decisions:**

- Handles are `(generation << 16) | slot` and a fresh table's live slots are at
  generation 1, which is what `handleOf` returns. A slot is never shared between a
  mesh and a texture, so that stays true for every loaded asset.
- `.obj` is a supported mesh source in the loader: the importer's own decoder turns
  it into geometry, so a project needs no external tool and no committed binaries
  (the alternative — only `.mesh` artifacts — would have made the shipped example
  depend on a binary blob).
- The headless frame allocates colour/depth per call; that is documented as the
  reason `renderSceneFrame` exists rather than being called "the loop".

**Pending / known limits:**

- No window, swapchain or frame loop: one frame at startup, then the process exits.
- No per-frame allocator hand-off yet; the world-transform snapshot is still
  per-frame.
- One `Renderable` per entity, no instancing, no multi-material meshes, no CBOR/
  binary scene format; texture upload/eviction and mip chains for assets are GPU work.

**Next priority:** the presentation layer — a window + event loop that drives
`EngineRenderer.render` repeatedly with owned colour/depth buffers and a
per-frame allocator hand-off (then asset upload/eviction and CXTX mips).

**Merged:** PR **#41** → `main` `fd45a92`, CI green (`Build & test (Zig 0.17.0)`
pass, 24 s). Re-tested on the merge: clean `.zig-cache`, **707/707** on `main`.
Note for continuation: `origin/main` was re-rooted onto an identical tree (Arena
replays the branch history), so `main` and this branch shared no common ancestor
and every file showed as an add/add conflict despite **zero** tree difference
(`git diff --stat 3893758 7328182` empty). The merge was done with `-s ours` —
the correct result for identical content, no file lost.

**Integration:** startup step 6/7 → `EngineRenderScene.load` → `planSlots` +
`loadAssets` → `findCamera` → `renderSceneFrame` → `pipeline.renderFrame` →
`SoftwareBackend` → rasterizer. `render` still depends on no asset code; only
`render_scene` (a composition-root module) imports `assets`.

## Cycle 2026-11-06 (e) — Frame pipeline over the contract + rasterizer overflow fix

**Delivered (validated):**

- `src/render/pipeline.zig` (new, `corex.render.pipeline`, re-exported on
  `corex.render`): the layer that **uses** the tier contract, so a scene becomes a
  frame in one call.
  - `renderScene(gpa, tier, surface, scene, cam, sort_mode, resources, params)`
    = `extractDrawList` → `renderFrame`; `renderFrame` is the same path for an
    already extracted list (`beginFrame` → N × `draw` → `endFrame`).
  - `mvp = view_projection * world` folded once per draw here, per the contract.
  - `tierFromConfig(config.RendererTier)` maps the project setting onto `Tier`
    **without** `render` importing `core/config.zig` (duck-typed on the tag name,
    `std.meta.stringToEnum`) and with a **comptime** check that no config tier
    lacks a render tier. `backendFor(tier, gpa)` is the single registration point;
    `advanced` has no backend.
  - `resolve(tier, params, blend_hint)` → `FrameOptions` the tier can honour
    (antialias/mipmap/light/blend coerced off), so the pipeline never trips its own
    gate; the default blend follows the sort mode (`back_to_front` → `.alpha`).
  - `FrameReport`: tier, commands, extraction culling, backend `FrameStats` and the
    **accepted** options.
  - `ResourceTable`: fixed-capacity, no allocation after `init`, slots for
    meshes/colours/textures with **per-kind generations** (a released or reused
    slot cannot be aliased by a stale handle; setting a material does not
    invalidate the slot's mesh). `liveCount()` counts mesh+colour pairs.
  - `AssetTable` + `textureFromAsset`: render real project assets — a zero-copy
    `CXMH` view (`assets.mesh`) is copied into tightly-packed scratch, a decoded
    `CXTX` texture is adapted with no copy; oversized meshes are
    `error.MeshTooLarge`, never truncated. `render` keeps no asset-layer
    dependency beyond these two adapters (only `raster.Mesh`/`Texture` are stored).
- Startup step 7 now selects the renderer tier from `settings.json`, logs it
  (`renderer tier: <name>`), and fails the session with `error.PreparationFailed`
  (exit code 6) when the tier has no backend — Advanced is refused, never silently
  rendered at Medium. `StartupResult.renderTier` carries it; the launch summary
  prints the selected tier (`validate` prepares no session and reports the config).
- **Bug fixed in the rasterizer** (pre-existing, found by a pipeline test): a
  triangle whose vertices project outside the target could panic with an integer
  overflow in the pixel-box math. The box was clamped *before* the fixed-point→pixel
  shift (which floors, so it can be negative); the antialiasing halo then widened
  it to -2 and `clip_min - min` overflowed `i32`. Both paths now clamp to the
  target after the shift and share the same four clamps.
- Docs: `docs/render-backend.md` gains the pipeline and asset-handle sections plus
  updated limitations; `docs/render-raster.md` documents the box clamp;
  `architecture.md`, `README.md`, `CHANGELOG.md` updated.

- **Second bug fixed (lifetime, found by running the suite in every optimize
  mode):** `DrawResources.fromComptime` (previous cycle) took the provider by
  value and stored the address of its own parameter — a dangling pointer that read
  correctly at `-O Debug` and, at `-O ReleaseSafe`, made the software backend
  render a different colour from the rasterizer it must match. It now takes
  `&provider`, checked at comptime with an explicit message, so the borrow and its
  lifetime are the caller's. Regression test drives a provider whose handles and
  tint are read through the adapter and asserts the pixel channel by channel.

**Validation:** `zig build test` → **696/696** (15 new) on a cold cache in
**Debug, ReleaseSafe and ReleaseFast**; `zig fmt --check` clean; `zig build` OK;
headless smoke on `examples/hello-project` OK with `[90%] selecting renderer` and
`renderer tier: medium`. (Running only Debug is what hid the lifetime bug — every
optimize mode is now part of the check.) New tests: config↔render
tier bijection, `resolve` per tier (including that the resolved options pass
`unsupported`), backend selection (Advanced refused), a scene rendered on Low and
Medium through the pipeline, **pipeline output byte-identical** to driving the
backend by hand, malformed surface and missing backend refused, handle generations
(stale handle dead, per-kind independence, null for unused kinds, live-pair count),
`AssetTable` faithfulness and `MeshTooLarge`, `CXTX` adapter (no copy, validated),
a real `CXMH` + `CXTX` textured frame end to end (textured vs flat differ), startup
tier selection, Advanced-at-startup failure, and `validate` selecting no tier. The
rasterizer regression test was checked to **fail without the fix**.

**Errors found and fixed in-cycle:** the per-slot generation design invalidated a
slot's mesh handle as soon as its material was set (now per kind); `@typeInfo`
enum iteration needed `field_names` + `inline for`; `@field(Enum, name)` is
compile-time only, so the mapping goes through `stringToEnum`; `std.meta.fields`
is deprecated/allocation-backed here; error-set and zig-shadowing fixes. Test
assumptions corrected against real behaviour: the importer dedupes only identical
`v/vt` pairs (6 vertices, not 4), a 2x2 texture is 16 bytes, `liveCount` counts
pairs, and a filtered checker produces few distinct luminances — so the asset test
now compares textured against flat output instead.

**Decisions:** pipeline lives in `render` (not `core/startup`) so it stays a
pure, testable layer and `startup` only *selects*; tier mapping is comptime-checked
so a tier cannot exist on one side only; `resolve` coerces instead of rejecting so
callers need no per-tier branching; per-kind generations beat a single slot
generation because a draw's mesh and material normally share a slot; asset handles
are plain `u32` (as `DrawCommand` already defines them) rather than a new
generic-handle type.

**Pending:** presentation layer (window + swapchain + frame loop) so the engine
actually renders per frame; per-frame allocator hand-off for the draw list;
automatic asset upload/eviction from the asset index; mip generation for `CXTX`
(the artifact has no levels yet); GUI library and graphical editor; Lua VM;
export templates; native module API; audio device backends.

**Integrated:** commit `82ffebf`, PR #39, CI green (Build & test 23s), merged into
`main` as **`8a054f2`** (merge commit, no conflicts, no force). `main` re-tested
after the merge in a clean worktree at `origin/main`: **696/696 in Debug** and
**696/696 in ReleaseSafe**, `zig fmt --check` clean, `zig build` OK, headless smoke
OK (`Renderer tier: medium`), `--version` OK; merged tree `ff6680e…` identical to
the branch tree.

**Next priority:** the runtime/window presentation layer — own a swapchain and a
frame loop, select the backend with the now-wired tier, and call `renderScene` per
frame. It must stay behind the existing `Backend` vtable and the pipeline, and the
GPU API choice (Vulkan/Metal/D3D12) must be documented before coding.

## Cycle 2026-11-06 (d) — Renderer tier contract and CPU backend driver

**Delivered (validated):**

- `src/render/backend.zig` (new, `corex.render.backend`, re-exported on
  `corex.render`): the contract every renderer tier implements, so a backend can
  be added or swapped without touching the scene, extraction or caller.
  - `Tier` (`low`/`medium`/`advanced`) with **one** `capabilities(tier)` table:
    `depth`, `textures`, `lighting`, `blending`, `mipmaps`, `antialias`. Low is the
    documented floor (opaque, untextured, unlit geometry with a depth buffer);
    Medium is the full CPU feature set; Advanced declares the same set until a
    backend exists and is deliberately not implied by Medium.
  - `FrameOptions` (`blend`, `antialias`, `mipmap`, `light`, `depth_test`,
    `depth_write`, `cull`, `front_face`) + `rasterOptions()` so a new field cannot
    be forgotten on one side of the conversion.
  - `Surface`: borrowed RGBA8 `color` + `f32` `depth`, `validate()`, `clear()`,
    `pixelCount()`, and `Surface.of(&target)` adapting the rasterizer's `Target`
    as a cast, not a copy.
  - `DrawResources`: the duck-typed asset resolver as a **runtime** value (pointer
    + `meshFn`/`colorFn` + optional `textureFn`/`lightFn`), with
    `fromComptime(provider)` adapting any provider the rasterizer already accepts.
    Absent optional declarations become null pointers and a **private** `texture`
    decl stays invisible — the same rule `@hasDecl` applies.
  - `Backend`: explicit vtable (`tier`, `beginFrame`, `draw`, `endFrame`,
    `deinit`), the same shape as `core.splash.SplashScreen`, chosen because the
    tier comes from `settings.json` at runtime. `draw` takes
    `mvp = view_projection * world`, folded once by the caller.
  - `Error` (`FrameNotBegun`, `FrameAlreadyBegun`, `InvalidSurface`,
    `UnsupportedFeature`, `UnresolvedHandle`, `InvalidTexture`, `OutOfMemory`);
    `DrawStats`/`FrameStats` with `FrameStats.add` as the only fold.
- `unsupported(tier, options)`: pure capability gate. `beginFrame` **rejects**
  (`error.UnsupportedFeature`) instead of degrading, and a rejected frame does not
  start one. Two derived rules: `mipmap` is not a request on a tier without
  textures, but a **material that binds a texture** on such a tier is rejected
  (silent flat shading would hide the misconfiguration); a provider
  `directionalLight` is ignored without `lighting`, while an explicit
  `FrameOptions.light` is rejected.
- `SoftwareBackend`: the CPU driver and **reference implementation** of the
  contract, built on `raster.drawMeshAlloc` (passing the identity as the world
  matrix so the pre-folded `mvp` is applied exactly once). It serves `.low`
  through the gate as well as `.medium`.
- `docs/render-backend.md` (new): tiers/capability table, the pieces, lifecycle,
  ownership, the CPU driver, guarantees, limitations and next steps.
- Docs updated: `docs/architecture.md` (module tree + tier section),
  `README.md` (doc link, roadmap item now `[x]`), `CHANGELOG.md`.

**Validation:** `zig build test` → **681/681** (9 new) in a cold cache; `zig fmt
--check` clean; `zig build` and the headless smoke run OK. The key new test drives
the same command through `SoftwareBackend` and through `raster.drawMeshAlloc`
directly and asserts the colour **and** depth buffers are byte-identical — that is
what makes the CPU path a valid oracle for a future GPU backend. Also covered:
the capability table per tier, the gate (`UnsupportedFeature` for blend,
antialias, explicit light, and a texture binding on Low; defaults and
`mipmap = .level0` accepted; no frame left open after a rejection), stats
accounting with a culled quad and an unresolved handle, frame lifecycle misuse,
malformed surfaces, light precedence (provider / explicit / absent tier) and
adapter fidelity.

**Errors found and fixed in-cycle:** the first draft assumed `mvp` folded the
world matrix inside the backend (the contract puts that on the caller) and two
tests were wrong about the rasterizer's semantics — equal depth does not
overwrite, and `culled` counts **triangles**, not draws. Also fixed a shadowed
`command` identifier, type errors from an anonymous-struct provider at test scope
(hoisted to file scope) and the `tier_supports(.feature)` enum-literal-as-string
mistake (replaced by `caps()`).

**Decisions:** the contract takes the tier as an argument rather than importing
`core/config.zig` (non-trivial link from `render` to `core`, low coupling);
runtime vtable rather than comptime generics (runtime tier selection; the
rasterizer's comptime `resources` stays untouched behind the adapter); `Surface`
carries borrowed plain buffers rather than a GPU handle (backends keep their own
state behind the vtable; `Surface` serves readback and the reference path).

**Pending:** GPU backend selection (Low/Medium) implementing this vtable — an
API choice, to be documented before coding; wiring a backend into startup from
`settings.json` together with the runtime/window layer; presentation and
double buffering; per-material/per-pass state if a backend ever needs it.

**Integrated:** commit `76f3aa6`, PR #37, CI green (Build & test 24s), merged into
`main` as **`cf25839`** (merge commit, no conflicts, no force). `main` re-tested
after the merge in a clean worktree at `origin/main` → **681/681**, `zig fmt
--check` clean, `zig build` OK, headless smoke on `examples/hello-project` OK
(`Renderer tier: medium`); merged tree `ac681aa…` identical to the branch tree.

**Next priority:** the runtime/window layer that owns a swapchain and selects a
backend by tier from `settings.json`, keeping the contract as the only seam.

## Cycle 2026-11-06 (c) — Mipmaps and LOD selection

**Delivered (validated):**

- `Texture.mips: []const MipLevel` — the levels below level 0, largest first —
  plus `MipLevel`, `Texture.mipLevel(i)` / `mipLevelCount()`, and validation of the
  chain inside `Texture.validate()` (exactly repeated halving, level length
  `w*h*4`, nothing after 1x1) as `error.InvalidTexture`.
- `corex.render.mipmap` (`src/render/mipmap.zig`): `Chain.generate(gpa, w, h,
  pixels)` box-filters every level below level 0 with `(sum + count/2) / count`
  per channel (integers, one round-half-up, no float) and owns one allocation;
  odd axes share their last row/column instead of dropping it. Pure helpers
  `levelCount` / `levelDims`. The module has no dependency on `raster.zig`.
- `Options.mipmap` (`corex.render.Mipmap`) = `.trilinear` (default) / `.level0`.
- LOD: `texelGradient` evaluates the exact derivative of `u = p / den`
  (`(dp*den - p*dden) / den²`) with one reciprocal; `textureLod` is
  `clamp(log2(max(|du|,|dv|)), 0, levels-1)`; `sampleTrilinear` filters
  `floor`/`ceil` with the material filter and mixes them with one final round.
  The six per-pixel gradient constants (`GradSteps`) come from the same per-pixel
  edge steps the coverage loop already computes — six multiplies per triangle,
  no extra sampling.
- Fast path: a constant perspective denominator (every orthographic projection
  and any affine UV map) makes the level constant, so `GradSteps.constantLod`
  hoists the `log2` to once per triangle. Bit-identical to the general path.
- Byte-identity guarantees kept: no `mips` → the exact old `sampleTexture`
  expression; `mipmap = .level0` → level 0 of the chain through the same sampler.

**Key decisions:**

- The chain is the caller's data, built by a free function that owns one
  allocation (`Chain`) and returns borrowed `levels()`. The rasterizer stays
  allocation-free and keeps zero coupling to an asset layer — a decoded `CXTX`
  texture plus `Chain.generate` is the whole integration.
- Integer box filter rather than float: it is deterministic across platforms and
  can be pinned exactly by the Python reference, like every other number in this
  path. `+ count/2` is the single round-half-up.
- Anisotropy is **not** attempted: the gradient takes the larger axis, which
  over-blurs grazing angles. Documented as a limitation rather than approximated.
- Performance: the first version recomputed the derivative and `log2` per pixel,
  costing ~2x at 1024². The constant-denominator fast path brought the
  orthographic case to ~1.2x (68.6 ms → 79.8 ms at 128 texels/pixel), which is the
  common case for 2D/UI draws. The perspective case still pays ~2x and is
  documented.
- Three generator/reference bugs found and fixed while validating: `math` was
  not imported in the new trilinear helper; `.level0` on a mipmapped texture must
  sample the chain's own level 0 (not the 4x4 fixture); and the 4x4 base cases
  were being fed the 16x16 level 0, which the new `big_base` flag in the vector
  file now makes explicit.

**Validation run (all green):**

- `zig build test -Doptimize=Debug|ReleaseSafe|ReleaseFast` → 672/672 (12 new:
  6 mipmap-module, 6 rasterizer).
- `zig build`, `zig fmt --check src/ tools/ build.zig`, `zig build bench`.
- 34 new reference frames (78 total, 1094 covered pixels) match bit for bit,
  including a 24-case random mipmapped sweep over magnification, minification,
  perspective and both `mipmap` modes.
- AA-off/level-0 regression: the pre-existing 44 texture cases plus the 73 base,
  40 light and 49 blend cases are byte-identical.
- Launch-contract smoke: `--version`, `--mode validate`, `--headless`,
  `--mode runtime --headless` (all exit 0).
- Benchmark @1024²: level 0 68.62 ms, trilinear 79.84 ms (128 texels/pixel);
  @512²: 17.76 → 20.69 ms; @256²: 4.96 → 5.92 ms.
- Generator reproducible: two consecutive runs produce the same vector file
  (md5 `7d50729f…`).
- Merged as PR #35 (merge commit `b5ea278`); `main` re-tested afterwards:
  672/672, `zig fmt`, `zig build` and the launch-contract smoke all green, and the
  merge tree is identical to the branch tree.

**Pending / next priority:**

1. Renderer Low/Medium GPU backend contracts consuming the same draw list.
2. Optional follow-ups, only if justified: anisotropic LOD (multiple samples or
   a longer axis), per-material LOD bias, and `Texture` reuse for the AA path.
3. GUI library + graphical editor; then the graphical splash on top of it.
4. Lua VM / gameplay scripting (VM choice must be documented first).
5. Export system / Export Templates (engine side) and the runtime player.
6. Native Module API loader (C++), header under `include/corex/`.
7. Audio: chorus/flanger/convolution/side-chain; OS device backends.
8. Assets: progressive JPEG, compressed audio, glTF/FBX/DAE; hot-reload watcher.

## Cycle 2026-11-06 (b) — Edge antialiasing in the software rasterizer

**Delivered (validated):**

- `render.raster.Antialias` = `.none` (default) / `.edge`, exposed as
  `corex.render.Antialias` through an additive `Options.antialias` field, plus
  `Stats.antialiased_pixels` (count of partially covered resolved pixels).
- `.edge` supersamples each pixel with a 4x4 grid of 16 **exact integer**
  sub-samples at 2/6/10/14 sixteenths (`aaSampleOffset`), evaluated from the same
  `i64` edge functions with the constant per-unit `EdgeSteps` deltas — no float, no
  table, bit-exactly reproducible like the one-sample path.
- The top-left fill rule is applied to the **sub-samples**, so two triangles sharing
  an edge partition its samples: a quad's two triangles sum to exactly 16 on every
  interior pixel (no seam, no double count).
- Coverage is accumulated **per draw command** in `AccumBuffers` (one `AccSlot` +
  one id per pixel of the draw's reach box, `reachRect`-sized, caller-owned) and
  resolved once per touched pixel. Per-fragment compositing was rejected (seams).
- Resolution: fully covered pixels take the un-antialiased write / `blendPixels`
  and stay **byte-identical**; partial pixels run `compositeCoverage`, which folds
  `count/16` into the source alpha and applies straight-alpha source-over in `f64`
  with one quantize per channel. Partial pixels never write depth.
- Fast path per pixel: two integer comparisons per edge decide provable full / empty
  coverage (`aa_sample_reach` = 6 sub-pixel units); only near-edge pixels run the
  16-sample grid.
- API: `drawMeshAlloc` / `rasterizeAlloc` (allocator, can antialias) vs
  `drawMesh` / `rasterize` / `rasterTriangle` (no allocator, force
  `antialias = .none`, signatures and behaviour unchanged). `DrawError` = `Error`
  plus `OutOfMemory`, raised **before** any pixel is written.
- New tests: from-scratch sub-sample cross-check of `coverageCount` (pins the
  stepping, not just self-consistency), quad-partition property, area conservation
  against the shoelace screen area, grid-aligned byte identity, no-depth-from-partial,
  translucent composite formula, `checkAllAllocationFailures` over the scratch sites,
  single-triangle entry point. 660 tests total (658 before this cycle: the three
  broken AA tests were replaced one for one and two are new).
- Docs: `docs/render-raster.md` gained a full **Antialiasing** section (positions and
  rule, per-draw accumulation, resolve math, cost, verification), the API table, the
  pipeline step and an honest limitations bullet; `README.md`, `docs/architecture.md`
  and `CHANGELOG.md` updated; `tools/bench_raster.zig` gained an `aa` column
  (`runAntialiased`, half-pixel-shifted projection, warm-up + best of five).

**Key decisions / corrections:**

- **The original "pixel center strictly inside ⇒ coverage 16" shortcut was a real
  bug**, not a test tolerance issue: a center can sit a fraction of a sub-sample
  from an edge while most sub-samples fall outside. It made slanted edges lose
  ~6 px of coverage (172.97 vs the true 167.04). Replaced by the reach-based
  provable full/empty test.
- The area-conservation assertion is now `|sum_aa - area| <= max(area*0.005,
  quant_error)`. Measured 167.40 vs 167.04 (0.2%); a binary rasterizer gives 165.0
  (1.2%) and cannot pass, so the test still means what it claims.
- An early debug harness passed `.{1,0,0,1}` as a tint: the `drawMesh` tint is
  **RGBA8**, so that alpha meant 1, not 255 and every edge looked ~1/255 too dark.
  The AA fixtures use the shared `red` (`{255,0,0,255}`) like the rest of the file.
- No MSAA/GBuffer, no coverage-based texture filtering, no AA inside
  `rasterTriangle`: mipmapping is the correct fix for texture minification.

**Validation run (all green):**

- `zig build test -Doptimize=Debug|ReleaseSafe|ReleaseFast` → 660/660.
- `zig build`, `zig fmt --check src/ build.zig`, `zig build bench` (ReleaseFast).
- Launch-contract smoke: `--version`, `--project … --mode validate`, `--headless`,
  `--mode runtime --headless` (all exit 0).
- AA-off regression: the four reference corpora (73 + 44 + 40 + 49 cases) stay
  byte-identical.
- Benchmark @1024² (1024 sampled tiles, ReleaseFast): one sample 27.3 ms,
  `.edge` 40.9 ms; @512²: 7.5 ms → 19.6 ms; @256²: 2.3 ms → 12.6 ms.

**Pending / next priority:**

1. Texture minification: mipmaps / LOD selection (currently aliases) — the last
   bullet of "Rasterizer shading".
2. Optional AA improvements, only if justified: better sample pattern, or a
   coverage-aware texture path. Not scheduled.
3. Renderer Low/Medium GPU backend contracts consuming the same draw list.
4. GUI library + graphical editor; then the graphical splash on top of it.
5. Lua VM / gameplay scripting (VM choice must be documented first).
6. Export system / Export Templates (engine side) and the runtime player.
7. Native Module API loader (C++), header under `include/corex/`.
8. Audio: chorus/flanger/convolution/side-chain; OS device backends.
9. Assets: progressive JPEG, compressed audio, glTF/FBX/DAE; hot-reload watcher.

## Cycle 2026-11-06 — Framebuffer blending in the software rasterizer

**Delivered (validated):**

- `render.raster.Blend` = `.none` / `.alpha` / `.premultiplied` / `.additive`,
  exposed as `corex.render.Blend`, selected by the additive
  `Options.blend` field (default `.none`).
- `blendPixels` composites the **quantized** shaded fragment with the existing
  target pixel in `f64` with a pinned order; one clamp+quantize per channel
  (`unitByte`). Alpha composites in every mode (`out.a = sa + da*keep`); depth is
  never blended; `depth_test`/`depth_write` keep their meanings.
- Degenerate cases are defined, not accidental: a fully transparent source is an
  exact no-op in every mode; `.alpha` with `out.a == 0` yields transparent black
  instead of dividing by zero. `.premultiplied` premultiplies the straight-alpha
  fragment at blend time (`src*sa + dst*keep`).
- `.none` short-circuits before any arithmetic → byte-identical (color *and*
  depth) to the pre-blending path; a test proves it.
- 49 reference frames in `src/render/raster_blend_vectors.zig` generated by
  `tools/gen_raster_blend_vectors.py` (every case starts from a non-empty target;
  801 covered pixels; all four modes; textured/lit sources; saturation) + per-mode
  unit tests + a cross-layer test (scene → `back_to_front` extraction → alpha
  blend → QOI round-trip).
- `tools/bench_raster.zig` measures the blended paths; `docs/render-raster.md`
  documents the modes, the math, the depth/order caveat and the measured cost.

**Key decisions:**

- The mode is named `.none`, not `.opaque`: `opaque` is a reserved keyword in
  Zig 0.17.0 and cannot be an enum tag.
- Blending is per-fragment in submission order. No order-independent
  transparency, no fragment buffering/sorting inside the rasterizer: the caller
  pairs `.alpha` with `extractDrawList(..., .back_to_front)` and (for
  multi-surface transparency) `depth_write = false`.
- `.alpha` is straight-alpha over a straight-alpha target (the framebuffer stores
  what the shading path produces); `.premultiplied` is the premultiplied
  composite. Both agree when the destination is opaque.
- The target keeps its 8-bit RGBA8 layout: no extra buffers, no allocator, no
  precision upgrade. Round-trip loss through repeated blends is inherent and
  documented.
- No G-buffer, no MSAA, no shader abstraction added — out of scope for this step.

**Validation run (all green):**

- `zig build test -Doptimize=Debug|ReleaseSafe|ReleaseFast` → 652 tests.
- `zig build`, `zig fmt --check src/ tools/ build.zig`.
- Launch-contract smoke: `--version`, `--mode validate`, `--headless`,
  `--mode runtime --headless`.
- Generator reproducibility: re-running `tools/gen_raster_blend_vectors.py`
  reproduces the committed vector file byte for byte.

**Pending / next priority:**

1. Rasterizer antialiasing (coverage-based edge AA) — the remaining bullet of
   "Rasterizer shading: antialiasing, mipmaps".
2. Texture minification: mipmaps/LOD selection (currently aliases).
3. Renderer Low/Medium GPU backend contracts consuming the same draw list.
4. GUI library + graphical editor; then the graphical splash on top of it.
5. Lua VM / gameplay scripting (VM choice must be documented first).
6. Export system / Export Templates (engine side) and the runtime player.
7. Native Module API loader (C++), header under `include/corex/`.
8. Audio: chorus/flanger/convolution/side-chain; OS device backends.
9. Assets: progressive JPEG, compressed audio, glTF/FBX/DAE; hot-reload watcher.

**Toolchain note:** Zig 0.17.0 is not pre-installed in the sandbox. It was
installed with `python3 -m venv /tmp/zigvenv && /tmp/zigvenv/bin/pip install
ziglang==0.17.0` and invoked as
`/tmp/zigvenv/lib/python3.11/site-packages/ziglang/zig`. `/tmp` does not survive
between sandbox sessions, so this must be repeated on a fresh session.
