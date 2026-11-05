//! Frame-level ECS scheduling: system profiling and cooperative frame budgets.
//!
//! `FrameSchedule` wraps an `AutoSchedule` dependency graph and adds two
//! allocation-free runtime facilities:
//!
//! - **System profiling** — a fixed-size `FrameProfiler(N)` records per-system
//!   run counts, error counts and monotonic timings. Parallel profiling is safe
//!   because each system writes only its own stats slot; reset/report must not
//!   race with a running frame.
//! - **Cooperative frame budgets** — `runBudgeted` executes systems sequentially
//!   in topological order and stops *between* systems when a time or system-count
//!   budget is reached. A `FrameCursor` lets the next call resume where the
//!   previous one stopped. Systems are never preempted mid-run, so a single
//!   system can overrun the budget; this is a cooperative policy, not a hard
//!   real-time guarantee.
//!
//! The plain `run` path still dispatches inferred parallel layers through
//! `std.Io`. Budgeted execution is deliberately sequential so that budget checks
//! and cursor advancement have a single, deterministic owner.

const std = @import("std");
const schedule = @import("schedule.zig");
const graph = @import("graph.zig");
const diagnostics = @import("../core/diagnostics.zig");

const Io = std.Io;
const Timer = diagnostics.Timer;

/// Per-system profiling counters. Timings are monotonic nanoseconds.
pub const SystemStats = struct {
    runs: u64 = 0,
    errors: u64 = 0,
    total_ns: i64 = 0,
    last_ns: i64 = 0,
    max_ns: i64 = 0,
    min_ns: i64 = std.math.maxInt(i64),
};

/// Fixed-size profiler for a schedule with `N` systems. No allocation; the
/// caller owns the value. `before`/`after` are the observer hooks consumed by
/// `schedule.runSystem`. Each system index has an independent slot, so parallel
/// recording does not share mutable state. `reset`, `totalNanoseconds` and
/// `writeReport` must be called outside a running frame.
pub fn FrameProfiler(comptime N: usize) type {
    return struct {
        const Self = @This();

        stats: [N]SystemStats,
        starts: [N]Io.Timestamp,
        frame_elapsed_ns: i64 = 0,

        pub fn init() Self {
            var self: Self = .{ .stats = undefined, .starts = undefined };
            for (&self.stats) |*s| s.* = .{};
            return self;
        }

        pub fn reset(self: *Self) void {
            for (&self.stats) |*s| s.* = .{};
            self.frame_elapsed_ns = 0;
        }

        pub fn before(self: *Self, io: Io, index: usize) void {
            self.starts[index] = Io.Timestamp.now(io, .awake);
        }

        pub fn after(self: *Self, io: Io, index: usize, result: anyerror!void) void {
            const timer = Timer{ .io = io, .begin = self.starts[index] };
            const ns = timer.elapsedNanoseconds();
            const s = &self.stats[index];
            s.runs +|= 1;
            if (result) |_| {} else |_| s.errors +|= 1;
            s.last_ns = ns;
            s.total_ns +|= ns;
            s.max_ns = @max(s.max_ns, ns);
            s.min_ns = @min(s.min_ns, ns);
        }

        pub fn totalNanoseconds(self: *const Self) i64 {
            var sum: i64 = 0;
            for (self.stats) |s| sum +|= s.total_ns;
            return sum;
        }

        pub fn writeReport(self: *const Self, comptime names: [N][]const u8, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.writeAll("ecs frame profile (ms):\n");
            for (self.stats, names) |s, name| {
                const last_ms = @as(f64, @floatFromInt(s.last_ns)) / 1_000_000.0;
                const total_ms = @as(f64, @floatFromInt(s.total_ns)) / 1_000_000.0;
                try writer.print("  {s}: last={d:.3} total={d:.3} runs={d} errors={d}\n", .{
                    name, last_ms, total_ms, s.runs, s.errors,
                });
            }
            const frame_ms = @as(f64, @floatFromInt(self.frame_elapsed_ns)) / 1_000_000.0;
            try writer.print("  frame: {d:.3}\n", .{frame_ms});
        }
    };
}

