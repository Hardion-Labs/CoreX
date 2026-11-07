//! Conservative software occlusion culling for the render extraction layer.
//!
//! Extraction already rejects what the frustum excludes. What it could not reject
//! is geometry that is *inside* the frustum but completely hidden behind something
//! nearer — the wall in front of the room. This module answers that question with a
//! coarse **tile depth buffer** built from the frame's own large occluders, and it
//! answers it **conservatively**: it may keep a hidden object (a missed cull, only
//! cost) and it must never drop a visible one.
//!
//! ## How a tile is claimed
//!
//! An occluder is a world-space `Aabb`. The 8 corners are projected to NDC; if any
//! corner is behind the near plane the box is rejected outright (its projection is
//! not a bounded convex set). The remaining 8 points are reduced to their convex
//! hull — perspective projection maps a convex body in front of the camera onto a
//! convex polygon — and a tile is claimed by the occluder only when **all four of
//! its corners lie inside that hull**. A partially covered tile is never claimed,
//! so the buffer never invents coverage that is not there.
//!
//! The depth stored for a claimed tile is the **maximum** NDC `z` over the box's
//! corners: every point of the box in that tile is at least that near, so a tested
//! object whose *nearest* point is farther than that bound is behind the occluder
//! everywhere in the tile. Using the box-wide maximum (rather than a per-tile
//! slice) is conservative and cheap; it only makes culls less likely.
//!
//! ## How a tile is tested
//!
//! The tested bound is projected the same way; its screen rectangle is the
//! conservative `floor`/`ceil` tile span of its 8 projected corners, and its depth
//! is the **minimum** corner NDC `z` (the nearest point of the object). The object
//! is occluded only when **every** tile of that rectangle is claimed by an occluder
//! whose bound is nearer than the object's nearest point minus `depth_bias`.
//!
//! Everything here is pure CPU math over a caller-owned buffer: no allocation in
//! `add`/`isOccluded`, no hidden state, no frame history (this is *not* temporal
//! reprojection, which would need the previous frame's depth and its own
//! correctness story).

const std = @import("std");
const dbg = false;
const transform = @import("../scene/transform.zig");

const Mat4 = transform.Mat4;
const Vec3 = transform.Vec3;

/// NDC `z` range of the pipeline: near is -1, far is +1, and smaller is nearer.
pub const ndc_near: f32 = -1.0;
pub const ndc_far: f32 = 1.0;

