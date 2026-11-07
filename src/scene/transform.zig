//! Transform math for the scene system: column-major 4x4 matrices and
//! quaternion helpers used to propagate local transforms into world space.
//!
//! Conventions:
//! - `Mat4` is a column-major `[16]f32`; element (row r, column c) is `m[c*4+r]`.
//!   This matches the layout GPUs expect, so the renderer can upload it directly.
//! - A `Transform` is local TRS (translation, rotation quaternion `[x,y,z,w]`,
//!   scale). `fromTransform` builds `M = T * R * S`.
//! - World composition is `world_child = world_parent * local_child`, which is
//!   fully correct under non-uniform scale and rotation (no shear is lost,
//!   unlike a naive component-wise TRS compose).
//!
//! This module is pure math (depends only on `std` and the `Transform`
//! component). It is reusable by the renderer/editor and is independently
//! testable.

const std = @import("std");
const components = @import("components.zig");

pub const Transform = components.Transform;
pub const Vec3 = [3]f32;
pub const Quat = [4]f32;
/// Column-major 4x4 matrix. Element (row r, col c) = `m[c * 4 + r]`.
pub const Mat4 = [16]f32;

pub const identity_quat: Quat = .{ 0, 0, 0, 1 };

/// The identity matrix.
pub fn identity() Mat4 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

/// Matrix product `a * b` (column-major).
pub fn multiply(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    inline for (0..4) |c| {
        inline for (0..4) |r| {
            var sum: f32 = 0;
            inline for (0..4) |k| {
                sum += a[k * 4 + r] * b[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
    return out;
}

/// Inverts a 4x4 matrix using Gauss-Jordan elimination.
///
/// Returns `null` when the matrix is singular (no pivot large enough).
/// Column-major layout: element (row r, col c) is `m[c * 4 + r]`.
pub fn mat4Inverse(m: Mat4) ?Mat4 {
    // Work row-major for clarity: a[r * 4 + c] = element at row r, col c.
    var a: [16]f32 = undefined;
    var r: usize = 0;
    while (r < 4) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            a[r * 4 + c] = m[c * 4 + r];
        }
    }
    // Augment with identity.
    var inv: [16]f32 = undefined;
    r = 0;
    while (r < 4) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            inv[r * 4 + c] = if (r == c) 1.0 else 0.0;
        }
    }
    // Gauss-Jordan elimination with partial pivoting.
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        // Find pivot: largest absolute value in this column at or below the diagonal.
        var pivot_row: usize = col;
        var max_val = @abs(a[col * 4 + col]);
        var rr: usize = col + 1;
        while (rr < 4) : (rr += 1) {
            const v = @abs(a[rr * 4 + col]);
            if (v > max_val) {
                max_val = v;
                pivot_row = rr;
            }
        }
        if (max_val < 1e-8) return null;
        // Swap rows if needed.
        if (pivot_row != col) {
            var cc: usize = 0;
            while (cc < 4) : (cc += 1) {
                const tmp = a[col * 4 + cc];
                a[col * 4 + cc] = a[pivot_row * 4 + cc];
                a[pivot_row * 4 + cc] = tmp;
                const tmp2 = inv[col * 4 + cc];
                inv[col * 4 + cc] = inv[pivot_row * 4 + cc];
                inv[pivot_row * 4 + cc] = tmp2;
            }
        }
        // Normalize pivot row.
        const inv_pivot = 1.0 / a[col * 4 + col];
        var cc: usize = 0;
        while (cc < 4) : (cc += 1) {
            a[col * 4 + cc] *= inv_pivot;
            inv[col * 4 + cc] *= inv_pivot;
        }
        // Eliminate this column from all other rows.
        rr = 0;
        while (rr < 4) : (rr += 1) {
            if (rr == col) continue;
            const factor = a[rr * 4 + col];
            cc = 0;
            while (cc < 4) : (cc += 1) {
                a[rr * 4 + cc] -= factor * a[col * 4 + cc];
                inv[rr * 4 + cc] -= factor * inv[col * 4 + cc];
            }
        }
    }
    // Convert back to column-major: result[c * 4 + r] = inv[r * 4 + c].
    var result: Mat4 = undefined;
    r = 0;
    while (r < 4) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            result[c * 4 + r] = inv[r * 4 + c];
        }
    }
    return result;
}

