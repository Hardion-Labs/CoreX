//! Software triangle rasterizer: the CPU backend that turns a draw list into
//! pixels. No GPU, no windowing, no allocator in the pixel path.
//!
//! Pipeline per triangle: world + view-projection transform to clip space,
//! Sutherland-Hodgman clipping against all six frustum planes, perspective
//! divide, viewport transform with a Y flip, then fixed-point edge-function
//! rasterization with a top-left fill rule, backface culling and an f32 depth
//! buffer.
//!
//! Why fixed point: snapping screen coordinates to 1/16 of a pixel makes every
//! edge function an exact `i64` expression. Coverage is therefore *bit-exactly*
//! reproducible and independent of float rounding, and adjacent triangles that
//! share an edge neither double-draw nor leave a gap. The fill rule is what
//! guarantees that, and a test proves it by counting coverage across a split
//! quad.
//!
//! Depth is NDC `z` in [-1, 1]. After the perspective divide, `z` is affine in
//! screen space, so it interpolates linearly from the barycentric weights with no
//! per-pixel perspective correction. Attributes such as UVs are interpolated
//! with a full perspective correction: each vertex stores `uw = u / w`,
//! `vw = v / w` and `w_inv = 1 / w` (clip space), which are linearly interpolated
//! and divided through at the end of the pixel.
//!
//! Textures are borrowed, decoded RGBA8 buffers (`Texture`) with repeat wrap and
//! nearest/bilinear filtering. A `Texture` may carry a mip chain (`mips`); with
//! one, `Options.mipmap = .trilinear` picks the level per pixel from the exact
//! screen-space UV gradient and mixes the two neighbouring levels, which is what
//! removes minification aliasing. A sampled texel is multiplied by the material's
//! linear RGBA tint. The resulting fragment is written verbatim by default, or
//! composited with the target using `Options.blend` (straight-alpha source-over,
//! premultiplied or additive) — see `Blend`.
//!
//! Coupling: geometry and materials arrive through a duck-typed `resources`
//! value, so this module never imports the asset layer. A caller adapts
//! `assets.mesh.MeshView` (or plain arrays) with a few lines; see the tests.
//!
//! Lighting is one optional directional Lambert term; blending is per-fragment
//! in submission order (no order-independent transparency). Not implemented,
//! and not claimed: MSAA, anisotropic filtering, or any GPU path.

const std = @import("std");
const draw = @import("draw.zig");
const mip = @import("mipmap.zig");
const transform = @import("../scene/transform.zig");

const Allocator = std.mem.Allocator;
const Mat4 = transform.Mat4;
const Vec3 = transform.Vec3;
const DrawCommand = draw.DrawCommand;

pub const Error = error{
    /// The color/depth slices do not match the requested dimensions.
    InvalidTarget,
    /// A dimension is zero or exceeds `max_dimension`.
    InvalidDimension,
    /// A mesh index points past its position array.
    InvalidIndex,
    /// A position or UV coordinate is NaN or infinite.
    InvalidVertex,
    /// The UV array is missing or does not hold one entry per position while
    /// a textured draw was requested.
    InvalidUv,
    /// A texture's dimensions are zero, exceed `max_dimension`, or its pixel
    /// slice does not hold exactly `width * height * 4` bytes.
    InvalidTexture,
    /// A light is mis-shaped: direction is non-finite or zero-length, or a
    /// color/ambient channel is negative or non-finite.
    InvalidLight,
};

/// `Error` plus the allocation failure an antialiased draw can report (`OutOfMemory`
/// surfaces before any pixel is written, so the target is never half-rendered).
pub const DrawError = Error || error{OutOfMemory};

/// Largest framebuffer side. Bounds the fixed-point range and the pixel count.
pub const max_dimension: u32 = 16384;

/// Subpixel precision: screen coordinates are stored in 28.4 fixed point.
pub const subpixel_bits: u5 = 4;
pub const subpixel_scale: i32 = 1 << subpixel_bits;

/// Which triangle orientation faces the camera, in NDC (before the Y flip).
pub const FrontFace = enum { counter_clockwise, clockwise };

pub const CullMode = enum { none, back, front };

/// Texture magnification filter.
pub const Filter = enum { nearest, bilinear };

/// How a shaded fragment is combined with what the target already holds.
///
/// Every mode is evaluated in `f64` with a single pinned operation order and
/// quantized once, so results are reproducible bit for bit:
///
/// ```
/// sa = src.a / 255            da = dst.a / 255            keep = 1 - sa
/// out.a = sa + da * keep                       (all blending modes)
/// ```
///
/// `none` writes the fragment verbatim (the pre-blending behaviour) and is
/// the default. `alpha` treats both sides as straight (non-premultiplied)
/// alpha and does source-over — the target's RGB is read as straight, so the
/// result is `(src*src.a + dst*dst.a*keep) / out.a`; a fully transparent
/// result is transparent black. `premultiplied` composites into a target that
/// already stores premultiplied RGB: the straight-alpha fragment is
/// premultiplied here and added to `dst * keep`. `additive` adds the
/// source scaled by its own alpha to the target (then clamps). Alpha of the
/// target is composited in every mode, so a transparent destination keeps its
/// coverage.
pub const Blend = enum { none, alpha, premultiplied, additive };

/// Edge antialiasing strategy.
///
/// `none` (the default) is the classic one-sample rasterizer: a pixel center is
/// either inside or outside, and the whole fragment is written or not. It stays
/// bit-identical to the behaviour before antialiasing existed.
///
/// `edge` turns partially covered pixels into translucent fragments. Coverage is
/// estimated from the three fixed-point edge functions as the fraction of a
/// 4x4 sub-sample grid (offsets `(i + 0.5) / 4`, i.e. 16 exact sample points per
/// pixel) that lies inside the triangle, computed with integers only. The
/// fragment is then composited the same way as any other: alpha is scaled by
/// coverage and the destination is pulled towards it proportionally, so a
/// triangle edge blends into whatever is already on the target — including a
/// neighbouring triangle sharing that edge, which is what removes the staircase
/// without erasing the geometric partition.
///
/// Resolution happens **once per draw command**, not per fragment: sub-sample
/// coverage, shaded color and depth are accumulated into caller-owned scratch
/// (`drawMesh`/`rasterize` allocate it from their allocator, so `rasterTriangle`
/// on its own cannot antialias) and each touched pixel is composited exactly
/// once. That is what keeps shared interior edges between two triangles of the
/// same mesh watertight and free of a seam — the classic failure of per-fragment
/// alpha AA.
///
/// Consequences worth knowing before opting in: the result is no longer
/// bit-comparable with the reference corpora, a partially covered pixel never
/// writes depth (`depth_write` is ignored for it, because a translucent fragment
/// must not occlude), and the cost is 16 coverage samples for edge pixels plus an
/// extra `w*h` accumulation pass over the draw's bounding box.
pub const Antialias = enum { none, edge };

/// Sub-samples per pixel axis used by `Antialias.edge`: a 4x4 grid, 16 exact
/// integer sample points.
pub const aa_grid: u5 = 4;
/// Coverage maximum (`aa_grid * aa_grid`). Coverage is `0..=aa_samples`.
pub const aa_samples: u16 = aa_grid * aa_grid;

/// A single directional light for the Lambert shading path, set through
/// `Options.light` (or supplied by the duck-typed `resources` via an optional
/// `pub fn directionalLight(self) ?Light`, mirroring `texture()`).
///
/// `direction` points FROM the surface TOWARD the light, in world space; any
/// nonzero length works — it is normalized internally per triangle with a
/// pinned f64 operation order. `color` is the light's linear RGB radiance and
/// `ambient` the constant linear RGB fill term; the pixel multiplier is
/// `ambient + max(0, n · l) * color` per channel, unclamped (channels may
/// exceed 1); clamping to [0, 1] happens exactly once, at the final multiply.
/// Both `color` and `ambient` must be finite and non-negative. Light never
/// touches the alpha channel.
pub const Light = struct {
    direction: [3]f32,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    ambient: [3]f32 = .{ 0.15, 0.15, 0.15 },

    pub fn validate(self: Light) Error!void {
        for (self.direction) |component| {
            if (!std.math.isFinite(component)) return error.InvalidLight;
        }
        const len_sq = @as(f64, @floatCast(self.direction[0])) * @as(f64, @floatCast(self.direction[0])) +
            @as(f64, @floatCast(self.direction[1])) * @as(f64, @floatCast(self.direction[1])) +
            @as(f64, @floatCast(self.direction[2])) * @as(f64, @floatCast(self.direction[2]));
        // Reject both zero-length and a length so tiny it underflows to zero.
        if (!(len_sq > 0.0) or !std.math.isFinite(len_sq)) return error.InvalidLight;
        for (self.color) |component| {
            if (!std.math.isFinite(component) or component < 0.0) return error.InvalidLight;
        }
        for (self.ambient) |component| {
            if (!std.math.isFinite(component) or component < 0.0) return error.InvalidLight;
        }
    }
};

pub const Options = struct {
    cull: CullMode = .back,
    front_face: FrontFace = .counter_clockwise,
    depth_test: bool = true,
    depth_write: bool = true,
    /// Single directional Lambert light for this draw, or null for the flat
    /// path. When set, the per-channel pixel multiplier is
    /// `ambient + max(0, n · l) * color` (linear), applied to the albedo
    /// (tint, or texel × tint) before quantization; alpha is never affected.
    /// `n` is the triangle's world-space face normal — `rasterTriangle`
    /// normalizes the caller-supplied raw normal itself — and `l` the light
    /// direction, normalized per triangle with a pinned f64 evaluation. The
    /// explicit `light` set here wins over any `directionalLight` the
    /// `resources` provider may offer.
    light: ?Light = null,
    /// How each shaded fragment is combined with the target. `none` (the
    /// default) writes it verbatim, which is bit-identical to the behaviour
    /// before blending existed. The transparent modes need the caller to draw
    /// back-to-front — extraction's `back_to_front` sort is what feeds them —
    /// because the rasterizer performs no reordering of its own.
    blend: Blend = .none,
    /// Edge antialiasing. `none` (default) keeps the one-sample rasterizer
    /// byte-identical to before; `.edge` composites partially covered edge
    /// pixels as translucent fragments. See `Antialias` for the guarantees each
    /// mode does and does not give.
    antialias: Antialias = .none,
    /// How a textured draw picks the mip level to sample. Only matters for a
    /// `Texture` that carries `mips`; without them every mode samples level 0,
    /// which is the pre-mipmap behaviour byte for byte.
    mipmap: Mipmap = .trilinear,
    /// Per-draw refinement of that choice: level bias and a tap-count cap. The
    /// default biases nothing and caps nothing, so every image produced before
    /// this field existed is reproduced byte for byte.
    sampling: Sampling = .{},
};

/// Refinement of the mip choice for one draw — the per-material controls a real
/// renderer exposes, expressed as plain data so they can travel through the
/// resource provider instead of through every command.
///
/// Both fields exist for the same reason: **the footprint is an estimate**. A LOD
/// bias corrects for content or a projection the derivative does not know about
/// (sharpen a signature, blur a distant sign), and a tap cap trades anisotropic
/// quality for time on a material drawn many times.
///
/// Neither changes the level selection *rule*: the bias is added after the LOD is
/// computed and the cap is applied to the tap count, so a `.level0` draw and an
/// untextured draw are unaffected.
pub const Sampling = struct {
    /// Added to the computed level, in levels. Positive values sample **smaller**
    /// levels (sharper, more aliasing), negative values sample larger ones
    /// (blurrier). The result is clamped to the chain, so a large bias cannot read
    /// past the last level.
    lod_bias: f64 = 0.0,
    /// Largest number of anisotropic taps this draw may take. `0` means "the
    /// global default" (`max_aniso_samples`), not "none": a cap of zero taps would
    /// mean no sampling at all, which is not a thing a caller can ask for.
    /// Values above the global maximum are clamped to it.
    max_samples: u8 = 0,

    /// The cap actually in force, `1..max_aniso_samples`.
    pub fn tapCap(self: Sampling) u8 {
        if (self.max_samples == 0) return max_aniso_samples;
        return @min(self.max_samples, max_aniso_samples);
    }

    /// Whether this is the do-nothing value, so the hot path can skip the bias
    /// arithmetic entirely. Exact comparison: a caller who sets `0.0` gets the
    /// pre-existing path, and any non-zero bias is honoured.
    pub fn isIdentity(self: Sampling) bool {
        return self.lod_bias == 0.0 and self.max_samples == 0;
    }
};

/// Mip level selection for textured draws.
pub const Mipmap = enum {
    /// Always sample level 0: `filter` magnifies *and* minifies. Aliases when
    /// minifying; use it for pixel-art textures that must stay crisp.
    level0,
    /// Choose the level per pixel from the screen-space UV gradient and mix the
    /// two neighbouring levels (trilinear), so a minified texture averages
    /// instead of aliasing. Costs one extra filtered fetch when the level is
    /// fractional. This is the default and a no-op for a texture without `mips`.
    trilinear,
    /// Trilinear, except when the pixel footprint is elongated (a surface seen at
    /// a grazing angle): up to `max_aniso_samples` taps are taken along the
    /// footprint's longer axis at a correspondingly sharper level, and their
    /// results averaged. This is what stops the over-blur a single level causes
    /// along the short axis. A round footprint takes exactly the trilinear path,
    /// bit for bit. See "Anisotropic minification" in `docs/render-raster.md`.
    anisotropic,
};

/// A triangle vertex in screen space: `x`/`y` are 28.4 fixed point pixels with
/// the origin at the top-left, `z` is NDC depth in [-1, 1]. `uw`/`vw` are the
/// UV coordinates already divided by the clip-space `w` and `w_inv` is its
/// reciprocal (all three as f64) — both are needed for perspective-correct
/// attribute interpolation. They default to pass-through values so callers
/// shading flat colors never need to set them.
pub const ScreenVertex = struct {
    x: i32,
    y: i32,
    z: f32,
    uw: f64 = 0.0,
    vw: f64 = 0.0,
    w_inv: f64 = 1.0,
};

/// Borrowed geometry. Positions and indices are plain typed slices, so this
/// module carries no knowledge of any artifact byte layout. `uvs` is optional:
/// it is only required when the material samples a texture, in which case it
/// must hold exactly one entry per position.
pub const Mesh = struct {
    positions: []const [3]f32,
    /// Triangle list; length must be a multiple of three.
    indices: []const u32,
    uvs: ?[]const [2]f32 = null,
};

/// One mip level of a texture: RGBA8, row-major, top-down, exactly the layout
/// of `Texture.pixels`. `width`/`height` are the level's own (reduced) size.
/// The same type `mipmap.Chain` produces, so a generated chain feeds a
/// `Texture` with no conversion.
pub const MipLevel = mip.Level;

/// A borrowed, decoded texture: RGBA8, row-major, top-down — exactly the
/// layout of `assets.texture`'s `CXTX` pixel payload. `v = 0` samples the
/// first (top) row. Coordinates wrap with repeat addressing (any value maps
/// into the texture).
///
/// Level 0 lives in `width`/`height`/`pixels`; the optional `mips` slice holds
/// the smaller levels, largest first (see `MipChain`), which is what enables
/// minification without aliasing. Without `mips` the texture is level 0 only
/// and sampling stays bit-identical to the pre-mipmap behaviour.
pub const Texture = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, row-major, 4 bytes per pixel (RGBA).
    pixels: []const u8,
    filter: Filter = .bilinear,
    /// Optional mip levels below level 0, largest first. Empty (the default)
    /// means level 0 only: no LOD selection, `filter` magnifies/minifies.
    mips: []const MipLevel = &.{},

    /// Level 0 plus every entry of `mips`, so `mipLevelCount() == 1 + mips.len`.
    /// Returns level 0 itself for an invalid index rather than panicking —
    /// callers derive the index from `lodLevel`, which is bounded by it.
    pub fn mipLevel(self: Texture, index: u32) MipLevel {
        if (index == 0 or index > self.mips.len) return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
        return self.mips[index - 1];
    }

    /// Number of sampling levels: 1 without `mips`.
    pub fn mipLevelCount(self: Texture) u32 {
        return 1 + @as(u32, @intCast(self.mips.len));
    }

    pub fn validate(self: Texture) Error!void {
        if (self.width == 0 or self.height == 0) return error.InvalidTexture;
        if (self.width > max_dimension or self.height > max_dimension) return error.InvalidTexture;
        const expected = @as(usize, self.width) * @as(usize, self.height) * 4;
        if (self.pixels.len != expected) return error.InvalidTexture;
        for (self.mips, 0..) |level, i| {
            // Level i + 1 must be exactly level i halved (floored, never below
            // 1): the chain is the one `mipmap.Chain.generate` builds, so a
            // caller cannot hand in levels that do not line up with the LOD
            // selection.
            const want = mip.levelDims(self.width, self.height, @intCast(i + 1));
            if (level.width != want[0] or level.height != want[1]) return error.InvalidTexture;
            if (level.pixels.len != @as(usize, level.width) * @as(usize, level.height) * 4) return error.InvalidTexture;
            // Nothing can follow the 1x1 level.
            if (want[0] == 1 and want[1] == 1 and i + 1 != self.mips.len) return error.InvalidTexture;
        }
    }
};

pub const Stats = struct {
    /// Draw commands whose mesh or material handle did not resolve.
    skipped_draws: usize = 0,
    /// Triangles read from index buffers.
    submitted: usize = 0,
    /// Triangles entirely outside the frustum, or degenerate after clipping.
    clipped: usize = 0,
    /// Triangles rejected by the cull mode, or zero-area on screen.
    culled: usize = 0,
    /// Triangles that survived clipping and culling. One of these may still
    /// cover no pixel center; `pixels` reports the actual coverage.
    rasterized: usize = 0,
    /// Pixels that passed the depth test and were written (one per covered
    /// pixel, however partially it was covered).
    pixels: usize = 0,
    /// Of `pixels`, how many were written with partial antialiased coverage
    /// (`antialias = .edge`). Always zero with the default one-sample path.
    antialiased_pixels: usize = 0,
    /// True when an `.edge` draw was downgraded to the one-sample path because
    /// the AA scratch would have exceeded `max_aa_scratch_bytes`.
    antialias_downgraded: bool = false,

    pub fn add(self: *Stats, other: Stats) void {
        self.skipped_draws += other.skipped_draws;
        self.submitted += other.submitted;
        self.clipped += other.clipped;
        self.culled += other.culled;
        self.rasterized += other.rasterized;
        self.pixels += other.pixels;
        self.antialiased_pixels += other.antialiased_pixels;
        self.antialias_downgraded = self.antialias_downgraded or other.antialias_downgraded;
    }
};

/// A borrowed RGBA8 color buffer plus an f32 depth buffer of the same size.
pub const Target = struct {
    width: u32,
    height: u32,
    /// Row-major, top-down, 4 bytes per pixel.
    color: []u8,
    depth: []f32,

    pub fn init(width: u32, height: u32, color: []u8, depth: []f32) Error!Target {
        if (width == 0 or height == 0) return error.InvalidDimension;
        if (width > max_dimension or height > max_dimension) return error.InvalidDimension;
        const pixels = @as(usize, width) * @as(usize, height);
        if (depth.len != pixels) return error.InvalidTarget;
        if (color.len != pixels * 4) return error.InvalidTarget;
        return .{ .width = width, .height = height, .color = color, .depth = depth };
    }

    pub fn pixelCount(self: Target) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    /// Reset both buffers. `depth_value` is normally 1 (the far plane).
    pub fn clear(self: *Target, rgba: [4]u8, depth_value: f32) void {
        for (0..self.pixelCount()) |i| {
            self.color[i * 4 + 0] = rgba[0];
            self.color[i * 4 + 1] = rgba[1];
            self.color[i * 4 + 2] = rgba[2];
            self.color[i * 4 + 3] = rgba[3];
            self.depth[i] = depth_value;
        }
    }

    pub fn colorAt(self: Target, x: u32, y: u32) [4]u8 {
        const i = (@as(usize, y) * self.width + x) * 4;
        return .{ self.color[i], self.color[i + 1], self.color[i + 2], self.color[i + 3] };
    }

    pub fn depthAt(self: Target, x: u32, y: u32) f32 {
        return self.depth[@as(usize, y) * self.width + x];
    }
};

// --- fixed-point edge functions --------------------------------------------

/// Twice the signed area of the triangle, in fixed-point units. Positive for the
/// orientation the pixel loop expects.
fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
    const dx = @as(i64, bx) - @as(i64, ax);
    const dy = @as(i64, by) - @as(i64, ay);
    return dx * (@as(i64, py) - ay) - dy * (@as(i64, px) - ax);
}

/// A top-left edge includes pixel centers that land exactly on it; every other
/// edge excludes them. With the normalized (positive-area) winding in a Y-down
/// framebuffer, a top edge runs left-to-right with the interior below it, and a
/// left edge runs upwards with the interior to its right.
///
/// Reversing an edge flips the sign of `dy` (and of `dx` when horizontal), so
/// exactly one of `isTopLeft(a, b)` / `isTopLeft(b, a)` holds. Two triangles
/// sharing an edge traverse it in opposite directions, which is what makes the
/// partition exact: no double-drawn pixel and no gap.
fn isTopLeft(ax: i32, ay: i32, bx: i32, by: i32) bool {
    const dy = @as(i64, by) - ay;
    const dx = @as(i64, bx) - ax;
    return (dy == 0 and dx > 0) or dy < 0;
}

fn floorDiv(v: i64) i32 {
    // Arithmetic shift keeps the floor semantics for negative coordinates.
    return @intCast(v >> subpixel_bits);
}

// --- texture sampling --------------------------------------------------------

/// Fractional part with floor semantics; works for negative coordinates too.
fn repeatFrac(t: f64) f64 {
    return t - @floor(t);
}

/// Wrap a fractional coordinate into `[0, len)` with repeat addressing.
fn wrapIndex(t: f64, len: u32) u32 {
    return @intFromFloat(@mod(@floor(t), @as(f64, @floatFromInt(len))));
}

fn texelOffset(tex: Texture, ix: u32, iy: u32) usize {
    return (@as(usize, iy) * tex.width + ix) * 4;
}

fn nearestTexel(tex: Texture, u: f64, v: f64) [4]u8 {
    const uf = repeatFrac(u);
    const vf = repeatFrac(v);
    const x: u32 = @min(tex.width - 1, @as(u32, @intFromFloat(@floor(uf * @as(f64, @floatFromInt(tex.width))))));
    const y: u32 = @min(tex.height - 1, @as(u32, @intFromFloat(@floor(vf * @as(f64, @floatFromInt(tex.height))))));
    const off = texelOffset(tex, x, y);
    return tex.pixels[off..][0..4].*;
}

fn nearestLevelTexel(level: MipLevel, u: f64, v: f64) [4]u8 {
    const uf = repeatFrac(u);
    const vf = repeatFrac(v);
    const x: u32 = @min(level.width - 1, @as(u32, @intFromFloat(@floor(uf * @as(f64, @floatFromInt(level.width))))));
    const y: u32 = @min(level.height - 1, @as(u32, @intFromFloat(@floor(vf * @as(f64, @floatFromInt(level.height))))));
    const off = (@as(usize, y) * level.width + x) * 4;
    return level.pixels[off..][0..4].*;
}

fn fetch(tex: Texture, ix: u32, iy: u32, channel: usize) f64 {
    const off = texelOffset(tex, ix, iy);
    return @floatFromInt(tex.pixels[off + channel]);
}

fn fetchLevel(level: MipLevel, ix: u32, iy: u32, channel: usize) f64 {
    const off = (@as(usize, iy) * level.width + ix) * 4;
    return @floatFromInt(level.pixels[off + channel]);
}

/// Bilinear magnification pinned to a single evaluation order: fractions as
/// f64, four taps summed as `(c00 * (1 - fx) + c10 * fx) * (1 - fy) +
/// (c01 * (1 - fx) + c11 * fx) * fy`, one final round to u8. The reference
/// vectors recompute this exact expression.
fn bilinearTexel(tex: Texture, u: f64, v: f64) [4]u8 {
    const uf = repeatFrac(u);
    const vf = repeatFrac(v);
    const tx = uf * @as(f64, @floatFromInt(tex.width)) - 0.5;
    const ty = vf * @as(f64, @floatFromInt(tex.height)) - 0.5;
    const fx = tx - @floor(tx);
    const fy = ty - @floor(ty);
    const x0 = wrapIndex(tx, tex.width);
    const x1 = (x0 + 1) % tex.width;
    const y0 = wrapIndex(ty, tex.height);
    const y1 = (y0 + 1) % tex.height;
    var out: [4]u8 = undefined;
    for (0..4) |channel| {
        const c00 = fetch(tex, x0, y0, channel);
        const c10 = fetch(tex, x1, y0, channel);
        const c01 = fetch(tex, x0, y1, channel);
        const c11 = fetch(tex, x1, y1, channel);
        const top = (c00 * (1.0 - fx) + c10 * fx) * (1.0 - fy);
        const bottom = (c01 * (1.0 - fx) + c11 * fx) * fy;
        out[channel] = @intFromFloat(@floor(top + bottom + 0.5));
    }
    return out;
}

/// `bilinearTexel` for an arbitrary level: same pinned operation order, wrapping
/// and single final round, against that level's own dimensions.
fn bilinearLevelTexel(level: MipLevel, u: f64, v: f64) [4]u8 {
    const uf = repeatFrac(u);
    const vf = repeatFrac(v);
    const tx = uf * @as(f64, @floatFromInt(level.width)) - 0.5;
    const ty = vf * @as(f64, @floatFromInt(level.height)) - 0.5;
    const fx = tx - @floor(tx);
    const fy = ty - @floor(ty);
    const x0 = wrapIndex(tx, level.width);
    const x1 = (x0 + 1) % level.width;
    const y0 = wrapIndex(ty, level.height);
    const y1 = (y0 + 1) % level.height;
    var out: [4]u8 = undefined;
    for (0..4) |channel| {
        const c00 = fetchLevel(level, x0, y0, channel);
        const c10 = fetchLevel(level, x1, y0, channel);
        const c01 = fetchLevel(level, x0, y1, channel);
        const c11 = fetchLevel(level, x1, y1, channel);
        const top = (c00 * (1.0 - fx) + c10 * fx) * (1.0 - fy);
        const bottom = (c01 * (1.0 - fx) + c11 * fx) * fy;
        out[channel] = @intFromFloat(@floor(top + bottom + 0.5));
    }
    return out;
}

