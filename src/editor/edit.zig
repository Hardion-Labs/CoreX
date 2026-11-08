//! The editing model: reversible operations over a scene, and dirty tracking.
//!
//! The editor shell can *show* a scene; this is the layer that lets it be *changed*
//! without losing work. Two ideas carry it:
//!
//! * **A command is a description, not a closure.** Each edit is a `Command` value
//!   naming an entity and the data it needs (a component value, a name, a parent). The
//!   stack is therefore a list of plain values — inspectable, comparable in tests and
//!   (later) saveable — with no captured pointers and no allocator hidden inside an
//!   operation.
//! * **The stack owns its memory, the scene owns its data.** Applying allocates the
//!   entry; undo and redo allocate nothing at all, which is what makes an undo bound to
//!   a key press safe to call from inside a frame.
//!
//! * **The gesture is the undo unit, not the command.** `applyBatch` records several
//!   commands as one step, so what the user did in one motion is what one `Ctrl+Z` backs
//!   out of — and `undoDepth` counts those steps, because that is the number of presses
//!   left. A command stays the unit of *meaning*: each one still carries its own
//!   snapshot, which is why a group needs no inverse formula of its own.
//!
//! Undo is exact, not reconstructed. Before every edit the history captures the
//! entity's **full prior state** (name, parent, every schema component), and undo puts
//! that state back. That is one rule for all seven commands instead of seven subtly
//! different inverse formulas — and it is what makes the hard cases right: undoing a
//! delete restores the entity's **original stable ID** (so the editor's selection
//! survives), its parent and all its components; undoing a create removes exactly what
//! the create produced.
//!
//! Nothing here imports the GUI or the renderer: the model serves the editor shell, a
//! test or a future console equally.

const std = @import("std");
const components = @import("../scene/components.zig");
const validation = @import("../core/validation.zig");
const paths = @import("../core/paths.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The command or its inverse names an entity the scene no longer has.
    EntityNotFound,
    /// The scene refused the change (invalid name, parent cycle, duplicate ID, ...).
    Rejected,
    OutOfMemory,
};

/// Length limit of a stored name, matching the scene's display-name rule.
pub const max_name_bytes = 128;

/// Identity of an entity in an edit. Stable IDs are the scene's own, not the
/// generational ECS handle: a handle is recycled, an ID never is, so a command recorded
/// last frame still names the right entity after a delete/create cycle.
pub const EntityId = u64;

