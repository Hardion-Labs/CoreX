//! Draw-list extraction: the backend-independent bridge from the scene to a
//! renderer. Given a scene (any `Scene(schema)` carrying `Transform` +
//! `Renderable`) and a `Camera`, it computes world transforms, frustum-culls
//! renderables, and emits a sorted list of `DrawCommand`s that any GPU backend
//! (Low/Medium/Advanced) can consume.
//!
//! This is pure CPU work — no GPU API, no asset or job-system dependency — so it
//! is fully testable headlessly. It reuses the scene's O(n) world-transform
//! snapshot and the ECS view iteration, keeping coupling low and performance
//! cache-friendly.

const std = @import("std");
const camera = @import("camera.zig");
const culling = @import("culling.zig");
const occlusion = @import("occlusion.zig");
const transform = @import("../scene/transform.zig");
const ecs = @import("../ecs.zig");

const Allocator = std.mem.Allocator;
const Mat4 = transform.Mat4;
const Entity = ecs.Entity;
pub const Camera = camera.Camera;
pub const Aabb = culling.Aabb;

/// A renderable scene component: opaque mesh/material handles plus a local-space
/// bounding box. Plain data, so it can be added to a scene schema with
/// `Component(Renderable, "renderable")` and serialized like any component.
/// Handles are resolved by the backend/asset layer; extraction only copies them.
pub const Renderable = struct {
    mesh: u32 = 0,
    material: u32 = 0,
    bounds: Aabb = .{ .center = .{ 0, 0, 0 }, .extents = .{ 0.5, 0.5, 0.5 } },

    pub fn isValid(self: Renderable) bool {
        for (self.bounds.center) |v| if (!std.math.isFinite(v)) return false;
        for (self.bounds.extents) |v| {
            if (!std.math.isFinite(v) or v < 0) return false;
        }
        return true;
    }
};

/// One visible draw call. Self-contained (carries its world matrix and world
/// bounds) so the draw list outlives the transient transform snapshot.
pub const DrawCommand = struct {
    entity: Entity,
    mesh: u32,
    material: u32,
    world: Mat4,
    bounds: Aabb,
    /// Depth of the bounds center along the view direction (positive in front).
    depth: f32,
};

/// Draw-list ordering strategies.
pub const SortMode = enum {
    /// Nearest first — good for opaque geometry (early-z).
    front_to_back,
    /// Farthest first — required for correct alpha blending.
    back_to_front,
    /// Group by material then mesh to minimize GPU state changes.
    by_material,
};

/// Extraction-time depth culling: a conservative software occlusion pass on top of
/// the frustum test.
///
/// The pass is **two-pass by construction**. Visible-ordered occluders (those whose
/// world bounds cover at least `min_coverage` tiles) are claimed into a tile depth
/// buffer front to back, and only *then* is every remaining renderable tested
/// against it. Testing while claiming would make the result depend on entity
/// iteration order — a wall listed after the room would cull nothing — so the order
/// is fixed by depth instead.
///
/// It can only ever reject geometry; a bound it keeps is rendered as before. That
/// is what makes the option safe to enable by default and what the tests assert:
/// every cull is a conservative one, so switching it off changes performance, never
/// pixels.
pub const Occlusion = struct {
    /// Tile grid of the depth buffer. 64x36 keeps the per-occluder cost to a few
    /// hundred point-in-hull tests while staying finer than most on-screen props;
    /// the grid is a pure accuracy/cost knob, never a correctness one.
    tiles_x: u16 = 64,
    tiles_y: u16 = 36,
    /// Smallest screen footprint, in tiles, for a bound to be used as an occluder.
    /// 1 would let every visible triangle claim tiles it does not fully cover and
    /// buy nothing; 16 needs a bound covering roughly a thirtieth of the screen.
    min_coverage: u32 = 16,
    /// Safety margin subtracted from a tested object's nearest depth, in NDC z.
    /// Keeps geometry that is coplanar with (or a rounding step in front of) an
    /// occluder visible.
    depth_bias: f32 = 0.0025,

    /// The grid actually usable: a zero axis is clamped to one tile rather than
    /// turned into an error. Extraction is not the place to reject a frame over a
    /// quality knob — `occlusion.Buffer` keeps its own `InvalidGrid` for callers
    /// that build a buffer directly.
    pub fn sanitized(self: Occlusion) Occlusion {
        var out = self;
        out.tiles_x = @max(self.tiles_x, 1);
        out.tiles_y = @max(self.tiles_y, 1);
        return out;
    }
};

/// `occlusion.Buffer.init` narrowed to the one error extraction can report.
/// `Occlusion.sanitized` has already clamped both axes to at least one tile, so the
/// buffer's own `InvalidGrid` is unreachable here by construction.
fn allocTiles(gpa: Allocator, config: Occlusion) error{OutOfMemory}!occlusion.Buffer {
    return occlusion.Buffer.init(gpa, config.tiles_x, config.tiles_y) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidGrid => unreachable,
    };
}