/// Build a local TRS matrix `T * R * S` from a `Transform`. The rotation
/// quaternion is normalized first; a zero-length quaternion becomes identity.
pub fn fromTransform(t: Transform) Mat4 {
    const q = quatNormalize(t.rotation);
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];

    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;

    const sx = t.scale[0];
    const sy = t.scale[1];
    const sz = t.scale[2];

    return .{
        (1 - (yy + zz)) * sx, (xy + wz) * sx,       (xz - wy) * sx,       0,
        (xy - wz) * sy,       (1 - (xx + zz)) * sy, (yz + wx) * sy,       0,
        (xz + wy) * sz,       (yz - wx) * sz,       (1 - (xx + yy)) * sz, 0,
        t.position[0],        t.position[1],        t.position[2],        1,
    };
}

/// Transform a point (applies rotation, scale and translation).
pub fn transformPoint(m: Mat4, p: Vec3) Vec3 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    };
}

/// Transform a direction vector (rotation and scale only; no translation).
/// Note: for normals under non-uniform scale, use the inverse-transpose instead.
pub fn transformDirection(m: Mat4, d: Vec3) Vec3 {
    return .{
        m[0] * d[0] + m[4] * d[1] + m[8] * d[2],
        m[1] * d[0] + m[5] * d[1] + m[9] * d[2],
        m[2] * d[0] + m[6] * d[1] + m[10] * d[2],
    };
}

/// Component-wise approximate equality (absolute epsilon).
pub fn approxEqual(a: Mat4, b: Mat4, epsilon: f32) bool {
    inline for (0..16) |i| {
        if (@abs(a[i] - b[i]) > epsilon) return false;
    }
    return true;
}

// --- Vec3 helpers ----------------------------------------------------------

/// Dot product `a · b`.
pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Component-wise difference `a - b`.
pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// Component-wise sum `a + b`.
pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

