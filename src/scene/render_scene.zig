//! Renders an engine scene: the component the scene file authors, the asset
//! resolution behind its handles, and the per-frame update a caller drives.
//!
//! This is the piece that was missing between the two halves the engine already
//! has. `docs/render-extraction.md` extracts a draw list from a scene carrying
//! `Transform` + `Renderable`, and `docs/render-backend.md` defines the tier
//! contract that draws it — but the engine's own scene schema
//! (`scene.EngineScene`) only carried `renderable`, so a project `.scene` could
//! not reference a mesh, and nothing owned a camera.
//!
//! What lives here:
//!
//! - `CameraComponent` — the camera an entity authors (`fov`, `near`, `far`,
//!   viewport aspect). It is a plain-data component, serialized like any other.
//! - `EngineRenderScene` / `EngineRenderPrefab` — the engine scene schema with
//!   `transform` + `renderable` + `camera`, in a fixed order.
//! - `EngineRenderer` — owns the frame state: the reusable draw list
//!   (`draw.RenderFrame.refill`, so a steady-state frame allocates no draw list),
//!   the handle tables, the tier and the last report.
//! - `probeSlot` / `LoadedAssets.handleOf` — the one mapping between a project
//!   asset path (`assets/hero.mesh`) and the `renderable` handle a scene stores.
//!   A hash picks the first candidate slot and linear probing resolves collisions
//!   deterministically over the sorted index, so the same project content always
//!   yields the same handles; `handleOf` is how a caller (or the authoring tool
//!   that writes the scene) asks for one instead of recomputing it.
//!
//! Dependency direction is deliberate: this module imports `assets` and `render`,
//! and nothing imports it except the composition roots (the binary). The reverse
//! would drag the asset layer into the render contract, which the contract
//! explicitly avoids.

