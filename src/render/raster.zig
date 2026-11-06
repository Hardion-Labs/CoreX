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
//! per-pixel perspective correction. (Attributes such as UVs would need that
//! correction; this backend shades flat, so there are none.)
//!
//! Coupling: geometry and materials arrive through a duck-typed `resources`
//! value, so this module never imports the asset layer. A caller adapts
//! `assets.mesh.MeshView` (or plain arrays) with a few lines; see the tests.
//!
//! Not implemented, and not claimed: textures, lighting, shading, blending,
//! transparency, MSAA, mipmaps, or any GPU path.

const std = @import("std");
const draw = @import("draw.zig");
const transform = @import("../scene/transform.zig");

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
};

/// Largest framebuffer side. Bounds the fixed-point range and the pixel count.
pub const max_dimension: u32 = 16384;

/// Subpixel precision: screen coordinates are stored in 28.4 fixed point.
pub const subpixel_bits: u5 = 4;
pub const subpixel_scale: i32 = 1 << subpixel_bits;

/// Which triangle orientation faces the camera, in NDC (before the Y flip).
pub const FrontFace = enum { counter_clockwise, clockwise };

pub const CullMode = enum { none, back, front };

pub const Options = struct {
    cull: CullMode = .back,
    front_face: FrontFace = .counter_clockwise,
    depth_test: bool = true,
    depth_write: bool = true,
};

/// A triangle vertex in screen space: `x`/`y` are 28.4 fixed point pixels with
/// the origin at the top-left, `z` is NDC depth in [-1, 1].
pub const ScreenVertex = struct {
    x: i32,
    y: i32,
    z: f32,
};