/// A name owned by the command itself, so a command outlives the buffer it was built
/// from (a text field's contents, a caller's stack array).
pub const Name = struct {
    bytes: [max_name_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) ?Name {
        if (text.len > max_name_bytes) return null;
        var n = Name{};
        @memcpy(n.bytes[0..text.len], text);
        n.len = @intCast(text.len);
        return n;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A union with one arm per component type of a scene schema, named by index.
///
/// The schema is the single source of truth: adding a component to a scene adds an arm
/// here with no edits, so a command carries that component's value with its **real
/// type** instead of a byte blob, and reading it back needs no cast.
pub fn ValueUnion(comptime types: anytype) type {
    const n = types.len;
    comptime {
        if (n == 0) @compileError("a scene schema needs at least one component");
    }
    const names = comptime blk: {
        var out: [n][:0]const u8 = undefined;
        for (0..n) |i| out[i] = std.fmt.comptimePrint("{d}", .{i});
        break :blk out;
    };
    const Tag = @Enum(usize, .exhaustive, &names, &std.simd.iota(usize, n));
    var field_types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.Union.FieldAttributes = undefined;
    for (types, 0..) |T, i| {
        field_types[i] = T;
        attrs[i] = .{};
    }
    return @Union(.auto, Tag, &names, &field_types, &attrs);
}

/// One reversible edit. `apply` runs the arm; undo restores the captured prior state.
pub fn Command(comptime Scene: type) type {
    return union(enum) {
        /// Put `value` on the entity, replacing whatever component of that type was
        /// there (or adding it).
        set_component: struct {
            id: EntityId,
            value: History(Scene).ComponentValue,
        },
        /// Remove the schema component at `index` (its position in `component_types`).
        remove_component: struct {
            id: EntityId,
            index: u8,
        },
        rename: struct {
            id: EntityId,
            /// `null` removes the name.
            name: ?Name,
        },
        reparent: struct {
            id: EntityId,
            /// `null` makes it a root.
            parent: ?EntityId,
        },
        /// Create a bare entity with a caller-chosen stable ID.
        create: struct {
            id: EntityId,
            name: ?Name = null,
            parent: ?EntityId = null,
        },
        /// Destroy an entity; undo restores it with its ID, name, parent and components.
        delete: struct {
            id: EntityId,
        },
        /// Change an entity's sibling order. `order` is the new sort key among
        /// siblings of the same parent; the entity's own ID means "natural order".
        set_order: struct {
            id: EntityId,
            order: u64,
        },
    };
}

/// The undo/redo stack for one scene schema.
pub fn History(comptime Scene: type) type {
    return struct {
        const Self = @This();

        pub const ComponentValue = ValueUnion(Scene.component_types);

        /// Everything an entity carries, captured before an edit changes it.
        pub const Snapshot = struct {
            /// False when the entity did not exist before the edit (a create).
            existed: bool = false,
            name: ?Name = null,
            parent: ?EntityId = null,
            /// Sibling order before the edit; restored by undo/redo.
            order: u64 = 0,
            /// One arm per schema component; `null` for a component that was absent.
            components: [Scene.component_count]?ComponentValue = @splat(null),
        };

        /// A command plus the state that preceded it.
        pub const Entry = struct {
            command: Command(Scene),
            before: Snapshot = .{},
            /// How many entries this gesture spans: `1` for a single command. A group is
            /// stored as a count on its own entries rather than as a second list of
            /// boundaries, because a second list is one more thing that can disagree with
            /// `entries` — and because it keeps `Entry` plain data, so `truncateRedo`
            /// cannot leak and `undo` cannot allocate.
            group_len: u32 = 1,
        };

        /// How many commands one gesture may span. The bound exists only so `group_len`
        /// fits the field above; no gesture the editor can produce comes near it.
        pub const max_batch = std.math.maxInt(u32);

        gpa: Allocator,
        /// Entries oldest-first; `entries.len` can exceed `cursor` (the redo tail).
        entries: std.ArrayList(Entry) = .empty,
        /// Number of applied entries.
        cursor: usize = 0,
        /// The scene has been changed since the last `markSaved`.
        dirty: bool = false,
        /// Edits applied over the history's lifetime, for a status bar counter.
        applied_total: usize = 0,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn canUndo(self: Self) bool {
            return self.cursor > 0;
        }

        pub fn canRedo(self: Self) bool {
            return self.cursor < self.entries.items.len;
        }

        /// How many `undo` presses are available — **gestures**, which is what a press steps
        /// back over, not the commands a gesture happened to need. Walking the group
        /// boundaries is exact without a second counter to keep in sync, and the walk is
        /// bounded by the history the user can accumulate. The shell asks `canUndo` /
        /// `canRedo` when a shortcut fires; nothing calls these depths per frame.
        pub fn undoDepth(self: Self) usize {
            var i = self.cursor;
            var steps: usize = 0;
            while (i > 0) : (steps += 1) {
                i -= self.entries.items[i - 1].group_len;
            }
            return steps;
        }

        /// How many `redo` presses are available, in gestures. See `undoDepth`.
        pub fn redoDepth(self: Self) usize {
            var i = self.cursor;
            var steps: usize = 0;
            while (i < self.entries.items.len) : (steps += 1) {
                i += self.entries.items[i].group_len;
            }
            return steps;
        }

        /// Drop the redo tail: after an undo, a new edit makes the undone future
        /// unreachable, so it must not reappear (or keep memory alive).
        pub fn truncateRedo(self: *Self) void {
            if (self.cursor < self.entries.items.len) {
                self.entries.shrinkRetainingCapacity(self.cursor);
            }
        }

        /// Apply `command` to `scene` and record it. The one-command case of `applyBatch`,
        /// so a single edit and a multi-command gesture cannot drift apart in what they
        /// guarantee.
        pub fn apply(self: *Self, scene: anytype, command: Command(Scene)) Error!void {
            try self.applyBatch(scene, &.{command});
        }

        /// Apply `commands` to `scene` as **one** undo step.
        ///
        /// A gesture that needs more than one command — swapping two siblings' order keys
        /// is the case the hierarchy has — is one thing the user did, so it has to be one
        /// thing they undo. Recording such a pair as two entries leaves a `Ctrl+Z` press
        /// stopping in the middle of it, and the state it stops in is one the user never
        /// had.
        ///
        /// Failure leaves the scene and the history as they were, for the group as a whole
        /// as well as for each command in it: a snapshot is captured before each mutation,
        /// every arm validates first, and a command that fails — an allocation, or a value
        /// the scene rejects — rolls the commands already applied back over their snapshots
        /// and records nothing.
        pub fn applyBatch(self: *Self, scene: anytype, commands: []const Command(Scene)) Error!void {
            if (commands.len == 0) return;
            if (commands.len > max_batch) return error.Rejected;
            self.truncateRedo();
            try self.entries.ensureUnusedCapacity(self.gpa, commands.len);

            const first = self.entries.items.len;
            for (commands, 0..) |command, i| {
                const id = commandEntityId(command);
                var before: Snapshot = .{};
                if (scene.entityById(id)) |entity| {
                    before = capture(scene, entity) catch |err| {
                        self.rollbackGroup(scene, first, i);
                        return err;
                    };
                }

                self.forward(scene, command) catch |err| {
                    // This command was not appended, so `i` is exactly how many applied
                    // edits stand between the scene and the state it had on entry.
                    self.rollbackGroup(scene, first, i);
                    return err;
                };

                self.entries.appendAssumeCapacity(.{
                    .command = command,
                    .before = before,
                    .group_len = @intCast(commands.len),
                });
            }

            // `cursor` lands on a group boundary and only ever moves by whole groups, which
            // is what lets `undo`/`redo` find a gesture's extent from the entry beside them.
            self.cursor = self.entries.items.len;
            self.applied_total += 1;
            self.dirty = true;
        }

        /// Undo `applied` entries appended from `first`, newest first — the reverse of the
        /// order they ran in, so a rolled-back gesture lands each entity in the state it
        /// had before the gesture rather than between two of its commands.
        fn rollbackGroup(self: *Self, scene: anytype, first: usize, applied: usize) void {
            var i = first + applied;
            while (i > first) {
                i -= 1;
                const entry = self.entries.items[i];
                restore(scene, commandEntityId(entry.command), entry.before) catch {};
            }
            self.entries.shrinkRetainingCapacity(first);
        }

        fn forward(self: *Self, scene: anytype, command: Command(Scene)) Error!void {
            _ = self;
            switch (command) {
                .set_component => |c| {
                    const entity = try entityOf(scene, c.id);
                    try setValue(scene, entity, c.value);
                },
                .remove_component => |c| {
                    const entity = try entityOf(scene, c.id);
                    if (!removeByIndex(scene, entity, c.index)) return error.Rejected;
                },
                .rename => |c| {
                    const entity = try entityOf(scene, c.id);
                    try renameEntity(scene, entity, if (c.name) |n| n.slice() else null);
                },
                .reparent => |c| {
                    const entity = try entityOf(scene, c.id);
                    try reparentEntity(scene, entity, c.parent);
                },
                .create => |c| {
                    if (c.id == 0) return error.Rejected;
                    if (scene.entityById(c.id) != null) return error.Rejected;
                    const parent = if (c.parent) |pid| try entityOf(scene, pid) else null;
                    _ = scene.createEntityWithExactId(
                        c.id,
                        if (c.name) |n| n.slice() else null,
                        if (parent) |p| scene.idOf(p) else null,
                    ) catch return error.Rejected;
                },
                .delete => |c| {
                    const entity = try entityOf(scene, c.id);
                    scene.destroyEntity(entity);
                },
                .set_order => |c| {
                    scene.setOrder(c.id, c.order) catch |err| switch (err) {
                        error.EntityNotFound => return error.EntityNotFound,
                        else => return error.Rejected,
                    };
                },
            }
        }

        /// Undo the most recent applied **gesture** by restoring the state captured before
        /// each of its commands, in the reverse of the order they ran. Allocates nothing.
        pub fn undo(self: *Self, scene: anytype) Error!void {
            if (!self.canUndo()) return;
            const end = self.cursor;
            const begin = end - self.entries.items[end - 1].group_len;
            var i = end;
            while (i > begin) {
                i -= 1;
                const entry = self.entries.items[i];
                try restore(scene, commandEntityId(entry.command), entry.before);
            }
            self.cursor = begin;
            self.dirty = true;
        }

        /// Re-apply the most recent undone gesture. The snapshots are **kept** from the
        /// first application: the state before a redone delete is the same state as before
        /// the original, so undo after redo restores it again.
        pub fn redo(self: *Self, scene: anytype) Error!void {
            if (!self.canRedo()) return;
            const begin = self.cursor;
            const end = begin + self.entries.items[begin].group_len;
            var i = begin;
            while (i < end) : (i += 1) {
                try self.forward(scene, self.entries.items[i].command);
            }
            self.cursor = end;
            self.dirty = true;
        }

        /// Capture the entity's full state, or mark that it does not exist yet.
        fn capture(scene: anytype, entity: anytype) Error!Snapshot {
            var snap = Snapshot{ .existed = true };
            if (scene.nameOf(entity)) |n| snap.name = Name.init(n) orelse return error.Rejected;
            if (scene.parent(entity)) |p| snap.parent = scene.idOf(p);
            const id = scene.idOf(entity) orelse return error.EntityNotFound;
            snap.order = scene.orderOf(id);
            inline for (Scene.component_types, 0..) |T, i| {
                if (scene.getComponent(T, entity)) |value| {
                    snap.components[i] = @unionInit(ComponentValue, fieldName(i), value.*);
                }
            }
            return snap;
        }

        /// Bring the entity back to `snap`: absent then and absent now is a no-op, absent
        /// then and present now is a destroy, present now is a value-for-value rewrite.
        fn restore(scene: anytype, id: EntityId, snap: Snapshot) Error!void {
            const existing = scene.entityById(id);
            if (!snap.existed) {
                if (existing) |entity| scene.destroyEntity(entity);
                return;
            }

            const entity = existing orelse blk: {
                // Restoring a delete: recreate with the same ID and parent so every
                // reference the editor holds (a selection, an older command) still
                // resolves.
                const parent = if (snap.parent) |pid| try entityOf(scene, pid) else null;
                break :blk scene.createEntityWithExactId(
                    id,
                    if (snap.name) |n| n.slice() else null,
                    if (parent) |p| scene.idOf(p) else null,
                ) catch return error.Rejected;
            };

            // Name and parent are attributes; components are a per-slot comparison so a
            // component added by the undone edit is removed again.
            const current_name = scene.nameOf(entity);
            const want_name = if (snap.name) |n| n.slice() else null;
            const name_matches = if (current_name) |cur| (want_name != null and std.mem.eql(u8, cur, want_name.?)) else want_name == null;
            if (!name_matches) try renameEntity(scene, entity, want_name);

            const current_parent = if (scene.parent(entity)) |p| scene.idOf(p) else null;
            if (!optIdEql(current_parent, snap.parent)) try reparentEntity(scene, entity, snap.parent);

            if (scene.orderOf(id) != snap.order) {
                scene.setOrder(id, snap.order) catch |err| switch (err) {
                    error.EntityNotFound => return error.EntityNotFound,
                    else => return error.Rejected,
                };
            }

            inline for (Scene.component_types, 0..) |T, i| {
                const want = snap.components[i];
                const has = scene.hasComponent(T, entity);
                if (want) |value| {
                    switch (value) {
                        inline else => |payload| {
                            if (@TypeOf(payload) == T) {
                                if (!has or !componentEql(T, scene.getComponent(T, entity).?.*, payload)) {
                                    try setValue(scene, entity, value);
                                }
                            }
                        },
                    }
                } else if (has) {
                    scene.removeComponent(T, entity);
                }
            }
        }

        /// Mark the scene as saved without touching the stacks: saving does not cost the
        /// user their undo history.
        pub fn markSaved(self: *Self) void {
            self.dirty = false;
        }

        fn fieldName(comptime i: usize) []const u8 {
            return std.fmt.comptimePrint("{d}", .{i});
        }

        fn commandEntityId(command: Command(Scene)) EntityId {
            return switch (command) {
                inline else => |c| c.id,
            };
        }

        fn optIdEql(a: ?EntityId, b: ?EntityId) bool {
            if (a) |x| return b != null and b.? == x;
            return b == null;
        }

        fn entityOf(scene: anytype, id: EntityId) Error!@TypeOf(scene.entityById(0).?) {
            return scene.entityById(id) orelse error.EntityNotFound;
        }

        fn renameEntity(scene: anytype, entity: anytype, name: ?[]const u8) Error!void {
            if (name) |n| validation.validateDisplayName(n) catch return error.Rejected;
            scene.setName(entity, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Rejected,
            };
        }

        fn reparentEntity(scene: anytype, entity: anytype, parent_id: ?EntityId) Error!void {
            const parent = if (parent_id) |pid| try entityOf(scene, pid) else null;
            scene.setParent(entity, parent) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Rejected,
            };
        }

        fn setValue(scene: anytype, entity: anytype, value: ComponentValue) Error!void {
            switch (value) {
                inline else => |payload| scene.addComponent(entity, payload) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Rejected,
                },
            }
        }

        /// Remove the schema component at `index`; returns whether one was present.
        fn removeByIndex(scene: anytype, entity: anytype, index: u8) bool {
            inline for (Scene.component_types, 0..) |T, i| {
                if (index == i) {
                    if (!scene.hasComponent(T, entity)) return false;
                    scene.removeComponent(T, entity);
                    return true;
                }
            }
            return false;
        }
    };
}

