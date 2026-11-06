# Software rasterizer

`corex.render.raster` turns an extracted draw list into pixels on the CPU. It is
the first stage of the engine that produces an image: before it, the render
subsystem only culled geometry and sorted draw commands.

There is no GPU dependency, no window system and no allocator in the pixel path,
so the whole backend runs headlessly and is covered by the normal test suite.
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
   multiplied by that tint.

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
| `Texture` | `width`/`height`, borrowed `pixels` RGBA8 (row-major, top-down), `filter`. `validate()` rejects zero/oversized dims and length mismatches with `InvalidTexture`. |
| `Filter` | `nearest` or `bilinear`. |
| `Options` | `cull` (`.none`/`.back`/`.front`), `front_face`, `depth_test`, `depth_write`. |
| `Stats` | `skipped_draws`, `submitted`, `clipped`, `culled`, `rasterized`, `pixels`. |
| `rasterize` | Whole draw list, resolving handles through `resources`. |
| `drawMesh` | One mesh, one world matrix, one flat RGBA8 tint, optional texture. |
| `rasterTriangle` | One screen-space triangle; the entry point the vectors target. |

`max_dimension` is 16384 per side, which bounds both the fixed-point range and the
pixel count. Errors are `InvalidTarget`, `InvalidDimension`, `InvalidIndex`
(index past the position array, or an index count that is not a multiple of
three), `InvalidUv` (a mesh whose `uvs` are missing or shorter than its
`positions` when a texture is bound) and `InvalidTexture` (malformed texture).

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
pub fn color(self: @This(), handle: u32) ?[4]f32   // linear RGBA in [0, 1]
pub fn texture(self: @This(), handle: u32) ?Texture // optional, see below
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

Omitting `fn texture` from the provider (or returning null) keeps the flat path;
the material tint is the shade color exactly as before.

Because `resources` is a comptime parameter there is no vtable and no indirect
call per vertex.

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
  material tint: `out = floor(t * tint / 255 + 0.5)`. No premultiply, no blending —
  alpha is written verbatim.

Texture and material resolution happen **once per draw command**, before any
pixel is written: a malformed texture (`validate()` rejects zero dimensions,
dimensions above `max_dimension`, or a pixel-buffer length mismatch with
`error.InvalidTexture`) aborts the command before touching the target; a mesh
without usable `uvs` skips the command (`skipped_draws`), also before any draw.

Not implemented: mipmaps/LOD selection, anisotropic filtering, sRGB transfer,
wrap modes other than repeat, or premultiplied alpha. Minified textures will
alias — generate small enough mip images offline. The sampling math is pinned
to the reference in `tools/gen_raster_texture_vectors.py`; changing any
expression there requires regenerating
[`src/render/raster_texture_vectors.zig`](../src/render/raster_texture_vectors.zig)
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
- **44 texture reference frames** in `src/render/raster_texture_vectors.zig`,
  generated by [`tools/gen_raster_texture_vectors.py`](../tools/gen_raster_texture_vectors.py)
  (same brute-force coverage). UVs are carried as pre-divided `uw`/`vw`/`w_inv`
  tuples, and the Python reference recomputes the perspective-correct
  interpolation, both filters, repeat wrap (including negative UVs), tint
  multiply and rounding from scratch; the tests compare the **full RGBA8 frame**
  plus coverage, so alpha writes and tint rounding are pinned as well — 576
  covered pixels across the corpus, all bit-exact.
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
break bit-exact reproducibility. The textured path was not separately profiled;
it adds one sample and one multiply per covered pixel on the flat path.

The pixel path takes no allocator and uses only fixed stack scratch, so it cannot
allocate, cannot fail with `OutOfMemory`, and is safe to call from a render thread.
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

- **No vertex colors, normals or lighting.** Materials carry a flat linear RGBA
  tint multiplied by an optional texture sample — there is no shading model of
  any kind beyond that.
- **No blending or transparency.** Alpha is written to the framebuffer verbatim,
  not composited. `back_to_front` sorting exists in the extraction layer but has
  nothing to blend against here.
- **No antialiasing, mipmaps or LOD selection.** One sample per pixel, no MSAA.
  Minification aliases.
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