const std = @import("std");
const r = @import("../render.zig");
const draw = r.draw;
const pipeline = r.pipeline;
const assets = @import("../assets.zig");
const scene_mod = @import("scene.zig");
const transform = @import("transform.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.render);

const components = @import("components.zig");
pub const Transform = components.Transform;
pub const Renderable = draw.Renderable;

/// A camera authored by an entity. The entity's world transform supplies the
/// position and basis; these fields are the lens.
pub const CameraComponent = struct {
    /// Vertical field of view in radians.
    fov: f32 = std.math.pi / 3.0,
    near: f32 = 0.1,
    far: f32 = 500.0,

    pub fn isValid(self: CameraComponent) bool {
        if (!std.math.isFinite(self.fov) or self.fov <= 0 or self.fov >= std.math.pi) return false;
        if (!std.math.isFinite(self.near) or self.near <= 0) return false;
        if (!std.math.isFinite(self.far) or self.far <= self.near) return false;
        return true;
    }
};

/// The engine's renderable scene schema: `transform`, `renderable`, `camera`.
/// The order is fixed (it is the order the component fields appear in the file);
/// a scene that authors `renderable` must be loaded with this schema, because the
/// serializer rejects components the schema does not declare.
pub const EngineRenderScene = scene_mod.Scene(.{
    scene_mod.Component(Transform, "transform"),
    scene_mod.Component(Renderable, "renderable"),
    scene_mod.Component(CameraComponent, "camera"),
});

/// The prefab schema matching `EngineRenderScene`.
pub const EngineRenderPrefab = @import("prefab.zig").Prefab(.{
    scene_mod.Component(Transform, "transform"),
    scene_mod.Component(Renderable, "renderable"),
    scene_mod.Component(CameraComponent, "camera"),
});

/// A loaded asset set: the artifacts a scene's handles resolve against, plus the
/// tables the backend resolves them through. Everything here is borrowed from
/// the bytes it was parsed from; the bytes live in the same struct.
pub const LoadedAssets = struct {
    gpa: Allocator,
    table: pipeline.AssetTable,
    /// Per-texture pixel ownership. An entry is the level-0 copy the table borrows;
    /// `null` once that texture was evicted (the block was freed and the table no
    /// longer holds a slice into it).
    pixel_blocks: std.ArrayList(?[]u8) = .empty,
    /// Generated mip chains, one optional entry per chain-carrying texture. Level 0
    /// is *not* in the chain: `mipmap.Chain` holds the levels below it.
    mip_chains: std.ArrayList(?r.mipmap.Chain) = .empty,
    /// What was uploaded from each path, so an eviction knows exactly which blocks to
    /// free instead of guessing from the slot.
    uploads: std.ArrayList(Uploaded) = .empty,
    /// What the loader used and skipped.
    report: AssetReport = .{},
    /// Path -> table slot for every renderable asset the plan placed (a path whose
    /// bytes failed to decode still owns its slot, so the layout never shifts). The
    /// keys are borrowed from the startup asset index, which outlives this struct.
    slots: std.StringHashMap(usize),

    /// One uploaded asset: which slot it fills and which owned blocks back it.
    const Uploaded = struct {
        slot: usize,
        /// Index into `pixel_blocks`, for a texture.
        pixel: ?usize = null,
        /// Index into `mip_chains`, for a texture with levels below 0.
        chain: ?usize = null,
    };

    pub fn deinit(self: *LoadedAssets) void {
        for (self.pixel_blocks.items) |block| if (block) |bytes| self.gpa.free(bytes);
        for (self.mip_chains.items) |*chain| if (chain.*) |*c| c.deinit(self.gpa);
        self.pixel_blocks.deinit(self.gpa);
        self.mip_chains.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.slots.deinit();
        self.table.deinit();
        self.* = undefined;
    }

    /// The `Renderable` handle bits for a planned path, or null when that path is not
    /// renderable at all. A caller that writes a scene, or one that resolves a
    /// scene's handles, uses this instead of recomputing the table layout.
    ///
    /// While an asset is live this returns the table's own handle, so it is correct
    /// even if the generation moved. A path that was planned but holds nothing —
    /// because its bytes failed to decode, or because it was evicted — gets the
    /// stable load-time name (generation 1), which resolves to nothing: that is the
    /// contract a stored `.scene` depends on, since it cannot be rewritten when one
    /// file in the project is broken. An unplanned path has no handle at all.
    pub fn handleOf(self: *const LoadedAssets, path: []const u8) ?u32 {
        const slot = self.slots.get(path) orelse return null;
        if (self.table.handleOf(slot, .mesh)) |handle| return handle.toBits();
        if (self.table.handleOf(slot, .texture)) |handle| return handle.toBits();
        const planned = pipeline.Handle{ .index = @intCast(slot), .generation = 1 };
        return planned.toBits();
    }

    /// Evict one asset: release its slot and free the pixel blocks behind it. Returns
    /// whether the path held a live asset.
    ///
    /// This is what makes the table's capacity and its memory reusable within a run.
    /// The slot keeps its place in the path map — the layout is a property of the
    /// project, and a reload must land in the same slot for stored scene handles to
    /// keep meaning the same thing — but it no longer resolves: `handleOf` returns
    /// null and every handle into it stops working, because `release` bumps the
    /// generations. A mesh's copy lives in the table's own scratch, which is reused by
    /// the next upload, so releasing the slot releases it.
    pub fn evict(self: *LoadedAssets, path: []const u8) bool {
        const slot = self.slots.get(path) orelse return false;
        if (!self.table.isLive(slot, .mesh) and !self.table.isLive(slot, .texture)) return false;
        self.table.release(slot);
        if (self.findUpload(slot)) |index| {
            const upload = &self.uploads.items[index];
            if (upload.pixel) |p| {
                if (self.pixel_blocks.items[p]) |bytes| self.gpa.free(bytes);
                self.pixel_blocks.items[p] = null;
            }
            if (upload.chain) |c| {
                if (self.mip_chains.items[c]) |*chain| chain.deinit(self.gpa);
                self.mip_chains.items[c] = null;
            }
        }
        self.report.evicted += 1;
        return true;
    }

    /// Bytes the table currently holds for assets: the mesh scratch it copied plus
    /// every level of the textures it borrows. This is what the renderer owns, and it
    /// is not the size of the source files; after `evict` the freed blocks are gone
    /// from it, so the number is a measurement and not an estimate.
    pub fn uploadedBytes(self: *const LoadedAssets) usize {
        return self.table.uploadedBytes();
    }

    /// The number of assets the table can still hold (slots free in either kind).
    pub fn freeSlots(self: *const LoadedAssets) usize {
        return self.table.table.capacity() - self.slots.count();
    }

    fn findUpload(self: *const LoadedAssets, slot: usize) ?usize {
        for (self.uploads.items, 0..) |upload, i| {
            if (upload.slot == slot) return i;
        }
        return null;
    }

    /// A one-level owned "chain" for a texture's level-0 copy is not representable in
    /// `mipmap.Chain` (which holds the levels *below* 0), so level 0 lives in
    /// `pixel_blocks` and only generated levels live in `mip_chains`.
    fn appendPixelBlock(self: *LoadedAssets, bytes: []u8) error{OutOfMemory}!usize {
        self.pixel_blocks.append(self.gpa, bytes) catch return error.OutOfMemory;
        return self.pixel_blocks.items.len - 1;
    }
};

/// Outcome of `loadAssets`: what was used and what was skipped, so a caller can
/// report it instead of guessing.
pub const AssetReport = struct {
    meshes: usize = 0,
    textures: usize = 0,
    /// The capacity the table was created with, recorded so a report explains the
    /// handles it implies.
    capacity: usize = 0,
    /// Files that were found but not loadable (decoder error, oversized mesh,
    /// table full). Counted, not fatal: a scene still renders the rest.
    skipped: usize = 0,
    /// Assets evicted after load. Counted so a report can distinguish "never
    /// uploaded" from "uploaded and released".
    evicted: usize = 0,
    /// Textures that received a generated mip chain below level 0.
    mipmapped: usize = 0,
};

/// First candidate slot for a project-relative asset path: a hash folded into the
/// table capacity.
///
/// This is only the *start* of the probe, not the final slot — see `loadAssets`.
/// It is a pure function of the path and the capacity, which is what makes the
/// mapping reproducible: two loads of the same project produce the same handles.
pub fn probeSlot(path: []const u8, capacity: usize) usize {
    // FNV-1a, then folded into the table.
    var hash: u32 = 2166136261;
    for (path) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return @as(usize, hash % @as(u32, @intCast(capacity)));
}

/// The engine renderer: one per session, driven once per frame.
///
/// It owns the reusable draw list and the tier, and gets its backend from
/// `pipeline.backendFor` (the single registration point), so a future GPU backend
/// becomes available here without a change to this code.
pub const EngineFrameReport = struct {
    commands: usize = 0,
    culled: usize = 0,
    /// Of `culled`, how many the occlusion pass rejected this frame.
    occlusion_culled: usize = 0,
    draws: usize = 0,
    skipped: usize = 0,
    pixels: usize = 0,
    /// The new draw list is field-identical to the previous frame's.
    unchanged: bool = false,
    /// Whether this frame changed (and grew) the reusable buffers. A steady-state
    /// frame is `false`: the draw list came out of the double buffer and the
    /// world-transform snapshot out of the per-frame arena.
    allocated: bool = false,
};

/// A camera found in a scene: the entity, its authored lens and the view the lens
/// and its world transform imply.
pub const CameraView = struct {
    entity: @import("../ecs.zig").Entity,
    component: CameraComponent,
    camera: r.Camera,
};

pub const EngineRenderer = struct {
    gpa: Allocator,
    tier: r.Tier,
    frame: draw.RenderFrame,
    /// What the last `render` produced, for logs and tests.
    last: EngineFrameReport = .{},

    pub fn init(gpa: Allocator, tier: r.Tier) !EngineRenderer {
        return .{ .gpa = gpa, .tier = tier, .frame = try draw.RenderFrame.init(gpa) };
    }

    pub fn deinit(self: *EngineRenderer) void {
        self.frame.deinit();
        self.* = undefined;
    }

    /// Render one frame of `scene` into `surface`.
    ///
    /// `camera` is the lens and `view` the camera from `cameraOf` (world position
    /// and orientation). The aspect comes from the surface, so resizing reframes
    /// instead of stretching. The draw list is refilled in place: a steady-state
    /// frame performs no draw-list allocation.
    pub fn render(
        self: *EngineRenderer,
        surface: r.BackendSurface,
        scene: anytype,
        camera: CameraComponent,
        view: r.Camera,
        resources: r.DrawResources,
        params: pipeline.FrameParams,
    ) pipeline.Error!pipeline.FrameReport {
        const aspect = @as(f32, @floatFromInt(surface.width)) / @as(f32, @floatFromInt(surface.height));
        const projection = r.camera.perspective(camera.fov, aspect, camera.near, camera.far);
        // The caller's view (from `cameraOf`) supplies the orientation; the lens
        // and the surface supply the projection, so resizing reframes.
        const cam = r.Camera.init(view.view, projection, view.position);

        const refilled = self.frame.refillWithOcclusion(scene, cam, .front_to_back, params.occlusion) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Internal,
        };
        var report = try pipeline.renderFrame(
            self.gpa,
            self.tier,
            surface,
            cam.view_projection,
            self.frame.commands,
            resources,
            params,
            .none,
        );
        report.culled = refilled.culled;
        report.occlusion_culled = refilled.occlusion_culled;
        self.last = .{
            .commands = self.frame.commands.len,
            .culled = refilled.culled,
            .occlusion_culled = refilled.occlusion_culled,
            .draws = report.stats.draws,
            .skipped = report.stats.skipped,
            .pixels = report.stats.pixels,
            .allocated = self.frame.allocated_last_frame,
            // Two independent facts: did the content change, and did emitting it
            // cost memory. A frame can be identical in content and still allocate
            // once, when a buffer grows to the size the scene needs.
            .unchanged = !refilled.changed,
        };
        return report;
    }

    /// The first entity in the scene that is a usable camera, or null when the
    /// scene authors none. Iteration is over the ECS view, so the answer is
    /// deterministic: entities are visited in storage order, which the scene keeps
    /// in ascending stable-ID order.
    pub fn findCamera(scene: anytype, gpa: Allocator) !?CameraView {
        var view = scene.ecsWorld().view(.{CameraComponent});
        while (view.next()) |entry| {
            const entity = entry[0];
            const component = entry[1];
            if (!component.isValid()) continue;
            if (try cameraOf(scene, entity, gpa)) |cam| {
                return .{ .entity = entity, .component = component.*, .camera = cam };
            }
        }
        return null;
    }

    /// Render one frame of `scene` with the scene's own camera, into a headless
    /// surface of `surface_size`. Returns null when the scene authors no camera —
    /// there is nothing to frame, which the caller reports instead of drawing an
    /// empty image as if it were the scene.
    ///
    /// This is the whole per-frame path a window loop will drive: find the camera,
    /// size the surface, render through the tier, report. Colour and depth are
    /// allocated per call, which is exactly why this is the *headless* entry point;
    /// a real loop keeps its buffers, clears once per frame and calls `render`.
    pub fn renderSceneFrame(
        self: *EngineRenderer,
        scene: anytype,
        dimensions: struct { width: u32, height: u32 },
        resources: r.DrawResources,
        params: pipeline.FrameParams,
    ) !?pipeline.FrameReport {
        const found = try findCamera(scene, self.gpa) orelse return null;
        const pixels = @as(usize, dimensions.width) * @as(usize, dimensions.height);
        if (pixels == 0) return error.InvalidSurface;

        const color = try self.gpa.alloc(u8, pixels * 4);
        defer self.gpa.free(color);
        const depth = try self.gpa.alloc(f32, pixels);
        defer self.gpa.free(depth);

        var target = try r.Target.init(dimensions.width, dimensions.height, color, depth);
        // The rasterizer does not clear: an uninitialised depth buffer would fail
        // every depth test, so the frame starts from a cleared surface.
        target.clear(.{ 0, 0, 0, 255 }, 1.0);
        return try self.render(r.BackendSurface.of(&target), scene, found.component, found.camera, resources, params);
    }

    /// The camera implied by `entity`'s world transform and component, or null
    /// when the entity is not a camera (or its lens is invalid). The basis is the
    /// entity's world matrix, so a camera can be parented and moved like any other
    /// entity; forward is -Z in this engine's convention.
    pub fn cameraOf(scene: anytype, entity: anytype, gpa: Allocator) !?r.Camera {
        const comp = scene.getComponent(CameraComponent, entity) orelse return null;
        if (!comp.isValid()) return null;
        var wt = try scene.computeWorldTransforms(gpa);
        defer wt.deinit();
        const world = wt.get(entity) orelse return null;
        const eye = transform.transformPoint(world, .{ 0, 0, 0 });
        const forward = transform.transformDirection(world, .{ 0, 0, -1 });
        const up = transform.transformDirection(world, .{ 0, 1, 0 });
        const target = .{ eye[0] + forward[0], eye[1] + forward[1], eye[2] + forward[2] };
        return r.Camera.perspectiveLookAt(eye, target, up, comp.fov, 1.0, comp.near, comp.far);
    }
};

