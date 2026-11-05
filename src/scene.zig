//! CoreXEngine scene system.
//!
//! Versioned scene documents (`scene/scene.zig`) backed by the ECS, plus the
//! built-in components the engine can currently consume (`scene/components.zig`).
//! See `docs/scene-format.md` for the file format and `docs/architecture.md` for
//! subsystem status.
//!
//! Example:
//! ```zig
//! const corex = @import("corex");
//! var scene = try corex.scene.EngineScene.init(gpa, "main");
//! defer scene.deinit();
//! const e = try scene.createEntity("Player", null);
//! try scene.addComponent(e, corex.scene.Transform{ .position = .{ 0, 1, 0 } });
//! const bytes = try scene.serialize(gpa);
//! defer gpa.free(bytes);
//! ```

const std = @import("std");

pub const scene = @import("scene/scene.zig");
pub const components = @import("scene/components.zig");
/// Transform math (column-major Mat4 + quaternion helpers) used to propagate
/// local transforms into world space. Reusable by the renderer/editor.
pub const transform = @import("scene/transform.zig");
/// Reusable single-root entity subtrees (`.prefab`) built on the scene format.
pub const prefab = @import("scene/prefab.zig");

pub const Scene = scene.Scene;
pub const Component = scene.Component;
pub const Prefab = prefab.Prefab;
pub const Transform = components.Transform;
pub const Mat4 = transform.Mat4;
pub const Vec3 = transform.Vec3;
pub const Quat = transform.Quat;
pub const Error = scene.Error;
pub const format_version = scene.format_version;
pub const max_scene_bytes = scene.max_scene_bytes;
pub const max_entities = scene.max_entities;

/// The engine's default scene schema. It currently contains the built-in
/// `Transform` component; additional built-ins are added when the engine can
/// actually consume them. Games/editor tools may define their own schema with
/// `Scene(.{ Component(MyComponent, "my_component"), ... })`.
pub const EngineScene = Scene(.{Component(Transform, "transform")});

/// The engine's default prefab schema (matches `EngineScene`).
pub const EnginePrefab = Prefab(.{Component(Transform, "transform")});

test {
    std.testing.refAllDecls(@This());
    _ = scene;
    _ = components;
    _ = prefab;
}
