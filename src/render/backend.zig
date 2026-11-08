//! Renderer tier contract: the boundary between the backend-independent draw
//! list and whatever executes it.
//!
//! CoreXEngine defines three renderer tiers — Low (broad reach, minimal feature
//! set), Medium (default) and Advanced (high-end; contract only for now). This
//! module is the **contract** they share, so a backend can be added without
//! touching the scene, the extraction layer or the caller:
//!
//! - `Tier` and `FrameOptions` — what a caller asks for, and which tier
//!   capabilities a tier must honour.
//! - `Surface` — the framebuffer a backend draws into (plain RGBA8 + `f32`
//!   depth; no GPU handle, no ownership transfer). `Surface.of(target)` adapts
//!   the software rasterizer's `Target`, so one call site can drive either path.
//! - `Backend` — the vtable a backend implements: `beginFrame`, `draw`, `endFrame`,
//!   `deinit`. It is explicit (`*anyopaque` + vtable, the same shape as
//!   `core.splash.SplashScreen`) rather than comptime-generic, because renderer
//!   backends get selected at runtime from the project configuration.
//! - `DrawResources` — the duck-typed asset resolver, as a **runtime** value:
//!   a pointer plus four function pointers instead of a comptime type. The
//!   software driver adapts the existing comptime `resources` (`mesh`, `color`,
//!   optional `texture`, optional `directionalLight`) to it, so neither contract
//!   changes and no per-vertex indirect call appears in the pixel loop.
//! - `SoftwareBackend` — the CPU driver behind this contract: the reference
//!   implementation of Medium, built on the existing rasterizer. It exists so the
//!   contract is exercised, not speculative: a GPU backend implementing the same
//!   vtable is a drop-in replacement.
//!
//! Tier capabilities are declared in one table (`capabilities`) so the tiers
//! differ by *documented, asserted* feature sets rather than by prose.
//! `beginFrame` **rejects** a request whose options the tier cannot honour
//! (`error.UnsupportedFeature`) instead of silently degrading — a project that
//! asks for antialiasing on Low is a configuration error, not a surprise.

const std = @import("std");
const draw = @import("draw.zig");
const raster = @import("raster.zig");
const transform = @import("../scene/transform.zig");

const Allocator = std.mem.Allocator;
const Mat4 = transform.Mat4;
const DrawCommand = draw.DrawCommand;

const testing = std.testing;

pub const Tier = enum {
    low,
    medium,
    /// Contract only: no backend implements it yet.
    advanced,

    pub fn name(self: Tier) []const u8 {
        return @tagName(self);
    }
};

/// Features a tier may or may not provide. Additive: a new feature is a new
/// field here plus the capability table entry, never a change to `FrameOptions`.
pub const Capabilities = struct {
    /// `FrameOptions.blend` may be anything but `.none`.
    blending: bool,
    /// `FrameOptions.antialias == .edge`.
    antialias: bool,
    /// `FrameOptions.mipmap == .trilinear` on a texture that carries mips.
    mipmaps: bool,
    /// `FrameOptions.mipmap == .anisotropic` may be honoured: the same levels,
    /// sampled with several taps along an elongated pixel footprint. Asked of a
    /// tier with `mipmaps` but not this one, `pipeline.resolve` coerces it to
    /// `.trilinear` — a quality loss at grazing angles, not a wrong frame.
    anisotropic: bool,
    /// `FrameOptions.light` (or a provider light) may be set.
    lighting: bool,
    /// A textured draw may bind a texture at all.
    textures: bool,
    /// Depth-stencil target (`Surface.depth`) is written and tested.
    depth: bool,
    /// `FrameOptions.sampling` may deviate from the default: a LOD bias or a
    /// reduced tap cap. Only meaningful where mip levels are sampled at all.
    sampling_controls: bool,
};

/// The documented capability of each tier. Low is the floor ("broad hardware
/// reach"): no blending, no antialiasing, no mip selection, no lighting, no
/// textures — untextured, unlit, opaque geometry with a depth buffer. Medium is
/// everything the CPU rasterizer implements today. Advanced is the same set until
/// a backend exists, and is deliberately *not* implied by Medium.
pub fn capabilities(tier: Tier) Capabilities {
    return switch (tier) {
        .low => .{
            .blending = false,
            .antialias = false,
            .mipmaps = false,
            .anisotropic = false,
            .lighting = false,
            .textures = false,
            .depth = true,
            .sampling_controls = false,
        },
        .medium => .{
            .blending = true,
            .antialias = true,
            .mipmaps = true,
            .anisotropic = true,
            .lighting = true,
            .textures = true,
            .depth = true,
            .sampling_controls = true,
        },
        .advanced => .{
            .blending = true,
            .antialias = true,
            .mipmaps = true,
            .anisotropic = true,
            .lighting = true,
            .textures = true,
            .depth = true,
            .sampling_controls = true,
        },
    };
}

/// What the caller asks of one frame. The tier decides whether it can be
/// honoured; `beginFrame` refuses the frame if not.
pub const FrameOptions = struct {
    blend: raster.Blend = .none,
    antialias: raster.Antialias = .none,
    mipmap: raster.Mipmap = .trilinear,
    /// Per-draw refinement of the mip choice (level bias, anisotropic tap cap).
    /// Resolved by `pipeline.resolve` against the tier.
    sampling: raster.Sampling = .{},
    light: ?raster.Light = null,
    depth_test: bool = true,
    depth_write: bool = true,
    cull: raster.CullMode = .back,
    front_face: raster.FrontFace = .counter_clockwise,

    /// The options the software rasterizer takes, for a backend that delegates
    /// to it. Kept as one function so a new `FrameOptions` field cannot be
    /// forgotten on one side.
    pub fn rasterOptions(self: FrameOptions) raster.Options {
        return .{
            .cull = self.cull,
            .front_face = self.front_face,
            .depth_test = self.depth_test,
            .depth_write = self.depth_write,
            .light = self.light,
            .blend = self.blend,
            .antialias = self.antialias,
            .mipmap = self.mipmap,
            .sampling = self.sampling,
        };
    }
};

