//! Backend-independent camera math for the render extraction layer.
//!
//! Builds view and projection matrices (column-major `Mat4`, right-handed,
//! camera looks down -Z, OpenGL-style clip space with NDC z in [-1, 1]) and
//! combines them into a `Camera`. This is pure CPU math — it does not depend on
//! any GPU API, so it is fully testable headlessly and is shared by every
//! renderer tier (Low/Medium/Advanced).
//!
//! Depends only on the scene transform math (`Mat4`, `Vec3`, vector helpers),
//! keeping coupling low.

const std = @import("std");
const transform = @import("../scene/transform.zig");

const Mat4 = transform.Mat4;
const Vec3 = transform.Vec3;

pub const Error = error{
    /// The projection parameters are degenerate or non-finite (e.g. `near == far`,
    /// `right == left`, negative aspect). Projection would divide by zero or
    /// produce NaN, so the matrix is rejected instead of silently breaking
    /// culling and rasterization downstream.
    InvalidFrustum,
};

/// Right-handed perspective projection (OpenGL clip space, NDC z in [-1, 1]).
/// `fov_y` is the vertical field of view in radians; `aspect` is width/height;
/// `near`/`far` are positive plane distances with `near < far`.
pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Error!Mat4 {
    if (!std.math.isFinite(fov_y) or fov_y <= 0 or fov_y >= std.math.pi) return error.InvalidFrustum;
    if (!std.math.isFinite(aspect) or aspect <= 0) return error.InvalidFrustum;
    if (!std.math.isFinite(near) or !std.math.isFinite(far) or near <= 0 or near >= far) return error.InvalidFrustum;
    const f = 1.0 / @tan(fov_y * 0.5);
    var m = std.mem.zeroes(Mat4);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = (2 * far * near) / (near - far);
    return m;
}

/// Right-handed orthographic projection (OpenGL clip space, NDC z in [-1, 1]).
pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Error!Mat4 {
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or right == left) return error.InvalidFrustum;
    if (!std.math.isFinite(bottom) or !std.math.isFinite(top) or top == bottom) return error.InvalidFrustum;
    if (!std.math.isFinite(near) or !std.math.isFinite(far) or far == near) return error.InvalidFrustum;
    var m = transform.identity();
    m[0] = 2 / (right - left);
    m[5] = 2 / (top - bottom);
    m[10] = -2 / (far - near);
    m[12] = -(right + left) / (right - left);
    m[13] = -(top + bottom) / (top - bottom);
    m[14] = -(far + near) / (far - near);
    return m;
}

/// Right-handed view matrix looking from `eye` toward `target` with the given
/// `up` hint. If `eye == target` (degenerate forward), returns the identity.
/// If `up` is parallel to the forward axis, no basis can be built from it, so
/// a fallback up from the axis least aligned with `f` is used instead of
/// emitting an all-zero basis.
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    const f = transform.normalize(transform.sub(target, eye));
    if (transform.length(f) < 1e-6) return transform.identity();
    var up_hint = up;
    if (transform.length(transform.cross(f, up_hint)) < 1e-6) {
        // World up (or whatever was passed) is parallel to the view axis:
        // pick the world axis least aligned with `f` as a stable surrogate.
        const ax = transform.Vec3{ 1, 0, 0 };
        const ay = transform.Vec3{ 0, 1, 0 };
        const az = transform.Vec3{ 0, 0, 1 };
        const afx = @abs(transform.dot(f, ax));
        const afy = @abs(transform.dot(f, ay));
        const afz = @abs(transform.dot(f, az));
        up_hint = if (afx <= afy and afx <= afz) ax else if (afy <= afz) ay else az;
    }
    const s = transform.normalize(transform.cross(f, up_hint));
    const u = transform.cross(s, f);

    var m = transform.identity();
    m[0] = s[0];
    m[4] = s[1];
    m[8] = s[2];
    m[1] = u[0];
    m[5] = u[1];
    m[9] = u[2];
    m[2] = -f[0];
    m[6] = -f[1];
    m[10] = -f[2];
    m[12] = -transform.dot(s, eye);
    m[13] = -transform.dot(u, eye);
    m[14] = transform.dot(f, eye);
    return m;
}

