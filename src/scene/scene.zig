//! Versioned scene documents backed by the ECS.
//!
//! A scene owns a typed ECS world, stable entity IDs and a parent hierarchy.
//! Runtime entity handles are generational and may be recycled; stable IDs are
//! monotonic `u64` values used by the file format and are never reused. The
//! scene keeps the two mappings in sync and rejects stale handles.
//!
//! Serialization is strict JSON (`format_version = 1`): unknown fields,
//! duplicate fields, duplicate entity IDs, unknown components, missing parents
//! and parent cycles are rejected. Component types must be plain data (no
//! pointers/slices), enforced at comptime, so copying them into ECS pools cannot
//! create dangling references.
//!
//! Ownership: a `Scene` owns its arena, ECS world and ID maps. Call `deinit`
//! exactly once. Like other owning structs, it is move-only; do not copy it and
//! deinit both copies.

const std = @import("std");
const ecs = @import("../ecs.zig");
const paths = @import("../core/paths.zig");
const validation = @import("../core/validation.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const format_version: u32 = 1;
pub const max_scene_bytes: usize = 16 * 1024 * 1024;
pub const max_entities: usize = 1_000_000;

pub const Error = error{
    InvalidJson,
    UnsupportedFormatVersion,
    InvalidName,
    InvalidEntity,
    DuplicateEntityId,
    InvalidComponent,
    InvalidParent,
    ParentCycle,
    EntityNotFound,
    EntityNotAlive,
    IdExhausted,
    SceneTooLarge,
    UnsafePath,
    ProjectIo,
    OutOfMemory,
};

/// Declare a serializable component for a scene schema.
///
/// `name` is the stable JSON key and must be a Zig-identifier-like string
/// (`[A-Za-z_][A-Za-z0-9_]*`). `T` must be plain data. If `T` declares
/// `pub fn isValid(self: T) bool`, the scene calls it before storing/serializing
/// the component.
pub fn Component(comptime T: type, comptime name: [:0]const u8) type {
    comptime {
        validateComponentName(name);
        assertPlainData(T);
    }
    return struct {
        pub const component_type = T;
        pub const component_name = name;
    };
}

fn validateComponentName(comptime name: []const u8) void {
    if (name.len == 0) @compileError("component name must not be empty");
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
        @compileError("component name must start with a letter or underscore: " ++ name);
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_'))
            @compileError("component name must contain only letters, digits or underscores: " ++ name);
    }
}

fn assertPlainData(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => {},
        .array => |info| assertPlainData(info.child),
        .optional => |info| assertPlainData(info.child),
        .@"struct" => |info| {
            const dummy: T = undefined;
            inline for (info.field_names) |field_name| {
                const FieldType = @TypeOf(@field(dummy, field_name));
                assertPlainData(FieldType);
            }
        },
        else => @compileError("scene component must be plain data (no pointers/slices/unions): " ++ @typeName(T)),
    }
}

fn componentIsValid(comptime T: type, value: T) bool {
    if (@hasDecl(T, "isValid")) return value.isValid();
    return true;
}

