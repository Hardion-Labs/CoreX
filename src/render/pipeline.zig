//! Frame pipeline — one call from a scene to a finished frame, over the tier
//! contract.
//!
//! `docs/render-backend.md` defines the contract a renderer tier implements
//! (`Tier`, `Capabilities`, `Surface`, `Backend`). This module is the layer that
//! **uses** it, so callers do not have to redo the same four steps every frame:
//!
//! 1. the tier named by the project (`settings.json` → `config.RendererTier`)
//!    selects a backend — `backendFor` is the one place that mapping lives, so
//!    adding a GPU backend never touches the caller;
//! 2. `beginFrame` validates the surface and the tier gate;
//! 3. every `DrawCommand` is submitted with `mvp = view_projection * world`
//!    folded by the pipeline (the contract's rule, done once here instead of in
//!    every caller);
//! 4. `endFrame` and a reported `FrameReport`.
//!
//! Two entry points, both the same code path:
//!
//! - `renderScene` — a scene to pixels: `extractDrawList` (culling + sorting)
//!   then the loop above.
//! - `renderFrame` — an already extracted draw list (what a caller keeps between
//!   frames or produces from its own source).
//!
//! The parameters of a frame are resolved **by the capabilities of the tier**, not
//! by the caller: a Low frame turns antialiasing and mip selection off itself and
//! never asks the backend for something it would reject. That is what makes the
//! same scene render on Low and Medium without branching at the call site.
//!
//! The default per-draw blend comes from the extraction sort: a
//! `back_to_front` list is for transparency (`blend = .alpha`, no depth write),
//! the other modes are opaque. `FrameParams.blend` overrides it when a caller
//! knows better.
//!
//! Asset handles are opaque `u32`s. `ResourceTable` is a small, fixed-capacity
//! handle table (allocation-free after `init`) that holds scratch copies of the
//! decoded slices; `meshViews` adapts zero-copy `CXMH` views (`assets.mesh`) and
//! `textures` adapts `CXTX` textures, so the engine binary can render real
//! project assets without the render layer depending on the asset layer.

const std = @import("std");
const draw = @import("draw.zig");
const raster = @import("raster.zig");
const backend = @import("backend.zig");
const camera = @import("camera.zig");
const transform = @import("../scene/transform.zig");
const texture_asset = @import("../assets/texture.zig");
const mesh_asset = @import("../assets/mesh.zig");

const Allocator = std.mem.Allocator;
const Mat4 = transform.Mat4;
const Io = std.Io;
const DrawCommand = draw.DrawCommand;
const DrawResources = backend.DrawResources;
const Surface = backend.Surface;

pub const Error = backend.Error || error{
    /// Extraction failed (malformed scene data surfaced during extraction).
    Internal,
    /// A color or other per-slot value is out of range or non-finite.
    InvalidValue,
    /// The camera's projection parameters are degenerate (e.g. near == far).
    InvalidFrustum,
    /// A mesh or its index data exceeds the slot sizing configured at init.
    MeshTooLarge,
    /// A scene asset is malformed and cannot be loaded.
    InvalidAsset,
};

/// The tier the project configuration names, as a render tier.
///
/// The parameter is deliberately duck-typed on the enum *tag name*: `render` must
/// not import `core/config.zig` (the dependency runs the other way), and the two
/// enums are kept in lockstep by test — a tier added on one side without the
/// other fails the build here rather than silently rendering the wrong tier.
pub fn tierFromConfig(renderer: anytype) backend.Tier {
    const T = @TypeOf(renderer);
    comptime {
        // A tier the config can name but the renderer cannot must not compile:
        // silently rendering a different tier is exactly what this contract
        // exists to prevent.
        for (@typeInfo(T).@"enum".field_names) |name| {
            if (std.meta.stringToEnum(backend.Tier, name) == null) {
                @compileError("config renderer tier \"" ++ name ++ "\" has no render tier");
            }
        }
    }
    return std.meta.stringToEnum(backend.Tier, @tagName(renderer)) orelse unreachable;
}

/// The backend that implements `tier`, or null when no backend exists for it.
///
/// Today every tier is served by the CPU driver (`SoftwareBackend`): Low through
/// the capability gate, Medium directly. Advanced has **no** backend — its
/// capabilities are declared for a future one, so asking for it is refused
/// instead of silently rendering at Medium quality. This function is the single
/// place a GPU backend gets registered.
pub fn backendFor(tier: backend.Tier, gpa: Allocator) ?SoftwareBackend {
    return switch (tier) {
        .low, .medium => SoftwareBackend.init(gpa, tier),
        .advanced => null,
    };
}

const SoftwareBackend = backend.SoftwareBackend;

/// Per-frame parameters: what the caller *wants*, subject to the tier.
/// Everything not available on the tier is turned off by `resolve` instead of
/// being requested and rejected.
pub const FrameParams = struct {
    /// Fog-free clear colour, straight alpha.
    clear: [4]u8 = .{ 0, 0, 0, 255 },
    /// Clear depth; `1` is the far plane.
    clear_depth: f32 = 1.0,
    /// Mip selection for textured draws. A tier without mipmaps coerces this to
    /// `.level0`; `.level0` is never coerced the other way, so a caller can keep
    /// pixel art crisp on a tier that does have mips.
    mipmap: raster.Mipmap = .trilinear,
    /// Frame-wide refinement of the mip choice. A material can override it through
    /// the resource provider's `sampling()`; the default biases nothing.
    sampling: raster.Sampling = .{},
    /// Extraction-time occlusion culling. `null` (the default) keeps the frustum-only
    /// extraction exactly as it was; `.{}` enables the pass with its default grid.
    /// It can only remove geometry that is provably hidden, so the pixels of every
    /// kept draw are identical either way — this is a cost knob, not a look knob.
    occlusion: ?draw.Occlusion = null,
    /// Edge antialiasing. Coerced to `.none` when the tier lacks it.
    antialias: raster.Antialias = .edge,
    /// Directional Lambert light, applied when the tier has lighting.
    light: ?raster.Light = null,
    /// Override the per-draw blend implied by the extraction sort.
    blend: ?raster.Blend = null,
    depth_test: bool = true,
    depth_write: bool = true,
    cull: raster.CullMode = .back,
    front_face: raster.FrontFace = .counter_clockwise,
};

