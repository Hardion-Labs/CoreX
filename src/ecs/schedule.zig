//! ECS system scheduling over `std.Io` concurrency.
//!
//! A schedule is a comptime tuple of stages; each stage is a tuple of systems.
//! Systems in the same stage are validated at comptime to have non-conflicting
//! component access, then run concurrently through an `Io.Group`. Stages run in
//! declaration order, and a stage completes before the next begins.
//!
//! Safety model:
//! - A system declares the component types it reads and writes. Two systems may
//!   share a stage only if their writes are disjoint and neither writes a type
//!   the other reads.
//! - A system that creates/destroys entities, or otherwise needs exclusive world
//!   access, must set `exclusive = true` and occupy a stage alone.
//! - Access declarations are a contract: the scheduler cannot inspect arbitrary
//!   Zig code. Declaring a write as a read (or omitting entity lifecycle access)
//!   can introduce data races and is a caller bug.
//!
//! The scheduler itself does not allocate. Parallel dispatch uses the caller's
//! `Io` implementation (for example `JobSystem.io()`); error slots and the group
//! live on the caller's stack for the duration of a stage.
//!
//! Optional observer hooks (`runObserved`, `runSequentialObserved`, `runSystem`,
//! `runLayer`) let higher layers profile or budget systems without changing the
//! plain `run`/`runSequential` contracts. `NoopObserver{}` compiles the hooks
//! away. See `graph.zig` (automatic dependency graphs) and `frame.zig` (frame
//! budgets and system profiling).
//!
//! Example:
//! ```zig
//! const Movement = ecs.schedule.system(World, Context, "movement", move, .{
//!     .reads = .{Velocity},
//!     .writes = .{Transform},
//! });
//! const Schedule = ecs.schedule.Schedule(World, Context, .{.{Movement}});
//! try Schedule.run(js.io(), &world, &context);
//! ```

const std = @import("std");

const Io = std.Io;

fn Erased(comptime W: type, comptime C: type) type {
    return struct {
        name: []const u8,
        run: *const fn (*W, *C) anyerror!void,
    };
}

/// Declare a schedulable system.
///
/// `run_fn` must be `fn (*W, *C) anyerror!void`. `spec` is a comptime struct
/// literal with optional fields:
/// - `reads`: tuple of component types read by the system (default `.{}`)
/// - `writes`: tuple of component types written by the system (default `.{}`)
/// - `exclusive`: bool, requires a single-system stage (default `false`)
pub fn system(
    comptime W: type,
    comptime C: type,
    comptime name: []const u8,
    comptime run_fn: anytype,
    comptime spec: anytype,
) type {
    const Spec = @TypeOf(spec);
    comptime {
        if (@typeInfo(Spec) != .@"struct")
            @compileError("system spec must be a struct literal, e.g. .{ .writes = .{Transform} }");
        for (@typeInfo(Spec).@"struct".field_names) |field_name| {
            if (!std.mem.eql(u8, field_name, "reads") and
                !std.mem.eql(u8, field_name, "writes") and
                !std.mem.eql(u8, field_name, "exclusive"))
            {
                @compileError("unknown system spec field: " ++ field_name);
            }
        }
        if (@typeInfo(@TypeOf(run_fn)) != .@"fn")
            @compileError("system run must be a function: fn (*World, *Context) anyerror!void");
    }

    const reads_arr = comptime blk: {
        if (!@hasField(Spec, "reads")) break :blk [0]type{};
        const tup = spec.reads;
        var arr: [tup.len]type = undefined;
        for (tup, 0..) |T, i| {
            if (@TypeOf(T) != type)
                @compileError("system reads must be a tuple of component types");
            arr[i] = T;
        }
        break :blk arr;
    };

    const writes_arr = comptime blk: {
        if (!@hasField(Spec, "writes")) break :blk [0]type{};
        const tup = spec.writes;
        var arr: [tup.len]type = undefined;
        for (tup, 0..) |T, i| {
            if (@TypeOf(T) != type)
                @compileError("system writes must be a tuple of component types");
            arr[i] = T;
        }
        break :blk arr;
    };

    const exclusive_flag = comptime blk: {
        if (!@hasField(Spec, "exclusive")) break :blk false;
        if (@TypeOf(spec.exclusive) != bool)
            @compileError("system spec exclusive must be a bool");
        break :blk spec.exclusive;
    };

    return struct {
        pub const world_type = W;
        pub const context_type = C;
        pub const system_name = name;
        pub const reads = reads_arr;
        pub const writes = writes_arr;
        pub const exclusive = exclusive_flag;
        pub const run = run_fn;
        pub const erased: Erased(W, C) = .{ .name = name, .run = run_fn };
    };
}

