//! Diagnostics and profiling primitives.
//!
//! Provides a monotonic stopwatch (`Timer`) and a lightweight stage profiler
//! (`Profiler`) used to measure startup stages and, later, runtime systems.
//! These are intentionally small and allocation-explicit.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Monotonic stopwatch backed by the `awake` clock. Not affected by wall-clock
/// jumps. Create with `Timer.start(io)` and read with `elapsedNanoseconds`.
pub const Timer = struct {
    io: Io,
    begin: Io.Timestamp,

    pub fn start(io: Io) Timer {
        return .{ .io = io, .begin = Io.Timestamp.now(io, .awake) };
    }

    pub fn elapsedNanoseconds(self: Timer) i64 {
        const now = Io.Timestamp.now(self.io, .awake);
        const d = self.begin.durationTo(now);
        return @intCast(d.toNanoseconds());
    }

    pub fn elapsedMilliseconds(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNanoseconds())) / 1_000_000.0;
    }

    /// Reset the start point to now.
    pub fn restart(self: *Timer) void {
        self.begin = Io.Timestamp.now(self.io, .awake);
    }
};

/// Collects named timing samples (e.g. one per startup stage). Samples are
/// appended in the order recorded. Call `deinit` to release storage.
pub const Profiler = struct {
    gpa: Allocator,
    io: Io,
    samples: std.ArrayList(Sample),
    /// Samples that could not be recorded because the append failed. Recording
    /// never aborts the profiled operation; dropped samples are counted here so
    /// a partial report is visible as partial.
    dropped: usize = 0,

    pub const Sample = struct {
        name: []const u8,
        duration_ns: i64,
    };

    pub fn init(gpa: Allocator, io: Io) Profiler {
        return .{ .gpa = gpa, .io = io, .samples = .empty };
    }

    pub fn deinit(self: *Profiler) void {
        self.samples.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start timing a named stage. Call `Stage.end` to record the sample.
    pub fn begin(self: *Profiler, name: []const u8) Stage {
        return .{ .profiler = self, .name = name, .timer = Timer.start(self.io) };
    }

    pub fn record(self: *Profiler, name: []const u8, duration_ns: i64) void {
        self.samples.append(self.gpa, .{ .name = name, .duration_ns = duration_ns }) catch {
            self.dropped += 1;
        };
    }

    pub fn totalNanoseconds(self: Profiler) i64 {
        var total: i64 = 0;
        for (self.samples.items) |s| total += s.duration_ns;
        return total;
    }

    /// Write a human-readable summary. Names are borrowed, not copied.
    pub fn writeReport(self: Profiler, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("profile (ms):\n");
        for (self.samples.items) |s| {
            const ms = @as(f64, @floatFromInt(s.duration_ns)) / 1_000_000.0;
            try writer.print("  {s}: {d:.3}\n", .{ s.name, ms });
        }
        const total_ms = @as(f64, @floatFromInt(self.totalNanoseconds())) / 1_000_000.0;
        try writer.print("  total: {d:.3}\n", .{total_ms});
        if (self.dropped > 0) try writer.print("  ({d} sample(s) dropped: out of memory)\n", .{self.dropped});
    }

    pub const Stage = struct {
        profiler: *Profiler,
        name: []const u8,
        timer: Timer,

        pub fn end(self: Stage) void {
            self.profiler.record(self.name, self.timer.elapsedNanoseconds());
        }
    };
};

test "timer measures non-negative elapsed time" {
    const io = std.testing.io;
    const t = Timer.start(io);
    const ns = t.elapsedNanoseconds();
    try std.testing.expect(ns >= 0);
    try std.testing.expect(t.elapsedMilliseconds() >= 0.0);
}

test "profiler records samples in order and totals them" {
    var p = Profiler.init(std.testing.allocator, std.testing.io);
    defer p.deinit();

    p.record("a", 1_000_000);
    p.record("b", 2_500_000);

    try std.testing.expectEqual(@as(usize, 2), p.samples.items.len);
    try std.testing.expectEqualStrings("a", p.samples.items[0].name);
    try std.testing.expectEqual(@as(i64, 3_500_000), p.totalNanoseconds());
}

test "profiler stage records a sample" {
    var p = Profiler.init(std.testing.allocator, std.testing.io);
    defer p.deinit();

    const stage = p.begin("work");
    stage.end();

    try std.testing.expectEqual(@as(usize, 1), p.samples.items.len);
    try std.testing.expectEqualStrings("work", p.samples.items[0].name);
    try std.testing.expect(p.samples.items[0].duration_ns >= 0);
}

test "profiler writes a report" {
    var p = Profiler.init(std.testing.allocator, std.testing.io);
    defer p.deinit();
    p.record("stage", 1_000_000);

    var buf: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try p.writeReport(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "stage") != null);
    try std.testing.expect(std.mem.find(u8, out, "total") != null);
}