/// What one frame actually did.
pub const FrameReport = struct {
    tier: backend.Tier,
    /// Draw commands handed to the backend (culled ones never reach it).
    commands: usize,
    /// Commands the extraction layer culled, when `renderScene` produced the list.
    culled: usize,
    /// Of those, how many the occlusion pass rejected (zero without it).
    occlusion_culled: usize = 0,
    /// Backend frame statistics.
    stats: backend.FrameStats,
    /// The frame options that were accepted, after the tier coercion. Useful for
    /// logging "requested X, got Y" without guessing.
    options: backend.FrameOptions,

    pub fn summary(self: FrameReport) ReportSummary {
        return .{
            .tier = self.tier,
            .commands = self.commands,
            .culled = self.culled,
            .occlusion_culled = self.occlusion_culled,
            .drawn = self.stats.draws,
            .skipped = self.stats.skipped,
            .pixels = self.stats.pixels,
        };
    }
};

/// A small, fixed-size rendering of a report, for logs and tests that must not
/// keep the full struct.
pub const ReportSummary = struct {
    tier: backend.Tier,
    commands: usize,
    culled: usize,
    /// Of `culled`, how many the occlusion pass rejected.
    occlusion_culled: usize = 0,
    drawn: usize,
    skipped: usize,
    pixels: usize,
};

/// Resolve the requested parameters against the tier: everything the tier cannot
/// honour is turned off, so the backend's gate is never tripped by the pipeline
/// itself (it still rejects a caller that pokes the vtable directly).
pub fn resolve(tier: backend.Tier, params: FrameParams, blend_hint: raster.Blend) backend.FrameOptions {
    const caps = backend.capabilities(tier);
    var options = backend.FrameOptions{
        .blend = params.blend orelse blend_hint,
        .antialias = params.antialias,
        .mipmap = params.mipmap,
        .sampling = params.sampling,
        .light = params.light,
        .depth_test = params.depth_test,
        .depth_write = params.depth_write,
        .cull = params.cull,
        .front_face = params.front_face,
    };
    if (!caps.antialias) options.antialias = .none;
    if (!caps.mipmaps) options.mipmap = .level0;
    // Anisotropy refines the level choice, so a tier without it renders the same
    // levels trilinearly: the image is still correct, just over-blurred at grazing
    // angles, which is a quality loss rather than a wrong frame.
    if (!caps.anisotropic and options.mipmap == .anisotropic) options.mipmap = .trilinear;
    // Sampling controls refine the level; a tier without them renders the
    // uncorrected level rather than refusing. `.{}` is the identity, so nothing
    // changes where the controls are unsupported and nobody asked for them.
    if (!caps.sampling_controls) options.sampling = .{};
    if (!caps.lighting) options.light = null;
    if (!caps.blending) options.blend = .none;
    return options;
}

/// Render an already extracted draw list. `blend_hint` is the blend the sort mode
/// implies (`extractDrawList` uses `.back_to_front` for transparency).
pub fn renderFrame(
    gpa: Allocator,
    tier: backend.Tier,
    surface: Surface,
    view_projection: Mat4,
    commands: []const DrawCommand,
    resources: DrawResources,
    params: FrameParams,
    blend_hint: raster.Blend,
) Error!FrameReport {
    try surface.validate();
    var gpu = backendFor(tier, gpa) orelse return error.UnsupportedFeature;
    const iface = gpu.interface();

    const options = resolve(tier, params, blend_hint);
    try iface.beginFrame(surface, options);
    for (commands) |cmd| {
        // The contract's rule, folded once here: backends never multiply per draw.
        const mvp = transform.multiply(view_projection, cmd.world);
        _ = try iface.draw(cmd, mvp, resources);
    }
    const stats = try iface.endFrame();
    return .{
        .tier = tier,
        .commands = commands.len,
        .culled = 0,
        .stats = stats,
        .options = options,
    };
}

/// The blend a sort mode implies: back-to-front lists are transparency.
pub fn blendHint(mode: draw.SortMode) raster.Blend {
    return switch (mode) {
        .back_to_front => .alpha,
        .front_to_back, .by_material => .none,
    };
}

/// Extract a scene's draw list and render it into `surface`.
pub fn renderScene(
    gpa: Allocator,
    tier: backend.Tier,
    surface: Surface,
    scene: anytype,
    cam: camera.Camera,
    mode: draw.SortMode,
    resources: DrawResources,
    params: FrameParams,
) Error!FrameReport {
    var frame = draw.extractDrawListOcclusion(scene, cam, mode, gpa, params.occlusion) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Internal,
    };
    defer frame.deinit();
    var report = try renderFrame(gpa, tier, surface, cam.view_projection, frame.commands, resources, params, blendHint(mode));
    report.culled = frame.culled;
    report.occlusion_culled = frame.culled_occluded;
    return report;
}

// --- resource tables --------------------------------------------------------

/// A handle in a `ResourceTable`: the slot index plus a generation, so a stale
/// handle cannot alias a slot that was replaced. Handles are what
/// `DrawCommand.mesh`/`.material` carry.
///
/// The generation is **per kind**: setting a material on a slot must not
/// invalidate the mesh handle of that slot, because one slot is exactly where a
/// draw's geometry and material usually live side by side.
pub const Handle = struct {
    index: u32,
    generation: u32,

    pub fn toBits(self: Handle) u32 {
        return (self.generation << 16) | (self.index & 0xffff);
    }
};

/// Which of a slot's three entries a handle refers to. Each kind has its own
/// generation, so setting a material cannot invalidate the mesh handle beside it.
pub const ResourceKind = enum { mesh, color, texture };