/// Position of component type `T` in a schema's declaration order.
///
/// A caller with a typed value (an inspector field writing a `Transform`) should not
/// have to know that position: it is a schema implementation detail that would silently
/// break when a component is added before it. Failing at **comptime** means a scene
/// schema without the component is a compile error, not a runtime no-op.
pub fn componentIndexOf(comptime types: anytype, comptime T: type) usize {
    inline for (types, 0..) |C, i| {
        if (C == T) return i;
    }
    @compileError("component " ++ @typeName(T) ++ " is not part of this scene schema");
}

/// Wrap a typed component value in the history's `ComponentValue` for `Scene`, choosing
/// the union arm from the value's own type. This is what lets the shell commit a
/// `Transform` without naming its schema index.
pub fn valueFor(comptime Scene: type, comptime T: type, value: T) ValueUnion(Scene.component_types) {
    const index = comptime componentIndexOf(Scene.component_types, T);
    return @unionInit(ValueUnion(Scene.component_types), std.fmt.comptimePrint("{d}", .{index}), value);
}

/// Structural equality for one component value. Components are plain data by contract,
/// so a field-by-field comparison is exact and needs no serialization round-trip.
pub fn componentEql(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);
    if (info == .array) {
        // Vector types (`[3]f32` for a position) have no `==`; compare per element so
        // a component with any array field is still compared structurally.
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!componentEql(info.array.child, x, y)) return false;
        return true;
    }
    if (info != .@"struct") return a == b;
    // Zig 0.17 describes a struct by parallel name/type slices rather than a `fields`
    // list, so iterate that form.
    inline for (info.@"struct".field_names, info.@"struct".field_types) |name, FT| {
        if (!componentEql(FT, @field(a, name), @field(b, name))) return false;
    }
    return true;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const scene_mod = @import("../scene/scene.zig");
