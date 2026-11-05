//! Scene prefabs: reusable, versioned entity subtrees.
//!
//! A prefab is a strict JSON document with the same `format_version = 1` shape
//! as a `.scene`, but with exactly one root entity. It can be parsed from disk,
//! captured from a live scene subtree, serialized deterministically, and
//! instantiated into any scene with the same component schema. Instantiation
//! clones entities/components by value and remaps stable IDs and parent links,
//! so multiple instances are independent and never collide with existing IDs.
//!
//! This module reuses `Scene` parsing/serialization and `Scene.cloneSubtree`;
//! it does not duplicate the scene format or ECS storage.

const std = @import("std");
const scene_mod = @import("scene.zig");
const ecs = @import("../ecs.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = scene_mod.Error || error{
    /// The prefab document does not contain exactly one root entity.
    InvalidPrefab,
};

pub const format_version = scene_mod.format_version;
pub const max_prefab_bytes = scene_mod.max_scene_bytes;

/// A reusable prefab for scenes built from `schemas`.
pub fn Prefab(comptime schemas: anytype) type {
    const SceneT = scene_mod.Scene(schemas);

    return struct {
        const Self = @This();

        pub const Scene = SceneT;

        scene: SceneT,
        root_id: u64,

        fn wrap(s: SceneT) Error!Self {
            const roots = try s.rootIds(s.gpa);
            defer s.gpa.free(roots);
            if (roots.len != 1) return error.InvalidPrefab;
            return .{ .scene = s, .root_id = roots[0] };
        }

        /// Parse a strict prefab document (a scene document with one root).
        pub fn parse(gpa: Allocator, bytes: []const u8) Error!Self {
            var s = try SceneT.parse(gpa, bytes);
            errdefer s.deinit();
            return wrap(s);
        }

        /// Load a prefab file relative to `dir` (usually the project root).
        pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Self {
            var s = try SceneT.load(gpa, io, dir, path);
            errdefer s.deinit();
            return wrap(s);
        }

        /// Capture the subtree rooted at `root` from a live scene into a new
        /// prefab. The source scene is unchanged. The prefab root becomes the
        /// captured root; its original parent (if any) is dropped.
        pub fn fromScene(gpa: Allocator, source: *SceneT, root_entity: ecs.Entity, opt_name: ?[]const u8) Error!Self {
            const root_id = source.idOf(root_entity) orelse return error.EntityNotFound;
            const prefab_name = opt_name orelse (source.nameOf(root_entity) orelse "prefab");
            var s = try SceneT.init(gpa, prefab_name);
            errdefer s.deinit();
            const inst = try s.cloneSubtree(source, root_id, null);
            return .{ .scene = s, .root_id = inst.root_id };
        }

        /// Instantiate the prefab into `target`, attaching the cloned root to
        /// `parent_id` (or as a root when null). Returns the new root handle.
        pub fn instantiate(self: *Self, target: *SceneT, parent_id: ?u64) Error!ecs.Entity {
            const inst = try target.cloneSubtree(&self.scene, self.root_id, parent_id);
            return inst.root;
        }

        /// Serialize deterministically (same layout as a scene document).
        pub fn serialize(self: *Self, gpa: Allocator) Error![]u8 {
            return self.scene.serialize(gpa);
        }

        /// Save to a project-relative path, creating parent directories.
        pub fn save(self: *Self, io: Io, dir: Io.Dir, path: []const u8) Error!void {
            return self.scene.save(io, dir, path);
        }

        pub fn deinit(self: *Self) void {
            self.scene.deinit();
            self.* = undefined;
        }

        pub fn count(self: Self) usize {
            return self.scene.count();
        }

        pub fn root(self: *Self) ecs.Entity {
            return self.scene.entityById(self.root_id).?;
        }

        pub fn name(self: Self) []const u8 {
            return self.scene.name;
        }
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Transform = @import("components.zig").Transform;

const Marker = struct { value: i32 };
const Validated = struct {
    value: i32,
    pub fn isValid(self: @This()) bool {
        return self.value >= 0;
    }
};
const TestScene = scene_mod.Scene(.{
    scene_mod.Component(Transform, "transform"),
    scene_mod.Component(Marker, "marker"),
    scene_mod.Component(Validated, "validated"),
});
const TestPrefab = Prefab(.{
    scene_mod.Component(Transform, "transform"),
    scene_mod.Component(Marker, "marker"),
    scene_mod.Component(Validated, "validated"),
});

const prefab_doc =
    \\{ "format_version": 1, "name": "enemy", "entities": [
    \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [1, 2, 3] }, "marker": { "value": 7 } } },
    \\  { "id": 2, "name": "Child", "parent": 1, "components": { "marker": { "value": 9 } } }
    \\] }
;

test "prefab: parse a single-root document" {
    var p = try TestPrefab.parse(testing.allocator, prefab_doc);
    defer p.deinit();
    try testing.expectEqualStrings("enemy", p.name());
    try testing.expectEqual(@as(usize, 2), p.count());
    try testing.expectEqual(@as(u64, 1), p.root_id);
    try testing.expectEqual(@as(i32, 7), p.scene.getComponent(Marker, p.root()).?.value);
}

test "prefab: parse rejects zero or multiple roots" {
    const empty =
        \\{ "format_version": 1, "name": "empty", "entities": [] }
    ;
    try testing.expectError(error.InvalidPrefab, TestPrefab.parse(testing.allocator, empty));

    const two_roots =
        \\{ "format_version": 1, "name": "multi", "entities": [
        \\  { "id": 1, "name": "A" },
        \\  { "id": 2, "name": "B" }
        \\] }
    ;
    try testing.expectError(error.InvalidPrefab, TestPrefab.parse(testing.allocator, two_roots));
}