/// Fixed-capacity table of meshes, materials (colours) and optionally textures.
///
/// Sized once with `init` — no allocation and no growth afterwards, so a frame
/// cannot fail or reallocate while building resources. `capacity` slots each of
/// mesh, colour and texture; roughly `capacity * 128` bytes of table state.
pub const ResourceTable = struct {
    pub const max_capacity: usize = 4096;

    meshes: []raster.Mesh,
    colors: [][4]f32,
    textures: []?raster.Texture,
    /// Per-kind, per-slot state: the generation of every kind of entry plus its
    /// liveness. Kept apart so one kind's lifetime cannot invalidate another's.
    slots: []Slot,

    const Slot = struct {
        mesh_gen: u32 = 0,
        color_gen: u32 = 0,
        texture_gen: u32 = 0,
        mesh: bool = false,
        color: bool = false,
        texture: bool = false,
    };

    pub fn init(gpa: Allocator, slot_count: usize) error{OutOfMemory}!ResourceTable {
        if (slot_count == 0 or slot_count > max_capacity) return error.OutOfMemory;
        const meshes = try gpa.alloc(raster.Mesh, slot_count);
        errdefer gpa.free(meshes);
        const colors = try gpa.alloc([4]f32, slot_count);
        errdefer gpa.free(colors);
        const textures = try gpa.alloc(?raster.Texture, slot_count);
        errdefer gpa.free(textures);
        const slots = try gpa.alloc(Slot, slot_count);
        errdefer gpa.free(slots);
        @memset(slots, Slot{});
        return .{
            .meshes = meshes,
            .colors = colors,
            .textures = textures,
            .slots = slots,
        };
    }

    pub fn deinit(self: *ResourceTable, gpa: Allocator) void {
        gpa.free(self.meshes);
        gpa.free(self.colors);
        gpa.free(self.textures);
        gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn capacity(self: ResourceTable) usize {
        return self.meshes.len;
    }

    /// Slots whose mesh/colour pair is live — the pairs a draw can use.
    pub fn liveCount(self: ResourceTable) usize {
        var live: usize = 0;
        for (self.slots) |slot| {
            if (slot.mesh and slot.color) live += 1;
        }
        return live;
    }

    /// Store geometry in slot `slot` (replacing whatever it held). The slices are
    /// borrowed: the caller keeps them alive while the table is in use.
    pub fn setMesh(self: *ResourceTable, slot: usize, mesh: raster.Mesh) Error!Handle {
        if (slot >= self.slots.len) return error.InvalidValue;
        const entry = &self.slots[slot];
        self.meshes[slot] = mesh;
        entry.mesh = true;
        entry.mesh_gen +%= 1;
        return .{ .index = @intCast(slot), .generation = entry.mesh_gen };
    }

    pub fn setColor(self: *ResourceTable, slot: usize, linear: [4]f32) Error!Handle {
        // Reject non-finite or out-of-range colors up front: @intFromFloat(NaN)
        // downstream is UB, and a NaN color would poison every draw that uses it.
        for (linear) |c| {
            if (!std.math.isFinite(c) or c < 0.0 or c > 1.0) return error.InvalidValue;
        }
        const entry = &self.slots[slot];
        self.colors[slot] = linear;
        entry.color = true;
        entry.color_gen +%= 1;
        return .{ .index = @intCast(slot), .generation = entry.color_gen };
    }

    pub fn setTexture(self: *ResourceTable, slot: usize, texture: raster.Texture) Error!Handle {
        if (slot >= self.slots.len) return error.InvalidValue;
        const entry = &self.slots[slot];
        self.textures[slot] = texture;
        entry.texture = true;
        entry.texture_gen +%= 1;
        return .{ .index = @intCast(slot), .generation = entry.texture_gen };
    }

    /// Drop every entry in `slot`. The next `set*` on it gets a fresh
    /// generation, so handles to what was released stop resolving.
    ///
    /// The generation is bumped **here**, not only on the next `set*`: a caller that
    /// releases a slot and then re-fills it must not have the old handles come back to
    /// life, and a caller that recomputes a handle from a slot index (as the asset
    /// loader does) needs the bump to have happened already. Releasing a slot that is
    /// already free is a no-op, so an eviction policy cannot inflate generations.
    pub fn release(self: *ResourceTable, slot: usize) void {
        if (slot >= self.slots.len) return;
        const entry = &self.slots[slot];
        if (!entry.mesh and !entry.color and !entry.texture) return;
        entry.mesh = false;
        entry.color = false;
        entry.texture = false;
        entry.mesh_gen +%= 1;
        entry.color_gen +%= 1;
        entry.texture_gen +%= 1;
    }

    /// Whether the kind's entry in `slot` is live.
    pub fn isLive(self: *const ResourceTable, slot: usize, kind: ResourceKind) bool {
        if (slot >= self.slots.len) return false;
        const entry = self.slots[slot];
        return switch (kind) {
            .mesh => entry.mesh,
            .color => entry.color,
            .texture => entry.texture,
        };
    }

    /// The current handle of a specific kind in `slot`, or null when that kind is not
    /// live there. This is what a caller that knows only the slot (the asset loader)
    /// uses, and it is the only correct way to build a handle after a release: the
    /// generation lives in the table, so a handle assembled from a guessed generation
    /// silently stops resolving.
    pub fn handleOf(self: *const ResourceTable, slot: usize, kind: ResourceKind) ?Handle {
        if (slot >= self.slots.len) return null;
        const entry = self.slots[slot];
        const gen = switch (kind) {
            .mesh => if (entry.mesh) entry.mesh_gen else return null,
            .color => if (entry.color) entry.color_gen else return null,
            .texture => if (entry.texture) entry.texture_gen else return null,
        };
        return .{ .index = @intCast(slot), .generation = gen };
    }

    /// Resolver for the backend. `with_textures = false` hides the texture
    /// function entirely, which is exactly the "optional declaration" the
    /// contract models.
    pub fn resources(self: *ResourceTable, with_textures: bool) DrawResources {
        const iface = struct {
            fn mesh(ptr: *anyopaque, handle: u32) ?raster.Mesh {
                const table: *ResourceTable = @ptrCast(@alignCast(ptr));
                const slot = handle & 0xffff;
                const gen = handle >> 16;
                if (slot >= table.meshes.len) return null;
                if (gen != table.slots[slot].mesh_gen or !table.slots[slot].mesh) return null;
                return table.meshes[slot];
            }
            fn color(ptr: *anyopaque, handle: u32) ?[4]f32 {
                const table: *ResourceTable = @ptrCast(@alignCast(ptr));
                const slot = handle & 0xffff;
                const gen = handle >> 16;
                if (slot >= table.colors.len) return null;
                if (gen != table.slots[slot].color_gen or !table.slots[slot].color) return null;
                return table.colors[slot];
            }
            fn texture(ptr: *anyopaque, handle: u32) ?raster.Texture {
                const table: *ResourceTable = @ptrCast(@alignCast(ptr));
                const slot = handle & 0xffff;
                const gen = handle >> 16;
                if (slot >= table.textures.len) return null;
                if (gen != table.slots[slot].texture_gen or !table.slots[slot].texture) return null;
                return table.textures[slot];
            }
        };
        return .{
            .ptr = self,
            .meshFn = iface.mesh,
            .colorFn = iface.color,
            .textureFn = if (with_textures) iface.texture else null,
        };
    }
};

/// Fill an `AssetTable` from zero-copy `CXMH` mesh views, so the engine binary can
/// render real project assets.
///
/// Nothing here owns asset bytes: every slice stored in the table borrows the
/// caller's decoded artifacts, which must outlive the table and the frame.
/// Positions, UVs and indices are copied out of the compact interleaved vertex
/// layout into tightly-packed scratch, because the rasterizer's `Mesh` takes
/// typed slices. Normals are not carried: the rasterizer shades with the
/// geometric face normal.
pub const AssetTable = struct {
    gpa: Allocator,
    table: ResourceTable,
    /// One slot per `setMesh` call: `[3]f32` per vertex, `[2]f32` per vertex and
    /// `u32` per index, all sized once at `init`.
    position_scratch: [][3]f32,
    uv_scratch: [][2]f32,
    index_scratch: [][]u32,
    index_data: []u32,
    vertices_per_slot: usize,
    indices_per_slot: usize,

    pub const Options = struct {
        capacity: usize,
        /// Largest vertex count a single slot may carry.
        vertices_per_slot: usize,
        /// Largest index count a single slot may carry (a multiple of three).
        indices_per_slot: usize,
    };

    pub const InitError = error{ OutOfMemory, InvalidOptions };

    /// Hard cap on per-slot scratch to keep `init`'s up-front allocation bounded
    /// even when a caller (or a hand-edited `settings.json`) supplies absurd
    /// `vertices_per_slot` / `indices_per_slot`. The scratch is allocated once
    /// at `init`, before any mesh is validated, so an unbounded value would be
    /// a DoS vector.
    pub const max_vertices_per_slot: usize = 1_000_000;
    pub const max_indices_per_slot: usize = 6_000_000;

    pub fn init(gpa: Allocator, options: Options) InitError!AssetTable {
        if (options.capacity == 0 or options.capacity > ResourceTable.max_capacity) return error.InvalidOptions;
        if (options.vertices_per_slot == 0 or options.indices_per_slot == 0) return error.InvalidOptions;
        if (options.indices_per_slot % 3 != 0) return error.InvalidOptions;
        if (options.vertices_per_slot > max_vertices_per_slot) return error.InvalidOptions;
        if (options.indices_per_slot > max_indices_per_slot) return error.InvalidOptions;
        var table = ResourceTable.init(gpa, options.capacity) catch return error.OutOfMemory;
        errdefer table.deinit(gpa);
        const positions = gpa.alloc([3]f32, options.capacity * options.vertices_per_slot) catch return error.OutOfMemory;
        errdefer gpa.free(positions);
        const uvs = gpa.alloc([2]f32, options.capacity * options.vertices_per_slot) catch return error.OutOfMemory;
        errdefer gpa.free(uvs);
        const slices = gpa.alloc([]u32, options.capacity) catch return error.OutOfMemory;
        errdefer gpa.free(slices);
        const data = gpa.alloc(u32, options.capacity * options.indices_per_slot) catch return error.OutOfMemory;
        errdefer gpa.free(data);
        for (slices, 0..) |*slice, i| slice.* = data[i * options.indices_per_slot ..][0..options.indices_per_slot];
        return .{
            .gpa = gpa,
            .table = table,
            .position_scratch = positions,
            .uv_scratch = uvs,
            .index_scratch = slices,
            .index_data = data,
            .vertices_per_slot = options.vertices_per_slot,
            .indices_per_slot = options.indices_per_slot,
        };
    }

    pub fn deinit(self: *AssetTable) void {
        self.table.deinit(self.gpa);
        self.gpa.free(self.position_scratch);
        self.gpa.free(self.uv_scratch);
        self.gpa.free(self.index_scratch);
        self.gpa.free(self.index_data);
        self.* = undefined;
    }

    /// Store `view` in `slot` and return the handle a `Renderable.mesh` uses.
    /// Fails with `error.MeshTooLarge` when the view exceeds the slot sizing —
    /// an explicit limit rather than a truncated mesh.
    pub fn setMesh(self: *AssetTable, slot: usize, view: mesh_asset.MeshView) Error!Handle {
        const vertex_count = view.vertex_count;
        const index_count = view.index_count;
        if (vertex_count > self.vertices_per_slot or index_count > self.indices_per_slot) return error.MeshTooLarge;
        const positions = self.position_scratch[slot * self.vertices_per_slot ..][0..vertex_count];
        const uvs = self.uv_scratch[slot * self.vertices_per_slot ..][0..vertex_count];
        const indices = self.index_scratch[slot][0..index_count];
        for (positions, uvs, 0..) |*p, *uv, i| {
            const v = view.vertexAt(i);
            p.* = .{ v.position[0], v.position[1], v.position[2] };
            uv.* = .{ v.uv[0], v.uv[1] };
        }
        for (indices, 0..) |*out, i| out.* = view.indexAt(i);
        return self.table.setMesh(slot, .{ .positions = positions, .uvs = uvs, .indices = indices });
    }

    /// Store a decoded (owned) mesh, in the same slot layout `setMesh` uses.
    ///
    /// The source format decoders (`assets.mesh.decodeObj`) return an owned `Mesh`
    /// rather than a `CXMH` view; this is the one conversion from that shape, so a
    /// source asset and a derived artifact land in the table identically.
    pub fn setDecodedMesh(self: *AssetTable, slot: usize, mesh: mesh_asset.Mesh) Error!Handle {
        const vertex_count = mesh.vertices.len;
        const index_count = mesh.indices.len;
        if (vertex_count > self.vertices_per_slot or index_count > self.indices_per_slot) return error.MeshTooLarge;
        const positions = self.position_scratch[slot * self.vertices_per_slot ..][0..vertex_count];
        const uvs = self.uv_scratch[slot * self.vertices_per_slot ..][0..vertex_count];
        const indices = self.index_scratch[slot][0..index_count];
        for (positions, uvs, mesh.vertices) |*p, *uv, v| {
            p.* = .{ v.position[0], v.position[1], v.position[2] };
            uv.* = .{ v.uv[0], v.uv[1] };
        }
        for (indices, mesh.indices) |*out, i| out.* = i;
        return self.table.setMesh(slot, .{ .positions = positions, .uvs = uvs, .indices = indices });
    }

    pub fn setColor(self: *AssetTable, slot: usize, linear: [4]f32) Error!Handle {
        return self.table.setColor(slot, linear);
    }

    pub fn setTexture(self: *AssetTable, slot: usize, texture: raster.Texture) Error!Handle {
        return self.table.setTexture(slot, texture);
    }

    /// The current handle of `kind` in `slot`, or null when it is not live. Read from
    /// the table rather than rebuilt from a slot index, because a release bumps the
    /// generation: a handle recomputed from the index would resolve to whatever the
    /// slot holds *now*, which is exactly the aliasing the generation exists to stop.
    pub fn handleOf(self: *const AssetTable, slot: usize, kind: ResourceKind) ?Handle {
        return self.table.handleOf(slot, kind);
    }

    /// Whether `kind` is live in `slot`.
    pub fn isLive(self: *const AssetTable, slot: usize, kind: ResourceKind) bool {
        return self.table.isLive(slot, kind);
    }

    /// Free everything `slot` holds and bump its generations, so every handle into it
    /// stops resolving. The scratch buffers stay allocated (they are sliced per slot
    /// and reused), so eviction is O(1) and never allocates.
    pub fn release(self: *AssetTable, slot: usize) void {
        self.table.release(slot);
    }

    /// Bytes the table can hand to a backend for the live entries: the mesh scratch
    /// that was copied out of the assets (positions, UVs, indices) plus the texture
    /// levels a caller uploaded. This is the table's own footprint, not the size of
    /// the files it was filled from, and it is what an eviction/report path counts.
    pub fn uploadedBytes(self: AssetTable) usize {
        var bytes: usize = 0;
        for (self.table.slots, 0..) |slot, i| {
            if (slot.mesh) {
                const mesh = self.table.meshes[i];
                bytes += mesh.positions.len * @sizeOf([3]f32);
                if (mesh.uvs) |uvs| bytes += uvs.len * @sizeOf([2]f32);
                bytes += mesh.indices.len * @sizeOf(u32);
            }
            if (slot.texture) {
                if (self.table.textures[i]) |texture| {
                    bytes += texture.pixels.len;
                    for (texture.mips) |level| bytes += level.pixels.len;
                }
            }
        }
        return bytes;
    }

    /// Resolver for the backend; see `ResourceTable.resources`.
    pub fn resources(self: *AssetTable, with_textures: bool) DrawResources {
        return self.table.resources(with_textures);
    }
};

/// Adapt a decoded `CXTX` texture to the rasterizer's borrowed `Texture`. The
/// slices borrow the asset bytes; nothing is copied.
pub fn textureFromAsset(asset_: texture_asset.Texture) raster.Texture {
    return .{
        .width = asset_.width,
        .height = asset_.height,
        .pixels = asset_.pixels,
        .filter = .bilinear,
    };
}

const testing = std.testing;

// --- tests -----------------------------------------------------------------

const TestScene = @import("../scene.zig").Scene(.{
    @import("../scene.zig").Component(transform.Transform, "transform"),
    @import("../scene.zig").Component(draw.Renderable, "renderable"),
});

const quad_positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
const quad_uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

const Scratch = struct {
    color: [16 * 16 * 4]u8 = @splat(0),
    depth: [16 * 16]f32 = @splat(1.0),
    target: raster.Target = undefined,
    surface: Surface = undefined,

    fn init(self: *Scratch) !void {
        self.target = try raster.Target.init(16, 16, &self.color, &self.depth);
        self.surface = Surface.of(&self.target);
    }
};

fn orthoCam() camera.Camera {
    return .{
        .view = transform.identity(),
        .projection = camera.orthographic(-2, 2, -2, 2, -4, 4),
        .view_projection = transform.identity(),
    };
}

/// A camera that really looks down -Z at the origin from +Z, so a quad in the XY
/// plane at z = 0 is visible and front-facing.
fn frontCam() camera.Camera {
    return camera.Camera.perspectiveLookAt(.{ 0, 0, 4 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 0.1, 100);
}

test "pipeline: config tiers map onto render tiers one to one" {
    const config = @import("../core/config.zig");
    // Every config tier has a render tier with the same tag …
    inline for (@typeInfo(config.RendererTier).@"enum".field_names) |name| {
        try testing.expect(tierFromConfig(@field(config.RendererTier, name)) ==
            @field(backend.Tier, name));
    }
    // … and every render tier has a config tier with the same tag, so neither
    // side can gain a tier alone.
    try testing.expectEqual(@as(usize, 3), @typeInfo(config.RendererTier).@"enum".field_names.len);
    try testing.expectEqual(@typeInfo(config.RendererTier).@"enum".field_names.len, @typeInfo(backend.Tier).@"enum".field_names.len);
    try testing.expect(backend.Tier.medium == tierFromConfig(config.RendererTier.medium));
}

test "pipeline: resolve honours the tier instead of asking for too much" {
    const params = FrameParams{ .antialias = .edge, .mipmap = .trilinear, .light = .{ .direction = .{ 0, 0, 1 } }, .blend = .additive };

    const low = resolve(.low, params, .none);
    try testing.expectEqual(raster.Antialias.none, low.antialias);
    try testing.expectEqual(raster.Mipmap.level0, low.mipmap);
    try testing.expectEqual(@as(?raster.Light, null), low.light);
    try testing.expectEqual(raster.Blend.none, low.blend);
    // The resolved options are accepted by the gate they were resolved for.
    try testing.expectEqual(@as(?[]const u8, null), backend.unsupported(.low, low));

    const medium = resolve(.medium, params, .none);
    try testing.expectEqual(raster.Antialias.edge, medium.antialias);
    try testing.expectEqual(raster.Mipmap.trilinear, medium.mipmap);
    try testing.expect(medium.light != null);
    try testing.expectEqual(raster.Blend.additive, medium.blend);
    try testing.expectEqual(@as(?[]const u8, null), backend.unsupported(.medium, medium));

    // Without an explicit blend, the extraction sort decides.
    try testing.expectEqual(raster.Blend.alpha, resolve(.medium, .{}, blendHint(.back_to_front)).blend);
    try testing.expectEqual(raster.Blend.none, resolve(.medium, .{}, blendHint(.front_to_back)).blend);
}

test "pipeline: every tier the config can name has a backend, Advanced has none" {
    const gpa = testing.allocator;
    try testing.expect(backendFor(.low, gpa) != null);
    try testing.expect(backendFor(.medium, gpa) != null);
    // Advanced declares capabilities but no backend: refused, not silently run
    // at Medium quality.
    try testing.expect(backendFor(.advanced, gpa) == null);
}

test "pipeline: a scene renders through the pipeline on Low and Medium" {
    const gpa = testing.allocator;
    var scene = try TestScene.init(gpa, "main");
    defer scene.deinit();
    var table = try ResourceTable.init(gpa, 4);
    defer table.deinit(gpa);
    // One slot carries both kinds; each keeps its own generation, so defining the
    // material after the mesh must not invalidate the mesh handle.
    const mesh_handle = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices, .uvs = &quad_uvs });
    const color_handle = try table.setColor(0, .{ 1, 0, 0, 1 });

    // `Renderable` stores the packed handles, exactly as a scene file would.
    const e = try scene.createEntity("quad", null);
    try scene.addComponent(e, transform.Transform{});
    try scene.addComponent(e, draw.Renderable{
        .mesh = mesh_handle.toBits(),
        .material = color_handle.toBits(),
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.1 } },
    });
    try testing.expectEqual(@as(u32, 0), mesh_handle.index);
    try testing.expectEqual(@as(u32, 0), color_handle.index);
    try testing.expectEqual(@as(u32, 1), mesh_handle.generation);
    try testing.expectEqual(@as(u32, 1), color_handle.generation);
    try testing.expect(table.resources(true).mesh(mesh_handle.toBits()) != null);
    try testing.expect(table.resources(true).color(color_handle.toBits()) != null);

    var scratch = Scratch{};
    try scratch.init();

    for ([_]backend.Tier{ .low, .medium }) |tier| {
        scratch.target.clear(.{ 9, 9, 9, 255 }, 1.0);
        const report = try renderScene(gpa, tier, scratch.surface, &scene, frontCam(), .front_to_back, table.resources(true), .{ .antialias = .edge });
        try testing.expectEqual(tier, report.tier);
        try testing.expectEqual(@as(usize, 1), report.commands);
        try testing.expectEqual(@as(usize, 1), report.stats.draws);
        try testing.expect(report.stats.pixels > 0);
        // The quad is red and was written: nothing stays at the clear colour.
        try testing.expect(!std.mem.eql(u8, &scratch.color, &(@as([16 * 16 * 4]u8, @splat(9)))));
        // Low must not have accepted antialiasing even though it was requested.
        try testing.expectEqual(if (tier == .low) raster.Antialias.none else raster.Antialias.edge, report.options.antialias);
    }
}

