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
const components_mod = @import("components.zig");
const transform = @import("transform.zig");

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

/// Membership test over a sorted slice, so bulk operations need no hash set.
fn containsSorted(sorted: []const u64, value: u64) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < value) {
            lo = mid + 1;
        } else if (sorted[mid] > value) {
            hi = mid;
        } else {
            return true;
        }
    }
    return false;
}

fn lessU64(_: void, a: u64, b: u64) bool {
    return a < b;
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
        /// Optional explicit sibling order. When absent, the entity's own stable ID
        /// is used as its sort key among siblings, which keeps old files (and new
        /// never-reordered entities) in creation order.
        order: ?u64 = null,
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

    // World-space transform helpers are only available when the schema includes
    // the built-in Transform component.
    const has_transform = blk: {
        for (schemas) |S| {
            if (S.component_type == components_mod.Transform) break :blk true;
        }
        break :blk false;
    };

    return struct {
        const Self = @This();

        /// The component types of this schema, in declaration order. Position `i` here
        /// is position `i` in the serialized document, and the same position an editor
        /// command uses to name a component without knowing its type by name.
        pub const component_types = blk: {
            var types: [schemas.len]type = undefined;
            for (schemas, 0..) |S, i| types[i] = S.component_type;
            break :blk types;
        };
        pub const component_count = schemas.len;

        gpa: Allocator,
        arena: *std.heap.ArenaAllocator,
        name: []const u8,
        world: WorldType,
        records: std.AutoHashMap(u64, Record),
        entity_ids: std.AutoHashMap(u64, u64),
        /// Explicit sibling order for entities whose order differs from their stable ID.
        /// Null until the first `setOrder` call; absent entries mean "natural order".
        sibling_order: ?std.AutoHashMap(u64, u64) = null,
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
            if (self.sibling_order) |*so| so.deinit();
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
            self.* = undefined;
        }

        /// Number of live scene entities.
        pub fn count(self: Self) usize {
            return self.records.count();
        }

        /// The stable ID the next `createEntity` will hand out.
        ///
        /// IDs are allocated monotonically and never reused, so a caller that
        /// creates a batch of entities can capture the exact set afterwards as
        /// the half-open range `[nextStableId() before, nextStableId() after)`.
        /// Bulk operations use this to track ownership without allocating, which
        /// keeps their rollback path working even when the allocator is failing.
        /// Returns 0 once the ID space is exhausted.
        pub fn nextStableId(self: Self) u64 {
            return self.next_id;
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

        /// Create an entity with a **caller-chosen** stable ID.
        ///
        /// This exists for restores: undoing a delete has to bring the entity back
        /// with the ID it had, or every reference to it (a selection, a command
        /// already in an undo stack) would dangle. IDs are still never reused by
        /// `createEntity`, which only hands out IDs above `next_id`; a restored ID is
        /// always one that was previously in use, and `next_id` is bumped past it.
        pub fn createEntityWithExactId(self: *Self, id: u64, name: ?[]const u8, parent_id: ?u64) Error!ecs.Entity {
            return self.createEntityWithId(id, name, parent_id);
        }

        /// Rename an entity. `name` is copied into the scene's arena, so the caller's
        /// buffer may die immediately; `null` removes the name.
        ///
        /// Note: the previous name stays in the arena until the scene is destroyed.
        /// Renaming in a loop therefore grows the arena by one name per rename — an
        /// acceptable cost for an editor session, and the reason this is documented
        /// rather than hidden.
        pub fn setName(self: *Self, entity: ecs.Entity, name: ?[]const u8) Error!void {
            if (!self.alive(entity)) return error.EntityNotAlive;
            const id = self.entity_ids.get(entity.key()) orelse return error.EntityNotFound;
            const owned: ?[]const u8 = if (name) |n| blk: {
                validation.validateDisplayName(n) catch return error.InvalidName;
                break :blk try self.arena.allocator().dupe(u8, n);
            } else null;
            self.records.getPtr(id).?.name = owned;
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
            if (self.sibling_order) |*so| _ = so.remove(id);
        }

        /// Destroy a set of entities in a single pass, identified by stable ID.
        ///
        /// `ids` must be sorted in non-decreasing order (duplicates are fine).
        /// Surviving children of destroyed entities are reparented to the nearest
        /// surviving ancestor, or become roots when there is none. That is
        /// exactly the result of calling `destroyEntity` once per ID, but the
        /// cost is O(records * log(ids)) instead of O(records * ids).
        ///
        /// The operation **cannot fail and does not allocate**: membership is a
        /// binary search over the caller's sorted slice, and ancestor resolution
        /// is memoized by path-compressing the `parent` field of the doomed
        /// records themselves, which are about to be deleted anyway. That makes
        /// it usable on teardown and rollback paths, where an allocator failure
        /// must not be able to strand entities. Unknown or dead IDs are ignored.
        ///
        /// Returns how many entities were actually destroyed.
        pub fn destroySet(self: *Self, ids: []const u64) usize {
            if (ids.len == 0) return 0;
            if (std.debug.runtime_safety) {
                for (ids[1..], ids[0 .. ids.len - 1]) |next, prev| {
                    std.debug.assert(next >= prev);
                }
            }

            // Reparent survivors first, while every record is still readable.
            var it = self.records.iterator();
            while (it.next()) |entry| {
                if (containsSorted(ids, entry.key_ptr.*)) continue;
                const pid = entry.value_ptr.parent orelse continue;
                if (!containsSorted(ids, pid)) continue;
                entry.value_ptr.parent = self.resolveSurvivingAncestor(ids, pid);
            }

            var removed: usize = 0;
            for (ids) |id| {
                const record = self.records.get(id) orelse continue;
                if (!self.world.alive(record.entity)) continue;
                self.world.destroy(record.entity);
                _ = self.entity_ids.remove(record.entity.key());
                _ = self.records.remove(id);
                if (self.sibling_order) |*so| _ = so.remove(id);
                removed += 1;
            }
            return removed;
        }

        /// Nearest ancestor of `start` that is not in `ids`, or null. `start`
        /// itself is doomed. Each doomed record on the walked path is rewritten
        /// to point straight at the answer, so a deep doomed chain is walked once
        /// in total rather than once per surviving child.
        fn resolveSurvivingAncestor(self: *Self, ids: []const u64, start: u64) ?u64 {
            var cursor: ?u64 = start;
            var survivor: ?u64 = null;
            // First find the answer, remembering the head of the walked chain.
            while (cursor) |c| {
                if (!containsSorted(ids, c)) {
                    survivor = c;
                    break;
                }
                const rec = self.records.getPtr(c) orelse break;
                cursor = rec.parent;
            }
            // Then compress: every doomed record between `start` and the answer
            // now points directly at it.
            var node: ?u64 = start;
            while (node) |c| {
                if (!containsSorted(ids, c)) break;
                const rec = self.records.getPtr(c) orelse break;
                const next = rec.parent;
                if (next == survivor) break;
                rec.parent = survivor;
                node = next;
            }
            return survivor;
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

        /// Sorted stable IDs of the direct children of `parent_id` (the roots when
        /// `parent_id` is null), written into `out` in ascending order.
        ///
        /// Returns how many IDs were written, which is `min(match_count, out.len)`:
        /// the buffer is never overflowed. When a parent has more children than the
        /// buffer holds, the **smallest** stable IDs are kept, so the result is a
        /// deterministic prefix rather than whatever the hash map happened to visit
        /// first. Allocation-free — the scan is over the scene's own records — which
        /// is what lets a tree view ask for one node's children per frame.
        /// Whether sibling `a` sorts before sibling `b`: ascending `(order, id)`.
        fn siblingLess(self: *const Self, a: u64, b: u64) bool {
            const oa = self.orderOf(a);
            const ob = self.orderOf(b);
            if (oa != ob) return oa < ob;
            return a < b;
        }

        pub fn childIdsInto(self: *const Self, parent_id: ?u64, out: []u64) usize {
            var written: usize = 0;
            var it = self.records.iterator();
            while (it.next()) |entry| {
                const record_parent = entry.value_ptr.parent;
                const matches = if (parent_id) |want| (record_parent != null and record_parent.? == want) else record_parent == null;
                if (!matches) continue;
                const id = entry.key_ptr.*;
                if (written < out.len) {
                    // Insertion sort into the window: a node usually has a handful
                    // of children, so this is cheaper than collecting and sorting.
                    // Shift right any sibling that sorts after `id`, then insert.
                    var i = written;
                    while (i > 0 and self.siblingLess(id, out[i - 1])) : (i -= 1) out[i] = out[i - 1];
                    out[i] = id;
                    written += 1;
                } else if (written > 0 and self.siblingLess(id, out[written - 1])) {
                    var i = written - 1;
                    while (i > 0 and self.siblingLess(id, out[i - 1])) : (i -= 1) out[i] = out[i - 1];
                    out[i] = id;
                }
            }
            return written;
        }

        /// The stable ID of an entity's parent, without resolving the parent entity.
        ///
        /// A tree view walks thousands of rows a frame and only needs the IDs, so asking
        /// for the entity and then its ID back would be two hash lookups per row for no
        /// information. Returns `null` for a root or an unknown ID.
        pub fn parentIdOf(self: *const Self, id: u64) ?u64 {
            const record = self.records.get(id) orelse return null;
            return record.parent;
        }

        /// Sorted stable IDs of all root entities (entities without a parent).
        /// Caller owns the returned slice and frees it with `gpa`.
        pub fn rootIds(self: *const Self, gpa: Allocator) Error![]u64 {
            // The order is defined by `childIdsInto`; this only sizes the slice.
            var total: usize = 0;
            var it = self.records.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.parent == null) total += 1;
            }
            const ids = try gpa.alloc(u64, total);
            errdefer gpa.free(ids);
            const written = self.childIdsInto(null, ids);
            std.debug.assert(written == total);
            return ids;
        }

        /// Result of cloning a subtree into a scene.
        pub const Instance = struct {
            root: ecs.Entity,
            root_id: u64,
            count: usize,
        };

        /// Clone the subtree rooted at `source.root_id` into `self`, attaching
        /// the cloned root to `parent_id` (or as a root when null). New stable
        /// IDs are allocated in ascending source-ID order, so the operation is
        /// deterministic. Components are copied by value (plain data). On error
        /// any entities created by this call are destroyed, leaving the target
        /// scene unchanged except for monotonic ID advancement.
        pub fn cloneSubtree(self: *Self, source: *Self, root_id: u64, parent_id: ?u64) Error!Instance {
            const root_record = source.records.get(root_id) orelse return error.EntityNotFound;
            if (!source.world.alive(root_record.entity)) return error.EntityNotFound;
            const parent_entity = if (parent_id) |pid|
                self.entityById(pid) orelse return error.InvalidParent
            else
                null;

            // Build a children adjacency map for the source, then collect the
            // subtree iteratively (no recursion, safe for deep hierarchies).
            var children: std.AutoHashMap(u64, std.ArrayList(u64)) = .init(self.gpa);
            defer {
                var vit = children.valueIterator();
                while (vit.next()) |list| list.deinit(self.gpa);
                children.deinit();
            }
            var sit = source.records.iterator();
            while (sit.next()) |entry| {
                if (entry.value_ptr.parent) |p| {
                    const gop = try children.getOrPut(p);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.gpa, entry.key_ptr.*);
                }
            }

            var order: std.ArrayList(u64) = .empty;
            defer order.deinit(self.gpa);
            var stack: std.ArrayList(u64) = .empty;
            defer stack.deinit(self.gpa);
            try stack.append(self.gpa, root_id);
            while (stack.items.len > 0) {
                const id = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                try order.append(self.gpa, id);
                if (children.getPtr(id)) |list| {
                    for (list.items) |child_id| try stack.append(self.gpa, child_id);
                }
            }
            std.mem.sort(u64, order.items, {}, lessU64);

            var map: std.AutoHashMap(u64, ecs.Entity) = .init(self.gpa);
            defer map.deinit();
            var created: std.ArrayList(ecs.Entity) = .empty;
            defer created.deinit(self.gpa);
            try created.ensureTotalCapacity(self.gpa, order.items.len);
            errdefer {
                var i = created.items.len;
                while (i > 0) {
                    i -= 1;
                    self.destroyEntity(created.items[i]);
                }
            }

            // First pass: create entities and copy components (parents wired later).
            for (order.items) |sid| {
                const rec = source.records.get(sid) orelse return error.EntityNotFound;
                const entity = try self.createEntity(rec.name, null);
                created.appendAssumeCapacity(entity);
                try map.put(sid, entity);
                inline for (schemas) |S| {
                    if (source.world.get(S.component_type, rec.entity)) |ptr| {
                        try self.addComponent(entity, ptr.*);
                    }
                }
            }

            // Second pass: remap parents inside the cloned subtree.
            for (order.items) |sid| {
                const entity = map.get(sid) orelse return error.EntityNotFound;
                const rec = source.records.get(sid) orelse return error.EntityNotFound;
                if (sid == root_id) {
                    if (parent_entity) |p| try self.setParent(entity, p);
                } else {
                    const pid = rec.parent orelse return error.InvalidParent;
                    const pe = map.get(pid) orelse return error.InvalidParent;
                    try self.setParent(entity, pe);
                }
            }

            const root_entity = map.get(root_id) orelse return error.EntityNotFound;
            return .{
                .root = root_entity,
                .root_id = self.idOf(root_entity) orelse return error.EntityNotFound,
                .count = order.items.len,
            };
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

        /// Set an entity's explicit sibling order. A value equal to the entity's own
        /// stable ID means "natural order"; any other value sorts siblings by
        /// `(order, id)` among children of the same parent.
        pub fn setOrder(self: *Self, id: u64, order: u64) !void {
            const record = self.records.get(id) orelse return error.EntityNotFound;
            if (!self.world.alive(record.entity)) return error.EntityNotAlive;
            if (order == id) {
                // Natural order: remove any explicit entry.
                if (self.sibling_order) |*so| _ = so.remove(id);
            } else {
                // Lazily allocate the map on first explicit order.
                if (self.sibling_order == null) {
                    const hm = std.AutoHashMap(u64, u64).init(self.gpa);
                    self.sibling_order = hm;
                }
                if (self.sibling_order) |*so| try so.put(id, order);
            }
        }

        /// The entity's explicit sibling order (defaults to its own stable ID).
        pub fn orderOf(self: *const Self, id: u64) u64 {
            if (self.sibling_order) |so| return so.get(id) orelse id;
            return id;
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

        /// A snapshot of world-space matrices for every live entity, computed in
        /// topological (parent-before-child) order. It is valid until the
        /// hierarchy or local transforms change; recompute to refresh. Lookup is
        /// by generational entity handle, so a stale handle returns null.
        /// Entities are stored in ascending stable-ID order for determinism.
        pub const WorldTransforms = struct {
            gpa: Allocator,
            matrices: []transform.Mat4,
            entities: []ecs.Entity,
            index: std.AutoHashMap(u64, usize),

            pub fn deinit(self: *WorldTransforms) void {
                self.gpa.free(self.matrices);
                self.gpa.free(self.entities);
                self.index.deinit();
                self.* = undefined;
            }

            pub fn count(self: WorldTransforms) usize {
                return self.matrices.len;
            }

            /// World matrix for a handle present in the snapshot (live at compute
            /// time), or null for a handle that is absent — notably a recycled
            /// slot's new generation, which can never read the previous entity's
            /// matrix. The snapshot is frozen; recompute after the scene changes.
            pub fn get(self: WorldTransforms, entity: ecs.Entity) ?transform.Mat4 {
                const idx = self.index.get(entity.key()) orelse return null;
                return self.matrices[idx];
            }
        };

        /// Compute world-space matrices for all live entities in a single O(n)
        /// iterative pass (parents before children). No recursion is used, so
        /// arbitrarily deep hierarchies are safe. Entities without a Transform
        /// component use the identity local transform. Requires a Transform in
        /// the schema. The caller owns the returned snapshot; call `deinit`.
        ///
        /// This is the per-frame-friendly API: compute once after transforms
        /// change, then look up many entities via `WorldTransforms.get`.
        pub fn computeWorldTransforms(self: *Self, gpa: Allocator) Error!WorldTransforms {
            if (!has_transform)
                @compileError("computeWorldTransforms requires a Transform component in the scene schema");

            const n = self.records.count();
            // Initialize with empty storage and register cleanup before any
            // fallible allocation, so a partial failure frees what was allocated.
            var wt = WorldTransforms{
                .gpa = gpa,
                .matrices = &.{},
                .entities = &.{},
                .index = std.AutoHashMap(u64, usize).init(gpa),
            };
            errdefer wt.deinit();
            wt.matrices = try gpa.alloc(transform.Mat4, n);
            wt.entities = try gpa.alloc(ecs.Entity, n);

            // Scratch space, freed before return.
            const local = try gpa.alloc(transform.Mat4, n);
            defer gpa.free(local);
            const parent_idx = try gpa.alloc(usize, n);
            defer gpa.free(parent_idx);
            const computed = try gpa.alloc(bool, n);
            defer gpa.free(computed);
            const stack = try gpa.alloc(usize, n);
            defer gpa.free(stack);
            const ids = try gpa.alloc(u64, n);
            defer gpa.free(ids);
            var id_to_idx = std.AutoHashMap(u64, usize).init(gpa);
            defer id_to_idx.deinit();

            // Deterministic dense order: ascending stable ID.
            var i: usize = 0;
            var it = self.records.iterator();
            while (it.next()) |entry| : (i += 1) ids[i] = entry.key_ptr.*;
            std.mem.sort(u64, ids, {}, struct {
                fn less(_: void, a: u64, b: u64) bool {
                    return a < b;
                }
            }.less);

            const root_sentinel = std.math.maxInt(usize);
            for (ids, 0..) |id, idx| {
                const rec = self.records.get(id).?;
                wt.entities[idx] = rec.entity;
                try wt.index.put(rec.entity.key(), idx);
                try id_to_idx.put(id, idx);
                const local_t: components_mod.Transform = if (self.world.get(components_mod.Transform, rec.entity)) |p| p.* else components_mod.Transform.identity;
                local[idx] = transform.fromTransform(local_t);
            }
            // Resolve parents in a second pass so forward references work.
            for (ids, 0..) |id, idx| {
                const rec = self.records.get(id).?;
                parent_idx[idx] = if (rec.parent) |pid| (id_to_idx.get(pid) orelse root_sentinel) else root_sentinel;
            }

            // Iterative topological evaluation: walk up to a computed ancestor
            // (or the root), then compose back down. Each entity is visited once.
            @memset(computed, false);
            for (0..n) |start| {
                if (computed[start]) continue;
                var sp: usize = 0;
                var cur = start;
                while (cur != root_sentinel and !computed[cur]) {
                    stack[sp] = cur;
                    sp += 1;
                    cur = parent_idx[cur];
                }
                var base: transform.Mat4 = if (cur == root_sentinel) transform.identity() else wt.matrices[cur];
                while (sp > 0) {
                    sp -= 1;
                    const j = stack[sp];
                    wt.matrices[j] = transform.multiply(base, local[j]);
                    base = wt.matrices[j];
                    computed[j] = true;
                }
            }
            return wt;
        }

        /// World matrix for a single entity by walking up its parent chain.
        /// Allocates a temporary chain buffer; for per-frame use over many
        /// entities prefer `computeWorldTransforms`. Requires a Transform in the
        /// schema. Returns `error.EntityNotAlive` for a dead handle.
        pub fn worldMatrix(self: *Self, gpa: Allocator, entity: ecs.Entity) Error!transform.Mat4 {
            if (!has_transform)
                @compileError("worldMatrix requires a Transform component in the scene schema");
            if (!self.alive(entity)) return error.EntityNotAlive;

            var chain: std.ArrayList(transform.Mat4) = .empty;
            defer chain.deinit(gpa);
            var cur: ?ecs.Entity = entity;
            while (cur) |e| {
                const local_t: components_mod.Transform = if (self.world.get(components_mod.Transform, e)) |p| p.* else components_mod.Transform.identity;
                try chain.append(gpa, transform.fromTransform(local_t));
                cur = self.parent(e);
            }

            var result = transform.identity();
            var i = chain.items.len;
            while (i > 0) {
                i -= 1;
                result = transform.multiply(result, chain.items[i]);
            }
            return result;
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
            // Third pass: apply explicit sibling orders.
            for (raw.entities) |re| {
                if (re.order) |o| {
                    try self.setOrder(re.id, o);
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
                const order = if (self.orderOf(id) != id) @as(?u64, self.orderOf(id)) else null;
                try entities.append(gpa, .{
                    .id = id,
                    .name = record.name,
                    .parent = record.parent,
                    .order = order,
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

test "scene: child ids are sorted, bounded and prefix-stable" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    const other = try s.createEntity("Other", null);
    // Created out of order on purpose: the answer must not depend on insertion.
    _ = try s.createEntity("c3", s.idOf(root));
    const c1 = try s.createEntity("c1", s.idOf(root));
    const c2 = try s.createEntity("c2", s.idOf(root));

    var buf: [8]u64 = @splat(0);
    const roots = s.childIdsInto(null, &buf);
    try std.testing.expectEqual(@as(usize, 2), roots);
    try std.testing.expectEqual(@as(u64, 1), buf[0]);
    try std.testing.expectEqual(@as(u64, 2), buf[1]);

    // root = 1, other = 2, then its children 3, 4, 5 in creation order.
    const kids = s.childIdsInto(s.idOf(root), &buf);
    try std.testing.expectEqual(@as(usize, 3), kids);
    try std.testing.expectEqual(@as(u64, 3), buf[0]);
    try std.testing.expectEqual(s.idOf(c1).?, buf[1]);
    try std.testing.expectEqual(s.idOf(c2).?, buf[2]);
    try std.testing.expectEqual(@as(u64, 5), buf[2]);

    // A buffer too small keeps the smallest IDs, never overflows, and reports the
    // number written rather than the number that matched.
    var small: [2]u64 = @splat(0);
    try std.testing.expectEqual(@as(usize, 2), s.childIdsInto(s.idOf(root), &small));
    try std.testing.expectEqual(@as(u64, 3), small[0]);
    try std.testing.expectEqual(s.idOf(c1).?, small[1]);

    // A leaf has no children; an unknown parent has none either.
    try std.testing.expectEqual(@as(usize, 0), s.childIdsInto(s.idOf(c1), &buf));
    try std.testing.expectEqual(@as(usize, 0), s.childIdsInto(9_999, &buf));
    try std.testing.expectEqual(@as(usize, 0), s.childIdsInto(null, small[0..0]));

    // `rootIds` agrees with the allocating path exactly.
    const owned = try s.rootIds(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqual(@as(usize, 2), owned.len);
    try std.testing.expectEqual(@as(u64, 1), owned[0]);
    try std.testing.expectEqual(@as(u64, 2), owned[1]);
    _ = other;
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

// --- world-space transforms ------------------------------------------------

test "world transforms: single entity world equals its local matrix" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const e = try s.createEntity("E", null);
    const local = Transform{ .position = .{ 1, 2, 3 }, .scale = .{ 2, 2, 2 } };
    try s.addComponent(e, local);

    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    try std.testing.expectEqual(@as(usize, 1), wt.count());
    try std.testing.expect(transform.approxEqual(wt.get(e).?, transform.fromTransform(local), 1e-5));
}

test "world transforms: child world is parent world times child local" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    try s.addComponent(root, Transform{ .position = .{ 10, 0, 0 }, .scale = .{ 2, 2, 2 } });
    const child = try s.createEntity("Child", s.idOf(root));
    try s.addComponent(child, Transform{ .position = .{ 1, 0, 0 } });

    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    // Child origin in world = root * child * (0,0,0) = (12, 0, 0).
    const p = transform.transformPoint(wt.get(child).?, .{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 12), p[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p[1], 1e-4);

    const expected = transform.multiply(transform.fromTransform(s.getComponent(Transform, root).?.*), transform.fromTransform(s.getComponent(Transform, child).?.*));
    try std.testing.expect(transform.approxEqual(wt.get(child).?, expected, 1e-4));
}

test "world transforms: entity without a Transform uses identity local" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    try s.addComponent(root, Transform{ .position = .{ 5, 5, 5 } });
    const bare = try s.createEntity("Bare", s.idOf(root)); // no Transform component

    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    // The bare entity passes through its parent's world transform unchanged.
    try std.testing.expect(transform.approxEqual(wt.get(bare).?, wt.get(root).?, 1e-5));
}

test "world transforms: deep hierarchy does not recurse or overflow" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const depth = 2000;
    var prev: ?ecs.Entity = null;
    var last: ecs.Entity = undefined;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const parent_id = if (prev) |p| s.idOf(p) else null;
        const e = try s.createEntity(null, parent_id);
        try s.addComponent(e, Transform{ .position = .{ 1, 0, 0 } });
        prev = e;
        last = e;
    }

    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    try std.testing.expectEqual(@as(usize, depth), wt.count());
    // Each level adds (1,0,0); the deepest entity sits at (depth, 0, 0).
    const p = transform.transformPoint(wt.get(last).?, .{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(depth)), p[0], 1e-2);
}

test "world transforms: forward parent references resolve (parse)" {
    const src =
        \\{ "format_version": 1, "name": "main", "entities": [
        \\  { "id": 1, "name": "Child", "parent": 2, "components": { "transform": { "position": [1, 0, 0] } } },
        \\  { "id": 2, "name": "Root", "components": { "transform": { "position": [10, 0, 0] } } }
        \\] }
    ;
    var s = try TestScene.parse(std.testing.allocator, src);
    defer s.deinit();
    const child = s.entityById(1).?;
    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    const p = transform.transformPoint(wt.get(child).?, .{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 11), p[0], 1e-4);
}

test "world transforms: worldMatrix convenience matches the batch snapshot" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    try s.addComponent(root, Transform{ .position = .{ 1, 2, 3 }, .rotation = transform.quatFromAxisAngle(.{ 0, 1, 0 }, 0.6) });
    const child = try s.createEntity("Child", s.idOf(root));
    try s.addComponent(child, Transform{ .position = .{ 4, 5, 6 }, .scale = .{ 2, 1, 3 } });
    const grand = try s.createEntity("Grand", s.idOf(child));
    try s.addComponent(grand, Transform{ .position = .{ 0, 1, 0 } });

    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    const single = try s.worldMatrix(std.testing.allocator, grand);
    try std.testing.expect(transform.approxEqual(single, wt.get(grand).?, 1e-4));
}

test "world transforms: snapshot is generation-safe across slot recycle" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity("A", null);
    try s.addComponent(a, Transform{ .position = .{ 1, 1, 1 } });
    var wt = try s.computeWorldTransforms(std.testing.allocator);
    try std.testing.expect(wt.get(a) != null);

    s.destroyEntity(a);
    const b = try s.createEntity("B", null); // recycles the slot, new generation
    // The recycled handle must not read the previous entity's frozen matrix.
    try std.testing.expect(wt.get(b) == null);
    wt.deinit();

    // A fresh snapshot reflects the current scene: a is gone, b is present.
    var wt2 = try s.computeWorldTransforms(std.testing.allocator);
    defer wt2.deinit();
    try std.testing.expect(wt2.get(a) == null);
    try std.testing.expect(wt2.get(b) != null);
}

test "world transforms: dead handle rejected by worldMatrix" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity("A", null);
    s.destroyEntity(a);
    try std.testing.expectError(error.EntityNotAlive, s.worldMatrix(std.testing.allocator, a));
}

test "world transforms: empty scene yields an empty snapshot" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    try std.testing.expectEqual(@as(usize, 0), wt.count());
}

