//! CoreXEngine render subsystem — backend-independent extraction layer.
//!
//! This is the CPU-side foundation every renderer tier (Low/Medium/Advanced)
//! consumes: camera math, frustum culling, and draw-list extraction from the
//! scene. It has no GPU dependency, so it is fully testable headlessly. The
//! actual GPU backends and the tier implementations are planned; this layer
//! defines the backend-independent contract they will consume.
//!
//! Example:
//! ```zig
//! const corex = @import("corex");
//! const R = corex.render;
//! // A scene schema carrying Transform + Renderable:
//! const MyScene = corex.scene.Scene(.{
//!     corex.scene.Component(corex.scene.Transform, "transform"),
//!     corex.scene.Component(R.Renderable, "renderable"),
//! });
//! var scene = try MyScene.init(gpa, "main");
//! defer scene.deinit();
//! // ... populate entities ...
//! const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, 1.0, 1.6, 0.1, 500);
//! var frame = try R.extractDrawList(&scene, cam, .front_to_back, gpa);
//! defer frame.deinit();
//! // frame.commands is a culled, sorted draw list for the GPU backend.
//! ```
//!
//! See `docs/render-extraction.md` for the design and guarantees.

const std = @import("std");

/// Camera view/projection math (right-handed, OpenGL-style clip space).
pub const camera = @import("render/camera.zig");
/// Frustum culling primitives (AABB/sphere vs. frustum planes).
pub const culling = @import("render/culling.zig");
/// Draw-list extraction from a scene.
pub const draw = @import("render/draw.zig");

pub const Camera = camera.Camera;
pub const perspective = camera.perspective;
pub const orthographic = camera.orthographic;
pub const lookAt = camera.lookAt;

pub const Aabb = culling.Aabb;
pub const Sphere = culling.Sphere;
pub const Plane = culling.Plane;
pub const Frustum = culling.Frustum;
pub const Classification = culling.Classification;
pub const transformAabb = culling.transformAabb;

pub const Renderable = draw.Renderable;
pub const DrawCommand = draw.DrawCommand;
pub const RenderFrame = draw.RenderFrame;
pub const SortMode = draw.SortMode;
pub const extractDrawList = draw.extractDrawList;

test {
    std.testing.refAllDecls(@This());
    _ = camera;
    _ = culling;
    _ = draw;
}