const Transform = components.Transform;
const Extra = struct { amount: i32 = 0 };

const TestScene = scene_mod.Scene(.{
    scene_mod.Component(Transform, "transform"),
    scene_mod.Component(Extra, "extra"),
});

const TestHistory = History(TestScene);

fn testHarness() struct { scene: TestScene, history: TestHistory } {
    return .{
        .scene = TestScene.init(testing.allocator, "level") catch unreachable,
        .history = TestHistory.init(testing.allocator),
    };
}

test "value union: one typed arm per schema component" {
    const U = ValueUnion(.{ Transform, Extra });
    const v: U = .{ .@"0" = Transform{ .position = .{ 1, 2, 3 } } };
    try testing.expectEqualStrings("0", @tagName(v));
    switch (v) {
        .@"0" => |t| try testing.expectEqual(@as(f32, 1), t.position[0]),
        else => return error.Rejected,
    }
    // The arms carry the real types, so reading a value back needs no cast.
    const e: U = .{ .@"1" = Extra{ .amount = 7 } };
    switch (e) {
        .@"1" => |x| try testing.expectEqual(@as(i32, 7), x.amount),
        else => return error.Rejected,
    }
    try testing.expectEqual(TestScene.component_count, @typeInfo(U).@"union".field_names.len);
}