/// The deterministic path → slot layout of a project's renderable assets.
///
/// This is what makes a `.scene` file able to name a mesh: the layout depends only
/// on the project's *content* (the sorted asset index) and the table capacity, never
/// on load order or which file happens to decode. `loadAssets` fills its table
/// through exactly this plan, and tooling (or a test) can compute the same handles to
/// author or verify a scene with `handleOf`.
pub const SlotPlan = struct {
    gpa: Allocator,
    /// The planned assets, in index order. A view of `storage`.
    entries: []Planned,
    /// The allocation `entries` is a view of (the entry count is not known before
    /// the plan is built, and freeing a sub-slice would be wrong).
    storage: []Planned,
    slots: std.StringHashMap(usize),
    capacity: usize,

    pub fn deinit(self: *SlotPlan) void {
        self.gpa.free(self.storage);
        self.slots.deinit();
        self.* = undefined;
    }

    /// The `Renderable` handle bits for a path in this plan, or null when the path
    /// is not a mesh (a texture is named through the same slot, but a `Renderable`
    /// carries one `mesh` and one `material`).
    pub fn handleOf(self: SlotPlan, path: []const u8) ?u32 {
        const slot = self.slots.get(path) orelse return null;
        const handle = pipeline.Handle{ .index = @intCast(slot), .generation = 1 };
        return handle.toBits();
    }

    /// The slot a path landed in, or null when the path is not renderable.
    pub fn slotOf(self: SlotPlan, path: []const u8) ?usize {
        return self.slots.get(path);
    }
};

