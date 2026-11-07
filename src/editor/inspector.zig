//! The inspector's editable numeric rows.
//!
//! A transform is three floats per row and a camera is one angle. Editing them from a
//! text field means: show the value, let the user type, parse on commit, and reject what
//! cannot be a value. That whole cycle lives here so the shell stays a composition layer
//! and the parsing rules are testable without a canvas.
//!
//! Two rules shape the code:
//!
//! * **The scene never sees half a keystroke.** Typing edits a buffer; only Enter (or a
//!   focus loss after a real change) produces a value, and an unparsable buffer produces
//!   nothing at all — the field reverts to what the scene holds.
//! * **A committed edit is one undoable command.** The three axes of a position are three
//!   fields, but changing one produces a single `set_component` with the other axes kept,
//!   so `Ctrl+Z` steps back over the whole value the user changed.

const std = @import("std");
const canvas = @import("../gui/canvas.zig");
const font = @import("../gui/font.zig");
const layout = @import("../gui/layout.zig");
const text = @import("../gui/text.zig");
const widgets = @import("../gui/widgets.zig");

const Rect = canvas.Rect;
const Theme = @import("../gui/theme.zig").Theme;

/// Most characters a numeric field accepts. Longer than any sane coordinate, short
/// enough that the buffer is a plain inline array.
pub const max_field_bytes = 24;

/// One editable number: the text being typed and where the caret is.
pub const Field = struct {
    buffer: [max_field_bytes]u8 = @splat(0),
    len: usize = 0,
    caret: usize = 0,

    pub fn set(self: *Field, value: f32) void {
        // `{d}` prints the shortest representation that round-trips, so a value the user
        // did not touch is not reformatted into something they would notice.
        const written = std.fmt.bufPrint(&self.buffer, "{d}", .{value}) catch "";
        self.len = written.len;
        self.caret = self.len;
    }

    /// The buffer's contents.
    ///
    /// Takes a pointer, not the value: a slice returned from a by-value `self` points at
    /// the *copy* the caller gets, which dies with the return. That is invisible in a
    /// small test and wrong the moment the caller keeps the slice.
    pub fn text(self: *const Field) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Parse the buffer. `null` covers an empty field, a lone `-`/`.` and anything the
    /// float parser rejects, and also non-finite results: `nan`/`inf` are not values a
    /// scene can hold, so accepting them would only defer the failure to serialization.
    pub fn parsed(self: *const Field) ?f32 {
        const value = std.fmt.parseFloat(f32, std.mem.trim(u8, self.text(), " \t")) catch return null;
        if (!std.math.isFinite(value)) return null;
        return value;
    }
};

/// A row of `count` fields under one label, e.g. `pos  x y z`.
///
/// `count` is comptime so the fields are inline storage rather than an allocation: the
/// inspector draws a fixed set of rows and must stay allocation-free per frame.
pub fn Row(comptime count: usize) type {
    return struct {
        const Self = @This();

        fields: [count]Field = @splat(.{}),
        /// Which field holds the keyboard (`count` when none does).
        focused: usize = count,
        /// Entity and component signature the buffers currently describe. When either
        /// changes the buffers are reloaded, so a selection change never shows the
        /// previous entity's numbers.
        owner: u64 = 0,
        signature: u64 = 0,

        pub fn isFocused(self: Self) bool {
            return self.focused < count;
        }

        /// Load every field from `values`.
        pub fn load(self: *Self, new_values: [count]f32) void {
            for (&self.fields, new_values) |*field, value| field.set(value);
            self.focused = count;
        }

        /// The values as they would be committed, or `null` if any field is not a number.
        pub fn values(self: *const Self) ?[count]f32 {
            var out: [count]f32 = undefined;
            for (&self.fields, 0..) |*field, i| out[i] = field.parsed() orelse return null;
            return out;
        }

        pub fn select(self: *Self, index: usize) void {
            self.focused = if (index < count) index else count;
        }
    };
}

/// What a drawn row asks its caller to do.
pub const Outcome = union(enum) {
    /// Nothing to commit.
    idle,
    /// The user committed a new value set for this row.
    commit: struct {
        /// Which axes carry a value, so a caller can tell a partially typed row from a
        /// complete one without a second copy of the fields.
        changed: u8 = 0,
    },
    /// The user asked to abandon the edit (Escape).
    escape,
};

/// Per-frame state the row painter needs that is not the row itself.
pub const Paint = struct {
    /// Stable ID of the entity the rows describe.
    entity_id: u64,
    /// A signature of the values on screen, so the buffers reload when the scene is
    /// changed by something other than this widget (undo, another command).
    signature: u64,
    /// Rows are laid out by the caller; this is the row's rectangle.
    key: []const u8,
};