test "edit: set_component applies, undoes and redoes exactly" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();

    const entity = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(entity).?;
    try h.scene.addComponent(entity, Transform{ .position = .{ 1, 0, 0 } });
    const original = Transform{ .position = .{ 1, 0, 0 } };

    try h.history.apply(&h.scene, .{ .set_component = .{
        .id = id,
        .value = .{ .@"0" = Transform{ .position = .{ 9, 0, 0 } } },
    } });
    try testing.expectEqual(@as(f32, 9), h.scene.getComponent(Transform, entity).?.position[0]);
    try testing.expect(h.history.dirty);
    try testing.expectEqual(@as(usize, 1), h.history.undoDepth());

    try h.history.undo(&h.scene);
    try testing.expect(componentEql(Transform, original, h.scene.getComponent(Transform, entity).?.*));
    try testing.expectEqual(@as(usize, 1), h.history.redoDepth());

    try h.history.redo(&h.scene);
    try testing.expectEqual(@as(f32, 9), h.scene.getComponent(Transform, entity).?.position[0]);
    // Undo must still work after a redo, with the same "before" state.
    try h.history.undo(&h.scene);
    try testing.expect(componentEql(Transform, original, h.scene.getComponent(Transform, entity).?.*));
}

test "edit: undoing a set_component that added a component removes it again" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const entity = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(entity).?;
    try testing.expect(!h.scene.hasComponent(Extra, entity));

    try h.history.apply(&h.scene, .{ .set_component = .{ .id = id, .value = .{ .@"1" = Extra{ .amount = 5 } } } });
    try testing.expect(h.scene.hasComponent(Extra, entity));

    try h.history.undo(&h.scene);
    try testing.expect(!h.scene.hasComponent(Extra, entity));
    try h.history.redo(&h.scene);
    try testing.expectEqual(@as(i32, 5), h.scene.getComponent(Extra, entity).?.amount);
}

test "edit: remove_component is reversible and refuses an absent component" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const entity = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(entity).?;
    try h.scene.addComponent(entity, Extra{ .amount = 42 });

    try h.history.apply(&h.scene, .{ .remove_component = .{ .id = id, .index = 1 } });
    try testing.expect(!h.scene.hasComponent(Extra, entity));
    try h.history.undo(&h.scene);
    try testing.expectEqual(@as(i32, 42), h.scene.getComponent(Extra, entity).?.amount);

    // Removing a component the entity does not have is rejected, and nothing is
    // recorded. (Transform is the one component this scene store never gave it.)
    const depth = h.history.undoDepth();
    try testing.expectError(error.Rejected, h.history.apply(&h.scene, .{ .remove_component = .{ .id = id, .index = 0 } }));
    try testing.expectEqual(depth, h.history.undoDepth());
}

test "edit: rename and reparent survive undo/redo and keep the tree valid" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const root = try h.scene.createEntity("root", null);
    const child = try h.scene.createEntity("child", h.scene.idOf(root));
    const root_id = h.scene.idOf(root).?;
    const child_id = h.scene.idOf(child).?;

    try h.history.apply(&h.scene, .{ .rename = .{ .id = child_id, .name = Name.init("renamed").? } });
    try testing.expectEqualStrings("renamed", h.scene.nameOf(child).?);
    try h.history.undo(&h.scene);
    try testing.expectEqualStrings("child", h.scene.nameOf(child).?);
    try h.history.redo(&h.scene);
    try testing.expectEqualStrings("renamed", h.scene.nameOf(child).?);

    // Reparent to a root, then undo back to the original parent.
    try h.history.apply(&h.scene, .{ .reparent = .{ .id = child_id, .parent = null } });
    try testing.expect(h.scene.parent(child) == null);
    try h.history.undo(&h.scene);
    try testing.expectEqual(root_id, h.scene.idOf(h.scene.parent(child).?).?);

    // A reparent that would create a cycle is rejected, records nothing, and leaves
    // the tree exactly as it was.
    const depth = h.history.undoDepth();
    try testing.expectError(error.Rejected, h.history.apply(&h.scene, .{ .reparent = .{ .id = root_id, .parent = child_id } }));
    try testing.expect(h.scene.parent(root) == null);
    try testing.expectEqual(depth, h.history.undoDepth());
}

test "edit: an invalid rename is rejected and the scene keeps its name" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const e = try h.scene.createEntity("keep", null);
    const id = h.scene.idOf(e).?;
    try testing.expectError(error.Rejected, h.history.apply(&h.scene, .{ .rename = .{ .id = id, .name = Name.init("a/b").? } }));
    try testing.expectEqualStrings("keep", h.scene.nameOf(e).?);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "edit: undoing a delete restores the same stable ID, parent and components" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const root = try h.scene.createEntity("root", null);
    const id_root = h.scene.idOf(root).?;
    const doomed = try h.scene.createEntity("doomed", id_root);
    const id = h.scene.idOf(doomed).?;
    try h.scene.addComponent(doomed, Transform{ .position = .{ 4, 5, 6 } });
    try h.scene.addComponent(doomed, Extra{ .amount = 11 });

    try h.history.apply(&h.scene, .{ .delete = .{ .id = id } });
    try testing.expect(h.scene.entityById(id) == null);

    try h.history.undo(&h.scene);
    const restored = h.scene.entityById(id).?;
    // The ID is the same, so a selection or an older command still resolves.
    try testing.expectEqual(id, h.scene.idOf(restored).?);
    try testing.expectEqualStrings("doomed", h.scene.nameOf(restored).?);
    try testing.expectEqual(id_root, h.scene.idOf(h.scene.parent(restored).?).?);
    try testing.expectEqual(@as(f32, 6), h.scene.getComponent(Transform, restored).?.position[2]);
    try testing.expectEqual(@as(i32, 11), h.scene.getComponent(Extra, restored).?.amount);

    // Redo deletes it again, and a second undo restores it again.
    try h.history.redo(&h.scene);
    try testing.expect(h.scene.entityById(id) == null);
    try h.history.undo(&h.scene);
    try testing.expect(h.scene.entityById(id) != null);
}