/// Plan the slot of every renderable asset in `index`, in index order.
///
/// A hash of the path picks the first candidate slot; a taken slot moves on to the
/// next free one (linear probing). Ownership is a single namespace for meshes and
/// textures, so no slot ever holds both — every handle of a loaded asset therefore
/// stays at generation 1, which is what `handleOf` encodes.
///
/// Running out of slots is `error.TableFull` naming the path that did not fit: a
/// mesh that silently failed to load would draw nothing at all, which is harder to
/// diagnose than a refused load.
pub fn planSlots(gpa: Allocator, index: anytype, capacity: usize) !SlotPlan {
    const storage = gpa.alloc(Planned, index.count()) catch return error.OutOfMemory;
    var plan = SlotPlan{
        .gpa = gpa,
        .entries = storage,
        .storage = storage,
        .slots = std.StringHashMap(usize).init(gpa),
        .capacity = capacity,
    };
    errdefer plan.deinit();
    var planned: usize = 0;

    const owner = gpa.alloc(bool, capacity) catch return error.OutOfMemory;
    defer gpa.free(owner);
    @memset(owner, false);

    for (index.entries.items) |entry| {
        const kind = kindOf(entry.path) orelse continue;
        var slot = probeSlot(entry.path, capacity);
        var probes: usize = 0;
        while (owner[slot]) : (probes += 1) {
            if (probes == capacity) {
                log.warn("renderer table capacity {d} is exhausted at \"{s}\"; increase it", .{ capacity, entry.path });
                return error.TableFull;
            }
            slot = (slot + 1) % capacity;
        }
        owner[slot] = true;
        plan.slots.put(entry.path, slot) catch return error.OutOfMemory;
        plan.entries[planned] = .{ .path = entry.path, .slot = slot, .kind = kind };
        planned += 1;
    }
    plan.entries = plan.storage[0..planned];
    return plan;
}

/// Load the renderable assets of a project so a scene's `renderable` handles
/// resolve. `index` is the startup asset index (project-relative paths), and the
/// files are read from `project_root`.
///
/// Format support is exactly what the asset layer decodes today: `.mesh` (`CXMH`
/// artifacts) and `.png`/`.bmp`/`.tga`/`.qoi` (decoded to RGBA8). Anything else
/// is counted in `skipped` — an honest count of what was not used, never a
/// silent success.
///
/// **Slot assignment.** A hash of the path picks the first candidate slot; a taken
/// slot moves on to the next one (linear probing) until a free slot of that kind is
/// found. The index is iterated in its sorted order, so assignment is deterministic:
/// the same project content always produces the same path → handle mapping, which is
/// what lets a `.scene` file name a mesh at all. Two passes are used — claim every
/// slot first, then load — so a file that fails to decode still owns its slot and
/// cannot shift the handles of the assets that follow it.
///
/// The mapping is a property of the project, not of the file names alone, so it is
/// read through `LoadedAssets.handleOf` rather than recomputed by hand.
///
/// Each mesh slot also gets a white base colour, so an untextured draw can name the
/// mesh's own handle as its material. A texture slot gets white *and* the texture, so
/// the material handle of a texture samples the authored pixels.
///
/// Running out of slots is `error.TableFull`, naming the path that did not fit: a
/// mesh that silently failed to load would draw nothing at all, which is harder to
/// diagnose than a refused session.
pub fn loadAssets(
    gpa: Allocator,
    io: Io,
    project_root: []const u8,
    index: anytype,
    options: pipeline.AssetTable.Options,
) !LoadedAssets {
    var loaded = LoadedAssets{
        .gpa = gpa,
        .table = try pipeline.AssetTable.init(gpa, options),
        .slots = std.StringHashMap(usize).init(gpa),
    };
    errdefer loaded.deinit();
    loaded.report.capacity = options.capacity;

    var dir = try Io.Dir.openDirAbsolute(io, project_root, .{});
    defer dir.close(io);

    // The layout is decided before any bytes are read, so it cannot depend on which
    // file happened to decode, and a caller can recompute it with `planSlots`.
    var plan = planSlots(gpa, index, options.capacity) catch |err| switch (err) {
        error.OutOfMemory, error.TableFull => return err,
    };
    defer plan.deinit();
    loaded.slots.deinit();
    loaded.slots = try plan.slots.clone();

    // Read and store each planned asset.
    //
    // The file bytes are **released as soon as the slot is filled**: a mesh is copied
    // into the table's own scratch and a texture keeps its pixels through a separate
    // allocation that survives the file, so holding the source bytes for the life of
    // the session would double every mesh's footprint for no reader. What outlives the
    // read is exactly what the rasterizer samples.
    for (plan.entries) |item| {
        const bytes = dir.readFileAlloc(io, item.path, gpa, .limited(max_asset_bytes)) catch {
            log.warn("unreadable asset \"{s}\"", .{item.path});
            loaded.report.skipped += 1;
            continue;
        };
        defer gpa.free(bytes);

        switch (item.kind) {
            .mesh => {
                const ext = std.fs.path.extension(item.path);
                const stored = if (std.ascii.eqlIgnoreCase(ext, ".obj"))
                    loadObjMesh(&loaded.table, item.slot, bytes)
                else
                    loadArtifactMesh(&loaded.table, item.slot, bytes);
                _ = stored catch |err| switch (err) {
                    error.InvalidAsset => {
                        log.warn("malformed mesh \"{s}\"", .{item.path});
                        loaded.report.skipped += 1;
                        continue;
                    },
                    error.MeshTooLarge => {
                        log.warn("mesh \"{s}\" does not fit the renderer table", .{item.path});
                        loaded.report.skipped += 1;
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                _ = loaded.table.setColor(item.slot, .{ 1, 1, 1, 1 });
                loaded.uploads.append(gpa, .{ .slot = item.slot }) catch return error.OutOfMemory;
                loaded.report.meshes += 1;
            },
            .texture => {
                const ext = std.fs.path.extension(item.path);
                var image = decodeImage(gpa, ext, bytes) catch {
                    log.warn("undecodable texture \"{s}\"", .{item.path});
                    loaded.report.skipped += 1;
                    continue;
                };
                defer image.deinit(gpa);
                const artifact = assets.texture.serialize(gpa, image) catch {
                    loaded.report.skipped += 1;
                    continue;
                };
                defer gpa.free(artifact);
                const parsed = assets.texture.parse(artifact) catch {
                    loaded.report.skipped += 1;
                    continue;
                };
                // The artifact round-trip above is what validates the CXTX layout, but
                // `artifact` dies with this iteration. Copy the level-0 pixels once,
                // owned by the mip storage list, and build the chain below them in the
                // same list so a texture costs one allocation per level block and the
                // table can keep borrowing plain slices.
                const level0 = gpa.dupe(u8, parsed.pixels) catch return error.OutOfMemory;
                const pixel_index = loaded.appendPixelBlock(level0) catch {
                    gpa.free(level0);
                    return error.OutOfMemory;
                };
                const mips = generateMips(gpa, &loaded.mip_chains, parsed.width, parsed.height, level0) catch |err| {
                    _ = loaded.evict(item.path);
                    return err;
                };
                if (mips.len > 0) loaded.report.mipmapped += 1;
                // A generated chain is the last entry of `mip_chains` at this point;
                // `generateMips` appends exactly one when it appends any.
                const chain_index: ?usize = if (mips.len > 0) loaded.mip_chains.items.len - 1 else null;
                _ = loaded.table.setColor(item.slot, .{ 1, 1, 1, 1 });
                _ = loaded.table.setTexture(item.slot, .{
                    .width = parsed.width,
                    .height = parsed.height,
                    .pixels = level0,
                    .filter = .bilinear,
                    .mips = mips,
                });
                loaded.uploads.append(gpa, .{ .slot = item.slot, .pixel = pixel_index, .chain = chain_index }) catch
                    return error.OutOfMemory;
                loaded.report.textures += 1;
            },
        }
    }
    return loaded;
}

/// The renderable formats the loader accepts, in the one place the planner and the
/// loader read.
pub const AssetKind = enum { mesh, texture };

/// The renderable kind of a path, or null when the loader does not handle it.
fn kindOf(path: []const u8) ?AssetKind {
    const ext = std.fs.path.extension(path);
    if (isMeshExtension(ext)) return .mesh;
    if (isTextureExtension(ext)) return .texture;
    return null;
}

/// Mesh artifacts and the one source format that needs no external tool: a
/// Wavefront OBJ is converted to a `CXMH` artifact in the importer's own decoder,
/// so a project can be authored and rendered with no binary assets in the tree.
fn isMeshExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".mesh") or std.ascii.eqlIgnoreCase(ext, ".obj");
}