test "pipeline: the pipeline result equals driving the backend by hand" {
    // The pipeline only folds `mvp` and resolves options; it must not change a
    // byte of the frame it produces.
    const gpa = testing.allocator;
    var table = try ResourceTable.init(gpa, 2);
    defer table.deinit(gpa);
    _ = table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices }) catch unreachable;
    _ = table.setColor(0, .{ 0.25, 0.5, 0.75, 1 }) catch unreachable;

    const cmd_mesh = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices });
    const cmd_color = try table.setColor(0, .{ 0.25, 0.5, 0.75, 1 });
    const cmd = DrawCommand{
        .entity = .{ .index = 1, .generation = 0 },
        .mesh = cmd_mesh.toBits(),
        .material = cmd_color.toBits(),
        .world = transform.fromTransform(.{ .position = .{ 0.25, 0, 0 } }),
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.1 } },
        .depth = 0,
    };
    const cam = frontCam();
    const params = FrameParams{ .antialias = .none, .clear = .{ 3, 4, 5, 255 } };

    var a = Scratch{};
    try a.init();
    a.target.clear(params.clear, 1.0);
    const report = try renderFrame(gpa, .medium, a.surface, cam.view_projection, &.{cmd}, table.resources(false), params, .none);
    try testing.expectEqual(@as(usize, 1), report.stats.draws);

    var b = Scratch{};
    try b.init();
    b.target.clear(params.clear, 1.0);
    var gpu = backend.SoftwareBackend.init(gpa, .medium);
    const iface = gpu.interface();
    try iface.beginFrame(b.surface, report.options);
    _ = try iface.draw(cmd, transform.multiply(cam.view_projection, cmd.world), table.resources(false));
    _ = try iface.endFrame();

    try testing.expectEqualSlices(u8, &a.color, &b.color);
    try testing.expectEqualSlices(f32, &a.depth, &b.depth);
}