test "edit: undoing a create removes exactly what the create produced" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    try h.history.apply(&h.scene, .{ .create = .{ .id = 7, .name = Name.init("fresh").? } });
    const created = h.scene.entityById(7).?;
    try h.scene.addComponent(created, Extra{ .amount = 3 });
    try h.history.undo(&h.scene);
    try testing.expect(h.scene.entityById(7) == null);
    // Redo brings back the bare created entity: the command describes a create, and the
    // component added afterwards was its own (now discarded) edit.
    try h.history.redo(&h.scene);
    const again = h.scene.entityById(7).?;
    try testing.expectEqualStrings("fresh", h.scene.nameOf(again).?);
    try testing.expect(!h.scene.hasComponent(Extra, again));
}

test "edit: a create with an ID already in use is rejected" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const e = try h.scene.createEntity("taken", null);
    const id = h.scene.idOf(e).?;
    try testing.expectError(error.Rejected, h.history.apply(&h.scene, .{ .create = .{ .id = id } }));
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
}

test "edit: a command naming a missing entity fails without recording anything" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    try testing.expectError(error.EntityNotFound, h.history.apply(&h.scene, .{ .delete = .{ .id = 999 } }));
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "edit: a new edit after undo discards the redo tail" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const e = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(e).?;
    try h.scene.addComponent(e, Extra{ .amount = 1 });

    try h.history.apply(&h.scene, .{ .set_component = .{ .id = id, .value = .{ .@"1" = Extra{ .amount = 2 } } } });
    try h.history.apply(&h.scene, .{ .set_component = .{ .id = id, .value = .{ .@"1" = Extra{ .amount = 3 } } } });
    try h.history.undo(&h.scene);
    try testing.expectEqual(@as(usize, 1), h.history.redoDepth());

    try h.history.apply(&h.scene, .{ .set_component = .{ .id = id, .value = .{ .@"1" = Extra{ .amount = 9 } } } });
    try testing.expectEqual(@as(usize, 0), h.history.redoDepth());
    try testing.expectEqual(@as(usize, 2), h.history.undoDepth());
    // The tail is gone, so the value it described can never come back.
    h.history.truncateRedo();
    try h.history.undo(&h.scene);
    try h.history.undo(&h.scene);
    try testing.expectEqual(@as(i32, 1), h.scene.getComponent(Extra, entityOfOrPanic(&h, id)).?.amount);
}

test "edit: applyBatch is one undo step, and one step covers the whole gesture" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const a = try h.scene.createEntity("a", null);
    const b = try h.scene.createEntity("b", null);
    const a_id = h.scene.idOf(a).?;
    const b_id = h.scene.idOf(b).?;

    try h.history.applyBatch(&h.scene, &.{
        .{ .rename = .{ .id = a_id, .name = Name.init("first").? } },
        .{ .rename = .{ .id = b_id, .name = Name.init("second").? } },
    });
    try testing.expectEqualStrings("first", h.scene.nameOf(h.scene.entityById(a_id).?).?);
    try testing.expectEqualStrings("second", h.scene.nameOf(h.scene.entityById(b_id).?).?);
    // Two commands, one gesture: this is the number of `Ctrl+Z` presses left, and it is one.
    try testing.expectEqual(@as(usize, 1), h.history.undoDepth());
    try testing.expectEqual(@as(usize, 2), h.history.entries.items.len);

    try h.history.undo(&h.scene);
    try testing.expectEqualStrings("a", h.scene.nameOf(h.scene.entityById(a_id).?).?);
    try testing.expectEqualStrings("b", h.scene.nameOf(h.scene.entityById(b_id).?).?);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expectEqual(@as(usize, 1), h.history.redoDepth());

    // Redo re-applies both, in the order they were given.
    try h.history.redo(&h.scene);
    try testing.expectEqualStrings("first", h.scene.nameOf(h.scene.entityById(a_id).?).?);
    try testing.expectEqualStrings("second", h.scene.nameOf(h.scene.entityById(b_id).?).?);
    try testing.expectEqual(@as(usize, 1), h.history.undoDepth());
    try testing.expectEqual(@as(usize, 0), h.history.redoDepth());
}

test "edit: a failing command rolls the whole gesture back and records nothing" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const a = try h.scene.createEntity("a", null);
    const a_id = h.scene.idOf(a).?;

    // The second command names an entity the scene does not have. Applied as two `apply`
    // calls this would have left the first rename standing; as a gesture it must not.
    try testing.expectError(
        error.EntityNotFound,
        h.history.applyBatch(&h.scene, &.{
            .{ .rename = .{ .id = a_id, .name = Name.init("renamed").? } },
            .{ .rename = .{ .id = 9999, .name = Name.init("nobody").? } },
        }),
    );
    try testing.expectEqualStrings("a", h.scene.nameOf(h.scene.entityById(a_id).?).?);
    try testing.expect(!h.history.canUndo());
    try testing.expectEqual(@as(usize, 0), h.history.entries.items.len);
    // Nothing was recorded, so nothing is owed to the user as an unsaved change either.
    try testing.expect(!h.history.dirty);
}