/// The framebuffer a backend draws into: borrowed, row-major, top-down RGBA8
/// plus one `f32` depth value per pixel. Deliberately plain data — a GPU backend
/// keeps its own handles behind the vtable and only needs this shape for a
/// readback target or the reference path.
pub const Surface = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes.
    color: []u8,
    /// `width * height` values in `[0, 1]`, `1` = far plane.
    depth: []f32,

    /// Adapt the rasterizer's `Target`. Both structs describe the same buffers;
    /// this is a cast, not a copy.
    pub fn of(target: *const raster.Target) Surface {
        return .{ .width = target.width, .height = target.height, .color = target.color, .depth = target.depth };
    }

    pub fn pixelCount(self: Surface) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    /// Structural validation; a backend calls this before writing.
    pub fn validate(self: Surface) error{InvalidSurface}!void {
        if (self.width == 0 or self.height == 0) return error.InvalidSurface;
        if (self.width > raster.max_dimension or self.height > raster.max_dimension) return error.InvalidSurface;
        const pixels = @as(usize, self.width) * @as(usize, self.height);
        if (self.depth.len != pixels) return error.InvalidSurface;
        if (self.color.len != pixels * 4) return error.InvalidSurface;
    }

    /// Reset to `rgba` and the far plane (`depth = 1`). Same definition as
    /// `Target.clear`, expressed once on the borrowed surface.
    pub fn clear(self: Surface, rgba: [4]u8, depth_value: f32) void {
        var i: usize = 0;
        while (i < self.pixelCount()) : (i += 1) {
            self.color[i * 4 + 0] = rgba[0];
            self.color[i * 4 + 1] = rgba[1];
            self.color[i * 4 + 2] = rgba[2];
            self.color[i * 4 + 3] = rgba[3];
            self.depth[i] = depth_value;
        }
    }
};

/// Per-draw statistics, one entry per `draw` call. A backend that batches draws
/// reports one entry per submitted command, in submission order.
pub const DrawStats = struct {
    /// Geometry handles resolved, and the draw reached the backend.
    submitted: usize = 0,
    /// Rejected before touching the surface.
    skipped: usize = 0,
    /// Shaded fragments actually written (partial antialiased ones included).
    pixels: usize = 0,
    /// Of `pixels`, how many were written with partial coverage.
    antialiased: usize = 0,
    /// Triangles the backend culled or clipped for this draw.
    culled: usize = 0,
};

/// Accumulated frame statistics.
pub const FrameStats = struct {
    /// Draw calls the backend accepted.
    draws: usize = 0,
    submitted: usize = 0,
    skipped: usize = 0,
    pixels: usize = 0,
    /// Pixels written with partial antialiased coverage.
    antialiased_pixels: usize = 0,
    /// Triangles the backend culled or clipped.
    culled: usize = 0,

    pub fn add(self: *FrameStats, one: DrawStats) void {
        self.draws += 1;
        self.submitted += one.submitted;
        self.skipped += one.skipped;
        self.pixels += one.pixels;
    }
};

pub const Error = error{
    /// `beginFrame` was not called, or the frame was already ended.
    FrameNotBegun,
    /// `beginFrame` was called twice without `endFrame`.
    FrameAlreadyBegun,
    /// The surface is malformed (zero/oversized dimensions, wrong buffer sizes).
    InvalidSurface,
    /// The requested options exceed what this tier provides.
    UnsupportedFeature,
    /// A material or mesh handle could not be resolved.
    UnresolvedHandle,
    /// A bound texture is malformed (dimensions, buffer length or mip chain).
    InvalidTexture,
    OutOfMemory,
};

/// The **runtime** asset resolver. Handles are opaque `u32`s on `DrawCommand`;
/// a backend asks for the data behind them.
///
/// `mesh`/`color` are required; `texture` and `light` may be null, which is
/// exactly the optional-declaration semantics of the comptime `resources` the
/// rasterizer takes (`@hasDecl` on `texture`/`directionalLight`). Function
/// pointers rather than a vtable struct keep the shape equal to the comptime
/// path, so `fromComptime` is a pure adapter.
/// Compile-time contract of `DrawResources.fromComptime`: the argument is a
/// pointer to the provider, never a provider by value.
fn assertProviderPointer(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size != .one) @compileError(
            "fromComptime takes a single-item pointer to the provider: pass &provider",
        ),
        else => @compileError(
            "fromComptime takes a pointer to the provider: pass &provider, not the provider itself",
        ),
    }
}

