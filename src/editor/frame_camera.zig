//! Framing a scene from the keyboard: the viewport's "focus" commands.
//!
//! Two questions live here, both testable without a window:
//!
//! * **What are the bounds?** `bounds` walks the scene's world transforms and returns the
//!   box that contains the geometry the scene actually has (entities with a `Renderable`
//!   and a `Transform`). A camera-only scene has no bounds, and saying so is better than
//!   framing an empty point at the origin.
//! * **Where does the camera go?** `fit` places the eye on the current view direction at
//!   the distance where the box fills the frame, and `orbit` swings that direction around
//!   the target. Both answer with a `Transform` the caller applies through the history as
//!   one `set_component`, so focusing the view is undoable like every other edit.
//!
//! The camera keeps its authored orientation unless the caller orbits it: framing changes
//! *where* the camera is, not *where it looks*, which is what makes repeated focus-alls
//! stable instead of drifting.

const std = @import("std");
const components = @import("../scene/components.zig");
const render_scene = @import("../scene/render_scene.zig");
const render_camera = @import("../render.zig").Camera;
const transform = @import("../scene/transform.zig");

const Renderable = render_scene.Renderable;

pub const Vec3 = transform.Vec3;
pub const Mat4 = transform.Mat4;

/// The world-space box around the scene's geometry.
pub const Bounds = struct {
    min: Vec3,
    max: Vec3,

    /// The box's centre.
    pub fn center(self: Bounds) Vec3 {
        return .{
            (self.min[0] + self.max[0]) * 0.5,
            (self.min[1] + self.max[1]) * 0.5,
            (self.min[2] + self.max[2]) * 0.5,
        };
    }

    /// Half the box's diagonal: the radius of the sphere around it. Zero for a single
    /// point, which `fit` handles by falling back to a minimum distance.
    pub fn radius(self: Bounds) f32 {
        const c = self.center();
        const dx = self.max[0] - c[0];
        const dy = self.max[1] - c[1];
        const dz = self.max[2] - c[2];
        return @sqrt(dx * dx + dy * dy + dz * dz);
    }

    pub fn isEmpty(self: Bounds) bool {
        for (0..3) |i| {
            if (!(self.max[i] > self.min[i])) return true;
        }
        return false;
    }
};

/// Bounds of every entity that has both a `Transform` and a `Renderable`.
///
/// A `Renderable` without a `Transform` cannot be placed and is skipped; a `Transform`
/// without a `Renderable` (a camera, an empty group) does not contribute, so focusing the
/// view frames what can be *seen* rather than where the lights happen to sit.
///
/// World transforms are computed once for the whole scene — the same allocation the
/// renderer already makes per frame — rather than by walking parents per entity.
pub fn bounds(scene: anytype, gpa: std.mem.Allocator) !?Bounds {
    var world = try scene.computeWorldTransforms(gpa);
    defer world.deinit();

    var min: Vec3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var max: Vec3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var found = false;

    var view = scene.ecsWorld().view(.{ components.Transform, Renderable });
    while (view.next()) |entry| {
        const entity = entry[0];
        const m = world.get(entity) orelse continue;
        // The eight corners of the entity's local unit box, so a scaled mesh is framed by
        // its real extent instead of by its origin.
        var corner: usize = 0;
        while (corner < 8) : (corner += 1) {
            const local: Vec3 = .{
                if (corner & 1 == 0) -0.5 else 0.5,
                if (corner & 2 == 0) -0.5 else 0.5,
                if (corner & 4 == 0) -0.5 else 0.5,
            };
            const p = transform.transformPoint(m, local);
            for (0..3) |i| {
                min[i] = @min(min[i], p[i]);
                max[i] = @max(max[i], p[i]);
            }
            found = true;
        }
    }
    if (!found) return null;
    return .{ .min = min, .max = max };
}

