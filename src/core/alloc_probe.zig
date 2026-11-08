//! Allocator view for allocation-failure property tests.
//!
//! `std.testing.checkAllAllocationFailures` counts how many allocations a probe
//! makes with unlimited memory, then re-runs it once per index, failing that one
//! and everything after it. Two of its verdicts are layout traps rather than bugs:
//! a probe that grows and finishes early enough is reported as
//! `NondeterministicMemoryUsage`, and an in-place `resize`/`remap` that succeeds is
//! not counted as an allocation at all. So whenever a probe lets a `std` container
//! grow — an `ArrayList`, a `DynamicBitSetUnmanaged` (`ecs.Entities.create` resizes
//! one per slot), a hash map, a `std.json` arena — whether the allocator could
//! extend that buffer in place decides the count, and "in place" depends on the
//! heap the earlier probe passes left behind. The verdict then follows the heap
//! rather than the code under test, which is how a correct error path can fail the
//! test after an unrelated field is added to an unrelated struct.
//!
//! `Deterministic` removes that degree of freedom: it delegates allocation and
//! freeing untouched — so the harness still sees every byte, still detects leaks,
//! and still reaches every failure point — but refuses in-place *growth*, forcing
//! the alloc-copy-free path the harness counts. The number of allocations a probe
//! performs then depends only on the code path it takes.
//!
//! Test-only: this is not part of the engine's public surface and is not re-exported
//! from `corex.zig`; the probes that need it import the file directly.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Deterministic = struct {
    inner: Allocator,

    pub fn init(inner: Allocator) Deterministic {
        return .{ .inner = inner };
    }

    pub fn allocator(self: *Deterministic) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Deterministic = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }

    /// Shrink and same-size are delegated (they cannot change the allocation count);
    /// growth is refused so the caller re-allocates through `alloc`, which is counted.
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Deterministic = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) return false;
        return self.inner.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Deterministic = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) return null;
        return self.inner.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Deterministic = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(buf, alignment, ra);
    }
};

/// `std.testing.checkAllAllocationFailures` over a `Deterministic` view of
/// `std.testing.allocator`: the harness still counts and still fails one
/// allocation at a time, but no pass can save an allocation by growing a buffer
/// where the previous pass had to move it. Call sites use this instead of the
/// standard harness so that a verdict means "this code handles OutOfMemory" and
/// never "this code handled it on this heap layout".
pub fn check(comptime probe: anytype, extra: anytype) !void {
    var view = Deterministic.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(view.allocator(), probe, extra);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

// Growing the same list through `Deterministic` costs the same number of
// allocations whether the heap right before it is empty or freshly freed: the
// count is a property of the code, which is what the harness contract needs.
fn grownListAllocations(gpa: Allocator) !usize {
    var counter = testing.FailingAllocator.init(gpa, .{});
    const counted = counter.allocator();
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(counted);
    for (0..200) |i| try list.append(counted, @intCast(i));
    return counter.alloc_index;
}

test "alloc_probe: growth through the view costs the same on any heap layout" {
    const gpa = testing.allocator;

    var expected: ?usize = null;
    for (0..8) |round| {
        // Change what the heap looks like before the probe: a large buffer
        // allocated and freed leaves a block a plain allocator could extend into.
        if (round % 2 == 1) {
            const filler = try gpa.alloc(u8, 1 << 16);
            gpa.free(filler);
        }
        var view = Deterministic.init(gpa);
        const count = try grownListAllocations(view.allocator());
        if (expected) |e| try testing.expectEqual(e, count) else expected = count;
    }
}

// What the view refuses is growth in place, and nothing else: an allocation
// request still reaches the inner allocator, a failed one is still
// `OutOfMemory`, and a buffer is still freeable at the length it came back with.
test "alloc_probe: growth is refused, allocation and freeing are delegated" {
    var view = Deterministic.init(testing.allocator);
    const gpa = view.allocator();

    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);
    try testing.expectEqual(@as(usize, 64), buf.len);

    try testing.expectEqual(false, gpa.resize(buf, 128));
    try testing.expectEqual(null, gpa.remap(buf, 128));

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var inner_view = Deterministic.init(failing.allocator());
    try testing.expectError(error.OutOfMemory, inner_view.allocator().alloc(u8, 1));
}
