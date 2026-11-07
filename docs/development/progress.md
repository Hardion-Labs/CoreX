# Continuity log — CoreXEngine

Permanent record of real progress, decisions, pending items and the next priority
task. Kept in sync with the code and Git; recovered at the start of every
continuation. Newest cycle first.

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
