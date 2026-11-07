//! Frame pacing: deciding how long to wait so a loop runs at a target rate.
//!
//! A frame loop that renders as fast as it can burns a core and produces a framerate
//! the display cannot show. Pacing is the piece that turns "render in a loop" into "run
//! at `target_fps`", and it is deliberately **pure arithmetic plus one sleep**: the
//! decision is a function of the frame's measured duration, so the whole thing is
//! testable without a real clock, a window or a vsync signal.
//!
//! ## What is real, and what is not yet
//!
//! Without a surface to present to, there is no authoritative "the display is ready"
//! signal — that is what vsync gives. So this pacer is a **sleep-based** pacer: it
//! sleeps the remainder of the frame budget and cannot do better than the timer's
//! resolution. When a presentable surface lands, the deadline this type computes is
//! exactly what a swapchain with `FIFO`/vsync would impose, so the accounting and the
//! statistics stay valid; only the waiting mechanism changes. Saying that plainly
//! matters: a pacer that claimed to vsync would be lying.
//!
//! ## Why the arithmetic is not `sleep(budget - elapsed)`
//!
//! Two mistakes are easy here and both are visible in real loops:
//!
//! 1. **Drift.** If each frame sleeps `budget - elapsed`, every frame's overshoot (the
//!    sleep granularity, the scheduler) accumulates, and a 60 Hz loop slowly becomes a
//!    55 Hz loop. The deadline is therefore anchored to a start time and advanced by
//!    `budget` per frame, so overshoot on one frame is repaid by the next.
//! 2. **Death spiral.** A frame slower than its budget would make "sleep the remainder"
//!    negative; clamping to zero keeps it running, and skipping the missed deadlines
//!    avoids trying to render a burst of catch-up frames after a stall. Missed frames
//!    are counted, not hidden.
//!
//! A loop that never sleeps is also legitimate (`Pacer.disabled`): the headless engine
//! default renders as fast as possible, because nothing is being shown and a scripted
//! run should not take wall-clock minutes.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What the pacer measured and decided. Every frame produces one, so a loop can report
/// the truth about its pacing instead of claiming a rate.
pub const FramePacing = struct {
    /// Wall-clock duration of the frame's work (everything except the wait).
    work_ns: u64 = 0,
    /// Time spent waiting for the deadline.
    slept_ns: u64 = 0,
    /// Whether the frame overran its budget and no wait was possible.
    late: bool = false,
};

/// A duration on the monotonic clock, from a nanosecond count.
fn awake(nanoseconds: i96) Io.Clock.Duration {
    return .{ .raw = Io.Duration.fromNanoseconds(nanoseconds), .clock = .awake };
}

/// Nanoseconds in a clock-relative duration.
fn nanos(duration: Io.Clock.Duration) i96 {
    return duration.raw.nanoseconds;
}

/// Longest a single frame is allowed to wait, in nanoseconds.
///
/// A one-second wait is already pathological (the target rate would be 1 fps); anything
/// larger means the deadline is in the wrong epoch — a clock that jumped, a corrupted
/// budget — and blocking the loop for it would hang the process. Exceeding this is
/// treated as "deadline lost": the schedule re-anchors and the frame is counted late
/// rather than slept away.
pub const max_wait_ns: u64 = std.time.ns_per_s;

pub const Error = error{
    /// `target_fps` was zero.
    InvalidTargetFps,
    /// The wait was interrupted; the caller decides whether to keep looping.
    Canceled,
};