fn sampleTexture(tex: Texture, u: f64, v: f64) [4]u8 {
    return switch (tex.filter) {
        .nearest => nearestTexel(tex, u, v),
        .bilinear => bilinearTexel(tex, u, v),
    };
}

fn sampleLevel(tex: Texture, index: u32, u: f64, v: f64) [4]u8 {
    const level = tex.mipLevel(index);
    return switch (tex.filter) {
        .nearest => nearestLevelTexel(level, u, v),
        .bilinear => bilinearLevelTexel(level, u, v),
    };
}

/// Continuous level of detail: `log2` of the larger of the two texel-space UV
/// gradients, clamped to `[0, levels - 1]`. `du`/`dv` are the per-pixel changes
/// of `u`/`v` already scaled by the texture size, so 1 means one texel per pixel
/// (level 0) and 2 means two (level 1). A zero, negative or non-finite gradient
/// selects level 0, which is also exactly the pre-mipmap behaviour.
fn textureLod(du: f64, dv: f64, levels: u32) f64 {
    const max_level: f64 = @floatFromInt(levels - 1);
    const rho = @max(@abs(du), @abs(dv));
    if (!(rho > 1.0) or !std.math.isFinite(rho)) return 0.0;
    const lod = @log2(rho);
    if (!(lod > 0.0)) return 0.0;
    return @min(lod, max_level);
}

/// `textureLod` with a bias added and the result clamped back into the chain.
///
/// The clamp is the whole reason this is a separate function: `textureLod` clamps
/// the *unbiased* value, so adding a bias afterwards could push a sample past the
/// last level. Biasing before the clamp would change the unbiased result for a
/// bias of zero on a magnification case (`rho <= 1` maps to 0 either way, so it
/// would not, but the argument stops holding the moment the clamp moves) — this
/// form keeps `bias == 0` bit-identical by construction and clamps once at the
/// end.
fn textureLodBiased(du: f64, dv: f64, levels: u32, bias: f64) f64 {
    if (bias == 0.0) return textureLod(du, dv, levels);
    const base = textureLod(du, dv, levels);
    const max_level: f64 = @floatFromInt(levels - 1);
    const biased = base + bias;
    if (!(biased > 0.0)) return 0.0;
    return @min(biased, max_level);
}

/// Trilinear sample: floor/ceil of `lod`, each level filtered with `filter`, then
/// the two results mixed channel-wise in `f64` and rounded **once**. A `lod` on a
/// level boundary does a single fetch, and level 0 with `lod == 0` reproduces the
/// plain `sampleTexture` result byte for byte.
fn sampleTrilinear(tex: Texture, u: f64, v: f64, lod: f64) [4]u8 {
    const base: u32 = @intFromFloat(@floor(lod));
    const levels = tex.mipLevelCount();
    if (base >= levels - 1) return sampleLevel(tex, levels - 1, u, v);
    const t = lod - @as(f64, @floatFromInt(base));
    if (!(t > 0.0)) return sampleLevel(tex, base, u, v);
    const coarse = sampleLevel(tex, base + 1, u, v);
    const fine = sampleLevel(tex, base, u, v);
    var out: [4]u8 = undefined;
    for (0..4) |channel| {
        const a = @as(f64, @floatFromInt(fine[channel]));
        const b = @as(f64, @floatFromInt(coarse[channel]));
        out[channel] = @intFromFloat(@floor(a * (1.0 - t) + b * t + 0.5));
    }
    return out;
}

/// Per-pixel screen-space UV derivatives, in *texel* units: the change of
/// `u * width` / `v * height` across one pixel step in x and in y, following the
/// perspective-correct mapping. Written as `(p * den - q * dden) / den^2`, the
/// exact derivative of `u = p / den` — no approximation, no extra sample.
///
/// `p`/`q` are the perspective numerator (`Σ w·uw / area`) and `den` the
/// denominator at this pixel; `dp`/`dq`/`dden` are their per-x and per-y
/// differences. A degenerate `den` cannot yield a derivative, so the caller's
/// level stays 0.
fn texelGradient(p: f64, q: f64, den: f64, dp: [2]f64, dq: [2]f64, dden: [2]f64, size: [2]f64) struct { du: f64, dv: f64 } {
    const den_sq = den * den;
    if (!(den_sq > 0.0) or !std.math.isFinite(den_sq)) return .{ .du = 0.0, .dv = 0.0 };
    // One reciprocal instead of four divides: all four derivatives share
    // `den * den`. The multiply form is pinned (and mirrored by the reference
    // generator) — the value only feeds a log2 and a level clamp, so the
    // rounding difference against a true divide is far below one level step.
    const inv_den_sq = 1.0 / den_sq;
    const dudx = (dp[0] * den - p * dden[0]) * inv_den_sq;
    const dvdx = (dq[0] * den - q * dden[0]) * inv_den_sq;
    const dudy = (dp[1] * den - p * dden[1]) * inv_den_sq;
    const dvdy = (dq[1] * den - q * dden[1]) * inv_den_sq;
    return .{
        .du = @max(@abs(dudx), @abs(dudy)) * size[0],
        .dv = @max(@abs(dvdx), @abs(dvdy)) * size[1],
    };
}

/// Both screen-axis derivatives of the texel-space UV gradient, for
/// anisotropic filtering. `texelGradient` collapses each axis with `max`; this
/// keeps them apart so the footprint's elongation and orientation are known.
/// Same pinned expressions, same single reciprocal.
const TexelDerivatives = struct {
    /// Per-axis derivatives, `[0]` across x and `[1]` across y, in texels.
    du: [2]f64,
    dv: [2]f64,
};

fn texelDerivatives(p: f64, q: f64, den: f64, dp: [2]f64, dq: [2]f64, dden: [2]f64, size: [2]f64) TexelDerivatives {
    const den_sq = den * den;
    if (!(den_sq > 0.0) or !std.math.isFinite(den_sq)) return .{ .du = .{ 0, 0 }, .dv = .{ 0, 0 } };
    const inv_den_sq = 1.0 / den_sq;
    const dudx = (dp[0] * den - p * dden[0]) * inv_den_sq;
    const dvdx = (dq[0] * den - q * dden[0]) * inv_den_sq;
    const dudy = (dp[1] * den - p * dden[1]) * inv_den_sq;
    const dvdy = (dq[1] * den - q * dden[1]) * inv_den_sq;
    return .{
        .du = .{ dudx * size[0], dudy * size[0] },
        .dv = .{ dvdx * size[1], dvdy * size[1] },
    };
}

/// How one pixel's texel footprint is sampled anisotropically. Everything here
/// is derived from the footprint alone, so it is reproducible by the reference
/// generator and pinned bit for bit.
pub const AnisoFootprint = struct {
    /// Number of taps along the footprint's long axis, `1..max_aniso_samples`.
    /// One means the footprint is round enough that the trilinear path is used.
    samples: u8,
    /// Long-axis direction of the footprint (unit length).
    axis: [2]f64,
    /// Level the trilinear path would choose — `log2` of the long axis.
    lod_major: f64,
    /// `lod_major - log2(anisotropy)`: the level that matches the *short* axis of
    /// the footprint. Never below `lod_major`; sampled at by the taps.
    lod_minor: f64,
};

/// Upper bound on taps per pixel for `Mipmap.anisotropic`. Eight is the value
/// real hardware uses; the cost is linear in it and the quality gain above it is
/// inaudible at the pixel level.
pub const max_aniso_samples: u8 = 8;

/// Largest anisotropy ratio the filter corrects for: a footprint more elongated
/// than 8:1 is averaged as if it were 8:1 rather than spending taps a surface at
/// that angle cannot support anyway.
pub const max_aniso_ratio: f64 = 8.0;

/// Decide how to sample a footprint from its per-axis texel derivatives.
///
/// The long axis is the footprint's longer direction (its length is `rho`, the
/// same quantity `textureLod` takes the `log2` of); the short axis is the length
/// of the other principal direction. `anisotropy = rho / sigma`, clamped to
/// `[1, max_aniso_ratio]`, decides how many taps are worth taking, and the taps
/// sample the level that matches `sigma` instead of `rho`, which is what removes
/// the over-blur along the short axis.
///
/// A round footprint (`sigma >= rho`, which includes every degenerate or
/// zero-gradient case) yields `samples = 1` and is sampled trilinearly.
pub fn anisoFootprint(d: TexelDerivatives, levels: u32) AnisoFootprint {
    return anisoFootprintCapped(d, levels, max_aniso_samples);
}

/// `anisoFootprint` with this draw's tap cap (`Sampling.tapCap`). The cap is
/// applied after the ceiling, because a material that is drawn a thousand times
/// is exactly the one that wants fewer taps, and because a cap can only ever
/// lower the count.
pub fn anisoFootprintCapped(d: TexelDerivatives, levels: u32, tap_cap: u8) AnisoFootprint {
    // The two screen-axis columns of the Jacobian. The longer one is the footprint's
    // long axis: its length is the extent of the footprint, and its direction is
    // the direction in UV space along which the texture compresses most — the axis
    // the taps must follow. The ratio of the two lengths is the anisotropy.
    const len_x = @sqrt(d.du[0] * d.du[0] + d.dv[0] * d.dv[0]);
    const len_y = @sqrt(d.du[1] * d.du[1] + d.dv[1] * d.dv[1]);
    const major = @max(len_x, len_y);
    const minor = @min(len_x, len_y);
    const rho = major;
    const lod_major = textureLod(rho, 0.0, levels);
    // Round footprint, a degenerate derivative, or nothing to correct: the exact
    // trilinear result. `!(...)` so a NaN takes this branch too.
    if (!(major > minor) or !(minor > 0.0) or !std.math.isFinite(rho)) {
        return .{ .samples = 1, .axis = .{ 0, 0 }, .lod_major = lod_major, .lod_minor = lod_major };
    }
    const anisotropy = @min(rho / minor, max_aniso_ratio);
    const lod_minor = @max(lod_major - std.math.log2(anisotropy), 0.0);
    // Fractional taps interpolate linearly in quality, which is why the sample
    // count is rounded up from a continuous want. `@ceil` before `@intFromFloat`
    // keeps the mapping monotone and free of a floating-point cast trap.
    const ceiling: f64 = @floatFromInt(@min(tap_cap, max_aniso_samples));
    const wanted = @ceil(@min(anisotropy, ceiling));
    const samples: u8 = if (wanted < 1.0) 1 else @intFromFloat(wanted);
    // Unit direction of the longer column.
    const axis = if (len_x >= len_y)
        [2]f64{ d.du[0] / major, d.dv[0] / major }
    else
        [2]f64{ d.du[1] / major, d.dv[1] / major };
    return .{ .samples = samples, .axis = axis, .lod_major = lod_major, .lod_minor = lod_minor };
}

/// Sample an elongated footprint with `footprint.samples` taps spread along its
/// long axis, in the pixel's own `(u, v)` space.
///
/// The tap spacing is chosen so the taps' centres span exactly one pixel:
/// offset `i` is `(i + 0.5) / samples - 0.5` pixels along the axis, and the axis
/// is expressed in texel units so the offset is divided by the level-0 extent.
/// Each tap is a trilinear sample at `lod_minor`, and the results are averaged
/// channel-wise in `f64` with **one** final round — the same one-round rule the
/// trilinear mix follows, so a single tap reproduces `sampleTrilinear(lod_major)`
/// only when the two levels coincide, which is the documented boundary.
fn sampleAnisotropic(tex: Texture, u: f64, v: f64, footprint: AnisoFootprint, size: [2]f64) [4]u8 {
    const n = footprint.samples;
    if (n <= 1) return sampleTrilinear(tex, u, v, footprint.lod_major);
    const step_u = footprint.axis[0] / (size[0] * @as(f64, @floatFromInt(n)));
    const step_v = footprint.axis[1] / (size[1] * @as(f64, @floatFromInt(n)));
    var acc: [4]f64 = .{ 0, 0, 0, 0 };
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        // Tap centres at -0.5 + (i + 0.5) / n pixels, so the outer taps sit half
        // a tap inside the pixel footprint instead of on its edge.
        const offset = @as(f64, @floatFromInt(i)) - (@as(f64, @floatFromInt(n)) - 1.0) / 2.0;
        const tap = sampleTrilinear(tex, u + step_u * offset, v + step_v * offset, footprint.lod_minor);
        for (0..4) |c| acc[c] += @as(f64, @floatFromInt(tap[c]));
    }
    var out: [4]u8 = undefined;
    const inv = 1.0 / @as(f64, @floatFromInt(n));
    for (0..4) |c| out[c] = @intFromFloat(@floor(acc[c] * inv + 0.5));
    return out;
}

/// Per-channel byte quantization with the pinned final round:
/// `floor(min(max(s, 0), 255) + 0.5)`. Handles multipliers > 1 (HDR lights).
fn clampByte(s: f64) u8 {
    return @intFromFloat(@floor(@min(@max(s, 0.0), 255.0) + 0.5));
}

/// Normalize a world-space direction (from a `Light`) into f64. Direction
/// validity is established by `Light.validate`; a zero or non-finite result
/// can still only arise from degenerate data, so it maps to no light.
fn normalizeDirection(d: [3]f32) [3]f64 {
    const x = @as(f64, @floatCast(d[0]));
    const y = @as(f64, @floatCast(d[1]));
    const z = @as(f64, @floatCast(d[2]));
    const len = std.math.sqrt((x * x + y * y) + z * z);
    if (!(len > 0.0) or !std.math.isFinite(len)) return .{ 0.0, 0.0, 0.0 };
    return .{ x / len, y / len, z / len };
}

/// Per-channel Lambert multiplier `ambient + max(0, n·l) * color` for one
/// triangle. The raw world-space face normal arrives un-normalized (typically
/// the cross product of two world-space edges); it is normalized here with a
/// pinned f64 operation order. A zero or non-finite normal lights the
/// triangle with `ambient` only. The result is unclamped — HDR multipliers
/// are legal and will be clamped at the final quantization.
fn lightMultiplier(light: Light, raw_normal: [3]f64) [3]f64 {
    const l = normalizeDirection(light.direction);
    const nrm = std.math.sqrt((raw_normal[0] * raw_normal[0] + raw_normal[1] * raw_normal[1]) + raw_normal[2] * raw_normal[2]);
    var dot: f64 = 0.0;
    if (nrm > 0.0 and std.math.isFinite(nrm)) {
        const n0 = raw_normal[0] / nrm;
        const n1 = raw_normal[1] / nrm;
        const n2 = raw_normal[2] / nrm;
        dot = @max(0.0, (n0 * l[0] + n1 * l[1]) + n2 * l[2]);
    }
    var lit: [3]f64 = undefined;
    for (0..3) |c| {
        lit[c] = @as(f64, @floatCast(light.ambient[c])) + dot * @as(f64, @floatCast(light.color[c]));
    }
    return lit;
}

/// Multiply the sampled texel by the material tint, one rounding per channel.
fn tintMultiply(texel: [4]u8, tint: [4]u8) [4]u8 {
    var out: [4]u8 = undefined;
    for (0..4) |channel| {
        out[channel] = @intFromFloat(@floor(
            @as(f64, @floatFromInt(texel[channel])) *
                @as(f64, @floatFromInt(tint[channel])) / 255.0 + 0.5,
        ));
    }
    return out;
}

/// Compose one quantized source fragment over the target's current pixel.
///
/// Both sides are normalized to `[0, 1]` once, blending happens in `f64` with
/// the pinned order documented on `Blend`, and each channel is quantized a
/// single time with `floor(clamp(v, 0, 1) * 255 + 0.5)`. `none` returns the
/// source untouched, which makes the blended path byte-identical to the
/// pre-blending framebuffer write for every caller that does not opt in.
fn blendPixels(src: [4]u8, dst: [4]u8, mode: Blend) [4]u8 {
    if (mode == .none) return src;

    const sa = @as(f64, @floatFromInt(src[3])) / 255.0;
    const da = @as(f64, @floatFromInt(dst[3])) / 255.0;
    const keep = 1.0 - sa;
    const out_a = sa + da * keep;

    var out: [4]u8 = undefined;
    switch (mode) {
        .none => unreachable,
        .alpha => {
            // A fully transparent result has no color to carry; keep it black
            // instead of dividing by zero.
            if (!(out_a > 0.0)) return .{ 0, 0, 0, 0 };
            for (0..3) |channel| {
                const s = @as(f64, @floatFromInt(src[channel])) / 255.0;
                const d = @as(f64, @floatFromInt(dst[channel])) / 255.0;
                out[channel] = unitByte(((s * sa) + ((d * da) * keep)) / out_a);
            }
        },
        .premultiplied => for (0..3) |channel| {
            const s = @as(f64, @floatFromInt(src[channel])) / 255.0;
            const d = @as(f64, @floatFromInt(dst[channel])) / 255.0;
            out[channel] = unitByte((s * sa) + (d * keep));
        },
        .additive => for (0..3) |channel| {
            const s = @as(f64, @floatFromInt(src[channel])) / 255.0;
            const d = @as(f64, @floatFromInt(dst[channel])) / 255.0;
            out[channel] = unitByte(d + (s * sa));
        },
    }
    out[3] = unitByte(out_a);
    return out;
}

/// Composite a shaded fragment with the destination using fractional coverage
/// (`coverage` in `1..=aa_samples`, `cov = coverage / aa_samples`).
///
/// Coverage is folded into the *source alpha*, then the ordinary straight-alpha
/// source-over equation runs with that attenuated source:
///
/// ```
/// sa = (src.a / 255) * cov          da = dst.a / 255          keep = 1 - sa
/// out.a   = sa + da * keep
/// out.rgb = (src.rgb*sa + dst.rgb*da*keep) / out.a    (transparent black if 0)
/// ```
///
/// in `f64`, quantized once per channel — the same arithmetic as `Blend.alpha` with
/// a scaled alpha, which is why partial coverage of a translucent fragment and full
/// coverage of a half-alpha one agree. A fully covered pixel never reaches here (it
/// takes the plain blend path), so coverage 16 is only used defensively.
fn compositeCoverage(src: [4]u8, dst: [4]u8, coverage: u16) [4]u8 {
    const cov = @as(f64, @floatFromInt(coverage)) / @as(f64, @floatFromInt(aa_samples));
    const sa = (@as(f64, @floatFromInt(src[3])) / 255.0) * cov;
    const da = @as(f64, @floatFromInt(dst[3])) / 255.0;
    const keep = 1.0 - sa;
    const out_a = sa + da * keep;
    if (!(out_a > 0.0)) return .{ 0, 0, 0, 0 };
    var out: [4]u8 = undefined;
    for (0..3) |channel| {
        const s = @as(f64, @floatFromInt(src[channel])) / 255.0;
        const d = @as(f64, @floatFromInt(dst[channel])) / 255.0;
        out[channel] = unitByte((s * sa + d * da * keep) / out_a);
    }
    out[3] = unitByte(out_a);
    return out;
}

/// Quantize a `[0, 1]` blend channel: `floor(clamp(v, 0, 1) * 255 + 0.5)`.
/// Distinct from `clampByte`, which works in byte units (`0..255`).
fn unitByte(v: f64) u8 {
    return @intFromFloat(@floor(@min(@max(v, 0.0), 1.0) * 255.0 + 0.5));
}

// --- antialiasing ------------------------------------------------------------

/// Sub-sample center `k` of a pixel along one axis, in 1/16-pixel units measured
/// from the pixel's top-left corner: `(k + 0.5) / grid * 16`. With the default 4x4
/// grid that is 2, 6, 10, 14 — the centers of the four quarter pixels.
inline fn aaSampleOffset(comptime grid: u5, k: u5) i32 {
    return @intCast((@as(u32, 2 * @as(u32, k) + 1) * subpixel_scale) / (@as(u32, grid) * 2));
}

/// Distance from a pixel center, in sub-pixel units, to the farthest sub-sample
/// along one axis: 6 units on the default 4x4 grid, whose offsets are 2, 6, 10
/// and 14 around the center at 8.
const aa_sample_reach: i64 = subpixel_scale / 2 - aaSampleOffset(aa_grid, 0);

/// `|v|` for an `i64` that cannot be `minInt` here (edge steps are coordinate
/// differences bounded by the target size), avoiding the `u64` of `@abs`.
inline fn absI(v: i64) i64 {
    return if (v < 0) -v else v;
}

/// Edge-function delta per **1/16 pixel** of screen step, per axis, for the three
/// edges of a triangle wound to positive area. These are the raw coordinate
/// differences, so they are exact integers and one order of magnitude smaller than
/// the per-pixel steps (`per_pixel = per_unit * subpixel_scale`).
const EdgeSteps = struct {
    /// Delta of edges 0..2 for a step of one sub-pixel unit along +x.
    dx: [3]i64,
    /// Delta of edges 0..2 for a step of one sub-pixel unit along +y.
    dy: [3]i64,

    fn fromScreen(a: ScreenVertex, b: ScreenVertex, c: ScreenVertex) EdgeSteps {
        return .{
            .dx = .{ @as(i64, b.y) - c.y, @as(i64, c.y) - a.y, @as(i64, a.y) - b.y },
            .dy = .{ @as(i64, c.x) - b.x, @as(i64, a.x) - c.x, @as(i64, b.x) - a.x },
        };
    }
};

/// How many of `grid * grid` sub-samples of a pixel lie inside the triangle.
/// `w` holds the pixel-center edge functions *without* the top-left bias and
/// `steps` their per-sub-pixel-unit derivatives. Everything is `i64` with the same
/// exactness the pixel-center test has, so coverage is reproducible bit for bit and
/// needs no floating point and no lookup table.
///
/// A sub-sample counts when it is inside all three edges, with the *same* top-left
/// rule the pixel-center test uses: an edge that is top-left at its own bias
/// (`bias == 0`) also claims samples lying exactly on it, and every other edge only
/// claims strictly-positive ones. This is what makes sub-samples on a shared edge
/// belong to exactly one of the two triangles, so their coverage still sums to a
/// full pixel and the shared edge has no seam.
fn coverageCount(comptime grid: u5, w: [3]i64, steps: EdgeSteps, bias: [3]i64) u16 {
    var inside: u16 = 0;
    inline for (0..grid) |j| {
        const dy: i64 = aaSampleOffset(grid, j) - subpixel_scale / 2;
        const row = [3]i64{
            w[0] + steps.dy[0] * dy,
            w[1] + steps.dy[1] * dy,
            w[2] + steps.dy[2] * dy,
        };
        inline for (0..grid) |i| {
            const dx: i64 = aaSampleOffset(grid, i) - subpixel_scale / 2;
            const e0 = row[0] + steps.dx[0] * dx;
            const e1 = row[1] + steps.dx[1] * dx;
            const e2 = row[2] + steps.dx[2] * dx;
            if (onEdge(e0, bias[0]) and onEdge(e1, bias[1]) and onEdge(e2, bias[2])) inside += 1;
        }
    }
    return inside;
}

/// Inside test for one edge at a sub-sample, honouring the top-left rule: a sample
/// exactly on a top-left edge (`bias == 0`) counts, one exactly on any other edge
/// does not.
inline fn onEdge(e: i64, bias: i64) bool {
    return e > 0 or (e == 0 and bias == 0);
}

/// One pixel accumulated during an antialiased draw: `count` of the 16 sub-samples
/// are covered, and `rgba`/`depth` are the values of the last sub-sample that was.
const AccSlot = struct {
    count: u16 = 0,
    rgba: [4]u8 = .{ 0, 0, 0, 0 },
    depth: f32 = 0,
};

/// Caller-owned scratch for one antialiased `drawMesh`. `coverage` and `depth`
/// hold one entry per target pixel the draw touched and `ids` lists their linear
/// indices — so the resolve pass visits touched pixels only, never the whole
/// target, and nothing is cleared. The buffers are sized once for the draw's
/// bounding rectangle and reused by every triangle of that draw.
const AccumBuffers = struct {
    coverage: []AccSlot,
    /// Linear indices of the touched slots, relative to `origin`.
    ids: []u32,
    count: usize = 0,
    /// Top-left pixel of the box the buffers describe.
    origin_x: i32,
    origin_y: i32,
    /// Box width in pixels, for the absolute->relative mapping.
    width: usize,

    /// Slot index for an absolute (target) pixel index, or null when the pixel
    /// lies outside the box. `null` never happens for pixels this triangle is
    /// allowed to touch (the box covers the mesh's conservative reach); it is the
    /// safety net that keeps an unexpected pixel from indexing out of bounds.
    fn slot(self: AccumBuffers, index: usize, target_width: usize) ?usize {
        const y = index / target_width;
        const x = index % target_width;
        const rel_x = @as(i64, @intCast(x)) - self.origin_x;
        const rel_y = @as(i64, @intCast(y)) - self.origin_y;
        if (rel_x < 0 or rel_y < 0) return null;
        const rx: usize = @intCast(rel_x);
        const ry: usize = @intCast(rel_y);
        if (rx >= self.width) return null;
        const offset = ry * self.width + rx;
        if (offset >= self.coverage.len) return null;
        return offset;
    }
};

/// Largest antialias scratch permitted for one draw. A hostile mesh can force
/// `reachRect` to fall back to the whole target; at 16k x 16k that would be
/// multiple GiB of slots, so draws beyond this are downgraded to the one-sample
/// path instead of allocating it.
pub const max_aa_scratch_bytes: usize = 256 * 1024 * 1024;

/// Owns the antialiasing scratch for one draw. The box is computed from the mesh's
/// conservative screen-space reach (see `reachRect`), which always contains every
/// touched pixel; a projection that the reach cannot bound falls back to the whole
/// target, so the buffer is never too small and the code never indexes out of
/// bounds.
const AccumStorage = struct {
    slot_storage: []AccSlot,
    id_storage: []u32,
    origin_x: i32,
    origin_y: i32,
    width: usize,
    buffers: AccumBuffers,

    fn init(gpa: Allocator, target: *Target, mesh: Mesh, mvp: Mat4) DrawError!AccumStorage {
        const rect = reachRect(target, mesh, mvp);
        const box = aaBoxSize(rect);
        const w = box.w;
        const h = box.h;
        // `ids` can never need more entries than there are pixels in the box.
        const slots = gpa.alloc(AccSlot, w * h) catch return error.OutOfMemory;
        errdefer gpa.free(slots);
        const ids = gpa.alloc(u32, w * h) catch return error.OutOfMemory;
        @memset(slots, AccSlot{});
        return .{
            .slot_storage = slots,
            .id_storage = ids,
            .origin_x = rect.min_x,
            .origin_y = rect.min_y,
            .width = w,
            .buffers = .{
                .coverage = slots,
                .ids = ids,
                .origin_x = rect.min_x,
                .origin_y = rect.min_y,
                .width = w,
            },
        };
    }

    fn deinit(self: *AccumStorage, gpa: Allocator) void {
        gpa.free(self.slot_storage);
        gpa.free(self.id_storage);
        self.* = undefined;
    }
};

