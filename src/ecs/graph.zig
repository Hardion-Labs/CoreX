//! Automatic dependency-graph scheduling for ECS systems.
//!
//! `AutoSchedule` takes a flat tuple of systems and derives a deterministic
//! comptime execution graph from their declared component access:
//!
//! - Two systems that conflict (write/write, write/read, or exclusive access)
//!   get a dependency edge in declaration order: the earlier system runs first.
//! - Non-conflicting systems share the same layer and may run concurrently.
//! - An exclusive system conflicts with every other system, so it naturally
//!   forms a barrier layer.
//!
//! The graph is a DAG by construction (edges only point from earlier to later
//! declarations), so no cycle detection or runtime topological sort is needed.
//! Layer assignment is a single comptime longest-path pass; at runtime the
//! scheduler only dispatches precomputed layers through the shared
//! `schedule.runLayer` helper. There is no runtime graph allocation.
//!
//! This is additive: the existing `Schedule` comptime-stage API is unchanged.
//! Use `AutoSchedule` when you want the engine to infer safe parallel layers
//! from access declarations; use `Schedule` when you want explicit stages.

const std = @import("std");
const schedule = @import("schedule.zig");

const Io = std.Io;

/// Build an automatic schedule from a flat tuple of systems.
///
/// Systems must be created with `schedule.system`, share the same world and
/// context types, and have unique names (names identify profiling samples).
/// The returned namespace exposes `run`, `runObserved`, `runSequential`,
/// `runSequentialObserved`, `depths`, `stage_count`, `system_count` and `names`.
pub fn AutoSchedule(comptime W: type, comptime C: type, comptime sys_tuple: anytype) type {
    comptime {
        for (sys_tuple) |S| schedule.validateSystem(S, W, C);
        for (sys_tuple, 0..) |A, i| {
            for (sys_tuple, 0..) |B, j| {
                if (j <= i) continue;
                if (std.mem.eql(u8, A.system_name, B.system_name))
                    @compileError("AutoSchedule system names must be unique: '" ++ A.system_name ++ "'");
            }
        }
    }

    const depth_layers = comptime blk: {
        var d: [sys_tuple.len]usize = @splat(0);
        for (sys_tuple, 0..) |S, i| {
            var depth: usize = 0;
            for (sys_tuple, 0..) |P, j| {
                if (j >= i) break;
                if (schedule.conflicts(P, S)) depth = @max(depth, d[j] + 1);
            }
            d[i] = depth;
        }
        break :blk d;
    };

    const layer_count = comptime blk: {
        var m: usize = 0;
        for (depth_layers) |d| m = @max(m, d + 1);
        break :blk m;
    };

    const system_names = comptime blk: {
        var arr: [sys_tuple.len][]const u8 = undefined;
        for (sys_tuple, 0..) |S, i| arr[i] = S.system_name;
        break :blk arr;
    };

    return struct {
        pub const world_type = W;
        pub const context_type = C;
        pub const system_count = sys_tuple.len;
        pub const stage_count = layer_count;
        pub const systems = sys_tuple;
        pub const depths = depth_layers;
        pub const names = system_names;

        /// Run all inferred layers in order, dispatching non-conflicting systems
        /// concurrently through `io`. Returns the first system error in
        /// declaration order, or `error.Canceled` if a group is canceled.
        pub fn run(io: Io, world: *W, ctx: *C) anyerror!void {
            return runObserved(io, world, ctx, schedule.NoopObserver{});
        }

        /// Like `run`, with observer hooks (see `schedule.runSystem`).
        pub fn runObserved(io: Io, world: *W, ctx: *C, observer: anytype) anyerror!void {
            inline for (0..layer_count) |layer| {
                try schedule.runLayer(sys_tuple, depth_layers, layer, 0, io, world, ctx, observer);
            }
        }

        /// Run systems sequentially in declaration order (a topological order of
        /// the inferred graph), without Io dispatch.
        pub fn runSequential(world: *W, ctx: *C) anyerror!void {
            return runSequentialObserved(null, world, ctx, schedule.NoopObserver{});
        }

        /// Like `runSequential`, with observer hooks. Requires `io` when an
        /// observer is supplied.
        pub fn runSequentialObserved(io: ?Io, world: *W, ctx: *C, observer: anytype) anyerror!void {
            inline for (sys_tuple, 0..) |S, i| {
                try schedule.runSystem(S, io, world, ctx, observer, i);
            }
        }

        /// The inferred layer of a system index.
        pub fn stageOf(index: usize) usize {
            return depth_layers[index];
        }
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const world_mod = @import("world.zig");

const CompA = struct { v: i32 };
const CompB = struct { v: i32 };
const CompC = struct { v: i32 };
const TestWorld = world_mod.World(.{ CompA, CompB, CompC });
const Ctx = struct { a: i32 = 0, b: i32 = 0, c: i32 = 0 };

fn incA(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.a += 1;
}
fn incB(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.b += 1;
}
fn aToC(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.c = ctx.a;
}
fn cToB(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.b = ctx.c;
}
fn exclusive(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.a += 10;
    ctx.b += 10;
    ctx.c += 10;
}
fn fail(_: *TestWorld, _: *Ctx) anyerror!void {
    return error.GraphBoom;
}

const SysA = schedule.system(TestWorld, Ctx, "a", incA, .{ .writes = .{CompA} });
const SysB = schedule.system(TestWorld, Ctx, "b", incB, .{ .writes = .{CompB} });
const SysA2C = schedule.system(TestWorld, Ctx, "a2c", aToC, .{ .reads = .{CompA}, .writes = .{CompC} });
const SysC2B = schedule.system(TestWorld, Ctx, "c2b", cToB, .{ .reads = .{CompC}, .writes = .{CompB} });
const SysExcl = schedule.system(TestWorld, Ctx, "excl", exclusive, .{ .exclusive = true });
const SysFail = schedule.system(TestWorld, Ctx, "fail", fail, .{ .exclusive = true });

test "auto schedule: empty graph runs" {
    const S = AutoSchedule(TestWorld, Ctx, .{});
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try S.run(testing.io, &world, &ctx);
    try testing.expectEqual(@as(usize, 0), S.system_count);
    try testing.expectEqual(@as(usize, 0), S.stage_count);
}

test "auto schedule: independent systems share layer 0" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysB });
    try testing.expectEqual(@as(usize, 1), S.stage_count);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, &S.depths);
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try S.run(testing.io, &world, &ctx);
    try testing.expectEqual(@as(i32, 1), ctx.a);
    try testing.expectEqual(@as(i32, 1), ctx.b);
}