/// A tile depth buffer over the screen, in NDC units.
///
/// The buffer is **borrowed**: `init` allocates once and `deinit` frees, but
/// `clear`/`add`/`isOccluded` never allocate, so a frame loop can keep one buffer
/// and reset it per frame.
pub const Buffer = struct {
    tiles_x: u16,
    tiles_y: u16,
    /// `tiles_x * tiles_y` entries, row-major: the farthest depth an occluder
    /// bound covers that tile with, or `empty` when nothing was claimed.
    depths: []f32,

    /// Sentinel for "no occluder here". Larger than any NDC `z`, so it never
    /// occludes and never compares as nearer.
    pub const empty: f32 = std.math.inf(f32);

    pub fn init(gpa: std.mem.Allocator, tiles_x: u16, tiles_y: u16) !Buffer {
        if (tiles_x == 0 or tiles_y == 0) return error.InvalidGrid;
        const depths = try gpa.alloc(f32, @as(usize, tiles_x) * tiles_y);
        @memset(depths, empty);
        return .{ .tiles_x = tiles_x, .tiles_y = tiles_y, .depths = depths };
    }

    pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
        gpa.free(self.depths);
        self.* = undefined;
    }

    pub fn tileCount(self: Buffer) usize {
        return self.depths.len;
    }

    /// Forget every claim. Called once per frame before the occluder pass.
    pub fn clear(self: *Buffer) void {
        @memset(self.depths, empty);
    }

    /// Claim the tiles this bound covers in full. A bound that cannot be projected
    /// (behind the near plane, or with a degenerate hull) claims nothing.
    pub fn add(self: *Buffer, view_projection: Mat4, b: Aabb) void {
        const proj = projectAabb(view_projection, b) orelse return;
        var hull = Hull.fromPoints(proj.corners) orelse return;
        if (@import("builtin").is_test and dbg) std.debug.print("ADD hull={any}\n", .{hull.points[0..hull.len]});
        if (!hull.isConvexCcw()) hull.reverse();
        const span = tileSpan(self.*, proj);
        if (@import("builtin").is_test and dbg) std.debug.print("ADD span {any} ccw={}\n", .{ span, hull.isConvexCcw() });
        if (span.isEmpty()) return;
        const farthest = proj.farthest;
        var ty: u32 = span.min_y;
        while (ty <= span.max_y) : (ty += 1) {
            var tx: u32 = span.min_x;
            while (tx <= span.max_x) : (tx += 1) {
                if (!hull.coversTile(self.*, tx, ty)) {
                    if (@import("builtin").is_test and dbg) {
                        const p0 = [2]f32{ -1.0 + @as(f32, @floatFromInt(tx)) * (2.0 / @as(f32, @floatFromInt(self.tiles_x))), -1.0 + @as(f32, @floatFromInt(ty)) * (2.0 / @as(f32, @floatFromInt(self.tiles_y))) };
                        var k: usize = 0;
                        while (k < hull.len) : (k += 1) std.debug.print("   v{} cross={d}\n", .{ k, cross(hull.points[k], hull.points[(k + 1) % hull.len], p0) });
                        std.debug.print("  miss tile {} {} p={any} len={d}\n", .{ tx, ty, p0, hull.len });
                    }
                    continue;
                }
                const i = @as(usize, ty) * self.tiles_x + tx;
                // Keep the largest claimed depth: "the occluder is at most this
                // far in this tile" is the safe direction for a later test. An
                // unclaimed tile takes the value outright — `empty` is +infinity,
                // so a plain `max` would never replace it.
                if (self.depths[i] == empty or farthest > self.depths[i]) self.depths[i] = farthest;
            }
        }
    }

    /// Whether `b` is entirely hidden by what has been claimed so far.
    ///
    /// `depth_bias` is subtracted from the object's nearest depth before the
    /// comparison, which keeps co-planar and z-fighting geometry visible: a cull
    /// that is not certain is not a cull.
    pub fn isOccluded(self: Buffer, view_projection: Mat4, b: Aabb, depth_bias: f32) bool {
        const proj = projectAabb(view_projection, b) orelse return false;
        const span = tileSpan(self, proj);
        if (span.isEmpty()) return false;
        // Never cull something that could be near or outside the depth range: an
        // object touching either end cannot be proven to be behind anything.
        if (!(proj.nearest > ndc_near) or !(proj.nearest < ndc_far)) return false;
        const limit = proj.nearest - @max(depth_bias, 0.0);
        var ty: u32 = span.min_y;
        while (ty <= span.max_y) : (ty += 1) {
            var tx: u32 = span.min_x;
            while (tx <= span.max_x) : (tx += 1) {
                const d = self.depths[@as(usize, ty) * self.tiles_x + tx];
                // `empty` is +inf, which never satisfies this, so an unclaimed tile
                // always keeps the object.
                if (!(d < limit)) return false;
            }
        }
        return true;
    }

    /// How many tiles the projection of `b` touches, or null when it cannot be
    /// projected at all. This is the screen footprint a caller uses to decide
    /// whether a bound is a large enough occluder to be worth claiming tiles for.
    pub fn tileCoverage(self: Buffer, view_projection: Mat4, b: Aabb) ?u32 {
        const proj = projectAabb(view_projection, b) orelse return null;
        const span = tileSpan(self, proj);
        if (span.isEmpty()) return null;
        return (span.max_x - span.min_x + 1) * (span.max_y - span.min_y + 1);
    }

    /// Number of claimed tiles. Diagnostics for tests and logs, not a heuristic.
    pub fn claimedCount(self: Buffer) usize {
        var n: usize = 0;
        for (self.depths) |d| {
            if (d != empty) n += 1;
        }
        return n;
    }
};

