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

/// An owned, sorted draw list plus culling diagnostics.
pub const RenderFrame = struct {
    gpa: Allocator,
    commands: []DrawCommand,
    /// Number of renderables rejected by frustum culling this extraction.
    culled: usize,

    pub fn deinit(self: *RenderFrame) void {
        self.gpa.free(self.commands);
        self.* = undefined;
    }

    pub fn count(self: RenderFrame) usize {
        return self.commands.len;
    }
};

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
    var wt = try scene.computeWorldTransforms(gpa);
    defer wt.deinit();

    var commands: std.ArrayList(DrawCommand) = .empty;
    errdefer commands.deinit(gpa);

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
        try commands.append(gpa, .{
            .entity = e,
            .mesh = rend.mesh,
            .material = rend.material,
            .world = world,
            .bounds = world_bounds,
            .depth = -view_center[2],
        });
    }

    sortCommands(commands.items, mode);
    return RenderFrame{
        .gpa = gpa,
        .commands = try commands.toOwnedSlice(gpa),
        .culled = culled,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");

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

test "extract: survives every allocation failure without leaking" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            var s = try TestScene.init(alloc, "main");
            defer s.deinit();
            const e = try s.createEntity("e", null);
            try s.addComponent(e, components.Transform{ .position = .{ 0, 0, 0 } });
            try s.addComponent(e, Renderable{ .mesh = 1 });
            var frame = try extractDrawList(&s, testCamera(), .front_to_back, alloc);
            frame.deinit();
        }
    }.f, .{});
}
