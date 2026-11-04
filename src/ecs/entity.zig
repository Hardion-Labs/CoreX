//! Generational entity handles and lifecycle.
//!
//! An `Entity` is a lightweight handle: a slot index plus a generation counter.
//! When an entity is destroyed its slot's generation is bumped, so any stale
//! handle to the old entity fails `alive` checks even if the slot is recycled.
//! This prevents use-after-free at the ECS boundary without runtime refcounting.
//!
//! Slots whose generation would reach the retired sentinel are never recycled,
//! so a stale handle can never alias a live entity (no wraparound aliasing).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A generational entity handle. Copyable by value; equality is by index and
/// generation. `Entity.invalid` is never alive.
pub const Entity = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: Entity = .{
        .index = std.math.maxInt(u32),
        .generation = std.math.maxInt(u32),
    };

    pub fn eql(a: Entity, b: Entity) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    /// A stable 64-bit key (for hash maps). Not a dense array index.
    pub fn key(self: Entity) u64 {
        return @bitCast(self);
    }
};

/// Generation value that marks a slot as permanently retired (never alive,
/// never recycled). Valid handles always have a generation below this.
const retired_generation: u32 = std.math.maxInt(u32);

/// Manages entity creation, destruction and liveness with slot recycling.
pub const Entities = struct {
    gpa: Allocator,
    generations: std.ArrayList(u32),
    free_indices: std.ArrayList(u32),
    /// One bit per slot: whether the slot currently holds a live entity. This
    /// lets `at`/`alive` distinguish free slots from occupied ones (generation
    /// alone cannot, since a free slot keeps its bumped generation).
    occupied: std.DynamicBitSetUnmanaged,
    alive_count: usize,

    pub fn init(gpa: Allocator) Entities {
        return .{
            .gpa = gpa,
            .generations = .empty,
            .free_indices = .empty,
            .occupied = .{},
            .alive_count = 0,
        };
    }

    pub fn deinit(self: *Entities) void {
        self.generations.deinit(self.gpa);
        self.free_indices.deinit(self.gpa);
        self.occupied.deinit(self.gpa);
        self.* = undefined;
    }

    /// Create a new entity, reusing a freed slot when available.
    pub fn create(self: *Entities) Allocator.Error!Entity {
        if (self.free_indices.pop()) |index| {
            self.alive_count += 1;
            self.occupied.set(index);
            return .{ .index = index, .generation = self.generations.items[index] };
        }
        const index: u32 = @intCast(self.generations.items.len);
        try self.generations.append(self.gpa, 0);
        // Keep the free list's capacity in step so `destroy` never allocates.
        try self.free_indices.ensureTotalCapacity(self.gpa, self.generations.items.len);
        try self.occupied.resize(self.gpa, self.generations.items.len, false);
        self.occupied.set(index);
        self.alive_count += 1;
        return .{ .index = index, .generation = 0 };
    }

    /// Destroy an entity. No-op if the handle is not alive. Infallible: the free
    /// list capacity is reserved by `create`.
    pub fn destroy(self: *Entities, e: Entity) void {
        if (!self.alive(e)) return;
        const gen = self.generations.items[e.index];
        self.alive_count -= 1;
        self.occupied.unset(e.index);
        if (gen == retired_generation - 1) {
            // Retire the slot so no future handle can reuse this generation.
            self.generations.items[e.index] = retired_generation;
            return;
        }
        self.generations.items[e.index] = gen + 1;
        self.free_indices.appendAssumeCapacity(e.index);
    }

    /// Whether `e` refers to a currently live entity.
    pub fn alive(self: Entities, e: Entity) bool {
        if (e.index >= self.generations.items.len) return false;
        if (!self.occupied.isSet(e.index)) return false;
        return self.generations.items[e.index] == e.generation;
    }

    /// The live entity at a slot index, or null if the slot is free/retired.
    pub fn at(self: Entities, index: u32) ?Entity {
        if (index >= self.generations.items.len) return null;
        if (!self.occupied.isSet(index)) return null;
        return .{ .index = index, .generation = self.generations.items[index] };
    }

    /// Number of live entities.
    pub fn count(self: Entities) usize {
        return self.alive_count;
    }

    /// Total slots ever allocated (live + free + retired).
    pub fn capacity(self: Entities) usize {
        return self.generations.items.len;
    }
};

test "entity: create yields distinct alive entities" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();

    const a = try ents.create();
    const b = try ents.create();
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(ents.alive(a));
    try std.testing.expect(ents.alive(b));
    try std.testing.expectEqual(@as(usize, 2), ents.count());
}

test "entity: destroy invalidates the handle" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();

    const a = try ents.create();
    ents.destroy(a);
    try std.testing.expect(!ents.alive(a));
    try std.testing.expectEqual(@as(usize, 0), ents.count());
}

test "entity: recycled slot has a new generation (stale handle stays dead)" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();

    const a = try ents.create();
    ents.destroy(a);
    const b = try ents.create();

    try std.testing.expectEqual(a.index, b.index); // slot recycled
    try std.testing.expect(a.generation != b.generation); // generation bumped
    try std.testing.expect(!ents.alive(a)); // stale handle is dead
    try std.testing.expect(ents.alive(b));
}

test "entity: invalid handle is never alive" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();
    try std.testing.expect(!ents.alive(Entity.invalid));
    const a = try ents.create();
    try std.testing.expect(!ents.alive(Entity.invalid));
    _ = a;
}

test "entity: destroy is idempotent for a stale handle" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();
    const a = try ents.create();
    ents.destroy(a);
    ents.destroy(a); // no-op, must not underflow count
    try std.testing.expectEqual(@as(usize, 0), ents.count());
}

test "entity: at returns live entity for a slot" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();
    const a = try ents.create();
    const got = ents.at(a.index).?;
    try std.testing.expect(a.eql(got));
    ents.destroy(a);
    try std.testing.expect(ents.at(a.index) == null);
}

test "entity: many create/destroy cycles keep counts correct" {
    var ents = Entities.init(std.testing.allocator);
    defer ents.deinit();

    var handles: [64]Entity = undefined;
    for (&handles) |*h| h.* = try ents.create();
    try std.testing.expectEqual(@as(usize, 64), ents.count());

    for (handles, 0..) |h, i| {
        if (i % 2 == 0) ents.destroy(h);
    }
    try std.testing.expectEqual(@as(usize, 32), ents.count());

    for (handles, 0..) |h, i| {
        try std.testing.expectEqual(i % 2 == 1, ents.alive(h));
    }
}

test "entity: key is a stable bitcast" {
    const e = Entity{ .index = 7, .generation = 3 };
    const k = e.key();
    const back: Entity = @bitCast(k);
    try std.testing.expect(e.eql(back));
}