/// A bound transformed to NDC: the 8 projected corners plus the depth extremes.
pub const Projected = struct {
    /// Corner `i` is `(x, y, z, 1, 1, 1, 1, 1)`: `x = 0` means `min_x`, `1` means
    /// `max_x`, and so on for `y` (1) and `z` (2). Kept as plain data so the hull is
    /// a pure function of these points.
    corners: [8][2]f32,
    nearest: f32,
    farthest: f32,
};

/// The tile span a projected bound touches, clamped to the grid.
const Span = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    fn isEmpty(self: Span) bool {
        return self.min_x > self.max_x or self.min_y > self.max_y;
    }
};

fn tileSpan(buf: Buffer, proj: Projected) Span {
    var lo_x: f32 = proj.corners[0][0];
    var hi_x = lo_x;
    var lo_y: f32 = proj.corners[0][1];
    var hi_y = lo_y;
    for (proj.corners[1..]) |c| {
        lo_x = @min(lo_x, c[0]);
        hi_x = @max(hi_x, c[0]);
        lo_y = @min(lo_y, c[1]);
        hi_y = @max(hi_y, c[1]);
    }
    // NDC [-1, 1] maps onto [0, tiles). `floor` on the low end and `ceil` on the
    // high end make the span a superset of every tile the bound touches.
    const tx: f32 = @floatFromInt(buf.tiles_x);
    const ty: f32 = @floatFromInt(buf.tiles_y);
    const fx0 = std.math.floor((lo_x + 1.0) * 0.5 * tx);
    const fx1 = std.math.ceil((hi_x + 1.0) * 0.5 * tx);
    const fy0 = std.math.floor((lo_y + 1.0) * 0.5 * ty);
    const fy1 = std.math.ceil((hi_y + 1.0) * 0.5 * ty);
    if (!std.math.isFinite(fx0) or !std.math.isFinite(fx1) or
        !std.math.isFinite(fy0) or !std.math.isFinite(fy1)) return .{ .min_x = 1, .min_y = 0, .max_x = 0, .max_y = 0 };
    const max_x: f32 = @floatFromInt(buf.tiles_x - 1);
    const max_y: f32 = @floatFromInt(buf.tiles_y - 1);
    const cx0 = std.math.clamp(fx0, 0.0, max_x + 1.0);
    const cx1 = std.math.clamp(fx1, -1.0, max_x);
    const cy0 = std.math.clamp(fy0, 0.0, max_y + 1.0);
    const cy1 = std.math.clamp(fy1, -1.0, max_y);
    if (!(cx1 >= cx0) or !(cy1 >= cy0)) return .{ .min_x = 1, .min_y = 0, .max_x = 0, .max_y = 0 };
    return .{
        .min_x = @intFromFloat(cx0),
        .min_y = @intFromFloat(cy0),
        .max_x = @intFromFloat(cx1),
        .max_y = @intFromFloat(cy1),
    };
}

/// Project all 8 corners of `b`. Returns null when any corner is at or behind the
/// near plane (`w <= 0`, where the perspective division is meaningless) or outside
/// the `[-1, 1]` NDC depth range — a bound that intersects either clip plane has no
/// bounded projection and must neither claim tiles nor be culled.
///
/// The `w` test alone would not catch an orthographic camera: its `w` is always 1,
/// so a box sitting behind the eye would still "project". The depth test catches
/// both, because NDC `z` is monotone in view depth in every projection.
pub fn projectAabb(m: Mat4, b: Aabb) ?Projected {
    var proj: Projected = undefined;
    var nearest: f32 = std.math.inf(f32);
    var farthest: f32 = -std.math.inf(f32);
    var i: usize = 0;
    for (0..2) |kz| {
        for (0..2) |ky| {
            for (0..2) |kx| {
                const p = Vec3{
                    if (kx == 0) b.center[0] - b.extents[0] else b.center[0] + b.extents[0],
                    if (ky == 0) b.center[1] - b.extents[1] else b.center[1] + b.extents[1],
                    if (kz == 0) b.center[2] - b.extents[2] else b.center[2] + b.extents[2],
                };
                const clip = clipPoint(m, p);
                if (!(clip[3] > 1e-6)) return null;
                const inv_w = 1.0 / clip[3];
                const nx = clip[0] * inv_w;
                const ny = clip[1] * inv_w;
                const nz = clip[2] * inv_w;
                if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) return null;
                if (nz < ndc_near or nz > ndc_far) return null;
                proj.corners[i] = .{ nx, ny };
                nearest = @min(nearest, nz);
                farthest = @max(farthest, nz);
                i += 1;
            }
        }
    }
    proj.nearest = nearest;
    proj.farthest = farthest;
    return proj;
}