pub fn Scene(comptime schemas: anytype) type {
    comptime {
        // Reject duplicate component names early.
        for (schemas, 0..) |A, i| {
            for (schemas, 0..) |B, j| {
                if (j <= i) continue;
                if (std.mem.eql(u8, A.component_name, B.component_name))
                    @compileError("duplicate scene component name: " ++ A.component_name);
            }
        }
    }

    const ComponentsJson = blk: {
        var names: [schemas.len][]const u8 = undefined;
        var types: [schemas.len]type = undefined;
        var attrs: [schemas.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        inline for (schemas, 0..) |S, i| {
            names[i] = S.component_name;
            types[i] = ?S.component_type;
            const default: ?S.component_type = null;
            attrs[i] = .{ .default_value_ptr = &default };
        }
        break :blk @Struct(.auto, null, &names, &types, &attrs);
    };

    const WorldType = blk: {
        // Build a comptime tuple *value* whose elements are component types,
        // which is what ecs.World expects. The tuple's field type is `type`.
        var field_types: [schemas.len]type = undefined;
        for (&field_types) |*ft| ft.* = type;
        const TupleType = @Tuple(&field_types);
        var comps: TupleType = undefined;
        inline for (schemas, 0..) |S, i| comps[i] = S.component_type;
        break :blk ecs.World(comps);
    };

    const RawEntity = struct {
        id: u64,
        name: ?[]const u8 = null,
        parent: ?u64 = null,
        components: ComponentsJson = .{},
    };

    const RawScene = struct {
        format_version: u32,
        name: []const u8,
        entities: []const RawEntity = &.{},
    };

    const Record = struct {
        entity: ecs.Entity,
        name: ?[]const u8,
        parent: ?u64,
    };

    return struct {
        const Self = @This();

        gpa: Allocator,
        arena: *std.heap.ArenaAllocator,
        name: []const u8,
        world: WorldType,
        records: std.AutoHashMap(u64, Record),
        entity_ids: std.AutoHashMap(u64, u64),
        next_id: u64,

        pub fn init(gpa: Allocator, name: []const u8) Error!Self {
            validation.validateDisplayName(name) catch return error.InvalidName;
            var arena = try gpa.create(std.heap.ArenaAllocator);
            errdefer gpa.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const owned_name = try arena.allocator().dupe(u8, name);
            return .{
                .gpa = gpa,
                .arena = arena,
                .name = owned_name,
                .world = WorldType.init(gpa),
                .records = std.AutoHashMap(u64, Record).init(gpa),
                .entity_ids = std.AutoHashMap(u64, u64).init(gpa),
                .next_id = 1,
            };
        }

        pub fn deinit(self: *Self) void {
            self.world.deinit();
            self.records.deinit();
            self.entity_ids.deinit();
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
            self.* = undefined;
        }

        /// Number of live scene entities.
        pub fn count(self: Self) usize {
            return self.records.count();
        }

        /// Create an entity with a fresh stable ID. `parent` is a stable ID, or
        /// null for a root entity. The returned handle is generational.
        pub fn createEntity(self: *Self, name: ?[]const u8, parent_id: ?u64) Error!ecs.Entity {
            if (self.next_id == 0) return error.IdExhausted;
            const id = self.next_id;
            return self.createEntityWithId(id, name, parent_id);
        }

        fn createEntityWithId(self: *Self, id: u64, name: ?[]const u8, parent_id: ?u64) Error!ecs.Entity {
            if (id == 0) return error.InvalidEntity;
            if (self.records.contains(id)) return error.DuplicateEntityId;
            if (name) |n| validation.validateDisplayName(n) catch return error.InvalidName;
            if (parent_id) |p| {
                if (!self.records.contains(p)) return error.InvalidParent;
            }

            const owned_name = if (name) |n| try self.arena.allocator().dupe(u8, n) else null;
            const entity = try self.world.create();
            errdefer self.world.destroy(entity);

            try self.records.put(id, .{ .entity = entity, .name = owned_name, .parent = parent_id });
            errdefer _ = self.records.remove(id);
            try self.entity_ids.put(entity.key(), id);

            if (self.next_id != 0) {
                if (id == std.math.maxInt(u64)) {
                    self.next_id = 0;
                } else if (id + 1 > self.next_id) {
                    self.next_id = id + 1;
                }
            }
            return entity;
        }

        /// Destroy an entity. Direct children are reparented to the destroyed
        /// entity's parent (or become roots). No-op for a dead handle.
        pub fn destroyEntity(self: *Self, entity: ecs.Entity) void {
            if (!self.world.alive(entity)) return;
            const id = self.entity_ids.get(entity.key()) orelse return;
            const record = self.records.get(id) orelse return;
            const new_parent = record.parent;

            var it = self.records.iterator();
            while (it.next()) |entry| {
                const child = entry.value_ptr;
                if (child.parent) |p| {
                    if (p == id) child.parent = new_parent;
                }
            }

            self.world.destroy(entity);
            _ = self.records.remove(id);
            _ = self.entity_ids.remove(entity.key());
        }

        pub fn alive(self: Self, entity: ecs.Entity) bool {
            return self.world.alive(entity) and self.entity_ids.contains(entity.key());
        }

        pub fn entityById(self: Self, id: u64) ?ecs.Entity {
            const record = self.records.get(id) orelse return null;
            if (!self.world.alive(record.entity)) return null;
            return record.entity;
        }

        pub fn idOf(self: Self, entity: ecs.Entity) ?u64 {
            if (!self.world.alive(entity)) return null;
            return self.entity_ids.get(entity.key());
        }

        pub fn nameOf(self: Self, entity: ecs.Entity) ?[]const u8 {
            const id = self.idOf(entity) orelse return null;
            const record = self.records.get(id) orelse return null;
            return record.name;
        }

        pub fn parent(self: Self, entity: ecs.Entity) ?ecs.Entity {
            const id = self.idOf(entity) orelse return null;
            const record = self.records.get(id) orelse return null;
            const pid = record.parent orelse return null;
            return self.entityById(pid);
        }

        /// Set or clear an entity's parent. Rejects dead handles, missing
        /// parents, self-parenting and cycles.
        pub fn setParent(self: *Self, entity: ecs.Entity, parent_entity: ?ecs.Entity) Error!void {
            if (!self.world.alive(entity)) return error.EntityNotAlive;
            const id = self.entity_ids.get(entity.key()) orelse return error.EntityNotFound;
            var parent_id: ?u64 = null;
            if (parent_entity) |p| {
                if (!self.world.alive(p)) return error.EntityNotAlive;
                const pid = self.entity_ids.get(p.key()) orelse return error.EntityNotFound;
                if (pid == id) return error.InvalidParent;
                if (self.wouldCycle(id, pid)) return error.ParentCycle;
                parent_id = pid;
            }
            self.records.getPtr(id).?.parent = parent_id;
        }

        fn wouldCycle(self: Self, id: u64, parent_id: u64) bool {
            var current: ?u64 = parent_id;
            var steps: usize = 0;
            while (current) |cid| {
                if (cid == id) return true;
                steps += 1;
                if (steps > self.records.count()) return true;
                const record = self.records.get(cid) orelse return true;
                current = record.parent;
            }
            return false;
        }

        pub fn addComponent(self: *Self, entity: ecs.Entity, value: anytype) Error!void {
            const T = @TypeOf(value);
            if (!self.alive(entity)) return error.EntityNotAlive;
            if (!componentIsValid(T, value)) return error.InvalidComponent;
            self.world.add(entity, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EntityNotAlive => return error.EntityNotAlive,
            };
        }

        pub fn getComponent(self: *Self, comptime T: type, entity: ecs.Entity) ?*T {
            if (!self.alive(entity)) return null;
            return self.world.get(T, entity);
        }

        pub fn hasComponent(self: *Self, comptime T: type, entity: ecs.Entity) bool {
            if (!self.alive(entity)) return false;
            return self.world.has(T, entity);
        }

        pub fn removeComponent(self: *Self, comptime T: type, entity: ecs.Entity) void {
            if (!self.alive(entity)) return;
            self.world.remove(T, entity);
        }

        /// Access the underlying ECS world for component queries and systems.
        /// Entity lifecycle must go through `createEntity`/`destroyEntity` so
        /// stable IDs and hierarchy stay consistent.
        pub fn ecsWorld(self: *Self) *WorldType {
            return &self.world;
        }

        /// Parse a strict, versioned scene document. On success the caller owns
        /// the returned scene; on error no resources leak.
        pub fn parse(gpa: Allocator, bytes: []const u8) Error!Self {
            if (bytes.len > max_scene_bytes) return error.SceneTooLarge;
            var tmp_arena = std.heap.ArenaAllocator.init(gpa);
            defer tmp_arena.deinit();

            const parsed = std.json.parseFromSlice(RawScene, tmp_arena.allocator(), bytes, .{
                .duplicate_field_behavior = .@"error",
                .ignore_unknown_fields = false,
                .max_value_len = bytes.len,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJson,
            };
            defer parsed.deinit();
            const raw = parsed.value;

            if (raw.format_version != format_version) return error.UnsupportedFormatVersion;
            validation.validateDisplayName(raw.name) catch return error.InvalidName;
            if (raw.entities.len > max_entities) return error.InvalidEntity;

            var self = try init(gpa, raw.name);
            errdefer self.deinit();

            // First pass: create entities and components. Parents may reference
            // entities later in the file, so hierarchy is wired in pass two.
            for (raw.entities) |re| {
                const entity = try self.createEntityWithId(re.id, re.name, null);
                inline for (schemas) |S| {
                    if (@field(re.components, S.component_name)) |value| {
                        try self.addComponent(entity, value);
                    }
                }
            }

            // Second pass: resolve and validate parents.
            for (raw.entities) |re| {
                if (re.parent) |pid| {
                    const entity = self.entityById(re.id) orelse return error.EntityNotFound;
                    const parent_entity = self.entityById(pid) orelse return error.InvalidParent;
                    try self.setParent(entity, parent_entity);
                }
            }
            return self;
        }

        /// Serialize to deterministic, indented JSON. Entities are emitted in
        /// ascending stable-ID order; absent optional fields are omitted.
        /// Caller owns the returned bytes.
        pub fn serialize(self: *Self, gpa: Allocator) Error![]u8 {
            var ids: std.ArrayList(u64) = .empty;
            defer ids.deinit(gpa);
            var entities: std.ArrayList(RawEntity) = .empty;
            defer entities.deinit(gpa);

            var it = self.records.iterator();
            while (it.next()) |entry| {
                try ids.append(gpa, entry.key_ptr.*);
            }
            std.mem.sort(u64, ids.items, {}, struct {
                fn less(_: void, a: u64, b: u64) bool {
                    return a < b;
                }
            }.less);

            for (ids.items) |id| {
                const record = self.records.get(id) orelse return error.EntityNotFound;
                if (!self.world.alive(record.entity)) return error.EntityNotFound;
                var components: ComponentsJson = .{};
                inline for (schemas) |S| {
                    if (self.world.get(S.component_type, record.entity)) |ptr| {
                        if (!componentIsValid(S.component_type, ptr.*)) return error.InvalidComponent;
                        @field(components, S.component_name) = ptr.*;
                    }
                }
                try entities.append(gpa, .{
                    .id = id,
                    .name = record.name,
                    .parent = record.parent,
                    .components = components,
                });
            }

            const doc = RawScene{
                .format_version = format_version,
                .name = self.name,
                .entities = entities.items,
            };
            return std.json.Stringify.valueAlloc(gpa, doc, .{
                .whitespace = .indent_2,
                .emit_null_optional_fields = false,
            }) catch return error.OutOfMemory;
        }

        /// Load a scene file relative to `dir` (usually the project root).
        pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Self {
            paths.validateRelative(path) catch return error.UnsafePath;
            const bytes = dir.readFileAlloc(io, path, gpa, .limited(max_scene_bytes)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProjectIo,
            };
            defer gpa.free(bytes);
            return parse(gpa, bytes);
        }

        /// Save the scene to a project-relative path, creating parent
        /// directories when needed. This writes the serialized document directly;
        /// callers that need crash-atomic replacement should stage a temp file.
        pub fn save(self: *Self, io: Io, dir: Io.Dir, path: []const u8) Error!void {
            paths.validateRelative(path) catch return error.UnsafePath;
            const bytes = try self.serialize(self.gpa);
            defer self.gpa.free(bytes);
            if (std.fs.path.dirname(path)) |parent_dir| {
                if (parent_dir.len > 0) {
                    dir.createDirPath(io, parent_dir) catch return error.ProjectIo;
                }
            }
            dir.writeFile(io, .{ .sub_path = path, .data = bytes }) catch return error.ProjectIo;
        }
    };
}

// --- tests -----------------------------------------------------------------

const Transform = @import("components.zig").Transform;
const TestScene = Scene(.{Component(Transform, "transform")});

const empty_scene =
    \\{ "format_version": 1, "name": "main", "entities": [] }
;

const populated_scene =
    \\{ "format_version": 1, "name": "main", "entities": [
    \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [1, 2, 3] } } },
    \\  { "id": 2, "name": "Child", "parent": 1 }
    \\] }