fn typeIn(comptime T: type, comptime list: anytype) bool {
    inline for (list) |X| {
        if (X == T) return true;
    }
    return false;
}

fn intersects(comptime A: anytype, comptime B: anytype) bool {
    inline for (A) |X| {
        if (typeIn(X, B)) return true;
    }
    return false;
}

pub fn conflicts(comptime A: type, comptime B: type) bool {
    if (A.exclusive or B.exclusive) return true;
    return intersects(A.writes, B.writes) or
        intersects(A.writes, B.reads) or
        intersects(A.reads, B.writes);
}

pub fn validateSystem(comptime S: type, comptime W: type, comptime C: type) void {
    if (!@hasDecl(S, "world_type") or S.world_type != W)
        @compileError("system world type does not match schedule world type");
    if (!@hasDecl(S, "context_type") or S.context_type != C)
        @compileError("system context type does not match schedule context type");
    if (!@hasDecl(S, "erased"))
        @compileError("schedule entries must be created with ecs.schedule.system");
}

/// A comptime schedule of systems grouped into ordered stages.
///
/// `stages` is a tuple of tuples of systems, e.g. `.{ .{ a, b }, .{ c } }`.
/// Systems within a stage must not conflict (see module docs). The schedule is
/// a zero-sized namespace; call `run` with an `Io`, world and context.
pub fn Schedule(comptime W: type, comptime C: type, comptime stages: anytype) type {
    comptime {
        for (stages) |stage| {
            for (stage, 0..) |A, i| {
                validateSystem(A, W, C);
                for (stage, 0..) |B, j| {
                    if (j <= i) continue;
                    if (conflicts(A, B)) {
                        @compileError("systems '" ++ A.system_name ++ "' and '" ++ B.system_name ++
                            "' have conflicting access and cannot share a stage");
                    }
                }
            }
        }
    }

    return struct {
        pub const world_type = W;
        pub const context_type = C;
        pub const stage_count = stages.len;
        pub const system_count = blk: {
            var n: usize = 0;
            for (stages) |stage| n += stage.len;
            break :blk n;
        };

        /// Run all stages in order. Systems in a multi-system stage are dispatched
        /// concurrently and awaited before the next stage. Returns the first
        /// system error in declaration order, or `error.Canceled` if the Io group
        /// is canceled. All dispatched systems finish before this returns.
        pub fn run(io: Io, world: *W, ctx: *C) anyerror!void {
            return runObserved(io, world, ctx, NoopObserver{});
        }

        /// Like `run`, but notifies `observer` before/after each system. The
        /// observer is a comptime duck-typed value: if its type declares
        /// `before(io, index)` and `after(io, index, result)`, those are called
        /// around the system run. `NoopObserver{}` compiles the hooks away.
        pub fn runObserved(io: Io, world: *W, ctx: *C, observer: anytype) anyerror!void {
            comptime var base_index: usize = 0;
            inline for (stages) |stage| {
                if (stage.len != 0) {
                    const depths = comptime std.mem.zeroes([stage.len]usize);
                    try runLayer(stage, depths, 0, base_index, io, world, ctx, observer);
                }
                base_index += stage.len;
            }
        }

        /// Run all systems sequentially in declaration order, without dispatching
        /// through `Io`. Useful for single-threaded contexts, debugging, or worlds
        /// whose allocator is not thread-safe. Stage boundaries are still respected
        /// as ordering points, but no parallelism is used.
        pub fn runSequential(world: *W, ctx: *C) anyerror!void {
            return runSequentialObserved(null, world, ctx, NoopObserver{});
        }

        /// Like `runSequential`, but with optional observer hooks. When an
        /// observer is supplied, `io` must be non-null so it can time systems.
        pub fn runSequentialObserved(io: ?Io, world: *W, ctx: *C, observer: anytype) anyerror!void {
            comptime var index: usize = 0;
            inline for (stages) |stage| {
                inline for (stage) |S| {
                    try runSystem(S, io, world, ctx, observer, index);
                    index += 1;
                }
            }
        }
    };
}