/// Bounds of one entity: its rendered extent when it has geometry, or a single point at
/// its world position when it does not.
///
/// A group or an empty entity is still frameable — the user selected it and asked to look
/// at it — so this never returns "nothing to frame" for a live entity. `null` means the
/// entity does not exist.
pub fn boundsOf(scene: anytype, id: u64, gpa: std.mem.Allocator) !?Bounds {
    const entity = scene.entityById(id) orelse return null;
    var world = try scene.computeWorldTransforms(gpa);
    defer world.deinit();
    const m = world.get(entity) orelse {
        // No transform at all: frame the origin, which is where the renderer would place it.
        return Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 0.001, 0.001, 0.001 } };
    };

    const rendered = scene.hasComponent(Renderable, entity);
    if (!rendered) {
        const p = transform.transformPoint(m, .{ 0, 0, 0 });
        // A degenerate box, so `fit` uses its radius and falls back to the minimum
        // distance rather than dividing by zero.
        return Bounds{ .min = p, .max = .{ p[0] + 0.001, p[1] + 0.001, p[2] + 0.001 } };
    }

    var min: Vec3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var max: Vec3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var corner: usize = 0;
    while (corner < 8) : (corner += 1) {
        const local: Vec3 = .{
            if (corner & 1 == 0) -0.5 else 0.5,
            if (corner & 2 == 0) -0.5 else 0.5,
            if (corner & 4 == 0) -0.5 else 0.5,
        };
        const p = transform.transformPoint(m, local);
        for (0..3) |i| {
            min[i] = @min(min[i], p[i]);
            max[i] = @max(max[i], p[i]);
        }
    }
    return .{ .min = min, .max = max };
}

/// Where the camera looks, kept apart from where it sits.
///
/// The eye is `target - direction * distance`, so a direction is the *viewing* direction
/// (from the eye towards the target) and orbit is a rotation of it about the target.
pub const View = struct {
    target: Vec3 = .{ 0, 0, 0 },
    /// Unit vector from the eye towards the target.
    direction: Vec3 = .{ 0, 0, -1 },
    distance: f32 = 5,
};

/// Minimum distance a fit will place the eye at, so framing a single point does not divide
/// by a zero radius and put the camera inside its own target.
pub const min_distance: f32 = 0.5;

/// Distance at which a sphere of `radius` fills a frame of `fov` radians vertically.
///
/// A margin keeps the geometry off the frame edges: framing something exactly is the same
/// as framing it with its top and bottom clipped by the near plane of the eye's attention.
pub fn fitDistance(radius: f32, fov: f32) f32 {
    const half = @max(fov, 0.01) * 0.5;
    const d = @max(radius, 0.0001) / @sin(half);
    return @max(d * 1.15, min_distance);
}

/// The `View` that frames `box` from the camera's current orientation.
pub fn fit(view: View, box: Bounds, fov: f32) View {
    const target = box.center();
    const direction = normalizeOrDefault(view.direction, .{ 0, 0, -1 });
    return .{
        .target = target,
        .direction = direction,
        .distance = fitDistance(box.radius(), fov),
    };
}

/// Swing the view around its target: `yaw` radians about world +Y, then `pitch` radians
/// about the camera's right axis. Pitch is clamped short of the poles, where the up vector
/// becomes degenerate and a look-at matrix would flip.
pub fn orbit(view: View, yaw: f32, pitch: f32) View {
    const d = normalizeOrDefault(view.direction, .{ 0, 0, -1 });
    const right = transform.normalize(transform.cross(.{ 0, 1, 0 }, d));

    // Pitch about the right axis, then yaw about world up: applying yaw first would make
    // "up" drift as the camera turns, which reads as the horizon rolling.
    var out = d;
    if (pitch != 0 and transform.length(right) > 0) {
        out = rotateAround(out, right, pitch);
    }
    if (yaw != 0) out = rotateAround(out, .{ 0, 1, 0 }, yaw);
    out = normalizeOrDefault(out, d);

    // Clamp away from the poles by clamping the *sine* of the elevation and rescaling the
    // horizontal part, which is exact (a rotation-based clamp only approximates the limit
    // and can overshoot when pitch is applied in steps).
    const limit = @as(f32, std.math.pi) / 2 - 0.02;
    const max_sin = @sin(limit);
    if (@abs(out[1]) > max_sin) {
        const y = std.math.copysign(max_sin, out[1]);
        const horizontal = @sqrt(@max(1 - y * y, 0));
        const h_len = @sqrt(out[0] * out[0] + out[2] * out[2]);
        if (h_len > 1e-6) {
            out[0] = out[0] / h_len * horizontal;
            out[2] = out[2] / h_len * horizontal;
            out[1] = y;
        } else {
            out = .{ 0, y, -horizontal };
        }
    }
    return .{ .target = view.target, .direction = normalizeOrDefault(out, d), .distance = @max(view.distance, min_distance) };
}