;

test "scene: parse empty scene" {
    var s = try TestScene.parse(std.testing.allocator, empty_scene);
    defer s.deinit();
    try std.testing.expectEqualStrings("main", s.name);
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "scene: create entities with stable IDs and names" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity("Root", null);
    const b = try s.createEntity("Child", s.idOf(a));
    try std.testing.expectEqual(@as(u64, 1), s.idOf(a).?);
    try std.testing.expectEqual(@as(u64, 2), s.idOf(b).?);
    try std.testing.expectEqualStrings("Root", s.nameOf(a).?);
    try std.testing.expect(s.parent(b).?.eql(a));
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "scene: add/get/remove transform component" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const e = try s.createEntity(null, null);
    try s.addComponent(e, Transform{ .position = .{ 1, 2, 3 } });
    try std.testing.expect(s.hasComponent(Transform, e));
    try std.testing.expectEqual(@as(f32, 1), s.getComponent(Transform, e).?.position[0]);
    s.removeComponent(Transform, e);
    try std.testing.expect(!s.hasComponent(Transform, e));
}

test "scene: stale handle cannot reach recycled entity" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity("A", null);
    try s.addComponent(a, Transform{ .position = .{ 1, 1, 1 } });
    s.destroyEntity(a);
    const b = try s.createEntity("B", null);
    try std.testing.expect(s.idOf(a) == null);
    try std.testing.expect(s.getComponent(Transform, a) == null);
    try std.testing.expectEqual(@as(u64, 2), s.idOf(b).?);
}

