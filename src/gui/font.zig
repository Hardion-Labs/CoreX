//! Built-in 8x8 bitmap font.
//!
//! The GUI cannot depend on a system font, a platform text stack or an asset
//! pipeline that does not exist yet, so the smallest useful thing is a **built-in
//! glyph atlas**: printable ASCII (0x20–0x7E), one byte per row, MSB = leftmost
//! pixel, 8x8 cells. It is deliberately a data table plus pure lookup — no
//! allocation, no I/O, no platform call — so text layout is testable everywhere.
//!
//! Every glyph is authored on a 6x7 grid inside the 8x8 cell (the classic
//! terminal proportions), which leaves a one-pixel column of spacing to the right
//! and a descender row below. `line_height` is 8 and `cell_width` is 6, so text
//! advances by exactly the inked width plus one pixel of breathing room.
//!
//! Scope: ASCII only, no kerning, no ligatures, no bidi and no grapheme clusters.
//! Anything outside the table renders as `fallback` (a hollow box), which is the
//! honest behaviour until real shaping exists.

const std = @import("std");

/// Horizontal advance of one glyph, in pixels.
pub const cell_width: u32 = 6;
/// Vertical advance of one line, in pixels.
pub const line_height: u32 = 8;
/// Height of the inked glyph box, in pixels.
pub const glyph_height: u32 = 7;

/// The character drawn for anything outside the table.
pub const fallback: u8 = '?';

/// First and last code points the table covers.
pub const first_cp: u8 = 0x20;
pub const last_cp: u8 = 0x7e;

/// Number of glyphs in the table.
pub const glyph_count: usize = last_cp - first_cp + 1;

/// Rows for one glyph: 8 bytes, MSB first, top row first. Rows 0..6 are inked;
/// row 7 is the descender row and is zero for every glyph in this table.
pub const Glyph = [8]u8;

fn g(comptime rows: [7]u8) Glyph {
    return .{ rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], 0 };
}