/// An observer that compiles to no hooks. Used by the plain `run` paths.
pub const NoopObserver = struct {};

fn observerType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// Run one system, optionally notifying an observer. The observer interface is
/// duck-typed: `before(io: Io, index: usize) void` and
/// `after(io: Io, index: usize, result: anyerror!void) void`. Supplying an
/// observer requires a non-null `io`. Returns the system's own result.
pub fn runSystem(
    comptime S: type,
    io: ?Io,
    world: anytype,
    ctx: anytype,
    observer: anytype,
    index: usize,
) anyerror!void {
    return runErasedSystem(S.erased, io, world, ctx, observer, index);
}

fn runErasedSystem(
    sys: anytype,
    io: ?Io,
    world: anytype,
    ctx: anytype,
    observer: anytype,
    index: usize,
) anyerror!void {
    const Obs = observerType(@TypeOf(observer));
    const has_before = @hasDecl(Obs, "before");
    const has_after = @hasDecl(Obs, "after");
    if (has_before != has_after)
        @compileError("schedule observer must declare both before() and after(), or neither");
    if (!has_before) return sys.run(world, ctx);

    const io_val = io orelse return error.MissingIo;
    observer.before(io_val, index);
    const result = sys.run(world, ctx);
    observer.after(io_val, index, result);
    return result;
}

/// Run one comptime layer of a system tuple. `depths[i]` is the layer of system
/// `i`; only systems whose depth equals `layer` run. `base_index` is added to the
/// tuple index to produce the observer's global system index. Single-system
/// layers run directly; larger layers dispatch through one `Io.Group` and await
/// all tasks before returning the first error in declaration order.
pub fn runLayer(
    comptime systems: anytype,
    comptime depths: anytype,
    comptime layer: usize,
    comptime base_index: usize,
    io: Io,
    world: anytype,
    ctx: anytype,
    observer: anytype,
) anyerror!void {
    const count = comptime blk: {
        var n: usize = 0;
        for (depths) |d| {
            if (d == layer) n += 1;
        }
        break :blk n;
    };
    if (count == 0) return;

    if (count == 1) {
        inline for (systems, 0..) |S, i| {
            if (depths[i] == layer) {
                try runSystem(S, io, world, ctx, observer, base_index + i);
            }
        }
        return;
    }

    var errors: [count]?anyerror = undefined;
    for (&errors) |*slot| slot.* = null;
    var group: Io.Group = .init;

    const W = @TypeOf(world.*);
    const C = @TypeOf(ctx.*);
    const Obs = @TypeOf(observer);
    const Task = struct {
        fn start(
            sys: Erased(W, C),
            w: *W,
            c: *C,
            err_slot: *?anyerror,
            io_arg: Io,
            obs: Obs,
            index: usize,
        ) void {
            runErasedSystem(sys, io_arg, w, c, obs, index) catch |err| {
                err_slot.* = err;
            };
        }
    };

    comptime var slot_index: usize = 0;
    inline for (systems, 0..) |S, i| {
        if (depths[i] == layer) {
            group.async(io, Task.start, .{ S.erased, world, ctx, &errors[slot_index], io, observer, base_index + i });
            slot_index += 1;
        }
    }
    try group.await(io);
    for (errors) |slot| {
        if (slot) |err| return err;
    }
}

// --- tests -----------------------------------------------------------------

const world_mod = @import("world.zig");

const Pos = struct { x: i32 };
const Vel = struct { x: i32 };
const Tag = struct { v: i32 };
const TestWorld = world_mod.World(.{ Pos, Vel, Tag });
const Context = struct { delta: i32 = 1, ran: bool = false };

fn moveSystem(world: *TestWorld, ctx: *Context) anyerror!void {
    var it = world.view(.{ Pos, Vel });
    while (it.next()) |entry| {
        entry[1].x += entry[2].x * ctx.delta;
    }
}

fn tagSystem(world: *TestWorld, _: *Context) anyerror!void {
    var it = world.view(.{Tag});
    while (it.next()) |entry| {
        entry[1].v += 1;
    }
}

fn copyPosToTag(world: *TestWorld, _: *Context) anyerror!void {
    var it = world.view(.{ Pos, Tag });
    while (it.next()) |entry| {
        entry[2].v = entry[1].x;
    }
}

fn failSystem(_: *TestWorld, _: *Context) anyerror!void {
    return error.Boom;
}