/// Per-frame scratch for the occlusion pass.
///
/// Owns the tile buffer and one reusable command list, so a frame loop allocates
/// nothing per frame: sized once by a warm-up frame, then only `clear`ed. Both
/// slices are grown in `gpa` and freed by `deinit`.
pub const OcclusionScratch = struct {
    gpa: Allocator,
    buffer: occlusion.Buffer,
    /// The occluders, in submission order, reused as the claim queue.
    claims: []DrawCommand = &.{},
    /// The survivors of the frustum pass that still have to be tested.
    pending: []DrawCommand = &.{},

    pub fn init(gpa: Allocator, config: Occlusion) !OcclusionScratch {
        const safe = config.sanitized();
        return .{
            .gpa = gpa,
            .buffer = try allocTiles(gpa, safe),
        };
    }

    pub fn deinit(self: *OcclusionScratch) void {
        self.buffer.deinit(self.gpa);
        self.gpa.free(self.claims);
        self.gpa.free(self.pending);
        self.* = undefined;
    }

    fn reset(self: *OcclusionScratch, config: Occlusion) !void {
        const safe = config.sanitized();
        // A different grid is honoured by rebuilding, so the knob really is per
        // frame rather than fixed at construction.
        if (self.buffer.tiles_x != safe.tiles_x or self.buffer.tiles_y != safe.tiles_y) {
            self.buffer.deinit(self.gpa);
            self.buffer = try allocTiles(self.gpa, safe);
        }
        self.buffer.clear();
    }

    fn sizeClaims(self: *OcclusionScratch, n: usize) !void {
        if (self.claims.len >= n) return;
        const grown = try self.gpa.alloc(DrawCommand, n);
        self.gpa.free(self.claims);
        self.claims = grown;
    }

    fn sizePending(self: *OcclusionScratch, n: usize) !void {
        if (self.pending.len >= n) return;
        const grown = try self.gpa.alloc(DrawCommand, n);
        self.gpa.free(self.pending);
        self.pending = grown;
    }
};

/// An owned, sorted draw list plus culling diagnostics.
///
/// The list is double-buffered so `refill` can compare this frame's commands with
/// the previous ones while extracting the new ones, without a steady-state
/// allocation and without ever reading a buffer that a grow may have moved.
pub const RenderFrame = struct {
    gpa: Allocator,
    /// The current frame's commands (a view of the active buffer).
    commands: []DrawCommand,
    /// Number of renderables rejected this extraction: the frustum pass plus the
    /// occlusion pass.
    culled: usize,
    /// Of those, how many the occlusion pass rejected. Zero when occlusion is off,
    /// so `culled - culled_occluded` is always the frustum count.
    culled_occluded: usize = 0,
    /// The exact allocations behind `commands` and the inactive buffer. Kept
    /// apart from the views so every free uses the length that was allocated.
    active: []DrawCommand,
    spare: []DrawCommand,
    /// Whether the last `refill` had to allocate (draw list or scratch arena).
    /// Exposed so a frame loop can report "this frame was free" instead of guessing;
    /// a steady-state frame sets it to false.
    allocated_last_frame: bool = false,
    /// The per-frame allocator hand-off: every transient allocation of a frame
    /// (the world-transform snapshot and its work arrays) comes from here and is
    /// released by one `reset` per `refill`, so a steady-state frame never touches
    /// the general-purpose allocator. The draw-list buffers themselves live in
    /// `gpa` because they persist across frames.
    scratch: std.heap.ArenaAllocator,
    /// The occlusion pass's persistent buffer and queues. Present even when the
    /// caller never enables occlusion: it is sized by the first frame that does.
    occlusion_scratch: OcclusionScratch,

    pub fn deinit(self: *RenderFrame) void {
        self.occlusion_scratch.deinit();
        self.scratch.deinit();
        self.gpa.free(self.active);
        self.gpa.free(self.spare);
        self.* = undefined;
    }

    /// An empty list that `extractDrawList` can grow in place, or that a caller
    /// keeps across frames and refills with `refill`.
    pub fn init(gpa: Allocator) !RenderFrame {
        const empty = try gpa.alloc(DrawCommand, 0);
        errdefer gpa.free(empty);
        const spare = try gpa.alloc(DrawCommand, 0);
        errdefer gpa.free(spare);
        var oscratch = try OcclusionScratch.init(gpa, .{});
        errdefer oscratch.deinit();
        return .{
            .gpa = gpa,
            .commands = empty,
            .culled = 0,
            .active = empty,
            .spare = spare,
            .allocated_last_frame = false,
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .occlusion_scratch = oscratch,
        };
    }

    /// Refill this frame in place, reusing the existing buffers.
    ///
    /// The new list is extracted into the inactive buffer and compared with the
    /// current one; then the two swap. In a steady state (same scene, same
    /// camera) nothing is allocated and nothing is copied — only the commands are
    /// re-emitted and compared.
    ///
    /// Returns the culled count and `changed = false` when the resulting list is
    /// field-for-field identical to the previous one.
    ///
    /// `changed` is advisory: `DrawCommand.world` is a `[16]f32` that the matrix
    /// math may leave partially undefined padding in, so two frames that render
    /// identically can still compare as changed (the comparison never reports a
    /// change that did not happen, only sometimes misses that none did).
    /// `occlusion` is opt-in per frame: `null` (the default in `refillOff`) keeps
    /// the frustum-only extraction, so a caller that wants the byte-identical
    /// pre-occlusion behaviour gets it by asking for nothing.
    pub fn refillWithOcclusion(
        self: *RenderFrame,
        scene: anytype,
        cam: Camera,
        mode: SortMode,
        config: ?Occlusion,
    ) !struct { culled: usize, occlusion_culled: usize, changed: bool } {
        var next: std.ArrayList(DrawCommand) = .fromOwnedSlice(self.spare);
        next.capacity = self.spare.len;
        // One reset per frame is the whole point of the hand-off: everything the
        // previous frame borrowed from the scratch arena is released at once, and a
        // frame that needs no more memory than last time allocates nothing.
        const scratch_before = self.scratch.queryCapacity();
        const list_capacity_before = next.capacity;
        const queue_before = self.occlusion_scratch.claims.len + self.occlusion_scratch.pending.len;
        _ = self.scratch.reset(.retain_capacity);
        // `extractIntoScratch` clears the list first, so the spare's previous
        // contents are never read; only its capacity is reused.
        const result = try extractIntoScratchOccluded(
            &next,
            scene,
            cam,
            mode,
            self.gpa,
            self.scratch.allocator(),
            &self.occlusion_scratch,
            config,
        );
        const culled = result.culled;
        self.allocated_last_frame = self.scratch.queryCapacity() != scratch_before or
            next.capacity != list_capacity_before or
            queue_before != self.occlusion_scratch.claims.len + self.occlusion_scratch.pending.len;
        const changed = self.culled != culled or
            self.culled_occluded != result.occlusion_culled or
            !commandsEqual(next.items, self.commands);
        // `next.items` was just written, so the comparison above must happen
        // before the swap; afterwards the old active buffer becomes the spare.
        // The allocation and the view are recorded separately: `items` is the
        // used length, `allocatedSlice()` the one a free must use.
        const old_active = self.active;
        self.active = next.allocatedSlice();
        self.commands = next.items;
        self.spare = old_active;
        self.culled = culled;
        self.culled_occluded = result.occlusion_culled;
        return .{ .culled = culled, .occlusion_culled = result.occlusion_culled, .changed = changed };
    }

    /// Frustum-only refill: the pre-occlusion extraction, byte for byte. Kept as a
    /// named entry point so call sites read as what they ask for.
    pub fn refill(
        self: *RenderFrame,
        scene: anytype,
        cam: Camera,
        mode: SortMode,
    ) !struct { culled: usize, changed: bool } {
        const r = try self.refillWithOcclusion(scene, cam, mode, null);
        return .{ .culled = r.culled, .changed = r.changed };
    }

    pub fn count(self: RenderFrame) usize {
        return self.commands.len;
    }
};