/// The table, indexed by `cp - first_cp`.
pub const glyphs: [glyph_count]Glyph = blk: {
    @setEvalBranchQuota(200_000);
    // Zig 0.17 has no array-repetition operator, so the table starts zeroed and
    // every glyph is assigned explicitly below.
    var table: [glyph_count]Glyph = undefined;
    @memset(std.mem.asBytes(&table), 0);

    // --- ASCII 0x20..0x2F ---
    table[' ' - first_cp] = g(.{ 0, 0, 0, 0, 0, 0, 0 });
    table['!' - first_cp] = g(.{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x10 });
    table['"' - first_cp] = g(.{ 0x28, 0x28, 0x28, 0x00, 0x00, 0x00, 0x00 });
    table['#' - first_cp] = g(.{ 0x28, 0x28, 0x7c, 0x28, 0x7c, 0x28, 0x28 });
    table['$' - first_cp] = g(.{ 0x10, 0x3c, 0x50, 0x38, 0x14, 0x78, 0x10 });
    table['%' - first_cp] = g(.{ 0x60, 0x64, 0x08, 0x10, 0x20, 0x4c, 0x0c });
    table['&' - first_cp] = g(.{ 0x30, 0x48, 0x50, 0x20, 0x54, 0x48, 0x34 });
    table['\'' - first_cp] = g(.{ 0x10, 0x10, 0x10, 0x00, 0x00, 0x00, 0x00 });
    table['(' - first_cp] = g(.{ 0x08, 0x10, 0x20, 0x20, 0x20, 0x10, 0x08 });
    table[')' - first_cp] = g(.{ 0x20, 0x10, 0x08, 0x08, 0x08, 0x10, 0x20 });
    table['*' - first_cp] = g(.{ 0x00, 0x54, 0x38, 0x7c, 0x38, 0x54, 0x00 });
    table['+' - first_cp] = g(.{ 0x00, 0x10, 0x10, 0x7c, 0x10, 0x10, 0x00 });
    table[',' - first_cp] = g(.{ 0x00, 0x00, 0x00, 0x00, 0x30, 0x10, 0x20 });
    table['-' - first_cp] = g(.{ 0x00, 0x00, 0x00, 0x7c, 0x00, 0x00, 0x00 });
    table['.' - first_cp] = g(.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30 });
    table['/' - first_cp] = g(.{ 0x00, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00 });

    // --- digits 0x30..0x39 ---
    table['0' - first_cp] = g(.{ 0x38, 0x44, 0x4c, 0x54, 0x64, 0x44, 0x38 });
    table['1' - first_cp] = g(.{ 0x10, 0x30, 0x10, 0x10, 0x10, 0x10, 0x38 });
    table['2' - first_cp] = g(.{ 0x38, 0x44, 0x04, 0x08, 0x10, 0x20, 0x7c });
    table['3' - first_cp] = g(.{ 0x7c, 0x08, 0x10, 0x08, 0x04, 0x44, 0x38 });
    table['4' - first_cp] = g(.{ 0x08, 0x18, 0x28, 0x48, 0x7c, 0x08, 0x08 });
    table['5' - first_cp] = g(.{ 0x7c, 0x40, 0x78, 0x04, 0x04, 0x44, 0x38 });
    table['6' - first_cp] = g(.{ 0x18, 0x20, 0x40, 0x78, 0x44, 0x44, 0x38 });
    table['7' - first_cp] = g(.{ 0x7c, 0x04, 0x08, 0x10, 0x20, 0x20, 0x20 });
    table['8' - first_cp] = g(.{ 0x38, 0x44, 0x44, 0x38, 0x44, 0x44, 0x38 });
    table['9' - first_cp] = g(.{ 0x38, 0x44, 0x44, 0x3c, 0x04, 0x08, 0x30 });

    // --- 0x3A..0x40 ---
    table[':' - first_cp] = g(.{ 0x00, 0x30, 0x30, 0x00, 0x30, 0x30, 0x00 });
    table[';' - first_cp] = g(.{ 0x00, 0x30, 0x30, 0x00, 0x30, 0x10, 0x20 });
    table['<' - first_cp] = g(.{ 0x08, 0x10, 0x20, 0x40, 0x20, 0x10, 0x08 });
    table['=' - first_cp] = g(.{ 0x00, 0x00, 0x7c, 0x00, 0x7c, 0x00, 0x00 });
    table['>' - first_cp] = g(.{ 0x20, 0x10, 0x08, 0x04, 0x08, 0x10, 0x20 });
    table['?' - first_cp] = g(.{ 0x38, 0x44, 0x04, 0x08, 0x10, 0x00, 0x10 });
    table['@' - first_cp] = g(.{ 0x38, 0x44, 0x5c, 0x54, 0x5c, 0x40, 0x38 });

    // --- 0x41..0x5A uppercase ---
    table['A' - first_cp] = g(.{ 0x38, 0x44, 0x44, 0x7c, 0x44, 0x44, 0x44 });
    table['B' - first_cp] = g(.{ 0x78, 0x44, 0x44, 0x78, 0x44, 0x44, 0x78 });
    table['C' - first_cp] = g(.{ 0x38, 0x44, 0x40, 0x40, 0x40, 0x44, 0x38 });
    table['D' - first_cp] = g(.{ 0x78, 0x44, 0x44, 0x44, 0x44, 0x44, 0x78 });
    table['E' - first_cp] = g(.{ 0x7c, 0x40, 0x40, 0x78, 0x40, 0x40, 0x7c });
    table['F' - first_cp] = g(.{ 0x7c, 0x40, 0x40, 0x78, 0x40, 0x40, 0x40 });
    table['G' - first_cp] = g(.{ 0x38, 0x44, 0x40, 0x5c, 0x44, 0x44, 0x3c });
    table['H' - first_cp] = g(.{ 0x44, 0x44, 0x44, 0x7c, 0x44, 0x44, 0x44 });
    table['I' - first_cp] = g(.{ 0x38, 0x10, 0x10, 0x10, 0x10, 0x10, 0x38 });
    table['J' - first_cp] = g(.{ 0x1c, 0x08, 0x08, 0x08, 0x08, 0x48, 0x30 });
    table['K' - first_cp] = g(.{ 0x44, 0x48, 0x50, 0x60, 0x50, 0x48, 0x44 });
    table['L' - first_cp] = g(.{ 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7c });
    table['M' - first_cp] = g(.{ 0x44, 0x6c, 0x54, 0x54, 0x44, 0x44, 0x44 });
    table['N' - first_cp] = g(.{ 0x44, 0x64, 0x54, 0x4c, 0x44, 0x44, 0x44 });
    table['O' - first_cp] = g(.{ 0x38, 0x44, 0x44, 0x44, 0x44, 0x44, 0x38 });
    table['P' - first_cp] = g(.{ 0x78, 0x44, 0x44, 0x78, 0x40, 0x40, 0x40 });
    table['Q' - first_cp] = g(.{ 0x38, 0x44, 0x44, 0x44, 0x54, 0x48, 0x34 });
    table['R' - first_cp] = g(.{ 0x78, 0x44, 0x44, 0x78, 0x50, 0x48, 0x44 });
    table['S' - first_cp] = g(.{ 0x3c, 0x40, 0x40, 0x38, 0x04, 0x04, 0x78 });
    table['T' - first_cp] = g(.{ 0x7c, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10 });
    table['U' - first_cp] = g(.{ 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x38 });
    table['V' - first_cp] = g(.{ 0x44, 0x44, 0x44, 0x44, 0x44, 0x28, 0x10 });
    table['W' - first_cp] = g(.{ 0x44, 0x44, 0x44, 0x54, 0x54, 0x6c, 0x44 });
    table['X' - first_cp] = g(.{ 0x44, 0x44, 0x28, 0x10, 0x28, 0x44, 0x44 });
    table['Y' - first_cp] = g(.{ 0x44, 0x44, 0x28, 0x10, 0x10, 0x10, 0x10 });
    table['Z' - first_cp] = g(.{ 0x7c, 0x04, 0x08, 0x10, 0x20, 0x40, 0x7c });

    // --- 0x5B..0x60 ---
    table['[' - first_cp] = g(.{ 0x38, 0x20, 0x20, 0x20, 0x20, 0x20, 0x38 });
    table['\\' - first_cp] = g(.{ 0x00, 0x40, 0x20, 0x10, 0x08, 0x04, 0x00 });
    table[']' - first_cp] = g(.{ 0x38, 0x08, 0x08, 0x08, 0x08, 0x08, 0x38 });
    table['^' - first_cp] = g(.{ 0x10, 0x28, 0x44, 0x00, 0x00, 0x00, 0x00 });
    table['_' - first_cp] = g(.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c });
    table['`' - first_cp] = g(.{ 0x20, 0x10, 0x08, 0x00, 0x00, 0x00, 0x00 });

    // --- 0x61..0x7A lowercase ---
    table['a' - first_cp] = g(.{ 0x00, 0x00, 0x38, 0x04, 0x3c, 0x44, 0x3c });
    table['b' - first_cp] = g(.{ 0x40, 0x40, 0x78, 0x44, 0x44, 0x44, 0x78 });
    table['c' - first_cp] = g(.{ 0x00, 0x00, 0x3c, 0x40, 0x40, 0x40, 0x3c });
    table['d' - first_cp] = g(.{ 0x04, 0x04, 0x3c, 0x44, 0x44, 0x44, 0x3c });
    table['e' - first_cp] = g(.{ 0x00, 0x00, 0x38, 0x44, 0x7c, 0x40, 0x3c });
    table['f' - first_cp] = g(.{ 0x1c, 0x20, 0x7c, 0x20, 0x20, 0x20, 0x20 });
    table['g' - first_cp] = g(.{ 0x00, 0x3c, 0x44, 0x44, 0x3c, 0x04, 0x38 });
    table['h' - first_cp] = g(.{ 0x40, 0x40, 0x78, 0x44, 0x44, 0x44, 0x44 });
    table['i' - first_cp] = g(.{ 0x10, 0x00, 0x30, 0x10, 0x10, 0x10, 0x38 });
    table['j' - first_cp] = g(.{ 0x08, 0x00, 0x18, 0x08, 0x08, 0x48, 0x30 });
    table['k' - first_cp] = g(.{ 0x40, 0x40, 0x48, 0x50, 0x60, 0x50, 0x48 });
    table['l' - first_cp] = g(.{ 0x30, 0x10, 0x10, 0x10, 0x10, 0x10, 0x38 });
    table['m' - first_cp] = g(.{ 0x00, 0x00, 0x68, 0x54, 0x54, 0x54, 0x54 });
    table['n' - first_cp] = g(.{ 0x00, 0x00, 0x78, 0x44, 0x44, 0x44, 0x44 });
    table['o' - first_cp] = g(.{ 0x00, 0x00, 0x38, 0x44, 0x44, 0x44, 0x38 });
    table['p' - first_cp] = g(.{ 0x00, 0x78, 0x44, 0x44, 0x78, 0x40, 0x40 });
    table['q' - first_cp] = g(.{ 0x00, 0x3c, 0x44, 0x44, 0x3c, 0x04, 0x04 });
    table['r' - first_cp] = g(.{ 0x00, 0x00, 0x58, 0x64, 0x40, 0x40, 0x40 });
    table['s' - first_cp] = g(.{ 0x00, 0x00, 0x3c, 0x40, 0x38, 0x04, 0x78 });
    table['t' - first_cp] = g(.{ 0x20, 0x20, 0x7c, 0x20, 0x20, 0x20, 0x1c });
    table['u' - first_cp] = g(.{ 0x00, 0x00, 0x44, 0x44, 0x44, 0x44, 0x3c });
    table['v' - first_cp] = g(.{ 0x00, 0x00, 0x44, 0x44, 0x44, 0x28, 0x10 });
    table['w' - first_cp] = g(.{ 0x00, 0x00, 0x44, 0x54, 0x54, 0x54, 0x28 });
    table['x' - first_cp] = g(.{ 0x00, 0x00, 0x44, 0x28, 0x10, 0x28, 0x44 });
    table['y' - first_cp] = g(.{ 0x00, 0x44, 0x44, 0x44, 0x3c, 0x04, 0x38 });
    table['z' - first_cp] = g(.{ 0x00, 0x00, 0x7c, 0x08, 0x10, 0x20, 0x7c });

    // --- 0x7B..0x7E ---
    table['{' - first_cp] = g(.{ 0x0c, 0x10, 0x10, 0x20, 0x10, 0x10, 0x0c });
    table['|' - first_cp] = g(.{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10 });
    table['}' - first_cp] = g(.{ 0x30, 0x08, 0x08, 0x04, 0x08, 0x08, 0x30 });
    table['~' - first_cp] = g(.{ 0x00, 0x00, 0x32, 0x4c, 0x00, 0x00, 0x00 });

    break :blk table;
};

