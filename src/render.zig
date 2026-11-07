//! CoreXEngine render subsystem — backend-independent extraction layer.
//!
//! This is the CPU-side foundation every renderer tier (Low/Medium/Advanced)
//! consumes: camera math, frustum culling, and draw-list extraction from the
//! scene. It has no GPU dependency, so it is fully testable headlessly. A CPU
//! software rasterizer turns the extracted draw list into an RGBA8 framebuffer;
//! GPU backends and the tier implementations are still planned.
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
//! // frame.commands is a culled, sorted draw list.
//! // Rasterize it on the CPU (resources resolves mesh/material handles):
//! var target = try R.Target.init(w, h, color_bytes, depth_values);
//! target.clear(.{ 0, 0, 0, 255 }, 1.0);
//! const stats = try R.rasterize(&target, frame.commands, cam.view_projection, resources, .{});
//! ```
//!
//! See `docs/render-extraction.md` for extraction and `docs/render-raster.md`
//! for the software rasterizer.

const std = @import("std");

/// Camera view/projection math (right-handed, OpenGL-style clip space).
pub const camera = @import("render/camera.zig");
/// Frustum culling primitives (AABB/sphere vs. frustum planes).
pub const culling = @import("render/culling.zig");
/// Draw-list extraction from a scene.
pub const draw = @import("render/draw.zig");
/// CPU software rasterizer (fixed-point coverage + f32 depth buffer).
pub const raster = @import("render/raster.zig");

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

/// Renderer tier contract shared by every backend (`low`/`medium`/`advanced`)
/// and the CPU driver that implements it today; see `docs/render-backend.md`.
pub const backend = @import("render/backend.zig");
pub const Tier = backend.Tier;
pub const Backend = backend.Backend;
pub const BackendSurface = backend.Surface;
pub const FrameOptions = backend.FrameOptions;
pub const FrameStats = backend.FrameStats;
pub const DrawStats = backend.DrawStats;
pub const DrawResources = backend.DrawResources;
pub const SoftwareBackend = backend.SoftwareBackend;
pub const capabilities = backend.capabilities;
pub const unsupported = backend.unsupported;

/// Frame pipeline over the tier contract: tier selection, option resolution,
/// `mvp` folding and the per-frame loop; see `docs/render-backend.md`.
pub const pipeline = @import("render/pipeline.zig");
pub const renderScene = pipeline.renderScene;
pub const renderFrame = pipeline.renderFrame;
pub const tierFromConfig = pipeline.tierFromConfig;
pub const backendFor = pipeline.backendFor;
pub const FrameParams = pipeline.FrameParams;
pub const FrameReport = pipeline.FrameReport;
pub const ResourceTable = pipeline.ResourceTable;
pub const AssetTable = pipeline.AssetTable;
pub const RenderHandle = pipeline.Handle;

pub const Target = raster.Target;
pub const ScreenVertex = raster.ScreenVertex;
pub const RasterMesh = raster.Mesh;
pub const RasterOptions = raster.Options;
pub const RasterStats = raster.Stats;
pub const CullMode = raster.CullMode;
pub const FrontFace = raster.FrontFace;
pub const rasterize = raster.rasterize;
pub const rasterizeAlloc = raster.rasterizeAlloc;
pub const drawMeshAlloc = raster.drawMeshAlloc;
pub const drawMesh = raster.drawMesh;
pub const rasterTriangle = raster.rasterTriangle;
/// RGBA8 texture sampled by the software rasterizer (top-down rows).
pub const RasterTexture = raster.Texture;
/// Texture minification filter (`nearest` or `bilinear`).
pub const TextureFilter = raster.Filter;
/// Framebuffer blend mode (`Options.blend`): `none`, `alpha`,
/// `premultiplied` or `additive`.
pub const Blend = raster.Blend;
/// Edge antialiasing mode (`Options.antialias`): `none` (one sample, default)
/// or `edge` (16 sub-samples per pixel, translucent edge fragments).
pub const Antialias = raster.Antialias;
/// Mip level selection for textured draws (`Options.mipmap`): `level0`
/// (always sample the full-size level), `trilinear` (pick from the screen-space
/// UV gradient and mix two levels; default) or `anisotropic` (up to eight taps
/// along an elongated footprint).
pub const Mipmap = raster.Mipmap;
/// Per-draw refinement of that choice (`Options.sampling`): a LOD bias in levels
/// and a cap on the anisotropic tap count. `Sampling{}` is the identity, so it
/// changes no existing frame; a tier without `sampling_controls` renders with the
/// uncorrected level instead of refusing.
pub const Sampling = raster.Sampling;
/// One mip level of a `RasterTexture` (`Texture.mips`, largest first).
pub const MipLevel = raster.MipLevel;
/// Builds the mip chain a `RasterTexture` samples when minifying.
pub const mipmap = @import("render/mipmap.zig");
/// Single directional Lambert light for the rasterizer (`Options.light`).
pub const RasterLight = raster.Light;

test {
    std.testing.refAllDecls(@This());
    _ = camera;
    _ = culling;
    _ = draw;
    _ = raster;
}