fn clipPoint(m: Mat4, p: Vec3) [4]f32 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
        m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15],
    };
}

/// Convex hull of at most 8 projected points, in the order used by the coverage
/// test. Fixed capacity: the input is always a box.
const Hull = struct {
    points: [8][2]f32 = undefined,
    len: u8 = 0,

    const eps: f32 = 1e-6;

    /// Andrew's monotone chain over the 8 corners, deduplicated.
    fn fromPoints(pts: [8][2]f32) ?Hull {
        var sorted = pts;
        // Insertion sort: 8 points, and it keeps the routine allocation-free.
        for (1..sorted.len) |i| {
            const key = sorted[i];
            var j = i;
            while (j > 0 and lessThan(sorted[j - 1], key)) : (j -= 1) {
                sorted[j] = sorted[j - 1];
            }
            sorted[j] = key;
        }
        var unique: [8][2]f32 = undefined;
        var n: usize = 0;
        for (sorted) |p| {
            if (n != 0 and samePoint(unique[n - 1], p)) continue;
            unique[n] = p;
            n += 1;
        }
        if (n < 3) return null;

        var hull: [16][2]f32 = undefined;
        var k: usize = 0;
        for (unique[0..n], 0..) |p, idx| {
            _ = idx;
            while (k >= 2 and cross(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
            hull[k] = p;
            k += 1;
        }
        const lower = k + 1;
        var i: usize = n - 1;
        while (i > 0) : (i -= 1) {
            const p = unique[i - 1];
            while (k >= lower and cross(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
            hull[k] = p;
            k += 1;
        }
        // The last point repeats the first.
        k -= 1;
        if (k < 3 or k > 8) return null;
        var out: Hull = .{};
        for (0..k) |j| out.points[j] = hull[j];
        out.len = @intCast(k);
        return out;
    }

    fn isConvexCcw(self: Hull) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const a = self.points[i];
            const b = self.points[(i + 1) % self.len];
            const c = self.points[(i + 2) % self.len];
            if (cross(a, b, c) < -eps) return false;
        }
        return true;
    }

    fn reverse(self: *Hull) void {
        std.mem.reverse([2]f32, self.points[0..self.len]);
    }

    /// Whether the hull contains the whole tile `(tx, ty)` — all four tile corners
    /// inside, which is the only case where full coverage is certain.
    fn coversTile(self: Hull, buf: Buffer, tx: u32, ty: u32) bool {
        const tx_f: f32 = @floatFromInt(tx);
        const ty_f: f32 = @floatFromInt(ty);
        const sx = 2.0 / @as(f32, @floatFromInt(buf.tiles_x));
        const sy = 2.0 / @as(f32, @floatFromInt(buf.tiles_y));
        for (0..2) |cy| {
            for (0..2) |cx| {
                const p = [2]f32{
                    -1.0 + (tx_f + @as(f32, @floatFromInt(cx))) * sx,
                    -1.0 + (ty_f + @as(f32, @floatFromInt(cy))) * sy,
                };
                if (!self.contains(p)) return false;
            }
        }
        return true;
    }

    fn contains(self: Hull, p: [2]f32) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const a = self.points[i];
            const b = self.points[(i + 1) % self.len];
            if (cross(a, b, p) < -eps) return false;
        }
        return true;
    }
};