fn markRan(_: *TestWorld, ctx: *Context) anyerror!void {
    ctx.ran = true;
}

fn spawnSystem(world: *TestWorld, _: *Context) anyerror!void {
    const e = try world.create();
    try world.add(e, Pos{ .x = 42 });
}

fn incPosSystem(world: *TestWorld, _: *void) anyerror!void {
    var it = world.view(.{Pos});
    while (it.next()) |entry| entry[1].x += 1;
}

const MoveSys = system(TestWorld, Context, "move", moveSystem, .{
    .reads = .{Vel},
    .writes = .{Pos},
});
const TagSys = system(TestWorld, Context, "tag", tagSystem, .{
    .writes = .{Tag},
});
const CopySys = system(TestWorld, Context, "copy", copyPosToTag, .{
    .reads = .{Pos},
    .writes = .{Tag},
});
const FailSys = system(TestWorld, Context, "fail", failSystem, .{});
const MarkSys = system(TestWorld, Context, "mark", markRan, .{});
const SpawnSys = system(TestWorld, Context, "spawn", spawnSystem, .{
    .writes = .{Pos},
    .exclusive = true,
});

fn seed(world: *TestWorld) !void {
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        const e = try world.create();
        try world.add(e, Pos{ .x = i });
        try world.add(e, Vel{ .x = 2 });
        try world.add(e, Tag{ .v = 0 });
    }
}

test "schedule: empty schedule runs" {
    const S = Schedule(TestWorld, Context, .{});
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    try S.run(std.testing.io, &world, &ctx);
    try std.testing.expectEqual(@as(usize, 0), S.system_count);
}

test "schedule: single system runs without Io workers" {
    const S = Schedule(TestWorld, Context, .{.{MoveSys}});
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world);
    var ctx = Context{ .delta = 3 };
    try S.run(std.testing.io, &world, &ctx);
    var it = world.view(.{Pos});
    var sum: i32 = 0;
    while (it.next()) |entry| sum += entry[1].x;
    // initial sum 0..7 = 28, plus 8 entities * 2 * 3 = 48 -> 76
    try std.testing.expectEqual(@as(i32, 76), sum);
}

test "schedule: disjoint systems share a parallel stage" {
    const S = Schedule(TestWorld, Context, .{.{ MoveSys, TagSys }});
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world);
    var ctx = Context{};
    try S.run(std.testing.io, &world, &ctx);

    // Pos advanced by 2, Tag advanced by 1.
    var it2 = world.view(.{ Pos, Vel, Tag });
    var count: usize = 0;
    while (it2.next()) |entry| {
        try std.testing.expectEqual(@as(i32, 2), entry[2].x);
        try std.testing.expectEqual(@as(i32, 1), entry[3].v);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
}