/// Screen-space rectangle (inclusive pixel bounds) that conservatively contains
/// every pixel the mesh can touch *for axis-aligned viewing rays of a standard
/// perspective/orthographic projection*: the projected corners of the mesh AABB are
/// extruded by the AABB's world-space diagonal, which is exactly the screen
/// displacement a unit change of view depth can cause under any such projection.
/// An empty mesh, a non-finite projection or a target whose pixels the reach cannot
/// bound falls back to the full target — correct, just less memory-efficient.
fn reachRect(target: *Target, mesh: Mesh, mvp: Mat4) Rect {
    const full = Rect{
        .min_x = 0,
        .min_y = 0,
        .max_x = @as(i32, @intCast(target.width)) - 1,
        .max_y = @as(i32, @intCast(target.height)) - 1,
    };
    if (mesh.positions.len == 0) return full;

    var min_world = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var max_world = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (mesh.positions) |p| {
        for (0..3) |axis| {
            min_world[axis] = @min(min_world[axis], p[axis]);
            max_world[axis] = @max(max_world[axis], p[axis]);
        }
    }
    var extent: f32 = 0;
    for (0..3) |axis| {
        const d = max_world[axis] - min_world[axis];
        if (!std.math.isFinite(d)) return full;
        extent = @max(extent, d);
    }
    if (!std.math.isFinite(extent)) return full;
    if (extent == 0) extent = 0; // a point cloud projects to a point

    var min_ndc = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var max_ndc = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for (0..8) |corner| {
        const p = [3]f32{
            if (corner & 1 == 0) min_world[0] else max_world[0],
            if (corner & 2 == 0) min_world[1] else max_world[1],
            if (corner & 4 == 0) min_world[2] else max_world[2],
        };
        var clip: [4]f32 = undefined;
        inline for (0..4) |r| {
            clip[r] = mvp[0 * 4 + r] * p[0] + mvp[1 * 4 + r] * p[1] + mvp[2 * 4 + r] * p[2] + mvp[3 * 4 + r];
        }
        // Behind or on the eye plane: the projection is unbounded, use everything.
        if (!(clip[3] > 1e-20) or !std.math.isFinite(clip[3])) return full;
        const inv = 1.0 / clip[3];
        const nx = clip[0] * inv;
        const ny = clip[1] * inv;
        if (!std.math.isFinite(nx) or !std.math.isFinite(ny)) return full;
        min_ndc[0] = @min(min_ndc[0], nx);
        max_ndc[0] = @max(max_ndc[0], nx);
        min_ndc[1] = @min(min_ndc[1], ny);
        max_ndc[1] = @max(max_ndc[1], ny);
    }

    // NDC -> pixel, matching `toScreen` (Y flip), plus one pixel for the AABB
    // diagonal and one for the antialiasing halo.
    const w: f32 = @floatFromInt(target.width);
    const h: f32 = @floatFromInt(target.height);
    const ndc_to_x = (1.0 / 2.0) * w;
    const ndc_to_y = -(1.0 / 2.0) * h;
    const pad: f32 = extent + 2.5;
    // Y is flipped (NDC up, framebuffer down), so the two mapped Y values are in
    // the opposite order; take their min/max rather than assuming.
    const x_a = min_ndc[0] * ndc_to_x + 0.5 * w;
    const x_b = max_ndc[0] * ndc_to_x + 0.5 * w;
    const y_a = min_ndc[1] * ndc_to_y + 0.5 * h;
    const y_b = max_ndc[1] * ndc_to_y + 0.5 * h;
    const lo_x = @min(x_a, x_b) - pad;
    const hi_x = @max(x_a, x_b) + pad;
    const lo_y = @min(y_a, y_b) - pad;
    const hi_y = @max(y_a, y_b) + pad;
    if (!std.math.isFinite(lo_x) or !std.math.isFinite(hi_x) or !std.math.isFinite(lo_y) or !std.math.isFinite(hi_y)) return full;
    // Clamp into the target: pixels outside it are never touched, and the box has
    // to stay inside so a triangle cannot index past the buffers.
    const last_x: f32 = @floatFromInt(@as(i32, @intCast(target.width)) - 1);
    const last_y: f32 = @floatFromInt(@as(i32, @intCast(target.height)) - 1);
    return .{
        .min_x = @intFromFloat(std.math.clamp(lo_x, 0, last_x)),
        .min_y = @intFromFloat(std.math.clamp(lo_y, 0, last_y)),
        .max_x = @intFromFloat(std.math.clamp(hi_x, 0, last_x)),
        .max_y = @intFromFloat(std.math.clamp(hi_y, 0, last_y)),
    };
}

/// Box dimensions of the AA scratch for a reach rectangle.
fn aaBoxSize(rect: Rect) struct { w: usize, h: usize } {
    const box_w: i64 = @as(i64, rect.max_x) - rect.min_x + 1;
    const box_h: i64 = @as(i64, rect.max_y) - rect.min_y + 1;
    return .{
        .w = @intCast(@max(box_w, 1)),
        .h = @intCast(@max(box_h, 1)),
    };
}

/// Exact scratch footprint of an antialiased draw over `reachRect`. Computed
/// with saturating arithmetic; a full 16384x16384 reach reports a huge value
/// and the caller downgrades instead of allocating.
fn aaScratchBytes(target: *Target, mesh: Mesh, mvp: Mat4) usize {
    const box = aaBoxSize(reachRect(target, mesh, mvp));
    const pixels = std.math.mul(usize, box.w, box.h) catch return std.math.maxInt(usize);
    return std.math.mul(usize, pixels, @sizeOf(AccSlot) + @sizeOf(u32)) catch return std.math.maxInt(usize);
}

const Rect = struct { min_x: i32, min_y: i32, max_x: i32, max_y: i32 };

/// Resolve accumulated sub-sample coverage into the target, once per touched
/// pixel. The coverage fraction `a = count / 16` is folded into the source alpha
/// and the ordinary straight-alpha source-over runs (`compositeCoverage`):
///
/// ```
/// sa     = (shaded.a / 255) * a          da = dst.a / 255     keep = 1 - sa
/// out.a  = sa + da * keep
/// out.rgb = (shaded.rgb*sa + dst.rgb*da*keep) / out.a
/// ```
///
/// all in `f64`, quantized once per channel — the same single-rounding rule the
/// shading and blending paths use. This is why an antialiased edge composites
/// correctly even over a translucent destination: coverage attenuates the source,
/// it does not blend towards the destination linearly. Because the accumulation is
/// per draw command and not per fragment, a pixel on a shared interior edge
/// receives the sub-samples of *both* triangles: total coverage stays exactly 16
/// and the edge stays seam-free.
///
/// A fully covered pixel skips coverage entirely and takes the plain path: the
/// verbatim write for `.blend = .none`, `blendPixels` otherwise. Both are
/// byte-identical to the one-sample path.
///
/// Partially covered pixels deliberately do **not** write depth: they are
/// translucent, and occluding with them would erase the geometry behind.
fn resolveAccumulated(target: *Target, accum: *AccumBuffers, options: Options, stats: *Stats) void {
    for (accum.ids[0..accum.count]) |id| {
        const offset: usize = id;
        const slot = &accum.coverage[offset];
        const rel_x = offset % accum.width;
        const rel_y = offset / accum.width;
        const x: i64 = @as(i64, accum.origin_x) + @as(i64, @intCast(rel_x));
        const y: i64 = @as(i64, accum.origin_y) + @as(i64, @intCast(rel_y));
        if (x < 0 or y < 0) continue;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= target.width or py >= target.height) continue;
        const index = py * @as(usize, target.width) + px;
        const o = index * 4;
        const dst: [4]u8 = .{ target.color[o + 0], target.color[o + 1], target.color[o + 2], target.color[o + 3] };
        const full = slot.count >= aa_samples;
        if (full and options.blend == .none) {
            // Fully covered and nothing to blend: write the shaded fragment
            // verbatim, byte-identical to the one-sample path.
            target.color[o + 0] = slot.rgba[0];
            target.color[o + 1] = slot.rgba[1];
            target.color[o + 2] = slot.rgba[2];
            target.color[o + 3] = slot.rgba[3];
        } else {
            // Fully covered goes through the plain blend mode, so an antialiased
            // draw composites exactly like an un-antialiased one; partial coverage
            // attenuates the source's alpha instead (straight-alpha source-over).
            const out = if (full)
                blendPixels(slot.rgba, dst, options.blend)
            else
                compositeCoverage(slot.rgba, dst, slot.count);
            target.color[o + 0] = out[0];
            target.color[o + 1] = out[1];
            target.color[o + 2] = out[2];
            target.color[o + 3] = out[3];
        }
        stats.pixels += 1;
        if (full) {
            if (options.depth_write) target.depth[index] = slot.depth;
        } else {
            stats.antialiased_pixels += 1;
        }
        slot.count = 0; // leave the slot clean for the next draw that reuses it
    }
    accum.count = 0;
}

/// Per-pixel change of the perspective numerator (`dp`, `dq`) and denominator
/// (`dden`), for the x and y screen axes. Both are affine in screen space, so
/// these six numbers are constant over the triangle and computed once — the LOD
/// therefore costs six multiplies per triangle plus one derivative per pixel.
const GradSteps = struct {
    dp: [2]f64,
    dq: [2]f64,
    dden: [2]f64,
    /// Set when the perspective denominator is constant over the triangle (every
    /// vertex carries the same `w_inv`) — an orthographic projection, or any
    /// affine UV map. The texel gradient, and therefore the level, is then the
    /// same for every pixel, so `log2` is paid once per triangle instead of once
    /// per pixel. The value is bit-identical either way: the per-pixel derivative
    /// with `dden == 0` reduces to exactly this expression.
    constant_lod: ?f64 = null,
    /// Set when the denominator is constant *and* the draw is anisotropic: the
    /// footprint's tap count, axis and level are then the same for every pixel, so
    /// only the tap *positions* vary. Computing them per pixel would repeat eight
    /// square roots and two `log2`s for an answer that cannot change.
    constant_aniso: ?AnisoFootprint = null,

    /// From the per-pixel barycentric steps (`da`, `db`) and the attribute
    /// differences to the reference vertex 2:
    /// `d(num)/d(axis) = da * (att0 - att2) + db * (att1 - att2)`.
    fn init(v0: ScreenVertex, v1: ScreenVertex, v2: ScreenVertex, da: [2]f64, db: [2]f64) GradSteps {
        const nu = v0.uw - v2.uw;
        const nv = v0.vw - v2.vw;
        const nw = v0.w_inv - v2.w_inv;
        const mu = v1.uw - v2.uw;
        const mv = v1.vw - v2.vw;
        const mw = v1.w_inv - v2.w_inv;
        return .{
            .dp = .{ da[0] * nu + db[0] * mu, da[1] * nu + db[1] * mu },
            .dq = .{ da[0] * nv + db[0] * mv, da[1] * nv + db[1] * mv },
            .dden = .{ da[0] * nw + db[0] * mw, da[1] * nw + db[1] * mw },
        };
    }

    /// The single level this triangle samples at, when `den` cannot vary. `size`
    /// is the level-0 extent in texels and `levels` the chain length.
    fn constantLod(self: GradSteps, den: f64, size: [2]f64, levels: u32, bias: f64) ?f64 {
        if (self.dden[0] != 0.0 or self.dden[1] != 0.0) return null;
        const grad_px = texelGradient(0.0, 0.0, den, self.dp, self.dq, self.dden, size);
        return textureLodBiased(grad_px.du, grad_px.dv, levels, bias);
    }

    /// The footprint this pixel samples, with this draw's `Sampling` applied: the
    /// tap cap enters the count and the LOD bias is added to both computed levels
    /// and re-clamped into the chain.
    ///
    /// `p`/`q` are the perspective numerators at this pixel. They only enter
    /// through the denominator, which is why a constant denominator makes the whole
    /// footprint constant and lets the caller cache it.
    fn aniso(self: GradSteps, p: f64, q: f64, den: f64, size: [2]f64, levels: u32, sampling: Sampling) AnisoFootprint {
        var footprint = anisoFootprintCapped(
            texelDerivatives(p, q, den, self.dp, self.dq, self.dden, size),
            levels,
            sampling.tapCap(),
        );
        if (sampling.lod_bias != 0.0) {
            const max_level: f64 = @floatFromInt(levels - 1);
            footprint.lod_major = @max(@min(footprint.lod_major + sampling.lod_bias, max_level), 0.0);
            footprint.lod_minor = @max(@min(footprint.lod_minor + sampling.lod_bias, max_level), 0.0);
        }
        return footprint;
    }

    /// The footprint every pixel of this triangle shares, when `den` cannot vary —
    /// computed once at setup instead of per pixel. Returns null when the
    /// denominator varies, so the caller falls back to `aniso`.
    fn constantAniso(self: GradSteps, den: f64, size: [2]f64, levels: u32, sampling: Sampling) ?AnisoFootprint {
        if (self.dden[0] != 0.0 or self.dden[1] != 0.0) return null;
        return self.aniso(0.0, 0.0, den, size, levels, sampling);
    }
};

/// Shade one covered pixel: flat `rgba`, or `rgba` multiplied by the filtered
/// texel with perspective-correct UVs (`w0`..`w2` are the already-biased
/// coverage weights as f64, `inv_area` normalizes them). `lit`, when set, is
/// the per-channel Lambert multiplier from `lightMultiplier` (albedo lighting,
/// alpha untouched). `grad` carries the per-pixel UV gradient constants when the
/// texture has mip levels and `lod_mode == .trilinear`, and is ignored
/// otherwise.
fn shadePixel(
    texture: ?Texture,
    v0: ScreenVertex,
    v1: ScreenVertex,
    v2: ScreenVertex,
    w0: f64,
    w1: f64,
    w2: f64,
    inv_area: f64,
    rgba: [4]u8,
    lit: ?[3]f64,
    lod_mode: Mipmap,
    grad: ?GradSteps,
    sampling: Sampling,
) [4]u8 {
    const tex = texture orelse {
        if (lit) |lm| {
            var out: [4]u8 = undefined;
            for (0..3) |c| {
                out[c] = clampByte(@as(f64, @floatFromInt(rgba[c])) * lm[c]);
            }
            out[3] = rgba[3];
            return out;
        }
        return rgba;
    };
    // Perspective numerator and denominator, both divided by `area` so the
    // barycentric weights 0..area normalize correctly.
    const num_u = ((w0 * v0.uw + w1 * v1.uw) + w2 * v2.uw) * inv_area;
    const num_v = ((w0 * v0.vw + w1 * v1.vw) + w2 * v2.vw) * inv_area;
    const den = ((w0 * v0.w_inv + w1 * v1.w_inv) + w2 * v2.w_inv) * inv_area;
    var u: f64 = 0.0;
    var v: f64 = 0.0;
    // The real pipeline clips to w > 1e-20 upstream; direct callers can still
    // hand in degenerate weights. Fall back to the affine answer rather than
    // emit NaN.
    if (den > 0.0 and std.math.isFinite(den)) {
        u = num_u / den;
        v = num_v / den;
    }
    // Level selection only exists when the texture actually carries mips; the
    // no-mip path therefore stays the exact single-sample expression above.
    const sampled = if (tex.mips.len == 0 or lod_mode == .level0) sampleTexture(tex, u, v) else blk: {
        const g = grad.?;
        // Anisotropic mode: the tap pattern depends on the per-pixel footprint, so
        // it needs the two screen-axis derivatives. A round footprint collapses to
        // the trilinear path inside `anisoFootprint`, bit for bit.
        if (lod_mode == .anisotropic) {
            const size = [2]f64{ @floatFromInt(tex.width), @floatFromInt(tex.height) };
            // The constant case was computed once per triangle at setup, bias
            // included; otherwise the footprint is per pixel.
            const footprint = g.constant_aniso orelse
                g.aniso(num_u, num_v, den, size, tex.mipLevelCount(), sampling);
            break :blk sampleAnisotropic(tex, u, v, footprint, size);
        }
        break :blk sampleTrilinear(tex, u, v, g.constant_lod orelse level: {
            // Perspective: the denominator varies per pixel, so the level does
            // too. One derivative and one log2 per pixel.
            const grad_px = texelGradient(num_u, num_v, den, g.dp, g.dq, g.dden, .{
                @floatFromInt(tex.width),
                @floatFromInt(tex.height),
            });
            break :level textureLodBiased(grad_px.du, grad_px.dv, tex.mipLevelCount(), sampling.lod_bias);
        });
    };
    if (lit) |lm| {
        var out: [4]u8 = undefined;
        for (0..4) |c| {
            if (c == 3) {
                // Alpha is never lit: keep the exact unlit tint-multiply formula.
                out[3] = @intFromFloat(@floor(
                    @as(f64, @floatFromInt(sampled[3])) *
                        @as(f64, @floatFromInt(rgba[3])) / 255.0 + 0.5,
                ));
                continue;
            }
            const s = ((@as(f64, @floatFromInt(sampled[c])) *
                @as(f64, @floatFromInt(rgba[c]))) * lm[c]) / 255.0;
            out[c] = clampByte(s);
        }
        return out;
    }
    return tintMultiply(sampled, rgba);
}

/// Rasterize one screen-space triangle. Returns false only when the triangle was
/// rejected by the cull mode or is exactly degenerate (zero area); a triangle
/// that survives but covers no pixel center still returns true, so the result
/// depends on the triangle and cull mode alone, never on the target size.
/// This is the exact entry point the reference vectors target.
///
/// When `texture` is set, UVs are interpolated perspective-correctly from the
/// vertices' `uw`/`vw`/`w_inv` (bypassing them with the defaults yields a
/// plain affine mapping), sampled with the texture's filter, and multiplied
/// by the `rgba` tint. When it is null the triangle is shaded flat.
///
/// When `options.light` is set, the albedo is multiplied per channel by
/// `ambient + max(0, n · l) * color`, where `n` is `world_normal` normalized
/// here (the raw, typically cross-product, world-space face normal; a zero or
/// non-finite normal lights with `ambient` only) and `l` the light's
/// direction normalized with a pinned f64 evaluation. The alpha channel is
/// never affected. `world_normal` must be the normal in the same space as the
/// light direction (world space); it is ignored when `options.light` is null.
pub fn rasterTriangle(
    target: *Target,
    a: ScreenVertex,
    b: ScreenVertex,
    c: ScreenVertex,
    rgba: [4]u8,
    options: Options,
    pixels_written: ?*usize,
    texture: ?Texture,
    world_normal: [3]f64,
) bool {
    // A single triangle has nowhere to accumulate sub-sample coverage, so the
    // antialiased modes are a no-op here; `drawMesh`/`rasterize` implement them.
    // The flag is cleared rather than silently ignored so callers do not believe
    // they got smoothing they did not.
    var opts = options;
    opts.antialias = .none;
    return rasterTriangleCore(target, a, b, c, rgba, opts, pixels_written, texture, world_normal, null);
}

/// The shared one-sample rasterizer, plus the accumulation mode used by
/// `drawMesh`: with `antialias = .edge` and an `accum` buffer it records
/// sub-sample coverage and shaded color instead of writing the target.
fn rasterTriangleCore(
    target: *Target,
    a: ScreenVertex,
    b: ScreenVertex,
    c: ScreenVertex,
    rgba: [4]u8,
    options: Options,
    pixels_written: ?*usize,
    texture: ?Texture,
    world_normal: [3]f64,
    accum: ?*AccumBuffers,
) bool {
    const v0 = a;
    var v1 = b;
    var v2 = c;
    var area = edge(v0.x, v0.y, v1.x, v1.y, v2.x, v2.y);
    if (area == 0) return false;

    // In a Y-down framebuffer the Y flip makes an NDC counter-clockwise triangle
    // come out with a negative signed area.
    const front = if (options.front_face == .counter_clockwise) area < 0 else area > 0;
    switch (options.cull) {
        .none => {},
        .back => if (!front) return false,
        .front => if (front) return false,
    }
    if (area < 0) {
        std.mem.swap(ScreenVertex, &v1, &v2);
        area = -area;
    }

    // Lambert multiplier per channel, computed once per surviving triangle —
    // the face normal is constant across it (clipping keeps sub-triangles
    // coplanar), so the pixel loop pays three multiplies and no divides.
    const lit: ?[3]f64 = if (options.light) |light| lightMultiplier(light, world_normal) else null;

    // Pixel centers sit at (x + 0.5, y + 0.5), i.e. half a pixel in fixed point.
    const bias0: i64 = if (isTopLeft(v1.x, v1.y, v2.x, v2.y)) 0 else 1;
    const bias1: i64 = if (isTopLeft(v2.x, v2.y, v0.x, v0.y)) 0 else 1;
    const bias2: i64 = if (isTopLeft(v0.x, v0.y, v1.x, v1.y)) 0 else 1;

    const half: i32 = subpixel_scale / 2;
    // Clamped *after* the shift, not before: `floorDiv` takes the floor of the
    // pixel index (`v >> 4`), so a vertex far to the left of the target yields a
    // large negative index. Clamping the fixed-point coordinate to 0 first left
    // a small negative `min_x` that the antialiasing halo below then widened by
    // one more, i.e. -2, and `clip_min_y - min_y` overflowed the i32 subtraction
    // that computes the box shift. Both paths pay the same four clamps.
    const min_x = @max(0, floorDiv(@min(v0.x, @min(v1.x, v2.x)) - half));
    const min_y = @max(0, floorDiv(@min(v0.y, @min(v1.y, v2.y)) - half));
    const max_x = @max(0, @min(@as(i32, @intCast(target.width)) - 1, floorDiv(@max(v0.x, @max(v1.x, v2.x)) - half)));
    const max_y = @max(0, @min(@as(i32, @intCast(target.height)) - 1, floorDiv(@max(v0.y, @max(v1.y, v2.y)) - half)));
    // An empty box means no pixel center can be inside. That is not culling:
    // the triangle was still accepted, it simply covers nothing here.
    if (min_x > max_x or min_y > max_y) return true;

    const px0 = min_x * subpixel_scale + half;
    const py0 = min_y * subpixel_scale + half;
    // Un-biased edge functions at the first pixel center. The top-left fill rule
    // is applied per pixel as `w - bias >= 0`, which keeps the coverage weights
    // (`w`) exact for both the fill rule and the sub-sample coverage count.
    const row0 = edge(v1.x, v1.y, v2.x, v2.y, px0, py0);
    const row1 = edge(v2.x, v2.y, v0.x, v0.y, px0, py0);
    const row2 = edge(v0.x, v0.y, v1.x, v1.y, px0, py0);

    // Stepping one pixel right/down changes each edge function by a constant,
    // so the inner loop needs no multiplications for coverage.
    const edge_steps = EdgeSteps.fromScreen(v0, v1, v2);
    const step_x0 = (@as(i64, v1.y) - v2.y) * subpixel_scale;
    const step_x1 = (@as(i64, v2.y) - v0.y) * subpixel_scale;
    const step_x2 = (@as(i64, v0.y) - v1.y) * subpixel_scale;
    const step_y0 = (@as(i64, v2.x) - v1.x) * subpixel_scale;
    const step_y1 = (@as(i64, v0.x) - v2.x) * subpixel_scale;
    const step_y2 = (@as(i64, v1.x) - v0.x) * subpixel_scale;

    const inv_area = 1.0 / @as(f64, @floatFromInt(area));
    // Mip level selection needs the per-pixel change of the perspective UV
    // numerator and denominator. Both are affine in screen space, so the six
    // constants are derived here once per triangle from the same per-pixel edge
    // steps the coverage loop uses (already in whole pixels). A texture without
    // mip levels, or `.level0`, never reads them.
    const grad: ?GradSteps = if (texture) |tex| blk: {
        if (tex.mips.len == 0 or options.mipmap == .level0) break :blk null;
        var g = GradSteps.init(v0, v1, v2, .{
            @as(f64, @floatFromInt(step_x0)) * inv_area,
            @as(f64, @floatFromInt(step_y0)) * inv_area,
        }, .{
            @as(f64, @floatFromInt(step_x1)) * inv_area,
            @as(f64, @floatFromInt(step_y1)) * inv_area,
        });
        const size = [2]f64{ @floatFromInt(tex.width), @floatFromInt(tex.height) };
        g.constant_lod = g.constantLod(v0.w_inv, size, tex.mipLevelCount(), options.sampling.lod_bias);
        if (options.mipmap == .anisotropic) g.constant_aniso = g.constantAniso(v0.w_inv, size, tex.mipLevelCount(), options.sampling);
        break :blk g;
    } else null;
    const z0: f64 = v0.z;
    const z1: f64 = v1.z;
    const z2: f64 = v2.z;
    const width: usize = target.width;
    var written: usize = 0;

    // Antialiased accumulation: one extra pixel of bounding box on every side (a
    // pixel whose center is outside can still be partially covered), unbiased
    // edge functions, and per-pixel resolution deferred to `resolveAccumulated`.
    // The one-sample path keeps the historical box and the biased accumulators
    // untouched, byte for byte.
    const aa = options.antialias == .edge and accum != null;
    const clip_min_x = if (aa) @max(0, @as(i32, @intCast(@as(u32, @intCast(@max(min_x, 0))) -| 1))) else min_x;
    const clip_min_y = if (aa) @max(0, @as(i32, @intCast(@as(u32, @intCast(@max(min_y, 0))) -| 1))) else min_y;
    // The halo can reach one pixel to the right/bottom, never past the target:
    // the extra pixel is only added when one exists.
    const clip_max_x = if (aa) @min(@as(i32, @intCast(target.width)) - 1, max_x + 1) else max_x;
    const clip_max_y = if (aa) @min(@as(i32, @intCast(target.height)) - 1, max_y + 1) else max_y;
    if (clip_min_x > clip_max_x or clip_min_y > clip_max_y) return true;

    // Offsets of the (possibly widened) box origin from the pixel-center origin the
    // rows were seeded at, in whole pixels — `step_x*`/`step_y*` are already
    // per-pixel deltas. Zero on the one-sample path.
    const shift_y: i64 = @as(i64, clip_min_y) - @as(i64, min_y);
    const shift_x: i64 = @as(i64, clip_min_x) - @as(i64, min_x);
    var row0c = if (aa) row0 + step_y0 * shift_y + step_x0 * shift_x else row0 - bias0;
    var row1c = if (aa) row1 + step_y1 * shift_y + step_x1 * shift_x else row1 - bias1;
    var row2c = if (aa) row2 + step_y2 * shift_y + step_x2 * shift_x else row2 - bias2;

    // Largest edge-function contribution any sub-sample of a pixel can have:
    // the sample offsets span +-`aa_sample_reach` units on both axes.
    const aa_reach: [3]i64 = .{
        aa_sample_reach * (absI(edge_steps.dx[0]) + absI(edge_steps.dy[0])),
        aa_sample_reach * (absI(edge_steps.dx[1]) + absI(edge_steps.dy[1])),
        aa_sample_reach * (absI(edge_steps.dx[2]) + absI(edge_steps.dy[2])),
    };

    var y = clip_min_y;
    while (y <= clip_max_y) : (y += 1) {
        var w0 = row0c;
        var w1 = row1c;
        var w2 = row2c;
        var x = clip_min_x;
        var index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
        while (x <= clip_max_x) : (x += 1) {
            // One-sample path: `w*` are already biased, so a single sign test is
            // the watertight top-left fill rule and `wgt*` are the weights.
            // Antialiased path: `w*` are unbiased, `> 0` on all three means the
            // center is strictly inside, and edge pixels are counted per sub-sample.
            var coverage: u16 = aa_samples;
            var owned: bool = undefined;
            var weight0: i64 = undefined;
            var weight1: i64 = undefined;
            var weight2: i64 = undefined;
            if (aa) {
                // A pixel center inside the triangle is *not* enough for full
                // coverage: it can sit less than one sub-sample spacing from an
                // edge while most sub-samples fall outside (the case the earlier
                // center-only shortcut got wrong on slanted edges). The sample
                // grid reaches at most `aa_sample_reach` units from the center on
                // either axis, so `w > reach` proves every sub-sample is inside
                // and `w < -reach` proves every sub-sample is outside — both
                // decided with one comparison per edge and nothing else.
                if (w0 > aa_reach[0] and w1 > aa_reach[1] and w2 > aa_reach[2]) {
                    coverage = aa_samples;
                    owned = true;
                } else if (w0 < -aa_reach[0] or w1 < -aa_reach[1] or w2 < -aa_reach[2]) {
                    coverage = 0;
                    owned = false;
                } else {
                    coverage = coverageCount(aa_grid, .{ w0, w1, w2 }, edge_steps, .{ bias0, bias1, bias2 });
                    owned = coverage > 0;
                }
                weight0 = w0;
                weight1 = w1;
                weight2 = w2;
            } else {
                owned = (w0 | w1 | w2) >= 0;
                weight0 = w0 + bias0;
                weight1 = w1 + bias1;
                weight2 = w2 + bias2;
            }
            if (owned) {
                // NDC z is affine in screen space after the divide, so plain
                // barycentric interpolation is already perspective-correct.
                const wgt0 = @as(f64, @floatFromInt(weight0));
                const wgt1 = @as(f64, @floatFromInt(weight1));
                const wgt2 = @as(f64, @floatFromInt(weight2));
                const depth: f32 = @floatCast(((wgt0 * z0 + wgt1 * z1) + wgt2 * z2) * inv_area);
                if (!options.depth_test or depth < target.depth[index]) {
                    const shaded = shadePixel(texture, v0, v1, v2, wgt0, wgt1, wgt2, inv_area, rgba, lit, options.mipmap, grad, options.sampling);
                    if (aa) {
                        // Accumulate; `resolveAccumulated` composites once the
                        // whole mesh has been submitted. The mapping is
                        // box-relative, and a pixel outside the box is dropped
                        // rather than written out of bounds.
                        const buf = accum.?;
                        if (buf.slot(index, width)) |offset| {
                            const slot = &buf.coverage[offset];
                            if (slot.count == 0) {
                                buf.ids[buf.count] = @intCast(offset);
                                buf.count += 1;
                            }
                            if (slot.count < coverage) {
                                slot.rgba = shaded;
                                slot.depth = depth;
                            }
                            const total: u32 = @as(u32, slot.count) + coverage;
                            slot.count = @intCast(@min(total, aa_samples));
                            // `written` is not bumped here: the pixel is counted
                            // once, when it is resolved, not once per sub-sample
                            // contribution (shared edges touch a pixel twice).
                        }
                    } else {
                        const o = index * 4;
                        const out_rgba = if (options.blend == .none)
                            shaded
                        else
                            blendPixels(shaded, .{ target.color[o + 0], target.color[o + 1], target.color[o + 2], target.color[o + 3] }, options.blend);
                        target.color[o + 0] = out_rgba[0];
                        target.color[o + 1] = out_rgba[1];
                        target.color[o + 2] = out_rgba[2];
                        target.color[o + 3] = out_rgba[3];
                        if (options.depth_write) target.depth[index] = depth;
                        written += 1;
                    }
                }
            }
            w0 += step_x0;
            w1 += step_x1;
            w2 += step_x2;
            index += 1;
        }
        row0c += step_y0;
        row1c += step_y1;
        row2c += step_y2;
    }
    if (pixels_written) |out| out.* += written;
    return true;
}