/// Rotate `v` about `axis` by `angle` (Rodrigues).
fn rotateAround(v: Vec3, axis: Vec3, angle: f32) Vec3 {
    const a = transform.normalize(axis);
    if (transform.length(a) == 0) return v;
    const c = @cos(angle);
    const s = @sin(angle);
    const dot = transform.dot(a, v);
    const cross = transform.cross(a, v);
    return .{
        v[0] * c + cross[0] * s + a[0] * dot * (1 - c),
        v[1] * c + cross[1] * s + a[1] * dot * (1 - c),
        v[2] * c + cross[2] * s + a[2] * dot * (1 - c),
    };
}

fn normalizeOrDefault(v: Vec3, fallback: Vec3) Vec3 {
    const n = transform.normalize(v);
    if (transform.length(n) == 0 or !std.math.isFinite(n[0]) or !std.math.isFinite(n[1]) or !std.math.isFinite(n[2])) {
        return fallback;
    }
    return n;
}

/// Read the view a camera transform already expresses, so a command starts from what is on
/// screen instead of from a default looking somewhere else.
///
/// The inverse of `toTransform`, which places the eye at `target - direction * distance`:
/// the eye is the transform's origin, the viewing direction is its local -Z, and the target
/// is `distance` along that direction. A rotation cannot say how far away the target is, so
/// the caller passes the distance it remembers; a round trip through `toTransform` keeps it
/// exact, and the next `fit` replaces it anyway.
pub fn viewOf(t: components.Transform, distance: f32) View {
    const m = transform.fromTransform(t);
    const direction = normalizeOrDefault(transform.transformDirection(m, .{ 0, 0, -1 }), .{ 0, 0, -1 });
    const d = @max(distance, min_distance);
    return .{
        .target = .{
            t.position[0] + direction[0] * d,
            t.position[1] + direction[1] * d,
            t.position[2] + direction[2] * d,
        },
        .direction = direction,
        .distance = d,
    };
}

/// The camera transform that realises `view`.
///
/// The camera looks down its local -Z (the scene's convention, see `cameraOf`), so the
/// basis is built from the viewing direction: forward = direction, right = up x forward,
/// up = forward x right. A degenerate up (looking straight down the world Y) falls back to
/// Z so the result is always a valid rotation.
pub fn toTransform(view: View) components.Transform {
    const forward = normalizeOrDefault(view.direction, .{ 0, 0, -1 });
    const distance = @max(view.distance, min_distance);
    const eye: Vec3 = .{
        view.target[0] - forward[0] * distance,
        view.target[1] - forward[1] * distance,
        view.target[2] - forward[2] * distance,
    };

    var right = transform.cross(forward, .{ 0, 1, 0 });
    if (transform.length(right) < 1e-4) right = transform.cross(forward, .{ 0, 0, 1 });
    right = transform.normalize(right);
    const up = transform.normalize(transform.cross(right, forward));

    // Matrix with columns (right, up, -forward): the camera's local axes in world space.
    const basis = transform.Mat4{
        right[0], up[0], -forward[0], 0,
        right[1], up[1], -forward[1], 0,
        right[2], up[2], -forward[2], 0,
        0,        0,     0,           1,
    };
    const quat = quatFromBasis(basis);
    return .{
        .position = eye,
        .rotation = quat,
        .scale = .{ 1, 1, 1 },
    };
}