pub const DrawResources = struct {
    ptr: *anyopaque,
    meshFn: *const fn (ptr: *anyopaque, handle: u32) ?raster.Mesh,
    colorFn: *const fn (ptr: *anyopaque, handle: u32) ?[4]f32,
    textureFn: ?*const fn (ptr: *anyopaque, handle: u32) ?raster.Texture = null,
    lightFn: ?*const fn (ptr: *anyopaque) ?raster.Light = null,
    /// Per-material sampling controls, if the provider offers them.
    samplingFn: ?*const fn (ptr: *anyopaque, handle: u32) ?raster.Sampling = null,

    pub fn mesh(self: DrawResources, handle: u32) ?raster.Mesh {
        return self.meshFn(self.ptr, handle);
    }

    pub fn color(self: DrawResources, handle: u32) ?[4]f32 {
        return self.colorFn(self.ptr, handle);
    }

    pub fn texture(self: DrawResources, handle: u32) ?raster.Texture {
        const f = self.textureFn orelse return null;
        return f(self.ptr, handle);
    }

    /// The sampling controls of the material `handle`, or null when the material
    /// asks for the frame's own values. Resolved per draw: two meshes sharing a
    /// frame can want different sharpness, which is the entire reason this is a
    /// material property rather than a frame parameter.
    pub fn sampling(self: DrawResources, handle: u32) ?raster.Sampling {
        const f = self.samplingFn orelse return null;
        return f(self.ptr, handle);
    }

    pub fn directionalLight(self: DrawResources) ?raster.Light {
        const f = self.lightFn orelse return null;
        return f(self.ptr);
    }

    /// Wrap a comptime resource provider (anything with `mesh`/`color` and
    /// optionally `texture`/`directionalLight`) once per frame. The provider must
    /// outlive the returned value; nothing is copied.
    ///
    /// The adapter never inspects the provider beyond `@hasDecl`, so a provider
    /// that compiles for `raster.rasterize` also compiles here.
    ///
    /// The argument is a **pointer on purpose**. Taking the address of an `anytype`
    /// parameter would hand out a dangling pointer to the callee's own copy: it
    /// happens to read correctly at `-O Debug` only because the dead stack slot is
    /// not overwritten, and it silently loses the provider's fields as soon as the
    /// optimizer reuses the slot (observed as a `ReleaseSafe`-only conformance
    /// failure). Passing `&provider` makes the borrow explicit and checked.
    pub fn fromComptime(provider: anytype) DrawResources {
        const Ptr = @TypeOf(provider);
        assertProviderPointer(Ptr);
        const P = @typeInfo(Ptr).pointer.child;
        const Adapter = struct {
            fn mesh(ptr: *anyopaque, handle: u32) ?raster.Mesh {
                const self: *const P = @ptrCast(@alignCast(ptr));
                return self.mesh(handle);
            }
            fn color(ptr: *anyopaque, handle: u32) ?[4]f32 {
                const self: *const P = @ptrCast(@alignCast(ptr));
                return self.color(handle);
            }
            fn texture(ptr: *anyopaque, handle: u32) ?raster.Texture {
                const self: *const P = @ptrCast(@alignCast(ptr));
                return self.texture(handle);
            }
            fn light(ptr: *anyopaque) ?raster.Light {
                const self: *const P = @ptrCast(@alignCast(ptr));
                return self.directionalLight();
            }
            fn sampling(ptr: *anyopaque, handle: u32) ?raster.Sampling {
                const self: *const P = @ptrCast(@alignCast(ptr));
                return self.sampling(handle);
            }
        };
        const has_texture = comptime @hasDecl(P, "texture");
        const has_light = comptime @hasDecl(P, "directionalLight");
        const has_sampling = comptime @hasDecl(P, "sampling");
        return .{
            .ptr = @ptrCast(@constCast(provider)),
            .meshFn = Adapter.mesh,
            .colorFn = Adapter.color,
            .textureFn = if (has_texture) Adapter.texture else null,
            .lightFn = if (has_light) Adapter.light else null,
            .samplingFn = if (has_sampling) Adapter.sampling else null,
        };
    }
};