/// Field-by-field comparison of two draw lists.
///
/// Not a byte comparison: `DrawCommand` has padding the compiler may leave
/// undefined, so comparing raw bytes reports a change between two lists that are
/// identical in every field that is actually read.
pub fn commandsEqual(a: []const DrawCommand, b: []const DrawCommand) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.entity.eql(y.entity)) return false;
        if (x.mesh != y.mesh or x.material != y.material) return false;
        if (!std.mem.eql(f32, &x.world, &y.world)) return false;
        if (!std.meta.eql(x.bounds, y.bounds)) return false;
        if (x.depth != y.depth) return false;
    }
    return true;
}

fn sortCommands(items: []DrawCommand, mode: SortMode) void {
    switch (mode) {
        .front_to_back => std.mem.sort(DrawCommand, items, {}, struct {
            fn less(_: void, a: DrawCommand, b: DrawCommand) bool {
                if (a.depth != b.depth) return a.depth < b.depth;
                return a.entity.key() < b.entity.key();
            }
        }.less),
        .back_to_front => std.mem.sort(DrawCommand, items, {}, struct {
            fn less(_: void, a: DrawCommand, b: DrawCommand) bool {
                if (a.depth != b.depth) return a.depth > b.depth;
                return a.entity.key() < b.entity.key();
            }
        }.less),
        .by_material => std.mem.sort(DrawCommand, items, {}, struct {
            fn less(_: void, a: DrawCommand, b: DrawCommand) bool {
                if (a.material != b.material) return a.material < b.material;
                if (a.mesh != b.mesh) return a.mesh < b.mesh;
                return a.entity.key() < b.entity.key();
            }
        }.less),
    }
}

/// Extract a culled, sorted draw list from `scene` (a `*Scene(schema)` with
/// `Transform` + `Renderable`) as seen by `cam`. Computes the world-transform
/// snapshot once, culls each renderable's world AABB against the camera frustum,
/// and sorts survivors by `mode`. The caller owns the returned `RenderFrame`.
///
/// Fails only on allocation failure (the scene is already valid). Entities whose
/// world matrix is absent from the snapshot are skipped defensively.
pub fn extractDrawList(scene: anytype, cam: Camera, mode: SortMode, gpa: Allocator) !RenderFrame {
    return extractDrawListOcclusion(scene, cam, mode, gpa, null);
}