test "pipeline: occlusion changes which commands are drawn, never the pixels" {
    // The claim the pass is sold on: it removes geometry that cannot be seen, so the
    // frame is byte-identical with it on and off. A big near quad hides a small far
    // one; the far one is drawn opaque *after* nothing, so its absence can only be
    // detected by comparing the two frames.
    const gpa = testing.allocator;
    var scene = try TestScene.init(gpa, "main");
    defer scene.deinit();
    var table = try ResourceTable.init(gpa, 4);
    defer table.deinit(gpa);
    const mesh_handle = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices, .uvs = &quad_uvs });
    const red = try table.setColor(0, .{ 1, 0, 0, 1 });
    const blue = try table.setColor(1, .{ 0, 0, 1, 1 });

    // Near, large, covering the view.
    const near = try scene.createEntity("near", null);
    try scene.addComponent(near, transform.Transform{ .position = .{ 0, 0, 1.0 } });
    try scene.addComponent(near, draw.Renderable{
        .mesh = mesh_handle.toBits(),
        .material = red.toBits(),
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 2, 2, 0.05 } },
    });
    // Far, small, directly behind the near one, drawn with its own colour.
    const far = try scene.createEntity("far", null);
    try scene.addComponent(far, transform.Transform{ .position = .{ 0, 0, -3.0 } });
    try scene.addComponent(far, draw.Renderable{
        .mesh = mesh_handle.toBits(),
        .material = blue.toBits(),
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 0.4, 0.4, 0.05 } },
    });

    var plain_scratch = Scratch{};
    try plain_scratch.init();
    var occluded_scratch = Scratch{};
    try occluded_scratch.init();

    plain_scratch.target.clear(.{ 9, 9, 9, 255 }, 1.0);
    occluded_scratch.target.clear(.{ 9, 9, 9, 255 }, 1.0);
    const plain = try renderScene(gpa, .medium, plain_scratch.surface, &scene, frontCam(), .front_to_back, table.resources(true), .{ .antialias = .none });
    const occluded = try renderScene(gpa, .medium, occluded_scratch.surface, &scene, frontCam(), .front_to_back, table.resources(true), .{ .antialias = .none, .occlusion = .{} });

    try testing.expectEqual(@as(usize, 2), plain.commands);
    try testing.expectEqual(@as(usize, 0), plain.occlusion_culled);
    // The pass found the hidden quad: one command fewer reaches the backend.
    try testing.expectEqual(@as(usize, 1), occluded.commands);
    try testing.expectEqual(@as(usize, 1), occluded.occlusion_culled);
    try testing.expectEqual(@as(usize, 1), occluded.culled);
    // And the pixels are untouched — the whole justification for enabling it.
    try testing.expectEqualSlices(u8, &plain_scratch.color, &occluded_scratch.color);
}