test "edit: an empty gesture is not an edit" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    try h.history.applyBatch(&h.scene, &.{});
    try testing.expect(!h.history.canUndo());
    try testing.expect(!h.history.dirty);
    try testing.expectEqual(@as(usize, 0), h.history.entries.items.len);
}

test "edit: a gesture stays whole across a truncation and costs nothing to undo" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const a = try h.scene.createEntity("a", null);
    const b = try h.scene.createEntity("b", null);
    const a_id = h.scene.idOf(a).?;
    const b_id = h.scene.idOf(b).?;

    try h.history.apply(&h.scene, .{ .rename = .{ .id = a_id, .name = Name.init("one").? } });
    try h.history.applyBatch(&h.scene, &.{
        .{ .rename = .{ .id = b_id, .name = Name.init("two").? } },
        .{ .set_order = .{ .id = b_id, .order = 1 } },
    });
    // One command and one gesture: two presses, three entries.
    try testing.expectEqual(@as(usize, 2), h.history.undoDepth());
    try h.history.undo(&h.scene);
    try testing.expectEqualStrings("b", h.scene.nameOf(h.scene.entityById(b_id).?).?);
    try testing.expectEqual(b_id, h.scene.orderOf(b_id));

    // A new edit after the undo must drop the *whole* redo tail, including both entries of
    // the discarded gesture, or the tail would reappear as a half gesture.
    var counting = CountingAllocator{ .child = testing.allocator };
    h.history.gpa = counting.allocator();
    try h.history.applyBatch(&h.scene, &.{
        .{ .rename = .{ .id = b_id, .name = Name.init("three").? } },
        .{ .rename = .{ .id = a_id, .name = Name.init("four").? } },
    });
    h.history.gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), h.history.redoDepth());
    try testing.expectEqual(@as(usize, 2), h.history.undoDepth());

    // Undoing a group allocates nothing, exactly as undoing a single command does: the
    // entries it walks over were paid for when they were recorded.
    counting.calls = 0;
    h.history.gpa = counting.allocator();
    try h.history.undo(&h.scene);
    try h.history.undo(&h.scene);
    h.history.gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), counting.calls);
    try testing.expectEqualStrings("a", h.scene.nameOf(h.scene.entityById(a_id).?).?);
    try testing.expectEqualStrings("b", h.scene.nameOf(h.scene.entityById(b_id).?).?);
}

test "edit: undo and redo are allocation-free once the entry exists" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const e = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(e).?;
    try h.scene.addComponent(e, Extra{ .amount = 1 });
    try h.history.apply(&h.scene, .{ .set_component = .{ .id = id, .value = .{ .@"1" = Extra{ .amount = 2 } } } });

    // A counting allocator proves the claim rather than asserting it in a comment.
    var counting = CountingAllocator{ .child = testing.allocator };
    h.history.gpa = counting.allocator();
    try h.history.undo(&h.scene);
    try h.history.redo(&h.scene);
    try h.history.undo(&h.scene);
    try testing.expectEqual(@as(usize, 0), counting.calls);
    h.history.gpa = testing.allocator;
}

test "edit: dirty clears on save and comes back on the next edit" {
    var h = testHarness();
    defer h.scene.deinit();
    defer h.history.deinit();
    const e = try h.scene.createEntity("box", null);
    const id = h.scene.idOf(e).?;
    try h.scene.addComponent(e, Extra{});

    try testing.expect(!h.history.dirty);
    try h.history.apply(&h.scene, .{ .rename = .{ .id = id, .name = Name.init("x").? } });
    try testing.expect(h.history.dirty);
    h.history.markSaved();
    try testing.expect(!h.history.dirty);
    // Saving must not cost the user their history.
    try testing.expect(h.history.canUndo());
    try h.history.apply(&h.scene, .{ .rename = .{ .id = id, .name = Name.init("y").? } });
    try testing.expect(h.history.dirty);
    // Undo also marks the scene dirty: the file no longer matches what is on screen.
    h.history.markSaved();
    try h.history.undo(&h.scene);
    try testing.expect(h.history.dirty);
}

test "edit: a rename longer than the name buffer is refused up front" {
    var long: [max_name_bytes + 1]u8 = @splat('a');
    try testing.expect(Name.init(&long) == null);
    try testing.expect(Name.init(long[0..max_name_bytes]) != null);
}

/// Fetch an entity by ID in a test, failing loudly rather than returning null.
fn entityOfOrPanic(h: anytype, id: u64) @TypeOf(h.scene.entityById(0).?) {
    return h.scene.entityById(id) orelse @panic("entity missing in test");
}

/// Counts allocator calls, so "this path allocates nothing" is measured, not claimed.
const CountingAllocator = struct {
    child: Allocator,
    calls: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.child.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.child.rawFree(memory, alignment, ra);
    }

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

// --- saving -----------------------------------------------------------------