/// `extractDrawList` with the optional occlusion stage. A one-shot list has no
/// frame-to-frame state to reuse, so the pass owns a throwaway buffer here; a frame
/// loop should keep a `RenderFrame` and call `refillWithOcclusion` instead, which
/// reuses it and allocates nothing in the steady state.
pub fn extractDrawListOcclusion(
    scene: anytype,
    cam: Camera,
    mode: SortMode,
    gpa: Allocator,
    config: ?Occlusion,
) !RenderFrame {
    var commands: std.ArrayList(DrawCommand) = .empty;
    errdefer commands.deinit(gpa);
    // The pass needs somewhere to keep its tile buffer. When it is asked for, that
    // buffer is this frame's own scratch and is handed back with the list, so it is
    // built once and not thrown away.
    var oscratch = try OcclusionScratch.init(gpa, config orelse .{});
    errdefer oscratch.deinit();
    const result = try extractIntoScratchOccluded(
        &commands,
        scene,
        cam,
        mode,
        gpa,
        gpa,
        if (config != null) &oscratch else null,
        config,
    );
    const owned = try commands.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    const spare = try gpa.alloc(DrawCommand, 0);
    errdefer gpa.free(spare);
    return .{
        .gpa = gpa,
        .commands = owned,
        .culled = result.culled,
        .culled_occluded = result.occlusion_culled,
        .active = owned,
        .spare = spare,
        .allocated_last_frame = false,
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .occlusion_scratch = oscratch,
    };
}

/// Fill `out` with the same sorted draw list `extractDrawList` produces, reusing
/// `out`'s capacity.
///
/// This is the entry point for a frame loop: the buffer is allocated once and
/// reused, so a steady-state frame performs no draw-list allocation (the only
/// remaining per-frame allocation is the world-transform snapshot, which belongs
/// to the scene). Leftover entries are dropped before the frame fills it again, so
/// the list never carries a stale command. Returns the number of culled
/// renderables.
pub fn extractInto(
    out: *std.ArrayList(DrawCommand),
    scene: anytype,
    cam: Camera,
    mode: SortMode,
    gpa: Allocator,
) !usize {
    return extractIntoScratch(out, scene, cam, mode, gpa, gpa);
}

pub fn extractIntoScratch(
    out: *std.ArrayList(DrawCommand),
    scene: anytype,
    cam: Camera,
    mode: SortMode,
    list_gpa: Allocator,
    scratch: Allocator,
) !usize {
    return (try extractIntoScratchOccluded(out, scene, cam, mode, list_gpa, scratch, null, null)).culled;
}

/// The extraction proper, with the optional occlusion stage.
///
/// Frustum culling runs first and fills `out`. With `config` set and a
/// `occ_scratch` to hold the tile buffer, a second stage then claims visible
/// occluders front to back and tests what is left; occlusion culls are removed from
/// `out` in place and counted separately. Without them this is exactly the
/// pre-occlusion function: same commands, same order, same `culled`.
pub fn extractIntoScratchOccluded(
    out: *std.ArrayList(DrawCommand),
    scene: anytype,
    cam: Camera,
    mode: SortMode,
    list_gpa: Allocator,
    scratch: Allocator,
    occ_scratch: ?*OcclusionScratch,
    config: ?Occlusion,
) !struct { culled: usize, occlusion_culled: usize } {
    out.clearRetainingCapacity();
    errdefer out.clearRetainingCapacity();

    var wt = try scene.computeWorldTransforms(scratch);
    defer wt.deinit();

    const frustum = culling.Frustum.fromMat4(cam.view_projection);
    var culled: usize = 0;

    var view = scene.ecsWorld().view(.{Renderable});
    while (view.next()) |entry| {
        const e = entry[0];
        const rend = entry[1];
        const world = wt.get(e) orelse continue;
        const world_bounds = culling.transformAabb(world, rend.bounds);
        if (frustum.classifyAabb(world_bounds) == .outside) {
            culled += 1;
            continue;
        }
        const view_center = transform.transformPoint(cam.view, world_bounds.center);
        try out.append(list_gpa, .{
            .entity = e,
            .mesh = rend.mesh,
            .material = rend.material,
            .world = world,
            .bounds = world_bounds,
            .depth = -view_center[2],
        });
    }

    var occlusion_culled: usize = 0;
    if (config != null and occ_scratch != null) {
        occlusion_culled = try applyOcclusion(out, cam, config.?, occ_scratch.?);
    }

    sortCommands(out.items, mode);
    // `culled` is the total the caller sees; the occlusion split is reported beside
    // it so a frame can say *why* something disappeared.
    return .{ .culled = culled + occlusion_culled, .occlusion_culled = occlusion_culled };
}