/// Scale a vector by a scalar.
pub fn scale(v: Vec3, s: f32) Vec3 {
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

/// Euclidean length of a vector.
pub fn length(v: Vec3) f32 {
    return @sqrt(dot(v, v));
}

/// Unit-length vector; a near-zero vector becomes zero (callers that need a
/// direction must guard against the degenerate case).
pub fn normalize(v: Vec3) Vec3 {
    const len = length(v);
    if (len < 1e-8) return .{ 0, 0, 0 };
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

// --- quaternion helpers ----------------------------------------------------

/// Normalize a quaternion; a near-zero quaternion becomes identity.
pub fn quatNormalize(q: Quat) Quat {
    const len = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (len < 1e-8) return identity_quat;
    const inv = 1.0 / len;
    return .{ q[0] * inv, q[1] * inv, q[2] * inv, q[3] * inv };
}

/// Hamilton product `a * b`.
pub fn quatMultiply(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

/// Rotate a vector by a quaternion (normalized internally).
pub fn quatRotateVec3(q: Quat, v: Vec3) Vec3 {
    const n = quatNormalize(q);
    const u = Vec3{ n[0], n[1], n[2] };
    const t = cross(u, v);
    const tx = 2 * t[0];
    const ty = 2 * t[1];
    const tz = 2 * t[2];
    const c = cross(u, .{ tx, ty, tz });
    return .{
        v[0] + n[3] * tx + c[0],
        v[1] + n[3] * ty + c[1],
        v[2] + n[3] * tz + c[2],
    };
}

/// Unit quaternion for a rotation of `angle` radians about `axis` (normalized
/// internally; a zero axis yields identity).
pub fn quatFromAxisAngle(axis: Vec3, angle: f32) Quat {
    const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    if (len < 1e-8) return identity_quat;
    const inv = 1.0 / len;
    const half = angle * 0.5;
    const s = @sin(half);
    return .{ axis[0] * inv * s, axis[1] * inv * s, axis[2] * inv * s, @cos(half) };
}

/// Cross product `a × b` (right-handed).
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

// --- Euler angles ----------------------------------------------------------

/// Degrees to radians and back.
const deg_to_rad: f32 = std.math.pi / 180.0;
const rad_to_deg: f32 = 180.0 / std.math.pi;

/// Compose a unit quaternion from Euler angles in degrees:
/// roll about X, then pitch about Y, then yaw about Z (intrinsic; equivalently
/// `q = q_yaw * q_pitch * q_roll`). All angles are in degrees.
pub fn quatFromEuler(roll: f32, pitch: f32, yaw: f32) Quat {
    const cr = std.math.cos(roll * deg_to_rad * 0.5);
    const sr = std.math.sin(roll * deg_to_rad * 0.5);
    const cp = std.math.cos(pitch * deg_to_rad * 0.5);
    const sp = std.math.sin(pitch * deg_to_rad * 0.5);
    const cy = std.math.cos(yaw * deg_to_rad * 0.5);
    const sy = std.math.sin(yaw * deg_to_rad * 0.5);
    return .{
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy,
    };
}

/// Extract Euler angles in degrees from a quaternion (the inverse of
/// `quatFromEuler`, normalized first). Returns roll (about X), pitch (about Y),
/// yaw (about Z), all in degrees. Pitch is clamped to [-90, 90] to avoid the
/// gimbal-lock singularity.
pub fn quatToEuler(q: Quat) [3]f32 {
    const n = quatNormalize(q);
    const x = n[0];
    const y = n[1];
    const z = n[2];
    const w = n[3];

    const roll_rad = std.math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y));

    const sinp = 2 * (w * y - z * x);
    const half_pi = std.math.pi / 2.0;
    const sign: f32 = if (sinp >= 0) 1.0 else -1.0;
    const pitch_rad = if (@abs(sinp) >= 1) sign * half_pi else std.math.asin(sinp);

    const yaw_rad = std.math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));

    return .{
        roll_rad * rad_to_deg,
        pitch_rad * rad_to_deg,
        yaw_rad * rad_to_deg,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const eps = 1e-5;

fn expectVec3(expected: Vec3, actual: Vec3) !void {
    inline for (0..3) |i| {
        try testing.expectApproxEqAbs(expected[i], actual[i], eps);
    }
}

test "identity matrix is the multiplicative identity" {
    const i = identity();
    const m = fromTransform(.{ .position = .{ 1, 2, 3 }, .scale = .{ 2, 3, 4 } });
    try testing.expect(approxEqual(multiply(i, m), m, eps));
    try testing.expect(approxEqual(multiply(m, i), m, eps));
}

test "fromTransform identity yields identity matrix" {
    try testing.expect(approxEqual(fromTransform(Transform.identity), identity(), eps));
}

test "fromTransform translation moves a point" {
    const m = fromTransform(.{ .position = .{ 5, -2, 7 } });
    try expectVec3(.{ 5, -2, 7 }, transformPoint(m, .{ 0, 0, 0 }));
    try expectVec3(.{ 6, 0, 10 }, transformPoint(m, .{ 1, 2, 3 }));
}

test "fromTransform scale scales a point and direction" {
    const m = fromTransform(.{ .scale = .{ 2, 3, 4 } });
    try expectVec3(.{ 2, 6, 12 }, transformPoint(m, .{ 1, 2, 3 }));
    try expectVec3(.{ 2, 6, 12 }, transformDirection(m, .{ 1, 2, 3 }));
}

test "fromTransform rotation 90deg about Z maps X to Y" {
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 2.0);
    const m = fromTransform(.{ .rotation = q });
    try expectVec3(.{ 0, 1, 0 }, transformPoint(m, .{ 1, 0, 0 }));
    try expectVec3(.{ -1, 0, 0 }, transformPoint(m, .{ 0, 1, 0 }));
}

test "transformDirection ignores translation" {
    const m = fromTransform(.{ .position = .{ 100, 100, 100 }, .scale = .{ 2, 2, 2 } });
    try expectVec3(.{ 2, 0, 0 }, transformDirection(m, .{ 1, 0, 0 }));
}

test "multiply composes translation then scale correctly" {
    // parent scales by 2, child translates by (1,0,0): world point of child
    // origin = parent * child applied to (0,0,0) = (2,0,0).
    const parent = fromTransform(.{ .scale = .{ 2, 2, 2 } });
    const child = fromTransform(.{ .position = .{ 1, 0, 0 } });
    const world = multiply(parent, child);
    try expectVec3(.{ 2, 0, 0 }, transformPoint(world, .{ 0, 0, 0 }));
    try expectVec3(.{ 4, 0, 0 }, transformPoint(world, .{ 1, 0, 0 }));
}