test "scene: destroy reparents children to grandparent" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("root", null);
    const mid = try s.createEntity("mid", s.idOf(root));
    const leaf = try s.createEntity("leaf", s.idOf(mid));
    s.destroyEntity(mid);
    try std.testing.expect(s.parent(leaf).?.eql(root));
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "scene: setParent rejects self and cycles" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity(null, null);
    const b = try s.createEntity(null, s.idOf(a));
    try std.testing.expectError(error.InvalidParent, s.setParent(a, a));
    try std.testing.expectError(error.ParentCycle, s.setParent(a, b));
    try s.setParent(b, null);
    try std.testing.expect(s.parent(b) == null);
}

test "scene: serialize/parse roundtrip with hierarchy and components" {
    var s = try TestScene.init(std.testing.allocator, "roundtrip");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    try s.addComponent(root, Transform{ .position = .{ 1, 2, 3 } });
    const child = try s.createEntity("Child", s.idOf(root));
    try s.addComponent(child, Transform{ .position = .{ 4, 5, 6 }, .scale = .{ 2, 2, 2 } });

    const bytes = try s.serialize(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var loaded = try TestScene.parse(std.testing.allocator, bytes);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("roundtrip", loaded.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    const lroot = loaded.entityById(1).?;
    const lchild = loaded.entityById(2).?;
    try std.testing.expectEqualStrings("Root", loaded.nameOf(lroot).?);
    try std.testing.expect(loaded.parent(lchild).?.eql(lroot));
    try std.testing.expectEqual(@as(f32, 4), loaded.getComponent(Transform, lchild).?.position[0]);
    try std.testing.expectEqual(@as(f32, 2), loaded.getComponent(Transform, lchild).?.scale[0]);
}

test "scene: serialize is deterministic and sorted by ID" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    _ = try s.createEntity(null, null);
    _ = try s.createEntity(null, null);
    const a = try s.serialize(std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try s.serialize(std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "\"id\": 1").? < std.mem.indexOf(u8, a, "\"id\": 2").?);
}

test "scene: parse rejects unsupported version and bad JSON" {
    try std.testing.expectError(error.UnsupportedFormatVersion, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 99, "name": "main", "entities": [] }
    ));
    try std.testing.expectError(error.InvalidJson, TestScene.parse(std.testing.allocator, "{ nope"));
    try std.testing.expectError(error.InvalidJson, TestScene.parse(std.testing.allocator,
        \\{ "name": "main", "entities": [] }
    ));
}

