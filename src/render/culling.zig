//! Frustum culling primitives for the render extraction layer.
//!
//! Provides axis-aligned bounding boxes (`Aabb`), spheres, planes and a
//! `Frustum` extracted from a view-projection matrix (Gribb–Hartmann method),
//! plus conservative classification of bounds against the frustum. All pure
//! CPU math, backend-independent and fully testable headlessly.
//!
//! Plane convention: a point `p` is on the inside (positive half-space) when
//! `dot(normal, p) + d >= 0`. Planes are normalized so `distanceToPoint` returns
//! a signed Euclidean distance.

const std = @import("std");
const transform = @import("../scene/transform.zig");

const Mat4 = transform.Mat4;
const Vec3 = transform.Vec3;

/// Axis-aligned bounding box defined by a center and half-extents.
pub const Aabb = struct {
    center: Vec3 = .{ 0, 0, 0 },
    extents: Vec3 = .{ 0, 0, 0 },

    pub fn fromMinMax(mn: Vec3, mx: Vec3) Aabb {
        return .{
            .center = transform.scale(transform.add(mn, mx), 0.5),
            .extents = transform.scale(transform.sub(mx, mn), 0.5),
        };
    }

    pub fn min(self: Aabb) Vec3 {
        return transform.sub(self.center, self.extents);
    }

    pub fn max(self: Aabb) Vec3 {
        return transform.add(self.center, self.extents);
    }
};

/// Bounding sphere.
pub const Sphere = struct {
    center: Vec3 = .{ 0, 0, 0 },
    radius: f32 = 0,
};

/// A plane `dot(normal, p) + d = 0`; inside is `>= 0`.
pub const Plane = struct {
    normal: Vec3,
    d: f32,

    pub fn normalized(self: Plane) Plane {
        const len = transform.length(self.normal);
        if (len < 1e-8) return self;
        const inv = 1.0 / len;
        return .{ .normal = transform.scale(self.normal, inv), .d = self.d * inv };
    }

    pub fn distanceToPoint(self: Plane, p: Vec3) f32 {
        return transform.dot(self.normal, p) + self.d;
    }
};

/// Result of testing bounds against a frustum.
pub const Classification = enum {
    /// Fully outside at least one plane — safe to cull.
    outside,
    /// Straddles at least one plane — partially visible.
    intersecting,
    /// Fully inside every plane.
    inside,
};

/// The six clip planes of a view-projection frustum.
pub const Frustum = struct {
    planes: [6]Plane,

    pub const left = 0;
    pub const right = 1;
    pub const bottom = 2;
    pub const top = 3;
    pub const near = 4;
    pub const far = 5;

    /// Extract normalized planes from a column-major view-projection matrix
    /// (Gribb–Hartmann). `clip = m * world` (column vector).
    pub fn fromMat4(m: Mat4) Frustum {
        var planes: [6]Plane = undefined;
        // left = row3 + row0
        planes[left] = (Plane{ .normal = .{ m[3] + m[0], m[7] + m[4], m[11] + m[8] }, .d = m[15] + m[12] }).normalized();
        // right = row3 - row0
        planes[right] = (Plane{ .normal = .{ m[3] - m[0], m[7] - m[4], m[11] - m[8] }, .d = m[15] - m[12] }).normalized();
        // bottom = row3 + row1
        planes[bottom] = (Plane{ .normal = .{ m[3] + m[1], m[7] + m[5], m[11] + m[9] }, .d = m[15] + m[13] }).normalized();
        // top = row3 - row1
        planes[top] = (Plane{ .normal = .{ m[3] - m[1], m[7] - m[5], m[11] - m[9] }, .d = m[15] - m[13] }).normalized();
        // near = row3 + row2
        planes[near] = (Plane{ .normal = .{ m[3] + m[2], m[7] + m[6], m[11] + m[10] }, .d = m[15] + m[14] }).normalized();
        // far = row3 - row2
        planes[far] = (Plane{ .normal = .{ m[3] - m[2], m[7] - m[6], m[11] - m[10] }, .d = m[15] - m[14] }).normalized();
        return .{ .planes = planes };
    }

    pub fn classifyAabb(self: Frustum, b: Aabb) Classification {
        const mn = b.min();
        const mx = b.max();
        var all_inside = true;
        for (self.planes) |p| {
            // Positive vertex: the corner furthest along the plane normal.
            const pv = Vec3{
                if (p.normal[0] >= 0) mx[0] else mn[0],
                if (p.normal[1] >= 0) mx[1] else mn[1],
                if (p.normal[2] >= 0) mx[2] else mn[2],
            };
            if (p.distanceToPoint(pv) < 0) return .outside;
            // Negative vertex: if it is outside any plane, the box straddles.
            const nv = Vec3{
                if (p.normal[0] >= 0) mn[0] else mx[0],
                if (p.normal[1] >= 0) mn[1] else mx[1],
                if (p.normal[2] >= 0) mn[2] else mx[2],
            };
            if (p.distanceToPoint(nv) < 0) all_inside = false;
        }
        return if (all_inside) .inside else .intersecting;
    }

    pub fn classifySphere(self: Frustum, s: Sphere) Classification {
        var all_inside = true;
        for (self.planes) |p| {
            const dist = p.distanceToPoint(s.center);
            if (dist < -s.radius) return .outside;
            if (dist < s.radius) all_inside = false;
        }
        return if (all_inside) .inside else .intersecting;
    }
};