/// Borrowed geometry. Positions and indices are plain typed slices, so this
/// module carries no knowledge of any artifact byte layout.
pub const Mesh = struct {
    positions: []const [3]f32,
    /// Triangle list; length must be a multiple of three.
    indices: []const u32,
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
    /// Pixels that passed the depth test and were written.
    pixels: usize = 0,

    pub fn add(self: *Stats, other: Stats) void {
        self.skipped_draws += other.skipped_draws;
        self.submitted += other.submitted;
        self.clipped += other.clipped;
        self.culled += other.culled;
        self.rasterized += other.rasterized;
        self.pixels += other.pixels;
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

/// Rasterize one screen-space triangle. Returns false only when the triangle was
/// rejected by the cull mode or is exactly degenerate (zero area); a triangle
/// that survives but covers no pixel center still returns true, so the result
/// depends on the triangle and cull mode alone, never on the target size.
/// This is the exact entry point the reference vectors target.
pub fn rasterTriangle(
    target: *Target,
    a: ScreenVertex,
    b: ScreenVertex,
    c: ScreenVertex,
    rgba: [4]u8,
    options: Options,
    pixels_written: ?*usize,
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

    // Pixel centers sit at (x + 0.5, y + 0.5), i.e. half a pixel in fixed point.
    const bias0: i64 = if (isTopLeft(v1.x, v1.y, v2.x, v2.y)) 0 else 1;
    const bias1: i64 = if (isTopLeft(v2.x, v2.y, v0.x, v0.y)) 0 else 1;
    const bias2: i64 = if (isTopLeft(v0.x, v0.y, v1.x, v1.y)) 0 else 1;

    const half: i32 = subpixel_scale / 2;
    const min_x = @max(0, floorDiv(@min(v0.x, @min(v1.x, v2.x)) - half));
    const min_y = @max(0, floorDiv(@min(v0.y, @min(v1.y, v2.y)) - half));
    const max_x = @min(@as(i32, @intCast(target.width)) - 1, floorDiv(@max(v0.x, @max(v1.x, v2.x)) - half));
    const max_y = @min(@as(i32, @intCast(target.height)) - 1, floorDiv(@max(v0.y, @max(v1.y, v2.y)) - half));
    // An empty box means no pixel center can be inside. That is not culling:
    // the triangle was still accepted, it simply covers nothing here.
    if (min_x > max_x or min_y > max_y) return true;

    const px0 = min_x * subpixel_scale + half;
    const py0 = min_y * subpixel_scale + half;
    var row0 = edge(v1.x, v1.y, v2.x, v2.y, px0, py0) - bias0;
    var row1 = edge(v2.x, v2.y, v0.x, v0.y, px0, py0) - bias1;
    var row2 = edge(v0.x, v0.y, v1.x, v1.y, px0, py0) - bias2;

    // Stepping one pixel right/down changes each edge function by a constant,
    // so the inner loop needs no multiplications for coverage.
    const step_x0 = (@as(i64, v1.y) - v2.y) * subpixel_scale;
    const step_x1 = (@as(i64, v2.y) - v0.y) * subpixel_scale;
    const step_x2 = (@as(i64, v0.y) - v1.y) * subpixel_scale;
    const step_y0 = (@as(i64, v2.x) - v1.x) * subpixel_scale;
    const step_y1 = (@as(i64, v0.x) - v2.x) * subpixel_scale;
    const step_y2 = (@as(i64, v1.x) - v0.x) * subpixel_scale;

    const inv_area = 1.0 / @as(f64, @floatFromInt(area));
    const z0: f64 = v0.z;
    const z1: f64 = v1.z;
    const z2: f64 = v2.z;
    const width: usize = target.width;
    var written: usize = 0;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var w0 = row0;
        var w1 = row1;
        var w2 = row2;
        var x = min_x;
        var index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
        while (x <= max_x) : (x += 1) {
            if ((w0 | w1 | w2) >= 0) {
                // NDC z is affine in screen space after the divide, so plain
                // barycentric interpolation is already perspective-correct.
                const depth: f32 = @floatCast(((@as(f64, @floatFromInt(w0 + bias0)) * z0 +
                    @as(f64, @floatFromInt(w1 + bias1)) * z1) +
                    @as(f64, @floatFromInt(w2 + bias2)) * z2) * inv_area);
                if (!options.depth_test or depth < target.depth[index]) {
                    const o = index * 4;
                    target.color[o + 0] = rgba[0];
                    target.color[o + 1] = rgba[1];
                    target.color[o + 2] = rgba[2];
                    target.color[o + 3] = rgba[3];
                    if (options.depth_write) target.depth[index] = depth;
                    written += 1;
                }
            }
            w0 += step_x0;
            w1 += step_x1;
            w2 += step_x2;
            index += 1;
        }
        row0 += step_y0;
        row1 += step_y1;
        row2 += step_y2;
    }
    if (pixels_written) |out| out.* += written;
    return true;
}

// --- clip space -------------------------------------------------------------

const ClipVertex = [4]f32;

/// The six frustum half-spaces in clip space (OpenGL convention, z in [-w, w]).
/// A vertex is inside when every distance is >= 0.
fn planeDistance(plane: usize, v: ClipVertex) f32 {
    return switch (plane) {
        0 => v[3] + v[0], // left
        1 => v[3] - v[0], // right
        2 => v[3] + v[1], // bottom
        3 => v[3] - v[1], // top
        4 => v[3] + v[2], // near
        5 => v[3] - v[2], // far
        else => unreachable,
    };
}

fn lerpClip(a: ClipVertex, b: ClipVertex, t: f32) ClipVertex {
    var out: ClipVertex = undefined;
    for (&out, a, b) |*o, x, y| o.* = x + (y - x) * t;
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
    const w = v[3];
    if (!(w > 1e-20) or !std.math.isFinite(w)) return null;
    const inv = 1.0 / w;
    const nx = v[0] * inv;
    const ny = v[1] * inv;
    const nz = v[2] * inv;
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
    };
}

/// Transform, clip and rasterize one clip-space triangle.
fn drawClipTriangle(
    target: *Target,
    tri: [3]ClipVertex,
    rgba: [4]u8,
    options: Options,
    stats: *Stats,
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
        if (rasterTriangle(target, screen[0], screen[i], screen[i + 1], rgba, options, &stats.pixels)) {
            stats.rasterized += 1;
        } else {
            stats.culled += 1;
        }
    }
}

fn transformVertex(m: Mat4, p: [3]f32) ClipVertex {
    var out: ClipVertex = undefined;
    inline for (0..4) |r| {
        out[r] = m[0 * 4 + r] * p[0] + m[1 * 4 + r] * p[1] + m[2 * 4 + r] * p[2] + m[3 * 4 + r];
    }
    return out;
}

/// Rasterize one mesh with a flat RGBA color. `world` and `view_projection` are
/// combined once, so the per-vertex cost is a single matrix-vector product.
pub fn drawMesh(
    target: *Target,
    mesh: Mesh,
    world: Mat4,
    view_projection: Mat4,
    rgba: [4]u8,
    options: Options,
) Error!Stats {
    if (mesh.indices.len % 3 != 0) return error.InvalidIndex;
    const mvp = transform.multiply(view_projection, world);
    var stats: Stats = .{};
    var i: usize = 0;
    while (i < mesh.indices.len) : (i += 3) {
        stats.submitted += 1;
        const idx0 = mesh.indices[i];
        const idx1 = mesh.indices[i + 1];
        const idx2 = mesh.indices[i + 2];
        if (idx0 >= mesh.positions.len or idx1 >= mesh.positions.len or idx2 >= mesh.positions.len)
            return error.InvalidIndex;
        const tri = [3]ClipVertex{
            transformVertex(mvp, mesh.positions[idx0]),
            transformVertex(mvp, mesh.positions[idx1]),
            transformVertex(mvp, mesh.positions[idx2]),
        };
        drawClipTriangle(target, tri, rgba, options, &stats);
    }
    return stats;
}

