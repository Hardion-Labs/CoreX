# Software rasterizer

`corex.render.raster` turns an extracted draw list into pixels on the CPU. It is
the first stage of the engine that produces an image: before it, the render
subsystem only culled geometry and sorted draw commands.

There is no GPU dependency, no window system and no allocator in the pixel path —
the only allocation in the whole backend is the scratch an antialiased draw needs,
and it is the caller's allocator, sized once per draw and freed before the next
(see [Antialiasing](#antialiasing)). The whole backend therefore runs headlessly
and is covered by the normal test suite.
This is **not** a renderer tier: the Low/Medium/Advanced tiers and GPU backends
remain unimplemented (see [scope.md](scope.md)).

## Pipeline

Per triangle, in order:

1. **Transform.** `view_projection * world` is composed once per draw command, so
   each vertex costs a single matrix-vector product into clip space.
2. **Clip.** Sutherland-Hodgman against all six frustum half-spaces in clip space
   (`w ± x`, `w ± y`, `w ± z`). Clipping happens *before* the perspective divide,
   which is what makes near-crossing triangles safe: an unclipped vertex near the
   eye divides by a tiny `w` and smears across the whole target.
3. **Divide and viewport.** Perspective divide to NDC, then map to pixels with a
   **Y flip** (NDC is Y-up, the framebuffer is top-down) and snap to fixed point.
4. **Cull.** The signed screen area decides front-facing; degenerate (zero-area)
   triangles are dropped.
5. **Rasterize.** Integer edge functions with a top-left fill rule over a clamped
   bounding box, with a depth test. Per pixel the shaded result is either the flat
   material tint or a texture sample (nearest or bilinear, perspective-correct)
   multiplied by that tint. When a light is configured, a per-channel Lambert
   multiplier is applied to the albedo first (RGB only) — see
   [Lighting](#lighting). The fragment is then written as-is (`.blend = .none`,
   the default) or composited with the target — see [Blending](#blending). With
   `antialias = .edge` the pixel loop instead accumulates sub-sample coverage per
   draw command, and a resolve pass composites the touched pixels — see
   [Antialiasing](#antialiasing).

A clipped triangle stays convex, so the resulting polygon (at most nine vertices)
is covered exactly by a triangle fan. Both clip buffers are fixed 12-slot arrays
on the stack: clipping never allocates and cannot grow without bound.

## Fixed-point coverage and the top-left rule

Screen coordinates are stored in **28.4 fixed point** — sixteenths of a pixel.
Every edge function is then an exact `i64` expression:

```
E(a, b, p) = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
```

This buys two things that a float rasterizer cannot offer:

- **Bit-exact reproducibility.** Coverage does not depend on float rounding,
  compiler optimizations or target CPU. The reference vectors match bit for bit
  in Debug, ReleaseSafe and ReleaseFast.
- **Watertight shared edges.** Pixel centers sit at `(x + 0.5, y + 0.5)`. A center
  landing exactly on an edge is included only if that edge is a *top* or *left*
  edge. With the normalized positive-area winding in a Y-down buffer, a top edge
  runs left-to-right (`dy == 0 and dx > 0`) and a left edge runs upwards
  (`dy < 0`). Reversing an edge flips the sign of `dy`, so exactly one of
  `isTopLeft(a, b)` / `isTopLeft(b, a)` holds — and two triangles sharing an edge
  traverse it in opposite directions. The partition is therefore exact: **no
  double-drawn pixel and no crack**.

The edge functions are stepped incrementally: moving one pixel right or down
changes each by a constant, so the inner loop does no multiplication for
coverage. The three weights are tested with a single sign check, `(w0 | w1 | w2) >= 0`.

## Depth

The depth buffer holds **NDC `z` in [-1, 1]**, cleared to `1` (the far plane).
After the perspective divide, `z` is affine in screen space, so plain barycentric
interpolation is already perspective-correct and no per-pixel divide is needed.
UVs are *not* affine that way: each vertex carries `uw = u / w`, `vw = v / w` and
`w_inv = 1 / w` (clip space), which are interpolated linearly and divided through
at the pixel (`u = (Σλ_i·uw_i) / (Σλ_i·w_inv_i)`). See
[Textures](#textures).

Interpolation is evaluated in `f64` with a pinned operation order and rounded
once to `f32`, which is what makes the depth values reproducible against the
reference:

```
z = ((w0 * z0 + w1 * z1) + w2 * z2) * (1 / area)
```

The test is strict `<`, so an equal depth does not overwrite. `depth_test` and
`depth_write` are independent: disabling the test gives painter's-order
overdraw, and disabling the write lets geometry be tested without occluding
later draws.

Storing `1/w` instead of `z` was rejected: it is constant under an orthographic
projection and so can neither order fragments nor detect coplanar surfaces.

## API

```zig
const R = corex.render;

// Caller-owned buffers; the rasterizer only borrows them.
var target = try R.Target.init(width, height, color_bytes, depth_values);
target.clear(.{ 0, 0, 0, 255 }, 1.0);

const stats = try R.rasterize(&target, frame.commands, cam.view_projection, resources, .{});
```

| Item | Meaning |
| --- | --- |
| `Target` | Borrowed RGBA8 `color` (`w*h*4`) plus `f32` `depth` (`w*h`). `init` validates both lengths. |
| `Target.clear` | Reset color and depth. |
| `Target.colorAt` / `depthAt` / `pixelCount` | Accessors. |
| `Mesh` | `positions: []const [3]f32`, `indices: []const u32` (triangle list), optional `uvs: []const [2]f32` (one per position). |
| `Texture` | `width`/`height`, borrowed `pixels` RGBA8 (row-major, top-down), `filter`, and optional `mips` (`[]const MipLevel`, largest first; empty by default). `validate()` rejects zero/oversized dims, length mismatches and a chain that is not repeated halving — all with `InvalidTexture`. |
| `MipLevel` | `{ width, height, pixels }` for one reduced level, same layout as `Texture.pixels`. |
| `mipmap.Chain` | `generate(gpa, width, height, pixels)` builds the levels below level 0 (integer box filter) and owns them; `levels()` feeds `Texture.mips`, `deinit(gpa)` frees. `levelCount`/`levelDims` are the pure helpers. |
| `Mipmap` | `.trilinear` (default, pick and mix levels) or `.level0` (always full size). |
| `Filter` | `nearest` or `bilinear`. |
| `Light` | Directional light for the Lambert path: `direction` (toward the light, world space, normalized internally), `color`, `ambient`. `validate()` rejects malformed lights with `InvalidLight`. |
| `Blend` | `.none` (default, verbatim write), `.alpha` (straight-alpha source-over), `.premultiplied`, `.additive`. |
| `Antialias` | `.none` (default, one sample per pixel) or `.edge` (4x4 sub-samples, see [Antialiasing](#antialiasing)). |
| `Options` | `cull` (`.none`/`.back`/`.front`), `front_face`, `depth_test`, `depth_write`, `light` (optional directional Lambert light; beats a `resources.directionalLight()` provider), `blend`, `antialias`, `mipmap`. |
| `Stats` | `skipped_draws`, `submitted`, `clipped`, `culled`, `rasterized`, `pixels`, `antialiased_pixels`. |
| `rasterize` / `rasterizeAlloc` | Whole draw list, resolving handles through `resources`. `rasterize` takes no allocator and therefore forces `antialias = .none`; `rasterizeAlloc` is the entry point that can antialias. |
| `drawMesh` / `drawMeshAlloc` | One mesh, one world matrix, one flat RGBA8 tint, optional texture and light. Same split: only the `Alloc` variant antialiases. |
| `rasterTriangle` | One screen-space triangle; the entry point the vectors target. Never antialiases (it has no per-draw accumulator to resolve against). |

`max_dimension` is 16384 per side, which bounds both the fixed-point range and the
pixel count. Errors are `InvalidTarget`, `InvalidDimension`, `InvalidIndex`
(index past the position array, or an index count that is not a multiple of
three), `InvalidUv` (a mesh whose `uvs` are missing or shorter than its
`positions` when a texture is bound), `InvalidTexture` (malformed texture) and
`InvalidLight` (zero-length or non-finite light direction, or a negative/non-finite
`color`/`ambient` channel — raised at the `drawMesh` entry, before any draw).
`DrawError` is that set plus `OutOfMemory`, which only the `*Alloc` entry points
can return: an antialiased draw allocates its accumulation scratch first, so a
failed allocation fails the draw before a single pixel is written. Passing
`undefined` as the allocator is sound exactly when `antialias` is `.none` — which
is what the non-alloc wrappers do.

`rasterTriangle` returns `false` **only** for a cull rejection or an exactly
degenerate triangle. A triangle that survives but covers no pixel center returns
`true`: the result depends on the triangle and the cull mode alone, never on the
target size. `Stats.rasterized` counts those survivors, and `Stats.pixels` reports
what was actually covered.

### Resolving mesh and material handles

`Renderable.mesh` and `.material` are opaque `u32` handles. The rasterizer
resolves them through a **duck-typed** `resources` value that must provide:

```zig
pub fn mesh(self: @This(), handle: u32) ?RasterMesh
pub fn color(self: @This(), handle: u32) ?[4]f32    // linear RGBA in [0, 1]
pub fn texture(self: @This(), handle: u32) ?Texture // optional, see below
pub fn directionalLight(self: @This()) ?Light       // optional, see below
```

A command whose mesh or material does not resolve is counted in `skipped_draws`
and leaves the target untouched. Colors are clamped to [0, 1] and quantized with
round-to-nearest (`0.5` becomes 128).

The `texture` method is **optional**: its presence is detected at comptime via
`@hasDecl`, which only sees **`pub`** decls — a private `fn texture` is treated
as absent. When the material resolves to a texture but the mesh carries no
`uvs` (or a `uvs` slice whose length differs from `positions`), the command is
counted in `skipped_draws` and skipped — this is a soft, data-level failure,
mirroring unresolved handles. A texture whose pixels or dimensions are
malformed is a hard `error.InvalidTexture` — bad asset data must not render
silently wrong. When no texture resolves, the material shades flat and any
`uvs` on the mesh are ignored entirely.

This keeps `render` free of any dependency on the asset layer — the same boundary
the audio mixer maintains. Adapting a decoded `CXMH` mesh is a handful of lines.
`MeshView` stores interleaved vertices, so de-interleave the positions once into
a buffer you own and cache it alongside the asset:

```zig
const Resources = struct {
    positions: []const []const [3]f32, // per mesh handle, de-interleaved once
    indices: []const []const u32,
    uvs: []const []const [2]f32,       // same layout, or skip if the asset has none
    palette: []const [4]f32,
    textures: []const corex.render.RasterTexture,

    pub fn mesh(self: @This(), handle: u32) ?corex.render.RasterMesh {
        if (handle >= self.positions.len) return null;
        return .{ .positions = self.positions[handle], .indices = self.indices[handle],
                  .uvs = self.uvs[handle] };
    }

    pub fn color(self: @This(), handle: u32) ?[4]f32 {
        if (handle >= self.palette.len) return null;
        return self.palette[handle];
    }

    pub fn texture(self: @This(), handle: u32) ?corex.render.RasterTexture {
        if (handle >= self.textures.len) return null;
        return self.textures[handle];
    }
};

// One-time conversion from a parsed artifact:
for (0..view.vertex_count) |i| positions[i] = view.vertexAt(i).position;
for (0..view.vertex_count) |i| uvs[i] = view.vertexAt(i).uv;
for (0..view.index_count) |i| indices[i] = view.indexAt(i);
```

The `directionalLight` method is **optional** in the same way: detected at comptime
via `@hasDecl`, `pub` required. It returns one `Light` shaded for every draw command
in the batch; an explicit `Options.light` on the call wins over it. A malformed
light — provider or explicit — fails with `error.InvalidLight` at the `drawMesh`
entry, before any draw. The light is **not** validated when resolved, only when it
reaches `drawMesh`, so a provider may return it unconditionally without adding its
own validation step. Omitting `directionalLight` (or returning null) keeps the
unlit path and stays byte-identical to before lighting existed.

Omitting `fn texture` from the provider (or returning null) keeps the flat path;
the material tint is the shade color exactly as before.

Because `resources` is a comptime parameter there is no vtable and no indirect
call per vertex.

## Blending

`Options.blend` selects how each shaded fragment is combined with what the target
already holds. `Blend` has four modes:

| Mode | RGB | Use |
| --- | --- | --- |
| `.none` (default) | `src` written verbatim | Opaque geometry. Bit-identical to the behaviour before blending existed. |
| `.alpha` | `(src·sa + (dst·da)·keep) / out.a` | Straight-alpha source-over — the "normal" 2D/UI/transparency compositing mode. |
| `.premultiplied` | `src·sa + dst·keep` | Compositing into a target that already stores premultiplied RGB. |
| `.additive` | `dst + src·sa` | Glow, particles, light accumulation. |

Every mode composites alpha the same way, so a transparent destination keeps its
coverage:

```
sa = src.a / 255        da = dst.a / 255        keep = 1 - sa
out.a = sa + da * keep
```

Each channel is then clamped to `[0, 1]` and quantized **once**:
`floor(clamp(v, 0, 1) * 255 + 0.5)` — the same single-rounding rule the shading
path uses. All arithmetic is `f64` with a pinned operation order, so blended
frames are reproducible bit for bit across Debug, ReleaseSafe and ReleaseFast.

Two degenerate cases are defined rather than left to the FPU:

- `.alpha` with `out.a == 0` (both sides fully transparent) cannot divide out the
  alpha, so the pixel becomes transparent black `{0, 0, 0, 0}`.
- A fully transparent source (`sa == 0`) is an exact no-op in every mode: the
  fragment contributes no RGB, and the surviving alpha, RGB and depth are the
  destination's. (`.premultiplied` multiplies the fragment by `sa` for exactly
  this reason.)

Depth is untouched by blending: the depth test and `depth_write` keep their
independent meanings, so a translucent surface still occludes what is *behind*
it. There is no depth pre-pass, no order-independent transparency and no
per-fragment sorting. Correct transparency therefore depends on submission order:
draw back to front. The extraction layer already provides the sort for this
(`SortMode.back_to_front`) — the rasterizer does not reorder draws on its own,
because doing so would require buffering and then sorting every fragment.

```zig
// Translucent pass: extraction sorted back_to_front, straight-alpha blending.
var frame = try R.extractDrawList(&scene, cam, .back_to_front, gpa);
defer frame.deinit();
const stats = try R.rasterize(&target, frame.commands, cam.view_projection, resources, .{
    .blend = .alpha,
    .depth_write = false, // translucent surfaces do not occlude each other
});
```

## Antialiasing

`Options.antialias = .edge` switches the rasterizer from one center sample per
pixel to a **4x4 grid of 16 sub-samples** and composites the resulting fractional
coverage. It is the fix for two artifacts of the default path: staircase edges on
slanted geometry, and thin geometry that disappears entirely because no pixel
center falls inside it.

```zig
var frame = try R.extractDrawList(&scene, cam, .back_to_front, gpa);
defer frame.deinit();
// .edge needs scratch, so it goes through the *Alloc variants.
const stats = try R.rasterizeAlloc(gpa, &target, frame.commands, cam.view_projection, resources, .{
    .antialias = .edge,
    .blend = .alpha,
});
```

`Antialias` is `.none` (default) or `.edge`. Coverage is sampled per pixel,
not per fragment, and resolution is deferred until the whole draw command is in —
that is the design decision that makes shared edges work (see below).

### Sub-sample positions and the top-left rule

Sub-sample `k` of a pixel along one axis sits at `(k + 0.5) / 4` of the pixel, so
in the 28.4 fixed-point grid the four offsets are **2, 6, 10 and 14** sixteenths
from the pixel's top-left corner — i.e. `aaSampleOffset`, the exact integer
centers of the four quarter pixels. Nothing about the grid is floating point.

The three edge functions at a pixel center are already exact `i64` values, and
moving to a sub-sample is one multiply-add per edge with the constant per-unit
deltas (`EdgeSteps.dx`/`.dy`: raw coordinate differences, one order of magnitude
smaller than the per-pixel steps). `coverageCount` therefore evaluates all 16
samples with integer arithmetic only — no lookup table, no float, reproducible bit
for bit like every other coverage decision in this file.

The **top-left fill rule is applied to the sub-samples too**, with the same
`bias` the pixel-center test uses: a sample lying exactly on an edge counts only
when that edge is a top or left edge. Two triangles sharing an edge traverse it in
opposite directions, so for a sub-sample on that edge exactly one of them claims
it. Coverage of the two triangles therefore *sums* to the pixel's full 16 and the
shared interior edge has no seam — the watertightness property of the one-sample
path survives sub-sampling.

Each pixel is first classified with two integer comparisons per edge: a center
farther from every edge than one sub-sample spacing (`aa_sample_reach`, 6 units)
is **provably** fully covered (16) or provably empty (0) and skips the grid
entirely; only the pixels within one sub-sample of an edge run `coverageCount`.
A center inside the triangle is *not* sufficient for full coverage — it can sit a
fraction of a sub-sample from an edge while most sub-samples fall outside — so the
earlier "center inside means 16" shortcut was removed.

### Per-draw accumulation

Per-fragment compositing was rejected: each triangle composites on its own, so on
a shared edge the second triangle blends over the first triangle's already-blended
pixels and a visible seam appears. The implemented model accumulates:

1. For each triangle of the draw, every touched pixel keeps a `count` of covered
   sub-samples plus the shaded color and depth of the *last* contributing sample.
2. After the whole mesh is submitted, `resolveAccumulated` visits each touched
   pixel once, writes the color and (for fully covered pixels) the depth.

The scratch is a pair of caller-allocated buffers sized to the draw's bounding
rectangle — `AccumBuffers`, exposed through `drawMeshAlloc`/`rasterizeAlloc`. It
holds one `AccSlot` (`count`, `rgba`, `depth`) and one id per pixel of that
rectangle, and only touched ids are visited at resolve time: nothing is cleared,
and the resolve pass is proportional to covered pixels, not to the target. The
rectangle comes from `reachRect`, which bounds the mesh AABB's projection
conservatively; if it cannot, it falls back to the whole target (correct, just
more memory). A failed allocation fails the draw **before** any pixel is written.

Because the slot keeps the *last* sample's shade, a partially covered pixel is
shaded once, not once per sub-sample. Coverage is constant across a flat or
linearly-filtered fragment, so this costs nothing in quality.

### Resolving partial coverage

Fully covered pixels (`count == 16`) skip coverage arithmetic: `.blend = .none`
writes the shaded fragment verbatim and the other modes go through
`blendPixels`, both **byte-identical to the one-sample path**. Only the 0 <
`count` < 16 pixels run `compositeCoverage`, which folds the coverage into the
source alpha and then runs the ordinary straight-alpha source-over:

```
cov = count / 16
sa  = (src.a / 255) * cov        da = dst.a / 255        keep = 1 - sa
out.a   = sa + da * keep
out.rgb = (src.rgb*sa + dst.rgb*da*keep) / out.a
```

in `f64` with the same single quantization per channel. Attenuating the source
(and not interpolating linearly towards the destination) is what makes an
antialiased edge behave correctly over a translucent target, and it makes
"fully covered" and "partial coverage of a half-alpha source" agree.
Two equal-area fractions of different colors therefore add up to the same result
whichever way the edge is covered.

Partially covered pixels deliberately **do not write depth**: they are
translucent, and letting them occlude would erase the geometry behind the hairline
they just added. `Stats.antialiased_pixels` counts them; `Stats.pixels` counts
every resolved pixel once (not once per sub-sample contribution).

### Cost

Antialiasing only spends work on edge pixels — the interior of a large triangle
takes the two-comparison fast path — but the accumulation indirection, the
per-pixel slot bookkeeping and the deferred resolve pass are real. Measured on the
same harness (1024 quads tiled across the target, projection shifted half a pixel
on X so every tile has fractional edges):

| Target | One sample | `.edge` | Relative |
| --- | --- | --- | --- |
| 256×256 | 2.3 ms | 12.6 ms | ~5.5× |
| 512×512 | 7.5 ms | 19.6 ms | ~2.6× |
| 1024×1024 | 27.3 ms | 40.9 ms | ~1.5× |

Small tiles are dominated by the per-draw scratch sizing (1024 draws), large ones
by fill, and the ~1024² case is the one the ratio is meaningful for. Antialiasing
is opt-in for exactly this reason; the default path is unchanged in cost.

### Verification

- **Area conservation.** A slanted quad's alpha sum, converted to pixels, equals
  the quad's exact shoelace screen area. Measured 167.40 px against 167.04 px
  (0.2%) with a 0.5% tolerance — a binary rasterizer lands 2 px (1.2%) short here
  and cannot pass. This is the numerical statement that coverage integrates.
- **Coverage per pixel**, brute-force cross-checked: `coverageCount` is tested
  against a direct sub-sample loop over the same three edge functions for the
  pixel centers of a triangle, so the incremental stepping is pinned to the
  definition rather than to itself.
- **Partition.** A quad split into two triangles has its coverage sum to 16 for
  every interior pixel: no seam and no double count.
- **Full coverage is bit-identical.** A grid-aligned quad renders byte-identical
  color and depth to the one-sample path, with `antialiased_pixels == 0`.
- **Partial pixels never write depth**, fully covered ones always do.
- **Translucent composite.** Partial coverage over a partly transparent target
  matches the source-over formula hand-computed in the test.
- **Allocation failure.** `checkAllAllocationFailures` sweeps every allocation
  site of `drawMeshAlloc`/`rasterizeAlloc` and asserts a clean `OutOfMemory` with
  no partial writes and no leaked scratch.
- **No regression on the default path.** The four reference corpora
  ([`raster_vectors.zig`](../src/render/raster_vectors.zig) and the blend, texture
  and light corpora, 206 cases) are byte-identical with the feature present,
  because `antialias = .none` is the default and the AA code is not on that path.

## Textures

`Texture` is a borrowed RGBA8 buffer — `width * height * 4` bytes, row-major,
top-down; `v = 0` is the top row of the image, matching both the framebuffer's
top-down layout and every image codec `assets.image` decodes. `Filter` selects
`nearest` or `bilinear` magnification. Repeat wrap is unconditional: the wrapped
coordinate is `u - floor(u)`, so negative UVs wrap correctly too.

Per pixel (`den = (Σλ_i·w_inv_i) / area`):

```
u = (Σλ_i·uw_i / area) / den,  v = (Σλ_i·vw_i / area) / den
```

evaluated in `f64` with a pinned operation order. `λ` is the perspective-correct
barycentric weight (the same `w + bias` the fixed-point coverage uses). If `den`
is not strictly positive and finite the pixel samples `uv = (0, 0)` — a degenerate
`w` gradient cannot produce a NaN pixel.

Sampling:

- **Nearest:** `x = min(n - 1, floor(frac(u) * n))` per axis.
- **Bilinear:** texel centers at `t = frac(u) * n - 0.5`; `fx = t - floor(t)`;
  taps at `floor(t)` and `floor(t) + 1` wrapping mod `n`;
  `out = floor((top * (1 - fy) + bottom * fy) + 0.5)` per channel, where
  `top`/`bottom` mix the two columns with `fx`. A single final rounding, never
  intermediate rounding.
- **Tint:** the sampled texel is multiplied per channel (including alpha) by the
  material tint: `out = floor(t * tint / 255 + 0.5)`. No premultiply: the shading
  result is straight (non-premultiplied) alpha, which is what the `.alpha` blend
  mode expects — see [Blending](#blending).

Texture and material resolution happen **once per draw command**, before any
pixel is written: a malformed texture (`validate()` rejects zero dimensions,
dimensions above `max_dimension`, or a pixel-buffer length mismatch with
`error.InvalidTexture`) aborts the command before touching the target; a mesh
without usable `uvs` skips the command (`skipped_draws`), also before any draw.

### Minification: mipmaps and LOD selection

A texture that covers fewer pixels than it has texels aliases hard under both
filters: nearest picks an arbitrary texel per pixel (moire), bilinear still
averages only 2x2 of them. `Texture.mips` is the fix — a **mip chain** below level
0, and `Options.mipmap` decides whether the sampler uses it.

| Field / value | Meaning |
| --- | --- |
| `Texture.mips: []const MipLevel` | Levels 1..n, **largest first**, each exactly half of the one above (floored, never below 1). Empty (default) means level 0 only — every pre-mipmap behaviour is unchanged, byte for byte. |
| `MipLevel` | `{ width, height, pixels }`, RGBA8 row-major top-down, same layout as `Texture.pixels`. |
| `Options.mipmap = .trilinear` | Default. Pick the level per pixel from the screen-space UV gradient and mix the two neighbouring levels. |
| `Options.mipmap = .level0` | Always sample level 0: crisp pixel art, aliasing under minification. |

`corex.render.mipmap.Chain.generate(gpa, width, height, pixels)` builds the
levels below level 0 with an **integer box filter** — `(sum + count/2) / count`
per channel, one round-half-up, no float — and an odd axis shares its last row or
column with the previous destination texel instead of dropping it, so the chain
conserves energy. The chain owns one allocation; `levels()` is what
`Texture.mips` wants. `Texture.validate()` rejects a chain that is not exactly
repeated halving (or a level after 1x1), so a hand-built chain cannot silently
desynchronize from the LOD selection.

**Level selection.** With `u = p / den` (the perspective-correct mapping), the
exact per-pixel derivative is `(dp * den - p * dden) / den²`. `dp`, `dq` and
`dden` are the per-pixel changes of the perspective numerator and denominator;
both are affine in screen space, so those six numbers are derived **once per
triangle** from the same per-pixel edge steps the coverage loop already uses:
`d(att) = da * (att0 - att2) + db * (att1 - att2)`, where `da`/`db` are the
per-pixel barycentric steps. The gradient is then

```
rho = max(|du/dx|, |du/dy|, |dv/dx|, |dv/dy|) * size      // texels per pixel
lod = clamp(log2(rho), 0, levels - 1)
```

so one texel per pixel is level 0, two is level 1, and magnifying (rho <= 1)
clamps to 0 — the chain is never touched when magnifying. A zero, negative or
non-finite gradient also selects level 0.

**Trilinear.** `floor(lod)` and `ceil(lod)` are each filtered with the material's
`filter` (nearest or bilinear) and the two results are mixed channel-wise in
`f64` with **one final round**:
`out = floor(fine * (1 - t) + coarse * t + 0.5)`. An integral `lod` does a single
fetch, and `level0` through the trilinear path reproduces the plain sampler byte
for byte.

**Fast path.** When every vertex of a triangle carries the same `w_inv` (every
orthographic projection, and any affine UV map) the denominator is constant, so
`dden == 0`, the derivative reduces to `dp * den / den² = dp / den`, and the level
is the **same for every pixel**. `GradSteps.constantLod` detects that and hoists
the `log2` to once per triangle — the per-pixel cost becomes a compare and a
select. Values are bit-identical to the general path; this is why the orthographic
benchmark below only pays ~1.2x.

Everything else about minification is unchanged: **no anisotropic filtering**
(the gradient takes the larger axis, which over-blurs grazing angles), one
gradient per pixel rather than per sample, no LOD bias or `textureQueryLod`, no
gamma-correct downsampling.

Not implemented: anisotropic filtering, sRGB transfer, or wrap modes other than
repeat. Without a mip chain a minified texture still aliases — build one with
`mipmap.Chain.generate`. The sampling math (filters, LOD and the trilinear mix) is
pinned to the reference in `tools/gen_raster_texture_vectors.py`; changing any
expression there requires regenerating
[`src/render/raster_texture_vectors.zig`](../src/render/raster_texture_vectors.zig)
and the tests will fail loudly until both sides agree bit for bit.

## Lighting

A single directional light shades both the flat and the textured path with a
Lambert term. `Light` is a plain struct:

| Field | Meaning |
| --- | --- |
| `direction: [3]f32` | Direction **toward** the light, world space. Not normalized — the implementation normalizes in `f64`. |
| `color: [3]f32` | Diffuse multiplier per channel. Values above 1.0 are legal (HDR). Defaults to white. |
| `ambient: [3]f32` | Constant fill added regardless of facing, per channel. Defaults to `{0.15, 0.15, 0.15}`. |

Configure it with `Options.light` (per draw), or give the `resources` object
passed to `rasterize` an optional `pub fn directionalLight(self) ?Light` —
resolved once per draw command, mirroring the `mesh`/`color`/`texture`
providers. An explicit `Options.light` wins over the provider.

Per surviving triangle (after culling):

1. **World-space face normal.** Each winning vertex's world-space position is
   mapped to `f64` with the `world * position` product (column-major `Mat4`),
   and `faceNormal` returns the raw cross product `n = cross(b - a, c - a)` of
   the world-space edge vectors.
2. **Normalized in `f64`:** `nrm = sqrt((n0*n0 + n1*n1) + n2*n2)`. A zero or
   non-finite length produces an ambient-only result for that triangle.
3. `dot = max(0, n . l)` with `l` the normalized light direction; per channel
   `lm = ambient + dot * color` — deliberately **unclamped** (HDR-legal).
4. **Applied:** flat — `rgb = clampByte(tint * lm)`, alpha verbatim;
   textured — texel and tint multiply first, then the light:
   `rgb = clampByte(((t * tint) * lm) / 255)`, alpha stays the unlit
   `floor(t*a/255 + 0.5)` rounding. `clampByte(s) = floor(min(max(s, 0), 255) + 0.5)`
   — multipliers above 1 clamp at the final quantize, never before.

Malformed lights are a hard error: `Light.validate()` runs at the `drawMesh`
entry — every draw path funnels through `drawMesh` — and rejects a zero-length
or non-finite direction, or any negative/non-finite color or ambient channel,
with `error.InvalidLight` **before a single pixel or depth value is written**.

This is a face-lighting (flat-shaded) model: all fragments of a triangle share
its geometric normal. No per-vertex normals, vertex colors, specular terms,
point/spot lights or shadows — see
[Limitations and next steps](#limitations-and-next-steps). The lighting math is
pinned to the reference in `tools/gen_raster_light_vectors.py`; changing any
expression there requires regenerating
[`src/render/raster_light_vectors.zig`](../src/render/raster_light_vectors.zig)
and the tests will fail loudly until both sides agree bit for bit.

## Verification

- **73 reference vectors** in `src/render/raster_vectors.zig`, generated by
  [`tools/gen_raster_vectors.py`](../tools/gen_raster_vectors.py). The reference
  deliberately does *not* mirror the implementation: it evaluates all three edge
  functions from scratch for **every pixel of the target** with Python
  arbitrary-precision integers, with no bounding box and no incremental stepping.
  Agreement therefore validates the stepping, the bbox clamp and the fill-rule
  bias independently. Coverage masks and `f32` depth **bit patterns** must match
  exactly — 866 covered pixels across the corpus. CI never runs the generator.
- **78 texture reference frames** in `src/render/raster_texture_vectors.zig`,
  generated by [`tools/gen_raster_texture_vectors.py`](../tools/gen_raster_texture_vectors.py)
  (same brute-force coverage). UVs are carried as pre-divided `uw`/`vw`/`w_inv`
  tuples, and the Python reference recomputes the perspective-correct
  interpolation, both filters, repeat wrap (including negative UVs), tint
  multiply and rounding from scratch; the tests compare the **full RGBA8 frame**
  plus coverage, so alpha writes and tint rounding are pinned as well. 34 of the
  cases are mipmapped (a 16x16 level 0 with 8 levels below it, and a 4x4 level 0
  with 2; the generator rebuilds both chains with the same integer box filter and
  recomputes the per-pixel LOD derivative and the trilinear mix); 1094 covered
  pixels across the corpus, all bit-exact.
- **40 lit reference frames** in `src/render/raster_light_vectors.zig`,
  generated by [`tools/gen_raster_light_vectors.py`](../tools/gen_raster_light_vectors.py)
  (same brute-force coverage). The raw world-space face normal is an input per
  case; both sides normalize it in `f64`, compute `dot = max(0, n . l)` and
  `lm = ambient + dot * color` with pinned operation order, and clamp only at
  the final byte quantize. Full RGBA8 frames plus coverage bit-match — 670
  covered pixels across the corpus.
- **49 blend reference frames** in `src/render/raster_blend_vectors.zig`,
  generated by [`tools/gen_raster_blend_vectors.py`](../tools/gen_raster_blend_vectors.py)
  (same brute-force coverage). Each case starts from a **non-empty target**, shades
  one triangle with the flat/textured/Lambert rules above, and composites it with
  one of the four modes; the Python reference recomputes the blend from first
  principles in the pinned `f64` order. Full RGBA8 frames plus coverage must match
  bit for bit — 801 covered pixels across the corpus, covering every mode, opaque
  and transparent sources and destinations, saturation, and textured/lit sources.
- **Blending unit tests.** Per-mode math is pinned by hand (half-alpha red over
  opaque blue gives `{128, 0, 127, 255}` in `.alpha` and `.premultiplied`, and
  `{128, 0, 255, 255}` in `.additive`); a fully transparent source is an exact
  no-op in every mode; `.alpha` over a fully transparent destination yields
  transparent black instead of dividing by zero; alpha accumulates to full
  coverage over a partly transparent target; `.additive` saturates at 255;
  a test proves the default `.none` path is byte-identical to the pre-blending
  write (color *and* depth) for a transparent tint; and `rasterize` applies the
  mode to every command.
- **Lighting unit tests.** `Light.validate()` rejects zero-length/non-finite
  directions and negative/non-finite channels (HDR accepted); an invalid light
  fails in `drawMesh` before any draw; a facing-away face renders ambient-only;
  a perpendicular face contributes exactly the ambient term; a reversed-winding
  triangle lights from the world-space normal with culling off; a translated
  world does not bend the normal; lit+textured albedo multiplies through the
  multiplier and rounds once; the `directionalLight()` provider shades draws and
  an explicit `Options.light` wins over it.
- **Cross-layer lit integration tests** in
  [`src/render/raster_image_test.zig`](../src/render/raster_image_test.zig)
  (composition root): scene → extraction → rasterizer with a
  `directionalLight()` provider — full-diffuse, ambient-only and oblique dots
  pinned per channel; a 180-degree world rotation faces the quad away from the
  light (culled by default, ambient-only with culling off); an explicit
  `Options.light` wins over the provider through the full path.
- **Cross-layer blended integration test** (same composition root): a scene with an
  opaque far quad and a half-transparent near quad goes through
  `extractDrawList(.back_to_front)` → `rasterize(.blend = .alpha)`, asserting the
  near quad is composited last and the center pixel is exactly `{128, 0, 127, 255}`,
  then round-trips through the QOI codec byte for byte.
- **Watertightness property test.** A quad split into triangles is rasterized
  piecewise into separate targets; the coverage counts must sum to the quad area
  (no overlap) and their union must cover it (no gap). Repeated over ten
  subpixel-perturbed diagonals, which is exactly where a float edge function
  cracks.
- **Hand-computed coverage.** A right triangle whose covered pixel set is derived
  analytically, pinning the fill-rule convention rather than just its consistency.
- **Analytic depth tests.** Linear gradient across a triangle, order independence
  (near wins whether drawn first or last), equal-depth rejection, and the two
  independent flag combinations.
- **Clipping.** Fully-behind and beyond-far rejection, a near-straddling triangle,
  a vertex exactly at the eye (no NaN), a huge off-screen triangle, and a direct
  test that the six-plane clip never exceeds nine vertices.
- **End to end.** A real `Scene` with `Transform` + `Renderable` goes through
  `extractDrawList` and into `rasterize`, with the covered box computed from the
  camera's field of view.
- **Cross-layer roundtrip.** `src/render/raster_image_test.zig` renders two
  overlapping quads from a scene, hands the rasterizer's own buffer to
  `assets.image.encodeQoi`, decodes it back and asserts the pixels are byte-identical.
  It lives at the composition root so the rasterizer itself keeps no dependency on
  the asset layer. A second case does the same for a textured render (nearest
  sampling, tint multiply on near and far quads, alpha verbatim).

## Performance

ReleaseFast, best of five runs, 1024 quads (2048 triangles) tiled across the
target, x86-64:

| Target | Pixels covered | Time | Fill rate | Triangles/s |
| --- | --- | --- | --- | --- |
| 256×256 | 65 536 | 0.447 ms | 146.7 Mpx/s | 4.58 M |
| 512×512 | 262 144 | 1.091 ms | 240.2 Mpx/s | 1.88 M |
| 1024×1024 | 1 048 576 | 3.654 ms | 287.0 Mpx/s | 0.56 M |

Small triangles are setup-bound; large ones approach the scalar fill limit. The
per-pixel `f64` interpolation is deliberately kept rather than stepped
incrementally in float, because incremental float accumulation would drift and
break bit-exact reproducibility. When a light is configured, its multiplier is
computed once per surviving triangle (one normalize + one dot); per pixel it
adds only one `f64` multiply per RGB channel. The lit path has not been
benchmarked separately — no fill-rate claim is made for it.

Blending adds a fixed per-pixel cost and no per-triangle cost. Measured with the
same harness on the same machine (Intel Xeon @ 2.60GHz, 2 vCPU, 1024 quads, full
coverage, 50%-alpha tint, `.none` re-measured for scale):

| Target | `.none` | `.alpha` | `.additive` | `.alpha` vs `.none` |
| --- | --- | --- | --- | --- |
| 256×256 | 0.662 ms | 1.540 ms | 1.330 ms | ~2.3× |
| 512×512 | 1.965 ms | 5.848 ms | 4.795 ms | ~3.0× |
| 1024×1024 | 6.601 ms | 20.836 ms | 17.437 ms | ~3.2× |

The cost is the `f64` normalization of both pixels, the composite itself and the
second quantization. `.none` keeps a branch on the mode *outside* the arithmetic
and returns the shaded fragment untouched, so callers that do not opt in pay only
that branch. Both sides of every operation are kept in the reference generator —
tightening the arithmetic requires regenerating
[`src/render/raster_blend_vectors.zig`](../src/render/raster_blend_vectors.zig).

### Textured path

Measured with the committed harness (`zig build bench -Doptimize=ReleaseFast`,
[`tools/bench_raster.zig`](../tools/bench_raster.zig); not run in CI) on an Intel
Xeon @ 2.60GHz (2 vCPU), 1024 quads, 64×64 RGBA8 texture, repeat wrap, white
tint, full coverage. The flat path re-measured on this machine is in the last
column for a valid relative comparison; the absolute flat numbers are consistent
with the table above within run-to-run variance.

| Path | 256×256 | 512×512 | 1024×1024 | Relative cost @1024² |
| --- | --- | --- | --- | --- |
| Flat (re-measured) | 0.382 ms | 1.162 ms | 3.948 ms | 1× (265.6 Mpx/s) |
| Nearest | 0.940 ms (69.7 Mpx/s) | 3.350 ms (78.2 Mpx/s) | 13.075 ms (80.2 Mpx/s) | ~3.3× |
| Bilinear | 2.455 ms (26.7 Mpx/s) | 9.514 ms (27.6 Mpx/s) | 35.829 ms (29.3 Mpx/s) | ~9.1× |

Minification through the mip chain, measured with the same harness: the shared
tiles sample a 512x512 texture at 8 UV units per 32-pixel tile, i.e. 128 texels
per pixel (level 7 — the case mipmaps exist for).

| Target | Level 0 only | Trilinear (mip chain) | Relative |
| --- | --- | --- | --- |
| 256×256 | 4.96 ms | 5.92 ms | ~1.2× |
| 512×512 | 17.76 ms | 20.69 ms | ~1.2× |
| 1024×1024 | 68.62 ms | 79.84 ms | ~1.2× |

The ~1.2x is the constant-level fast path: the UV map is affine here, so the level
is hoisted out of the pixel loop and the per-pixel cost is a select plus one extra
fetch. With a perspective divide in play (a varying denominator) the level has to
be recomputed per pixel — one derivative and one `log2` — and the same draw costs
about 2x. Both numbers are the price of not aliasing; `mipmap = .level0` keeps the
old cost exactly.

Bilinear is disproportionately expensive because of the per-pixel `f64`
perspective correction: two divides by `Σλ·w_inv` per pixel. Replacing them with
`x * (1/den)` would double-round and silently diverge from the pinned vectors,
so it is deliberately not done — a reciprocal must be introduced in both
references (or not at all). Nearest costs one texel fetch and a clamp; bilinear
costs four fetches, four taps weighted in `f64` and two `f64` divides. Both
numbers are honest scalar upper bounds of the current implementation, not
aspirational targets: SIMD texel gathering, a reciprocal fast path guarded by
exactness checks, and mipmaps all remain future work.

The one-sample pixel path takes no allocator and uses only fixed stack scratch, so
it cannot allocate and cannot fail with `OutOfMemory`. The only allocation in the
rasterizer is the per-draw scratch of `antialias = .edge`, made through the
caller's allocator by `rasterizeAlloc` / `drawMeshAlloc` — the allocator-free
entry points never reach it.
The caller's `color` slice is plain RGBA8 — exactly `assets.image.Image.pixels` —
so a rendered frame can be written as an image with no copy and no reformat:

```zig
const img = corex.assets.image.Image{
    .width = target.width, .height = target.height, .pixels = target.color,
};
const bytes = try corex.assets.image.encodeQoi(gpa, img);
defer gpa.free(bytes);
```

See [asset-decoders.md](asset-decoders.md) for the codec.

## Limitations and next steps

- **Flat Lambert per-face lighting only.** One directional light (`Options.light`
  or a `resources.directionalLight()` provider), applied with the geometric
  (face) normal — no per-vertex normals, vertex colors, specular terms,
  point/spot lights, shadow mapping or multiple lights.
- **Blending is per-fragment, in submission order.** Four modes exist (`.none`,
  `.alpha`, `.premultiplied`, `.additive`) but there is no order-independent
  transparency, no depth pre-pass, no per-command sort inside the rasterizer and
  no separate blend function for RGB vs alpha. Correct transparency is the
  caller's responsibility: sort `back_to_front` (extraction already can) and, for
  multi-surface transparency, disable `depth_write`.
- **Edge antialiasing is 16x coverage supersampling, and it is opt-in.**
  `antialias = .edge` fixes staircase edges and vanishing thin geometry, but it
  costs 1.5x to 5.5x depending on how much of the frame is edge (see
  [Cost](#cost)), needs per-draw scratch and therefore an allocator. It does not
  antialias *within* a pixel for textured minification — that is mipmapping's job.
- **Mip selection is isotropic.** The LOD takes the larger axis of the UV
  gradient, so a surface seen at a grazing angle over-blurs where anisotropic
  filtering would not. There is no LOD bias, no per-material level clamp and no
  `textureQueryLod`; a texture without `mips` still minifies by point sampling
  level 0 and aliases.
- **No GPU backend.** This is a CPU reference path, not a Renderer Low tier.
- **Single-threaded.** No tile parallelism or binning; a frame is rasterized in
  submission order on the calling thread.
- **No scissor, stencil, viewport offset or wireframe.** The viewport is always
  the whole target.
- **No sRGB conversion.** `color` quantizes linear values directly; a transfer
  function belongs with the material system.

## Related

- Draw-list extraction: [render-extraction.md](render-extraction.md)
- Mesh decoding / `CXMH`: [mesh-import.md](mesh-import.md)
- Image encoding (QOI): [asset-decoders.md](asset-decoders.md)
- World transforms: [scene-transforms.md](scene-transforms.md)
- Architecture: [architecture.md](architecture.md)
- Scope and tiers: [scope.md](scope.md)
- Versioning: [versioning.md](versioning.md)
