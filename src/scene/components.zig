//! Built-in scene components.
//!
//! Scene components are plain-data structs: they are copied into ECS sparse-set
//! pools and serialized as JSON objects. They must not contain pointers,
//! slices or allocator-owned resources; the scene serializer enforces this at
//! comptime. Add new built-ins here only when the engine can actually consume
//! them (no placeholder components).

const std = @import("std");

/// Local transform of an entity relative to its parent (or the scene root).
///
/// `rotation` is a quaternion `[x, y, z, w]`. The default is the identity
/// transform. This component stores the authored local value; world-space
/// propagation is computed at runtime by `Scene.computeWorldTransforms` /
/// `Scene.worldMatrix` (see `src/scene/transform.zig` and
/// `docs/scene-transforms.md`) and is never serialized into `.scene` files.
pub const Transform = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },

    pub const identity: Transform = .{};

    /// Reject non-finite values. JSON cannot express NaN/Infinity directly, but
    /// overflow during parsing or programmatic construction must not enter the
    /// ECS with invalid floating-point state.
    pub fn isValid(self: Transform) bool {
        for (self.position) |v| if (!std.math.isFinite(v)) return false;
        for (self.rotation) |v| if (!std.math.isFinite(v)) return false;
        for (self.scale) |v| if (!std.math.isFinite(v)) return false;
        return true;
    }
};

test "Transform defaults to identity and is valid" {
    const t = Transform{};
    try std.testing.expectEqual(@as(f32, 0), t.position[0]);
    try std.testing.expectEqual(@as(f32, 1), t.rotation[3]);
    try std.testing.expectEqual(@as(f32, 1), t.scale[0]);
    try std.testing.expect(t.isValid());
}

test "Transform rejects non-finite values" {
    var t = Transform{};
    t.position[0] = std.math.nan(f32);
    try std.testing.expect(!t.isValid());
    t = Transform{};
    t.scale[2] = std.math.inf(f32);
    try std.testing.expect(!t.isValid());
}