test "auto schedule: read/write chain produces ordered layers" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysA2C, SysC2B });
    try testing.expectEqual(@as(usize, 3), S.stage_count);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &S.depths);
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try S.run(testing.io, &world, &ctx);
    try testing.expectEqual(@as(i32, 1), ctx.a);
    try testing.expectEqual(@as(i32, 1), ctx.c);
    try testing.expectEqual(@as(i32, 1), ctx.b);
}

test "auto schedule: exclusive system forms a barrier" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysExcl, SysB });
    try testing.expectEqual(@as(usize, 3), S.stage_count);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &S.depths);
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try S.runSequential(&world, &ctx);
    try testing.expectEqual(@as(i32, 11), ctx.a); // 1 then +10
    try testing.expectEqual(@as(i32, 11), ctx.b); // +10 then +1
}

test "auto schedule: conflicting declaration order is preserved" {
    // SysA2C reads A and is declared first; SysA writes A. The edge points from
    // the earlier declaration to the later one, so a2c runs in layer 0 and a in
    // layer 1, regardless of the access direction.
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA2C, SysA });
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, &S.depths);
    try testing.expectEqual(@as(usize, 2), S.stage_count);
}

test "auto schedule: sequential run follows a topological order" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysA2C, SysC2B });
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try S.runSequential(&world, &ctx);
    try testing.expectEqual(@as(i32, 1), ctx.b);
}

test "auto schedule: error propagates and stops later layers" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysFail, SysA });
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    try testing.expectError(error.GraphBoom, S.run(testing.io, &world, &ctx));
    try testing.expectEqual(@as(i32, 0), ctx.a);
}

test "auto schedule: observer hooks fire for each system" {
    const Obs = struct {
        before_count: usize = 0,
        after_count: usize = 0,
        pub fn before(self: *@This(), io: Io, index: usize) void {
            _ = io;
            _ = index;
            self.before_count += 1;
        }
        pub fn after(self: *@This(), io: Io, index: usize, result: anyerror!void) void {
            _ = io;
            _ = index;
            _ = result catch {};
            self.after_count += 1;
        }
    };
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysA2C, SysC2B });
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var obs = Obs{};
    try S.runSequentialObserved(testing.io, &world, &ctx, &obs);
    try testing.expectEqual(@as(usize, 3), obs.before_count);
    try testing.expectEqual(@as(usize, 3), obs.after_count);
}

test "auto schedule: names and stageOf expose the graph" {
    const S = AutoSchedule(TestWorld, Ctx, .{ SysA, SysB, SysA2C });
    try testing.expectEqualStrings("a", S.names[0]);
    try testing.expectEqualStrings("b", S.names[1]);
    try testing.expectEqualStrings("a2c", S.names[2]);
    try testing.expectEqual(@as(usize, 0), S.stageOf(0));
    try testing.expectEqual(@as(usize, 0), S.stageOf(1));
    try testing.expectEqual(@as(usize, 1), S.stageOf(2));
}