/// Rasterize an extracted draw list.
///
/// `resources` is duck-typed and resolved per command, keeping this module free
/// of any asset-layer dependency. It must provide:
///
/// - `fn mesh(self, handle: u32) ?Mesh`
/// - `fn color(self, handle: u32) ?[4]f32` — linear RGBA in [0, 1]
///
/// A command whose mesh or material handle does not resolve is counted in
/// `skipped_draws` and leaves the target untouched.
pub fn rasterize(
    target: *Target,
    commands: []const DrawCommand,
    view_projection: Mat4,
    resources: anytype,
    options: Options,
) Error!Stats {
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
        stats.add(try drawMesh(target, mesh, cmd.world, view_projection, rgba, options));
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
    const drew = rasterTriangle(&s.target, sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0), red, .{ .cull = .none }, null);
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
    _ = rasterTriangle(&a.target, sv(0, 0, 0), sv(4, 0, 0), sv(0, 4, 0), red, .{ .cull = .none }, null);
    _ = rasterTriangle(&b.target, sv(4, 0, 0), sv(4, 4, 0), sv(0, 4, 0), green, .{ .cull = .none }, null);
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
        _ = rasterTriangle(&a.target, p0, p1, d1, red, .{ .cull = .none }, null);
        _ = rasterTriangle(&a.target, p0, d1, d0, red, .{ .cull = .none }, null);
        _ = rasterTriangle(&a.target, p0, d0, p3, red, .{ .cull = .none }, null);
        _ = rasterTriangle(&b.target, p1, p2, d1, green, .{ .cull = .none }, null);
        _ = rasterTriangle(&b.target, d1, p2, p3, green, .{ .cull = .none }, null);
        _ = rasterTriangle(&b.target, d1, p3, d0, green, .{ .cull = .none }, null);
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
    try testing.expect(!rasterTriangle(&s.target, sv(0, 0, 0), sv(2, 0, 0), sv(4, 0, 0), red, .{ .cull = .none }, null));
    try testing.expect(!rasterTriangle(&s.target, sv(1, 1, 0), sv(1, 1, 0), sv(1, 1, 0), red, .{ .cull = .none }, null));
    try testing.expect(!rasterTriangle(&s.target, sv(0, 0, 0), sv(2, 2, 0), sv(4, 4, 0), red, .{ .cull = .none }, null));
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
                const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], red, .{ .cull = mode, .front_face = ff }, null);
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
    _ = rasterTriangle(&a.target, v0, v1, v2, red, .{ .cull = .none }, null);
    _ = rasterTriangle(&b.target, v0, v2, v1, red, .{ .cull = .none }, null);
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
            _ = rasterTriangle(
                &s.target,
                .{ .x = tri[0].x, .y = tri[0].y, .z = z },
                .{ .x = tri[1].x, .y = tri[1].y, .z = z },
                .{ .x = tri[2].x, .y = tri[2].y, .z = z },
                col,
                .{ .cull = .none },
                &pixels,
            );
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
    _ = rasterTriangle(&s.target, sv(0, 0, 0.5), sv(4, 0, 0.5), sv(0, 4, 0.5), red, .{ .cull = .none }, null);
    var pixels: usize = 0;
    _ = rasterTriangle(&s.target, sv(0, 0, 0.5), sv(4, 0, 0.5), sv(0, 4, 0.5), green, .{ .cull = .none }, &pixels);
    try testing.expectEqual(@as(usize, 0), pixels);
    try testing.expectEqualSlices(u8, &red, &s.target.colorAt(0, 0));
}

test "depth_write false leaves the depth buffer untouched" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    var pixels: usize = 0;
    _ = rasterTriangle(&s.target, sv(0, 0, -0.5), sv(4, 0, -0.5), sv(0, 4, -0.5), red, .{ .cull = .none, .depth_write = false }, &pixels);
    try testing.expectEqual(@as(usize, 6), pixels);
    for (s.depth) |d| try testing.expectEqual(@as(f32, 1.0), d);
    // A later, farther triangle still passes because depth stayed at the clear.
    _ = rasterTriangle(&s.target, sv(0, 0, 0.9), sv(4, 0, 0.9), sv(0, 4, 0.9), green, .{ .cull = .none }, &pixels);
    try testing.expectEqual(@as(usize, 12), pixels);
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(0, 0));
}