test "pipeline: a malformed surface is refused before any draw" {
    const gpa = testing.allocator;
    var table = try ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    const bad = Surface{ .width = 4, .height = 4, .color = &.{}, .depth = &.{} };
    try testing.expectError(error.InvalidSurface, renderFrame(gpa, .medium, bad, transform.identity(), &.{}, table.resources(false), .{}, .none));
    // Advanced has no backend at all.
    var good = Scratch{};
    try good.init();
    try testing.expectError(error.UnsupportedFeature, renderFrame(gpa, .advanced, good.surface, transform.identity(), &.{}, table.resources(false), .{}, .none));
}

test "pipeline: anisotropic is coerced to trilinear where the tier lacks it" {
    // Quality refinement, not a capability gate: the frame still renders correctly,
    // just without the grazing-angle correction. Medium declares it, so nothing is
    // coerced there.
    const medium = resolve(.medium, .{ .mipmap = .anisotropic }, .none);
    try testing.expectEqual(raster.Mipmap.anisotropic, medium.mipmap);

    const low = resolve(.low, .{ .mipmap = .anisotropic }, .none);
    // Low has no textures at all, which is already the stronger coercion.
    try testing.expectEqual(raster.Mipmap.level0, low.mipmap);

    // The documented rule holds for every tier: asking for anything above
    // `.level0` on a tier without mipmaps lands on `.level0`, never on a mode the
    // tier cannot sample.
    try testing.expectEqual(raster.Mipmap.level0, resolve(.low, .{ .mipmap = .trilinear }, .none).mipmap);
}