test "world transforms: snapshot entities are sorted by stable ID" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const a = try s.createEntity("A", null);
    const b = try s.createEntity("B", null);
    const c = try s.createEntity("C", null);
    var wt = try s.computeWorldTransforms(std.testing.allocator);
    defer wt.deinit();
    try std.testing.expectEqual(s.idOf(a).?, s.idOf(wt.entities[0]).?);
    try std.testing.expectEqual(s.idOf(b).?, s.idOf(wt.entities[1]).?);
    try std.testing.expectEqual(s.idOf(c).?, s.idOf(wt.entities[2]).?);
}

fn worldTransformsAllocationProbe(allocator: Allocator) !void {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    try s.addComponent(root, Transform{ .position = .{ 1, 2, 3 } });
    const child = try s.createEntity("Child", s.idOf(root));
    try s.addComponent(child, Transform{ .position = .{ 4, 5, 6 }, .scale = .{ 2, 2, 2 } });
    var wt = try s.computeWorldTransforms(allocator);
    wt.deinit();
    _ = try s.worldMatrix(allocator, child);
}

test "world transforms: compute survives every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, worldTransformsAllocationProbe, .{});
}

test "scene: destroySet matches repeated destroyEntity exactly" {
    const gpa = std.testing.allocator;
    // A wide, deep hierarchy: root 1, chains and branches under it, plus a
    // second independent root. Every doomed-subset shape below is exercised
    // against the one-at-a-time reference implementation.
    const build = struct {
        fn make(alloc: Allocator) !TestScene {
            var s = try TestScene.init(alloc, "main");
            errdefer s.deinit();
            _ = try s.createEntity("a", null); // 1
            _ = try s.createEntity("b", 1); // 2
            _ = try s.createEntity("c", 2); // 3
            _ = try s.createEntity("d", 3); // 4
            _ = try s.createEntity("e", 4); // 5
            _ = try s.createEntity("f", 1); // 6
            _ = try s.createEntity("g", 6); // 7
            _ = try s.createEntity("h", null); // 8
            _ = try s.createEntity("i", 8); // 9
            _ = try s.createEntity("j", 2); // 10
            return s;
        }
    }.make;

    const subsets = [_][]const u64{
        &.{},
        &.{1},
        &.{2},
        &.{ 2, 3 },
        &.{ 2, 3, 4 },
        &.{ 1, 2, 3, 4, 5 },
        &.{ 1, 6, 8 },
        &.{ 3, 4 },
        &.{ 2, 4 }, // sparse, non-contiguous
        &.{ 2, 2, 2 }, // duplicates
        &.{99}, // unknown id
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    };

    for (subsets) |ids| {
        var batch = try build(gpa);
        defer batch.deinit();
        var one_by_one = try build(gpa);
        defer one_by_one.deinit();

        const removed = batch.destroySet(ids);

        var expected: usize = 0;
        for (ids) |id| {
            if (one_by_one.entityById(id)) |e| {
                one_by_one.destroyEntity(e);
                expected += 1;
            }
        }
        try std.testing.expectEqual(expected, removed);
        try std.testing.expectEqual(one_by_one.count(), batch.count());

        // Byte-identical documents prove names, components, IDs and the whole
        // reparenting result agree, not just the entity count.
        const a = try batch.serialize(gpa);
        defer gpa.free(a);
        const b = try one_by_one.serialize(gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, b, a);
    }
}