test "scene: parse rejects duplicate and zero entity IDs" {
    try std.testing.expectError(error.DuplicateEntityId, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1}, {"id":1} ] }
    ));
    try std.testing.expectError(error.InvalidEntity, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":0} ] }
    ));
}

test "scene: parse rejects unknown fields and components" {
    try std.testing.expectError(error.InvalidJson, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"bogus":true} ] }
    ));
    try std.testing.expectError(error.InvalidJson, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"components":{"nope":{}}} ] }
    ));
    try std.testing.expectError(error.InvalidJson, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"components":{"transform":{},"transform":{}}} ] }
    ));
}

test "scene: parse rejects missing parent, self parent and cycles" {
    try std.testing.expectError(error.InvalidParent, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"parent":99} ] }
    ));
    try std.testing.expectError(error.InvalidParent, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"parent":1} ] }
    ));
    try std.testing.expectError(error.ParentCycle, TestScene.parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "main", "entities": [ {"id":1,"parent":2}, {"id":2,"parent":1} ] }
    ));
}

test "scene: parse rejects invalid component values" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const e = try s.createEntity(null, null);
    var bad = Transform{};
    bad.position[0] = std.math.nan(f32);
    try std.testing.expectError(error.InvalidComponent, s.addComponent(e, bad));
}