// --- clip space -------------------------------------------------------------

/// A clip-space vertex carrying affine-in-t attributes. UVs travel alongside
/// the position from `transformVertex` through Sutherland-Hodgman clipping
/// (attribute interpolation at the clip parameter `t` is exact, the same way
/// position interpolation is), and are divided by `w` only at `toScreen`.
const ClipVertex = struct {
    /// Clip-space position: `p[0] = x`, `p[1] = y`, `p[2] = z`, `p[3] = w`.
    p: [4]f32,
    u: f64,
    v: f64,
};

/// The six frustum half-spaces in clip space (OpenGL convention, z in [-w, w]).
/// A vertex is inside when every distance is >= 0.
fn planeDistance(plane: usize, v: ClipVertex) f32 {
    const p = v.p;
    return switch (plane) {
        0 => p[3] + p[0], // left
        1 => p[3] - p[0], // right
        2 => p[3] + p[1], // bottom
        3 => p[3] - p[1], // top
        4 => p[3] + p[2], // near
        5 => p[3] - p[2], // far
        else => unreachable,
    };
}

fn lerpClip(a: ClipVertex, b: ClipVertex, t: f32) ClipVertex {
    var out: ClipVertex = undefined;
    const tf: f64 = t;
    inline for (0..4) |i| {
        out.p[i] = a.p[i] + (b.p[i] - a.p[i]) * t;
    }
    out.u = a.u + (b.u - a.u) * tf;
    out.v = a.v + (b.v - a.v) * tf;
    return out;
}

/// Clip a convex polygon against one plane, in place across two fixed buffers.
/// A triangle clipped by six planes has at most nine vertices, so the buffers
/// never need to grow and nothing is allocated.
fn clipPlane(count: usize, src: []const ClipVertex, dst: []ClipVertex, plane: usize) usize {
    if (count == 0) return 0;
    var n: usize = 0;
    var prev = src[count - 1];
    var prev_d = planeDistance(plane, prev);
    for (src[0..count]) |cur| {
        const cur_d = planeDistance(plane, cur);
        const prev_in = prev_d >= 0;
        const cur_in = cur_d >= 0;
        if (cur_in != prev_in) {
            const denom = prev_d - cur_d;
            // Signs differ, so denom is non-zero unless both are exactly zero,
            // in which case both endpoints are on the plane and already kept.
            if (denom != 0) {
                dst[n] = lerpClip(prev, cur, prev_d / denom);
                n += 1;
            }
        }
        if (cur_in) {
            dst[n] = cur;
            n += 1;
        }
        prev = cur;
        prev_d = cur_d;
    }
    return n;
}

fn toScreen(v: ClipVertex, width: f32, height: f32) ?ScreenVertex {
    const p = v.p;
    const w = p[3];
    if (!(w > 1e-20) or !std.math.isFinite(w)) return null;
    const inv = 1.0 / w;
    const invd: f64 = @floatCast(inv);
    const nx = p[0] * inv;
    const ny = p[1] * inv;
    const nz = p[2] * inv;
    if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) return null;
    const sx = (nx * 0.5 + 0.5) * width;
    // Y flip: NDC is Y-up, the framebuffer is top-down.
    const sy = (0.5 - ny * 0.5) * height;
    const fx = sx * @as(f32, @floatFromInt(subpixel_scale));
    const fy = sy * @as(f32, @floatFromInt(subpixel_scale));
    // Clipping bounds NDC to [-1, 1]; this guard only catches rounding at the
    // extreme or a pathological projection.
    const limit: f32 = @floatFromInt(std.math.maxInt(i32) / 2);
    if (!(fx > -limit and fx < limit and fy > -limit and fy < limit)) return null;
    return .{
        .x = @intFromFloat(@round(fx)),
        .y = @intFromFloat(@round(fy)),
        .z = std.math.clamp(nz, -1.0, 1.0),
        .uw = v.u * invd,
        .vw = v.v * invd,
        .w_inv = invd,
    };
}

/// Transform, clip and rasterize one clip-space triangle.
fn drawClipTriangle(
    target: *Target,
    tri: [3]ClipVertex,
    rgba: [4]u8,
    options: Options,
    stats: *Stats,
    texture: ?Texture,
    world_normal: [3]f64,
    accum: ?*AccumBuffers,
) void {
    var buf_a: [12]ClipVertex = undefined;
    var buf_b: [12]ClipVertex = undefined;
    @memcpy(buf_a[0..3], &tri);
    var count: usize = 3;
    var src: []ClipVertex = &buf_a;
    var dst: []ClipVertex = &buf_b;

    for (0..6) |plane| {
        count = clipPlane(count, src[0..count], dst, plane);
        if (count < 3) {
            stats.clipped += 1;
            return;
        }
        const tmp = src;
        src = dst;
        dst = tmp;
    }

    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    var screen: [12]ScreenVertex = undefined;
    for (src[0..count], 0..) |v, i| {
        screen[i] = toScreen(v, width, height) orelse {
            stats.clipped += 1;
            return;
        };
    }

    // The clipped polygon is convex, so a fan covers it exactly.
    var i: usize = 1;
    while (i + 1 < count) : (i += 1) {
        if (rasterTriangleCore(target, screen[0], screen[i], screen[i + 1], rgba, options, &stats.pixels, texture, world_normal, accum)) {
            stats.rasterized += 1;
        } else {
            stats.culled += 1;
        }
    }
}

fn transformVertex(m: Mat4, p: [3]f32, uv: [2]f32) ClipVertex {
    var out: ClipVertex = undefined;
    inline for (0..4) |r| {
        out.p[r] = m[0 * 4 + r] * p[0] + m[1 * 4 + r] * p[1] + m[2 * 4 + r] * p[2] + m[3 * 4 + r];
    }
    out.u = uv[0];
    out.v = uv[1];
    return out;
}

/// Rasterize one mesh with a flat RGBA color, or one multiplied by a
/// perspective-correct sampled texture. `world` and `view_projection` are
/// combined once, so the per-vertex cost is a single matrix-vector product.
///
/// A non-null `texture` requires `mesh.uvs` with one entry per position:
/// `error.InvalidUv` is returned otherwise. Texture contents are validated
/// before any draw (`error.InvalidTexture`).
pub fn drawMesh(
    target: *Target,
    mesh: Mesh,
    world: Mat4,
    view_projection: Mat4,
    rgba: [4]u8,
    options: Options,
    texture: ?Texture,
) Error!Stats {
    // No allocator, therefore nowhere to accumulate sub-sample coverage: the
    // antialiased modes require `drawMeshAlloc`/`rasterize` and are turned off
    // here instead of being silently approximated.
    var opts = options;
    opts.antialias = .none;
    // `antialias` is cleared above, so the allocation branch is never taken and
    // the only reachable errors are `Error`.
    return drawMeshAlloc(undefined, target, mesh, world, view_projection, rgba, opts, texture) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
        else => |e| e,
    };
}

/// `drawMesh` with the allocator needed by `antialias = .edge`. The scratch is
/// sized for the draw's bounding rectangle, used by every triangle of the mesh and
/// freed before returning; a failed allocation fails the draw **before** any
/// pixel is written, so the target is never left half-rendered.
pub fn drawMeshAlloc(
    gpa: Allocator,
    target: *Target,
    mesh: Mesh,
    world: Mat4,
    view_projection: Mat4,
    rgba: [4]u8,
    options: Options,
    texture: ?Texture,
) DrawError!Stats {
    if (mesh.indices.len % 3 != 0) return error.InvalidIndex;
    // Validate every index and every coordinate up front: a malformed mesh must
    // be rejected before a single fragment is written, so a failed draw never
    // leaves a half-rendered target.
    for (mesh.indices) |idx| {
        if (idx >= mesh.positions.len) return error.InvalidIndex;
    }
    for (mesh.positions) |p| {
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or !std.math.isFinite(p[2])) return error.InvalidVertex;
    }
    if (mesh.uvs) |uvs| {
        // Positions and UVs are indexed by the same index buffer, so the
        // arrays must be the same length even without a texture.
        if (uvs.len != mesh.positions.len) return error.InvalidUv;
        for (uvs) |uv| {
            if (!std.math.isFinite(uv[0]) or !std.math.isFinite(uv[1])) return error.InvalidUv;
        }
    }
    if (texture) |tex| {
        try tex.validate();
        const uvs = mesh.uvs orelse return error.InvalidUv;
        if (uvs.len != mesh.positions.len) return error.InvalidUv;
    }
    if (options.light) |light| try light.validate();

    // Antialiased draws need per-pixel accumulation across every triangle of the
    // mesh, so the coverage buffer covers this draw's bounding rectangle only.
    // Allocation happens before the first fragment: a failure leaves the target
    // untouched instead of half-rendered.
    const mvp = transform.multiply(view_projection, world);
    var opts = options;
    var accum_storage: ?AccumStorage = null;
    defer if (accum_storage) |*storage| storage.deinit(gpa);
    var accum: ?*AccumBuffers = null;
    var antialias_downgraded = false;
    if (options.antialias == .edge) {
        if (aaScratchBytes(target, mesh, mvp) <= max_aa_scratch_bytes) {
            accum_storage = try AccumStorage.init(gpa, target, mesh, mvp);
            accum = &accum_storage.?.buffers;
        } else {
            // A hostile reach can imply several GiB of scratch; downgrade to
            // the one-sample path rather than allocating it.
            opts.antialias = .none;
            antialias_downgraded = true;
        }
    }

    var stats: Stats = .{};
    stats.antialias_downgraded = antialias_downgraded;
    var i: usize = 0;
    while (i < mesh.indices.len) : (i += 3) {
        stats.submitted += 1;
        const idx0 = mesh.indices[i];
        const idx1 = mesh.indices[i + 1];
        const idx2 = mesh.indices[i + 2];
        if (idx0 >= mesh.positions.len or idx1 >= mesh.positions.len or idx2 >= mesh.positions.len)
            return error.InvalidIndex;
        const uv0: [2]f32 = if (mesh.uvs) |uvs| uvs[idx0] else .{ 0, 0 };
        const uv1: [2]f32 = if (mesh.uvs) |uvs| uvs[idx1] else .{ 0, 0 };
        const uv2: [2]f32 = if (mesh.uvs) |uvs| uvs[idx2] else .{ 0, 0 };
        var world_normal: [3]f64 = .{ 0.0, 0.0, 0.0 };
        if (options.light != null) {
            world_normal = faceNormal(
                worldPoint(world, mesh.positions[idx0]),
                worldPoint(world, mesh.positions[idx1]),
                worldPoint(world, mesh.positions[idx2]),
            );
        }
        const tri = [3]ClipVertex{
            transformVertex(mvp, mesh.positions[idx0], uv0),
            transformVertex(mvp, mesh.positions[idx1], uv1),
            transformVertex(mvp, mesh.positions[idx2], uv2),
        };
        drawClipTriangle(target, tri, rgba, opts, &stats, texture, world_normal, accum);
    }
    if (accum) |buf| resolveAccumulated(target, buf, opts, &stats);
    return stats;
}

/// World-space position of `p` in f64, column-major mat4. Used for the face
/// normal, which must live in the same (world) space as the light direction.
/// The operation order is pinned so the reference vectors reproduce it.
fn worldPoint(world: Mat4, p: [3]f32) [3]f64 {
    const x = @as(f64, @floatCast(p[0]));
    const y = @as(f64, @floatCast(p[1]));
    const z = @as(f64, @floatCast(p[2]));
    return .{
        @as(f64, @floatCast(world[0])) * x + @as(f64, @floatCast(world[4])) * y + @as(f64, @floatCast(world[8])) * z + @as(f64, @floatCast(world[12])),
        @as(f64, @floatCast(world[1])) * x + @as(f64, @floatCast(world[5])) * y + @as(f64, @floatCast(world[9])) * z + @as(f64, @floatCast(world[13])),
        @as(f64, @floatCast(world[2])) * x + @as(f64, @floatCast(world[6])) * y + @as(f64, @floatCast(world[10])) * z + @as(f64, @floatCast(world[14])),
    };
}

/// `cross(b - a, c - a)` for world-space points, deliberately not normalized —
/// `lightMultiplier` normalizes with a pinned order.
fn faceNormal(a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    const e0 = b[0] - a[0];
    const e1 = b[1] - a[1];
    const e2 = b[2] - a[2];
    const f0 = c[0] - a[0];
    const f1 = c[1] - a[1];
    const f2 = c[2] - a[2];
    return .{
        e1 * f2 - e2 * f1,
        e2 * f0 - e0 * f2,
        e0 * f1 - e1 * f0,
    };
}

/// Rasterize an extracted draw list.
///
/// `resources` is duck-typed and resolved per command, keeping this module free
/// of any asset-layer dependency. It must provide:
///
/// - `fn mesh(self, handle: u32) ?Mesh`
/// - `fn color(self, handle: u32) ?[4]f32` — linear RGBA in [0, 1]
/// - `fn texture(self, handle: u32) ?Texture` — optional, detected at comptime
///   via `@hasDecl`, which only sees `pub` decls; absent or returning null,
///   the material shades flat
/// - `fn directionalLight(self) ?Light` — optional, same comptime detection;
///   supplies one world-space directional Lambert light for every command.
///   An explicit `options.light` set by the caller wins over the provider's.
///
/// A command whose mesh or material handle does not resolve is counted in
/// `skipped_draws` and leaves the target untouched. A command whose material
/// resolves a texture but whose mesh carries no (or a mismatched) `uvs` is
/// likewise counted in `skipped_draws` and leaves the target untouched. A
/// malformed texture is a hard `error.InvalidTexture`. Attributes are
/// interpolated perspective-correctly; UV clipping is exact because UV
/// attributes travel through Sutherland-Hodgman at the clip parameter.
pub fn rasterize(
    target: *Target,
    commands: []const DrawCommand,
    view_projection: Mat4,
    resources: anytype,
    options: Options,
) DrawError!Stats {
    // No allocator: antialiasing needs per-draw accumulation scratch, so the mode
    // is turned off here rather than approximated. Use `rasterizeAlloc` for it.
    var opts = options;
    opts.antialias = .none;
    return rasterizeAlloc(undefined, target, commands, view_projection, resources, opts);
}

