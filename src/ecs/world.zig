//! The ECS world: generational entities plus one sparse-set pool per component
//! type, with type-safe access and multi-component views.
//!
//! `World` is parameterized at comptime by a tuple of component types, e.g.
//! `World(.{ Transform, Velocity })`. Each component gets a `Pool`; the world
//! owns entity lifecycle and removes an entity's components from every pool on
//! destroy. Access through a stale (dead) handle is rejected, so a recycled slot
//! can never be reached through an old entity.
//!
//! Low coupling: the world depends only on `entity.zig` and `pool.zig`. It has
//! no knowledge of scenes, rendering, or scripting; those layers build on it.

const std = @import("std");
const entity = @import("entity.zig");
const pool = @import("pool.zig");

pub const Entity = entity.Entity;
const Entities = entity.Entities;
const Pool = pool.Pool;
const Allocator = std.mem.Allocator;

pub const AddError = error{ OutOfMemory, EntityNotAlive };

pub fn World(comptime components: anytype) type {
    const comp_info = @typeInfo(@TypeOf(components)).@"struct";
    const N = components.len;

    // Reify a tuple with one Pool(T) per component type.
    const Pools = blk: {
        var pool_types: [N]type = undefined;
        inline for (components, 0..) |T, i| {
            pool_types[i] = Pool(T);
        }
        break :blk @Tuple(&pool_types);
    };

    return struct {
        const Self = @This();

        entities: Entities,
        pools: Pools,

        pub fn init(gpa: Allocator) Self {
            var self = Self{ .entities = Entities.init(gpa), .pools = undefined };
            inline for (components, comp_info.field_names) |T, name| {
                @field(self.pools, name) = Pool(T).init(gpa);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.entities.deinit();
            inline for (comp_info.field_names) |name| {
                @field(self.pools, name).deinit();
            }
            self.* = undefined;
        }

        /// Create a new entity with no components.
        pub fn create(self: *Self) Allocator.Error!Entity {
            return self.entities.create();
        }

        /// Destroy an entity and remove all of its components. No-op for a dead
        /// handle.
        pub fn destroy(self: *Self, e: Entity) void {
            if (!self.entities.alive(e)) return;
            inline for (comp_info.field_names) |name| {
                @field(self.pools, name).remove(e.index);
            }
            self.entities.destroy(e);
        }

        pub fn alive(self: Self, e: Entity) bool {
            return self.entities.alive(e);
        }

        pub fn count(self: Self) usize {
            return self.entities.count();
        }

        /// Attach (or overwrite) a component on a live entity. The component
        /// type must be registered in this World (checked at comptime).
        pub fn add(self: *Self, e: Entity, value: anytype) AddError!void {
            const T = @TypeOf(value);
            if (!self.entities.alive(e)) return error.EntityNotAlive;
            try self.poolPtr(T).add(e.index, value);
        }

        /// Remove a component from a live entity. No-op if absent or dead.
        pub fn remove(self: *Self, comptime T: type, e: Entity) void {
            if (!self.entities.alive(e)) return;
            self.poolPtr(T).remove(e.index);
        }

        /// Pointer to a component on a live entity, or null.
        pub fn get(self: *Self, comptime T: type, e: Entity) ?*T {
            if (!self.entities.alive(e)) return null;
            return self.poolPtr(T).get(e.index);
        }

        pub fn has(self: *Self, comptime T: type, e: Entity) bool {
            if (!self.entities.alive(e)) return false;
            return self.poolPtr(T).has(e.index);
        }

        /// Number of entities that have component `T`.
        pub fn componentCount(self: *Self, comptime T: type) usize {
            return self.poolPtr(T).len();
        }

        /// Iterate entities that have all of the component types in `Ts` (a
        /// comptime tuple, e.g. `.{ Transform, Velocity }`). Each `next` yields
        /// a tuple `{ Entity, *T0, *T1, ... }`.
        ///
        /// The first component drives iteration; put the most selective type
        /// first for best performance. Do not add/remove components of the
        /// viewed types while iterating (dense storage may be reordered).
        pub fn view(self: *Self, comptime Ts: anytype) View(Ts) {
            return View(Ts).init(self);
        }

        fn componentIndex(comptime T: type) usize {
            inline for (components, 0..) |FT, i| {
                if (FT == T) return i;
            }
            @compileError("component " ++ @typeName(T) ++ " is not registered in this World");
        }

        fn poolPtr(self: *Self, comptime T: type) *Pool(T) {
            const i = comptime componentIndex(T);
            return &@field(self.pools, comp_info.field_names[i]);
        }

        fn View(comptime Ts: anytype) type {
            const M = Ts.len;
            if (M == 0) @compileError("view requires at least one component type");

            // Entry = tuple { Entity, *T0, *T1, ... }.
            const Entry = blk: {
                var types: [M + 1]type = undefined;
                types[0] = Entity;
                inline for (Ts, 0..) |T, i| {
                    types[i + 1] = *T;
                }
                break :blk @Tuple(&types);
            };

            return struct {
                world: *Self,
                cursor: usize,
                mutation: u64,

                pub fn init(world: *Self) @This() {
                    return .{
                        .world = world,
                        .cursor = 0,
                        .mutation = world.poolPtr(Ts[0]).mutationCount(),
                    };
                }

                pub fn next(self: *@This()) ?Entry {
                    const drive = self.world.poolPtr(Ts[0]);
                    // Dense storage may swap-remove underneath an in-flight
                    // iteration, silently skipping or duplicating entries.
                    // Catch that in Debug/ReleaseSafe instead of corrupting
                    // the frame.
                    std.debug.assert(drive.mutationCount() == self.mutation);
                    while (self.cursor < drive.len()) {
                        const slot = drive.entities()[self.cursor];
                        self.cursor += 1;
                        const e = self.world.entities.at(slot) orelse continue;

                        var present = true;
                        inline for (Ts, 0..) |T, i| {
                            if (i == 0) continue; // first type drives iteration
                            if (!self.world.poolPtr(T).has(slot)) present = false;
                        }
                        if (!present) continue;

                        var entry: Entry = undefined;
                        entry[0] = e;
                        inline for (Ts, 0..) |T, i| {
                            entry[i + 1] = self.world.poolPtr(T).get(slot).?;
                        }
                        return entry;
                    }
                    return null;
                }
            };
        }
    };
}

// --- tests -----------------------------------------------------------------

const Transform = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };

const TestWorld = World(.{ Transform, Velocity, Health });

test "world: create and count" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.create();
    const b = try w.create();
    try std.testing.expect(w.alive(a));
    try std.testing.expect(w.alive(b));
    try std.testing.expectEqual(@as(usize, 2), w.count());
}

test "world: add/get/has/remove components" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const e = try w.create();

    try w.add(e, Transform{ .x = 1, .y = 2 });
    try std.testing.expect(w.has(Transform, e));
    try std.testing.expect(!w.has(Velocity, e));
    try std.testing.expectEqual(@as(f32, 1), w.get(Transform, e).?.x);

    w.get(Transform, e).?.x = 10;
    try std.testing.expectEqual(@as(f32, 10), w.get(Transform, e).?.x);

    w.remove(Transform, e);
    try std.testing.expect(!w.has(Transform, e));
    try std.testing.expect(w.get(Transform, e) == null);
}

test "world: add on dead entity is rejected" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const e = try w.create();
    w.destroy(e);
    try std.testing.expectError(error.EntityNotAlive, w.add(e, Transform{ .x = 0, .y = 0 }));
}

test "world: destroy removes all components" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const e = try w.create();
    try w.add(e, Transform{ .x = 0, .y = 0 });
    try w.add(e, Velocity{ .dx = 1, .dy = 1 });
    try std.testing.expectEqual(@as(usize, 1), w.componentCount(Transform));
    try std.testing.expectEqual(@as(usize, 1), w.componentCount(Velocity));

    w.destroy(e);
    try std.testing.expectEqual(@as(usize, 0), w.componentCount(Transform));
    try std.testing.expectEqual(@as(usize, 0), w.componentCount(Velocity));
    try std.testing.expectEqual(@as(usize, 0), w.count());
}

test "world: stale handle cannot reach a recycled entity's components" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.create();
    try w.add(a, Health{ .hp = 100 });
    w.destroy(a);

    const b = try w.create(); // recycles a's slot
    try w.add(b, Health{ .hp = 50 });

    // Stale handle `a` must not see b's component.
    try std.testing.expect(w.get(Health, a) == null);
    try std.testing.expect(!w.has(Health, a));
    try std.testing.expectEqual(@as(i32, 50), w.get(Health, b).?.hp);
}

test "world: single-component view" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.create();
    const b = try w.create();
    try w.add(a, Transform{ .x = 1, .y = 1 });
    try w.add(b, Transform{ .x = 2, .y = 2 });
    _ = try w.create(); // no Transform

    var n: usize = 0;
    var sum: f32 = 0;
    var it = w.view(.{Transform});
    while (it.next()) |entry| {
        n += 1;
        sum += entry[1].x;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(f32, 3), sum);
}

test "world: multi-component view yields only entities with all components" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();

    const a = try w.create();
    try w.add(a, Transform{ .x = 0, .y = 0 });
    try w.add(a, Velocity{ .dx = 1, .dy = 2 });

    const b = try w.create();
    try w.add(b, Transform{ .x = 5, .y = 5 }); // no Velocity

    const c = try w.create();
    try w.add(c, Transform{ .x = 10, .y = 10 });
    try w.add(c, Velocity{ .dx = 3, .dy = 4 });

    var n: usize = 0;
    var it = w.view(.{ Transform, Velocity });
    while (it.next()) |entry| {
        const e = entry[0];
        const t = entry[1];
        const v = entry[2];
        // Simulate a movement system.
        t.x += v.dx;
        t.y += v.dy;
        try std.testing.expect(e.eql(a) or e.eql(c));
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(f32, 1), w.get(Transform, a).?.x);
    try std.testing.expectEqual(@as(f32, 13), w.get(Transform, c).?.x);
    try std.testing.expectEqual(@as(f32, 5), w.get(Transform, b).?.x); // untouched
}

test "world: view reflects removals" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.create();
    try w.add(a, Transform{ .x = 0, .y = 0 });
    try w.add(a, Velocity{ .dx = 1, .dy = 1 });
    w.remove(Velocity, a);

    var it = w.view(.{ Transform, Velocity });
    try std.testing.expect(it.next() == null);
}

test "world: many entities and a movement pass" {
    var w = TestWorld.init(std.testing.allocator);
    defer w.deinit();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const e = try w.create();
        try w.add(e, Transform{ .x = 0, .y = 0 });
        try w.add(e, Velocity{ .dx = 1, .dy = 1 });
    }
    var it = w.view(.{ Transform, Velocity });
    while (it.next()) |entry| {
        entry[1].x += entry[2].dx;
        entry[1].y += entry[2].dy;
    }
    try std.testing.expectEqual(@as(usize, 100), w.componentCount(Transform));
}