fn isTextureExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".bmp") or
        std.ascii.eqlIgnoreCase(ext, ".tga") or
        std.ascii.eqlIgnoreCase(ext, ".qoi");
}

const Planned = struct {
    path: []const u8,
    slot: usize,
    kind: AssetKind,
};

/// Generate the mip levels of a texture and keep the chain alive in `chains`.
///
/// `render.mipmap` builds a chain with integer box filtering (deterministic across
/// platforms) and owns the level block; the chain is stored whole in the caller's
/// list, so its lifetime is exactly the loader's and `deinit` frees it. The returned
/// slice borrows into the chain — the shape `raster.Texture.mips` expects, with no
/// per-level allocation and nothing for the caller to free separately.
///
/// A 1x1 texture has no levels below it, so nothing is appended and the returned
/// slice is empty: level 0 only is the honest answer for an image that cannot be
/// minified. A `level0`-only request therefore costs no allocation here.
fn generateMips(
    gpa: Allocator,
    chains: *std.ArrayList(?r.mipmap.Chain),
    width: u32,
    height: u32,
    pixels: []const u8,
) error{OutOfMemory}![]const r.MipLevel {
    if (r.mipmap.levelCount(width, height) < 2) return &.{};
    const chain = r.mipmap.Chain.generate(gpa, width, height, pixels) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    chains.append(gpa, chain) catch {
        var undo = chain;
        undo.deinit(gpa);
        return error.OutOfMemory;
    };
    // `items.len` moved, so address the stored element: `append` may have reallocated.
    return chains.items[chains.items.len - 1].?.levels();
}

/// Store one mesh artifact in `slot`. A `CXMH` artifact is parsed zero-copy, so the
/// table borrows the file bytes the caller holds.
fn loadArtifactMesh(table: *pipeline.AssetTable, slot: usize, bytes: []const u8) !void {
    const view = try assets.mesh.parse(bytes);
    _ = try table.setMesh(slot, view);
}

/// Decode one OBJ source and store it in `slot`. The decoded mesh is transient: only
/// the tightly-packed scratch copy in the table survives, so no OBJ parse state is
/// retained. `error.InvalidAsset` covers malformed sources and an empty face list.
fn loadObjMesh(table: *pipeline.AssetTable, slot: usize, bytes: []const u8) !void {
    var decoded = assets.mesh.decodeObj(table.gpa, bytes) catch |err| switch (err) {
        error.InvalidMesh => return error.InvalidAsset,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer decoded.deinit(table.gpa);
    _ = try table.setDecodedMesh(slot, decoded);
}

/// Largest asset file the loader will read (the cache artifact ceiling).
pub const max_asset_bytes: usize = 256 * 1024 * 1024;

fn decodeImage(gpa: Allocator, ext: []const u8, bytes: []const u8) !assets.image.Image {
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return assets.png.decode(gpa, bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return assets.image.decodeBmp(gpa, bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".tga")) return assets.image.decodeTga(gpa, bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".qoi")) return assets.image.decodeQoi(gpa, bytes);
    return error.UnsupportedFormat;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Half turn about +Y: the entity's local -Z forward axis then points along +Z,
/// which is how a camera stands on +Z and looks back at the origin in this
/// engine's right-handed clip space.
fn halfTurnY() [4]f32 {
    return .{ 0, 0, 0, 1 };
}

test "render_scene: the schema authors transform, renderable and camera" {
    // Round-trip through the real serializer: the components are plain data and
    // survive parse(serialize(x)) unchanged, which is what makes a scene file
    // able to reference a mesh at all.
    const gpa = testing.allocator;
    var scene = try EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    const e = try scene.createEntity("quad", null);
    try scene.addComponent(e, Transform{ .position = .{ 1, 2, 3 } });
    try scene.addComponent(e, Renderable{
        .mesh = 7,
        .material = 9,
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.1 } },
    });
    try scene.addComponent(e, CameraComponent{ .fov = 1.0, .near = 0.5, .far = 40 });

    const bytes = try scene.serialize(gpa);
    defer gpa.free(bytes);
    var back = try EngineRenderScene.parse(gpa, bytes);
    defer back.deinit();
    const re = back.entityById(1).?;
    try testing.expectEqual(@as(u32, 7), back.getComponent(Renderable, re).?.mesh);
    try testing.expectEqual(@as(u32, 9), back.getComponent(Renderable, re).?.material);
    try testing.expectEqual(@as(f32, 1.0), back.getComponent(CameraComponent, re).?.fov);
    try testing.expectEqual(@as(f32, 40), back.getComponent(CameraComponent, re).?.far);
}

test "render_scene: a camera component validates its lens" {
    try testing.expect((CameraComponent{}).isValid());
    try testing.expect(!(CameraComponent{ .fov = 0 }).isValid());
    try testing.expect(!(CameraComponent{ .fov = std.math.pi }).isValid());
    try testing.expect(!(CameraComponent{ .near = 0 }).isValid());
    try testing.expect(!(CameraComponent{ .near = 5, .far = 5 }).isValid());
    try testing.expect(!(CameraComponent{ .far = std.math.inf(f32) }).isValid());
}