/// Occlusion pass: walk the frame front to back, testing each command against the
/// buffer built from the commands already passed, then claiming its own tiles.
///
/// Interleaving is what keeps the pass honest. Claiming *every* occluder first would
/// let a command occlude itself (its own tiles are in the buffer by the time it is
/// tested) and would let a farther occluder's depth bound compete with a nearer one's.
/// Ordering by depth, nearest first, removes both: a command is only ever tested
/// against strictly nearer geometry, and each bound claims tiles at most once.
///
/// Sorting first also makes the result independent of entity iteration order: the
/// same scene produces the same survivors whatever order the ECS hands the
/// components out in.
fn applyOcclusion(out: *std.ArrayList(DrawCommand), cam: Camera, config: Occlusion, scratch: *OcclusionScratch) !usize {
    try scratch.reset(config);
    const vp = cam.view_projection;
    if (out.items.len == 0) return 0;
    try scratch.sizeClaims(out.items.len);
    try scratch.sizePending(out.items.len);
    @memcpy(scratch.claims[0..out.items.len], out.items);
    const ordered = scratch.claims[0..out.items.len];
    // Ascending depth is nearest first (`depth` is positive in front). The entity key
    // breaks ties, so the order is total and reproducible.
    std.mem.sort(DrawCommand, ordered, {}, struct {
        fn less(_: void, a: DrawCommand, b: DrawCommand) bool {
            if (a.depth != b.depth) return a.depth < b.depth;
            return a.entity.key() < b.entity.key();
        }
    }.less);

    var kept: usize = 0;
    var removed: usize = 0;
    for (ordered) |cmd| {
        // Test first: at this point the buffer holds strictly nearer geometry only.
        if (scratch.buffer.isOccluded(vp, cmd.bounds, config.depth_bias)) {
            removed += 1;
            continue;
        }
        scratch.pending[kept] = cmd;
        kept += 1;
        // Then claim, so the commands that follow are tested against this bound too —
        // but only when it covers enough of the screen to be worth the tiles.
        const coverage = scratch.buffer.tileCoverage(vp, cmd.bounds) orelse continue;
        if (coverage < config.min_coverage) continue;
        scratch.buffer.add(vp, cmd.bounds);
    }
    @memcpy(out.items[0..kept], scratch.pending[0..kept]);
    out.shrinkRetainingCapacity(kept);
    return removed;
}

const testing = std.testing;
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const alloc_probe = @import("../core/alloc_probe.zig");

const TestScene = scene_mod.Scene(.{
    scene_mod.Component(components.Transform, "transform"),
    scene_mod.Component(Renderable, "renderable"),
});

fn testCamera() Camera {
    // Looking from +Z toward the origin; objects near the origin are visible.
    return Camera.perspectiveLookAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, 1.0, 1, 100);
}

test "extract: empty scene yields an empty frame" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    var frame = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 0), frame.count());
    try testing.expectEqual(@as(usize, 0), frame.culled);
}

test "extract: visible object is kept, off-screen object is culled" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const visible = try s.createEntity("visible", null);
    try s.addComponent(visible, components.Transform{ .position = .{ 0, 0, 0 } });
    try s.addComponent(visible, Renderable{ .mesh = 1, .material = 2 });

    const offscreen = try s.createEntity("offscreen", null);
    try s.addComponent(offscreen, components.Transform{ .position = .{ 500, 0, 0 } });
    try s.addComponent(offscreen, Renderable{ .mesh = 3, .material = 4 });

    var frame = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 1), frame.count());
    try testing.expectEqual(@as(usize, 1), frame.culled);
    try testing.expect(frame.commands[0].entity.eql(visible));
    try testing.expectEqual(@as(u32, 1), frame.commands[0].mesh);
    try testing.expectEqual(@as(u32, 2), frame.commands[0].material);
}

test "extract: entity without Renderable is not drawn" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const bare = try s.createEntity("bare", null);
    try s.addComponent(bare, components.Transform{ .position = .{ 0, 0, 0 } });
    var frame = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 0), frame.count());
}

test "extract: world matrix reflects the hierarchy" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("root", null);
    try s.addComponent(root, components.Transform{ .position = .{ 1, 0, 0 } });
    const child = try s.createEntity("child", s.idOf(root));
    try s.addComponent(child, components.Transform{ .position = .{ 0, 2, 0 } });
    try s.addComponent(child, Renderable{ .mesh = 7 });

    var frame = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 1), frame.count());
    // Child world position = root(1,0,0) + child(0,2,0) = (1,2,0).
    const pos = transform.transformPoint(frame.commands[0].world, .{ 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 1), pos[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), pos[1], 1e-4);
}

test "extract: front_to_back and back_to_front sort by depth" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    // Three objects at different depths along the view axis (z). Nearer to the
    // camera (at z=10) means larger z.
    const near = try s.createEntity("near", null);
    try s.addComponent(near, components.Transform{ .position = .{ 0, 0, 5 } });
    try s.addComponent(near, Renderable{ .mesh = 1 });
    const mid = try s.createEntity("mid", null);
    try s.addComponent(mid, components.Transform{ .position = .{ 0, 0, 0 } });
    try s.addComponent(mid, Renderable{ .mesh = 2 });
    const far = try s.createEntity("far", null);
    try s.addComponent(far, components.Transform{ .position = .{ 0, 0, -5 } });
    try s.addComponent(far, Renderable{ .mesh = 3 });

    var front = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer front.deinit();
    try testing.expectEqual(@as(usize, 3), front.count());
    try testing.expect(front.commands[0].entity.eql(near));
    try testing.expect(front.commands[1].entity.eql(mid));
    try testing.expect(front.commands[2].entity.eql(far));
    try testing.expect(front.commands[0].depth <= front.commands[1].depth);
    try testing.expect(front.commands[1].depth <= front.commands[2].depth);

    var back = try extractDrawList(&s, testCamera(), .back_to_front, testing.allocator);
    defer back.deinit();
    try testing.expect(back.commands[0].entity.eql(far));
    try testing.expect(back.commands[2].entity.eql(near));
}