/// The glyph for `cp`, or `fallback` outside the table.
pub fn glyph(cp: u8) *const Glyph {
    if (cp < first_cp or cp > last_cp) return &glyphs[fallback - first_cp];
    return &glyphs[cp - first_cp];
}

/// Whether the glyph for `cp` has ink in `row` (`0..7`), `col` (`0..7`) being
/// counted from the left edge of the cell.
pub fn hasInk(cp: u8, row: u3, col: u3) bool {
    const rows = glyph(cp);
    const mask: u8 = @as(u8, 0x80) >> col;
    return (rows[row] & mask) != 0;
}

/// Inked width of a single line of `text`, in pixels: `0` for an empty string,
/// otherwise `(len - 1) * cell_width + inkedWidth(last glyph)`.
///
/// Trailing spaces are part of the advance (a caller may measure a padded label)
/// but contribute no ink of their own, which is what makes `measure("a ")` wider
/// than `measure("a")` yet still inside the same one-pixel spacing.
pub fn measure(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const last = text[text.len - 1];
    // Every glyph but the last advances a full cell. The last one contributes its own
    // ink so a label does not carry trailing padding -- except whitespace, which has
    // no ink and would otherwise measure as if it were not there at all.
    const last_width = if (last == ' ' or last == '\t') cell_width else inkWidth(last);
    return @as(u32, @intCast(text.len - 1)) * cell_width + last_width;
}