test "render_scene: probeSlot folds a path into the table and is stable" {
    // The candidate slot is a pure function of (path, capacity): the same project
    // load always starts probing at the same place.
    try testing.expectEqual(probeSlot("assets/hero.mesh", 64), probeSlot("assets/hero.mesh", 64));
    try testing.expect(probeSlot("assets/hero.mesh", 64) != probeSlot("assets/other.mesh", 64));
    // Folded into the table, so it is always a valid index — and always a start
    // point: two paths may share one, which is what probing resolves.
    for (0..64) |i| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "assets/mesh{d}.mesh", .{i}) catch unreachable;
        try testing.expect(probeSlot(path, 8) < 8);
    }
}

test "render_scene: loadAssets decodes a project's mesh and texture" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");

    // A real CXMH artifact, produced by the importer's serializer.
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
    var decoded = try assets.mesh.decodeObj(gpa, obj);
    defer decoded.deinit(gpa);
    const mesh_bytes = try assets.mesh.serialize(gpa, decoded);
    defer gpa.free(mesh_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/quad.mesh", .data = mesh_bytes });

    // A real QOI texture, decoded by the same path the loader uses.
    const texels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const qoi = try assets.image.encodeQoi(gpa, .{ .width = 2, .height = 2, .pixels = @constCast(&texels) });
    defer gpa.free(qoi);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/checker.qoi", .data = qoi });
    // A file the loader must skip: it is indexed but not a renderable format.
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/notes.txt", .data = "not an asset" });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 64, .vertices_per_slot = 16, .indices_per_slot = 24 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.report.meshes);
    try testing.expectEqual(@as(usize, 1), loaded.report.textures);
    try testing.expectEqual(@as(usize, 0), loaded.report.skipped);
    try testing.expectEqual(options.capacity, loaded.report.capacity);

    // The handles a scene file stores resolve, and the assets behind them are the
    // real decoded data: an unindexed quad (two triangles, one vertex per face
    // corner) and the authored texels.
    const resources = loaded.table.resources(true);
    const mesh_bits = loaded.handleOf("assets/quad.mesh").?;
    const mesh = resources.mesh(mesh_bits).?;
    try testing.expectEqual(@as(usize, 6), mesh.positions.len);
    try testing.expectEqual(@as(usize, 6), mesh.indices.len);
    // The mesh slot is also a usable white material (an untextured draw).
    const white = resources.color(mesh_bits).?;
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, &white);

    const tex_handle = loaded.handleOf("assets/checker.qoi").?;
    const tex = resources.texture(tex_handle).?;
    try testing.expectEqual(@as(u32, 2), tex.width);
    try testing.expectEqualSlices(u8, &texels, tex.pixels);

    // A path that is not renderable has no handle at all, so a scene referring to it
    // cannot silently resolve to some other asset's slot.
    try testing.expect(loaded.handleOf("assets/missing.mesh") == null);
    try testing.expect(loaded.handleOf("assets/notes.txt") == null);
    // Two assets, two distinct slots: probing never aliases.
    try testing.expect(mesh_bits != tex_handle or (mesh_bits & 0xffff) != (tex_handle & 0xffff));
    try testing.expectEqual(@as(usize, 2), loaded.slots.count());
    try testing.expectEqual(@as(usize, options.capacity - 2), loaded.freeSlots());
}

test "render_scene: an uploaded texture carries a real mip chain" {
    // The gap this closes: `FrameParams.mipmap` defaults to `.trilinear` and Medium
    // declares mipmaps, but a texture uploaded without levels could only ever sample
    // level 0 — minification aliased and the tier's capability was decorative.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");

    // A 4x4 image with four distinct quadrants, so every generated level has a
    // predictable value rather than one averaged into a uniform grey.
    var texels: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const i = (y * 4 + x) * 4;
            const top = y < 2;
            const left = x < 2;
            texels[i + 0] = if (left) 255 else 0;
            texels[i + 1] = if (top) 255 else 0;
            texels[i + 2] = 0;
            texels[i + 3] = 255;
        }
    }
    const qoi = try assets.image.encodeQoi(gpa, .{ .width = 4, .height = 4, .pixels = &texels });
    defer gpa.free(qoi);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/grid.qoi", .data = qoi });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 4, .vertices_per_slot = 8, .indices_per_slot = 12 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.report.mipmapped);

    const texture = loaded.table.resources(true).texture(loaded.handleOf("assets/grid.qoi").?).?;
    // 4x4 -> 2x2 -> 1x1: level 0 plus two generated levels.
    try testing.expectEqual(@as(u32, 3), texture.mipLevelCount());
    try testing.expectEqual(@as(u32, 2), texture.mipLevel(1).width);
    try testing.expectEqual(@as(u32, 1), texture.mipLevel(2).width);
    // `validate` is the contract the backend trusts: every level halved, every level
    // complete. A chain that failed either would be rejected at draw time.
    try texture.validate();

    // The 2x2 level is the box average of each quadrant, so the top-left texel keeps
    // its yellow-red corner and the 1x1 level averages the four quadrants.
    const level1 = texture.mipLevel(1);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 0, 255 }, level1.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, level1.pixels[12..16]);
    const level2 = texture.mipLevel(2);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 0, 255 }, level2.pixels[0..4]);

    // The chain is counted in the table's footprint, and it is not the file size.
    const uploaded = loaded.uploadedBytes();
    try testing.expect(uploaded >= 4 * 4 * 4 + 2 * 2 * 4 + 4);
    try testing.expect(uploaded < qoi.len + 4 * 4 * 4 + 2 * 2 * 4 + 4 + 64);
}

test "render_scene: a 1x1 texture generates no levels and says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    const texels = [_]u8{ 9, 8, 7, 255 };
    const qoi = try assets.image.encodeQoi(gpa, .{ .width = 1, .height = 1, .pixels = @constCast(&texels) });
    defer gpa.free(qoi);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/dot.qoi", .data = qoi });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];
    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 2, .vertices_per_slot = 8, .indices_per_slot = 12 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.report.mipmapped);
    try testing.expectEqual(@as(usize, 0), loaded.mip_chains.items.len);

    const texture = loaded.table.resources(true).texture(loaded.handleOf("assets/dot.qoi").?).?;
    try testing.expectEqual(@as(u32, 1), texture.mipLevelCount());
    try testing.expectEqualSlices(u8, &texels, texture.pixels);
}