/// The backend contract. One vtable per backend; the caller drives it.
///
/// Lifecycle: `beginFrame(surface, options)` → N × `draw(...)` → `endFrame()`,
/// then repeat. `deinit` releases whatever the backend owns; the surface, the
/// draw list and the resources are all borrowed and never freed here.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The tier this backend implements.
        tier: *const fn (ptr: *anyopaque) Tier,
        /// Prepare `surface` for one frame. Rejects unsupported options.
        beginFrame: *const fn (ptr: *anyopaque, surface: Surface, options: FrameOptions) Error!void,
        /// Draw one command. `mvp` is `view_projection * command.world`, folded
        /// once by the caller so backends never recompute it per draw.
        draw: *const fn (ptr: *anyopaque, command: DrawCommand, mvp: Mat4, resources: DrawResources) Error!DrawStats,
        /// Finish the frame and hand back its statistics.
        endFrame: *const fn (ptr: *anyopaque) Error!FrameStats,
        /// Release backend-owned resources. The `Allocator` is the one the
        /// backend was created with.
        deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
    };

    pub fn tier(self: Backend) Tier {
        return self.vtable.tier(self.ptr);
    }

    pub fn beginFrame(self: Backend, surface: Surface, options: FrameOptions) Error!void {
        return self.vtable.beginFrame(self.ptr, surface, options);
    }

    pub fn draw(self: Backend, command: DrawCommand, mvp: Mat4, resources: DrawResources) Error!DrawStats {
        return self.vtable.draw(self.ptr, command, mvp, resources);
    }

    pub fn endFrame(self: Backend) Error!FrameStats {
        return self.vtable.endFrame(self.ptr);
    }

    pub fn deinit(self: Backend, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

/// The subset of `FrameOptions` that `tier` cannot honour, or `null` when the
/// frame is acceptable. Pure, so callers can validate before touching a surface.
pub fn unsupported(tier: Tier, options: FrameOptions) ?[]const u8 {
    const caps = capabilities(tier);
    if (!caps.depth and (options.depth_test or options.depth_write)) return "depth";
    if (!caps.blending and options.blend != .none) return "blend";
    if (!caps.antialias and options.antialias != .none) return "antialias";
    // Level selection is only meaningful where textures exist at all; a tier
    // without them cannot sample any level, so the mode is not a request.
    if (caps.textures and !caps.mipmaps and options.mipmap != .level0) return "mipmap";

    if (!caps.lighting and options.light != null) return "light";
    return null;
}

test "capabilities: Low is the documented floor, Medium the full CPU feature set" {
    const low = capabilities(.low);
    try std.testing.expect(!low.blending);
    try std.testing.expect(!low.antialias);
    try std.testing.expect(!low.mipmaps);
    try std.testing.expect(!low.lighting);
    try std.testing.expect(!low.textures);
    // Depth is the one feature Low must have: it is what makes overdraw correct.
    try std.testing.expect(low.depth);

    const medium = capabilities(.medium);
    try std.testing.expect(medium.blending and medium.antialias and medium.mipmaps);
    try std.testing.expect(medium.lighting and medium.textures and medium.depth);

    // Medium does not imply Advanced: the enums stay distinct values.
    try std.testing.expect(capabilities(.advanced).blending);
    try std.testing.expect(!std.meta.eql(Tier.medium, Tier.advanced));
}

test "unsupported: every requested feature is named, defaults are accepted" {
    try std.testing.expectEqual(@as(?[]const u8, null), unsupported(.low, .{}));
    try std.testing.expectEqualStrings("blend", unsupported(.low, .{ .blend = .alpha }).?);
    try std.testing.expectEqualStrings("antialias", unsupported(.low, .{ .antialias = .edge }).?);
    // Low has no textures, so level selection is moot there and the default
    // options are accepted; Medium, which does have textures, may still be
    // configured without mipmaps and must then be asked for `.level0`.
    try std.testing.expectEqual(@as(?[]const u8, null), unsupported(.low, .{ .mipmap = .trilinear }));
    try std.testing.expectEqualStrings("light", unsupported(.low, .{ .light = .{ .direction = .{ 0, 0, 1 } } }).?);
    // `mipmap = .level0` is what Low samples anyway, so it is not a request.
    try std.testing.expectEqual(@as(?[]const u8, null), unsupported(.low, .{ .mipmap = .level0 }));
    // Medium accepts everything the CPU path implements.
    try std.testing.expectEqual(@as(?[]const u8, null), unsupported(.medium, .{
        .blend = .additive,
        .antialias = .edge,
        .mipmap = .trilinear,
        .light = .{ .direction = .{ 0, 0, 1 } },
    }));
}

test "Surface.of borrows the target's buffers and validates them" {
    var color: [4 * 4 * 4]u8 = undefined;
    var depth: [4 * 4]f32 = undefined;
    var target = try raster.Target.init(4, 4, &color, &depth);
    const surface = Surface.of(&target);
    try testing.expectEqual(@as(u32, 4), surface.width);
    try testing.expectEqual(@as(usize, 16), surface.pixelCount());
    try surface.validate();
    // Same memory: clearing through the surface is visible on the target.
    surface.clear(.{ 1, 2, 3, 4 }, 0.5);
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, target.colorAt(0, 0));
    try testing.expectEqual(@as(f32, 0.5), target.depthAt(3, 3));

    var bad = Surface{ .width = 4, .height = 4, .color = &color, .depth = depth[0..15] };
    try testing.expectError(error.InvalidSurface, bad.validate());
    bad = .{ .width = 0, .height = 4, .color = &color, .depth = &depth };
    try testing.expectError(error.InvalidSurface, bad.validate());
}