test "scene: destroySet reparents survivors to the nearest surviving ancestor" {
    const gpa = std.testing.allocator;
    var s = try TestScene.init(gpa, "main");
    defer s.deinit();
    _ = try s.createEntity("root", null); // 1 survives
    _ = try s.createEntity("gone1", 1); // 2
    _ = try s.createEntity("gone2", 2); // 3
    _ = try s.createEntity("gone3", 3); // 4
    const keep = try s.createEntity("keep", 4); // 5 survives, deep under doomed chain
    const orphan = try s.createEntity("orphan", 3); // 6 survives under a doomed root-less chain

    try std.testing.expectEqual(@as(usize, 3), s.destroySet(&.{ 2, 3, 4 }));
    // `keep` climbs past 4, 3 and 2 to the surviving root 1.
    try std.testing.expectEqual(@as(?u64, 1), s.records.get(5).?.parent);
    try std.testing.expect(s.world.alive(keep));
    // `orphan` had no surviving ancestor above 3, so it also lands on 1.
    try std.testing.expectEqual(@as(?u64, 1), s.records.get(6).?.parent);
    try std.testing.expect(s.world.alive(orphan));

    // Removing the last ancestor turns survivors into roots.
    try std.testing.expectEqual(@as(usize, 1), s.destroySet(&.{1}));
    try std.testing.expectEqual(@as(?u64, null), s.records.get(5).?.parent);
    try std.testing.expectEqual(@as(?u64, null), s.records.get(6).?.parent);
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "scene: destroySet on a deep doomed chain stays linear and does not recurse" {
    const gpa = std.testing.allocator;
    var s = try TestScene.init(gpa, "main");
    defer s.deinit();
    // 20k-deep chain: recursion would overflow the stack, and a per-child
    // ancestor walk without memoization would be quadratic.
    const depth = 20_000;
    var parent: ?u64 = null;
    var ids = try gpa.alloc(u64, depth);
    defer gpa.free(ids);
    for (0..depth) |i| {
        const e = try s.createEntity(null, parent);
        ids[i] = s.idOf(e).?;
        parent = ids[i];
    }
    const leaf = try s.createEntity("leaf", parent);
    const leaf_id = s.idOf(leaf).?;

    try std.testing.expectEqual(@as(usize, depth), s.destroySet(ids));
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expect(s.world.alive(leaf));
    try std.testing.expectEqual(@as(?u64, null), s.records.get(leaf_id).?.parent);
}

test "scene: destroySet ignores unknown and stale IDs" {
    const gpa = std.testing.allocator;
    var s = try TestScene.init(gpa, "main");
    defer s.deinit();
    const e = try s.createEntity("gone", null);
    const id = s.idOf(e).?;
    s.destroyEntity(e);
    try std.testing.expectEqual(@as(usize, 0), s.destroySet(&.{ 0, id, 12345 }));
    try std.testing.expectEqual(@as(usize, 0), s.destroySet(&.{}));
}

test "scene: destroySet performs no allocation at all" {
    // The no-allocation guarantee is what makes destroySet usable on teardown
    // and rollback paths, so assert it directly rather than only probing OOM.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var s = try TestScene.init(alloc, "main");
    defer s.deinit();
    var parent: ?u64 = null;
    for (0..2000) |_| {
        const e = try s.createEntity(null, parent);
        parent = s.idOf(e).?;
    }
    const survivor = try s.createEntity("survivor", parent);
    // Build the doomed ID list before measuring, so only destroySet is timed.
    const ids = try std.testing.allocator.alloc(u64, 2000);
    defer std.testing.allocator.free(ids);
    for (ids, 0..) |*id, i| id.* = @intCast(i + 1);

    const before = failing.alloc_index;
    // A deep doomed chain with a surviving leaf: the worst case for ancestor
    // resolution, and it must still not ask the allocator for anything.
    try std.testing.expectEqual(@as(usize, 2000), s.destroySet(ids));
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expect(s.world.alive(survivor));
}

test "scene: parentIdOf answers without resolving the parent entity" {
    var s = try TestScene.init(std.testing.allocator, "main");
    defer s.deinit();
    const root = try s.createEntity("Root", null);
    const child = try s.createEntity("Child", s.idOf(root));
    const root_id = s.idOf(root).?;
    const child_id = s.idOf(child).?;

    try std.testing.expect(s.parentIdOf(root_id) == null);
    try std.testing.expectEqual(root_id, s.parentIdOf(child_id).?);
    // An unknown ID is not an error: the caller is a per-frame scan, not a query.
    try std.testing.expect(s.parentIdOf(999) == null);
}