test "extract: by_material groups material then mesh" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const specs = [_]struct { mat: u32, mesh: u32 }{
        .{ .mat = 2, .mesh = 9 },
        .{ .mat = 1, .mesh = 5 },
        .{ .mat = 1, .mesh = 2 },
        .{ .mat = 2, .mesh = 1 },
    };
    for (specs) |sp| {
        const e = try s.createEntity(null, null);
        try s.addComponent(e, components.Transform{});
        try s.addComponent(e, Renderable{ .mesh = sp.mesh, .material = sp.mat });
    }
    var frame = try extractDrawList(&s, testCamera(), .by_material, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 4), frame.count());
    // Expected order: (1,2),(1,5),(2,1),(2,9).
    try testing.expectEqual(@as(u32, 1), frame.commands[0].material);
    try testing.expectEqual(@as(u32, 2), frame.commands[0].mesh);
    try testing.expectEqual(@as(u32, 1), frame.commands[1].material);
    try testing.expectEqual(@as(u32, 5), frame.commands[1].mesh);
    try testing.expectEqual(@as(u32, 2), frame.commands[2].material);
    try testing.expectEqual(@as(u32, 1), frame.commands[2].mesh);
    try testing.expectEqual(@as(u32, 2), frame.commands[3].material);
    try testing.expectEqual(@as(u32, 9), frame.commands[3].mesh);
}

test "extract: deterministic output for identical scenes" {
    var a = try TestScene.init(testing.allocator, "main");
    defer a.deinit();
    var b = try TestScene.init(testing.allocator, "main");
    defer b.deinit();
    for ([_]*TestScene{ &a, &b }) |s| {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const e = try s.createEntity(null, null);
            try s.addComponent(e, components.Transform{ .position = .{ @floatFromInt(i % 3), 0, 0 } });
            try s.addComponent(e, Renderable{ .mesh = @intCast(i), .material = @intCast(i % 2) });
        }
    }
    var fa = try extractDrawList(&a, testCamera(), .by_material, testing.allocator);
    defer fa.deinit();
    var fb = try extractDrawList(&b, testCamera(), .by_material, testing.allocator);
    defer fb.deinit();
    try testing.expectEqual(fa.count(), fb.count());
    for (fa.commands, fb.commands) |ca, cb| {
        try testing.expectEqual(ca.mesh, cb.mesh);
        try testing.expectEqual(ca.material, cb.material);
        try testing.expectEqual(ca.entity.key(), cb.entity.key());
    }
}

test "extract: scaled bounds still cull correctly" {
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    // A tiny object far off-screen stays culled even with a large local bound
    // scaled down; a huge bound that reaches the view is kept.
    const small = try s.createEntity("small", null);
    try s.addComponent(small, components.Transform{ .position = .{ 500, 0, 0 }, .scale = .{ 0.01, 0.01, 0.01 } });
    try s.addComponent(small, Renderable{ .bounds = .{ .extents = .{ 1, 1, 1 } } });

    var frame = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 0), frame.count());
    try testing.expectEqual(@as(usize, 1), frame.culled);
}

test "Renderable: isValid rejects non-finite and negative extents" {
    try testing.expect((Renderable{}).isValid());
    var bad = Renderable{};
    bad.bounds.extents[0] = -1;
    try testing.expect(!bad.isValid());
    bad = Renderable{};
    bad.bounds.center[1] = std.math.nan(f32);
    try testing.expect(!bad.isValid());
}

