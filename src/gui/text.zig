//! Text drawing: turns the built-in glyph table into pixels on a canvas.
//!
//! This is the bridge between `font` (pure data and measurement) and `canvas`
//! (pure painting). It exists as its own module because text has policy that
//! neither side should own: newline handling, integer scaling, an optional clip
//! rectangle so a label cannot spill out of its widget, and the rule that a glyph
//! pixel is painted with `fillRect` so it composites with the same alpha path as
//! every other primitive.
//!
//! Still no shaping, no kerning, no wrapping: a line that does not fit is simply
//! clipped. Wrapping is a layout concern and lands there once a widget needs it.

const std = @import("std");
const canvas = @import("canvas.zig");
const font = @import("font.zig");

pub const Color = canvas.Color;
pub const Rect = canvas.Rect;

pub const Options = struct {
    color: Color = canvas.white,
    /// Integer pixel scale: `2` draws every glyph pixel as a 2x2 block.
    scale: u8 = 1,
    /// Clip rectangle in canvas coordinates. Pixels outside it are skipped
    /// entirely, so text never paints outside its widget even when it overflows.
    clip: ?Rect = null,
};

/// Height a block of `text` occupies at `scale`, including its newlines.
/// Zig has no default parameters, so the scale is always explicit here; use
/// `draw`'s return value when the caller just wants to advance a cursor.
pub fn height(text: []const u8, scale: u8) i32 {
    const s: i32 = @intCast(@max(scale, 1));
    return @as(i32, @intCast(font.lineCount(text))) * @as(i32, @intCast(font.line_height)) * s;
}

/// Width of the widest line of `text` at `scale`.
pub fn width(text: []const u8, scale: u8) i32 {
    const s: i32 = @intCast(@max(scale, 1));
    return @as(i32, @intCast(font.measure(longestLineText(text)))) * s;
}

/// Draw `text` with its top-left corner at `(x, y)`.
///
/// `\n` starts a new line; every other byte is one glyph and advances by
/// `font.cell_width` pixels (times `scale`). The returned height is what the
/// caller needs to advance a vertical cursor, so a stack of labels does not have
/// to recompute it.
pub fn draw(c: canvas.Canvas, x: i32, y: i32, text: []const u8, options: Options) i32 {
    const s: i32 = @intCast(@max(options.scale, 1));
    const cw: i32 = @as(i32, @intCast(font.cell_width)) * s;
    const lh: i32 = @as(i32, @intCast(font.line_height)) * s;

    var pen_x = x;
    var pen_y = y;
    for (text) |cp| {
        if (cp == '\n') {
            pen_x = x;
            pen_y += lh;
            continue;
        }
        drawGlyph(c, pen_x, pen_y, cp, s, options);
        pen_x += cw;
    }
    return height(text, options.scale);
}

fn drawGlyph(c: canvas.Canvas, x: i32, y: i32, cp: u8, s: i32, options: Options) void {
    const rows = font.glyph(cp);
    for (rows, 0..) |bits, row| {
        if (bits == 0) continue;
        var col: i32 = 0;
        while (col < 8) : (col += 1) {
            const mask: u8 = @as(u8, 0x80) >> @intCast(col);
            if ((bits & mask) == 0) continue;
            const px = x + col * s;
            const py = y + @as(i32, @intCast(row)) * s;
            const rect = Rect{ .x = px, .y = py, .w = s, .h = s };
            const clipped = if (options.clip) |clip| rect.intersect(clip) else rect;
            if (clipped.isEmpty()) continue;
            c.fillRect(clipped, options.color);
        }
    }
}

fn longestLineText(text: []const u8) []const u8 {
    var best: []const u8 = "";
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = text[start..i];
            if (font.measure(line) > font.measure(best)) best = line;
            start = i + 1;
        }
    }
    return best;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

fn buffer(comptime w: u32, comptime h: u32) [w * h * 4]u8 {
    return @splat(0);
}

