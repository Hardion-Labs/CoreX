//! Layout for the GUI: sizes, padding and a stacking cursor.
//!
//! The GUI is immediate-mode, so there is no retained tree to lay out. What a
//! widget needs instead is the next rectangle to occupy, in a direction, with
//! consistent padding and spacing, and the guarantee that nothing it is handed
//! runs outside the region it belongs to. That is the whole of this module: pure
//! integer arithmetic, no allocation, no canvas, no knowledge of input.
//!
//! Keeping it separate from `widgets` is deliberate. Layout is the part most
//! likely to be reused by a future retained-mode editor panel, and it is the part
//! that can be tested exhaustively without a single pixel being drawn.

const std = @import("std");
const font = @import("font.zig");
const Rect = @import("canvas.zig").Rect;

/// An extent with no position. Used for measured content and minimum sizes.
pub const Size = struct {
    w: i32 = 0,
    h: i32 = 0,

    pub const zero: Size = .{ .w = 0, .h = 0 };

    pub fn init(w: i32, h: i32) Size {
        return .{ .w = w, .h = h };
    }

    pub fn isEmpty(self: Size) bool {
        return self.w <= 0 or self.h <= 0;
    }

    /// Component-wise maximum: the size that fits both.
    pub fn max(a: Size, b: Size) Size {
        return .{ .w = @max(a.w, b.w), .h = @max(a.h, b.h) };
    }

    /// Component-wise minimum.
    pub fn min(a: Size, b: Size) Size {
        return .{ .w = @min(a.w, b.w), .h = @min(a.h, b.h) };
    }

    /// Grow by `pad`'s horizontal and vertical totals.
    pub fn padded(self: Size, pad: Padding) Size {
        return .{ .w = self.w + pad.horizontal(), .h = self.h + pad.vertical() };
    }

    /// Clamp into `[min, max]` per axis, without letting an inverted bound
    /// produce a negative extent.
    pub fn clamped(self: Size, minimum: Size, maximum: Size) Size {
        return .{
            .w = clampInt(self.w, minimum.w, maximum.w),
            .h = clampInt(self.h, minimum.h, maximum.h),
        };
    }
};

/// Clamp `value` into `[lo, hi]`, treating `hi < lo` as `hi = lo`.
pub fn clampInt(value: i32, lo: i32, hi: i32) i32 {
    const upper = @max(lo, hi);
    return @min(@max(value, lo), upper);
}

/// Edge insets. Uniform by default so the common case is one number.
pub const Padding = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub const zero: Padding = .{};

    pub fn all(v: i32) Padding {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn symmetric(h: i32, v: i32) Padding {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }

    pub fn horizontal(self: Padding) i32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Padding) i32 {
        return self.top + self.bottom;
    }

    pub fn add(a: Padding, b: Padding) Padding {
        return .{
            .top = a.top + b.top,
            .right = a.right + b.right,
            .bottom = a.bottom + b.bottom,
            .left = a.left + b.left,
        };
    }

    /// Shrink towards the centre: negative values grow the rectangle.
    pub fn sub(a: Padding, b: Padding) Padding {
        return a.add(.{ .top = -b.top, .right = -b.right, .bottom = -b.bottom, .left = -b.left });
    }

    /// The rectangle left after these insets, never inverted.
    pub fn apply(self: Padding, rect: Rect) Rect {
        return Rect.init(
            rect.x + self.left,
            rect.y + self.top,
            @max(rect.w - self.horizontal(), 0),
            @max(rect.h - self.vertical(), 0),
        );
    }
};

/// The direction a `Layout` stacks its children.
pub const Axis = enum { vertical, horizontal };