fn cross(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn samePoint(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) <= Hull.eps and @abs(a[1] - b[1]) <= Hull.eps;
}

fn lessThan(a: [2]f32, b: [2]f32) bool {
    if (a[0] != b[0]) return a[0] > b[0];
    return a[1] > b[1];
}

/// Axis-aligned box, re-exported so callers do not need two imports.
pub const Aabb = @import("culling.zig").Aabb;

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const camera = @import("camera.zig");

fn ortho() Mat4 {
    return camera.orthographic(-4, 4, -4, 4, 0.1, 100);
}

fn perspective() Mat4 {
    return camera.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 100);
}

fn box(center: Vec3, extents: Vec3) Aabb {
    return .{ .center = center, .extents = extents };
}

test "occlusion: a wall in front hides what is behind it and nothing else" {
    // 32x18 tiles over a 16:9 screen. The wall is a large box 10 units away; the
    // hidden object is directly behind it, the visible one is beside it.
    var buf = try Buffer.init(testing.allocator, 32, 18);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    buf.add(m, box(.{ 0, 0, -10 }, .{ 3, 2, 0.5 }));
    try testing.expect(buf.claimedCount() > 0);

    // Directly behind the wall, small enough to sit inside its tiles.
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -20 }, .{ 0.2, 0.2, 0.2 }), 0.0));
    // Beside the wall: not occluded, because its tiles are not all claimed.
    try testing.expect(!buf.isOccluded(m, box(.{ 3.6, 0, -20 }, .{ 0.2, 0.2, 0.2 }), 0.0));
    // In front of the wall: never occluded.
    try testing.expect(!buf.isOccluded(m, box(.{ 0, 0, -2 }, .{ 0.2, 0.2, 0.2 }), 0.0));
    // Bigger than the wall: it pokes out of the claimed tiles.
    try testing.expect(!buf.isOccluded(m, box(.{ 0, 0, -20 }, .{ 3.5, 2.5, 0.5 }), 0.0));
}

test "occlusion: clipping and degenerate bounds are never culled" {
    var buf = try Buffer.init(testing.allocator, 16, 9);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    buf.add(m, box(.{ 0, 0, -10 }, .{ 3, 2, 0.5 }));

    // A bound straddling the near plane has no bounded projection: it must not be
    // culled, and (below) it must not claim tiles either.
    try testing.expect(!buf.isOccluded(m, box(.{ 0, 0, 5 }, .{ 1, 1, 10 }), 0.0));
    // Zero-extent bounds inside a claimed tile are cullable: it is a point, and the
    // point is behind the occluder.
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -20 }, .{ 0, 0, 0 }), 0.0));
    // An unclaimed (never written) tile keeps everything.
    var fresh = try Buffer.init(testing.allocator, 16, 9);
    defer fresh.deinit(testing.allocator);
    try testing.expect(!fresh.isOccluded(m, box(.{ 0, 0, -20 }, .{ 0.2, 0.2, 0.2 }), 0.0));
    // A bound straddling the near plane claims nothing.
    fresh.add(m, box(.{ 0, 0, 5 }, .{ 1, 1, 10 }));
    try testing.expectEqual(@as(usize, 0), fresh.claimedCount());
    // Outside the screen entirely: nothing claimed, nothing culled.
    fresh.add(m, box(.{ 100, 100, -10 }, .{ 1, 1, 1 }));
    try testing.expectEqual(@as(usize, 0), fresh.claimedCount());
}

test "occlusion: only fully covered tiles are claimed, so the cull stays conservative" {
    // A grid fine enough that the occluder's edge falls inside a tile: that edge
    // tile must stay unclaimed, and an object centred on it must survive.
    var buf = try Buffer.init(testing.allocator, 64, 36);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    // Half-width 3.0 over an 8-unit-wide view: the wall ends at x = 3, which lands
    // inside a tile rather than on its boundary.
    buf.add(m, box(.{ 0, 0, -10 }, .{ 3.0, 2.0, 0.5 }));

    const edge_x: f32 = 3.0 - 1.0 / 64.0 * 8.0;
    try testing.expect(!buf.isOccluded(m, box(.{ edge_x, 0, -20 }, .{ 0.01, 0.01, 0.01 }), 0.0));
    // Well inside, the same object is hidden.
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -20 }, .{ 0.01, 0.01, 0.01 }), 0.0));
}