/// The CPU driver behind this contract: the reference implementation of Medium,
/// built on the existing rasterizer (coverage, depth, blending, textures, Lambert
/// lighting, edge antialiasing, mip selection). It exists so the contract is
/// exercised end to end by tests rather than declared and unused — a GPU backend
/// is a drop-in replacement for this value.
///
/// Ownership: the backend owns only its state; the surface, the draw list and the
/// resource provider are borrowed for the duration of the calls. `antialias`
/// needs scratch, so the backend takes the allocator once at creation.
pub const SoftwareBackend = struct {
    gpa: Allocator,
    tier_value: Tier,
    surface: ?Surface = null,
    frame_options: FrameOptions = .{},
    stats: FrameStats = .{},
    /// Set by `beginFrame` when the accepted surface is the rasterizer's own
    /// `Target` shape; `draw` rebuilds the `Target` from the borrowed buffers so
    /// the rasterizer keeps its existing entry points untouched.
    in_frame: bool = false,

    pub fn init(gpa: Allocator, tier_value: Tier) SoftwareBackend {
        return .{ .gpa = gpa, .tier_value = tier_value };
    }

    pub fn interface(self: *SoftwareBackend) Backend {
        return .{ .ptr = self, .vtable = &.{
            .tier = tierFn,
            .beginFrame = beginFrameFn,
            .draw = drawFn,
            .endFrame = endFrameFn,
            .deinit = deinitFn,
        } };
    }

    fn tierFn(ptr: *anyopaque) Tier {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        return self.tier_value;
    }

    /// This backend's capabilities, resolved through the one table.
    fn caps(self: SoftwareBackend) Capabilities {
        return capabilities(self.tier_value);
    }

    fn beginFrameFn(ptr: *anyopaque, surface: Surface, options: FrameOptions) Error!void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        if (self.in_frame) return error.FrameAlreadyBegun;
        try surface.validate();
        if (unsupported(self.tier_value, options)) |_| return error.UnsupportedFeature;
        self.surface = surface;
        self.frame_options = options;
        self.stats = .{};
        self.in_frame = true;
    }

    fn drawFn(ptr: *anyopaque, cmd: DrawCommand, mvp: Mat4, resources: DrawResources) Error!DrawStats {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        if (!self.in_frame) return error.FrameNotBegun;
        var stats = DrawStats{};
        const mesh = resources.mesh(cmd.mesh) orelse {
            stats.skipped = 1;
            self.stats.add(stats);
            return stats;
        };
        const linear = resources.color(cmd.material) orelse {
            stats.skipped = 1;
            self.stats.add(stats);
            return stats;
        };
        stats.submitted = 1;
        var rgba: [4]u8 = undefined;
        for (&rgba, linear) |*out, component| {
            out.* = @intFromFloat(@round(std.math.clamp(component, 0.0, 1.0) * 255.0));
        }
        // Textures are only asked for when the tier provides them; Low must not
        // even consult the provider.
        var texture: ?raster.Texture = null;
        if (self.caps().textures) {
            if (resources.texture(cmd.material)) |tex| {
                tex.validate() catch return error.InvalidTexture;
                const uv_ok = if (mesh.uvs) |uvs| uvs.len == mesh.positions.len else false;
                if (!uv_ok) {
                    stats = .{ .skipped = 1 };
                    self.stats.add(stats);
                    return stats;
                }
                texture = tex;
            }
        } else if (resources.textureFn != null and resources.texture(cmd.material) != null) {
            // A material that binds a texture on a tier without textures is a
            // configuration error: degrading silently would render flat and
            // "work", hiding the mistake.
            return error.UnsupportedFeature;
        }
        var options = self.frame_options;
        // A material's own sampling controls win when the tier has them: the frame
        // values are the default a material overrides, not a cap it must live under.
        if (self.caps().sampling_controls) {
            if (resources.sampling(cmd.material)) |material_sampling| options.sampling = material_sampling;
        }
        // Same precedence as the rasterizer: explicit options beat the provider.
        if (options.light == null and self.caps().lighting) {
            if (resources.directionalLight()) |light| options.light = light;
        }
        const surface = self.surface.?;
        var target = raster.Target{
            .width = surface.width,
            .height = surface.height,
            .color = surface.color,
            .depth = surface.depth,
        };
        // `mvp` is already `view_projection * world`: pass the identity as the
        // world matrix so the rasterizer folds it exactly once.
        const result = raster.drawMeshAlloc(
            self.gpa,
            &target,
            mesh,
            transform.identity(),
            mvp,
            rgba,
            options.rasterOptions(),
            texture,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTexture => return error.InvalidTexture,
            // An index/UV problem on one command is a skipped draw, not a
            // frame failure: the other commands still render.
            error.InvalidIndex, error.InvalidUv => {
                stats = .{ .submitted = 1, .skipped = 1 };
                self.stats.add(stats);
                return stats;
            },
            else => return error.UnresolvedHandle,
        };
        stats.pixels = result.pixels;
        stats.antialiased = result.antialiased_pixels;
        stats.culled = result.culled + result.clipped;
        self.stats.culled += stats.culled;
        self.stats.antialiased_pixels += result.antialiased_pixels;
        self.stats.add(stats);
        return stats;
    }

    fn endFrameFn(ptr: *anyopaque) Error!FrameStats {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        if (!self.in_frame) return error.FrameNotBegun;
        self.in_frame = false;
        self.surface = null;
        const stats = self.stats;
        self.stats = .{};
        return stats;
    }

    /// Releasing the backend is closing any open frame: the struct itself is
    /// owned by the caller (it may live on the stack), so it is never freed here
    /// and `gpa` is unused — the rasterizer's scratch is per draw.
    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        self.in_frame = false;
        self.surface = null;
        self.stats = .{};
        _ = gpa;
    }
};

// --- end-to-end tests over the contract --------------------------------------

/// The shared 8x8 test surface for the backend tests.
const TestSurface = struct {
    color: [8 * 8 * 4]u8 = @splat(0),
    depth: [8 * 8]f32 = @splat(1.0),
    target: ?raster.Target = null,

    fn init(self: *TestSurface) !raster.Target {
        self.target = try raster.Target.init(8, 8, &self.color, &self.depth);
        return self.target.?;
    }
};

fn ortho() Mat4 {
    return @import("camera.zig").orthographic(-2, 2, -2, 2, 0, 4) catch unreachable;
}

const quad_positions = [_][3]f32{ .{ -2, -2, -2 }, .{ 2, -2, -2 }, .{ 2, 2, -2 }, .{ -2, 2, -2 } };
const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
const quad_uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
const quad_mesh = raster.Mesh{ .positions = &quad_positions, .indices = &quad_indices, .uvs = &quad_uvs };

/// A comptime provider in exactly the shape the rasterizer accepts, so the test
/// proves the runtime adapter is faithful rather than merely similar.
const Provider = struct {
    texture_handle: bool = false,
    const all_red = [_]u8{ 255, 0, 0, 255 };

    pub fn mesh(self: Provider, handle: u32) ?raster.Mesh {
        _ = self;
        _ = handle;
        return quad_mesh;
    }

    pub fn color(self: Provider, handle: u32) ?[4]f32 {
        _ = self;
        _ = handle;
        return .{ 0.25, 0.5, 0.75, 1.0 };
    }

    pub fn texture(self: Provider, handle: u32) ?raster.Texture {
        _ = handle;
        if (!self.texture_handle) return null;
        return .{ .width = 1, .height = 1, .pixels = &all_red, .filter = .nearest };
    }
};

/// A provider that exposes per-material sampling controls.
const SamplingProvider = struct {
    pub fn mesh(_: SamplingProvider, _: u32) ?raster.Mesh {
        return quad_mesh;
    }
    pub fn color(_: SamplingProvider, _: u32) ?[4]f32 {
        return .{ 1, 1, 1, 1 };
    }
    pub fn sampling(_: SamplingProvider, handle: u32) ?raster.Sampling {
        if (handle != 7) return null;
        return .{ .lod_bias = 1.5, .max_samples = 4 };
    }
};