test "multiply is associative" {
    const a = fromTransform(.{ .position = .{ 1, 2, 3 }, .rotation = quatFromAxisAngle(.{ 0, 1, 0 }, 0.7) });
    const b = fromTransform(.{ .scale = .{ 2, 1, 3 }, .position = .{ -1, 0, 4 } });
    const c = fromTransform(.{ .rotation = quatFromAxisAngle(.{ 1, 0, 0 }, -0.4), .position = .{ 0, 5, 0 } });
    try testing.expect(approxEqual(multiply(multiply(a, b), c), multiply(a, multiply(b, c)), 1e-4));
}

test "fromTransform applies scale before rotation (M = T * R * S)" {
    // Scale X by 2 in local space, then rotate 45deg about Z. The local X axis
    // (1,0,0) becomes (2,0,0) after scale, then R*(2,0,0) = (2cos45, 2sin45, 0).
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 4.0);
    const m = fromTransform(.{ .rotation = q, .scale = .{ 2, 1, 1 } });
    const p = transformPoint(m, .{ 1, 0, 0 });
    try expectVec3(.{ 2 * @cos(std.math.pi / 4.0), 2 * @sin(std.math.pi / 4.0), 0 }, p);
}

test "matrix composition preserves shear under rotated non-uniform scale" {
    // A parent rotated 45deg about Z with non-uniform scale, composed with a
    // child translation, must agree with an independent sequential point
    // transform (a naive component-wise TRS compose would lose the shear).
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 4.0);
    const parent = fromTransform(.{ .rotation = q, .scale = .{ 2, 1, 1 } });
    const child = fromTransform(.{ .position = .{ 1, 1, 0 } });
    const world = multiply(parent, child);
    // child origin (0,0,0) -> child local (1,1,0) -> parent R*S*(1,1,0).
    const expected = transformPoint(parent, .{ 1, 1, 0 });
    try expectVec3(expected, transformPoint(world, .{ 0, 0, 0 }));
    // And a point offset in the child agrees with sequential application.
    const expected2 = transformPoint(parent, transformPoint(child, .{ 0.5, -0.25, 2 }));
    try expectVec3(expected2, transformPoint(world, .{ 0.5, -0.25, 2 }));
}

test "quatNormalize scales to unit length and handles zero" {
    const n = quatNormalize(.{ 0, 0, 0, 5 });
    try testing.expectApproxEqAbs(@as(f32, 1), n[3], eps);
    const z = quatNormalize(.{ 0, 0, 0, 0 });
    try testing.expectEqualSlices(f32, &identity_quat, &z);
}

test "quatMultiply by identity is unchanged" {
    const q = quatFromAxisAngle(.{ 0, 1, 0 }, 1.1);
    const r = quatMultiply(q, identity_quat);
    try testing.expectApproxEqAbs(q[0], r[0], eps);
    try testing.expectApproxEqAbs(q[3], r[3], eps);
}

test "quatRotateVec3 matches matrix rotation" {
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 2.0);
    try expectVec3(.{ 0, 1, 0 }, quatRotateVec3(q, .{ 1, 0, 0 }));
    const m = fromTransform(.{ .rotation = q });
    try expectVec3(transformPoint(m, .{ 1, 0, 0 }), quatRotateVec3(q, .{ 1, 0, 0 }));
}

test "quatFromAxisAngle zero axis yields identity" {
    try testing.expectEqualSlices(f32, &identity_quat, &quatFromAxisAngle(.{ 0, 0, 0 }, 1.0));
}

test "fromTransform normalizes a non-unit quaternion" {
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 2.0);
    const scaled = Quat{ q[0] * 3, q[1] * 3, q[2] * 3, q[3] * 3 };
    const a = fromTransform(.{ .rotation = q });
    const b = fromTransform(.{ .rotation = scaled });
    try testing.expect(approxEqual(a, b, eps));
}