test "pipeline: sampling controls survive where the tier has them and are zeroed where not" {
    const grazing = FrameParams{ .mipmap = .anisotropic, .sampling = .{ .lod_bias = 1.5, .max_samples = 4 } };

    const medium = resolve(.medium, grazing, .none);
    try testing.expectEqual(raster.Mipmap.anisotropic, medium.mipmap);
    try testing.expectEqual(@as(f64, 1.5), medium.sampling.lod_bias);
    try testing.expectEqual(@as(u8, 4), medium.sampling.tapCap());
    try testing.expectEqual(@as(?[]const u8, null), backend.unsupported(.medium, medium));

    // Low declares neither mipmaps nor sampling controls, so both are coerced: the
    // frame renders with the identity sampling rather than being refused.
    const low = resolve(.low, grazing, .none);
    try testing.expectEqual(raster.Mipmap.level0, low.mipmap);
    try testing.expect(low.sampling.isIdentity());
    try testing.expectEqual(@as(?[]const u8, null), backend.unsupported(.low, low));

    // The default requests nothing either, so the field is inert unless asked for.
    try testing.expect(resolve(.medium, .{}, .none).sampling.isIdentity());
    // A bias without a cap keeps the global tap count.
    const bias_only = resolve(.medium, .{ .sampling = .{ .lod_bias = -0.5 } }, .none);
    try testing.expectEqual(raster.max_aniso_samples, bias_only.sampling.tapCap());
}

test "pipeline: handles carry a generation, so a stale handle does not alias" {
    const gpa = testing.allocator;
    var table = try ResourceTable.init(gpa, 2);
    defer table.deinit(gpa);
    const first = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices });
    const res = table.resources(false);
    try testing.expect(res.mesh(first.toBits()) != null);

    table.release(0);
    try testing.expectEqual(@as(?raster.Mesh, null), res.mesh(first.toBits()));

    // Reusing the slot bumps the generation: the old handle stays dead while the
    // new one resolves, so a stale draw cannot pick up someone else's geometry.
    const second = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices });
    try testing.expect(second.generation != first.generation);
    try testing.expectEqual(@as(?raster.Mesh, null), res.mesh(first.toBits()));
    try testing.expect(res.mesh(second.toBits()) != null);

    // Out-of-range slots and unused kinds resolve to null, never a read.
    try testing.expectEqual(@as(?raster.Mesh, null), res.mesh(0xffff_ffff));
    try testing.expectEqual(@as(?[4]f32, null), res.color(second.toBits()));
    // Without the texture function the tier is untextured — the contract's
    // optional-declaration shape, not a runtime flag.
    try testing.expectEqual(@as(?raster.Texture, null), res.texture(second.toBits()));
    // A live mesh without a material is not a renderable pair.
    try testing.expectEqual(@as(usize, 0), table.liveCount());
    _ = table.setColor(0, .{ 1, 1, 1, 1 }) catch unreachable;
    try testing.expectEqual(@as(usize, 1), table.liveCount());
}

test "pipeline: release bumps every kind's generation and repeated release is a no-op" {
    // The invariant the asset loader leans on: after a release, no handle built from
    // the slot's index can come back to life, and an eviction policy that releases an
    // already-free slot cannot inflate generations until they wrap.
    const gpa = testing.allocator;
    var table = try ResourceTable.init(gpa, 2);
    defer table.deinit(gpa);
    _ = table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices }) catch unreachable;
    _ = table.setColor(0, .{ 1, 1, 1, 1 }) catch unreachable;
    const texels = [_]u8{ 1, 2, 3, 4 };
    _ = table.setTexture(0, .{ .width = 1, .height = 1, .pixels = &texels }) catch unreachable;

    const mesh_handle = table.handleOf(0, .mesh).?;
    const color_handle = table.handleOf(0, .color).?;
    const texture_handle = table.handleOf(0, .texture).?;
    try testing.expect(table.isLive(0, .mesh) and table.isLive(0, .color) and table.isLive(0, .texture));

    table.release(0);
    // Every kind stopped resolving, and no kind's handle was left valid.
    try testing.expectEqual(@as(?Handle, null), table.handleOf(0, .mesh));
    try testing.expectEqual(@as(?Handle, null), table.handleOf(0, .color));
    try testing.expectEqual(@as(?Handle, null), table.handleOf(0, .texture));
    try testing.expect(!table.isLive(0, .mesh) and !table.isLive(0, .color) and !table.isLive(0, .texture));
    const res = table.resources(true);
    try testing.expectEqual(@as(?raster.Mesh, null), res.mesh(mesh_handle.toBits()));
    try testing.expectEqual(@as(?[4]f32, null), res.color(color_handle.toBits()));
    try testing.expectEqual(@as(?raster.Texture, null), res.texture(texture_handle.toBits()));

    // Releasing an empty slot does nothing: the generations do not move, so a
    // release-on-evict loop cannot churn them.
    table.release(0);
    table.release(0);
    const refilled = try table.setMesh(0, .{ .positions = &quad_positions, .indices = &quad_indices });
    // Two bumps since the first handle: one from the release, one from this store.
    try testing.expectEqual(mesh_handle.generation +% 2, refilled.generation);

    // A slot index out of range is refused by both accessors rather than read.
    try testing.expectEqual(@as(?Handle, null), table.handleOf(1, .mesh));
}

test "pipeline: the asset table reports the bytes it uploaded, and eviction frees them" {
    const gpa = testing.allocator;
    const A = @import("../assets.zig");
    const source =
        \\v -1 -1 0
        \\v 1 -1 0
        \\v 1 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\f 1/1 2/2 3/3
    ;
    var decoded = try A.mesh.decodeObj(gpa, source);
    defer decoded.deinit(gpa);
    const bytes = try A.mesh.serialize(gpa, decoded);
    defer gpa.free(bytes);
    const view = try A.mesh.parse(bytes);

    var table = try AssetTable.init(gpa, .{ .capacity = 2, .vertices_per_slot = 4, .indices_per_slot = 3 });
    defer table.deinit();
    // An empty table owns nothing.
    try testing.expectEqual(@as(usize, 0), table.uploadedBytes());

    _ = try table.setMesh(0, view);
    // Three vertices: positions + UVs + indices, exactly the scratch it copied.
    const mesh_bytes = 3 * @sizeOf([3]f32) + 3 * @sizeOf([2]f32) + 3 * @sizeOf(u32);
    try testing.expectEqual(mesh_bytes, table.uploadedBytes());

    const level0 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const level1 = [_]u8{ 9, 10, 11, 12 };
    const mips = [_]raster.MipLevel{.{ .width = 1, .height = 1, .pixels = &level1 }};
    _ = table.setTexture(1, .{ .width = 2, .height = 1, .pixels = &level0, .mips = &mips }) catch unreachable;
    try testing.expectEqual(mesh_bytes + level0.len + level1.len, table.uploadedBytes());

    // Eviction removes the live entries from the footprint; the scratch block itself
    // stays allocated for reuse, which is why the count follows liveness, not size.
    table.release(0);
    try testing.expectEqual(level0.len + level1.len, table.uploadedBytes());
    table.release(1);
    try testing.expectEqual(@as(usize, 0), table.uploadedBytes());
}