/// `rasterize` with the allocator `antialias = .edge` needs. The scratch is
/// allocated per draw command (sized to that draw's reach) and freed before the
/// next one, and a failed allocation fails that command with `OutOfMemory` before
/// any of its pixels are written.
pub fn rasterizeAlloc(
    gpa: Allocator,
    target: *Target,
    commands: []const DrawCommand,
    view_projection: Mat4,
    resources: anytype,
    options: Options,
) DrawError!Stats {
    const have_texture = comptime @hasDecl(@TypeOf(resources), "texture");
    const have_light = comptime @hasDecl(@TypeOf(resources), "directionalLight");
    var stats: Stats = .{};
    for (commands) |cmd| {
        const mesh = resources.mesh(cmd.mesh) orelse {
            stats.skipped_draws += 1;
            continue;
        };
        const linear = resources.color(cmd.material) orelse {
            stats.skipped_draws += 1;
            continue;
        };
        var rgba: [4]u8 = undefined;
        for (&rgba, linear) |*out, component| {
            out.* = @intFromFloat(@round(std.math.clamp(component, 0.0, 1.0) * 255.0));
        }
        var texture: ?Texture = null;
        if (comptime have_texture) {
            if (resources.texture(cmd.material)) |tex| {
                try tex.validate();
                const uv_ok = if (mesh.uvs) |uvs| uvs.len == mesh.positions.len else false;
                if (!uv_ok) {
                    stats.skipped_draws += 1;
                    continue;
                }
                texture = tex;
            }
        }
        // An explicit Options.light wins over the provider's light.
        var draw_options = options;
        if (draw_options.light == null and comptime have_light) {
            if (resources.directionalLight()) |light| {
                draw_options.light = light;
            }
        }
        stats.add(try drawMeshAlloc(gpa, target, mesh, cmd.world, view_projection, rgba, draw_options, texture));
    }
    return stats;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// Allocate a target for tests only.
const TestSurface = struct {
    target: Target,
    color: []u8,
    depth: []f32,

    fn init(w: u32, h: u32) !TestSurface {
        const n = @as(usize, w) * h;
        const color = try testing.allocator.alloc(u8, n * 4);
        errdefer testing.allocator.free(color);
        const depth = try testing.allocator.alloc(f32, n);
        errdefer testing.allocator.free(depth);
        var self = TestSurface{
            .color = color,
            .depth = depth,
            .target = try Target.init(w, h, color, depth),
        };
        self.target.clear(.{ 0, 0, 0, 0 }, 1.0);
        return self;
    }

    fn deinit(self: *TestSurface) void {
        testing.allocator.free(self.color);
        testing.allocator.free(self.depth);
    }

    fn covered(self: TestSurface) usize {
        var n: usize = 0;
        for (0..self.target.pixelCount()) |i| {
            if (self.target.color[i * 4 + 3] != 0) n += 1;
        }
        return n;
    }
};

const red: [4]u8 = .{ 255, 0, 0, 255 };
const green: [4]u8 = .{ 0, 255, 0, 255 };
const white: [4]u8 = .{ 255, 255, 255, 255 };

fn sv(x: i32, y: i32, z: f32) ScreenVertex {
    return .{ .x = x * subpixel_scale, .y = y * subpixel_scale, .z = z };
}

test "Target rejects mismatched buffers and invalid dimensions" {
    var color: [16]u8 = undefined;
    var depth: [4]f32 = undefined;
    try testing.expectError(error.InvalidDimension, Target.init(0, 4, &color, &depth));
    try testing.expectError(error.InvalidDimension, Target.init(4, 0, &color, &depth));
    try testing.expectError(error.InvalidDimension, Target.init(max_dimension + 1, 1, &color, &depth));
    try testing.expectError(error.InvalidTarget, Target.init(2, 2, color[0..15], &depth));
    try testing.expectError(error.InvalidTarget, Target.init(2, 2, &color, depth[0..3]));
    const t = try Target.init(2, 2, &color, &depth);
    try testing.expectEqual(@as(usize, 4), t.pixelCount());
}

test "clear resets color and depth" {
    var s = try TestSurface.init(3, 2);
    defer s.deinit();
    s.target.color[0] = 9;
    s.target.depth[0] = -1;
    s.target.clear(.{ 7, 8, 9, 10 }, 0.5);
    for (0..s.target.pixelCount()) |i| {
        try testing.expectEqual(@as(u8, 7), s.target.color[i * 4]);
        try testing.expectEqual(@as(u8, 10), s.target.color[i * 4 + 3]);
        try testing.expectEqual(@as(f32, 0.5), s.target.depth[i]);
    }
}

test "top-left fill rule matches a hand-computed coverage set" {
    // Right triangle (0,0) (4,0) (0,4) in a 4x4 target. A pixel center is inside
    // when x + y <= 3; the hypotenuse is a bottom-right edge, so centers exactly
    // on it (x + y == 3) are excluded. That leaves the six pixels with x+y <= 2.
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const drew = rasterTriangle(&s.target, sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    try testing.expect(drew);
    try testing.expectEqual(@as(usize, 6), s.covered());
    for (0..4) |y| {
        for (0..4) |x| {
            const want = x + y <= 2;
            const got = s.target.colorAt(@intCast(x), @intCast(y))[3] != 0;
            try testing.expectEqual(want, got);
        }
    }
}

test "shared edge is covered exactly once across a split quad" {
    // Two triangles tiling a 4x4 quad. Rasterized separately, their coverage
    // counts must sum to 16 (no overlap) and their union must be 16 (no gap).
    var a = try TestSurface.init(4, 4);
    defer a.deinit();
    var b = try TestSurface.init(4, 4);
    defer b.deinit();
    _ = rasterTriangle(&a.target, sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    _ = rasterTriangle(&b.target, sv(4, 0, 0), sv(4, 4, 0), sv(0, 4, 0), green, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqual(@as(usize, 6), a.covered());
    try testing.expectEqual(@as(usize, 10), b.covered());
    var union_count: usize = 0;
    for (0..a.target.pixelCount()) |i| {
        const ca = a.target.color[i * 4 + 3] != 0;
        const cb = b.target.color[i * 4 + 3] != 0;
        try testing.expect(!(ca and cb));
        if (ca or cb) union_count += 1;
    }
    try testing.expectEqual(@as(usize, 16), union_count);
}

test "shared edge partition holds for many quad splits" {
    // Same property with subpixel vertices and non-axis-aligned splits, which is
    // where a float-based edge function would leave cracks.
    const splits = [_]i32{ 1, 3, 5, 7, 11, 13, 19, 23, 29, 31 };
    for (splits) |k| {
        var a = try TestSurface.init(8, 8);
        defer a.deinit();
        var b = try TestSurface.init(8, 8);
        defer b.deinit();
        const p0 = ScreenVertex{ .x = 0, .y = 0, .z = 0 };
        const p1 = ScreenVertex{ .x = 8 * subpixel_scale, .y = 0, .z = 0 };
        const p2 = ScreenVertex{ .x = 8 * subpixel_scale, .y = 8 * subpixel_scale, .z = 0 };
        const p3 = ScreenVertex{ .x = 0, .y = 8 * subpixel_scale, .z = 0 };
        // Shared diagonal perturbed to a subpixel position on both triangles.
        const d0 = ScreenVertex{ .x = k, .y = k * 2, .z = 0 };
        const d1 = ScreenVertex{ .x = 8 * subpixel_scale - k, .y = 8 * subpixel_scale - k, .z = 0 };
        _ = rasterTriangle(&a.target, p0, p1, d1, red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        _ = rasterTriangle(&a.target, p0, d1, d0, red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        _ = rasterTriangle(&a.target, p0, d0, p3, red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        _ = rasterTriangle(&b.target, p1, p2, d1, green, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        _ = rasterTriangle(&b.target, d1, p2, p3, green, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        _ = rasterTriangle(&b.target, d1, p3, d0, green, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
        for (0..a.target.pixelCount()) |i| {
            const ca = a.target.color[i * 4 + 3] != 0;
            const cb = b.target.color[i * 4 + 3] != 0;
            try testing.expect(!(ca and cb));
            try testing.expect(ca or cb);
        }
    }
}

test "degenerate triangles are rejected" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    try testing.expect(!rasterTriangle(&s.target, sv(0, 0, 0), sv(2, 0, 0), sv(4, 0, 0), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 }));
    try testing.expect(!rasterTriangle(&s.target, sv(1, 1, 0), sv(1, 1, 0), sv(1, 1, 0), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 }));
    try testing.expect(!rasterTriangle(&s.target, sv(0, 0, 0), sv(2, 2, 0), sv(4, 4, 0), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 }));
    try testing.expectEqual(@as(usize, 0), s.covered());
}

test "cull modes select one winding" {
    // (0,0) (4,0) (0,4) has positive screen area, i.e. it is clockwise in NDC.
    const cw = [_]ScreenVertex{ sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0) };
    const ccw = [_]ScreenVertex{ sv(0, 0, 0), sv(0, 4, 0), sv(4, 0, 0) };
    for ([_]FrontFace{ .counter_clockwise, .clockwise }) |ff| {
        for ([_][]const ScreenVertex{ &cw, &ccw }) |tri| {
            const front = if (ff == .counter_clockwise) tri[1].y > 0 else tri[1].x > 0;
            inline for (.{ CullMode.none, CullMode.back, CullMode.front }) |mode| {
                var s = try TestSurface.init(4, 4);
                defer s.deinit();
                const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], red, .{ .cull = mode, .front_face = ff }, null, null, .{ 0.0, 0.0, 0.0 });
                const want = switch (mode) {
                    .none => true,
                    .back => front,
                    .front => !front,
                };
                try testing.expectEqual(want, drew);
                try testing.expectEqual(@as(usize, if (want) 6 else 0), s.covered());
            }
        }
    }
}

test "coverage is identical for both windings when culling is off" {
    var a = try TestSurface.init(8, 8);
    defer a.deinit();
    var b = try TestSurface.init(8, 8);
    defer b.deinit();
    const v0 = ScreenVertex{ .x = 3, .y = 5, .z = 0 };
    const v1 = ScreenVertex{ .x = 100, .y = 17, .z = 0 };
    const v2 = ScreenVertex{ .x = 41, .y = 120, .z = 0 };
    _ = rasterTriangle(&a.target, v0, v1, v2, red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    _ = rasterTriangle(&b.target, v0, v2, v1, red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqualSlices(u8, a.color, b.color);
}

test "depth test keeps the nearest fragment regardless of draw order" {
    const tri = [_]ScreenVertex{ sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0) };
    for ([_]bool{ false, true }) |far_first| {
        var s = try TestSurface.init(4, 4);
        defer s.deinit();
        const order = [_]f32{ if (far_first) 0.8 else 0.2, if (far_first) 0.2 else 0.8 };
        const colors = [_][4]u8{ if (far_first) green else red, if (far_first) red else green };
        var pixels: usize = 0;
        for (order, colors) |z, col| {
            _ = rasterTriangle(&s.target, .{ .x = tri[0].x, .y = tri[0].y, .z = z }, .{ .x = tri[1].x, .y = tri[1].y, .z = z }, .{ .x = tri[2].x, .y = tri[2].y, .z = z }, col, .{ .cull = .none }, &pixels, null, .{ 0.0, 0.0, 0.0 });
        }
        // Near first: the far pass then fails every test (6 writes). Far first:
        // it writes 6 and the near pass overwrites all 6 (12 writes). Either way
        // the surviving color and depth are the near ones.
        try testing.expectEqual(@as(usize, if (far_first) 12 else 6), pixels);
        for (0..4) |y| for (0..4) |x| {
            if (x + y <= 2) {
                try testing.expectEqualSlices(u8, &red, &s.target.colorAt(@intCast(x), @intCast(y)));
                try testing.expectApproxEqAbs(@as(f32, 0.2), s.target.depthAt(@intCast(x), @intCast(y)), 1e-6);
            }
        };
    }
}

test "equal depth does not overwrite" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    _ = rasterTriangle(&s.target, sv(0, 0, 0.5), sv(4, 0, 0.5), sv(0, 4, 0.5), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    var pixels: usize = 0;
    _ = rasterTriangle(&s.target, sv(0, 0, 0.5), sv(4, 0, 0.5), sv(0, 4, 0.5), green, .{ .cull = .none }, &pixels, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqual(@as(usize, 0), pixels);
    try testing.expectEqualSlices(u8, &red, &s.target.colorAt(0, 0));
}

test "depth_write false leaves the depth buffer untouched" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    var pixels: usize = 0;
    _ = rasterTriangle(&s.target, sv(0, 0, -0.5), sv(4, 0, -0.5), sv(0, 4, -0.5), red, .{ .cull = .none, .depth_write = false }, &pixels, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqual(@as(usize, 6), pixels);
    for (s.depth) |d| try testing.expectEqual(@as(f32, 1.0), d);
    // A later, farther triangle still passes because depth stayed at the clear.
    _ = rasterTriangle(&s.target, sv(0, 0, 0.9), sv(4, 0, 0.9), sv(0, 4, 0.9), green, .{ .cull = .none }, &pixels, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqual(@as(usize, 12), pixels);
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(0, 0));
}

test "depth_test false paints in submission order" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    _ = rasterTriangle(&s.target, sv(0, 0, -0.9), sv(4, 0, -0.9), sv(0, 4, -0.9), red, .{ .cull = .none, .depth_test = false }, null, null, .{ 0.0, 0.0, 0.0 });
    _ = rasterTriangle(&s.target, sv(0, 0, 0.9), sv(4, 0, 0.9), sv(0, 4, 0.9), green, .{ .cull = .none, .depth_test = false }, null, null, .{ 0.0, 0.0, 0.0 });
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(0, 0));
}

test "depth interpolates linearly across the triangle" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    // z = -1 at x=0, +1 at x=4: the value at a pixel center is x/2 - 0.75.
    _ = rasterTriangle(&s.target, sv(0, 0, -1), sv(4, 0, 1), sv(0, 4, -1), red, .{ .cull = .none }, null, null, .{ 0.0, 0.0, 0.0 });
    for (0..4) |y| for (0..4) |x| {
        if (x + y <= 2) {
            const want = @as(f32, @floatFromInt(x)) * 0.5 - 0.75;
            try testing.expectApproxEqAbs(want, s.target.depthAt(@intCast(x), @intCast(y)), 1e-6);
        }
    };
}

// --- clip space / mesh / draw list tests ------------------------------------

const camera = @import("camera.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");

/// An orthographic setup whose mapping is easy to reason about exactly: the
/// identity view, x/y in [-2, 2] mapping to the full viewport, and z in [0, -4]
/// mapping to NDC [-1, 1]. A quad at z = -2 lands at depth 0.
fn orthoSetup() Mat4 {
    return camera.orthographic(-2, 2, -2, 2, 0, 4);
}

const quad_positions = [_][3]f32{
    .{ -2, -2, -2 }, .{ 2, -2, -2 }, .{ 2, 2, -2 }, .{ -2, 2, -2 },
};
const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

fn quadMesh() Mesh {
    return .{ .positions = &quad_positions, .indices = &quad_indices };
}

test "drawMesh: malformed meshes are rejected before any pixel is written" {
    // Shared helpers: a 2x2 quad surface with a known cleared state.
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const before_color = try testing.allocator.dupe(u8, s.color);
    defer testing.allocator.free(before_color);

    // Out-of-range index: validation happens up front, not inside the draw loop.
    const nan_mesh = Mesh{
        .positions = &.{ .{ 0, 0, 0 }, .{ std.math.nan(f32), 1, 0 }, .{ 1, 0, 0 } },
        .indices = &.{ 0, 1, 2 },
    };
    try testing.expectError(error.InvalidVertex, drawMesh(&s.target, nan_mesh, transform.identity(), orthoSetup(), red, .{}, null));
    try testing.expectEqualSlices(u8, before_color, s.color);

    const bad_index_mesh = Mesh{
        .positions = &quad_positions,
        .indices = &.{ 0, 1, 99 },
    };
    try testing.expectError(error.InvalidIndex, drawMesh(&s.target, bad_index_mesh, transform.identity(), orthoSetup(), red, .{}, null));
    try testing.expectEqualSlices(u8, before_color, s.color);

    // A UV array shorter than the position array is rejected even without a texture.
    const bad_uv_mesh = Mesh{
        .positions = &quad_positions,
        .indices = &quad_indices,
        .uvs = &.{.{ 0, 0 }},
    };
    try testing.expectError(error.InvalidUv, drawMesh(&s.target, bad_uv_mesh, transform.identity(), orthoSetup(), red, .{}, null));
    try testing.expectEqualSlices(u8, before_color, s.color);
}

test "drawMesh: a front-facing quad covers the whole viewport" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const stats = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 2), stats.submitted);
    try testing.expectEqual(@as(usize, 2), stats.rasterized);
    try testing.expectEqual(@as(usize, 0), stats.culled);
    try testing.expectEqual(@as(usize, 0), stats.clipped);
    try testing.expectEqual(@as(usize, 64), stats.pixels);
    try testing.expectEqual(@as(usize, 64), s.covered());
    for (s.depth) |d| try testing.expectApproxEqAbs(@as(f32, 0), d, 1e-6);
}

test "drawMesh: the shared diagonal of a quad leaves no seam" {
    var s = try TestSurface.init(16, 16);
    defer s.deinit();
    const stats = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 256), stats.pixels);
    for (s.color[3..], 0..) |_, i| {
        if (i % 4 == 0) try testing.expectEqual(@as(u8, 255), s.color[i + 3]);
    }
}

test "drawMesh: a back-facing quad is culled, and cull none draws it" {
    const back_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
    const mesh = Mesh{ .positions = &quad_positions, .indices = &back_indices };
    var a = try TestSurface.init(8, 8);
    defer a.deinit();
    const culled = try drawMesh(&a.target, mesh, transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 2), culled.culled);
    try testing.expectEqual(@as(usize, 0), culled.pixels);
    var b = try TestSurface.init(8, 8);
    defer b.deinit();
    const drawn = try drawMesh(&b.target, mesh, transform.identity(), orthoSetup(), red, .{ .cull = .none }, null);
    try testing.expectEqual(@as(usize, 2), drawn.rasterized);
    try testing.expectEqual(@as(usize, 64), drawn.pixels);
}

test "drawMesh: world transform is applied before the view-projection" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // Shrink the quad to a quarter of its size: it should cover the middle 4x4.
    var world = transform.identity();
    world[0] = 0.5;
    world[5] = 0.5;
    const stats = try drawMesh(&s.target, quadMesh(), world, orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    for (0..8) |y| for (0..8) |x| {
        const want = x >= 2 and x < 6 and y >= 2 and y < 6;
        try testing.expectEqual(want, s.target.colorAt(@intCast(x), @intCast(y))[3] != 0);
    };
}

test "drawMesh: geometry entirely behind the near plane is clipped" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const positions = [_][3]f32{ .{ -2, -2, 1 }, .{ 2, -2, 1 }, .{ 0, 2, 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 1), stats.submitted);
    try testing.expectEqual(@as(usize, 1), stats.clipped);
    try testing.expectEqual(@as(usize, 0), stats.pixels);
    try testing.expectEqual(@as(usize, 0), s.covered());
}

test "drawMesh: geometry beyond the far plane is clipped" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const positions = [_][3]f32{ .{ -2, -2, -9 }, .{ 2, -2, -9 }, .{ 0, 2, -9 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 1), stats.clipped);
    try testing.expectEqual(@as(usize, 0), s.covered());
}

test "drawMesh: a triangle straddling the near plane is clipped, not projected" {
    var s = try TestSurface.init(16, 16);
    defer s.deinit();
    const cam = camera.Camera.perspectiveLookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
    // One vertex sits between the eye and the near plane (w < near), two are well
    // in front. Without near clipping the near vertex projects to a huge
    // coordinate and the triangle smears across the whole target.
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 0, 1, 4.9 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{}, null);
    try testing.expectEqual(@as(usize, 1), stats.submitted);
    try testing.expectEqual(@as(usize, 0), stats.clipped);
    try testing.expect(stats.rasterized >= 1);
    for (s.depth) |d| try testing.expect(std.math.isFinite(d));
    // The far edge of the triangle is at z=0, which projects to a bounded band;
    // it must not fill the target.
    try testing.expect(s.covered() > 0 and s.covered() < 256);
}

test "drawMesh: a vertex exactly at the eye does not produce NaN" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const cam = camera.Camera.perspectiveLookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 0, 0, 5 } };
    const indices = [_]u32{ 0, 1, 2 };
    _ = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{}, null);
    for (s.depth) |d| try testing.expect(std.math.isFinite(d));
}

test "drawMesh: a huge off-screen triangle is clipped to the viewport" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const positions = [_][3]f32{ .{ -1000, -1000, -2 }, .{ 1000, -1000, -2 }, .{ 0, 1000, -2 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 64), stats.pixels);
    try testing.expectEqual(@as(usize, 64), s.covered());
}

test "drawMesh: rejects malformed index buffers" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const short = [_]u32{ 0, 1 };
    try testing.expectError(error.InvalidIndex, drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &short }, transform.identity(), orthoSetup(), red, .{}, null));
    const oob = [_]u32{ 0, 1, 99 };
    try testing.expectError(error.InvalidIndex, drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &oob }, transform.identity(), orthoSetup(), red, .{}, null));
    const empty = try drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &.{} }, transform.identity(), orthoSetup(), red, .{}, null);
    try testing.expectEqual(@as(usize, 0), empty.submitted);
}

/// Minimal resource provider: handles index directly into slices. This is the
/// whole adaptation cost a caller pays, and it keeps `render` independent of the
/// asset layer.
const SliceResources = struct {
    meshes: []const Mesh,
    colors: []const [4]f32,

    pub fn mesh(self: SliceResources, handle: u32) ?Mesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: SliceResources, handle: u32) ?[4]f32 {
        if (handle >= self.colors.len) return null;
        return self.colors[handle];
    }
};

fn command(mesh: u32, material: u32) DrawCommand {
    return .{
        .entity = .{ .index = 1, .generation = 0 },
        .mesh = mesh,
        .material = material,
        .world = transform.identity(),
        .bounds = @import("culling.zig").Aabb.fromMinMax(.{ -2, -2, -2 }, .{ 2, 2, 2 }),
        .depth = 2,
    };
}

test "rasterize: resolves handles and quantizes linear colors" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 0.5, 0.0, 1.0 }};
    const res = SliceResources{ .meshes = &meshes, .colors = &colors };
    const stats = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    try testing.expectEqual(@as(usize, 0), stats.skipped_draws);
    // 0.5 * 255 = 127.5, rounded to nearest.
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, &s.target.colorAt(0, 0));
}

test "rasterize: clamps out-of-range color components" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 2.0, -1.0, 0.0, 1.0 }};
    const res = SliceResources{ .meshes = &meshes, .colors = &colors };
    _ = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(0, 0));
}

test "rasterize: unresolved handles are skipped without touching the target" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1, 1, 1, 1 }};
    const res = SliceResources{ .meshes = &meshes, .colors = &colors };
    const stats = try rasterize(&s.target, &.{ command(7, 0), command(0, 9) }, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 2), stats.skipped_draws);
    try testing.expectEqual(@as(usize, 0), stats.pixels);
    try testing.expectEqual(@as(usize, 0), s.covered());
    for (s.depth) |d| try testing.expectEqual(@as(f32, 1.0), d);
}

test "rasterize: an empty draw list is a no-op" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const res = SliceResources{ .meshes = &.{}, .colors = &.{} };
    const stats = try rasterize(&s.target, &.{}, orthoSetup(), res, .{});
    try testing.expectEqual(Stats{}, stats);
}

test "rasterize: depth ordering across separate draw commands" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const near_positions = [_][3]f32{ .{ -2, -2, -1 }, .{ 2, -2, -1 }, .{ 2, 2, -1 }, .{ -2, 2, -1 } };
    const meshes = [_]Mesh{ quadMesh(), .{ .positions = &near_positions, .indices = &quad_indices } };
    const colors = [_][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 } };
    const res = SliceResources{ .meshes = &meshes, .colors = &colors };
    // Far quad first, then near: near must win everywhere.
    const stats = try rasterize(&s.target, &.{ command(0, 0), command(1, 1) }, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 32), stats.pixels);
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(2, 2));
    // Reverse order: the far quad must now be rejected entirely.
    s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
    const reversed = try rasterize(&s.target, &.{ command(1, 1), command(0, 0) }, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 16), reversed.pixels);
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(2, 2));
}

test "clipping a triangle against six planes stays within the fixed buffers" {
    // A triangle clipped by six half-spaces gains at most one vertex per plane,
    // so nine is the hard maximum and the 12-slot buffers cannot overflow. This
    // drives the growth path directly rather than trusting the bound.
    const cases = [_][3]ClipVertex{
        // Crosses all six: near+left+bottom at v0, right at v1, top+far at v2.
        .{ .{ .p = .{ -100, -100, -2, 1 }, .u = 0, .v = 0 }, .{ .p = .{ 100, -100, 0.5, 1 }, .u = 0, .v = 0 }, .{ .p = .{ 0, 100, 3, 1 }, .u = 0, .v = 0 } },
        // Crosses the four sides and the far plane.
        .{ .{ .p = .{ -3, -3, -1, 2 }, .u = 0, .v = 0 }, .{ .p = .{ 3, -3, -1, 2 }, .u = 0, .v = 0 }, .{ .p = .{ 0, 3, 5, 2 }, .u = 0, .v = 0 } },
        // Crosses only the four sides.
        .{ .{ .p = .{ -50, 0, -1, 2 }, .u = 0, .v = 0 }, .{ .p = .{ 50, -50, -1, 2 }, .u = 0, .v = 0 }, .{ .p = .{ 0, 50, -1, 2 }, .u = 0, .v = 0 } },
    };
    for (cases) |tri| {
        var buf_a: [12]ClipVertex = undefined;
        var buf_b: [12]ClipVertex = undefined;
        @memcpy(buf_a[0..3], &tri);
        var count: usize = 3;
        var src: []ClipVertex = &buf_a;
        var dst: []ClipVertex = &buf_b;
        var grew = false;
        for (0..6) |plane| {
            count = clipPlane(count, src[0..count], dst, plane);
            try testing.expect(count <= 9);
            if (count > 3) grew = true;
            if (count < 3) break;
            const tmp = src;
            src = dst;
            dst = tmp;
        }
        try testing.expect(grew);
        if (count >= 3) {
            // Every surviving vertex satisfies all six half-spaces.
            for (src[0..count]) |v| {
                for (0..6) |plane| try testing.expect(planeDistance(plane, v) >= -1e-3);
            }
        }
    }
}

test "drawMesh: a triangle crossing several planes still renders bounded output" {
    var s = try TestSurface.init(16, 16);
    defer s.deinit();
    const cam = camera.Camera.perspectiveLookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
    const positions = [_][3]f32{ .{ -100, -100, 4.9 }, .{ 100, -100, -50 }, .{ 0, 100, -200 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{}, null);
    try testing.expectEqual(@as(usize, 1), stats.submitted);
    try testing.expect(stats.pixels <= 256);
    for (s.depth) |d| try testing.expect(std.math.isFinite(d) and d >= -1 and d <= 1);
}

test "end to end: scene extraction feeds the rasterizer" {
    const TestScene = scene_mod.Scene(.{
        scene_mod.Component(components.Transform, "transform"),
        scene_mod.Component(draw.Renderable, "renderable"),
    });
    var sc = try TestScene.init(testing.allocator, "main");
    defer sc.deinit();
    const e = try sc.createEntity("quad", null);
    try sc.addComponent(e, components.Transform{ .position = .{ 0, 0, 0 } });
    try sc.addComponent(e, draw.Renderable{
        .mesh = 0,
        .material = 0,
        .bounds = @import("culling.zig").Aabb.fromMinMax(.{ -1, -1, -0.1 }, .{ 1, 1, 0.1 }),
    });

    const cam = camera.Camera.perspectiveLookAt(.{ 0, 0, 4 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 0.5, 100);
    var frame = try draw.extractDrawList(&sc, cam, .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 1), frame.count());

    // A unit quad in the XY plane; the fov is 90 degrees at distance 4, so the
    // visible half-extent is 4 and the quad spans a quarter of each axis.
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const meshes = [_]Mesh{.{ .positions = &positions, .indices = &quad_indices }};
    const res = SliceResources{ .meshes = &meshes, .colors = &.{.{ 1, 0, 0, 1 }} };
    var s = try TestSurface.init(16, 16);
    defer s.deinit();
    const stats = try rasterize(&s.target, frame.commands, cam.view_projection, res, .{});
    try testing.expectEqual(@as(usize, 2), stats.submitted);
    try testing.expectEqual(@as(usize, 2), stats.rasterized);
    // Half-extent 1 of a visible 4 maps to 2 pixels of 8 per half-axis: a 4x4 box.
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    try testing.expectEqualSlices(u8, &red, &s.target.colorAt(8, 8));
    try testing.expectEqual(@as(u8, 0), s.target.colorAt(0, 0)[3]);
}

// --- reference vectors ------------------------------------------------------

const vectors = @import("raster_vectors.zig");

test "rasterizer matches the independent reference bit for bit" {
    var s = try TestSurface.init(vectors.width, vectors.height);
    defer s.deinit();
    var total_pixels: usize = 0;
    for (vectors.cases) |case| {
        s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
        const options = Options{
            .cull = switch (case.cull) {
                .none => .none,
                .back => .back,
                .front => .front,
            },
            .front_face = switch (case.front_face) {
                .ccw => .counter_clockwise,
                .cw => .clockwise,
            },
            .depth_test = case.depth_test,
            .depth_write = case.depth_write,
        };
        const tri = [3]ScreenVertex{
            .{ .x = case.tri[0].x, .y = case.tri[0].y, .z = case.tri[0].z },
            .{ .x = case.tri[1].x, .y = case.tri[1].y, .z = case.tri[1].z },
            .{ .x = case.tri[2].x, .y = case.tri[2].y, .z = case.tri[2].z },
        };
        var pixels: usize = 0;
        const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], red, options, &pixels, null, .{ 0.0, 0.0, 0.0 });
        std.testing.expectEqual(case.drew, drew) catch |err| {
            std.debug.print("case {s}: drew mismatch\n", .{case.name});
            return err;
        };

        // Coverage must agree on every pixel, and depths must agree bit for bit.
        var depth_index: usize = 0;
        for (0..s.target.pixelCount()) |i| {
            const want = (case.mask[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
            const got: u8 = @intFromBool(s.target.color[i * 4 + 3] != 0);
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("case {s}: coverage mismatch at pixel {d} ({d},{d})\n", .{
                    case.name, i, i % vectors.width, i / vectors.width,
                });
                return err;
            };
            if (want == 1) {
                const got_bits: u32 = @bitCast(s.depth[i]);
                std.testing.expectEqual(case.depths[depth_index], got_bits) catch |err| {
                    std.debug.print("case {s}: depth mismatch at pixel {d}: want 0x{x:0>8} got 0x{x:0>8}\n", .{
                        case.name, i, case.depths[depth_index], got_bits,
                    });
                    return err;
                };
                depth_index += 1;
            }
        }
        try testing.expectEqual(case.depths.len, depth_index);
        try testing.expectEqual(pixels, depth_index);
        total_pixels += pixels;
    }
    // Guard against the vector file silently becoming empty.
    try testing.expect(vectors.cases.len >= 70);
    try testing.expect(total_pixels >= 800);
}

const texture_vectors = @import("raster_texture_vectors.zig");

test "textureLod: one texel per pixel is level 0, doubling adds one level" {
    // Below or at one texel per pixel there is nothing to filter.
    try testing.expectEqual(@as(f64, 0.0), textureLod(0.0, 0.0, 4));
    try testing.expectEqual(@as(f64, 0.0), textureLod(1.0, 0.5, 4));
    try testing.expectEqual(@as(f64, 0.0), textureLod(0.9, 0.2, 4));
    // Exact powers of two land on level boundaries.
    try testing.expectEqual(@as(f64, 1.0), textureLod(2.0, 2.0, 4));
    try testing.expectEqual(@as(f64, 2.0), textureLod(4.0, 1.0, 4));
    // The larger axis decides, and the result never exceeds the last level.
    try testing.expectEqual(@as(f64, 2.0), textureLod(1.0, 4.0, 4));
    try testing.expectEqual(@as(f64, 3.0), textureLod(64.0, 64.0, 4));
    try testing.expectEqual(@as(f64, 0.0), textureLod(64.0, 64.0, 1));
    // A degenerate gradient (non-finite, or a negative length) selects level 0.
    try testing.expectEqual(@as(f64, 0.0), textureLod(std.math.nan(f64), 1.0, 4));
    try testing.expectEqual(@as(f64, 0.0), textureLod(std.math.inf(f64), 1.0, 4));
    // Between levels it is fractional, so the sampler mixes both.
    const half = textureLod(3.0, 3.0, 4);
    try testing.expect(half > 1.0 and half < 2.0);
}