test "occlusion: the depth bias keeps near-coplanar geometry visible" {
    var buf = try Buffer.init(testing.allocator, 32, 18);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    buf.add(m, box(.{ 0, 0, -10 }, .{ 3, 2, 0.5 }));
    // 0.4 units behind the wall's far face: cullable without a bias.
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -10.95 }, .{ 0.2, 0.2, 0.2 }), 0.0));
    // The bias is in NDC z. With a bias larger than the depth separation the same
    // object is kept: uncertainty resolves to "visible".
    try testing.expect(!buf.isOccluded(m, box(.{ 0, 0, -10.95 }, .{ 0.2, 0.2, 0.2 }), 1.0));
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -30 }, .{ 0.2, 0.2, 0.2 }), 0.05));
}

test "occlusion: a perspective projection claims the near wall it sees" {
    // A tighter near plane than the shared fixture: with `near = 0.1`, 20 and 40
    // units both land within a couple of thousandths of NDC 1, so no bias could
    // separate them and the test would be measuring float precision, not the cull.
    const m = camera.perspective(std.math.pi / 4.0, 16.0 / 9.0, 5.0, 100);
    var buf = try Buffer.init(testing.allocator, 48, 27);
    defer buf.deinit(testing.allocator);
    // 20 units out, filling most of the view; the piece behind its centre is hidden.
    buf.add(m, box(.{ 0, 0, -20 }, .{ 6, 4, 0.5 }));
    try testing.expect(buf.claimedCount() > 0);
    try testing.expect(buf.isOccluded(m, box(.{ 0, 0, -40 }, .{ 0.5, 0.5, 0.5 }), 0.001));
    // Off to the side, still inside the frustum (NDC x 0.85) but clear of the
    // wall's silhouette (which ends at NDC x 0.41): visible.
    try testing.expect(!buf.isOccluded(m, box(.{ 25, 0, -40 }, .{ 0.5, 0.5, 0.5 }), 0.001));
}

test "occlusion: tileCoverage reports the projected footprint" {
    var buf = try Buffer.init(testing.allocator, 32, 18);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    // A 3x3 box in an 8x8 view over 32x18 tiles: 3/8 of the width is 12 tiles,
    // 3/8 of the height is 6.75 -> 7 rows with the conservative ceil.
    const big = buf.tileCoverage(m, box(.{ 0, 0, -10 }, .{ 3, 3, 0.5 })).?;
    const small = buf.tileCoverage(m, box(.{ 0, 0, -10 }, .{ 0.25, 0.25, 0.5 })).?;
    try testing.expect(big > small);
    try testing.expect(small >= 1);
    // A bound behind the eye has no footprint at all.
    try testing.expectEqual(@as(?u32, null), buf.tileCoverage(m, box(.{ 0, 0, 50 }, .{ 1, 1, 1 })));
}

test "occlusion: clear forgets every claim and the grid rejects empty axes" {
    var buf = try Buffer.init(testing.allocator, 8, 8);
    defer buf.deinit(testing.allocator);
    const m = ortho();
    buf.add(m, box(.{ 0, 0, -10 }, .{ 3, 3, 0.5 }));
    try testing.expect(buf.claimedCount() > 0);
    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.claimedCount());
    try testing.expect(!buf.isOccluded(m, box(.{ 0, 0, -20 }, .{ 0.2, 0.2, 0.2 }), 0.0));

    try testing.expectError(error.InvalidGrid, Buffer.init(testing.allocator, 0, 8));
    try testing.expectError(error.InvalidGrid, Buffer.init(testing.allocator, 8, 0));
}