test "depth_test false paints in submission order" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    _ = rasterTriangle(&s.target, sv(0, 0, -0.9), sv(4, 0, -0.9), sv(0, 4, -0.9), red, .{ .cull = .none, .depth_test = false }, null);
    _ = rasterTriangle(&s.target, sv(0, 0, 0.9), sv(4, 0, 0.9), sv(0, 4, 0.9), green, .{ .cull = .none, .depth_test = false }, null);
    try testing.expectEqualSlices(u8, &green, &s.target.colorAt(0, 0));
}

test "depth interpolates linearly across the triangle" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    // z = -1 at x=0, +1 at x=4: the value at a pixel center is x/2 - 0.75.
    _ = rasterTriangle(&s.target, sv(0, 0, -1), sv(4, 0, 1), sv(0, 4, -1), red, .{ .cull = .none }, null);
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

test "drawMesh: a front-facing quad covers the whole viewport" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const stats = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{});
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
    const stats = try drawMesh(&s.target, quadMesh(), transform.identity(), orthoSetup(), red, .{});
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
    const culled = try drawMesh(&a.target, mesh, transform.identity(), orthoSetup(), red, .{});
    try testing.expectEqual(@as(usize, 2), culled.culled);
    try testing.expectEqual(@as(usize, 0), culled.pixels);
    var b = try TestSurface.init(8, 8);
    defer b.deinit();
    const drawn = try drawMesh(&b.target, mesh, transform.identity(), orthoSetup(), red, .{ .cull = .none });
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
    const stats = try drawMesh(&s.target, quadMesh(), world, orthoSetup(), red, .{});
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
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{});
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
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{});
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
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{});
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
    _ = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{});
    for (s.depth) |d| try testing.expect(std.math.isFinite(d));
}

test "drawMesh: a huge off-screen triangle is clipped to the viewport" {
    var s = try TestSurface.init(8, 8);
    defer s.deinit();
    const positions = [_][3]f32{ .{ -1000, -1000, -2 }, .{ 1000, -1000, -2 }, .{ 0, 1000, -2 } };
    const indices = [_]u32{ 0, 1, 2 };
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), orthoSetup(), red, .{});
    try testing.expectEqual(@as(usize, 64), stats.pixels);
    try testing.expectEqual(@as(usize, 64), s.covered());
}

test "drawMesh: rejects malformed index buffers" {
    var s = try TestSurface.init(4, 4);
    defer s.deinit();
    const short = [_]u32{ 0, 1 };
    try testing.expectError(error.InvalidIndex, drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &short }, transform.identity(), orthoSetup(), red, .{}));
    const oob = [_]u32{ 0, 1, 99 };
    try testing.expectError(error.InvalidIndex, drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &oob }, transform.identity(), orthoSetup(), red, .{}));
    const empty = try drawMesh(&s.target, .{ .positions = &quad_positions, .indices = &.{} }, transform.identity(), orthoSetup(), red, .{});
    try testing.expectEqual(@as(usize, 0), empty.submitted);
}

/// Minimal resource provider: handles index directly into slices. This is the
/// whole adaptation cost a caller pays, and it keeps `render` independent of the
/// asset layer.
const SliceResources = struct {
    meshes: []const Mesh,
    colors: []const [4]f32,

    fn mesh(self: SliceResources, handle: u32) ?Mesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    fn color(self: SliceResources, handle: u32) ?[4]f32 {
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
        .{ .{ -100, -100, -2, 1 }, .{ 100, -100, 0.5, 1 }, .{ 0, 100, 3, 1 } },
        // Crosses the four sides and the far plane.
        .{ .{ -3, -3, -1, 2 }, .{ 3, -3, -1, 2 }, .{ 0, 3, 5, 2 } },
        // Crosses only the four sides.
        .{ .{ -50, 0, -1, 2 }, .{ 50, -50, -1, 2 }, .{ 0, 50, -1, 2 } },
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
    const stats = try drawMesh(&s.target, .{ .positions = &positions, .indices = &indices }, transform.identity(), cam.view_projection, red, .{});
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
        const drew = rasterTriangle(&s.target, tri[0], tri[1], tri[2], red, options, &pixels);
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