/// A 8x8 texture whose chain ends in a flat white 1x1 level, drawn minified so the
/// chosen level is visible; `bias` comes from the per-material sampling controls.
const MippedProvider = struct {
    bias: f64,

    const level0 = [_]u8{
        255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255,
        0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255,
        255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255,
        0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255,
        255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255,
        0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255,
        255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255,
        0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255, 0,   255, 0, 255, 255, 0,   0, 255,
    };
    const level1 = [_]u8{
        128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255,
        128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255,
        128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255,
        128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255, 128, 128, 0, 255,
    };
    const level2 = [_]u8{
        128, 128, 0, 255, 128, 128, 0, 255,
        128, 128, 0, 255, 128, 128, 0, 255,
    };
    const level3 = [_]u8{
        255, 255, 255, 255,
    };
    const mips = [_]raster.MipLevel{
        .{ .width = 4, .height = 4, .pixels = &level1 },
        .{ .width = 2, .height = 2, .pixels = &level2 },
        .{ .width = 1, .height = 1, .pixels = &level3 },
    };
    // 2 texels per pixel over the 8 px quad: the unbiased level is 1 (the flat
    // olive 4x4 level), so a +3 bias saturates on the white 1x1 one.
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const mipped_mesh = raster.Mesh{ .positions = &quad_positions, .indices = &quad_indices, .uvs = &uvs };

    pub fn mesh(_: MippedProvider, _: u32) ?raster.Mesh {
        return mipped_mesh;
    }

    pub fn color(_: MippedProvider, _: u32) ?[4]f32 {
        return .{ 1, 1, 1, 1 };
    }

    pub fn texture(_: MippedProvider, _: u32) ?raster.Texture {
        return .{ .width = 8, .height = 8, .pixels = &level0, .mips = &mips, .filter = .bilinear };
    }

    pub fn sampling(self: MippedProvider, _: u32) ?raster.Sampling {
        return .{ .lod_bias = self.bias };
    }
};

const LightProvider = struct {
    pub fn mesh(_: LightProvider, _: u32) ?raster.Mesh {
        return quad_mesh;
    }
    pub fn color(_: LightProvider, _: u32) ?[4]f32 {
        return .{ 1.0, 1.0, 1.0, 1.0 };
    }
    pub fn directionalLight(_: LightProvider) ?raster.Light {
        return .{ .direction = .{ 0, 0, 1 }, .color = .{ 0.5, 0.0, 0.0 }, .ambient = .{ 0, 0, 0 } };
    }
};

/// A provider with no optional declarations at all.
const NoExtras = struct {
    pub fn mesh(_: NoExtras, _: u32) ?raster.Mesh {
        return quad_mesh;
    }
    pub fn color(_: NoExtras, _: u32) ?[4]f32 {
        return .{ 1, 1, 1, 1 };
    }
};

/// A provider whose `texture` decl is private: `@hasDecl` must not see it, and
/// neither must the runtime adapter.
const PrivateExtras = struct {
    pub fn mesh(_: PrivateExtras, _: u32) ?raster.Mesh {
        return quad_mesh;
    }
    pub fn color(_: PrivateExtras, _: u32) ?[4]f32 {
        return .{ 1, 1, 1, 1 };
    }
    fn texture(_: PrivateExtras, _: u32) ?raster.Texture {
        return null;
    }
};

fn testCommand() DrawCommand {
    return .{
        .entity = .{ .index = 1, .generation = 0 },
        .mesh = 0,
        .material = 0,
        .world = transform.identity(),
        .bounds = .{ .center = .{ 0, 0, -2 }, .extents = .{ 2, 2, 0.5 } },
        .depth = 2,
    };
}

test "backend: the software backend is bit-identical to the rasterizer it drives" {
    // Same command, same surface, same options: the contract layer must not
    // change a single byte. This is the property that makes the CPU path a valid
    // reference for the GPU backends.
    const provider = Provider{};

    var direct_color: [8 * 8 * 4]u8 = @splat(0);
    var direct_depth: [8 * 8]f32 = @splat(1.0);
    var direct = try raster.Target.init(8, 8, &direct_color, &direct_depth);
    direct.clear(.{ 0, 0, 0, 255 }, 1.0);
    const direct_stats = try raster.drawMeshAlloc(
        testing.allocator,
        &direct,
        quad_mesh,
        transform.identity(),
        ortho(),
        .{ 64, 128, 191, 255 },
        .{ .blend = .alpha },
        null,
    );

    var via_color: [8 * 8 * 4]u8 = @splat(0);
    var via_depth: [8 * 8]f32 = @splat(1.0);
    var via = try raster.Target.init(8, 8, &via_color, &via_depth);
    via.clear(.{ 0, 0, 0, 255 }, 1.0);

    var backend = SoftwareBackend.init(testing.allocator, .medium);
    const iface = backend.interface();
    defer iface.deinit(testing.allocator);
    try iface.beginFrame(Surface.of(&via), .{ .blend = .alpha });
    const one = try iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&provider));
    const frame = try iface.endFrame();

    try testing.expectEqualSlices(u8, &direct_color, &via_color);
    try testing.expectEqualSlices(f32, &direct_depth, &via_depth);
    try testing.expectEqual(direct_stats.pixels, one.pixels);
    try testing.expectEqual(@as(usize, 1), frame.draws);
    try testing.expectEqual(@as(usize, 1), frame.submitted);
    try testing.expectEqual(@as(usize, 64), frame.pixels);
}

test "backend: culling, skipped draws and the frame stats add up" {
    const provider = Provider{};
    var surface = TestSurface{};
    var target = try surface.init();
    target.clear(.{ 0, 0, 0, 255 }, 1.0);

    var backend = SoftwareBackend.init(testing.allocator, .medium);
    const iface = backend.interface();
    defer iface.deinit(testing.allocator);
    try iface.beginFrame(Surface.of(&target), .{});

    // A back-facing quad (mirrored on X, so its winding flips) is culled before
    // any pixel. `mvp` is the caller's job: `view_projection * world`.
    var flipped = testCommand();
    flipped.world[0] = -1;
    _ = try iface.draw(flipped, transform.multiply(ortho(), flipped.world), DrawResources.fromComptime(&provider));

    // An unresolved mesh handle is a skipped draw, not an error.
    const unresolved = DrawResources{
        .ptr = @ptrCast(@constCast(&provider)),
        .meshFn = struct {
            fn f(_: *anyopaque, _: u32) ?raster.Mesh {
                return null;
            }
        }.f,
        .colorFn = struct {
            fn f(_: *anyopaque, _: u32) ?[4]f32 {
                return .{ 1, 1, 1, 1 };
            }
        }.f,
    };
    _ = try iface.draw(testCommand(), ortho(), unresolved);

    const stats = try iface.endFrame();
    try testing.expectEqual(@as(usize, 2), stats.draws);
    try testing.expectEqual(@as(usize, 1), stats.skipped);
    try testing.expectEqual(@as(usize, 0), stats.pixels);
    // `culled` counts triangles: the mirrored quad's two are both back-facing.
    try testing.expectEqual(@as(usize, 2), stats.culled);
}