test "texelGradient: matches the analytic derivative of the perspective mapping" {
    // u = p / den, so du/dx = (dp/dx * den - p * dden/dx) / den^2. Every value
    // here is an exact power of two, so the reciprocal multiply is exact too and
    // the assertion is an identity rather than an approximation.
    const g = texelGradient(0.5, 0.25, 2.0, .{ 0.5, 0.0 }, .{ 0.0, 0.125 }, .{ 0.25, 0.0 }, .{ 4.0, 4.0 });
    // du/dx = (0.5 * 2 - 0.5 * 0.25) / 4 = 0.875 / 4 -> * 4 texels = 0.875
    try testing.expectEqual(@as(f64, 0.875), g.du);
    // dv/dy = (0.125 * 2 - 0.25 * 0) / 4 = 0.25 / 4 -> * 4 texels = 0.25
    try testing.expectEqual(@as(f64, 0.25), g.dv);
    // A zero denominator yields no gradient at all (level 0 downstream).
    const degenerate = texelGradient(0.5, 0.25, 0.0, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 4, 4 });
    try testing.expectEqual(@as(f64, 0.0), degenerate.du);
    try testing.expectEqual(@as(f64, 0.0), degenerate.dv);
}

test "sampleTrilinear: integral levels pick one level, fractional mixes both" {
    // Two levels of a 2x2 texture: level 0 is black/white, level 1 is mid grey.
    const level0 = [_]u8{
        0,   0,   0,   255,
        255, 255, 255, 255,
        255, 255, 255, 255,
        0,   0,   0,   255,
    };
    const level1 = [_]u8{ 128, 128, 128, 255 };
    const mips = [_]MipLevel{.{ .width = 1, .height = 1, .pixels = &level1 }};
    const tex = Texture{ .width = 2, .height = 2, .pixels = &level0, .mips = &mips, .filter = .nearest };
    try tex.validate();
    // (0.1, 0.1) is the black texel; (0.6, 0.1) the white one.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &sampleTrilinear(tex, 0.1, 0.1, 0.0));
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &sampleTrilinear(tex, 0.6, 0.1, 0.0));
    // Halfway to the last level: floor((0 + 128) / 2 + 0.5) = 64.
    try testing.expectEqualSlices(u8, &.{ 64, 64, 64, 255 }, &sampleTrilinear(tex, 0.1, 0.1, 0.5));
    // At or past the last level only that level is fetched.
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, &sampleTrilinear(tex, 0.1, 0.1, 1.0));
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, &sampleTrilinear(tex, 0.1, 0.1, 9.0));
    // Level 0 through the trilinear path is byte-identical to the plain sampler.
    for ([_][2]f64{ .{ 0.1, 0.1 }, .{ 0.6, 0.2 }, .{ 0.9, 0.9 } }) |uv| {
        try testing.expectEqualSlices(u8, &sampleTexture(tex, uv[0], uv[1]), &sampleTrilinear(tex, uv[0], uv[1], 0.0));
    }
}

test "Texture.validate: rejects a mip chain that is not repeated halving" {
    const level0: [4 * 4 * 4]u8 = @splat(0);
    const l2: [2 * 2 * 4]u8 = @splat(0);
    const l1: [1 * 1 * 4]u8 = @splat(0);
    const short: [15]u8 = @splat(0);

    const ok_levels = [_]MipLevel{
        .{ .width = 2, .height = 2, .pixels = &l2 },
        .{ .width = 1, .height = 1, .pixels = &l1 },
    };
    const ok = Texture{ .width = 4, .height = 4, .pixels = &level0, .mips = &ok_levels };
    try ok.validate();
    try testing.expectEqual(@as(u32, 3), ok.mipLevelCount());
    try testing.expectEqual(@as(u32, 4), ok.mipLevel(0).width);
    try testing.expectEqual(@as(u32, 2), ok.mipLevel(1).width);
    try testing.expectEqual(@as(u32, 1), ok.mipLevel(2).width);
    // Out-of-range levels fall back to level 0 instead of reading out of bounds.
    try testing.expectEqual(@as(u32, 4), ok.mipLevel(99).width);

    // Wrong size for level 1.
    const bad_size = [_]MipLevel{.{ .width = 3, .height = 2, .pixels = &l2 }};
    try testing.expectError(error.InvalidTexture, (Texture{ .width = 4, .height = 4, .pixels = &level0, .mips = &bad_size }).validate());
    // Level pixel slice does not match its dimensions.
    const bad_len = [_]MipLevel{.{ .width = 2, .height = 2, .pixels = &short }};
    try testing.expectError(error.InvalidTexture, (Texture{ .width = 4, .height = 4, .pixels = &level0, .mips = &bad_len }).validate());
    // A level after 1x1 can never be reached.
    const after_last = [_]MipLevel{
        .{ .width = 2, .height = 2, .pixels = &l2 },
        .{ .width = 1, .height = 1, .pixels = &l1 },
        .{ .width = 1, .height = 1, .pixels = &l1 },
    };
    try testing.expectError(error.InvalidTexture, (Texture{ .width = 4, .height = 4, .pixels = &level0, .mips = &after_last }).validate());
}

test "drawMesh: mip selection removes minification aliasing" {
    // A 24x24 checker over an 8x8 quad is minified 3:1. Sampling level 0 with
    // nearest turns that into a beating pattern that jumps between 0 and 255 —
    // the classic moire. Level 1 already averages every 2x2 block of a checker
    // to mid grey, so trilinear sampling makes the whole quad uniform.
    var checker: [24 * 24 * 4]u8 = undefined;
    for (0..24) |y| for (0..24) |x| {
        const v: u8 = if ((x + y) % 2 == 0) 0 else 255;
        const o = (y * 24 + x) * 4;
        checker[o] = v;
        checker[o + 1] = v;
        checker[o + 2] = v;
        checker[o + 3] = 255;
    };
    var chain = try mip.Chain.generate(testing.allocator, 24, 24, &checker);
    defer chain.deinit(testing.allocator);
    const tex = Texture{ .width = 24, .height = 24, .pixels = &checker, .filter = .nearest, .mips = chain.levels() };
    try tex.validate();

    const Bounds = struct {
        fn of(target: *Target) [2]u8 {
            var lo: u8 = 255;
            var hi: u8 = 0;
            for (0..8) |y| for (0..8) |x| {
                const p = target.colorAt(@intCast(x), @intCast(y));
                lo = @min(lo, p[0]);
                hi = @max(hi, p[0]);
            };
            return .{ lo, hi };
        }
    };

    var aliased = try TestSurface.init(8, 8);
    defer aliased.deinit();
    _ = try drawMesh(&aliased.target, quadMeshUv(), transform.identity(), orthoSetup(), white, .{ .mipmap = .level0 }, tex);
    const raw = Bounds.of(&aliased.target);
    try testing.expectEqual(@as(u8, 0), raw[0]);
    try testing.expectEqual(@as(u8, 255), raw[1]);

    var smooth = try TestSurface.init(8, 8);
    defer smooth.deinit();
    _ = try drawMesh(&smooth.target, quadMeshUv(), transform.identity(), orthoSetup(), white, .{}, tex);
    const filtered = Bounds.of(&smooth.target);
    // Every pixel of the minified checker averages to the same mid value.
    try testing.expect(filtered[1] - filtered[0] <= 2);
    try testing.expect(filtered[0] > 100 and filtered[1] < 155);
}

test "drawMesh: a texture without mips is bit-identical under every mipmap mode" {
    var plain = try TestSurface.init(8, 8);
    defer plain.deinit();
    var trilinear = try TestSurface.init(8, 8);
    defer trilinear.deinit();
    const tex = Texture{ .width = 2, .height = 2, .pixels = &texel_2x2, .filter = .bilinear };
    _ = try drawMesh(&plain.target, quadMeshUv(), transform.identity(), orthoSetup(), white, .{ .mipmap = .level0 }, tex);
    _ = try drawMesh(&trilinear.target, quadMeshUv(), transform.identity(), orthoSetup(), white, .{ .mipmap = .trilinear }, tex);
    try testing.expectEqualSlices(u8, plain.target.color, trilinear.target.color);
}

test "textured rasterizer matches the independent reference bit for bit" {
    var s = try TestSurface.init(texture_vectors.width, texture_vectors.height);
    defer s.deinit();
    // The generator emits one 4x4 level-0 texture and one 16x16 level-0 texture
    // plus, per mipmapped case, the chain below level 0 it expects to be sampled.
    const checker = Texture{
        .width = 4,
        .height = 4,
        .pixels = &texture_vectors.texture,
        .filter = .nearest, // overridden per case below
    };
    var total_pixels: usize = 0;
    var mip_pixels: usize = 0;
    var aniso_pixels: usize = 0;
    for (texture_vectors.cases) |case| {
        s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
        const options = Options{
            .cull = switch (case.cull) {
                .none => .none,
                .back => .back,
                .front => .front,
            },
            .front_face = switch (case.front_face) {
                .ccw => .counter_clockwise,
                .cw => .clockwise,
            },
            .depth_test = case.depth_test,
            .depth_write = case.depth_write,
            .mipmap = switch (case.mipmap) {
                .level0 => .level0,
                .trilinear => .trilinear,
                .anisotropic => .anisotropic,
            },
            .sampling = .{ .lod_bias = case.lod_bias, .max_samples = case.tap_cap },
        };
        // Copy the case's levels into the sampler's own type (same layout).
        var mip_levels: [8]MipLevel = undefined;
        for (case.levels, 0..) |level, li| {
            mip_levels[li] = .{ .width = level.width, .height = level.height, .pixels = level.pixels };
        }
        const base: MipLevel = if (case.big_base)
            .{ .width = 16, .height = 16, .pixels = &texture_vectors.mip_texture }
        else
            .{ .width = checker.width, .height = checker.height, .pixels = checker.pixels };
        const tex = Texture{
            .width = base.width,
            .height = base.height,
            .pixels = base.pixels,
            .filter = switch (case.filter) {
                .nearest => .nearest,
                .bilinear => .bilinear,
            },
            // The vector file's `Level` has the same layout as `mipmap.Level`;
            // copy it across so the sampler sees its own type.
            .mips = mip_levels[0..case.levels.len],
        };
        // Every case must be a texture the rasterizer would accept.
        try tex.validate();
        const tri = [3]ScreenVertex{
            .{ .x = case.tri[0].x, .y = case.tri[0].y, .z = case.tri[0].z, .uw = case.tri[0].uw, .vw = case.tri[0].vw, .w_inv = case.tri[0].w_inv },
            .{ .x = case.tri[1].x, .y = case.tri[1].y, .z = case.tri[1].z, .uw = case.tri[1].uw, .vw = case.tri[1].vw, .w_inv = case.tri[1].w_inv },
            .{ .x = case.tri[2].x, .y = case.tri[2].y, .z = case.tri[2].z, .uw = case.tri[2].uw, .vw = case.tri[2].vw, .w_inv = case.tri[2].w_inv },
        };
        var pixels: usize = 0;
        const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], case.tint, options, &pixels, tex, .{ 0.0, 0.0, 0.0 });
        std.testing.expectEqual(case.drew, drew) catch |err| {
            std.debug.print("case {s}: drew mismatch\n", .{case.name});
            return err;
        };

        // Coverage agrees bit for bit with the depth buffer (clear depth 1.0,
        // every case writes depth), and the full RGBA frame matches exactly.
        // The mask-via-depth shortcut is valid because every vector case keeps
        // depth_test/depth_write enabled.
        for (0..s.target.pixelCount()) |i| {
            const want = (case.mask[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
            const got: u8 = if (s.depth[i] != 1.0) 1 else 0;
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("case {s}: coverage mismatch at pixel {d} ({d},{d})\n", .{
                    case.name, i, i % texture_vectors.width, i / texture_vectors.width,
                });
                return err;
            };
            for (0..4) |c| {
                const want_byte = case.frame[i * 4 + c];
                const got_byte = s.target.color[i * 4 + c];
                std.testing.expectEqual(want_byte, got_byte) catch |err| {
                    std.debug.print("case {s}: frame mismatch at pixel {d} ({d},{d}) channel {d}: want 0x{x:0>2} got 0x{x:0>2}\n", .{
                        case.name, i, i % texture_vectors.width, i / texture_vectors.width, c, want_byte, got_byte,
                    });
                    return err;
                };
            }
        }
        total_pixels += pixels;
        if (case.levels.len > 0) mip_pixels += pixels;
        if (case.mipmap == .anisotropic) aniso_pixels += pixels;
    }
    // Guard against the vector file silently becoming empty.
    try testing.expect(texture_vectors.cases.len >= 70);
    try testing.expect(total_pixels >= 1000);
    try testing.expect(mip_pixels >= 500);
    try testing.expect(texture_vectors.cases.len >= 116);
    try testing.expect(aniso_pixels >= 500);
}

// --- texture-specific unit tests --------------------------------------------

/// The 2x2 texture both unit tests and fixtures share. Texel order is
/// row-major, top-down: (0,0) red, (1,0) green, (0,1) blue, (1,1) yellow.
const texel_2x2 = [_]u8{
    255, 0,   0,   255,
    0,   255, 0,   255,
    0,   0,   255, 255,
    255, 255, 0,   255,
};

const four_positions = [_][3]f32{
    .{ -2, -2, -2 }, .{ 2, -2, -2 }, .{ 2, 2, -2 }, .{ -2, 2, -2 },
};
const four_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
const four_uvs = [_][2]f32{
    .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 },
};

fn quadMeshUv() Mesh {
    return .{ .positions = &four_positions, .indices = &four_indices, .uvs = &four_uvs };
}

const SliceTexturedResources = struct {
    meshes: []const Mesh,
    colors: []const [4]f32,
    textures: []const Texture,

    pub fn mesh(self: SliceTexturedResources, handle: u32) ?Mesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: SliceTexturedResources, handle: u32) ?[4]f32 {
        if (handle >= self.colors.len) return null;
        return self.colors[handle];
    }

    pub fn texture(self: SliceTexturedResources, handle: u32) ?Texture {
        if (handle >= self.textures.len) return null;
        return self.textures[handle];
    }
};

test "Texture.validate: rejects malformed textures, accepts a valid one" {
    var short = Texture{ .width = 2, .height = 2, .pixels = texel_2x2[0..15], .filter = .nearest };
    try testing.expectError(error.InvalidTexture, short.validate());
    var zero = Texture{ .width = 0, .height = 2, .pixels = &texel_2x2, .filter = .nearest };
    try testing.expectError(error.InvalidTexture, zero.validate());
    var wide = Texture{ .width = max_dimension + 1, .height = 1, .pixels = texel_2x2[0..0], .filter = .nearest };
    try testing.expectError(error.InvalidTexture, wide.validate());
    var ok = Texture{ .width = 2, .height = 2, .pixels = &texel_2x2, .filter = .bilinear };
    try ok.validate();
}

test "drawMesh: a texture without uvs is a hard error, target untouched" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const tex = Texture{ .width = 2, .height = 2, .pixels = &texel_2x2, .filter = .nearest };
    try testing.expectError(error.InvalidUv, drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{}, tex));
    try testing.expectEqual(@as(usize, 0), s.covered());
    for (s.depth) |d| try testing.expectEqual(@as(f32, 1.0), d);
}

test "drawMesh: a uv buffer shorter than positions is a hard error" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 } };
    const mesh = Mesh{ .positions = &four_positions, .indices = &four_indices, .uvs = &uvs };
    const tex = Texture{ .width = 2, .height = 2, .pixels = &texel_2x2, .filter = .nearest };
    try testing.expectError(error.InvalidUv, drawMesh(&s.target, mesh, transform.identity(), orthoSetup(), red, .{}, tex));
    try testing.expectEqual(@as(usize, 0), s.covered());
}

test "drawMesh: an all-red textured quad draws red, not the flat tint" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const all_red = [_]u8{ 255, 0, 0, 255 };
    const tex = Texture{ .width = 1, .height = 1, .pixels = &all_red, .filter = .nearest };
    const stats = try drawMesh(&s.target, quadMeshUv(), transform.identity(), orthoSetup(), white, .{}, tex);
    try testing.expectEqual(@as(usize, 64), stats.pixels);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

test "drawMesh: the material tint multiplies the sampled texel" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const all_red = [_]u8{ 255, 0, 0, 255 };
    const tex = Texture{ .width = 1, .height = 1, .pixels = &all_red, .filter = .nearest };
    const gray = [4]u8{ 128, 128, 128, 255 };
    _ = try drawMesh(&s.target, quadMeshUv(), transform.identity(), orthoSetup(), gray, .{}, tex);
    // floor(255 * 128 / 255 + 0.5) = 128, floor(0 * 128 / 255 + 0.5) = 0.
    try testing.expectEqualSlices(u8, &.{ 128, 0, 0, 255 }, &s.target.colorAt(4, 4));
    // A half-alpha tint leaves the alpha at floor(255 * 128 / 255 + 0.5) = 128.
    s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
    const half = [4]u8{ 255, 255, 255, 128 };
    _ = try drawMesh(&s.target, quadMeshUv(), transform.identity(), orthoSetup(), half, .{}, tex);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, &s.target.colorAt(4, 4));
}

test "drawMesh: a degenerate w gradient falls back to uv (0,0)" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // Every vertex carries w_inv = 0, so den == 0 and the shader must clamp
    // the sample to texel (0,0) instead of dividing by zero.
    const tri = [3]ScreenVertex{
        .{ .x = 0, .y = 0, .z = 0, .uw = 0, .vw = 0, .w_inv = 0 },
        .{ .x = 8 * 16, .y = 0, .z = 0, .uw = 1, .vw = 0, .w_inv = 0 },
        .{ .x = 0, .y = 8 * 16, .z = 0, .uw = 0, .vw = 1, .w_inv = 0 },
    };
    const tex = Texture{ .width = 2, .height = 2, .pixels = &texel_2x2, .filter = .nearest };
    _ = rasterTriangle(&s.target, tri[0], tri[1], tri[2], red, .{ .cull = .none }, null, tex, .{ 0.0, 0.0, 0.0 });
    // texel (0,0) is pure red.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(1, 1));
}

test "drawMesh: mesh uvs are ignored when the texture is null" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const stats = try drawMesh(&s.target, quadMeshUv(), transform.identity(), orthoSetup(), green, .{}, null);
    try testing.expectEqual(@as(usize, 64), stats.pixels);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &s.target.colorAt(4, 4));
}

test "rasterize: material resolving a texture renders; uv-less mesh is skipped" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const tex = Texture{ .width = 1, .height = 1, .pixels = &[_]u8{ 255, 0, 0, 255 }, .filter = .nearest };
    const flat_mesh = quadMeshUv();
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    // A mesh without uvs is skipped (non-fatal), the target stays untouched.
    const plain = [_]Mesh{quadMesh()};
    const res = SliceTexturedResources{ .meshes = &plain, .colors = &colors, .textures = &.{tex} };
    const stats = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 1), stats.skipped_draws);
    try testing.expectEqual(@as(usize, 0), stats.pixels);
    try testing.expectEqual(@as(usize, 0), s.covered());
    // Same material, uvs present: renders red.
    const textured = [_]Mesh{flat_mesh};
    const res2 = SliceTexturedResources{ .meshes = &textured, .colors = &colors, .textures = &.{tex} };
    const stats2 = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res2, .{});
    try testing.expectEqual(@as(usize, 0), stats2.skipped_draws);
    try testing.expectEqual(@as(usize, 16), stats2.pixels);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(2, 2));
}

test "rasterize: a malformed texture is a hard error, not a skip" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const bad = Texture{ .width = 2, .height = 2, .pixels = texel_2x2[0..3], .filter = .nearest };
    const meshes = [_]Mesh{quadMeshUv()};
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    const res = SliceTexturedResources{ .meshes = &meshes, .colors = &colors, .textures = &.{bad} };
    try testing.expectError(error.InvalidTexture, rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{}));
}

test "rasterize: material without texture shades flat (backward compatibility)" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMeshUv()};
    const colors = [_][4]f32{.{ 0.0, 1.0, 0.0, 1.0 }};
    // No texture entry for this handle: flat shading, uvs ignored.
    const res = SliceTexturedResources{ .meshes = &meshes, .colors = &colors, .textures = &.{} };
    const stats = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &s.target.colorAt(2, 2));
}

const light_vectors = @import("raster_light_vectors.zig");

test "lit rasterizer matches the independent reference bit for bit" {
    var s = try TestSurface.init(light_vectors.width, light_vectors.height);
    defer s.deinit();
    const checker = Texture{
        .width = 4,
        .height = 4,
        .pixels = &light_vectors.texture,
        .filter = .nearest, // overridden per case below
    };
    var total_pixels: usize = 0;
    for (light_vectors.cases) |case| {
        s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
        const options = Options{
            .cull = switch (case.cull) {
                .none => .none,
                .back => .back,
                .front => .front,
            },
            .front_face = switch (case.front_face) {
                .ccw => .counter_clockwise,
                .cw => .clockwise,
            },
            .depth_test = case.depth_test,
            .depth_write = case.depth_write,
            .light = if (case.light) |l| .{ .direction = l.direction, .color = l.color, .ambient = l.ambient } else null,
        };
        var texture: ?Texture = null;
        if (case.use_texture) {
            texture = Texture{
                .width = checker.width,
                .height = checker.height,
                .pixels = checker.pixels,
                .filter = switch (case.filter) {
                    .nearest => .nearest,
                    .bilinear => .bilinear,
                },
            };
        }
        const tri = [3]ScreenVertex{
            .{ .x = case.tri[0].x, .y = case.tri[0].y, .z = case.tri[0].z, .uw = case.tri[0].uw, .vw = case.tri[0].vw, .w_inv = case.tri[0].w_inv },
            .{ .x = case.tri[1].x, .y = case.tri[1].y, .z = case.tri[1].z, .uw = case.tri[1].uw, .vw = case.tri[1].vw, .w_inv = case.tri[1].w_inv },
            .{ .x = case.tri[2].x, .y = case.tri[2].y, .z = case.tri[2].z, .uw = case.tri[2].uw, .vw = case.tri[2].vw, .w_inv = case.tri[2].w_inv },
        };
        var pixels: usize = 0;
        const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], case.tint, options, &pixels, texture, case.world_normal);
        std.testing.expectEqual(case.drew, drew) catch |err| {
            std.debug.print("case {s}: drew mismatch\n", .{case.name});
            return err;
        };

        // Coverage via depth (clear depth 1.0; every case keeps depth_write),
        // then the full RGBA frame must match bit for bit.
        for (0..s.target.pixelCount()) |i| {
            const want = (case.mask[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
            const got: u8 = if (s.depth[i] != 1.0) 1 else 0;
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("case {s}: coverage mismatch at pixel {d} ({d},{d})\n", .{
                    case.name, i, i % light_vectors.width, i / light_vectors.width,
                });
                return err;
            };
            for (0..4) |c| {
                const want_byte = case.frame[i * 4 + c];
                const got_byte = s.target.color[i * 4 + c];
                std.testing.expectEqual(want_byte, got_byte) catch |err| {
                    std.debug.print("case {s}: frame mismatch at pixel {d} ({d},{d}) channel {d}: want 0x{x:0>2} got 0x{x:0>2}\n", .{
                        case.name, i, i % light_vectors.width, i / light_vectors.width, c, want_byte, got_byte,
                    });
                    return err;
                };
            }
        }
        total_pixels += pixels;
    }
    // Guard against the vector file silently becoming empty.
    try testing.expect(light_vectors.cases.len >= 35);
    try testing.expect(total_pixels >= 600);
}

const blend_vectors = @import("raster_blend_vectors.zig");
const alloc_probe = @import("../core/alloc_probe.zig");

test "blended rasterizer matches the independent reference bit for bit" {
    var s = try TestSurface.init(blend_vectors.width, blend_vectors.height);
    defer s.deinit();
    var total_pixels: usize = 0;
    var blended_cases: usize = 0;
    for (blend_vectors.cases) |case| {
        s.target.clear(case.clear, 1.0);
        const options = Options{
            .cull = switch (case.cull) {
                .none => .none,
                .back => .back,
                .front => .front,
            },
            .front_face = switch (case.front_face) {
                .ccw => .counter_clockwise,
                .cw => .clockwise,
            },
            .light = if (case.light) |l| .{ .direction = l.direction, .color = l.color, .ambient = l.ambient } else null,
            .blend = switch (case.blend) {
                .none => .none,
                .alpha => .alpha,
                .premultiplied => .premultiplied,
                .additive => .additive,
            },
        };
        var texture: ?Texture = null;
        if (case.use_texture) {
            texture = Texture{
                .width = blend_vectors.width / 2,
                .height = blend_vectors.height / 2,
                .pixels = &blend_vectors.texture,
                .filter = switch (case.filter) {
                    .nearest => .nearest,
                    .bilinear => .bilinear,
                },
            };
        }
        const tri = [3]ScreenVertex{
            .{ .x = case.tri[0].x, .y = case.tri[0].y, .z = case.tri[0].z, .uw = case.tri[0].uw, .vw = case.tri[0].vw, .w_inv = case.tri[0].w_inv },
            .{ .x = case.tri[1].x, .y = case.tri[1].y, .z = case.tri[1].z, .uw = case.tri[1].uw, .vw = case.tri[1].vw, .w_inv = case.tri[1].w_inv },
            .{ .x = case.tri[2].x, .y = case.tri[2].y, .z = case.tri[2].z, .uw = case.tri[2].uw, .vw = case.tri[2].vw, .w_inv = case.tri[2].w_inv },
        };
        var pixels: usize = 0;
        const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], case.tint, options, &pixels, texture, case.world_normal);
        std.testing.expectEqual(case.drew, drew) catch |err| {
            std.debug.print("case {s}: drew mismatch\n", .{case.name});
            return err;
        };

        // Coverage via depth (clear depth 1.0; every case keeps depth_write),
        // then the full composited RGBA frame must match bit for bit.
        for (0..s.target.pixelCount()) |i| {
            const want = (case.mask[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
            const got: u8 = if (s.depth[i] != 1.0) 1 else 0;
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("case {s}: coverage mismatch at pixel {d} ({d},{d})\n", .{
                    case.name, i, i % blend_vectors.width, i / blend_vectors.width,
                });
                return err;
            };
            for (0..4) |c| {
                const want_byte = case.frame[i * 4 + c];
                const got_byte = s.target.color[i * 4 + c];
                std.testing.expectEqual(want_byte, got_byte) catch |err| {
                    std.debug.print("case {s}: frame mismatch at pixel {d} ({d},{d}) channel {d}: want 0x{x:0>2} got 0x{x:0>2}\n", .{
                        case.name, i, i % blend_vectors.width, i / blend_vectors.width, c, want_byte, got_byte,
                    });
                    return err;
                };
            }
        }
        total_pixels += pixels;
        if (case.blend != .none) blended_cases += 1;
    }
    // Guard against the vector file silently becoming empty.
    try testing.expect(blend_vectors.cases.len >= 45);
    try testing.expect(blended_cases >= 40);
    try testing.expect(total_pixels >= 750);
}

