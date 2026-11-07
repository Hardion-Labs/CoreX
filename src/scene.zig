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
/// Renderable scene schema (transform + renderable + camera), the asset loader
/// behind it and the per-frame engine renderer.
pub const render_scene = @import("scene/render_scene.zig");
/// Reusable single-root entity subtrees (`.prefab`) built on the scene format.
pub const prefab = @import("scene/prefab.zig");
/// Sector residency streaming (`.corexstream`) over a live scene.
pub const stream = @import("scene/stream.zig");

pub const Scene = scene.Scene;
pub const Component = scene.Component;
pub const Prefab = prefab.Prefab;
pub const Transform = components.Transform;
pub const Renderable = render_scene.Renderable;
pub const CameraComponent = render_scene.CameraComponent;
pub const EngineRenderScene = render_scene.EngineRenderScene;
pub const EngineRenderPrefab = render_scene.EngineRenderPrefab;
pub const RenderAssets = render_scene.LoadedAssets;
pub const loadRenderAssets = render_scene.loadAssets;
pub const EngineRenderer = render_scene.EngineRenderer;
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
///
/// A scene that authors a **renderable** (or a camera) must be loaded with
/// `render_scene.EngineRenderScene`, which declares those components; the
/// serializer rejects components the schema does not know, so the schema is a
/// property of the document, not of the loader.
pub const EngineScene = Scene(.{Component(Transform, "transform")});

/// The engine's default prefab schema (matches `EngineScene`).
pub const EnginePrefab = Prefab(.{Component(Transform, "transform")});

/// The engine's default sector stream (matches `EngineScene`).
pub const EngineStream = stream.Stream(.{Component(Transform, "transform")});

test {
    std.testing.refAllDecls(@This());
    _ = scene;
    _ = components;
    _ = prefab;
    _ = stream;
}