test "extract: occlusion removes only what a nearer bound hides" {
    // A wall at z = 5 (2 units in front of the camera at z = 10) covering the whole
    // view, one small object behind it and one in front. The camera is at the
    // origin of the scene's view axis, so "in front" means a bigger z.
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();

    const wall = try s.createEntity("wall", null);
    try s.addComponent(wall, components.Transform{ .position = .{ 0, 0, 5 } });
    // Half-extents 3 in x and y: at 5 units from the camera the wall's silhouette
    // stops at NDC 0.6, leaving room for a bound that is inside the frustum but
    // clear of the wall.
    try s.addComponent(wall, Renderable{ .mesh = 1, .bounds = .{ .extents = .{ 3, 3, 0.25 } } });

    const hidden = try s.createEntity("hidden", null);
    try s.addComponent(hidden, components.Transform{ .position = .{ 0, 0, 0 } });
    try s.addComponent(hidden, Renderable{ .mesh = 2, .bounds = .{ .extents = .{ 0.2, 0.2, 0.2 } } });

    const near = try s.createEntity("near", null);
    try s.addComponent(near, components.Transform{ .position = .{ 0, 0, 8 } });
    try s.addComponent(near, Renderable{ .mesh = 3, .bounds = .{ .extents = .{ 0.2, 0.2, 0.2 } } });

    // Off to the side of the wall, still inside the frustum: unoccluded.
    const beside = try s.createEntity("beside", null);
    try s.addComponent(beside, components.Transform{ .position = .{ 8, 0, 0 } });
    try s.addComponent(beside, Renderable{ .mesh = 4, .bounds = .{ .extents = .{ 0.2, 0.2, 0.2 } } });

    var plain = try extractDrawList(&s, testCamera(), .front_to_back, testing.allocator);
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 4), plain.count());
    try testing.expectEqual(@as(usize, 0), plain.culled_occluded);

    var occluded = try extractDrawListOcclusion(&s, testCamera(), .front_to_back, testing.allocator, .{});
    defer occluded.deinit();
    // The one behind the wall is gone, the three others survive, and the totals add
    // up: the occlusion pass never loses a command silently.
    try testing.expectEqual(@as(usize, 3), occluded.count());
    try testing.expectEqual(@as(usize, 1), occluded.culled_occluded);
    try testing.expectEqual(@as(usize, 1), occluded.culled);
    for (occluded.commands) |c| try testing.expect(!c.entity.eql(hidden));
    // The order and every field of the survivors are untouched by the pass, so the
    // frame renders identically: only the hidden command is missing.
    var j: usize = 0;
    for (plain.commands) |c| {
        if (c.entity.eql(hidden)) continue;
        try testing.expect(c.entity.eql(occluded.commands[j].entity));
        try testing.expect(std.mem.eql(f32, &c.world, &occluded.commands[j].world));
        try testing.expectEqual(c.depth, occluded.commands[j].depth);
        j += 1;
    }
    try testing.expectEqual(occluded.count(), j);
}

test "extract: a slightly smaller occluder than the min_coverage keeps everything" {
    // The wall is visible but its footprint is under the default 16-tile threshold,
    // so it is never claimed and nothing is culled: the knob limits what may act as
    // an occluder, and a bound below it is only ever a *victim*.
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const wall = try s.createEntity("wall", null);
    try s.addComponent(wall, components.Transform{ .position = .{ 0, 0, 5 } });
    try s.addComponent(wall, Renderable{ .mesh = 1, .bounds = .{ .extents = .{ 6, 6, 0.25 } } });
    const hidden = try s.createEntity("hidden", null);
    try s.addComponent(hidden, components.Transform{ .position = .{ 0, 0, 0 } });
    try s.addComponent(hidden, Renderable{ .mesh = 2, .bounds = .{ .extents = .{ 0.2, 0.2, 0.2 } } });

    const high = draw_config: {
        var c = Occlusion{};
        c.min_coverage = 100_000;
        break :draw_config c;
    };
    var untouched = try extractDrawListOcclusion(&s, testCamera(), .front_to_back, testing.allocator, high);
    defer untouched.deinit();
    try testing.expectEqual(@as(usize, 2), untouched.count());
    try testing.expectEqual(@as(usize, 0), untouched.culled_occluded);
}

test "extract: occlusion stays conservative for coincident and touching bounds" {
    // The "hidden" object sits exactly on the wall's far face: with the default
    // depth bias it must survive, because the pass cannot prove it is behind.
    var s = try TestScene.init(testing.allocator, "main");
    defer s.deinit();
    const wall = try s.createEntity("wall", null);
    try s.addComponent(wall, components.Transform{ .position = .{ 0, 0, 5 } });
    try s.addComponent(wall, Renderable{ .mesh = 1, .bounds = .{ .extents = .{ 6, 6, 0.25 } } });
    const coplanar = try s.createEntity("coplanar", null);
    try s.addComponent(coplanar, components.Transform{ .position = .{ 0, 0, 4.75 } });
    try s.addComponent(coplanar, Renderable{ .mesh = 2, .bounds = .{ .extents = .{ 0.2, 0.2, 0.2 } } });

    var occluded = try extractDrawListOcclusion(&s, testCamera(), .front_to_back, testing.allocator, .{});
    defer occluded.deinit();
    try testing.expectEqual(@as(usize, 2), occluded.count());
    try testing.expectEqual(@as(usize, 0), occluded.culled_occluded);
}