// --- blending unit tests -----------------------------------------------------

test "blendPixels: source-over math per mode" {
    // Half-transparent red over opaque blue.
    const src = [4]u8{ 255, 0, 0, 128 };
    const dst = [4]u8{ 0, 0, 255, 255 };
    // alpha: sa = 128/255, keep = 127/255; rgb = (255*sa)/1 -> 128, blue -> 127.
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, &blendPixels(src, dst, .alpha));
    // premultiplied: src*sa + dst*keep -> (128, 0, 127), the same numbers as
    // alpha here because the destination is fully opaque (da == 1).
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, &blendPixels(src, dst, .premultiplied));
    // additive: dst + src*sa -> (128, 0, 255).
    try testing.expectEqualSlices(u8, &.{ 128, 0, 255, 255 }, &blendPixels(src, dst, .additive));
    // `none` ignores the destination entirely.
    try testing.expectEqualSlices(u8, &src, &blendPixels(src, dst, .none));
}

test "blendPixels: degenerate alphas stay finite" {
    // Fully transparent source: every mode leaves dst intact (no division by
    // zero in `alpha`, and a premultiplied fragment of zero alpha adds nothing
    // now that the source is premultiplied at blend time).
    const transparent = [4]u8{ 200, 100, 50, 0 };
    const dst = [4]u8{ 10, 20, 30, 128 };
    try testing.expectEqualSlices(u8, &dst, &blendPixels(transparent, dst, .alpha));
    try testing.expectEqualSlices(u8, &dst, &blendPixels(transparent, dst, .premultiplied));
    try testing.expectEqualSlices(u8, &dst, &blendPixels(transparent, dst, .additive));

    // Fully transparent source over a fully transparent destination: the
    // straight-alpha divide is skipped and the result is transparent black.
    const clear = [4]u8{ 0, 0, 0, 0 };
    try testing.expectEqualSlices(u8, &clear, &blendPixels(transparent, clear, .alpha));
    // Opaque source over a transparent destination is the source itself.
    const solid = [4]u8{ 9, 8, 7, 255 };
    try testing.expectEqualSlices(u8, &solid, &blendPixels(solid, clear, .alpha));
}

test "blendPixels: additive saturates and alpha composites" {
    const src = [4]u8{ 200, 100, 60, 255 };
    const dst = [4]u8{ 200, 20, 30, 200 };
    // sa = 1, so additive adds the full source: 400 -> 255, 120, 90.
    try testing.expectEqualSlices(u8, &.{ 255, 120, 90, 255 }, &blendPixels(src, dst, .additive));
    // Alpha accumulates to full coverage even when the destination was partial.
    const half = [4]u8{ 10, 10, 10, 128 };
    const got = blendPixels(half, half, .premultiplied);
    // out.a = 128/255 + (128/255)*(127/255) -> 0.7529 -> 192, and the RGB is
    // the premultiplied sum (10/255)*sa + (10/255)*keep = 0.0392 -> 10.
    try testing.expectEqual(@as(u8, 192), got[3]);
    try testing.expectEqual(@as(u8, 10), got[0]);
}

test "blend defaults to none and reproduces the unblended path exactly" {
    var blended = try TestSurface.init(8, 8);
    defer blended.deinit();
    var plain = try TestSurface.init(8, 8);
    defer plain.deinit();
    // A transparent tint still writes verbatim in the default mode.
    blended.target.clear(.{ 3, 4, 5, 6 }, 1.0);
    plain.target.clear(.{ 3, 4, 5, 6 }, 1.0);
    const tint = [4]u8{ 200, 130, 40, 77 };
    const a = try drawMesh(&blended.target, quadMesh(), transform.identity(), orthoSetup(), tint, .{}, null);
    const b = try drawMesh(&plain.target, quadMesh(), transform.identity(), orthoSetup(), tint, .{ .blend = .none }, null);
    try testing.expectEqual(a.pixels, b.pixels);
    try testing.expectEqualSlices(u8, plain.target.color, blended.target.color);
    for (blended.depth, plain.depth) |x, y| try testing.expectEqual(x, y);
}

test "alpha blending composites in submission order over a cleared target" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
    const base = [4]u8{ 0, 0, 255, 255 };
    const over = [4]u8{ 255, 0, 0, 128 };
    const flat = quadMesh();
    // depth_write off: both draws must reach the same pixels regardless of depth.
    _ = try drawMesh(&s.target, flat, transform.identity(), orthoSetup(), base, .{ .depth_write = false }, null);
    _ = try drawMesh(&s.target, flat, transform.identity(), orthoSetup(), over, .{ .depth_write = false, .blend = .alpha }, null);
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, &s.target.colorAt(1, 1));
}

test "rasterize applies the blend mode to every command" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    s.target.clear(.{ 0, 0, 255, 255 }, 1.0);
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 0.0, 0.0, 0.5 }};
    const res = SliceResources{ .meshes = &meshes, .colors = &colors };
    const stats = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{ .blend = .alpha, .depth_write = false });
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    // 0.5 * 255 = 127.5 -> round to 128 alpha; source-over over opaque blue.
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, &s.target.colorAt(0, 0));
}

// --- lighting unit tests ------------------------------------------------------

test "Light.validate: rejects malformed lights, accepts valid ones" {
    var ok = Light{ .direction = .{ 0, 0, 1 } };
    try ok.validate();
    var zero = Light{ .direction = .{ 0, 0, 0 } };
    try testing.expectError(error.InvalidLight, zero.validate());
    var nan = Light{ .direction = .{ 0.0, std.math.nan(f32), 0 } };
    try testing.expectError(error.InvalidLight, nan.validate());
    var inf = Light{ .direction = .{ 0.0, std.math.inf(f32), 0 } };
    try testing.expectError(error.InvalidLight, inf.validate());
    var neg = Light{ .direction = .{ 0, 1, 0 }, .color = .{ 0.5, -0.1, 0.5 } };
    try testing.expectError(error.InvalidLight, neg.validate());
    var negamb = Light{ .direction = .{ 0, 1, 0 }, .ambient = .{ 0.1, 0.1, -0.2 } };
    try testing.expectError(error.InvalidLight, negamb.validate());
    var nanamb = Light{ .direction = .{ 0, 1, 0 }, .ambient = .{ std.math.nan(f32), 0.1, 0.1 } };
    try testing.expectError(error.InvalidLight, nanamb.validate());
    // HDR multipliers are legal; they clamp at quantization.
    var hdr = Light{ .direction = .{ 0, 1, 0 }, .color = .{ 4.0, 4.0, 4.0 }, .ambient = .{ 2.0, 2.0, 2.0 } };
    try hdr.validate();
}

test "drawMesh: an invalid light fails before any draw" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const lit = Light{ .direction = .{ 0, 0, 0 } };
    try testing.expectError(error.InvalidLight, drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .light = lit }, null));
    try testing.expectEqual(@as(usize, 0), s.covered());
    for (s.depth) |d| try testing.expectEqual(@as(f32, 1.0), d);
}

test "drawMesh: a quad facing the light keeps the tint exactly" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // quad_positions wind to a +z face normal; light straight at it, dot = 1.
    const lit = Light{ .direction = .{ 0, 0, 1 }, .color = .{ 1.0, 1.0, 1.0 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    _ = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .light = lit }, null);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

test "drawMesh: a perpendicular light leaves only the ambient term" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // dot == 0 exactly: black with zero ambient.
    const black = Light{ .direction = .{ 1, 0, 0 }, .color = .{ 1.0, 1.0, 1.0 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    _ = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .light = black }, null);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &s.target.colorAt(4, 4));
    // Non-trivial ambient: floor(255 * 0.25 + 0.5) = 64 on green, 255*.75=191+ rounds... just pin computed values.
    s.target.clear(.{ 0, 0, 0, 0 }, 1.0);
    const amb = Light{ .direction = .{ 1, 0, 0 }, .color = .{ 1.0, 1.0, 1.0 }, .ambient = .{ 0.25, 0.5, 0.75 } };
    _ = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .light = amb }, null);
    try testing.expectEqualSlices(u8, &.{ 64, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

test "drawMesh: a face pointing away from the light is lit ambient-only" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // Reversed winding => the face normal points to -z (faceNormal cross).
    const flipped_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
    const flipped = Mesh{ .positions = &quad_positions, .indices = &flipped_indices };
    const lit = Light{ .direction = .{ 0, 0, 1 }, .color = .{ 1.0, 1.0, 1.0 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    // Screen winding flips too, so opt out of culling; this pins the world-space
    // normal chain (worldPoint -> faceNormal) rather than the cull stage.
    _ = try drawMesh(&s.target, flipped, transform.identity(), orthoSetup(), red, .{ .light = lit, .cull = .none }, null);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

test "drawMesh: a translation does not bend the face normal" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    // Translated quad, normal stays (0,0,1); perspective-free ortho path.
    var world = transform.identity();
    world[12] = 1.0;
    world[13] = 1.0;
    const lit = Light{ .direction = .{ 0, 0, 1 }, .color = .{ 1.0, 1.0, 1.0 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    _ = try drawMesh(&s.target, quadMesh(), world, orthoSetup(), red, .{ .light = lit }, null);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

test "drawMesh: lit texture multiplies albedo through the multiplier" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const all_white = [_]u8{ 255, 255, 255, 255 };
    const tex = Texture{ .width = 1, .height = 1, .pixels = &all_white, .filter = .nearest };
    // Half-gray light straight at the face: red tint * white texel * 0.5.
    const lit = Light{ .direction = .{ 0, 0, 1 }, .color = .{ 0.5, 0.5, 0.5 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    _ = try drawMesh(&s.target, quadMeshUv(), transform.identity(), orthoSetup(), red, .{ .light = lit }, tex);
    try testing.expectEqualSlices(u8, &.{ 128, 0, 0, 255 }, &s.target.colorAt(4, 4));
}

const SliceLitResources = struct {
    meshes: []const Mesh,
    colors: []const [4]f32,
    light: ?Light,

    pub fn mesh(self: SliceLitResources, handle: u32) ?Mesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: SliceLitResources, handle: u32) ?[4]f32 {
        if (handle >= self.colors.len) return null;
        return self.colors[handle];
    }

    pub fn directionalLight(self: SliceLitResources) ?Light {
        return self.light;
    }
};

test "rasterize: the provider's directionalLight shades the draw" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    // Provider supplies a red half light with zero ambient: white tint * 0.5R.
    const res = SliceLitResources{
        .meshes = &meshes,
        .colors = &colors,
        .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 0.5, 0.0, 0.0 }, .ambient = .{ 0.0, 0.0, 0.0 } },
    };
    const stats = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqual(@as(usize, 16), stats.pixels);
    try testing.expectEqualSlices(u8, &.{ 128, 0, 0, 255 }, &s.target.colorAt(2, 2));
}

test "rasterize: an explicit options.light wins over the provider's" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    const res = SliceLitResources{
        .meshes = &meshes,
        .colors = &colors,
        .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 0.5, 0.0, 0.0 }, .ambient = .{ 0.0, 0.0, 0.0 } },
    };
    // Explicit green-only light from the caller beats the provider's red one.
    const explicit = Light{ .direction = .{ 0, 0, 1 }, .color = .{ 0.0, 0.5, 0.0 }, .ambient = .{ 0.0, 0.0, 0.0 } };
    _ = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{ .light = explicit });
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255 }, &s.target.colorAt(2, 2));
}

test "rasterize: a provider with null light keeps the flat path" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    const res = SliceLitResources{ .meshes = &meshes, .colors = &colors, .light = null };
    _ = try rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{});
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &s.target.colorAt(2, 2));
}

test "rasterize: a provider returning an invalid light is a hard error" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const meshes = [_]Mesh{quadMesh()};
    const colors = [_][4]f32{.{ 1.0, 1.0, 1.0, 1.0 }};
    const res = SliceLitResources{
        .meshes = &meshes,
        .colors = &colors,
        .light = .{ .direction = .{ 0.0, 0.0, 0.0 } },
    };
    try testing.expectError(error.InvalidLight, rasterize(&s.target, &.{command(0, 0)}, orthoSetup(), res, .{}));
}

// --- antialiasing tests ------------------------------------------------------

test "coverageCount: the two triangles of a quad partition every pixel exactly" {
    // The property that makes antialiasing seam-free: for two triangles sharing an
    // edge, the sub-samples of every pixel are partitioned by the same top-left rule
    // the pixel-center test uses, so their coverage always adds up to the full grid.
    // A pixel of the quad is either fully owned (16 + 0, or 8 + 8) or not at all.
    const p0 = [2]i32{ 0, 0 };
    const p1 = [2]i32{ 4 * subpixel_scale, 0 };
    const p2 = [2]i32{ 4 * subpixel_scale, 4 * subpixel_scale };
    const p3 = [2]i32{ 0, 4 * subpixel_scale };

    for (0..4) |py| for (0..4) |px| {
        const cx: i32 = @intCast(px * subpixel_scale + subpixel_scale / 2);
        const cy: i32 = @intCast(py * subpixel_scale + subpixel_scale / 2);
        var sum: u16 = 0;
        // Triangle list (0,1,2) and (0,2,3), exactly like `quadMesh`.
        inline for ([_][3][2]i32{
            .{ p0, p1, p2 },
            .{ p0, p2, p3 },
        }) |tri| {
            const a = ScreenVertex{ .x = tri[0][0], .y = tri[0][1], .z = 0 };
            const b = ScreenVertex{ .x = tri[1][0], .y = tri[1][1], .z = 0 };
            const c = ScreenVertex{ .x = tri[2][0], .y = tri[2][1], .z = 0 };
            // Wind to positive area exactly like the rasterizer: it keeps `b, c`
            // when the signed area is already positive and swaps them otherwise.
            const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
            const s1 = if (area < 0) c else b;
            const s2 = if (area < 0) b else c;
            // Same edge order the rasterizer uses for the step table: edges
            // (s1,s2), (s2,a), (a,s1) with the matching `isTopLeft` biases.
            const steps = EdgeSteps.fromScreen(a, s1, s2);
            const bias: [3]i64 = .{
                if (isTopLeft(s1.x, s1.y, s2.x, s2.y)) 0 else 1,
                if (isTopLeft(s2.x, s2.y, a.x, a.y)) 0 else 1,
                if (isTopLeft(a.x, a.y, s1.x, s1.y)) 0 else 1,
            };
            sum += coverageCount(aa_grid, .{
                edge(s1.x, s1.y, s2.x, s2.y, cx, cy),
                edge(s2.x, s2.y, a.x, a.y, cx, cy),
                edge(a.x, a.y, s1.x, s1.y, cx, cy),
            }, steps, bias);
        }
        try testing.expectEqual(aa_samples, sum);
    };
}

test "coverageCount: stepping agrees with evaluating every sub-sample from scratch" {
    // `coverageCount` reaches sub-samples through the per-unit step table
    // (`EdgeSteps`), while the pixel-center edge functions come from the pixel
    // loop. Pinning it against a from-scratch evaluation at the absolute sub-sample
    // position validates the steps themselves, not just their self-consistency.
    const a = ScreenVertex{ .x = 3 * subpixel_scale, .y = 1 * subpixel_scale, .z = 0 };
    const b = ScreenVertex{ .x = 11 * subpixel_scale + 7, .y = 4 * subpixel_scale + 3, .z = 0 };
    const c = ScreenVertex{ .x = 5 * subpixel_scale + 9, .y = 12 * subpixel_scale + 5, .z = 0 };

    const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
    const s1 = if (area < 0) c else b;
    const s2 = if (area < 0) b else c;
    const steps = EdgeSteps.fromScreen(a, s1, s2);
    const bias: [3]i64 = .{
        if (isTopLeft(s1.x, s1.y, s2.x, s2.y)) 0 else 1,
        if (isTopLeft(s2.x, s2.y, a.x, a.y)) 0 else 1,
        if (isTopLeft(a.x, a.y, s1.x, s1.y)) 0 else 1,
    };

    // Every pixel of the triangle's bounding box, including the ones it misses.
    for (1..12) |py| for (3..12) |px| {
        const cx: i32 = @intCast(px * subpixel_scale + subpixel_scale / 2);
        const cy: i32 = @intCast(py * subpixel_scale + subpixel_scale / 2);
        const fast = coverageCount(aa_grid, .{
            edge(s1.x, s1.y, s2.x, s2.y, cx, cy),
            edge(s2.x, s2.y, a.x, a.y, cx, cy),
            edge(a.x, a.y, s1.x, s1.y, cx, cy),
        }, steps, bias);

        var brute: u16 = 0;
        for (0..aa_grid) |j| for (0..aa_grid) |i| {
            const sx: i32 = cx - subpixel_scale / 2 + aaSampleOffset(aa_grid, @intCast(i));
            const sy: i32 = cy - subpixel_scale / 2 + aaSampleOffset(aa_grid, @intCast(j));
            if (onEdge(edge(s1.x, s1.y, s2.x, s2.y, sx, sy), bias[0]) and
                onEdge(edge(s2.x, s2.y, a.x, a.y, sx, sy), bias[1]) and
                onEdge(edge(a.x, a.y, s1.x, s1.y, sx, sy), bias[2])) brute += 1;
        };
        try testing.expectEqual(brute, fast);
    };
}

test "antialias: a failed scratch allocation fails the draw before any write" {
    // `drawMeshAlloc` sizes its scratch from the draw's reach, so every allocation
    // site is reachable. A failure must surface as `OutOfMemory` and leave the
    // target exactly as it was cleared — never half-rendered — while the run that
    // gets all its memory must produce real pixels.
    const Probe = struct {
        fn run(gpa: Allocator, color: []u8, depth: []f32) !void {
            var target = try Target.init(16, 16, color, depth);
            target.clear(.{ 0, 0, 0, 0 }, 1.0);
            const stats = drawMeshAlloc(gpa, &target, aaQuadMesh(), transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null) catch |err| {
                for (target.color) |byte| try testing.expectEqual(@as(u8, 0), byte);
                return err;
            };
            try testing.expect(stats.pixels > 0);
        }
    };
    var color: [16 * 16 * 4]u8 = undefined;
    var depth: [16 * 16]f32 = undefined;
    try alloc_probe.check(Probe.run, .{ &color, &depth });
}

test "aaScratchBytes: exact footprint and full-target fallback" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const mvp = transform.multiply(orthoSetup(), transform.identity());
    const footprint = aaScratchBytes(&s.target, quadMesh(), mvp);
    // quadMesh fits the whole 8x8 view, and a reach smaller than that is fine
    // too — both results are exact multiples of the per-pixel footprint and the
    // function must agree with the scratch sizing below.
    const per_pixel = @sizeOf(AccSlot) + @sizeOf(u32);
    try testing.expectEqual(@as(usize, 0), footprint % per_pixel);
    const expected = std.math.mul(usize, 8 * 8, per_pixel) catch unreachable;
    try testing.expect(footprint <= expected);
    // Degenerate reach (no positions) reports the whole target, exactly as the
    // scratch sizing does.
    const empty_mesh = Mesh{ .positions = &.{}, .indices = &.{} };
    try testing.expectEqual(expected, aaScratchBytes(&s.target, empty_mesh, mvp));
}

test "antialias: a small .edge draw is never downgraded" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const stats = try drawMeshAlloc(testing.allocator, &s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);
    try testing.expect(!stats.antialias_downgraded);
    try testing.expect(max_aa_scratch_bytes >= 64 * 1024 * 1024);
}

test "antialias: a grid-aligned quad is unchanged and writes depth" {
    var plain = try TestSurface.init(8, 8);
    defer plain.deinit();
    var smooth = try TestSurface.init(8, 8);
    defer smooth.deinit();
    const plain_stats = try drawMesh(&plain.target, quadMesh(), transform.identity(), orthoSetup(), red, .{}, null);
    const smooth_stats = try drawMeshAlloc(testing.allocator, &smooth.target, quadMesh(), transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);
    // Every pixel of a viewport-filling quad is fully covered: identical output,
    // identical depth, and nothing was counted as partial.
    try testing.expectEqualSlices(u8, plain.target.color, smooth.target.color);
    for (plain.target.depth, smooth.target.depth) |x, y| try testing.expectEqual(x, y);
    try testing.expectEqual(plain_stats.pixels, smooth_stats.pixels);
    try testing.expectEqual(@as(usize, 0), smooth_stats.antialiased_pixels);
}

/// A triangle that covers the whole viewport and beyond: its vertices project far
/// outside the target, so the pixel box is clamped on all four sides.
const oversize_positions = [_][3]f32{
    .{ -40, -40, -2 }, .{ 40, -40, -2 }, .{ 0, 40, -2 },
};

test "antialias: a triangle far larger than the target rasterizes without overflow" {
    // Regression: the pixel box was clamped *before* the fixed-point to pixel
    // shift, which can produce a negative index; the antialiasing halo then
    // widened it by one more and the i32 subtraction that computes the box shift
    // (`clip_min - min`) overflowed — a panic in Debug/ReleaseSafe on any
    // oversized triangle with `antialias = .edge`. Both paths now clamp to the
    // target after the shift and share the same four clamps.
    var plain = try TestSurface.init(8, 8);
    defer plain.deinit();
    var smooth = try TestSurface.init(8, 8);
    defer smooth.deinit();
    const tri_indices = [_]u32{ 0, 1, 2 };
    const mesh = Mesh{ .positions = &oversize_positions, .indices = &tri_indices };
    const plain_stats = try drawMesh(&plain.target, mesh, transform.identity(), orthoSetup(), red, .{}, null);
    const smooth_stats = try drawMeshAlloc(testing.allocator, &smooth.target, mesh, transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);
    // The triangle covers every pixel, so both paths agree exactly.
    try testing.expectEqual(@as(usize, 64), plain_stats.pixels);
    try testing.expectEqualSlices(u8, plain.target.color, smooth.target.color);
    try testing.expectEqual(plain_stats.pixels, smooth_stats.pixels);

    // The same triangle shifted so that one vertex lands left of and above the
    // target: `min` clamps to 0 while the triangle's own extent stays negative.
    const shifted = [_][3]f32{
        .{ -40, 40, -2 }, .{ 1.2, 1.2, -2 }, .{ 1.4, 1.9, -2 },
    };
    const mesh2 = Mesh{ .positions = &shifted, .indices = &tri_indices };
    var out = try TestSurface.init(8, 8);
    defer out.deinit();
    _ = try drawMeshAlloc(testing.allocator, &out.target, mesh2, transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);
}

/// A quad with no axis-aligned edge in screen space: every edge cuts pixels at a
/// fractional position, which is exactly the case antialiasing exists for.
const aa_quad_positions = [_][3]f32{
    .{ -1.7, -1.9, -2 }, .{ 1.9, -1.3, -2 }, .{ 1.3, 1.7, -2 }, .{ -1.9, 1.1, -2 },
};

fn aaQuadMesh() Mesh {
    return .{ .positions = &aa_quad_positions, .indices = &quad_indices };
}

test "antialias: slanted edges get partial coverage instead of a staircase" {
    var plain = try TestSurface.init(16, 16);
    defer plain.deinit();
    var smooth = try TestSurface.init(16, 16);
    defer smooth.deinit();
    // `drawMesh` takes the tint as RGBA8 (`red` is 255,0,0,255), unlike the
    // `rasterize` provider whose colors are linear floats in [0, 1].
    const plain_stats = try drawMesh(&plain.target, aaQuadMesh(), transform.identity(), orthoSetup(), red, .{}, null);
    const smooth_stats = try drawMeshAlloc(testing.allocator, &smooth.target, aaQuadMesh(), transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);

    // Antialiasing reaches every pixel the one-sample path reaches plus the edge
    // pixels whose centers fall just outside but that are partly covered — exactly
    // the pixels a one-sample rasterizer drops (and why thin geometry vanishes).
    try testing.expect(smooth_stats.pixels >= plain_stats.pixels);
    try testing.expect(smooth_stats.antialiased_pixels > 0);

    // Interior pixels are byte-identical; edge pixels become translucent.
    var partial: usize = 0;
    var solid: usize = 0;
    for (0..16) |y| for (0..16) |x| {
        const one = plain.target.colorAt(@intCast(x), @intCast(y));
        const aa = smooth.target.colorAt(@intCast(x), @intCast(y));
        if (aa[3] == 0) {
            // Untouched by both paths.
            try testing.expectEqual(@as(u8, 0), one[3]);
        } else if (aa[3] == 255) {
            // Fully covered: bit-identical to the one-sample path, alpha included.
            try testing.expectEqual(@as(u8, 255), one[3]);
            try testing.expectEqualSlices(u8, &one, &aa);
            solid += 1;
        } else {
            // Fractionally covered — either an edge pixel both paths reach or one
            // only the sub-samples reach (the extra coverage AA adds, never a full
            // pixel, which is why thin geometry stops disappearing).
            try testing.expect(aa[3] < 255);
            // Red stays saturated: only alpha was attenuated.
            try testing.expectEqual(@as(u8, 255), aa[0]);
            partial += 1;
        }
    };
    try testing.expectEqual(smooth_stats.antialiased_pixels, partial);
    try testing.expect(partial > 0);
    try testing.expect(solid > 0);

    // The antialiased alpha sum estimates the *exact* screen-space area of the quad,
    // computed independently here with the shoelace formula. This is the numerical
    // statement that coverage integrates correctly, and it is impossible to satisfy
    // with a binary rasterizer (which rounds every pixel to fully covered).
    var area2: f64 = 0;
    var screen_pts: [4][2]f64 = undefined;
    for (aa_quad_positions, 0..) |p, i| {
        const vp = orthoSetup();
        const clip = [4]f32{
            vp[0] * p[0] + vp[4] * p[1] + vp[8] * p[2] + vp[12],
            vp[1] * p[0] + vp[5] * p[1] + vp[9] * p[2] + vp[13],
            vp[2] * p[0] + vp[6] * p[1] + vp[10] * p[2] + vp[14],
            vp[3] * p[0] + vp[7] * p[1] + vp[11] * p[2] + vp[15],
        };
        const nx = @as(f64, clip[0]) / clip[3];
        const ny = @as(f64, clip[1]) / clip[3];
        screen_pts[i] = .{ (nx * 0.5 + 0.5) * 16.0, (0.5 - ny * 0.5) * 16.0 };
    }
    for (0..4) |i| {
        const a = screen_pts[i];
        const b = screen_pts[(i + 1) % 4];
        area2 += a[0] * b[1] - b[0] * a[1];
    }
    const area = @abs(area2) * 0.5;
    var sum_aa: f64 = 0;
    var quantized: usize = 0;
    for (0..16 * 16) |i| {
        const alpha = smooth.target.color[i * 4 + 3];
        sum_aa += @as(f64, @floatFromInt(alpha)) / 255.0;
        if (alpha != 0) quantized += 1;
    }
    // Coverage integrates to the true area. Two bounded error sources remain: the
    // 4x4 sample grid estimates a pixel's area to within one sub-cell (1/16 pixel),
    // and 8-bit alpha stores `count/16` rounded to half an alpha unit. Measured on
    // this quad the sum is off by 0.36 px (0.2%); the tolerance is 0.5%. The point
    // of the assertion is that a binary rasterizer cannot meet it: its alpha sum is
    // 165.0 px here, 2.0 px (1.2%) short, and every pixel has a staircase edge.
    const quant_error = @as(f64, @floatFromInt(quantized)) * 0.5 / 255.0;
    try testing.expect(@abs(sum_aa - area) <= @max(area * 0.005, quant_error));
}