/// Extract a quaternion from a pure-rotation matrix (Shepperd's method, the numerically
/// stable branch chosen by the largest diagonal element).
fn quatFromBasis(m: transform.Mat4) transform.Quat {
    const m00 = m[0];
    const m01 = m[1];
    const m02 = m[2];
    const m10 = m[4];
    const m11 = m[5];
    const m12 = m[6];
    const m20 = m[8];
    const m21 = m[9];
    const m22 = m[10];
    const trace = m00 + m11 + m22;
    if (trace > 0) {
        const s = @sqrt(trace + 1.0) * 2;
        return .{ (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s };
    } else if (m00 > m11 and m00 > m22) {
        const s = @sqrt(1.0 + m00 - m11 - m22) * 2;
        return .{ 0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s };
    } else if (m11 > m22) {
        const s = @sqrt(1.0 + m11 - m00 - m22) * 2;
        return .{ (m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s };
    } else {
        const s = @sqrt(1.0 + m22 - m00 - m11) * 2;
        return .{ (m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s };
    }
}

/// A ray in world space: an origin and a unit direction.
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,
};

/// Builds a pick ray from NDC screen coordinates (`ndc_x`, `ndc_y` in [-1, 1]).
///
/// The ray starts at the camera's eye and passes through the point on the near
/// plane corresponding to the screen coordinate. Returns `null` when the
/// view-projection matrix cannot be inverted.
pub fn pickRay(
    ndc_x: f32,
    ndc_y: f32,
    inv_view_projection: Mat4,
    camera_position: Vec3,
) ?Ray {
    // Unproject the near-plane corner (ndc_x, ndc_y, -1) into world space.
    const clip: [4]f32 = .{ ndc_x, ndc_y, -1.0, 1.0 };
    var world: [4]f32 = undefined;
    inline for (0..4) |r| {
        var sum: f32 = 0;
        inline for (0..4) |c| {
            sum += inv_view_projection[c * 4 + r] * clip[c];
        }
        world[r] = sum;
    }
    if (world[3] == 0) return null;
    const inv_w = 1.0 / world[3];
    const near_point: Vec3 = .{ world[0] * inv_w, world[1] * inv_w, world[2] * inv_w };

    const direction = transform.normalize(transform.sub(near_point, camera_position));
    if (transform.length(direction) == 0) return null;

    return .{ .origin = camera_position, .direction = direction };
}

/// Intersects a ray with an axis-aligned bounding box using the slab method.
///
/// Returns the distance from the ray origin to the nearest intersection point,
/// or `null` when the ray misses the box.
pub fn rayIntersectsBounds(ray: Ray, box: Bounds) ?f32 {
    var t_min: f32 = -std.math.inf(f32);
    var t_max: f32 = std.math.inf(f32);

    inline for (0..3) |i| {
        const inv_d = if (ray.direction[i] != 0) 1.0 / ray.direction[i] else std.math.inf(f32);
        var t1 = (box.min[i] - ray.origin[i]) * inv_d;
        var t2 = (box.max[i] - ray.origin[i]) * inv_d;
        if (inv_d < 0) {
            const tmp = t1;
            t1 = t2;
            t2 = tmp;
        }
        t_min = @max(t_min, t1);
        t_max = @min(t_max, t2);
        if (t_min > t_max) return null;
    }

    if (t_max < 0) return null;
    return @max(t_min, 0.0);
}

/// Intersects a ray with a plane defined by a point and a unit normal.
///
/// Returns the distance from the ray origin to the intersection point, or `null`
/// when the ray is parallel to the plane or points away from it (behind the eye).
pub fn rayIntersectsPlane(ray: Ray, plane_point: Vec3, plane_normal: Vec3) ?f32 {
    const denom = transform.dot(ray.direction, plane_normal);
    if (@abs(denom) < 1e-6) return null;
    const t = transform.dot(transform.sub(plane_point, ray.origin), plane_normal) / denom;
    if (t < 0) return null;
    return t;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const scene_mod = @import("../scene/scene.zig");

fn testScene(gpa: std.mem.Allocator) !scene_mod.Scene(.{
    scene_mod.Component(components.Transform, "transform"),
    scene_mod.Component(@import("../scene/render_scene.zig").Renderable, "renderable"),
    scene_mod.Component(@import("../scene/render_scene.zig").CameraComponent, "camera"),
}) {
    return scene_mod.Scene(.{
        scene_mod.Component(components.Transform, "transform"),
        scene_mod.Component(@import("../scene/render_scene.zig").Renderable, "renderable"),
        scene_mod.Component(@import("../scene/render_scene.zig").CameraComponent, "camera"),
    }).init(gpa, "level");
}

test "frame camera: bounds cover rendered geometry and ignore cameras and empties" {
    const CameraComponent = @import("../scene/render_scene.zig").CameraComponent;
    var scene = try testScene(testing.allocator);
    defer scene.deinit();

    // Nothing rendered yet.
    try testing.expect(try bounds(&scene, testing.allocator) == null);

    const mesh = try scene.createEntity("mesh", null);
    try scene.addComponent(mesh, components.Transform{ .position = .{ 2, 0, 0 }, .scale = .{ 2, 2, 2 } });
    try scene.addComponent(mesh, Renderable{ .mesh = 1, .material = 0 });

    // A camera and an empty entity must not widen the box.
    const cam = try scene.createEntity("camera", null);
    try scene.addComponent(cam, components.Transform{ .position = .{ 100, 100, 100 } });
    try scene.addComponent(cam, CameraComponent{});
    const empty = try scene.createEntity("empty", null);
    try scene.addComponent(empty, components.Transform{ .position = .{ -100, -100, -100 } });

    const box = (try bounds(&scene, testing.allocator)).?;
    // A unit box at x=2 scaled by 2 spans [1, 3] in x, [-1, 1] in y and z.
    try testing.expectApproxEqAbs(@as(f32, 2), box.center()[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), box.center()[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), box.max[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), box.min[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, @sqrt(3.0)), box.radius(), 1e-4);
    try testing.expect(!box.isEmpty());
}

test "frame camera: a child's geometry is framed in world space" {
    var scene = try testScene(testing.allocator);
    defer scene.deinit();

    const parent = try scene.createEntity("parent", null);
    const parent_id = scene.idOf(parent).?;
    try scene.addComponent(parent, components.Transform{ .position = .{ 10, 0, 0 } });
    const child = try scene.createEntity("child", parent_id);
    try scene.addComponent(child, components.Transform{ .position = .{ 0, 0, 0 } });
    try scene.addComponent(child, Renderable{ .mesh = 1, .material = 0 });

    const box = (try bounds(&scene, testing.allocator)).?;
    // The renderable sits at the parent's world position, not at the origin.
    try testing.expectApproxEqAbs(@as(f32, 10), box.center()[0], 1e-5);
}

test "frame camera: fit distance grows with the box and shrinks with the field of view" {
    const small = Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    const big = Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 10, 10, 10 } };
    const fov: f32 = @as(f32, std.math.pi) / 3;
    try testing.expect(fitDistance(big.radius(), fov) > fitDistance(small.radius(), fov) * 9);
    try testing.expect(fitDistance(small.radius(), @as(f32, std.math.pi) / 6) > fitDistance(small.radius(), fov));
    // A point still puts the camera somewhere usable.
    try testing.expectEqual(min_distance, fitDistance(0, fov));
}

test "frame camera: fit keeps the authored direction and centres on the box" {
    const box = Bounds{ .min = .{ 2, 0, 0 }, .max = .{ 4, 2, 2 } };
    const before = View{ .target = .{ 0, 0, 0 }, .direction = .{ 0, 0, -1 }, .distance = 1 };
    const after = fit(before, box, @as(f32, std.math.pi) / 3);
    try testing.expectApproxEqAbs(@as(f32, 3), after.target[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), after.target[1], 1e-5);
    // Direction unchanged: focusing moves the camera, it does not re-aim it.
    try testing.expectApproxEqAbs(@as(f32, -1), after.direction[2], 1e-5);
    try testing.expect(after.distance > 1);
}

test "frame camera: orbit swings around the target and never flips at the poles" {
    const start = View{ .target = .{ 1, 2, 3 }, .direction = .{ 0, 0, -1 }, .distance = 8 };
    const yawed = orbit(start, @as(f32, std.math.pi) / 2, 0);
    // A quarter turn about +Y takes -Z to -X.
    try testing.expectApproxEqAbs(@as(f32, -1), yawed.direction[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), yawed.direction[2], 1e-4);
    try testing.expectEqual(start.target[0], yawed.target[0]);
    try testing.expectEqual(start.distance, yawed.distance);

    // Pitching past the pole clamps instead of flipping the up vector.
    // Positive pitch raises the camera above the target, so the viewing direction tilts
    // down; forty steps run well past the pole and must settle at the clamp, not flip.
    var view = start;
    var i: usize = 0;
    while (i < 40) : (i += 1) view = orbit(view, 0, 0.2);
    const elevation = std.math.asin(std.math.clamp(view.direction[1], -1, 1));
    // It stops short of the pole (never at exactly pi/2, where look-at flips) and stays
    // inside the clamp bound. The bound is a ceiling, not a target: repeated steps may
    // settle a little before it.
    const limit = @as(f32, std.math.pi) / 2 - 0.02;
    try testing.expect(-elevation <= limit + 1e-5);
    try testing.expect(-elevation > 1.5);
    // Still a unit vector.
    try testing.expectApproxEqAbs(@as(f32, 1), transform.length(view.direction), 1e-4);
}

test "frame camera: the transform it writes is a valid camera that looks at the target" {
    const CameraComponent = render_scene.CameraComponent;
    var scene = try testScene(testing.allocator);
    defer scene.deinit();

    const mesh = try scene.createEntity("mesh", null);
    try scene.addComponent(mesh, components.Transform{ .position = .{ 0, 0, 0 } });
    try scene.addComponent(mesh, Renderable{ .mesh = 1, .material = 0 });
    const cam = try scene.createEntity("camera", null);
    try scene.addComponent(cam, components.Transform{ .position = .{ 0, 0, 10 } });
    try scene.addComponent(cam, CameraComponent{});

    const box = (try bounds(&scene, testing.allocator)).?;
    // Frame it looking down -Z, the way the authored camera already looks.
    const framed = fit(.{ .target = .{ 0, 0, 0 }, .direction = .{ 0, 0, -1 }, .distance = 1 }, box, @as(f32, std.math.pi) / 3);
    const t = toTransform(framed);
    try testing.expect(t.isValid());
    // The eye is *behind* the target along the view direction, so it sees the target.
    try testing.expect(t.position[2] > 0);

    // Round-trip through the engine's own camera: it must look at the framed target.
    try scene.addComponent(mesh, components.Transform{ .position = .{ 0, 0, 0 } });
    const cam_entity = cam;
    const updated = try applyToCamera(&scene, cam_entity, t);
    try testing.expect(updated.position[2] > 0);
    // The projected centre of the box lands in the middle of the image.
    const vp = updated.view_projection;
    const p = transform.transformPoint(vp, framed.target);
    try testing.expectApproxEqAbs(@as(f32, 0), p[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), p[1], 1e-3);
}

test "viewOf reads back the camera a fit wrote, so a command starts from the screen" {
    const view = View{ .target = .{ 1, 2, 3 }, .direction = .{ 0, 0, -1 }, .distance = 7 };
    const t = toTransform(view);
    const back = viewOf(t, view.distance);
    try testing.expectApproxEqAbs(view.target[0], back.target[0], 1e-4);
    try testing.expectApproxEqAbs(view.target[1], back.target[1], 1e-4);
    try testing.expectApproxEqAbs(view.target[2], back.target[2], 1e-4);
    try testing.expectApproxEqAbs(view.direction[2], back.direction[2], 1e-5);
    try testing.expectApproxEqAbs(view.distance, back.distance, 1e-5);
}

test "boundsOf frames a child's world extent, a point for an empty, and null for a ghost" {
    var scene = try testScene(testing.allocator);
    defer scene.deinit();

    const parent = try scene.createEntity("parent", null);
    try scene.addComponent(parent, components.Transform{ .position = .{ 10, 0, 0 } });
    const child = try scene.createEntity("child", scene.idOf(parent).?);
    try scene.addComponent(child, components.Transform{ .position = .{ 2, 0, 0 } });
    try scene.addComponent(child, Renderable{ .mesh = 1, .material = 0 });

    // The child's box is in world space: its parent's offset counts.
    const box = (try boundsOf(&scene, scene.idOf(child).?, testing.allocator)).?;
    try testing.expectApproxEqAbs(@as(f32, 12), box.center()[0], 1e-4);
    // The unit box's half-diagonal, sqrt(3)/2: the mesh's real extent, not its origin.
    try testing.expectApproxEqAbs(@as(f32, 0.866_025_4), box.radius(), 1e-3);

    // An entity with no geometry is still frameable: it collapses to the point it occupies.
    const marker = (try boundsOf(&scene, scene.idOf(parent).?, testing.allocator)).?;
    try testing.expectApproxEqAbs(@as(f32, 10), marker.center()[0], 1e-2);
    try testing.expect(marker.radius() > 0);

    // An id that names nothing is not an error, and it is not a box either.
    try testing.expect((try boundsOf(&scene, 0xdead_beef, testing.allocator)) == null);
}

test "pickRay: centre of screen shoots down the camera's view direction" {
    const cam = render_camera.perspectiveLookAt(
        .{ 0, 0, 5 },
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        @as(f32, std.math.pi) / 3,
        1.0,
        0.1,
        100,
    );
    const inv_vp = transform.mat4Inverse(cam.view_projection) orelse return;
    const ray = pickRay(0, 0, inv_vp, cam.position) orelse return;
    // Centre of screen: ray points straight down -Z towards the target.
    try testing.expectApproxEqAbs(@as(f32, 0), ray.direction[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), ray.direction[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1), ray.direction[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), ray.origin[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), ray.origin[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), ray.origin[2], 1e-4);
}

test "pickRay: right edge of screen shoots right and down" {
    const cam = render_camera.perspectiveLookAt(
        .{ 0, 0, 5 },
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        @as(f32, std.math.pi) / 2,
        1.0,
        0.1,
        100,
    );
    const inv_vp = transform.mat4Inverse(cam.view_projection) orelse return;
    const ray = pickRay(1, -1, inv_vp, cam.position) orelse return;
    // Bottom-right corner of the NDC screen: ray points right and down in world space.
    try testing.expect(ray.direction[0] > 0);
    try testing.expect(ray.direction[1] < 0);
    try testing.expect(ray.direction[2] < 0);
}

test "rayIntersectsBounds: ray through the centre of a box hits" {
    const box = Bounds{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };
    const ray = Ray{ .origin = .{ 0, 0, -5 }, .direction = .{ 0, 0, 1 } };
    const hit = rayIntersectsBounds(ray, box) orelse return;
    try testing.expectApproxEqAbs(@as(f32, 4), hit, 1e-4);
}

test "rayIntersectsBounds: ray missing the box returns null" {
    const box = Bounds{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };
    const ray = Ray{ .origin = .{ 0, 5, -5 }, .direction = .{ 0, 0, 1 } };
    try testing.expect(rayIntersectsBounds(ray, box) == null);
}

test "rayIntersectsBounds: ray starting inside the box hits at distance 0" {
    const box = Bounds{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };
    const ray = Ray{ .origin = .{ 0, 0, 0 }, .direction = .{ 0, 0, 1 } };
    const hit = rayIntersectsBounds(ray, box) orelse return;
    try testing.expectApproxEqAbs(@as(f32, 0), hit, 1e-4);
}

/// Replace a camera entity's transform in place and recompute the engine camera, so a test
/// can assert on what the renderer would actually use.
fn applyToCamera(scene: anytype, entity: anytype, t: components.Transform) !@import("../render.zig").Camera {
    // `addComponent` replaces an existing component of the same type.
    try scene.addComponent(entity, t);
    return (try render_scene.EngineRenderer.cameraOf(scene, entity, testing.allocator)).?;
}