/// A camera combines a view and a projection matrix. `view_projection` is
/// `projection * view` (applied to a world-space column vector). `position` is
/// the world-space eye point, used for depth sorting.
pub const Camera = struct {
    view: Mat4,
    projection: Mat4,
    view_projection: Mat4,
    position: Vec3,

    pub fn init(view: Mat4, projection: Mat4, position: Vec3) Camera {
        return .{
            .view = view,
            .projection = projection,
            .view_projection = transform.multiply(projection, view),
            .position = position,
        };
    }

    /// Convenience: a perspective camera looking from `eye` at `target`.
    pub fn perspectiveLookAt(eye: Vec3, target: Vec3, up: Vec3, fov_y: f32, aspect: f32, near: f32, far: f32) Camera {
        return init(lookAt(eye, target, up), perspective(fov_y, aspect, near, far) catch unreachable, eye);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const eps = 1e-4;

fn expectVec3(expected: Vec3, actual: Vec3) !void {
    inline for (0..3) |i| try testing.expectApproxEqAbs(expected[i], actual[i], eps);
}

test "perspective maps near/far planes to NDC z = -1/+1" {
    const near: f32 = 1;
    const far: f32 = 100;
    const p = perspective(std.math.pi / 2.0, 1.0, near, far) catch unreachable;
    // A point on the near plane (view space z = -near) -> clip.z/clip.w = -1.
    const zn = p[10] * (-near) + p[14];
    const wn = p[11] * (-near);
    try testing.expectApproxEqAbs(@as(f32, -1), zn / wn, eps);
    // A point on the far plane (view space z = -far) -> clip.z/clip.w = +1.
    const zf = p[10] * (-far) + p[14];
    const wf = p[11] * (-far);
    try testing.expectApproxEqAbs(@as(f32, 1), zf / wf, eps);
}

test "perspective field of view scales x/y symmetrically" {
    const p = perspective(std.math.pi / 2.0, 2.0, 1, 10) catch unreachable;
    // fov 90deg => f = 1; aspect 2 => m[0] = 0.5, m[5] = 1.
    try testing.expectApproxEqAbs(@as(f32, 0.5), p[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p[5], eps);
}

test "orthographic maps the box corners to NDC +/-1" {
    const o = orthographic(-2, 2, -1, 1, 1, 10) catch unreachable;
    // x = right -> NDC x = +1; y = top -> NDC y = +1; z = -near -> NDC z = -1.
    try testing.expectApproxEqAbs(@as(f32, 1), o[0] * 2 + o[12], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), o[5] * 1 + o[13], eps);
    try testing.expectApproxEqAbs(@as(f32, -1), o[10] * (-1) + o[14], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), o[10] * (-10) + o[14], eps);
}

test "lookAt puts the eye at the origin and looks down -Z" {
    const eye = Vec3{ 0, 0, 5 };
    const v = lookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    // The eye maps to the origin.
    try expectVec3(.{ 0, 0, 0 }, transform.transformPoint(v, eye));
    // A point in front of the eye (toward the target) has negative view z.
    const ahead = transform.transformPoint(v, .{ 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, -5), ahead[2], eps);
    // The up direction maps to +Y.
    try expectVec3(.{ 0, 1, 0 }, transform.transformDirection(v, .{ 0, 1, 0 }));
}

test "lookAt with up parallel to the view axis still yields a finite orthonormal basis" {
    // Looking straight down -Y with the world up (0,1,0): no basis can be built
    // from that hint, so a fallback axis must kick in instead of an all-zero basis.
    const v = lookAt(.{ 0, 5, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    // The forward row is finite and unit length.
    const f = Vec3{ -v[2], -v[6], -v[10] };
    const flen = @sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    try testing.expectApproxEqAbs(@as(f32, 1), flen, eps);
    const s = Vec3{ v[0], v[4], v[8] };
    const slen = @sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    try testing.expectApproxEqAbs(@as(f32, 1), slen, eps);
    // Eye maps to the origin.
    try expectVec3(.{ 0, 0, 0 }, transform.transformPoint(v, .{ 0, 5, 0 }));
}

test "lookAt degenerate eye==target returns identity" {
    const v = lookAt(.{ 1, 2, 3 }, .{ 1, 2, 3 }, .{ 0, 1, 0 });
    try testing.expect(transform.approxEqual(transform.identity(), v, eps));
}

test "camera combines projection * view and stores the eye" {
    const eye = Vec3{ 0, 0, 5 };
    const cam = Camera.perspectiveLookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
    const expected = transform.multiply(cam.projection, cam.view);
    try testing.expect(transform.approxEqual(expected, cam.view_projection, eps));
    try expectVec3(eye, cam.position);
    // The target (world origin) is in front of the camera: view z < 0.
    const view_pos = transform.transformPoint(cam.view, .{ 0, 0, 0 });
    try testing.expect(view_pos[2] < 0);
}
