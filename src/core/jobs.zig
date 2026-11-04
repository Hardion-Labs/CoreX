//! Job system — foundation for asynchronous loading and parallel work.
//!
//! Wraps the Zig 0.17 `std.Io` concurrency interface. The job system owns a
//! `std.Io.Threaded` instance whose worker pool size is configured from the
//! `--jobs` launch option (or a sensible default). Tasks are dispatched with
//! `Io.async` and awaited through `Io.Future`.
//!
//! Ownership: a `JobSystem` must be initialized in place (`init(&js, ...)`) and
//! must not be moved afterwards, because its `Io` refers to its own `threaded`
//! field. Call `deinit` to join workers and release resources.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const JobSystem = struct {
    threaded: Io.Threaded,
    worker_count: usize,

    /// Initialize in place. `requested_workers == null` selects the default
    /// (logical cores minus one, minimum 1). The `JobSystem` must not be moved
    /// after this call.
    pub fn init(self: *JobSystem, gpa: Allocator, requested_workers: ?usize) void {
        const workers = requested_workers orelse defaultWorkerCount();
        self.* = .{
            .threaded = Io.Threaded.init(gpa, .{ .async_limit = .limited(workers) }),
            .worker_count = workers,
        };
    }

    pub fn deinit(self: *JobSystem) void {
        self.threaded.deinit();
        self.* = undefined;
    }

    /// The `Io` implementation jobs should use for their I/O and concurrency.
    pub fn io(self: *JobSystem) Io {
        return self.threaded.io();
    }

    /// Dispatch a job and return a future for its result. The caller must
    /// `await` (or `cancel`) the returned future exactly once. The job may run
    /// immediately or on a worker, depending on the `Io` implementation.
    pub fn spawn(
        self: *JobSystem,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) Io.Future(ReturnType(@TypeOf(function))) {
        return self.io().async(function, args);
    }

    /// Begin a batch of void-returning tasks that share a completion group.
    pub fn batch(self: *JobSystem) Batch {
        return .{ .group = .init, .io = self.io() };
    }
};

/// A group of fire-and-forget tasks. Each task writes its result into
/// caller-provided storage and returns `Io.Cancelable!void`. Call `wait` to
/// block until every task in the batch has finished.
pub const Batch = struct {
    group: Io.Group,
    io: Io,

    pub fn add(
        self: *Batch,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) void {
        self.group.async(self.io, function, args);
    }

    pub fn wait(self: *Batch) void {
        self.group.await(self.io) catch {};
    }

    pub fn cancel(self: *Batch) void {
        self.group.cancel(self.io);
    }
};

fn ReturnType(comptime F: type) type {
    return @typeInfo(F).@"fn".return_type orelse
        @compileError("job function must have a concrete return type");
}

/// Default worker count: logical cores minus one, minimum 1.
pub fn defaultWorkerCount() usize {
    const cores = std.Thread.getCpuCount() catch 1;
    return @max(1, cores -| 1);
}

fn addOne(x: i32) i32 {
    return x + 1;
}

fn fillSlot(slot: *i32, value: i32) Io.Cancelable!void {
    slot.* = value;
}

test "job system: spawn returns a result" {
    var js: JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var future = js.spawn(addOne, .{41});
    const result = future.await(js.io());
    try std.testing.expectEqual(@as(i32, 42), result);
}

test "job system: respects requested worker count" {
    var js: JobSystem = undefined;
    js.init(std.testing.allocator, 3);
    defer js.deinit();
    try std.testing.expectEqual(@as(usize, 3), js.worker_count);
}

test "job system: default worker count is at least one" {
    try std.testing.expect(defaultWorkerCount() >= 1);
}

test "job system: batch runs all tasks" {
    var js: JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var slots = [_]i32{ 0, 0, 0, 0 };
    var b = js.batch();
    for (&slots, 0..) |*slot, i| {
        b.add(fillSlot, .{ slot, @intCast(i * 10) });
    }
    b.wait();

    try std.testing.expectEqual(@as(i32, 0), slots[0]);
    try std.testing.expectEqual(@as(i32, 10), slots[1]);
    try std.testing.expectEqual(@as(i32, 20), slots[2]);
    try std.testing.expectEqual(@as(i32, 30), slots[3]);
}

test "job system: many parallel jobs produce correct results" {
    var js: JobSystem = undefined;
    js.init(std.testing.allocator, 4);
    defer js.deinit();

    var futures: [16]Io.Future(i32) = undefined;
    for (&futures, 0..) |*f, i| {
        f.* = js.spawn(addOne, .{@intCast(i)});
    }
    for (&futures, 0..) |*f, i| {
        const r = f.await(js.io());
        try std.testing.expectEqual(@as(i32, @intCast(i + 1)), r);
    }
}