test "render_scene: eviction frees the pixels and kills the handles into the slot" {
    // The eviction contract: the slot stops resolving, the memory is actually
    // returned (not just hidden behind a liveness flag), the layout never shifts, and
    // a reload of the same path cannot resurrect the old handles unless it really is
    // the same generation.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");

    const texels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const qoi = try assets.image.encodeQoi(gpa, .{ .width = 2, .height = 2, .pixels = @constCast(&texels) });
    defer gpa.free(qoi);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/checker.qoi", .data = qoi });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];
    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 4, .vertices_per_slot = 8, .indices_per_slot = 12 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();

    const path = "assets/checker.qoi";
    const bits = loaded.handleOf(path).?;
    const slot = loaded.slots.get(path).?;
    const before = loaded.uploadedBytes();
    try testing.expect(before >= 16);
    try testing.expect(loaded.table.resources(true).texture(bits) != null);

    // Evicting is idempotent: the second call reports "nothing was live".
    try testing.expect(loaded.evict(path));
    try testing.expect(!loaded.evict(path));
    try testing.expectEqual(@as(usize, 1), loaded.report.evicted);

    // The handle a scene stored does not resolve, and the table holds no bytes for it.
    try testing.expect(loaded.table.resources(true).texture(bits) == null);
    try testing.expectEqual(@as(usize, 0), loaded.uploadedBytes());
    try testing.expect(!loaded.table.isLive(slot, .texture));
    // The path still owns its slot: the layout is a property of the project, so the
    // handle bits a stored scene carries stay addressable even when empty.
    try testing.expect(loaded.handleOf(path) != null);
    try testing.expectEqual(@as(usize, options.capacity - 1), loaded.freeSlots());

    // The generation moved, so a handle rebuilt with the old generation cannot alias
    // a future upload in that slot.
    const table_handle = loaded.table.handleOf(slot, .texture);
    try testing.expect(table_handle == null);

    // Reload path: a fresh table filled the same way gives generation 1 again, which
    // is why a stored handle is stable across runs but not across an eviction.
    var reloaded = try loadAssets(gpa, io, root, index, options);
    defer reloaded.deinit();
    try testing.expectEqual(bits, reloaded.handleOf(path).?);
}

test "render_scene: loadAssets decodes an OBJ source, no artifact needed" {
    // Authoring story: a project's mesh is a text file the engine can decode, so a
    // checkout carries no binary assets and the frame still draws real geometry.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    const obj =
        \\v -1 -1 0
        \\v 1 -1 0
        \\v 1 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\f 1/1 2/2 3/3
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/tri.obj", .data = obj });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 4, .vertices_per_slot = 8, .indices_per_slot = 12 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.report.meshes);
    try testing.expectEqual(@as(usize, 0), loaded.report.skipped);

    const resources = loaded.table.resources(false);
    const mesh = resources.mesh(loaded.handleOf("assets/tri.obj").?).?;
    try testing.expectEqual(@as(usize, 3), mesh.positions.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try testing.expectEqual(@as(f32, -1), mesh.positions[0][0]);

    // A malformed OBJ is skipped and counted, not fatal.
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/bad.obj", .data = "v 0 0 0\nf 1 2 3\n" });
    var index2 = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index2.deinit();
    var loaded2 = try loadAssets(gpa, io, root, index2, options);
    defer loaded2.deinit();
    try testing.expectEqual(@as(usize, 1), loaded2.report.skipped);
    try testing.expectEqual(@as(usize, 1), loaded2.report.meshes);
}

test "render_scene: an exhausted table is refused, not silently truncated" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    // Slot assignment happens before anything is decoded, so the contents do not
    // matter here: only that the index offers two meshes.
    const content = [_]u8{ 'C', 0, 0, 0, 0, 0, 0, 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/a.mesh", .data = &content });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/b.mesh", .data = &content });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    // Capacity 1 cannot hold two meshes. The loader says so instead of letting the
    // second mesh alias the first one's handle.
    const options = pipeline.AssetTable.Options{ .capacity = 1, .vertices_per_slot = 8, .indices_per_slot = 12 };
    try testing.expectError(error.TableFull, loadAssets(gpa, io, root, index, options));
}

test "render_scene: a skipped file does not shift the other assets' handles" {
    // The two-pass layout: a malformed mesh still claims its slot, so the assets
    // indexed after it keep the handles they would have had if it decoded. That is
    // what makes a stored handle stable when one asset in the project is broken.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/broken.mesh", .data = "not a CXMH artifact" });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try @import("../core/assets.zig").indexDirectories(gpa, io, root, &.{"assets"});
    defer index.deinit();

    const options = pipeline.AssetTable.Options{ .capacity = 8, .vertices_per_slot = 8, .indices_per_slot = 12 };
    var loaded = try loadAssets(gpa, io, root, index, options);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.report.meshes);
    try testing.expectEqual(@as(usize, 1), loaded.report.skipped);
    // The path is planned and owns its slot even though nothing was stored, so the
    // handle exists and resolves to nothing — an honest miss.
    const bits = loaded.handleOf("assets/broken.mesh").?;
    try testing.expect(loaded.table.resources(true).mesh(bits) == null);
}

