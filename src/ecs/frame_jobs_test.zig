//! Integration tests: automatic graph schedules and frame profiling/budgets
//! dispatched over the engine job system. Kept separate so `graph.zig` and
//! `frame.zig` do not depend on `core.jobs` directly.

const std = @import("std");
const jobs = @import("../core/jobs.zig");
const schedule = @import("schedule.zig");
const graph = @import("graph.zig");
const frame = @import("frame.zig");
const world_mod = @import("world.zig");

const A = struct { value: i32 };
const B = struct { value: i32 };
const C = struct { value: i32 };
const W = world_mod.World(.{ A, B, C });
const Ctx = struct { delta: i32 };

fn bumpA(world: *W, ctx: *Ctx) anyerror!void {
    var it = world.view(.{A});
    while (it.next()) |entry| entry[1].value += ctx.delta;
}
fn bumpB(world: *W, ctx: *Ctx) anyerror!void {
    var it = world.view(.{B});
    while (it.next()) |entry| entry[1].value += ctx.delta * 2;
}
fn bumpC(world: *W, ctx: *Ctx) anyerror!void {
    var it = world.view(.{C});
    while (it.next()) |entry| entry[1].value += ctx.delta * 3;
}
fn aToB(world: *W, _: *Ctx) anyerror!void {
    var it = world.view(.{ A, B });
    while (it.next()) |entry| entry[2].value = entry[1].value;
}
fn bToC(world: *W, _: *Ctx) anyerror!void {
    var it = world.view(.{ B, C });
    while (it.next()) |entry| entry[2].value = entry[1].value;
}

const BumpA = schedule.system(W, Ctx, "bump_a", bumpA, .{ .writes = .{A} });
const BumpB = schedule.system(W, Ctx, "bump_b", bumpB, .{ .writes = .{B} });
const BumpC = schedule.system(W, Ctx, "bump_c", bumpC, .{ .writes = .{C} });
const A2B = schedule.system(W, Ctx, "a2b", aToB, .{ .reads = .{A}, .writes = .{B} });
const B2C = schedule.system(W, Ctx, "b2c", bToC, .{ .reads = .{B}, .writes = .{C} });

fn seed(world: *W, n: i32) !void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const e = try world.create();
        try world.add(e, A{ .value = i });
        try world.add(e, B{ .value = i });
        try world.add(e, C{ .value = i });
    }
}

test "frame integration: parallel profiling over JobSystem workers" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 4);
    defer js.deinit();

    var world = W.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world, 64);
    var ctx = Ctx{ .delta = 3 };

    const S = frame.FrameSchedule(W, Ctx, .{ BumpA, BumpB, BumpC });
    try std.testing.expectEqual(@as(usize, 1), S.stage_count);
    var profiler = S.Profiler.init();
    try S.runProfiled(js.io(), &world, &ctx, &profiler);

    var it = world.view(.{ A, B, C });
    var count: usize = 0;
    while (it.next()) |entry| {
        const base = entry[1].value - 3;
        try std.testing.expectEqual(base + 6, entry[2].value);
        try std.testing.expectEqual(base + 9, entry[3].value);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), count);
    for (profiler.stats) |s| {
        try std.testing.expectEqual(@as(u64, 1), s.runs);
        try std.testing.expectEqual(@as(u64, 0), s.errors);
    }
    try std.testing.expect(profiler.frame_elapsed_ns >= 0);
}

test "graph integration: inferred chain runs ordered layers over JobSystem" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var world = W.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world, 32);
    var ctx = Ctx{ .delta = 5 };

    const S = graph.AutoSchedule(W, Ctx, .{ BumpA, A2B, B2C });
    try std.testing.expectEqual(@as(usize, 3), S.stage_count);
    try S.run(js.io(), &world, &ctx);

    var it = world.view(.{ A, B, C });
    while (it.next()) |entry| {
        try std.testing.expectEqual(entry[1].value, entry[2].value);
        try std.testing.expectEqual(entry[1].value, entry[3].value);
    }
}

test "frame integration: budgeted resume uses the caller Io sequentially" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var world = W.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, A{ .value = 0 });
    try world.add(e, B{ .value = 0 });
    try world.add(e, C{ .value = 0 });
    var ctx = Ctx{ .delta = 1 };

    const S = frame.FrameSchedule(W, Ctx, .{ BumpA, BumpB, BumpC });
    var profiler = S.Profiler.init();
    var cursor = frame.FrameCursor{};

    const r1 = try S.runBudgeted(js.io(), &world, &ctx, &profiler, &cursor, .{ .max_systems = 1 });
    try std.testing.expectEqual(@as(usize, 1), r1.executed);
    try std.testing.expect(!r1.completed);
    try std.testing.expectEqual(@as(i32, 1), world.get(A, e).?.value);
    try std.testing.expectEqual(@as(i32, 0), world.get(B, e).?.value);

    const r2 = try S.runBudgeted(js.io(), &world, &ctx, &profiler, &cursor, .unlimited);
    try std.testing.expect(r2.completed);
    try std.testing.expectEqual(@as(i32, 2), world.get(B, e).?.value);
    try std.testing.expectEqual(@as(i32, 3), world.get(C, e).?.value);
}