test "schedule: stages run in declaration order" {
    const S = Schedule(TestWorld, Context, .{ .{MoveSys}, .{CopySys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world);
    var ctx = Context{};
    try S.run(std.testing.io, &world, &ctx);

    var it = world.view(.{ Pos, Tag });
    while (it.next()) |entry| {
        try std.testing.expectEqual(entry[1].x, entry[2].v);
    }
}

test "schedule: system error propagates and stops later stages" {
    const S = Schedule(TestWorld, Context, .{ .{FailSys}, .{MarkSys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    try std.testing.expectError(error.Boom, S.run(std.testing.io, &world, &ctx));
    try std.testing.expect(!ctx.ran);
}

test "schedule: parallel stage waits for all systems before returning error" {
    const S = Schedule(TestWorld, Context, .{.{ FailSys, TagSys }});
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world);
    var ctx = Context{};
    try std.testing.expectError(error.Boom, S.run(std.testing.io, &world, &ctx));
    try std.testing.expectEqual(@as(usize, 8), world.componentCount(Tag));
    var it = world.view(.{Tag});
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(i32, 1), entry[1].v);
    }
}

test "schedule: exclusive system can create entities" {
    const S = Schedule(TestWorld, Context, .{ .{SpawnSys}, .{MoveSys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    try S.run(std.testing.io, &world, &ctx);
    try std.testing.expectEqual(@as(usize, 1), world.count());
    // Spawned entity has Pos but no Vel, so MoveSys does not change it.
    var it = world.view(.{Pos});
    const entry = it.next().?;
    try std.testing.expectEqual(@as(i32, 42), entry[1].x);
    try std.testing.expect(it.next() == null);
}

test "schedule: void context is supported" {
    const IncSys = system(TestWorld, void, "inc", incPosSystem, .{ .writes = .{Pos} });
    const S = Schedule(TestWorld, void, .{.{IncSys}});
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Pos{ .x = 0 });
    var ctx: void = {};
    try S.run(std.testing.io, &world, &ctx);
    try std.testing.expectEqual(@as(i32, 1), world.get(Pos, e).?.x);
}

test "schedule: conflict detection logic" {
    const ReadPos = system(TestWorld, Context, "read_pos", copyPosToTag, .{ .reads = .{Pos}, .writes = .{Tag} });
    const WritePos = system(TestWorld, Context, "write_pos", moveSystem, .{ .reads = .{Vel}, .writes = .{Pos} });
    try std.testing.expect(conflicts(WritePos, ReadPos)); // write Pos vs read Pos
    try std.testing.expect(conflicts(WritePos, WritePos)); // write Pos vs write Pos
    try std.testing.expect(!conflicts(WritePos, TagSys)); // Pos/Vel vs Tag disjoint
    try std.testing.expect(conflicts(SpawnSys, TagSys)); // exclusive conflicts with everything
}

test "schedule: empty stages are skipped" {
    const S = Schedule(TestWorld, Context, .{ .{}, .{MarkSys}, .{} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    try S.run(std.testing.io, &world, &ctx);
    try std.testing.expect(ctx.ran);
    try std.testing.expectEqual(@as(usize, 3), S.stage_count);
    try std.testing.expectEqual(@as(usize, 1), S.system_count);
}

test "schedule: runSequential preserves order without Io" {
    const S = Schedule(TestWorld, Context, .{ .{ MoveSys, TagSys }, .{CopySys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try seed(&world);
    var ctx = Context{};
    try S.runSequential(&world, &ctx);

    var it = world.view(.{ Pos, Tag });
    while (it.next()) |entry| {
        // Move advanced Pos by 2; Copy then copied Pos into Tag.
        try std.testing.expectEqual(entry[1].x, entry[2].v);
    }
}

test "schedule: runSequential propagates errors and stops" {
    const S = Schedule(TestWorld, Context, .{ .{FailSys}, .{MarkSys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    try std.testing.expectError(error.Boom, S.runSequential(&world, &ctx));
    try std.testing.expect(!ctx.ran);
}

test "schedule: observer hooks use global indices across stages" {
    const Obs = struct {
        indices: [3]usize = undefined,
        count: usize = 0,
        errors: usize = 0,
        pub fn before(self: *@This(), io: Io, index: usize) void {
            _ = io;
            self.indices[self.count] = index;
            self.count += 1;
        }
        pub fn after(self: *@This(), io: Io, index: usize, result: anyerror!void) void {
            _ = io;
            _ = index;
            if (result) |_| {} else |_| self.errors += 1;
        }
    };
    const S = Schedule(TestWorld, Context, .{ .{ MoveSys, TagSys }, .{CopySys} });
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    var obs = Obs{};
    try S.runSequentialObserved(std.testing.io, &world, &ctx, &obs);
    try std.testing.expectEqual(@as(usize, 3), obs.count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &obs.indices);
    try std.testing.expectEqual(@as(usize, 0), obs.errors);
}

test "schedule: observer receives errors and requires Io when present" {
    const Obs = struct {
        last_error: ?anyerror = null,
        pub fn before(self: *@This(), io: Io, index: usize) void {
            _ = self;
            _ = io;
            _ = index;
        }
        pub fn after(self: *@This(), io: Io, index: usize, result: anyerror!void) void {
            _ = io;
            _ = index;
            if (result) |_| {} else |err| self.last_error = err;
        }
    };
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();
    var ctx = Context{};
    var obs = Obs{};

    const Failing = Schedule(TestWorld, Context, .{ .{FailSys}, .{MarkSys} });
    try std.testing.expectError(error.Boom, Failing.runSequentialObserved(std.testing.io, &world, &ctx, &obs));
    try std.testing.expectEqual(@as(?anyerror, error.Boom), obs.last_error);
    try std.testing.expect(!ctx.ran);

    const Mark = Schedule(TestWorld, Context, .{.{MarkSys}});
    try std.testing.expectError(error.MissingIo, Mark.runSequentialObserved(null, &world, &ctx, &obs));
    try std.testing.expect(!ctx.ran);
}