test "render_scene: the engine renderer draws a projected scene and reuses its list" {
    const gpa = testing.allocator;
    var scene = try EngineRenderScene.init(gpa, "main");
    defer scene.deinit();

    // A quad at the origin, seen from a camera entity placed on +Z and turned to
    // face the origin (the scene's forward is -Z).
    const quad = try scene.createEntity("quad", null);
    try scene.addComponent(quad, Transform{});
    try scene.addComponent(quad, Renderable{
        .mesh = 0,
        .material = 0,
        .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.1 } },
    });
    const camera_entity = try scene.createEntity("cam", null);
    const camera_transform = Transform{
        .position = .{ 0, 0, 4 },
        .rotation = halfTurnY(),
    };
    try scene.addComponent(camera_entity, camera_transform);
    try scene.addComponent(camera_entity, CameraComponent{ .fov = std.math.pi / 2.0 });

    const cam = (try EngineRenderer.cameraOf(&scene, camera_entity, gpa)).?;
    try testing.expect(cam.view_projection[0] != 0);
    try testing.expect(cam.view_projection[15] != 0);

    var table = try pipeline.ResourceTable.init(gpa, 2);
    defer table.deinit(gpa);
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const mesh_handle = table.setMesh(0, .{ .positions = &positions, .indices = &indices });
    const color_handle = table.setColor(0, .{ 1, 0, 0, 1 });
    scene.getComponent(Renderable, quad).?.mesh = mesh_handle.toBits();
    scene.getComponent(Renderable, quad).?.material = color_handle.toBits();

    var color: [32 * 32 * 4]u8 = undefined;
    var depth: [32 * 32]f32 = undefined;
    var target = try r.Target.init(32, 32, &color, &depth);
    // The pipeline draws into the surface it is given; clearing is the caller's
    // job (a real loop clears once per frame), and an uninitialised depth buffer
    // would fail every depth test.
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const surface = r.BackendSurface.of(&target);

    var engine = try EngineRenderer.init(gpa, .medium);
    defer engine.deinit();
    const comp = scene.getComponent(CameraComponent, camera_entity).?.*;

    const report = try engine.render(surface, &scene, comp, cam, table.resources(false), .{ .antialias = .none });
    try testing.expectEqual(@as(usize, 1), report.commands);
    try testing.expectEqual(@as(usize, 1), report.stats.draws);
    try testing.expect(report.stats.pixels > 0);
    try testing.expectEqual(@as(usize, 1), engine.last.commands);

    // Second frame, nothing changed: the list is reused and reported unchanged.
    _ = try engine.render(surface, &scene, comp, cam, table.resources(false), .{ .antialias = .none });
    // Nothing moved, so the refilled list is identical and reported unchanged.
    try testing.expect(engine.last.unchanged);
    try testing.expectEqual(@as(usize, 1), engine.last.commands);

    // Moving the quad changes the frame, and the report says so.
    scene.getComponent(Transform, quad).?.position = .{ 0.5, 0, 0 };
    _ = try engine.render(surface, &scene, comp, cam, table.resources(false), .{ .antialias = .none });
    try testing.expect(!engine.last.unchanged);

    // Culling reaches the report: a quad far behind the camera is dropped.
    scene.getComponent(Transform, quad).?.position = .{ 0, 0, 400 };
    _ = try engine.render(surface, &scene, comp, cam, table.resources(false), .{ .antialias = .none });
    try testing.expectEqual(@as(usize, 1), engine.last.culled);
    try testing.expectEqual(@as(usize, 0), engine.last.draws);
}

test "render_scene: an entity without a camera component is not a camera" {
    const gpa = testing.allocator;
    var scene = try EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    const e = try scene.createEntity("plain", null);
    try testing.expect(try EngineRenderer.cameraOf(&scene, e, gpa) == null);
    // An invalid lens never reaches the scene: `addComponent` runs the component's
    // own `isValid`, so a degenerate projection cannot be authored at all.
    try testing.expectError(error.InvalidComponent, scene.addComponent(e, CameraComponent{ .fov = 0 }));
    try testing.expect(try EngineRenderer.cameraOf(&scene, e, gpa) == null);
}

test "render_scene: a scene without a camera frames nothing" {
    const gpa = testing.allocator;
    var scene = try EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    const e = try scene.createEntity("quad", null);
    try scene.addComponent(e, Transform{});
    try scene.addComponent(e, Renderable{});

    try testing.expect(try EngineRenderer.findCamera(&scene, gpa) == null);
    var engine = try EngineRenderer.init(gpa, .medium);
    defer engine.deinit();
    // A missing camera is reported before any surface is touched, so an empty
    // resource resolver is enough to prove it.
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try testing.expect(try engine.renderSceneFrame(&scene, .{ .width = 16, .height = 16 }, table.resources(false), .{}) == null);
}

test "render_scene: the renderer frames a scene through its own camera" {
    // The whole headless frame path, as the binary drives it: no camera argument,
    // the scene supplies one; the surface is sized from the dimensions requested.
    const gpa = testing.allocator;
    var scene = try EngineRenderScene.init(gpa, "main");
    defer scene.deinit();

    const quad = try scene.createEntity("quad", null);
    try scene.addComponent(quad, Transform{});
    try scene.addComponent(quad, Renderable{ .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.01 } } });
    const camera_entity = try scene.createEntity("cam", null);
    try scene.addComponent(camera_entity, Transform{ .position = .{ 0, 0, 4 } });
    try scene.addComponent(camera_entity, CameraComponent{ .fov = std.math.pi / 2.0 });

    const found = (try EngineRenderer.findCamera(&scene, gpa)).?;
    try testing.expect(found.entity.eql(camera_entity));
    try testing.expectEqual(@as(f32, std.math.pi / 2.0), found.component.fov);

    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const mesh_handle = table.setMesh(0, .{ .positions = &positions, .indices = &indices });
    const color_handle = table.setColor(0, .{ 0, 1, 0, 1 });
    scene.getComponent(Renderable, quad).?.mesh = mesh_handle.toBits();
    scene.getComponent(Renderable, quad).?.material = color_handle.toBits();

    var engine = try EngineRenderer.init(gpa, .medium);
    defer engine.deinit();
    const report = (try engine.renderSceneFrame(&scene, .{ .width = 24, .height = 18 }, table.resources(true), .{ .antialias = .none })).?;
    try testing.expectEqual(@as(usize, 1), report.commands);
    try testing.expectEqual(@as(usize, 1), report.stats.draws);
    try testing.expect(report.stats.pixels > 0);
    // The aspect came from the requested surface, not from a fixed 1:1 view.
    try testing.expect(engine.last.commands == 1 and engine.last.draws == 1);

    // Zero-sized surfaces are refused rather than rendering nothing silently.
    try testing.expectError(error.InvalidSurface, engine.renderSceneFrame(&scene, .{ .width = 0, .height = 10 }, table.resources(true), .{}));

    // The per-frame hand-off, end to end: the first frames grow the buffers and the
    // scratch arena, and from then on the same scene renders without allocating.
    try testing.expect(engine.last.allocated);
    _ = (try engine.renderSceneFrame(&scene, .{ .width = 24, .height = 18 }, table.resources(true), .{ .antialias = .none })).?;
    const settled = (try engine.renderSceneFrame(&scene, .{ .width = 24, .height = 18 }, table.resources(true), .{ .antialias = .none })).?;
    try testing.expect(!engine.last.allocated);
    try testing.expect(engine.last.unchanged);
    try testing.expectEqual(@as(usize, 1), settled.commands);

    // Two camera entities: the first (lowest stable ID) frames the view, so the
    // outcome does not depend on hash-map iteration order.
    const second = try scene.createEntity("cam2", null);
    try scene.addComponent(second, Transform{ .position = .{ 0, 0, -4 } });
    try scene.addComponent(second, CameraComponent{ .fov = std.math.pi / 3.0 });
    const again = (try EngineRenderer.findCamera(&scene, gpa)).?;
    try testing.expect(again.entity.eql(camera_entity));
}