test "scene: load/save file roundtrip and unsafe path rejection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try TestScene.init(std.testing.allocator, "file");
    defer s.deinit();
    const e = try s.createEntity("E", null);
    try s.addComponent(e, Transform{ .position = .{ 7, 8, 9 } });
    try s.save(std.testing.io, tmp.dir, "scenes/main.scene");

    var loaded = try TestScene.load(std.testing.allocator, std.testing.io, tmp.dir, "scenes/main.scene");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expectEqual(@as(f32, 7), loaded.getComponent(Transform, loaded.entityById(1).?).?.position[0]);

    try std.testing.expectError(error.UnsafePath, TestScene.load(std.testing.allocator, std.testing.io, tmp.dir, "../escape.scene"));
    try std.testing.expectError(error.ProjectIo, TestScene.load(std.testing.allocator, std.testing.io, tmp.dir, "missing.scene"));
}

test "scene: empty schema scene works" {
    const Empty = Scene(.{});
    var s = try Empty.parse(std.testing.allocator, empty_scene);
    defer s.deinit();
    const e = try s.createEntity("bare", null);
    try std.testing.expectEqual(@as(u64, 1), s.idOf(e).?);
    const bytes = try s.serialize(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var loaded = try Empty.parse(std.testing.allocator, bytes);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
}

fn parseAllocationProbe(allocator: Allocator) !void {
    var s = try TestScene.parse(allocator, populated_scene);
    s.deinit();
}

fn createAllocationProbe(allocator: Allocator) !void {
    var s = try TestScene.init(allocator, "main");
    defer s.deinit();
    const e = try s.createEntity("E", null);
    try s.addComponent(e, Transform{});
}

fn serializeAllocationProbe(allocator: Allocator) !void {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const e = try s.createEntity("E", null);
    try s.addComponent(e, Transform{});
    const bytes = try s.serialize(allocator);
    allocator.free(bytes);
}

test "scene: parse survives every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAllocationProbe, .{});
}

test "scene: create/add survives every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAllocationProbe, .{});
}

test "scene: serialize survives every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, serializeAllocationProbe, .{});
}