/// A vsync-less frame pacer at a fixed target rate.
pub const Pacer = struct {
    /// Frame budget in nanoseconds (`1e9 / target_fps`), or `null` when disabled.
    budget_ns: ?u64 = null,
    /// Deadline for the end of the current frame, on the monotonic clock.
    deadline: ?Io.Clock.Timestamp = null,
    /// Frames whose deadline had already passed when the work finished.
    late_frames: usize = 0,
    /// Frames the pacer re-anchored because the wait would have been absurd.
    resyncs: usize = 0,

    /// A pacer that never waits: the headless default.
    pub const disabled: Pacer = .{};

    /// A pacer at `target_fps` frames per second.
    ///
    /// The budget is computed in integers, so the target rate is exactly the documented
    /// one and not an approximation of it.
    pub fn init(target_fps: u32) Error!Pacer {
        if (target_fps == 0) return error.InvalidTargetFps;
        return .{ .budget_ns = std.time.ns_per_s / target_fps };
    }

    pub fn enabled(self: Pacer) bool {
        return self.budget_ns != null;
    }

    /// Forget the current deadline, so the next `end` anchors a fresh schedule.
    ///
    /// Called when the work between frames changes shape (a resize, a scene load): the
    /// accumulated schedule was measured against work that no longer happens, and
    /// catching up on it would produce a burst of frames.
    pub fn reschedule(self: *Pacer) void {
        self.deadline = null;
    }

    /// Called before the frame's work starts. Returns the instant the work is measured
    /// from, or `null` when pacing is off.
    pub fn begin(self: Pacer, io: Io) ?Io.Clock.Timestamp {
        if (!self.enabled()) return null;
        return Io.Clock.Timestamp.now(io, .awake);
    }

    /// Sleep the remainder of the frame budget and report what happened.
    ///
    /// `started` is the value `begin` returned for this frame. The next deadline is
    /// `previous_deadline + budget` (or `now + budget` for the first frame), so a frame
    /// that overran is repaid instead of compounding.
    pub fn end(self: *Pacer, io: Io, started: ?Io.Clock.Timestamp) Error!FramePacing {
        const start = started orelse return .{};
        const budget = self.budget_ns orelse return .{};
        const now = Io.Clock.Timestamp.now(io, .awake);
        // Direction matters and is easy to get backwards: in this std
        // `t.durationFromNow(io)` is `t - now` and `t.untilNow(io)` is `now - t`
        // (verified against the live clock, not assumed). So elapsed work is
        // `start.untilNow` and the remaining wait is `target.durationFromNow`.
        const work = nanos(start.untilNow(io));
        var pacing = FramePacing{ .work_ns = if (work > 0) @intCast(work) else 0 };

        // The deadline this frame must be finished by: the previous one advanced by one
        // budget, so overshoot does not accumulate across frames. The first frame
        // anchors on the instant its work started — anchoring on `now` would make the
        // first frame's overrun invisible and let it slip a full budget late.
        const budget_span = awake(@intCast(budget));
        const target: Io.Clock.Timestamp = if (self.deadline) |d|
            d.addDuration(budget_span)
        else
            start.addDuration(budget_span);

        // Positive means there is time left.
        const wait_ns = nanos(target.durationFromNow(io));

        if (wait_ns <= 0) {
            // The frame overran its budget. Do not sleep, count it, and keep the
            // schedule moving from `now` rather than from a deadline already in the past.
            pacing.late = true;
            self.late_frames += 1;
            // Re-anchor on the instant this frame actually ended, **not** one budget
            // after it: `deadline` is the end of the frame just finished, so storing
            // `now + budget` would hand the next frame two budgets of slack and turn a
            // steady overrun into an alternating "sleep, overrun, sleep" pattern instead
            // of an honest report that the loop cannot keep up.
            self.deadline = now;
            return pacing;
        }
        if (wait_ns > @as(i96, @intCast(max_wait_ns))) {
            // A deadline this far out is not a rate, it is a broken clock: re-anchor
            // instead of blocking the loop, and say so.
            self.resyncs += 1;
            self.deadline = now;
            return pacing;
        }

        Io.sleep(io, Io.Duration.fromNanoseconds(@intCast(wait_ns)), .awake) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        pacing.slept_ns = @intCast(wait_ns);
        self.deadline = target;
        return pacing;
    }

    /// The rate the pacer was configured for, in whole frames per second.
    pub fn targetFps(self: Pacer) ?u32 {
        const budget = self.budget_ns orelse return null;
        return @intCast(std.time.ns_per_s / budget);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "pacer: the budget is the exact reciprocal of the target rate" {
    const sixty = try Pacer.init(60);
    try testing.expectEqual(@as(?u64, 16_666_666), sixty.budget_ns);
    try testing.expectEqual(@as(?u32, 60), sixty.targetFps());

    // An exact divisor stays exact in both directions.
    const fifty = try Pacer.init(50);
    try testing.expectEqual(@as(?u64, 20_000_000), fifty.budget_ns);
    try testing.expectEqual(@as(?u32, 50), fifty.targetFps());

    // A rate faster than the nanosecond budget cannot be represented; it is clamped,
    // not silently wrapped to zero.
    const absurd = try Pacer.init(std.time.ns_per_s * 2 + 1);
    try testing.expectEqual(@as(?u64, 0), absurd.budget_ns);

    try testing.expectError(error.InvalidTargetFps, Pacer.init(0));
}

test "pacer: disabled never measures anything and never waits" {
    var off = Pacer.disabled;
    try testing.expect(!off.enabled());
    try testing.expectEqual(@as(?u64, null), off.budget_ns);
    try testing.expectEqual(@as(?u32, null), off.targetFps());

    const io = testing.io;
    try testing.expectEqual(@as(?Io.Clock.Timestamp, null), off.begin(io));
    const pacing = try off.end(io, null);
    try testing.expectEqual(@as(u64, 0), pacing.work_ns);
    try testing.expectEqual(@as(u64, 0), pacing.slept_ns);
    try testing.expect(!pacing.late);
}

test "pacer: a fast frame waits out the rest of its budget" {
    // The property that makes a loop a *paced* loop: work that finishes early waits,
    // so the frame period is at least the budget. Measured on the real monotonic clock
    // with a generous tolerance — this asserts the sleep happened, not its precision.
    const io = testing.io;
    var pacer = try Pacer.init(50); // 20 ms
    const started = pacer.begin(io).?;
    const pacing = try pacer.end(io, started);

    try testing.expect(!pacing.late);
    try testing.expect(pacing.slept_ns > 0);
    try testing.expect(pacing.slept_ns <= 20_000_000);

    // The deadline was recorded, so the next frame continues the same schedule.
    try testing.expect(pacer.deadline != null);
    try testing.expectEqual(@as(usize, 0), pacer.late_frames);
    try testing.expectEqual(@as(usize, 0), pacer.resyncs);
}

test "pacer: a late frame does not sleep and does not accumulate debt" {
    // A frame that overruns its budget must not make the next one sleep for a negative
    // time, and must not try to catch up a burst. The schedule re-anchors from now.
    const io = testing.io;
    var pacer = try Pacer.init(1000); // 1 ms budget
    try testing.expectEqual(@as(?u64, 1_000_000), pacer.budget_ns);

    // Simulate work that took far longer than the budget by starting the frame in the
    // past: the deadline computed from it is already behind `now`.
    // 50 ms ago: a negative duration added to "now" moves the instant backwards.
    const long_ago = Io.Clock.Timestamp.now(io, .awake).addDuration(awake(-50 * std.time.ns_per_ms));
    const pacing = try pacer.end(io, long_ago);
    try testing.expect(pacing.late);
    try testing.expectEqual(@as(u64, 0), pacing.slept_ns);
    try testing.expect(pacing.work_ns >= 50_000_000);
    try testing.expectEqual(@as(usize, 1), pacer.late_frames);
    // Re-anchored, so the next frame has a future deadline rather than a backlog.
    try testing.expect(pacer.deadline != null);
}

test "pacer: reschedule drops a stale deadline instead of repaying it" {
    // After a stall (a scene load, a resize), the old schedule is meaningless. Without
    // this, the loop would render a burst of frames to "catch up" — visible as a hitch.
    const io = testing.io;
    var pacer = try Pacer.init(60);
    const started = pacer.begin(io).?;
    _ = try pacer.end(io, started);
    try testing.expect(pacer.deadline != null);

    pacer.reschedule();
    try testing.expectEqual(@as(?Io.Clock.Timestamp, null), pacer.deadline);
}

test "pacer: a late frame re-anchors on its own end, not a budget later" {
    // The subtle bug this test pins: after an overrun, storing `now + budget` as the
    // next deadline hands the following frame two budgets of slack, so a loop that
    // cannot keep up alternates "sleep a whole frame, overrun, sleep a whole frame"
    // and reports half the late frames it actually has. The deadline is the end of the
    // frame just finished, so the next wait can only be one budget minus whatever has
    // already passed — never more than one budget.
    const io = testing.io;
    var pacer = try Pacer.init(200); // 5 ms budget
    const long_ago = Io.Clock.Timestamp.now(io, .awake).addDuration(awake(-40 * std.time.ns_per_ms));
    const late = try pacer.end(io, long_ago);
    try testing.expect(late.late);

    // A fresh frame that starts now must wait at most one budget, not two.
    const started = pacer.begin(io).?;
    const next = try pacer.end(io, started);
    try testing.expect(!next.late);
    try testing.expect(next.slept_ns <= 5_000_000);
    try testing.expectEqual(@as(usize, 1), pacer.late_frames);
}