/// A cooperative frame budget. A zero field disables that limit. Time is checked
/// between systems using the monotonic `awake` clock; a running system is never
/// interrupted, so the budget can be overrun by at most one system.
pub const FrameBudget = struct {
    max_nanoseconds: u64 = 0,
    max_systems: usize = 0,

    pub const unlimited: FrameBudget = .{};
};

/// Why a budgeted run stopped.
pub const StopReason = enum {
    completed,
    time_budget,
    system_budget,
};

/// Outcome of one `runBudgeted` call.
pub const FrameResult = struct {
    executed: usize,
    elapsed_ns: i64,
    completed: bool,
    reason: StopReason,
};

/// Resumable position in a budgeted schedule. `next_system` is the index of the
/// next system to run; it advances only after a system succeeds. On error it
/// stays at the failed system so the caller can decide whether to retry.
pub const FrameCursor = struct {
    next_system: usize = 0,

    pub fn reset(self: *FrameCursor) void {
        self.* = .{};
    }
};

/// A frame-aware schedule over a flat tuple of systems.
pub fn FrameSchedule(comptime W: type, comptime C: type, comptime sys_tuple: anytype) type {
    const AutoGraph = graph.AutoSchedule(W, C, sys_tuple);
    const N = AutoGraph.system_count;

    return struct {
        pub const Graph = AutoGraph;
        pub const system_count = N;
        pub const stage_count = AutoGraph.stage_count;
        pub const names = AutoGraph.names;
        pub const Profiler = FrameProfiler(N);

        /// Run all inferred parallel layers (no profiling).
        pub fn run(io: Io, world: *W, ctx: *C) anyerror!void {
            return AutoGraph.run(io, world, ctx);
        }

        /// Run sequentially without Io dispatch (no profiling).
        pub fn runSequential(world: *W, ctx: *C) anyerror!void {
            return AutoGraph.runSequential(world, ctx);
        }

        /// Run all inferred parallel layers, recording per-system stats into
        /// `profiler`. The profiler accumulates across calls until `reset`.
        pub fn runProfiled(io: Io, world: *W, ctx: *C, profiler: *Profiler) anyerror!void {
            const timer = Timer.start(io);
            const result = AutoGraph.runObserved(io, world, ctx, profiler);
            profiler.frame_elapsed_ns = timer.elapsedNanoseconds();
            return result;
        }

        /// Run systems sequentially from `cursor.next_system`, stopping between
        /// systems when `budget` is reached. Updates `cursor` and `profiler`.
        /// Budget exhaustion is a normal result (`completed = false`), not an
        /// error. A system error propagates and leaves the cursor at that system.
        pub fn runBudgeted(
            io: Io,
            world: *W,
            ctx: *C,
            profiler: *Profiler,
            cursor: *FrameCursor,
            budget: FrameBudget,
        ) anyerror!FrameResult {
            if (cursor.next_system > N) return error.InvalidCursor;
            const timer = Timer.start(io);
            const budget_ns: i64 = std.math.cast(i64, budget.max_nanoseconds) orelse std.math.maxInt(i64);
            var executed: usize = 0;
            var reason: StopReason = .completed;
            var stopped = false;

            errdefer profiler.frame_elapsed_ns = timer.elapsedNanoseconds();

            inline for (AutoGraph.systems, 0..) |S, idx| {
                if (!stopped and idx >= cursor.next_system) {
                    if (budget.max_systems != 0 and executed >= budget.max_systems) {
                        reason = .system_budget;
                        stopped = true;
                    } else if (budget.max_nanoseconds != 0 and timer.elapsedNanoseconds() >= budget_ns) {
                        reason = .time_budget;
                        stopped = true;
                    } else {
                        try schedule.runSystem(S, io, world, ctx, profiler, idx);
                        cursor.next_system = idx + 1;
                        executed += 1;
                    }
                }
            }

            const completed = cursor.next_system >= N;
            if (completed) reason = .completed;
            const elapsed = timer.elapsedNanoseconds();
            profiler.frame_elapsed_ns = elapsed;
            return FrameResult{
                .executed = executed,
                .elapsed_ns = elapsed,
                .completed = completed,
                .reason = reason,
            };
        }

        /// Write a human-readable profiling report (no allocation).
        pub fn writeReport(profiler: *const Profiler, writer: *Io.Writer) Io.Writer.Error!void {
            try profiler.writeReport(AutoGraph.names, writer);
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
fn incC(_: *TestWorld, ctx: *Ctx) anyerror!void {
    ctx.c += 1;
}
fn boom(_: *TestWorld, _: *Ctx) anyerror!void {
    return error.FrameBoom;
}

const SysA = schedule.system(TestWorld, Ctx, "a", incA, .{ .writes = .{CompA} });
const SysB = schedule.system(TestWorld, Ctx, "b", incB, .{ .writes = .{CompB} });
const SysC = schedule.system(TestWorld, Ctx, "c", incC, .{ .writes = .{CompC} });
const SysBoom = schedule.system(TestWorld, Ctx, "boom", boom, .{});

const Three = FrameSchedule(TestWorld, Ctx, .{ SysA, SysB, SysC });

test "frame: system budget stops between systems and resumes" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = Three.Profiler.init();
    var cursor = FrameCursor{};

    const r1 = try Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .{ .max_systems = 1 });
    try testing.expectEqual(@as(usize, 1), r1.executed);
    try testing.expect(!r1.completed);
    try testing.expectEqual(StopReason.system_budget, r1.reason);
    try testing.expectEqual(@as(usize, 1), cursor.next_system);
    try testing.expectEqual(@as(i32, 1), ctx.a);
    try testing.expectEqual(@as(i32, 0), ctx.b);

    const r2 = try Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .{ .max_systems = 2 });
    try testing.expectEqual(@as(usize, 2), r2.executed);
    try testing.expect(r2.completed);
    try testing.expectEqual(StopReason.completed, r2.reason);
    try testing.expectEqual(@as(usize, 3), cursor.next_system);
    try testing.expectEqual(@as(i32, 1), ctx.b);
    try testing.expectEqual(@as(i32, 1), ctx.c);

    try testing.expectEqual(@as(u64, 1), profiler.stats[0].runs);
    try testing.expectEqual(@as(u64, 1), profiler.stats[1].runs);
    try testing.expectEqual(@as(u64, 1), profiler.stats[2].runs);
    try testing.expect(profiler.totalNanoseconds() >= 0);
    try testing.expect(profiler.frame_elapsed_ns >= 0);

    // A completed cursor is a no-op.
    const r3 = try Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited);
    try testing.expectEqual(@as(usize, 0), r3.executed);
    try testing.expect(r3.completed);
}