/// A cursor over a rectangle that hands out child rectangles in `axis` order.
///
/// The cursor only ever moves forward, so a widget cannot accidentally be given
/// the same space twice. Space that is not consumed by the end of a frame is
/// reported by `remaining`, which is what a panel uses to know how much room its
/// content left over (to place a footer, or fill a background).
pub const Layout = struct {
    rect: Rect,
    cursor: i32 = 0,
    spacing: i32 = 0,
    axis: Axis = .vertical,

    pub fn init(rect: Rect, axis: Axis) Layout {
        return .{ .rect = rect, .axis = axis };
    }

    pub fn withSpacing(self: Layout, spacing: i32) Layout {
        var copy = self;
        copy.spacing = @max(spacing, 0);
        return copy;
    }

    pub fn withPadding(self: Layout, pad: Padding) Layout {
        var copy = self;
        copy.rect = pad.apply(self.rect);
        return copy;
    }

    /// Extent still available along the axis.
    pub fn available(self: Layout) i32 {
        return switch (self.axis) {
            .vertical => @max(self.rect.h - self.cursor, 0),
            .horizontal => @max(self.rect.w - self.cursor, 0),
        };
    }

    /// Consume `size` along the axis and return the rectangle it occupies. The
    /// rectangle is always inside `rect`: a size larger than the space left is
    /// truncated rather than allowed to overflow, so a widget drawn into it
    /// cannot paint over its neighbours.
    pub fn measure(self: *Layout, size: Size) Rect {
        return self.measureClamped(size, .{ .w = self.rect.w, .h = self.rect.h });
    }

    /// `measure` with a maximum extent taken from the caller (a widget narrower
    /// than the row, for example).
    pub fn measureClamped(self: *Layout, size: Size, maximum: Size) Rect {
        if (self.cursor > 0) self.cursor += self.spacing;
        const room = self.available();
        const out = switch (self.axis) {
            .vertical => blk: {
                const h = clampInt(size.h, 0, @min(room, maximum.h));
                break :blk Rect.init(self.rect.x, self.rect.y + self.cursor, @min(size.w, maximum.w), h);
            },
            .horizontal => blk: {
                const w = clampInt(size.w, 0, @min(room, maximum.w));
                break :blk Rect.init(self.rect.x + self.cursor, self.rect.y, w, @min(size.h, maximum.h));
            },
        };
        self.cursor += switch (self.axis) {
            .vertical => out.h,
            .horizontal => out.w,
        };
        return out;
    }

    /// Everything not yet consumed, without advancing the cursor.
    pub fn remaining(self: Layout) Rect {
        return switch (self.axis) {
            .vertical => Rect.init(self.rect.x, self.rect.y + self.cursor, self.rect.w, self.available()),
            .horizontal => Rect.init(self.rect.x + self.cursor, self.rect.y, self.available(), self.rect.h),
        };
    }

    /// Consume everything that is left.
    pub fn fillRemaining(self: *Layout) Rect {
        const out = self.remaining();
        self.cursor = switch (self.axis) {
            .vertical => self.rect.h,
            .horizontal => self.rect.w,
        };
        return out;
    }

    pub fn reset(self: *Layout) void {
        self.cursor = 0;
    }
};

/// Size of a block of text at `scale`, measured the same way `text.draw` paints
/// it (widest line by `font.measure`, one `line_height` per line).
pub fn textSize(text: []const u8, scale: u8) Size {
    const s: i32 = @intCast(@max(scale, 1));
    const width = font.measure(longestLine(text));
    return .{
        .w = @as(i32, @intCast(width)) * s,
        .h = @as(i32, @intCast(font.lineCount(text))) * @as(i32, @intCast(font.line_height)) * s,
    };
}

fn longestLine(text: []const u8) []const u8 {
    var best: []const u8 = "";
    var best_width = font.measure(best);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = text[start..i];
            const w = font.measure(line);
            if (w > best_width) {
                best = line;
                best_width = w;
            }
            start = i + 1;
        }
    }
    return best;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "layout: a vertical stack advances by size plus spacing and stays inside" {
    var l = Layout.init(Rect.init(10, 20, 100, 50), .vertical).withSpacing(4);
    const a = l.measure(.{ .w = 40, .h = 10 });
    const b = l.measure(.{ .w = 40, .h = 10 });
    try testing.expectEqual(Rect.init(10, 20, 40, 10), a);
    try testing.expectEqual(Rect.init(10, 34, 40, 10), b);
    try testing.expectEqual(@as(i32, 50 - 24), l.available());
    try testing.expectEqual(Rect.init(10, 44, 100, 26), l.remaining());
}