test "prefab: fromScene captures only the subtree and drops the original parent" {
    var source = try TestScene.init(testing.allocator, "world");
    defer source.deinit();
    const parent = try source.createEntity("Parent", null);
    const root = try source.createEntity("Root", source.idOf(parent));
    try source.addComponent(root, Transform{ .position = .{ 4, 5, 6 } });
    const child = try source.createEntity("Child", source.idOf(root));
    try source.addComponent(child, Marker{ .value = 11 });
    const sibling = try source.createEntity("Sibling", source.idOf(parent));
    try source.addComponent(sibling, Marker{ .value = 99 });

    var p = try TestPrefab.fromScene(testing.allocator, &source, root, "captured");
    defer p.deinit();
    try testing.expectEqualStrings("captured", p.name());
    try testing.expectEqual(@as(usize, 2), p.count()); // root + child, not parent/sibling
    try testing.expectEqual(@as(u64, 1), p.root_id); // deterministic remap
    try testing.expect(p.scene.parent(p.root()) == null);
    try testing.expectEqual(@as(i32, 11), p.scene.getComponent(Marker, p.scene.entityById(2).?).?.value);
    // Source unchanged.
    try testing.expectEqual(@as(usize, 4), source.count());
}

test "prefab: instantiate remaps IDs/hierarchy/components and supports multiple instances" {
    var p = try TestPrefab.parse(testing.allocator, prefab_doc);
    defer p.deinit();
    var target = try TestScene.init(testing.allocator, "level");
    defer target.deinit();
    const anchor = try target.createEntity("Anchor", null);
    try target.addComponent(anchor, Marker{ .value = 1 });

    const a = try p.instantiate(&target, target.idOf(anchor));
    const b = try p.instantiate(&target, target.idOf(anchor));
    try testing.expect(!a.eql(b));
    try testing.expectEqual(@as(usize, 5), target.count()); // anchor + 2 + 2

    // Both roots are children of the anchor and carry copied components.
    try testing.expect(target.parent(a).?.eql(anchor));
    try testing.expect(target.parent(b).?.eql(anchor));
    try testing.expectEqual(@as(i32, 7), target.getComponent(Marker, a).?.value);
    try testing.expectEqual(@as(i32, 7), target.getComponent(Marker, b).?.value);

    // Mutating one instance does not affect the other or the prefab.
    target.getComponent(Marker, a).?.value = 42;
    try testing.expectEqual(@as(i32, 7), target.getComponent(Marker, b).?.value);
    try testing.expectEqual(@as(i32, 7), p.scene.getComponent(Marker, p.root()).?.value);

    // Each instance has its own child with the remapped parent link.
    const ca = target.entityById(target.idOf(a).? + 1).?;
    const cb = target.entityById(target.idOf(b).? + 1).?;
    try testing.expect(target.parent(ca).?.eql(a));
    try testing.expect(target.parent(cb).?.eql(b));
    try testing.expectEqual(@as(i32, 9), target.getComponent(Marker, ca).?.value);
}

test "prefab: instantiate as root and serialize/parse roundtrip" {
    var p = try TestPrefab.parse(testing.allocator, prefab_doc);
    defer p.deinit();
    var target = try TestScene.init(testing.allocator, "level");
    defer target.deinit();
    const r = try p.instantiate(&target, null);
    try testing.expect(target.parent(r) == null);

    const bytes = try p.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var p2 = try TestPrefab.parse(testing.allocator, bytes);
    defer p2.deinit();
    try testing.expectEqual(p.count(), p2.count());
    try testing.expectEqual(p.root_id, p2.root_id);
}

test "prefab: cloneSubtree survives allocation failure without leaking" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            var source = try TestScene.init(alloc, "source");
            defer source.deinit();
            const root = try source.createEntity("Root", null);
            try source.addComponent(root, Marker{ .value = 1 });
            const child = try source.createEntity("Child", source.idOf(root));
            try source.addComponent(child, Marker{ .value = 2 });

            var target = try TestScene.init(alloc, "target");
            defer target.deinit();
            const anchor = try target.createEntity("Anchor", null);
            const before = target.count();
            const inst = try target.cloneSubtree(&source, source.idOf(root).?, target.idOf(anchor));
            try testing.expectEqual(@as(usize, before + 2), target.count());
            try testing.expect(target.parent(inst.root).?.eql(anchor));
        }
    }.f, .{});
}

test "scene: cloneSubtree rolls back created entities when a component copy fails" {
    var source = try TestScene.init(testing.allocator, "source");
    defer source.deinit();
    const root = try source.createEntity("Root", null);
    try source.addComponent(root, Validated{ .value = 1 });
    const child = try source.createEntity("Child", source.idOf(root));
    try source.addComponent(child, Validated{ .value = 1 });
    // Bypass validation to make the child's component invalid; cloning must
    // reject it and roll back every entity created during the call.
    source.getComponent(Validated, child).?.value = -1;

    var target = try TestScene.init(testing.allocator, "target");
    defer target.deinit();
    const anchor = try target.createEntity("Anchor", null);
    const before = target.count();
    try testing.expectError(
        error.InvalidComponent,
        target.cloneSubtree(&source, source.idOf(root).?, target.idOf(anchor)),
    );
    try testing.expectEqual(before, target.count());
    try testing.expect(target.alive(anchor));
}