test "frame: unlimited budget completes and cursor reset restarts" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = Three.Profiler.init();
    var cursor = FrameCursor{};
    const r = try Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited);
    try testing.expect(r.completed);
    try testing.expectEqual(@as(usize, 3), r.executed);
    cursor.reset();
    const r2 = try Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited);
    try testing.expectEqual(@as(usize, 3), r2.executed);
    try testing.expectEqual(@as(u64, 2), profiler.stats[0].runs);
}

test "frame: time budget stops after an overrunning system" {
    const SlowCtx = struct { io: Io, slow_done: bool = false, fast_done: bool = false };
    const SlowWorld = world_mod.World(.{CompA});
    const slowFn = struct {
        fn f(_: *SlowWorld, ctx: *SlowCtx) anyerror!void {
            try Io.sleep(ctx.io, Io.Duration.fromMilliseconds(2), .awake);
            ctx.slow_done = true;
        }
    }.f;
    const fastFn = struct {
        fn f(_: *SlowWorld, ctx: *SlowCtx) anyerror!void {
            ctx.fast_done = true;
        }
    }.f;
    const SlowSys = schedule.system(SlowWorld, SlowCtx, "slow", slowFn, .{ .writes = .{CompA} });
    const FastSys = schedule.system(SlowWorld, SlowCtx, "fast", fastFn, .{});
    const S = FrameSchedule(SlowWorld, SlowCtx, .{ SlowSys, FastSys });

    var world = SlowWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = SlowCtx{ .io = testing.io };
    var profiler = S.Profiler.init();
    var cursor = FrameCursor{};
    const r = try S.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .{ .max_nanoseconds = 1_000_000 });
    try testing.expectEqual(@as(usize, 1), r.executed);
    try testing.expect(!r.completed);
    try testing.expectEqual(StopReason.time_budget, r.reason);
    try testing.expect(ctx.slow_done);
    try testing.expect(!ctx.fast_done);
    try testing.expectEqual(@as(usize, 1), cursor.next_system);
    try testing.expect(r.elapsed_ns >= 1_000_000);
}