/// Save `scene` to `path` without ever leaving a half-written file behind.
///
/// `Scene.save` writes the document in place, which is the right primitive for a
/// library call and the wrong one for an editor: a crash (or a full disk) in the middle
/// of that write destroys the user's only copy. This stages the bytes in a sibling temp
/// path and renames it over the target, so the file on disk is either the old project or
/// the new one, never a truncated mix.
///
/// On success the history is marked clean — the stacks are **kept**, so saving costs the
/// user nothing to undo. On failure the file is untouched and the history stays dirty,
/// which is what makes "retry the save" meaningful.
pub fn saveScene(history: anytype, scene: anytype, io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: Allocator) !void {
    paths.validateRelative(path) catch return error.UnsafePath;
    const dirname = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);

    // A dot-prefixed sibling: same directory (so the rename cannot cross a filesystem)
    // and hidden from a file listing. Two buffers, because the second format embeds the
    // first: printing into one would alias its own input.
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&name_buf, ".{s}.saving", .{basename}) catch return error.NameTooLong;
    const temp_path = if (dirname.len == 0 or std.mem.eql(u8, dirname, "."))
        temp_name
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dirname, temp_name }) catch return error.NameTooLong;

    const bytes = scene.serialize(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProjectIo,
    };
    defer gpa.free(bytes);

    if (dirname.len > 0 and !std.mem.eql(u8, dirname, ".")) {
        dir.createDirPath(io, dirname) catch return error.ProjectIo;
    }
    dir.writeFile(io, .{ .sub_path = temp_path, .data = bytes }) catch return error.ProjectIo;
    dir.rename(temp_path, dir, path, io) catch |err| {
        // The temp file is worthless if the rename failed; do not leave it behind.
        dir.deleteFile(io, temp_path) catch {};
        return err;
    };
    history.markSaved();
}

test "save: writes the project atomically, marks it clean and keeps the history" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var scene = try TestScene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = TestHistory.init(testing.allocator);
    defer history.deinit();

    const entity = try scene.createEntity("box", null);
    const id = scene.idOf(entity).?;
    try history.apply(&scene, .{ .rename = .{ .id = id, .name = Name.init("box2").? } });
    try testing.expect(history.dirty);

    try saveScene(&history, &scene, io, dir, "level.corex", testing.allocator);
    try testing.expect(!history.dirty);
    // Saving must not cost the user their undo history.
    try testing.expect(history.canUndo());

    const written = try dir.readFileAlloc(io, "level.corex", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "box2") != null);

    // A round trip proves the staged bytes are a complete, loadable document.
    var reloaded = try TestScene.parse(testing.allocator, written);
    defer reloaded.deinit();
    try testing.expectEqualStrings("level", reloaded.name);
    try testing.expectEqual(@as(usize, 1), reloaded.count());

    // The temp file is gone: the directory holds exactly the saved project.
    var entries = try dir.openDir(io, ".", .{ .iterate = true });
    defer entries.close(io);
    var it = entries.iterate();
    var files: usize = 0;
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, "level.corex")) files += 1;
        if (std.mem.indexOf(u8, e.name, ".saving") != null) return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), files);
}

test "save: writes into a scene subdirectory and creates it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var scene = try TestScene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = TestHistory.init(testing.allocator);
    defer history.deinit();

    try saveScene(&history, &scene, io, dir, "scenes/level.corex", testing.allocator);
    const written = try dir.readFileAlloc(io, "scenes/level.corex", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(written);
    try testing.expect(written.len > 0);
    // The temp sibling lived in the same subdirectory, so it is gone there too.
    entriesGone: {
        var sub = dir.openDir(io, "scenes", .{ .iterate = true }) catch break :entriesGone;
        defer sub.close(io);
        var it = sub.iterate();
        while (it.next(io) catch null) |e| {
            if (std.mem.indexOf(u8, e.name, ".saving") != null) return error.TestUnexpectedResult;
        }
    }
}

test "save: keeps the project dirty when the write fails" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var scene = try TestScene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = TestHistory.init(testing.allocator);
    defer history.deinit();
    const entity = try scene.createEntity("box", null);
    try history.apply(&scene, .{ .rename = .{ .id = scene.idOf(entity).?, .name = Name.init("x").? } });

    // `../escape.corex` is refused by the path rules, so nothing is written.
    try testing.expectError(error.UnsafePath, saveScene(&history, &scene, io, tmp.dir, "../escape.corex", testing.allocator));
    try testing.expect(history.dirty);
}

test "edit: valueFor picks the union arm from the value's type, not from a caller-supplied index" {
    var scene = try TestScene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = TestHistory.init(testing.allocator);
    defer history.deinit();
    const entity = try scene.createEntity("box", null);
    const id = scene.idOf(entity).?;
    try scene.addComponent(entity, Extra{ .amount = 1 });

    // The caller names the type; the schema decides which arm that is.
    const value = valueFor(TestScene, Transform, Transform{ .position = .{ 0, 2, 0 } });
    try testing.expectEqualStrings("0", @tagName(value));
    try history.apply(&scene, .{ .set_component = .{ .id = id, .value = value } });
    try testing.expectEqual(@as(f32, 2), scene.getComponent(Transform, entity).?.position[1]);
    // The other component was untouched.
    try testing.expectEqual(@as(i32, 1), scene.getComponent(Extra, entity).?.amount);

    const other = valueFor(TestScene, Extra, Extra{ .amount = 9 });
    try testing.expectEqualStrings("1", @tagName(other));
    try history.apply(&scene, .{ .set_component = .{ .id = id, .value = other } });
    try testing.expectEqual(@as(i32, 9), scene.getComponent(Extra, entity).?.amount);

    try testing.expectEqual(@as(usize, 0), componentIndexOf(TestScene.component_types, Transform));
    try testing.expectEqual(@as(usize, 1), componentIndexOf(TestScene.component_types, Extra));
}