test "antialias: partially covered pixels never write depth" {
    var smooth = try TestSurface.init(16, 16);
    defer smooth.deinit();
    const stats = try drawMeshAlloc(testing.allocator, &smooth.target, aaQuadMesh(), transform.identity(), orthoSetup(), red, .{ .antialias = .edge }, null);
    try testing.expect(stats.antialiased_pixels > 0);

    var partial_with_depth: usize = 0;
    var full_without_depth: usize = 0;
    for (0..16 * 16) |i| {
        const alpha = smooth.target.color[i * 4 + 3];
        const wrote_depth = smooth.target.depth[i] != 1.0;
        if (alpha > 0 and alpha < 255 and wrote_depth) partial_with_depth += 1;
        if (alpha == 255 and !wrote_depth) full_without_depth += 1;
    }
    // A translucent fragment must not occlude; fully covered ones must.
    try testing.expectEqual(@as(usize, 0), partial_with_depth);
    try testing.expectEqual(@as(usize, 0), full_without_depth);
}

test "antialias: a translucent source composites through fractional coverage" {
    var smooth = try TestSurface.init(16, 16);
    defer smooth.deinit();
    smooth.target.clear(.{ 0, 0, 255, 255 }, 1.0);
    const over = [4]u8{ 255, 0, 0, 128 };
    _ = try drawMeshAlloc(testing.allocator, &smooth.target, aaQuadMesh(), transform.identity(), orthoSetup(), over, .{ .antialias = .edge, .blend = .alpha }, null);

    // Fully covered interior: exactly the plain `.alpha` result of a half-alpha red
    // over opaque blue; edge pixels are weaker (less red, more blue).
    var saw_full = false;
    var saw_partial = false;
    for (0..16 * 16) |i| {
        const px = [4]u8{ smooth.target.color[i * 4], smooth.target.color[i * 4 + 1], smooth.target.color[i * 4 + 2], smooth.target.color[i * 4 + 3] };
        if (std.mem.eql(u8, &px, &.{ 0, 0, 255, 255 })) continue; // clear
        if (std.mem.eql(u8, &px, &.{ 128, 0, 127, 255 })) {
            saw_full = true;
        } else {
            try testing.expect(px[0] < 128 and px[2] > 127 and px[3] == 255);
            saw_partial = true;
        }
    }
    try testing.expect(saw_full);
    try testing.expect(saw_partial);
}

test "antialias: single-triangle entry point ignores the mode" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    var pixels: usize = 0;
    const drew = rasterTriangle(&s.target, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 4 * subpixel_scale, .y = 0, .z = 0 }, .{ .x = 0, .y = 4 * subpixel_scale, .z = 0 }, red, .{ .cull = .none, .antialias = .edge }, &pixels, null, .{ 0, 0, 0 });
    try testing.expect(drew);
    // No accumulator is available, so the one-sample result is written: the
    // hypotenuse row keeps full coverage rather than a translucent edge.
    try testing.expectEqual(@as(usize, 6), pixels);
}

// --- per-draw sampling controls -------------------------------------------

test "Sampling: the identity is tap 8 and no bias, and tests the fast path" {
    const identity = Sampling{};
    try testing.expect(identity.isIdentity());
    try testing.expectEqual(max_aniso_samples, identity.tapCap());

    // `max_samples == 0` means "the global default", not "no taps": a cap of
    // zero would mean the draw samples nothing at all.
    try testing.expectEqual(max_aniso_samples, (Sampling{ .max_samples = 0 }).tapCap());
    try testing.expectEqual(@as(u8, 1), (Sampling{ .max_samples = 1 }).tapCap());
    try testing.expectEqual(@as(u8, 4), (Sampling{ .max_samples = 4 }).tapCap());
    // Above the global maximum the cap is clamped rather than honoured: the
    // kernel has no more taps to give.
    try testing.expectEqual(max_aniso_samples, (Sampling{ .max_samples = 9 }).tapCap());
    try testing.expectEqual(max_aniso_samples, (Sampling{ .max_samples = 255 }).tapCap());

    // Any deviation from the default is *not* the identity, including a bias that
    // rounds to zero levels: exact comparison keeps the caller's intent.
    try testing.expect(!(Sampling{ .lod_bias = 0.5 }).isIdentity());
    try testing.expect(!(Sampling{ .lod_bias = -0.0 + 1e-18 }).isIdentity());
    try testing.expect(!(Sampling{ .max_samples = 1 }).isIdentity());
}

test "textureLodBiased: the bias shifts the level and clamps to the chain" {
    // 8 texels/pixel is level 3; a +1 bias must read one level *smaller* (sharper).
    try testing.expectEqual(@as(f64, 3.0), textureLod(8.0, 8.0, 5));
    try testing.expectEqual(@as(f64, 4.0), textureLodBiased(8.0, 8.0, 5, 1.0));
    try testing.expectEqual(@as(f64, 2.0), textureLodBiased(8.0, 8.0, 5, -1.0));
    try testing.expectEqual(@as(f64, 2.5), textureLodBiased(8.0, 8.0, 5, -0.5));

    // Past the last level, and below level 0, the result stops at the chain ends.
    try testing.expectEqual(@as(f64, 4.0), textureLodBiased(8.0, 8.0, 5, 64.0));
    try testing.expectEqual(@as(f64, 0.0), textureLodBiased(8.0, 8.0, 5, -64.0));

    // A bias of zero must be the pre-existing function bit for bit, and the two
    // arguments are symmetric (the level follows the larger gradient).
    const cases = [_][2]f64{ .{ 0.25, 1.0 }, .{ 3.0, 0.5 }, .{ 17.0, 2.0 } };
    for (cases) |c| {
        try testing.expectEqual(textureLod(c[0], c[1], 4), textureLodBiased(c[0], c[1], 4, 0.0));
        try testing.expectEqual(textureLod(c[1], c[0], 4), textureLod(c[0], c[1], 4));
    }
}

test "anisoFootprintCapped: the tap cap limits the count, never the level" {
    // An 8:1 grazing footprint asks for eight taps by default.
    const grazing = TexelDerivatives{ .du = .{ 8.0, 0.0 }, .dv = .{ 0.0, 1.0 } };
    try testing.expectEqual(@as(u8, 8), anisoFootprintCapped(grazing, 5, max_aniso_samples).samples);

    // Capping the taps must not change the levels: only the number of samples
    // along the axis is a quality/time knob, the footprint itself is the same.
    const full = anisoFootprintCapped(grazing, 5, max_aniso_samples);
    for ([_]u8{ 1, 2, 4 }) |cap| {
        const capped = anisoFootprintCapped(grazing, 5, cap);
        try testing.expectEqual(cap, capped.samples);
        try testing.expectEqual(full.lod_major, capped.lod_major);
        try testing.expectEqual(full.lod_minor, capped.lod_minor);
        try testing.expectEqual(full.axis, capped.axis);
    }

    // A cap wider than the kernel is the kernel's own maximum.
    try testing.expectEqual(@as(u8, 8), anisoFootprintCapped(grazing, 5, 200).samples);
    // And a round footprint stays at one tap whatever the cap says.
    const round = TexelDerivatives{ .du = .{ 4.0, 0.0 }, .dv = .{ 0.0, 4.0 } };
    try testing.expectEqual(@as(u8, 1), anisoFootprintCapped(round, 5, 4).samples);
}

test "GradSteps: sampling controls bias and cap without touching the rule" {
    // A constant denominator (affine UVs) with a grazing footprint: 8 texels along
    // x, 1 along y. `dp`/`dq` are the per-pixel derivatives of the numerators.
    const size = [2]f64{ 16.0, 16.0 };
    const grad = GradSteps{ .dp = .{ 8.0, 0.0 }, .dq = .{ 0.0, 1.0 }, .dden = .{ 0.0, 0.0 } };
    const levels: u32 = 5;

    // The identity reproduces the uncapped footprint and the plain level exactly.
    const plain = grad.aniso(0.0, 0.0, 1.0, size, levels, .{});
    const direct = anisoFootprintCapped(
        texelDerivatives(0.0, 0.0, 1.0, grad.dp, grad.dq, grad.dden, size),
        levels,
        max_aniso_samples,
    );
    try testing.expectEqual(direct.samples, plain.samples);
    try testing.expectEqual(direct.lod_major, plain.lod_major);
    try testing.expectEqual(direct.lod_minor, plain.lod_minor);
    // The cached path is the same footprint, because the denominator cannot vary.
    const cached = grad.constantAniso(1.0, size, levels, .{}).?;
    try testing.expectEqual(plain.samples, cached.samples);
    try testing.expectEqual(plain.lod_major, cached.lod_major);
    try testing.expectEqual(plain.lod_minor, cached.lod_minor);

    // A tap cap removes taps but must leave both levels alone.
    const capped = grad.aniso(0.0, 0.0, 1.0, size, levels, .{ .max_samples = 2 });
    try testing.expectEqual(@as(u8, 2), capped.samples);
    try testing.expectEqual(plain.lod_major, capped.lod_major);
    try testing.expectEqual(plain.lod_minor, capped.lod_minor);
    try testing.expectEqual(plain.axis, capped.axis);

    // A positive bias sharpens (smaller level), negative blurs, and both clamp.
    const sharper = grad.aniso(0.0, 0.0, 1.0, size, levels, .{ .lod_bias = 1.0 });
    try testing.expectEqual(@min(plain.lod_major + 1.0, 4.0), sharper.lod_major);
    try testing.expectEqual(@min(plain.lod_minor + 1.0, 4.0), sharper.lod_minor);
    const blurrier = grad.aniso(0.0, 0.0, 1.0, size, levels, .{ .lod_bias = -1.0 });
    try testing.expectEqual(@max(plain.lod_major - 1.0, 0.0), blurrier.lod_major);
    try testing.expectEqual(@as(f64, 0.0), blurrier.lod_minor);
    try testing.expectEqual(@as(f64, 4.0), grad.aniso(0.0, 0.0, 1.0, size, levels, .{ .lod_bias = 99.0 }).lod_major);

    // The cached affine path biases exactly like the per-pixel one.
    const cached_biased = grad.constantAniso(1.0, size, levels, .{ .lod_bias = 1.0 }).?;
    try testing.expectEqual(sharper.lod_major, cached_biased.lod_major);
    try testing.expectEqual(sharper.lod_minor, cached_biased.lod_minor);

    // `constantLod` is the trilinear counterpart: same bias, same clamp, and it
    // collapses the two axes with `max` exactly like `texelGradient`.
    const g = texelGradient(0.0, 0.0, 1.0, grad.dp, grad.dq, grad.dden, size);
    try testing.expectEqual(textureLod(g.du, g.dv, levels), grad.constantLod(1.0, size, levels, 0.0).?);
    try testing.expectEqual(textureLodBiased(g.du, g.dv, levels, 1.0), grad.constantLod(1.0, size, levels, 1.0).?);
    try testing.expectEqual(textureLodBiased(g.du, g.dv, levels, -1.0), grad.constantLod(1.0, size, levels, -1.0).?);
    // The trilinear level follows the *long* axis (8 texels/pixel), the taps follow
    // the short one: that difference is the whole point of the anisotropic mode.
    try testing.expect(plain.lod_major > plain.lod_minor);
    // A varying denominator has no cached value at all.
    const varying = GradSteps{ .dp = .{ 8.0, 0.0 }, .dq = .{ 0.0, 1.0 }, .dden = .{ 0.25, 0.0 } };
    try testing.expectEqual(@as(?f64, null), varying.constantLod(1.0, size, levels, 0.0));
    try testing.expectEqual(@as(?AnisoFootprint, null), varying.constantAniso(1.0, size, levels, .{}));
}

test "rasterize: the sampling controls reach the pixels" {
    // Stripes with an 8-texel period over a 32x32 chain: level 0 is crisp, level 4
    // is already a flat average, so which level a draw samples is visible in the
    // frame instead of only in the level arithmetic.
    const AnisoResources = @import("raster_aniso_resources.zig").Provider;
    const w = 32;
    const h = 32;
    var pixels: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const o = (y * w + x) * 4;
            const on = (y % 8) < 4;
            pixels[o + 0] = if (on) 240 else 16;
            pixels[o + 1] = if (on) 240 else 16;
            pixels[o + 2] = if (on) 240 else 16;
            pixels[o + 3] = 255;
        }
    }
    const alloc = testing.allocator;
    var chain = try @import("mipmap.zig").Chain.generate(alloc, w, h, &pixels);
    defer chain.deinit(alloc);

    const size = 8;
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    // 4 texels per pixel across x, 1 across y: LOD 2 for trilinear, a 4:1 footprint
    // for anisotropic, so both the bias and the tap cap land on a different level.
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0.25 }, .{ 0, 0.25 } };
    const mesh = Mesh{ .positions = &positions, .indices = &indices, .uvs = &uvs };
    const vp = @import("camera.zig").orthographic(-1, 1, -1, 1, 0, 2);
    const tex = Texture{ .width = w, .height = h, .pixels = &pixels, .mips = chain.levels(), .filter = .bilinear };
    try tex.validate();

    const settings = [_]Options{
        .{ .cull = .none, .mipmap = .trilinear },
        // +2 levels: past the last one, onto the flat level 4.
        .{ .cull = .none, .mipmap = .trilinear, .sampling = .{ .lod_bias = 2.0 } },
        .{ .cull = .none, .mipmap = .anisotropic },
        // One tap: the documented collapse onto the trilinear level.
        .{ .cull = .none, .mipmap = .anisotropic, .sampling = .{ .max_samples = 1 } },
    };
    var frames: [settings.len][size * size * 4]u8 = undefined;
    var depth: [size * size]f32 = @splat(1.0);
    for (settings, 0..) |options, i| {
        @memset(&frames[i], 0);
        @memset(&depth, 1.0);
        // The target borrows the buffer itself, never a copy of it.
        var target = try Target.init(size, size, &frames[i], &depth);
        _ = try rasterize(&target, &.{.{
            .entity = .{ .index = 1, .generation = 0 },
            .mesh = 0,
            .material = 0,
            .world = @import("../scene/transform.zig").identity(),
            .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 1 } },
            .depth = 0,
        }}, vp, AnisoResources{ .tex = tex, .quad = mesh }, options);
    }

    // The bias moves the frame, so it reaches the sampler and not just a struct field.
    try testing.expect(!std.mem.eql(u8, &frames[0], &frames[1]));
    // Capping the taps to the trilinear path changes the image: the correction was
    // actually being spent.
    try testing.expect(!std.mem.eql(u8, &frames[2], &frames[3]));
    // And a cap of one *is* the trilinear path, byte for byte — the reason the cap
    // can be described as a quality/time knob rather than as a second filter.
    try testing.expectEqualSlices(u8, &frames[0], &frames[3]);
}

// --- anisotropic filtering ------------------------------------------------

test "anisoFootprint: a round footprint is one tap and the trilinear level" {
    // Equal per-axis derivatives: nothing to correct, so the mode must not spend a
    // second tap and the level is exactly what `textureLod` picks.
    const round = TexelDerivatives{ .du = .{ 4.0, 0.0 }, .dv = .{ 0.0, 4.0 } };
    const f = anisoFootprint(round, 5);
    try testing.expectEqual(@as(u8, 1), f.samples);
    try testing.expectEqual(textureLod(4.0, 4.0, 5), f.lod_major);
    try testing.expectEqual(f.lod_major, f.lod_minor);
    try testing.expectEqual([2]f64{ 0.0, 0.0 }, f.axis);

    // A degenerate (zero) derivative cannot describe a footprint either.
    const none = anisoFootprint(.{ .du = .{ 0, 0 }, .dv = .{ 0, 0 } }, 5);
    try testing.expectEqual(@as(u8, 1), none.samples);
    try testing.expectEqual(@as(f64, 0.0), none.lod_minor);
}

test "anisoFootprint: elongation sets the tap count and the minor level" {
    // 8 texels across x, 1 across y: an 8:1 footprint, the clamp, so eight taps.
    // The corrected level follows the *short* axis (1 texel/pixel -> level 0)
    // while the trilinear level follows the long one (8 -> level 3).
    const grazing = TexelDerivatives{ .du = .{ 8.0, 0.0 }, .dv = .{ 0.0, 1.0 } };
    const f = anisoFootprint(grazing, 5);
    try testing.expectEqual(@as(u8, 8), f.samples);
    try testing.expectEqual(@as(f64, 3.0), f.lod_major);
    try testing.expectEqual(@as(f64, 0.0), f.lod_minor);
    // The axis runs along the long direction: +x here, normalised.
    try testing.expectEqual([2]f64{ 1.0, 0.0 }, f.axis);

    // 2:1 takes two taps and one level of correction.
    const mild = TexelDerivatives{ .du = .{ 4.0, 0.0 }, .dv = .{ 0.0, 2.0 } };
    const m = anisoFootprint(mild, 6);
    try testing.expectEqual(@as(u8, 2), m.samples);
    try testing.expectEqual(@as(f64, 2.0), m.lod_major);
    try testing.expectEqual(@as(f64, 1.0), m.lod_minor);

    // Beyond 8:1 the ratio clamps, so the tap count stops growing and the correction
    // stops deepening: the extra taps would not buy anything a viewer can see.
    const extreme = TexelDerivatives{ .du = .{ 64.0, 0.0 }, .dv = .{ 0.0, 1.0 } };
    const e = anisoFootprint(extreme, 8);
    try testing.expectEqual(@as(u8, max_aniso_samples), e.samples);
    try testing.expectEqual(@as(f64, 6.0), e.lod_major);
    try testing.expectEqual(@as(f64, 3.0), e.lod_minor);

    // The minor level never goes below level 0, even where the arithmetic would.
    const tiny = TexelDerivatives{ .du = .{ 0.5, 0.0 }, .dv = .{ 0.0, 0.0625 } };
    const t = anisoFootprint(tiny, 4);
    try testing.expectEqual(@as(f64, 0.0), t.lod_major);
    try testing.expectEqual(@as(f64, 0.0), t.lod_minor);
}

test "anisoFootprint: the long axis is whichever direction is longer" {
    // A vertically elongated footprint must put its taps along y, not x.
    const vertical = TexelDerivatives{ .du = .{ 1.0, 0.0 }, .dv = .{ 0.0, 8.0 } };
    const f = anisoFootprint(vertical, 5);
    try testing.expectEqual(@as(u8, 8), f.samples);
    try testing.expectEqual([2]f64{ 0.0, 1.0 }, f.axis);
}

test "sampleAnisotropic: one tap is exactly sampleTrilinear at the major level" {
    const level0 = [_]u8{
        255, 0, 0,   255, 0,   255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    // 2x2 -> 1x1 is the whole chain: the rasterizer rejects a level that does not
    // halve the one above it, so the fixture must be a real chain.
    const level1 = [_]u8{ 128, 128, 128, 255 };
    const mips = [_]MipLevel{.{ .width = 1, .height = 1, .pixels = &level1 }};
    const tex = Texture{ .width = 2, .height = 2, .pixels = &level0, .mips = &mips, .filter = .bilinear };
    try tex.validate();

    const round = anisoFootprint(.{ .du = .{ 3.0, 0.0 }, .dv = .{ 0.0, 3.0 } }, tex.mipLevelCount());
    try testing.expectEqual(@as(u8, 1), round.samples);
    const size = [2]f64{ 2, 2 };
    const uv = [_][2]f64{ .{ 0.1, 0.1 }, .{ 0.7, 0.35 }, .{ 1.3, -0.2 } };
    for (uv) |pair| {
        try testing.expectEqualSlices(
            u8,
            &sampleTrilinear(tex, pair[0], pair[1], round.lod_major),
            &sampleAnisotropic(tex, pair[0], pair[1], round, size),
        );
    }
}

test "sampleAnisotropic: taps average along the axis and stay inside one round" {
    // A 4x1 texture of alternating black and white is the worst case for a single
    // tap: the corrected footprint spans several texels, so averaging them must
    // produce a value no tap alone could give, and every channel must stay exact.
    const level0 = [_]u8{
        0,   0,   0,   255,
        255, 255, 255, 255,
        0,   0,   0,   255,
        255, 255, 255, 255,
    };
    const level1 = [_]u8{
        128, 128, 128, 255,
        128, 128, 128, 255,
    };
    const level2 = [_]u8{ 128, 128, 128, 255 };
    const mips = [_]MipLevel{
        .{ .width = 2, .height = 1, .pixels = &level1 },
        .{ .width = 1, .height = 1, .pixels = &level2 },
    };
    const tex = Texture{ .width = 4, .height = 1, .pixels = &level0, .mips = &mips, .filter = .nearest };
    try tex.validate();

    const size = [2]f64{ @floatFromInt(tex.width), @floatFromInt(tex.height) };
    const footprint = AnisoFootprint{ .samples = 4, .axis = .{ 1.0, 0.0 }, .lod_major = 2.0, .lod_minor = 0.0 };
    const got = sampleAnisotropic(tex, 0.5, 0.25, footprint, size);
    // Four taps spread over the middle of the strip hit both colours, so the
    // average is a mid grey rather than black or white.
    try testing.expect(got[0] > 60 and got[0] < 200);
    try testing.expectEqual(@as(u8, 255), got[3]);

    // Sampling the same footprint at the same place twice is deterministic.
    try testing.expectEqualSlices(u8, &got, &sampleAnisotropic(tex, 0.5, 0.25, footprint, size));
}

test "anisotropic mode keeps detail that trilinear blurs away at grazing angles" {
    // The claim the feature exists for, measured rather than asserted: on a
    // high-frequency texture seen with a 4:1 footzprint, anisotropic sampling must
    // preserve more contrast than isotropic sampling while still averaging (no
    // aliasing). A pure level-0 sample is the aliasing baseline: it keeps contrast
    // but by picking texels, not by averaging them.
    const w = 64;
    const h = 64;
    var pixels: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const o = (y * w + x) * 4;
            // Horizontal stripes with an 8-texel period: the variation runs along
            // the footprint's *short* axis, which is exactly the detail anisotropic
            // filtering is supposed to keep and an isotropic level blurs away.
            const on = (y % 8) < 4;
            pixels[o + 0] = if (on) 240 else 16;
            pixels[o + 1] = if (on) 240 else 16;
            pixels[o + 2] = if (on) 240 else 16;
            pixels[o + 3] = 255;
        }
    }
    const alloc = testing.allocator;
    var chain = try @import("mipmap.zig").Chain.generate(alloc, w, h, &pixels);
    defer chain.deinit(alloc);

    // 8x8 target; UVs stretch 4 texels per pixel in x and 1 in y.
    const size = 8;
    var color: [size * size * 4]u8 = @splat(0);
    var depth: [size * size]f32 = @splat(1.0);
    var target = try Target.init(size, size, &color, &depth);
    const vp = @import("camera.zig").orthographic(-1, 1, -1, 1, 0, 2);
    // 16 texels per pixel across x, 2 across y: an 8:1 footprint (the clamp), so
    // the trilinear level follows x (level 4) while the corrected level follows y
    // (level 1).
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 0.25 }, .{ 0, 0.25 } };
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const mesh = Mesh{ .positions = &positions, .indices = &indices, .uvs = &uvs };
    // Provider methods named `mesh`/`color` cannot be declared inside a function
    // body here (the enclosing test has locals by those names), so the provider
    // lives at file scope with the quad passed in.
    const AnisoResources = @import("raster_aniso_resources.zig").Provider;
    // Mean absolute difference between neighbouring pixels: high means the image
    // still carries detail, low means it was blurred to a flat field.
    const Detail = struct {
        fn measure(buf: []const u8, n: usize) f64 {
            // Both axes, not just the horizontal one: the detail under test runs
            // vertically, and a metric that only looked across would read zero for
            // both modes and prove nothing.
            var sum: f64 = 0;
            var count: usize = 0;
            for (0..n) |y| {
                for (0..n) |x| {
                    const here = @as(f64, @floatFromInt(buf[(y * n + x) * 4]));
                    if (x + 1 < n) {
                        const right = @as(f64, @floatFromInt(buf[(y * n + x + 1) * 4]));
                        sum += @abs(here - right);
                        count += 1;
                    }
                    if (y + 1 < n) {
                        const down = @as(f64, @floatFromInt(buf[((y + 1) * n + x) * 4]));
                        sum += @abs(here - down);
                        count += 1;
                    }
                }
            }
            return sum / @as(f64, @floatFromInt(count));
        }
    };

    var detail: [2]f64 = undefined;
    for ([_]Mipmap{ .trilinear, .anisotropic }, 0..) |mode, i| {
        @memset(&color, 0);
        @memset(&depth, 1.0);
        const tex = Texture{ .width = w, .height = h, .pixels = &pixels, .mips = chain.levels(), .filter = .bilinear };
        try tex.validate();
        _ = try rasterize(&target, &.{.{
            .entity = .{ .index = 1, .generation = 0 },
            .mesh = 0,
            .material = 0,
            .world = @import("../scene/transform.zig").identity(),
            .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 1 } },
            .depth = 0,
        }}, vp, AnisoResources{ .tex = tex, .quad = mesh }, .{ .cull = .none, .mipmap = mode });
        detail[i] = Detail.measure(&color, size);
    }
    // Anisotropic sampling follows the short axis (1 texel per pixel), so the
    // checkerboard survives; trilinear follows the long one (4 texels per pixel)
    // and averages it into a flat field.
    try testing.expect(detail[1] > detail[0] * 2.0);
}