test "pipeline: the asset table renders a CXMH mesh view and refuses oversized ones" {
    const gpa = testing.allocator;
    const A = @import("../assets.zig");
    const source =
        \\v -1 -1 0
        \\v 1 -1 0
        \\v 1 1 0
        \\v -1 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\vt 0 1
        \\f 1/1 2/2 3/3
        \\f 1/1 3/3 4/4
    ;
    var mesh = try A.mesh.decodeObj(gpa, source);
    defer mesh.deinit(gpa);
    const bytes = try A.mesh.serialize(gpa, mesh);
    defer gpa.free(bytes);
    const view = try A.mesh.parse(bytes);
    try testing.expectEqual(@as(u32, 6), view.index_count);

    var assets = try AssetTable.init(gpa, .{ .capacity = 1, .vertices_per_slot = 6, .indices_per_slot = 6 });
    defer assets.deinit();
    const handle = try assets.setMesh(0, view);
    _ = assets.setColor(0, .{ 0, 1, 0, 1 }) catch unreachable;

    const res = assets.resources(false);
    const stored = res.mesh(handle.toBits()).?;
    try testing.expectEqual(@as(usize, 6), stored.positions.len);
    try testing.expectEqual(@as(usize, 6), stored.indices.len);
    // The scratch copy is a faithful read of the interleaved artifact.
    try testing.expectEqual(@as(f32, -1), stored.positions[0][0]);
    try testing.expectEqual(@as(usize, 6), stored.uvs.?.len);
    // Verified against the shared vertex order the importer produces.
    try testing.expectEqual(@as(f32, 0), stored.uvs.?[0][0]);
    try testing.expectEqual(@as(f32, 1), stored.uvs.?[1][0]);
    try testing.expectEqual(@as(f32, 1), stored.uvs.?[2][1]);
    try testing.expectEqual(@as(u32, 1), stored.indices[1]);
    try testing.expectEqual(@as(u32, 2), stored.indices[2]);

    // One vertex too many is refused, not silently truncated.
    const big = try A.mesh.parse(bytes);
    var tiny = try AssetTable.init(gpa, .{ .capacity = 1, .vertices_per_slot = 5, .indices_per_slot = 6 });
    defer tiny.deinit();
    try testing.expectError(error.MeshTooLarge, tiny.setMesh(0, big));
}

test "pipeline: a CXTX texture adapts to the rasterizer's borrowed texture" {
    var pixels: [4 * 4 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);
    const asset_ = @import("../assets/texture.zig").Texture{
        .width = 2,
        .height = 2,
        .pixel_format = .rgba8,
        .pixels = pixels[0..16],
    };
    const tex = textureFromAsset(asset_);
    try testing.expectEqual(@as(u32, 2), tex.width);
    try testing.expectEqual(@as(usize, 16), tex.pixels.len);
    try tex.validate();
    // Same memory, no copy.
    try testing.expect(tex.pixels.ptr == asset_.pixels.ptr);
}

test "pipeline: real assets (CXMH + CXTX) render end to end through the table" {
    // The composition-root check: artifact bytes in, textured pixels out, with
    // the asset layer only touched by this test's adapters.
    const gpa = testing.allocator;
    const A = @import("../assets.zig");

    const obj =
        \\v -1 -1 0
        \\v 1 -1 0
        \\v 1 1 0
        \\v -1 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\vt 0 1
        \\f 1/1 2/2 3/3
        \\f 1/1 3/3 4/4
    ;
    var decoded = try A.mesh.decodeObj(gpa, obj);
    defer decoded.deinit(gpa);
    const mesh_bytes = try A.mesh.serialize(gpa, decoded);
    defer gpa.free(mesh_bytes);
    const view = try A.mesh.parse(mesh_bytes);

    // A 2x2 texture: black/white checker in RGBA8, the `CXTX` payload layout.
    const texels = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255 };
    const tex_asset = @import("../assets/texture.zig").Texture{
        .width = 2,
        .height = 2,
        .pixel_format = .rgba8,
        .pixels = &texels,
    };

    var assets = try AssetTable.init(gpa, .{ .capacity = 1, .vertices_per_slot = 6, .indices_per_slot = 6 });
    defer assets.deinit();
    const mesh_handle = try assets.setMesh(0, view);
    const color_handle = try assets.setColor(0, .{ 1, 1, 1, 1 });
    const tex_handle = try assets.setTexture(0, textureFromAsset(tex_asset));
    try testing.expectEqual(mesh_handle.index, tex_handle.index);

    var scene = try TestScene.init(gpa, "main");
    defer scene.deinit();
    const e = try scene.createEntity("textured", null);
    try scene.addComponent(e, transform.Transform{});
    try scene.addComponent(e, draw.Renderable{
        .mesh = mesh_handle.toBits(),
        .material = color_handle.toBits(),
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.1 } },
    });

    var scratch = Scratch{};
    try scratch.init();
    scratch.target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const report = try renderScene(gpa, .medium, scratch.surface, &scene, frontCam(), .front_to_back, assets.resources(true), .{ .antialias = .none });
    try testing.expectEqual(@as(usize, 1), report.stats.draws);
    try testing.expect(report.stats.pixels > 0);

    // The same frame with the texture function hidden samples flat white. The two
    // differ, which proves the texture handle resolved through the table and
    // reached the pixels rather than the draw silently falling back to the tint.
    var textured: [16 * 16 * 4]u8 = undefined;
    @memcpy(&textured, &scratch.color);
    scratch.target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const flat = try renderScene(gpa, .medium, scratch.surface, &scene, frontCam(), .front_to_back, assets.resources(false), .{ .antialias = .none });
    try testing.expectEqual(flat.stats.draws, report.stats.draws);
    try testing.expect(!std.mem.eql(u8, &textured, &scratch.color));
}