test "frame: system error leaves cursor at the failed system" {
    const S = FrameSchedule(TestWorld, Ctx, .{ SysBoom, SysA });
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = S.Profiler.init();
    var cursor = FrameCursor{};
    try testing.expectError(error.FrameBoom, S.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited));
    try testing.expectEqual(@as(usize, 0), cursor.next_system);
    try testing.expectEqual(@as(i32, 0), ctx.a);
    try testing.expectEqual(@as(u64, 1), profiler.stats[0].runs);
    try testing.expectEqual(@as(u64, 1), profiler.stats[0].errors);
    try testing.expectEqual(@as(u64, 0), profiler.stats[1].runs);
}

test "frame: parallel profiling records every system and writes a report" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = Three.Profiler.init();
    try Three.runProfiled(testing.io, &world, &ctx, &profiler);
    try testing.expectEqual(@as(i32, 1), ctx.a);
    try testing.expectEqual(@as(i32, 1), ctx.b);
    try testing.expectEqual(@as(i32, 1), ctx.c);
    for (profiler.stats) |s| {
        try testing.expectEqual(@as(u64, 1), s.runs);
        try testing.expectEqual(@as(u64, 0), s.errors);
        try testing.expect(s.last_ns >= 0);
        try testing.expect(s.max_ns >= s.last_ns);
        try testing.expect(s.min_ns <= s.last_ns);
    }
    var buf: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try Three.writeReport(&profiler, &writer);
    const out = writer.buffered();
    try testing.expect(std.mem.find(u8, out, "a:") != null);
    try testing.expect(std.mem.find(u8, out, "frame:") != null);
}

test "frame: profiler reset clears stats" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = Three.Profiler.init();
    try Three.runProfiled(testing.io, &world, &ctx, &profiler);
    profiler.reset();
    try testing.expectEqual(@as(i64, 0), profiler.totalNanoseconds());
    try testing.expectEqual(@as(i64, 0), profiler.frame_elapsed_ns);
    for (profiler.stats) |s| try testing.expectEqual(@as(u64, 0), s.runs);
}

test "frame: empty schedule completes immediately" {
    const S = FrameSchedule(TestWorld, Ctx, .{});
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = S.Profiler.init();
    var cursor = FrameCursor{};
    const r = try S.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited);
    try testing.expect(r.completed);
    try testing.expectEqual(@as(usize, 0), r.executed);
    try testing.expectEqual(@as(usize, 0), S.system_count);
}

test "frame: an out-of-range cursor is rejected" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = Three.Profiler.init();
    var cursor = FrameCursor{ .next_system = Three.system_count + 1 };
    try testing.expectError(error.InvalidCursor, Three.runBudgeted(testing.io, &world, &ctx, &profiler, &cursor, .unlimited));
}

test "frame: parallel profiling records errors without losing sibling stats" {
    const FailA = schedule.system(TestWorld, Ctx, "fail_a", boom, .{ .writes = .{CompA} });
    const S = FrameSchedule(TestWorld, Ctx, .{ FailA, SysB });
    try testing.expectEqual(@as(usize, 1), S.stage_count); // independent writes -> one parallel layer

    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    var ctx = Ctx{};
    var profiler = S.Profiler.init();
    try testing.expectError(error.FrameBoom, S.runProfiled(testing.io, &world, &ctx, &profiler));
    try testing.expectEqual(@as(u64, 1), profiler.stats[0].runs);
    try testing.expectEqual(@as(u64, 1), profiler.stats[0].errors);
    try testing.expectEqual(@as(u64, 1), profiler.stats[1].runs);
    try testing.expectEqual(@as(u64, 0), profiler.stats[1].errors);
    try testing.expectEqual(@as(i32, 1), ctx.b); // sibling still ran
    try testing.expect(profiler.frame_elapsed_ns >= 0);
}