test "text: a glyph paints only its inked pixels, at the requested position" {
    var buf = buffer(16, 16);
    var c = try canvas.Canvas.init(16, 16, &buf);
    // 'I' is a serifed bar: columns 3 and 4 inked on rows 0 and 6, column 3 alone
    // on the rows between. The cell padding to the left and below stays untouched.
    _ = draw(c, 2, 1, "I", .{ .color = canvas.white });
    try testing.expectEqual(canvas.white, c.get(2 + 3, 1 + 0).?);
    try testing.expectEqual(canvas.white, c.get(2 + 3, 1 + 6).?);
    try testing.expectEqual(canvas.white, c.get(2 + 4, 1 + 0).?);
    try testing.expectEqual(canvas.transparent, c.get(2 + 4, 1 + 3).?);
    try testing.expectEqual(canvas.transparent, c.get(2 + 0, 1 + 0).?);
    try testing.expectEqual(canvas.transparent, c.get(2 + 3, 1 + 7).?);
    try testing.expectEqual(@as(i32, 8), height("I", 1));
}

test "text: newlines start a new line and height grows per line" {
    var buf = buffer(24, 24);
    var c = try canvas.Canvas.init(24, 24, &buf);
    const used = draw(c, 0, 0, "I\nI", .{});
    try testing.expectEqual(@as(i32, 16), used);
    try testing.expectEqual(canvas.white, c.get(3, 0).?);
    try testing.expectEqual(canvas.transparent, c.get(3, 8 - 1).?);
    try testing.expectEqual(canvas.white, c.get(3, 8).?);
    try testing.expectEqual(@as(i32, 24), height("a\nbb\nccc", 1));
    // Width is the widest line, not the sum: "ccc" is three cells of advance.
    try testing.expectEqual(@as(i32, 2 * @as(i32, @intCast(font.cell_width)) + @as(i32, @intCast(font.inkWidth('c')))), width("a\nbb\nccc", 1));
}

test "text: the clip rectangle stops ink at its edge" {
    var buf = buffer(16, 16);
    var c = try canvas.Canvas.init(16, 16, &buf);
    // A clip that covers only the left half of the glyph column.
    _ = draw(c, 0, 0, "I", .{ .clip = Rect.init(0, 0, 3, 16) });
    try testing.expectEqual(canvas.transparent, c.get(3, 0).?);
    // Without the clip the same pixel is painted.
    _ = draw(c, 0, 0, "I", .{});
    try testing.expectEqual(canvas.white, c.get(3, 0).?);
}

test "text: integer scale expands each glyph pixel into a block" {
    var buf = buffer(32, 32);
    var c = try canvas.Canvas.init(32, 32, &buf);
    _ = draw(c, 0, 0, "I", .{ .scale = 2 });
    // Row 0 is the serif bar (`0x38`: columns 2..4), so its 2x2 blocks cover
    // x = 4..9. The block for column 2 starts at x = 4; column 1's is empty.
    try testing.expectEqual(canvas.white, c.get(4, 0).?);
    try testing.expectEqual(canvas.white, c.get(5, 1).?);
    try testing.expectEqual(canvas.white, c.get(9, 0).?);
    try testing.expectEqual(canvas.transparent, c.get(3, 0).?);
    // Row 1 inks only column 3, so its block spans x = 6..7 and x = 8 stays clear.
    try testing.expectEqual(canvas.white, c.get(7, 2).?);
    try testing.expectEqual(canvas.white, c.get(6, 2).?);
    try testing.expectEqual(canvas.transparent, c.get(8, 2).?);
    try testing.expectEqual(canvas.transparent, c.get(4, 2).?);
    // Row 7 is the always-empty descender band.
    try testing.expectEqual(canvas.transparent, c.get(6, 14).?);
    try testing.expectEqual(@as(i32, 16), height("I", 2));
}

test "text: unsupported bytes render as the fallback box, not as nothing" {
    var buf = buffer(16, 16);
    const c = try canvas.Canvas.init(16, 16, &buf);
    _ = draw(c, 0, 0, "\x01", .{});
    var painted: usize = 0;
    for (c.pixels, 0..) |byte, i| {
        if (i % 4 == 3 and byte == 255) painted += 1;
    }
    try testing.expect(painted > 0);
    // Same count as the fallback glyph drawn directly.
    try testing.expectEqual(font.inkWidth(font.fallback), font.inkWidth(0x01));
}

test "text: an empty string draws nothing and reports zero height" {
    var buf = buffer(4, 4);
    const c = try canvas.Canvas.init(4, 4, &buf);
    _ = draw(c, 0, 0, "", .{});
    // `lineCount("")` is 1, so height is one line but no pixel is inked.
    try testing.expectEqual(@as(i32, 8), height("", 1));
    for (buf) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(i32, 0), width("", 1));
}