/// Conservatively transform a local AABB by a matrix into a world AABB (Arvo's
/// method): transform the center, and scale the extents by the absolute values
/// of the linear part. The result encloses the transformed box under rotation
/// and non-uniform scale.
pub fn transformAabb(m: Mat4, b: Aabb) Aabb {
    const center = transform.transformPoint(m, b.center);
    var extents = Vec3{ 0, 0, 0 };
    inline for (0..3) |i| {
        inline for (0..3) |j| {
            extents[i] += @abs(m[j * 4 + i]) * b.extents[j];
        }
    }
    return .{ .center = center, .extents = extents };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const eps = 1e-4;

test "aabb: fromMinMax / min / max round-trip" {
    const b = Aabb.fromMinMax(.{ -1, -2, -3 }, .{ 1, 2, 3 });
    try testing.expectApproxEqAbs(@as(f32, 0), b.center[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 2), b.extents[1], eps);
    try testing.expectApproxEqAbs(@as(f32, -3), b.min()[2], eps);
    try testing.expectApproxEqAbs(@as(f32, 3), b.max()[2], eps);
}

test "plane: normalized distance is signed Euclidean" {
    const p = (Plane{ .normal = .{ 2, 0, 0 }, .d = 2 }).normalized();
    try testing.expectApproxEqAbs(@as(f32, 1), p.normal[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), p.d, eps);
    try testing.expectApproxEqAbs(@as(f32, 3), p.distanceToPoint(.{ 2, 0, 0 }), eps);
    try testing.expectApproxEqAbs(@as(f32, -1), p.distanceToPoint(.{ -2, 0, 0 }), eps);
}

test "frustum: identity matrix yields the NDC cube [-1,1]^3" {
    const f = Frustum.fromMat4(transform.identity());
    // Center is inside; a point beyond +X is outside.
    try testing.expectEqual(Classification.inside, f.classifySphere(.{ .center = .{ 0, 0, 0 }, .radius = 0.1 }));
    try testing.expectEqual(Classification.outside, f.classifySphere(.{ .center = .{ 2, 0, 0 }, .radius = 0.1 }));
    // Left plane normal points +X with d=1 (x >= -1 is inside).
    try testing.expectApproxEqAbs(@as(f32, 1), f.planes[Frustum.left].normal[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), f.planes[Frustum.left].d, eps);
}

test "frustum: classifies aabb inside / intersecting / outside" {
    const f = Frustum.fromMat4(transform.identity());
    try testing.expectEqual(Classification.inside, f.classifyAabb(Aabb{ .center = .{ 0, 0, 0 }, .extents = .{ 0.5, 0.5, 0.5 } }));
    try testing.expectEqual(Classification.intersecting, f.classifyAabb(Aabb{ .center = .{ 1, 0, 0 }, .extents = .{ 0.5, 0.5, 0.5 } }));
    try testing.expectEqual(Classification.outside, f.classifyAabb(Aabb{ .center = .{ 3, 0, 0 }, .extents = .{ 0.5, 0.5, 0.5 } }));
}

test "frustum: classifies sphere inside / intersecting / outside" {
    const f = Frustum.fromMat4(transform.identity());
    try testing.expectEqual(Classification.inside, f.classifySphere(.{ .center = .{ 0, 0, 0 }, .radius = 0.5 }));
    try testing.expectEqual(Classification.intersecting, f.classifySphere(.{ .center = .{ 1, 0, 0 }, .radius = 0.5 }));
    try testing.expectEqual(Classification.outside, f.classifySphere(.{ .center = .{ 3, 0, 0 }, .radius = 0.5 }));
}

test "frustum: a real perspective camera culls behind and to the side" {
    const camera = @import("camera.zig");
    const cam = camera.Camera.perspectiveLookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
    const f = Frustum.fromMat4(cam.view_projection);
    // Origin (the look target) is in front -> visible.
    try testing.expect(f.classifySphere(.{ .center = .{ 0, 0, 0 }, .radius = 0.5 }) != .outside);
    // Behind the camera -> culled.
    try testing.expectEqual(Classification.outside, f.classifySphere(.{ .center = .{ 0, 0, 10 }, .radius = 0.5 }));
    // Far to the side -> culled.
    try testing.expectEqual(Classification.outside, f.classifySphere(.{ .center = .{ 50, 0, 0 }, .radius = 0.5 }));
    // Beyond the far plane -> culled.
    try testing.expectEqual(Classification.outside, f.classifySphere(.{ .center = .{ 0, 0, -200 }, .radius = 0.5 }));
}

test "transformAabb: identity, translation and scale" {
    const b = Aabb{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 1 } };
    const id = transformAabb(transform.identity(), b);
    try testing.expectApproxEqAbs(@as(f32, 1), id.extents[0], eps);

    const moved = transformAabb(transform.fromTransform(.{ .position = .{ 5, 0, 0 } }), b);
    try testing.expectApproxEqAbs(@as(f32, 5), moved.center[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), moved.extents[0], eps);

    const scaled = transformAabb(transform.fromTransform(.{ .scale = .{ 2, 3, 4 } }), b);
    try testing.expectApproxEqAbs(@as(f32, 2), scaled.extents[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 3), scaled.extents[1], eps);
    try testing.expectApproxEqAbs(@as(f32, 4), scaled.extents[2], eps);
}

test "transformAabb: rotation yields a conservative enclosing box" {
    // Rotate a unit box 45deg about Z; the world AABB must enclose all 8 corners.
    const b = Aabb{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 1 } };
    const q = transform.quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 4.0);
    const m = transform.fromTransform(.{ .rotation = q });
    const wb = transformAabb(m, b);
    // Each original corner, transformed, must lie within the world AABB.
    for ([_]f32{ -1, 1 }) |x| {
        for ([_]f32{ -1, 1 }) |y| {
            for ([_]f32{ -1, 1 }) |z| {
                const p = transform.transformPoint(m, .{ x, y, z });
                inline for (0..3) |i| {
                    try testing.expect(p[i] >= wb.min()[i] - eps);
                    try testing.expect(p[i] <= wb.max()[i] + eps);
                }
            }
        }
    }
    // 45deg rotation of a unit square gives half-extent sqrt(2) in x and y.
    try testing.expectApproxEqAbs(@as(f32, @sqrt(2.0)), wb.extents[0], eps);
    try testing.expectApproxEqAbs(@as(f32, @sqrt(2.0)), wb.extents[1], eps);
}