test "RenderFrame: occlusion refill reuses its buffer and reports the split" {
    const gpa = testing.allocator;
    var counter = Counter{ .parent = gpa };
    const counting = counter.allocator();

    var s = try TestScene.init(gpa, "main");
    defer s.deinit();
    const wall = try s.createEntity("wall", null);
    try s.addComponent(wall, components.Transform{ .position = .{ 0, 0, 5 } });
    try s.addComponent(wall, Renderable{ .mesh = 1, .bounds = .{ .extents = .{ 6, 6, 0.25 } } });
    for (0..8) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        const e = try s.createEntity(name, null);
        try s.addComponent(e, components.Transform{ .position = .{ 0, 0, @as(f32, @floatFromInt(i)) * 0.1 } });
        try s.addComponent(e, Renderable{ .mesh = 2, .bounds = .{ .extents = .{ 0.01, 0.01, 0.01 } } });
    }

    var frame = try RenderFrame.init(counting);
    defer frame.deinit();
    // Warm up both double buffers and the occlusion queues.
    _ = try frame.refillWithOcclusion(&s, testCamera(), .front_to_back, .{});
    _ = try frame.refillWithOcclusion(&s, testCamera(), .front_to_back, .{});

    counter.bytes = 0;
    counter.calls = 0;
    const steady = try frame.refillWithOcclusion(&s, testCamera(), .front_to_back, .{});
    try testing.expectEqual(@as(usize, 0), counter.calls);
    try testing.expectEqual(@as(usize, 0), counter.bytes);
    // The wall and the eight hidden things: only the wall survives.
    try testing.expectEqual(@as(usize, 1), frame.count());
    try testing.expectEqual(@as(usize, 8), steady.occlusion_culled);
    try testing.expectEqual(frame.culled_occluded, steady.occlusion_culled);
    try testing.expect(!steady.changed);

    // Turning the pass off restores the nine commands, and the buffer is reusable.
    const off = try frame.refill(&s, testCamera(), .front_to_back);
    try testing.expectEqual(@as(usize, 9), frame.count());
    try testing.expectEqual(@as(usize, 0), frame.culled_occluded);
    try testing.expect(off.changed);
}

test "extract: survives every allocation failure without leaking" {
    try alloc_probe.check(
        struct {
            fn f(alloc: Allocator) !void {
                var s = try TestScene.init(alloc, "main");
                defer s.deinit();
                const e = try s.createEntity("e", null);
                try s.addComponent(e, components.Transform{ .position = .{ 0, 0, 0 } });
                try s.addComponent(e, Renderable{ .mesh = 1 });
                var frame = try extractDrawList(&s, testCamera(), .front_to_back, alloc);
                frame.deinit();
            }
        }.f,
        .{},
    );
}

/// A counting allocator wrapper: how many bytes a stretch of code asked the
/// general-purpose allocator for. Used to prove the per-frame hand-off works.
const Counter = struct {
    parent: Allocator,
    bytes: usize = 0,
    calls: usize = 0,

    fn allocator(self: *Counter) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bytes += len;
        self.calls += 1;
        return out;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (self.parent.rawResize(buf, alignment, new_len, ret_addr)) {
            self.bytes += new_len -| buf.len;
            self.calls += 1;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.bytes += new_len -| buf.len;
        self.calls += 1;
        return out;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

test "RenderFrame: a steady-state frame takes no allocation from the general allocator" {
    // The per-frame hand-off, stated as a property: after a warm-up frame has grown
    // the draw list and the scratch arena to the size this scene needs, refilling
    // the same scene asks the general-purpose allocator for nothing at all — the
    // world-transform snapshot comes from the arena, which one reset per frame
    // releases.
    const gpa = testing.allocator;
    var counter = Counter{ .parent = gpa };
    const counting = counter.allocator();

    var s = try TestScene.init(gpa, "main");
    defer s.deinit();
    for (0..4) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "e{d}", .{i});
        const e = try s.createEntity(name, null);
        try s.addComponent(e, components.Transform{ .position = .{ @as(f32, @floatFromInt(i)), 0, 0 } });
        try s.addComponent(e, Renderable{ .mesh = @intCast(i + 1) });
    }

    var frame = try RenderFrame.init(counting);
    defer frame.deinit();

    // Warm-up: this frame is allowed to allocate (the buffers and the arena grow).
    // Two passes, not one: `refill` extracts into the *spare* buffer, so a
    // double-buffered frame reaches its steady size only after both buffers have
    // been grown once. That is the honest cost of comparing this frame with the
    // last, and it is paid twice per session, never per frame.
    const warm = try frame.refill(&s, testCamera(), .front_to_back);
    try testing.expectEqual(@as(usize, 4), frame.commands.len);
    _ = try frame.refill(&s, testCamera(), .front_to_back);

    // Steady state: same scene, same camera. Nothing new may be requested.
    counter.bytes = 0;
    counter.calls = 0;
    const steady = try frame.refill(&s, testCamera(), .front_to_back);
    try testing.expectEqual(@as(usize, 0), counter.calls);
    try testing.expectEqual(@as(usize, 0), counter.bytes);
    try testing.expectEqual(warm.culled, steady.culled);
    try testing.expect(!steady.changed);
    try testing.expectEqual(@as(usize, 4), frame.commands.len);

    // A scene that outgrows the arena still renders: the arena simply grows.
    for (0..64) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "g{d}", .{i});
        const e = try s.createEntity(name, null);
        try s.addComponent(e, components.Transform{ .position = .{ 0, @as(f32, @floatFromInt(i)) * 0.01, 0 } });
        try s.addComponent(e, Renderable{ .mesh = 7 });
    }
    _ = try frame.refill(&s, testCamera(), .front_to_back);
    try testing.expectEqual(@as(usize, 68), frame.commands.len);
}