/// Draw one numeric row and handle its typing.
///
/// Returns the commit request, if any. The caller owns the decision — it holds the
/// history and the component type — so this module never imports the scene.
pub fn drawRow(
    ctx: *widgets.Context,
    comptime count: usize,
    row: *Row(count),
    rect: Rect,
    paint: Paint,
    field_h: i32,
    seed: u64,
) Outcome {
    const theme = ctx.theme;
    const line_h: i32 = @intCast(font.line_height);

    // Reload whenever the entity or the underlying values changed, but never while the
    // user is typing: a reload mid-edit would erase what they are entering.
    const stale = row.owner != paint.entity_id or row.signature != paint.signature;
    if (stale and !row.isFocused()) {
        row.owner = paint.entity_id;
        row.signature = paint.signature;
    }

    const key_w: i32 = 40;
    const key_rect = Rect.init(rect.x, rect.y, @min(key_w, rect.w), line_h);
    _ = text.draw(ctx.canvas, key_rect.x, key_rect.y, paint.key, .{ .color = theme.text_muted, .clip = key_rect });

    const avail = @max(rect.w - key_w, 0);
    if (avail == 0 or count == 0) return .idle;
    const gap: i32 = 2;
    const cell = @divTrunc(@max(avail - gap * @as(i32, @intCast(count - 1)), 0), @as(i32, @intCast(count)));
    if (cell <= 0) return .idle;

    var outcome: Outcome = .idle;
    var focus_lost_with_change = false;

    inline for (0..count) |i| {
        const fx = rect.x + key_w + @as(i32, @intCast(i)) * (cell + gap);
        const field_rect = Rect.init(fx, rect.y, cell, field_h);
        const id = widgets.Id.from(seed + i, paint.key);
        var field = widgets.TextField{
            .buffer = &row.fields[i].buffer,
            .len = row.fields[i].len,
            .caret = row.fields[i].caret,
        };
        const before = row.fields[i].text();
        var snapshot: [max_field_bytes]u8 = @splat(0);
        const snapshot_len = before.len;
        @memcpy(snapshot[0..snapshot_len], before);

        const response = widgets.textField(ctx, id, field_rect, &field);
        row.fields[i].len = field.len;
        row.fields[i].caret = field.caret;
        if (response.focused) row.focused = i;

        if (response.focused) {
            // Enter commits the whole row; Escape restores every field from the scene.
            if (ctx.keyPressed(.enter)) {
                outcome = .{ .commit = .{ .changed = changedMask(count, row) } };
            } else if (ctx.keyPressed(.escape)) {
                outcome = .escape;
            }
            _ = ctx.claimTextInput();
        } else if (row.focused == i and !std.mem.eql(u8, snapshot[0..snapshot_len], row.fields[i].text())) {
            // Focus moved away after an edit: treat it as a commit, the way a form does,
            // so a value typed and then clicked away is not silently lost.
            focus_lost_with_change = true;
        }
    }

    if (outcome == .idle and focus_lost_with_change) {
        outcome = .{ .commit = .{ .changed = changedMask(count, row) } };
    }
    if (outcome == .idle and row.isFocused() and !ctx.input.pointer_down) {
        // Clicking outside the row's fields ends the edit; do not keep swallowing keys.
        var any_focused = false;
        inline for (0..count) |i| {
            const id = widgets.Id.from(seed + i, paint.key);
            if (ctx.focus.eql(id)) any_focused = true;
        }
        if (!any_focused) row.focused = count;
    }
    return outcome;
}

/// Which of the row's fields differ from zero — unused by the shell today, but the
/// commit needs *something* describing what was touched, and a mask is cheaper than a
/// second copy of the values.
fn changedMask(comptime count: usize, row: *const Row(count)) u8 {
    var mask: u8 = 0;
    for (&row.fields, 0..) |*field, i| {
        if (field.len > 0) mask |= @as(u8, 1) << @intCast(i);
    }
    return mask & ((@as(u8, 1) << @intCast(count)) - 1);
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "inspector field: prints and parses a value that round-trips" {
    var f = Field{};
    f.set(1.5);
    try testing.expectEqualStrings("1.5", f.text());
    try testing.expectEqual(@as(f32, 1.5), f.parsed().?);

    f.set(-0.25);
    try testing.expectEqual(@as(f32, -0.25), f.parsed().?);

    // Integer-valued floats print without a trailing ".0", which keeps the field narrow.
    f.set(3.0);
    try testing.expectEqualStrings("3", f.text());
    try testing.expectEqual(@as(f32, 3), f.parsed().?);
}

test "inspector field: rejects what cannot be a scene value" {
    var f = Field{};
    f.len = 0;
    try testing.expect(f.parsed() == null); // empty
    f.len = 1;
    f.buffer[0] = '-';
    try testing.expect(f.parsed() == null); // lone sign
    f.set(0);
    f.len = 3;
    @memcpy(f.buffer[0..3], "nan");
    try testing.expect(f.parsed() == null); // not a number
    f.len = 4;
    @memcpy(f.buffer[0..4], "1e40");
    try testing.expect(f.parsed() == null); // overflows f32 to infinity
    f.len = 1;
    f.buffer[0] = ' ';
    try testing.expect(f.parsed() == null); // blanks only
}

test "inspector row: loads, commits and reports a non-numeric field" {
    var row = Row(3){};
    row.load(.{ 1, 2, 3 });
    try testing.expectEqualStrings("1", row.fields[0].text());
    try testing.expectEqualStrings("3", row.fields[2].text());
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, &row.values().?);

    // One broken field makes the whole row uncommittable rather than committing a
    // partial value.
    row.fields[1].len = 1;
    row.fields[1].buffer[0] = 'x';
    try testing.expect(row.values() == null);

    // Selecting a field outside the row clears the focus rather than clamping to it.
    row.select(2);
    try testing.expect(row.isFocused());
    try testing.expectEqual(@as(usize, 2), row.focused);
    row.select(9);
    try testing.expect(!row.isFocused());
}

test "inspector row: a change mask names the fields that carry a value" {
    var row = Row(3){};
    row.load(.{ 0, 0, 0 });
    // "0" is a value, so all three fields are set — the mask is about presence, not
    // about being non-zero.
    try testing.expectEqual(@as(u8, 0b111), changedMask(3, &row));
    row.fields[1].len = 0;
    row.fields[2].len = 0;
    try testing.expectEqual(@as(u8, 0b001), changedMask(3, &row));
}