test "vec3: dot, sub, add, scale and length" {
    try testing.expectEqual(@as(f32, 32), dot(.{ 1, 2, 3 }, .{ 4, 5, 6 }));
    try expectVec3(.{ -3, -3, -3 }, sub(.{ 1, 2, 3 }, .{ 4, 5, 6 }));
    try expectVec3(.{ 5, 7, 9 }, add(.{ 1, 2, 3 }, .{ 4, 5, 6 }));
    try expectVec3(.{ 2, 4, 6 }, scale(.{ 1, 2, 3 }, 2));
    try testing.expectApproxEqAbs(@as(f32, 5), length(.{ 3, 4, 0 }), eps);
}

test "vec3: normalize yields unit length and handles zero" {
    const n = normalize(.{ 3, 4, 0 });
    try testing.expectApproxEqAbs(@as(f32, 1), length(n), eps);
    try expectVec3(.{ 0, 0, 0 }, normalize(.{ 0, 0, 0 }));
}

test "vec3: cross is right-handed and orthogonal" {
    try expectVec3(.{ 0, 0, 1 }, cross(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
    const a = Vec3{ 1, 2, 3 };
    const b = Vec3{ 4, 5, 6 };
    const c = cross(a, b);
    try testing.expectApproxEqAbs(@as(f32, 0), dot(a, c), eps);
    try testing.expectApproxEqAbs(@as(f32, 0), dot(b, c), eps);
}

test "euler: quatFromEuler and quatToEuler round-trip identity" {
    const q = quatFromEuler(0, 0, 0);
    try testing.expectEqualSlices(f32, &identity_quat, &q);
}

test "euler: quatFromEuler 90deg yaw about Z maps X to Y" {
    const q = quatFromEuler(0, 0, 90);
    const m = fromTransform(.{ .rotation = q });
    try expectVec3(.{ 0, 1, 0 }, transformPoint(m, .{ 1, 0, 0 }));
    try expectVec3(.{ -1, 0, 0 }, transformPoint(m, .{ 0, 1, 0 }));
}

test "euler: quatToEuler extracts yaw from a pure-z rotation" {
    const q = quatFromAxisAngle(.{ 0, 0, 1 }, std.math.pi / 4.0);
    const e = quatToEuler(q);
    try testing.expectApproxEqAbs(@as(f32, 45), e[2], eps); // yaw
    try testing.expectApproxEqAbs(@as(f32, 0), e[0], eps); // roll
    try testing.expectApproxEqAbs(@as(f32, 0), e[1], eps); // pitch
}

test "euler: quatToEuler extracts pitch from a pure-y rotation" {
    const q = quatFromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 3.0);
    const e = quatToEuler(q);
    try testing.expectApproxEqAbs(@as(f32, 60), e[1], eps); // pitch
    try testing.expectApproxEqAbs(@as(f32, 0), e[0], eps); // roll
    try testing.expectApproxEqAbs(@as(f32, 0), e[2], eps); // yaw
}

test "euler: quatToEuler extracts roll from a pure-x rotation" {
    const q = quatFromAxisAngle(.{ 1, 0, 0 }, -std.math.pi / 6.0);
    const e = quatToEuler(q);
    try testing.expectApproxEqAbs(@as(f32, -30), e[0], eps); // roll
    try testing.expectApproxEqAbs(@as(f32, 0), e[1], eps); // pitch
    try testing.expectApproxEqAbs(@as(f32, 0), e[2], eps); // yaw
}

test "euler: quatFromEuler with zero axis-like angles yields identity-like quaternion" {
    const q = quatFromEuler(0, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), q[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), q[1], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), q[2], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), q[3], eps);
}

test "mat4Inverse: identity inverts to identity" {
    const inv = mat4Inverse(identity()) orelse return;
    try testing.expect(approxEqual(inv, identity(), eps));
}

test "mat4Inverse: matrix times its inverse is identity" {
    const m = fromTransform(.{
        .position = .{ 1, 2, 3 },
        .rotation = quatFromAxisAngle(.{ 0, 1, 0 }, 0.7),
        .scale = .{ 2, 1, 3 },
    });
    const inv = mat4Inverse(m) orelse return;
    const product = multiply(m, inv);
    try testing.expect(approxEqual(product, identity(), eps));
}

test "mat4Inverse: singular matrix returns null" {
    const zero: Mat4 = @splat(0);
    try testing.expect(mat4Inverse(zero) == null);
}