test "backend: the tier gate rejects what a tier cannot do, before any pixel" {
    var surface = TestSurface{};
    var target = try surface.init();
    target.clear(.{ 7, 7, 7, 255 }, 1.0);

    var low = SoftwareBackend.init(testing.allocator, .low);
    const low_iface = low.interface();
    defer low_iface.deinit(testing.allocator);
    try testing.expectEqual(Tier.low, low_iface.tier());
    // Defaults are fine on Low: opaque, unlit, untextured geometry.
    try low_iface.beginFrame(Surface.of(&target), .{});
    const plain = try low_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&Provider{}));
    try testing.expectEqual(@as(usize, 64), plain.pixels);
    _ = try low_iface.endFrame();

    // Blending and antialiasing are not part of Low.
    try testing.expectError(error.UnsupportedFeature, low_iface.beginFrame(Surface.of(&target), .{ .blend = .alpha }));
    try testing.expectError(error.UnsupportedFeature, low_iface.beginFrame(Surface.of(&target), .{ .antialias = .edge }));
    // Rejections must not have started a frame.
    try testing.expectError(error.FrameNotBegun, low_iface.endFrame());

    // A material that binds a texture is a configuration error on a tier without
    // textures — it must not silently render flat.
    try low_iface.beginFrame(Surface.of(&target), .{});
    try testing.expectError(
        error.UnsupportedFeature,
        low_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&Provider{ .texture_handle = true })),
    );
    _ = try low_iface.endFrame();

    // Medium accepts the same frame. The surface is cleared first: the Low draw
    // above left its depth at the same value, and equal depth does not overwrite.
    target.clear(.{ 7, 7, 7, 255 }, 1.0);
    var medium = SoftwareBackend.init(testing.allocator, .medium);
    const medium_iface = medium.interface();
    defer medium_iface.deinit(testing.allocator);
    try testing.expectEqual(Tier.medium, medium_iface.tier());
    try medium_iface.beginFrame(Surface.of(&target), .{ .blend = .alpha, .antialias = .edge });
    const one = try medium_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&Provider{ .texture_handle = true }));
    const stats = try medium_iface.endFrame();
    // The quad fills the viewport exactly, so every pixel is fully covered: the
    // antialiased frame is accepted and renders, with no partial pixels to report.
    try testing.expectEqual(@as(usize, 64), one.pixels);
    try testing.expectEqual(@as(usize, 0), stats.antialiased_pixels);
}

test "backend: frame lifecycle is enforced" {
    var surface = TestSurface{};
    var target = try surface.init();
    var backend = SoftwareBackend.init(testing.allocator, .medium);
    const iface = backend.interface();
    defer iface.deinit(testing.allocator);

    try testing.expectError(error.FrameNotBegun, iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&Provider{})));
    try testing.expectError(error.FrameNotBegun, iface.endFrame());

    try iface.beginFrame(Surface.of(&target), .{});
    try testing.expectError(error.FrameAlreadyBegun, iface.beginFrame(Surface.of(&target), .{}));
    _ = try iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&Provider{}));
    _ = try iface.endFrame();
    // A second frame is fine, and a malformed surface is refused.
    var short_depth: [8 * 8 - 1]f32 = @splat(1.0);
    const bad = Surface{ .width = 8, .height = 8, .color = &surface.color, .depth = &short_depth };
    try testing.expectError(error.InvalidSurface, iface.beginFrame(bad, .{}));
    try iface.beginFrame(Surface.of(&target), .{});
    _ = try iface.endFrame();
}

test "backend: a provider light is used unless the frame options set one" {
    var surface = TestSurface{};
    var target = try surface.init();
    var backend = SoftwareBackend.init(testing.allocator, .medium);
    const iface = backend.interface();
    defer iface.deinit(testing.allocator);

    // Provider light: red diffuse from +Z over a white quad.
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    try iface.beginFrame(Surface.of(&target), .{});
    _ = try iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&LightProvider{}));
    _ = try iface.endFrame();
    try testing.expectEqual([4]u8{ 128, 0, 0, 255 }, target.colorAt(4, 4));

    // An explicit frame light wins over the provider's.
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    try iface.beginFrame(Surface.of(&target), .{ .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 0.0, 0.5, 0.0 }, .ambient = .{ 0, 0, 0 } } });
    _ = try iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&LightProvider{}));
    _ = iface.endFrame() catch unreachable;
    try testing.expectEqual([4]u8{ 0, 128, 0, 255 }, target.colorAt(4, 4));

    // A tier without lighting ignores the provider instead of lighting.
    var low = SoftwareBackend.init(testing.allocator, .low);
    const low_iface = low.interface();
    defer low_iface.deinit(testing.allocator);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    try low_iface.beginFrame(Surface.of(&target), .{});
    _ = try low_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&LightProvider{}));
    _ = try low_iface.endFrame();
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, target.colorAt(4, 4));
}

