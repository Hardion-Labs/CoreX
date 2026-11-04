//! Sparse-set component storage.
//!
//! A `Pool(T)` stores components of type `T` keyed by entity slot index using a
//! sparse set: a sparse array maps slot index -> dense index, and parallel dense
//! arrays hold the entity indices and components. This gives O(1) add / remove /
//! get / has and tightly packed, cache-friendly iteration over the dense arrays.
//!
//! Removal is swap-remove (the last dense element moves into the removed slot),
//! so dense order is not stable across removals. Iteration order is insertion
//! order only until the first removal.
//!
//! The pool keys by slot index, not by full generational handle; liveness is the
//! caller's responsibility (the `World` removes components on entity destroy).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Sentinel stored in the sparse array for slots with no component.
const absent: u32 = std.math.maxInt(u32);

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// slot index -> dense index, or `absent`.
        sparse: std.ArrayList(u32),
        /// dense index -> slot index.
        dense_entities: std.ArrayList(u32),
        /// dense index -> component.
        dense_components: std.ArrayList(T),

        pub fn init(gpa: Allocator) Self {
            return .{
                .gpa = gpa,
                .sparse = .empty,
                .dense_entities = .empty,
                .dense_components = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.gpa);
            self.dense_entities.deinit(self.gpa);
            self.dense_components.deinit(self.gpa);
            self.* = undefined;
        }

        /// Add (or overwrite) the component for a slot.
        pub fn add(self: *Self, slot: u32, value: T) Allocator.Error!void {
            if (slot >= self.sparse.items.len) {
                const needed = @as(usize, slot) + 1 - self.sparse.items.len;
                try self.sparse.appendNTimes(self.gpa, absent, needed);
            }
            const existing = self.sparse.items[slot];
            if (existing != absent) {
                self.dense_components.items[existing] = value;
                return;
            }
            const dense_index: u32 = @intCast(self.dense_entities.items.len);
            try self.dense_entities.append(self.gpa, slot);
            errdefer _ = self.dense_entities.pop();
            try self.dense_components.append(self.gpa, value);
            self.sparse.items[slot] = dense_index;
        }

        /// Remove the component for a slot, if present. Swap-remove; no-op when
        /// absent. Infallible.
        pub fn remove(self: *Self, slot: u32) void {
            if (slot >= self.sparse.items.len) return;
            const dense_index = self.sparse.items[slot];
            if (dense_index == absent) return;

            const last = self.dense_entities.items.len - 1;
            if (dense_index != last) {
                const moved_slot = self.dense_entities.items[last];
                self.dense_entities.items[dense_index] = moved_slot;
                self.dense_components.items[dense_index] = self.dense_components.items[last];
                self.sparse.items[moved_slot] = dense_index;
            }
            _ = self.dense_entities.pop();
            _ = self.dense_components.pop();
            self.sparse.items[slot] = absent;
        }

        /// Pointer to the component for a slot, or null if absent.
        pub fn get(self: *Self, slot: u32) ?*T {
            if (slot >= self.sparse.items.len) return null;
            const dense_index = self.sparse.items[slot];
            if (dense_index == absent) return null;
            return &self.dense_components.items[dense_index];
        }

        pub fn has(self: *Self, slot: u32) bool {
            if (slot >= self.sparse.items.len) return false;
            return self.sparse.items[slot] != absent;
        }

        /// Number of stored components.
        pub fn len(self: Self) usize {
            return self.dense_entities.items.len;
        }

        /// Dense slice of slot indices (parallel to `components`).
        pub fn entities(self: *Self) []const u32 {
            return self.dense_entities.items;
        }

        /// Dense slice of components (parallel to `entities`).
        pub fn components(self: *Self) []T {
            return self.dense_components.items;
        }
    };
}

const Vec2 = struct { x: f32, y: f32 };

test "pool: add and get" {
    var pool = Pool(Vec2).init(std.testing.allocator);
    defer pool.deinit();

    try pool.add(3, .{ .x = 1, .y = 2 });
    try std.testing.expect(pool.has(3));
    try std.testing.expect(!pool.has(0));
    const v = pool.get(3).?;
    try std.testing.expectEqual(@as(f32, 1), v.x);
    try std.testing.expectEqual(@as(f32, 2), v.y);
    try std.testing.expectEqual(@as(usize, 1), pool.len());
}

test "pool: add overwrites existing" {
    var pool = Pool(i32).init(std.testing.allocator);
    defer pool.deinit();
    try pool.add(0, 10);
    try pool.add(0, 20);
    try std.testing.expectEqual(@as(usize, 1), pool.len());
    try std.testing.expectEqual(@as(i32, 20), pool.get(0).?.*);
}

test "pool: remove is swap-remove and keeps dense arrays consistent" {
    var pool = Pool(i32).init(std.testing.allocator);
    defer pool.deinit();

    try pool.add(0, 100);
    try pool.add(1, 101);
    try pool.add(2, 102);
    pool.remove(1); // middle element; last (slot 2) moves into its place

    try std.testing.expectEqual(@as(usize, 2), pool.len());
    try std.testing.expect(!pool.has(1));
    try std.testing.expectEqual(@as(i32, 100), pool.get(0).?.*);
    try std.testing.expectEqual(@as(i32, 102), pool.get(2).?.*);
    // Dense arrays stay parallel and consistent.
    try std.testing.expectEqual(pool.entities().len, pool.components().len);
}

test "pool: remove last and remove absent are safe" {
    var pool = Pool(i32).init(std.testing.allocator);
    defer pool.deinit();
    try pool.add(5, 50);
    pool.remove(5); // last element
    pool.remove(5); // now absent
    pool.remove(999); // never present
    try std.testing.expectEqual(@as(usize, 0), pool.len());
    try std.testing.expect(pool.get(5) == null);
}

test "pool: re-add after remove" {
    var pool = Pool(i32).init(std.testing.allocator);
    defer pool.deinit();
    try pool.add(0, 1);
    pool.remove(0);
    try pool.add(0, 2);
    try std.testing.expectEqual(@as(i32, 2), pool.get(0).?.*);
    try std.testing.expectEqual(@as(usize, 1), pool.len());
}

test "pool: dense iteration visits all components" {
    var pool = Pool(i32).init(std.testing.allocator);
    defer pool.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) try pool.add(i, @intCast(i * i));

    var sum: i64 = 0;
    for (pool.components()) |c| sum += c;
    // sum of squares 0..9 = 285
    try std.testing.expectEqual(@as(i64, 285), sum);
    try std.testing.expectEqual(@as(usize, 10), pool.len());
}

test "pool: sparse growth across large slot indices" {
    var pool = Pool(u8).init(std.testing.allocator);
    defer pool.deinit();
    try pool.add(1000, 7);
    try std.testing.expect(pool.has(1000));
    try std.testing.expect(!pool.has(999));
    try std.testing.expectEqual(@as(u8, 7), pool.get(1000).?.*);
}
