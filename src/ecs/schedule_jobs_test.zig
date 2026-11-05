//! Integration tests: ECS schedules dispatched over the engine job system.
//!
//! These live in a separate file so the schedule module itself remains
//! independent of `core.jobs`; the public test build imports this file.

const std = @import("std");
const jobs = @import("../core/jobs.zig");
const schedule = @import("schedule.zig");
const world_mod = @import("world.zig");

const A = struct { value: i32 };
const B = struct { value: i32 };
const W = world_mod.World(.{ A, B });
const Ctx = struct { delta: i32 };

fn bumpA(world: *W, ctx: *Ctx) anyerror!void {
    var it = world.view(.{A});
    while (it.next()) |entry| entry[1].value += ctx.delta;
}

fn bumpB(world: *W, ctx: *Ctx) anyerror!void {
    var it = world.view(.{B});
    while (it.next()) |entry| entry[1].value += ctx.delta * 2;
}

fn fail(_: *W, _: *Ctx) anyerror!void {
    return error.IntegrationBoom;
}

const BumpASys = schedule.system(W, Ctx, "bump_a", bumpA, .{ .writes = .{A} });
const BumpBSys = schedule.system(W, Ctx, "bump_b", bumpB, .{ .writes = .{B} });
const FailSys = schedule.system(W, Ctx, "fail", fail, .{});

test "schedule integration: parallel stage runs over JobSystem workers" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 4);
    defer js.deinit();

    var world = W.init(std.testing.allocator);
    defer world.deinit();
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const e = try world.create();
        try world.add(e, A{ .value = i });
        try world.add(e, B{ .value = i });
    }

    const S = schedule.Schedule(W, Ctx, .{.{ BumpASys, BumpBSys }});
    var ctx = Ctx{ .delta = 3 };
    try S.run(js.io(), &world, &ctx);

    var it = world.view(.{ A, B });
    var count: usize = 0;
    while (it.next()) |entry| {
        const base = entry[1].value - 3;
        try std.testing.expectEqual(base + 6, entry[2].value);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), count);
}

test "schedule integration: system error propagates through JobSystem" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var world = W.init(std.testing.allocator);
    defer world.deinit();
    const S = schedule.Schedule(W, Ctx, .{.{ FailSys, BumpASys }});
    var ctx = Ctx{ .delta = 1 };
    try std.testing.expectError(error.IntegrationBoom, S.run(js.io(), &world, &ctx));
}