test "backend: DrawResources.fromComptime mirrors the optional declarations" {
    // The provider lives in a named local: `fromComptime` borrows it, so the
    // adapter must never be built from a temporary whose lifetime ends before the
    // first `draw`.
    var bare_provider = NoExtras{};
    const bare = DrawResources.fromComptime(&bare_provider);
    // A provider without `texture`/`directionalLight` yields null function
    // pointers, exactly like `@hasDecl` missing in the comptime path.
    try testing.expect(bare.textureFn == null);
    try testing.expect(bare.lightFn == null);
    try testing.expect(bare.mesh(0) != null);
    try testing.expectEqual(@as(?raster.Texture, null), bare.texture(0));
    try testing.expectEqual(@as(?raster.Light, null), bare.directionalLight());

    // A private `texture` decl is invisible to `@hasDecl` and must stay invisible
    // here too — the adapter inherits the same rule instead of redefining it.
    var priv_provider = PrivateExtras{};
    const priv = DrawResources.fromComptime(&priv_provider);
    try testing.expect(priv.textureFn == null);
}

test "backend: fromComptime picks up an optional sampling() and ignores its absence" {
    var with = SamplingProvider{};
    const has = DrawResources.fromComptime(&with);
    try testing.expect(has.samplingFn != null);
    const s = has.sampling(7).?;
    try testing.expectEqual(@as(f64, 1.5), s.lod_bias);
    try testing.expectEqual(@as(u8, 4), s.max_samples);
    try testing.expectEqual(@as(?raster.Sampling, null), has.sampling(999));

    // A provider without the declaration yields a null pointer and a null answer,
    // exactly like `@hasDecl` missing in the comptime path: no default is invented.
    var without = NoExtras{};
    const none = DrawResources.fromComptime(&without);
    try testing.expect(none.samplingFn == null);
    try testing.expectEqual(@as(?raster.Sampling, null), none.sampling(0));
    // Same rule for a private decl.
    var priv = PrivateExtras{};
    const hidden = DrawResources.fromComptime(&priv);
    try testing.expect(hidden.samplingFn == null);
}

test "backend: a material's sampling controls apply on a tier that has them only" {
    // A chain whose last level is a flat colour: biasing down to it turns the quad
    // flat, so the bias is visible as a colour change and not just as a number.
    var flat_provider = MippedProvider{ .bias = 0.0 };
    var biased_provider = MippedProvider{ .bias = 3.0 };

    var plain_surface = TestSurface{};
    var plain = try plain_surface.init();
    plain.clear(.{ 0, 0, 0, 255 }, 1.0);
    var medium = SoftwareBackend.init(testing.allocator, .medium);
    const medium_iface = medium.interface();
    defer medium_iface.deinit(testing.allocator);
    try medium_iface.beginFrame(Surface.of(&plain), .{ .mipmap = .trilinear });
    _ = try medium_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&flat_provider));
    _ = try medium_iface.endFrame();
    const unbiased = plain.colorAt(4, 4);

    var biased_surface = TestSurface{};
    var biased = try biased_surface.init();
    biased.clear(.{ 0, 0, 0, 255 }, 1.0);
    try medium_iface.beginFrame(Surface.of(&biased), .{ .mipmap = .trilinear });
    _ = try medium_iface.draw(testCommand(), ortho(), DrawResources.fromComptime(&biased_provider));
    _ = try medium_iface.endFrame();
    const with_bias = biased.colorAt(4, 4);

    // The bias lands on the last (1x1, white) level, so the pixel is white; without
    // it the level is fractional and the pattern still shows through.
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, with_bias);
    try testing.expect(!std.mem.eql(u8, &with_bias, &unbiased));

    // The low tier has no textures at all, so the controls cannot be observed
    // there; `pipeline.resolve` is what zeroes them, and its test pins that.
    try testing.expect(!capabilities(.low).sampling_controls);
    try testing.expect(capabilities(.medium).sampling_controls);
    try testing.expect(capabilities(.advanced).sampling_controls);
}

test "backend: a provider whose fields matter survives the frame, not just a call" {
    // Regression for a lifetime bug: `fromComptime` used to take the provider by
    // value and store the address of its own parameter, so every field read came
    // from a dead stack slot. It read correctly at -O Debug and produced the wrong
    // colour at -O ReleaseSafe. The provider below reads three fields through the
    // adapter on every handle, which no stale slot survives.
    const FieldProvider = struct {
        mesh_handle: u32 = 7,
        material_handle: u32 = 3,
        tint: [4]f32,

        pub fn mesh(self: @This(), handle: u32) ?raster.Mesh {
            if (handle != self.mesh_handle) return null;
            return quad_mesh;
        }
        pub fn color(self: @This(), handle: u32) ?[4]f32 {
            if (handle != self.material_handle) return null;
            return self.tint;
        }
    };
    var provider = FieldProvider{ .tint = .{ 0.5, 0.25, 1.0, 1.0 } };
    const resources = DrawResources.fromComptime(&provider);

    // Wrong handles must miss: that is the field being read, not a constant.
    try testing.expectEqual(@as(?raster.Mesh, null), resources.mesh(0));
    try testing.expect(resources.mesh(7) != null);
    try testing.expectEqual([4]f32{ 0.5, 0.25, 1.0, 1.0 }, resources.color(3).?);

    var cmd = testCommand();
    cmd.mesh = 7;
    cmd.material = 3;
    var surface = TestSurface{};
    var target = try surface.init();
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    var gpu = SoftwareBackend.init(testing.allocator, .medium);
    const iface = gpu.interface();
    defer iface.deinit(testing.allocator);
    try iface.beginFrame(Surface.of(&target), .{});
    _ = try iface.draw(cmd, ortho(), resources);
    _ = try iface.endFrame();
    // The tint reached the framebuffer, channel by channel.
    try testing.expectEqual([4]u8{ 128, 64, 255, 255 }, target.colorAt(4, 4));
}