/// Width of the ink in one glyph's cell, `0..6`. Space is 0.
pub fn inkWidth(cp: u8) u32 {
    const rows = glyph(cp);
    var max_col: i32 = -1;
    for (rows) |bits| {
        if (bits == 0) continue;
        var col: i32 = 7;
        while (col >= 0) : (col -= 1) {
            const mask: u8 = @as(u8, 0x80) >> @intCast(col);
            if ((bits & mask) != 0) break;
        }
        if (col > max_col) max_col = col;
    }
    if (max_col < 0) return 0;
    return @intCast(max_col + 1);
}

/// Byte length of the longest line in `text` (lines separated by `\\n`).
pub fn longestLine(text: []const u8) usize {
    var longest: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            longest = @max(longest, i - start);
            start = i + 1;
        }
    }
    return longest;
}

/// Number of lines in `text`; an empty string is one (empty) line.
pub fn lineCount(text: []const u8) u32 {
    var lines: u32 = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    return lines;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "font: the table covers printable ASCII and leaves the rest to the fallback" {
    try testing.expectEqual(@as(usize, 95), glyph_count);
    // Every glyph of the table is addressable and distinct from the fallback in at
    // least the rows that carry information: a table entry that was never filled in
    // would be all-zero, which is what space legitimately is.
    var blank: usize = 0;
    for (glyphs) |rows| {
        var any = false;
        for (rows) |r| {
            if (r != 0) any = true;
        }
        if (!any) blank += 1;
    }
    try testing.expectEqual(@as(usize, 1), blank); // only the space
    // Outside the table everything maps to the fallback glyph.
    try testing.expectEqual(glyph(fallback), glyph(0x01));
    try testing.expectEqual(glyph(fallback), glyph(0xff));
    try testing.expect(glyph('A')[0] != 0);
}

test "font: ink is looked up per pixel and space has none" {
    // 'A' is 0x38 in row 0: the three middle pixels of an 8-wide cell.
    try testing.expect(!hasInk('A', 0, 0));
    try testing.expect(hasInk('A', 0, 2));
    try testing.expect(hasInk('A', 0, 3));
    try testing.expect(hasInk('A', 0, 4));
    try testing.expect(!hasInk('A', 0, 5));
    // A space carries no ink on any row or column.
    for (0..7) |row| {
        for (0..8) |col| try testing.expect(!hasInk(' ', @intCast(row), @intCast(col)));
    }
    // The descender row is empty for every glyph in this table, so a line of text
    // never needs the eighth row and `line_height` is a clean 8.
    for (glyphs) |rows| try testing.expectEqual(@as(u8, 0), rows[7]);
}

test "font: measurement is the advance of the glyphs, not a fixed cell grid" {
    try testing.expectEqual(@as(u32, 0), measure(""));
    // A single glyph is its own ink width: no trailing spacing is counted.
    try testing.expectEqual(inkWidth('I'), measure("I"));
    // Two glyphs: one full advance plus the second glyph's ink.
    try testing.expectEqual(cell_width + inkWidth('I'), measure("II"));
    // A trailing space has no ink but still advances, so a padded label measures
    // exactly one cell wider than the bare one instead of collapsing.
    try testing.expectEqual(measure("a") + cell_width, measure("a "));
    try testing.expectEqual(measure("ab"), measure("a b") - cell_width);
    // ... and the ink width of everything outside the table is the fallback box.
    try testing.expectEqual(inkWidth(fallback), inkWidth(0x00));
    // A tab is not in the table: it renders as the fallback and measures like it.
    try testing.expectEqual(inkWidth(fallback), inkWidth('\t'));
}

test "font: line helpers split on newlines, not on any other byte" {
    try testing.expectEqual(@as(u32, 1), lineCount(""));
    try testing.expectEqual(@as(u32, 1), lineCount("one"));
    try testing.expectEqual(@as(u32, 2), lineCount("one\ntwo"));
    try testing.expectEqual(@as(u32, 3), lineCount("a\n\nb"));
    try testing.expectEqual(@as(usize, 0), longestLine(""));
    try testing.expectEqual(@as(usize, 3), longestLine("a\nbcd\nef"));
    try testing.expectEqual(@as(usize, 2), longestLine("ab\n"));
}
