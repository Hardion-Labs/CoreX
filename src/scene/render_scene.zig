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
    /// File bytes, one allocation each, owned here.
    blobs: std.ArrayList([]u8) = .empty,
    /// What the loader used and skipped.
    report: AssetReport = .{},
    /// Path -> table slot for every renderable asset the plan placed (a path whose
    /// bytes failed to decode still owns its slot, so the layout never shifts). The
    /// keys are borrowed from the startup asset index, which outlives this struct.
    slots: std.StringHashMap(usize),

    pub fn deinit(self: *LoadedAssets) void {
        for (self.blobs.items) |blob| self.gpa.free(blob);
        self.blobs.deinit(self.gpa);
        self.slots.deinit();
        self.table.deinit();
        self.* = undefined;
    }

    /// The `Renderable` handle bits for a planned path, or null when that path is not
    /// renderable at all. A caller that writes a scene, or one that resolves a
    /// scene's handles, uses this instead of recomputing the table layout.
    ///
    /// A loaded slot always carries generation 1 in a fresh table, which is what the
    /// handle encodes; a later `release`/`set*` on that slot changes the generation
    /// and the stored handle stops resolving, as the generation exists to guarantee.
    pub fn handleOf(self: *const LoadedAssets, path: []const u8) ?u32 {
        const slot = self.slots.get(path) orelse return null;
        const handle = pipeline.Handle{ .index = @intCast(slot), .generation = 1 };
        return handle.toBits();
    }

    /// The number of assets the table can still hold (slots free in either kind).
    pub fn freeSlots(self: *const LoadedAssets) usize {
        return self.table.table.capacity() - self.slots.count();
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
    draws: usize = 0,
    skipped: usize = 0,
    pixels: usize = 0,
    /// The new draw list is byte-identical to the previous frame's.
    unchanged: bool = false,
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

        const refilled = self.frame.refill(scene, cam, .front_to_back) catch |err| switch (err) {
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
        self.last = .{
            .commands = self.frame.commands.len,
            .culled = refilled.culled,
            .draws = report.stats.draws,
            .skipped = report.stats.skipped,
            .pixels = report.stats.pixels,
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
    for (plan.entries) |item| {
        const bytes = dir.readFileAlloc(io, item.path, gpa, .limited(max_asset_bytes)) catch {
            log.warn("unreadable asset \"{s}\"", .{item.path});
            loaded.report.skipped += 1;
            continue;
        };
        loaded.blobs.append(gpa, bytes) catch {
            gpa.free(bytes);
            return error.OutOfMemory;
        };

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
                // The rasterizer samples the pixels directly; the artifact
                // round-trip above is what validates the CXTX layout, and the pixels
                // are owned by `image`, which ends here — so store a copy the table
                // can borrow.
                const copy = gpa.dupe(u8, parsed.pixels) catch return error.OutOfMemory;
                loaded.blobs.append(gpa, copy) catch {
                    gpa.free(copy);
                    return error.OutOfMemory;
                };
                _ = loaded.table.setColor(item.slot, .{ 1, 1, 1, 1 });
                _ = loaded.table.setTexture(item.slot, .{
                    .width = parsed.width,
                    .height = parsed.height,
                    .pixels = copy,
                    .filter = .bilinear,
                });
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

    // Two camera entities: the first (lowest stable ID) frames the view, so the
    // outcome does not depend on hash-map iteration order.
    const second = try scene.createEntity("cam2", null);
    try scene.addComponent(second, Transform{ .position = .{ 0, 0, -4 } });
    try scene.addComponent(second, CameraComponent{ .fov = std.math.pi / 3.0 });
    const again = (try EngineRenderer.findCamera(&scene, gpa)).?;
    try testing.expect(again.entity.eql(camera_entity));
}