test "layout: a horizontal stack advances along x and reports its remainder" {
    var l = Layout.init(Rect.init(0, 0, 30, 8), .horizontal).withSpacing(2);
    try testing.expectEqual(Rect.init(0, 0, 8, 8), l.measure(.{ .w = 8, .h = 8 }));
    try testing.expectEqual(Rect.init(10, 0, 8, 8), l.measure(.{ .w = 8, .h = 8 }));
    const rest = l.fillRemaining();
    try testing.expectEqual(Rect.init(18, 0, 12, 8), rest);
    try testing.expectEqual(@as(i32, 0), l.available());
}

test "layout: a child larger than the space left is truncated, never inverted" {
    var l = Layout.init(Rect.init(0, 0, 20, 10), .vertical);
    const first = l.measure(.{ .w = 100, .h = 100 });
    try testing.expectEqual(Rect.init(0, 0, 20, 10), first);
    try testing.expect(first.isEmpty() == false);
    // Nothing is left, so the next slot collapses rather than starting a new row.
    const second = l.measure(.{ .w = 5, .h = 5 });
    try testing.expectEqual(@as(i32, 0), second.h);
    try testing.expectEqual(@as(i32, 10), second.y);
}

test "layout: spacing applies between items but not before the first" {
    var l = Layout.init(Rect.init(0, 0, 10, 100), .vertical).withSpacing(6);
    try testing.expectEqual(Rect.init(0, 0, 10, 4), l.measure(.{ .w = 10, .h = 4 }));
    try testing.expectEqual(Rect.init(0, 10, 10, 4), l.measure(.{ .w = 10, .h = 4 }));
    l.reset();
    try testing.expectEqual(@as(i32, 0), l.measure(.{ .w = 1, .h = 1 }).y);
}

test "layout: padding insets the content rect and never inverts it" {
    const padded = Padding.all(4).apply(Rect.init(0, 0, 100, 40));
    try testing.expectEqual(Rect.init(4, 4, 92, 32), padded);
    // Insets larger than the rect collapse the extent; the origin still moves in,
    // which is harmless because an empty rect contains nothing and draws nothing.
    try testing.expectEqual(Rect.init(40, 40, 0, 0), Padding.all(40).apply(Rect.init(0, 0, 50, 20)));
    try testing.expectEqual(@as(i32, 12), Padding.symmetric(6, 4).horizontal());
    try testing.expectEqual(@as(i32, 8), Padding.symmetric(6, 4).vertical());
    const combined = Padding.all(2).add(Padding.symmetric(3, 0));
    try testing.expectEqual(@as(i32, 10), combined.horizontal());
    try testing.expectEqual(@as(i32, 4), combined.vertical());
    // Subtracting a padding grows the rect back out symmetrically.
    try testing.expectEqual(Rect.init(-2, -2, 14, 14), Padding.all(2).sub(Padding.all(2)).apply(Rect.init(-2, -2, 14, 14)));
}

test "layout: sizes clamp and pad predictably" {
    const s = Size.init(30, 10).clamped(.{ .w = 5, .h = 5 }, .{ .w = 20, .h = 20 });
    try testing.expectEqual(Size.init(20, 10), s);
    try testing.expectEqual(Size.init(10, 10), Size.init(4, 4).padded(Padding.all(3)));
    try testing.expectEqual(Size.init(9, 4), Size.init(9, 3).max(.{ .w = 2, .h = 4 }));
    // An inverted bound collapses rather than producing a negative extent.
    try testing.expectEqual(@as(i32, 5), clampInt(7, 5, 1));
    try testing.expectEqual(@as(i32, 9), clampInt(9, 0, 100));
}

test "layout: text measurement matches the font contract" {
    try testing.expectEqual(Size.init(0, 8), textSize("", 1));
    try testing.expectEqual(Size.init(11, 8), textSize("II", 1));
    // Widest line, and one line height per line: "a\nbbb\ncc" is "bbb" wide.
    try testing.expectEqual(Size.init(2 * 6 + @as(i32, @intCast(font.inkWidth('b'))), 24), textSize("a\nbbb\ncc", 1));
    try testing.expectEqual(Size.init(22, 16), textSize("II", 2));
}
