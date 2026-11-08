//! The inspector's editable numeric rows.
//!
//! A transform is three floats per row and a camera is one angle. Editing them from a
//! text field means: show the value, let the user type, parse on commit, and reject what
//! cannot be a value. That whole cycle lives here so the shell stays a composition layer
//! and the parsing rules are testable without a canvas.
//!
//! Three rules shape the code:
//!
//! * **The scene never sees half a keystroke.** Typing edits a buffer; only Enter (or a
//!   focus loss after a real change) produces a value, and an unparsable buffer produces
//!   nothing at all — the field reverts to what the scene holds.
//! * **A committed edit is one undoable command.** The three axes of a position are three
//!   fields, but changing one produces a single `set_component` with the other axes kept,
//!   so `Ctrl+Z` steps back over the whole value the user changed.
//!
//! A number can be typed or dragged, and both end the same way: a drag writes into the
//! same buffer typing writes into, so it is the *release* that commits, through the one
//! path above. Typing shows no live preview in the viewport and neither does dragging —
//! a row edits a number, which is what makes one rule enough for both.

const std = @import("std");
const canvas = @import("../gui/canvas.zig");
const font = @import("../gui/font.zig");
const input = @import("../gui/input.zig");
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

/// A number being dragged.
///
/// Like the viewport's drag state, this is a **value the shell owns** rather than a flag
/// inside the widget: "was this press a scrub or a click?" has to be answerable without a
/// pointer, and one drag can only be in progress across all the rows — so the slot is
/// shared by every row instead of copied into each one.
pub const Scrub = struct {
    /// The field the press landed on (`Id.zero` while nothing is being dragged).
    id: widgets.Id = .zero,
    /// Where the press happened, in canvas coordinates.
    origin: canvas.Point = .{},
    /// The value the field held when the press landed. Every frame measures from here, so
    /// a long drag cannot compound itself the way a per-frame delta would.
    start: f32 = 0,
    /// Whether the pointer has travelled enough to be a drag. Until it has, the press is
    /// still a possible click, and a click has to keep placing the caret.
    moved: bool = false,

    /// Pixels of travel per unit of value: ten for one unit, which is coarse enough to
    /// cross a room and fine enough to land on a half-metre.
    pub const units_per_pixel: f32 = 0.1;
    /// `Shift` divides the rate, for the last decimal.
    pub const fine_divisor: i32 = 10;

    pub fn owns(self: Scrub, id: widgets.Id) bool {
        return self.id.eql(id);
    }

    /// Whether some row already holds the gesture. A second press must not arm a second
    /// scrub, or releasing one would commit the other's number.
    pub fn busy(self: Scrub) bool {
        return self.id.value != 0;
    }

    pub fn begin(self: *Scrub, id: widgets.Id, at: canvas.Point, from: f32) void {
        self.* = .{ .id = id, .origin = at, .start = from };
    }

    /// Follow the pointer. Returns the value the field should hold, or `null` while the
    /// press has not moved enough to have been a drag.
    pub fn drag(self: *Scrub, at: canvas.Point, fine: bool) ?f32 {
        if (!self.moved and !input.travelled(self.origin, at)) return null;
        self.moved = true;
        // The dominant axis, so a horizontal drag does not also nudge the field next to it
        // and the gesture reads the same in a wide panel and a narrow one. Up is a gain,
        // because that is the only direction a vertical drag can sensibly mean.
        const dx: i32 = at.x - self.origin.x;
        const dy: i32 = at.y - self.origin.y;
        const px: i32 = if (@abs(dx) >= @abs(dy)) dx else -dy;
        const rate: f32 = units_per_pixel / @as(f32, @floatFromInt(if (fine) fine_divisor else 1));
        return self.start + @as(f32, @floatFromInt(px)) * rate;
    }

    /// Release the gesture. Returns whether a real scrub happened, i.e. whether there is a
    /// value worth committing at all.
    pub fn end(self: *Scrub) bool {
        const moved = self.moved;
        self.* = .{};
        return moved;
    }

    /// Drop the gesture with nothing to commit — what `Escape` means for a row.
    pub fn cancel(self: *Scrub) void {
        self.* = .{};
    }
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
    /// The shell's one gesture slot, shared by every row.
    scrub: *Scrub,
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

        // A press that travels edits the number; one that does not was a click, and the
        // caret placement the widget just did is all it does. This runs after the widget on
        // purpose: the press still takes focus the way any click takes focus, and only once
        // the GUI's drag threshold is behind it does the field start editing its own value.
        if (paint.scrub.owns(id)) {
            if (!ctx.input.pointer_down) {
                // Released. What the pointer dragged to is the number the user meant, so the
                // row commits through the same outcome typing uses; a press that never
                // travelled commits nothing, which is what keeps a click a click.
                if (paint.scrub.end()) {
                    outcome = .{ .commit = .{ .changed = changedMask(count, row) } };
                }
            } else if (paint.scrub.drag(ctx.input.pointer, ctx.input.modifiers.shift)) |value| {
                row.fields[i].set(value);
                // The drag owns the text this frame, so the caret sits at the end of what it
                // wrote instead of at the pixel under the pointer.
                row.fields[i].caret = row.fields[i].len;
            }
        } else if (!paint.scrub.busy() and response.pressed and ctx.input.pointer_pressed) {
            // Armed on the press frame, from whatever the buffer holds: a field mid-typing
            // scrubs from the number it would have committed, not from the scene's.
            paint.scrub.begin(id, ctx.input.pointer, row.fields[i].parsed() orelse 0);
        }

        if (response.focused) {
            // Enter commits the whole row; Escape restores every field from the scene.
            if (ctx.keyPressed(.enter)) {
                outcome = .{ .commit = .{ .changed = changedMask(count, row) } };
            } else if (ctx.keyPressed(.escape)) {
                // Abandoning the edit abandons a drag with it, or the release below would
                // commit the value Escape has just thrown away.
                if (paint.scrub.owns(id)) paint.scrub.cancel();
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

test "inspector scrub: a press becomes a drag only past the GUI's threshold" {
    var s = Scrub{};
    const id = widgets.Id.from(1, "pos");
    try testing.expect(!s.busy());

    s.begin(id, .{ .x = 100, .y = 50 }, 1);
    try testing.expect(s.busy());
    try testing.expect(s.owns(id));
    try testing.expect(!s.owns(widgets.Id.from(2, "pos")));

    // Exactly the threshold is still a click: two pixels in either axis have to leave the
    // number where it was, or a slow click would move a coordinate.
    try testing.expect(s.drag(.{ .x = 102, .y = 50 }, false) == null);
    try testing.expect(s.drag(.{ .x = 100, .y = 52 }, false) == null);
    try testing.expect(!s.moved);

    // Past it, ten pixels per unit measured from the press value.
    try testing.expectEqual(@as(f32, 4), s.drag(.{ .x = 130, .y = 50 }, false).?);
    try testing.expect(s.moved);

    // A release reports that there is something to commit, and frees the slot.
    try testing.expect(s.end());
    try testing.expect(!s.busy());
}

test "inspector scrub: the dominant axis, the fine modifier, and no compounding" {
    var s = Scrub{};
    const id = widgets.Id.from(1, "pos");

    // A vertical drag means the same thing: up is a gain.
    s.begin(id, .{ .x = 0, .y = 0 }, 1);
    try testing.expectEqual(@as(f32, 3), s.drag(.{ .x = 0, .y = -20 }, false).?);

    // The bigger axis wins, so a drag aimed at a column does not also nudge its neighbour.
    s.begin(id, .{ .x = 0, .y = 0 }, 0);
    try testing.expectEqual(@as(f32, 2), s.drag(.{ .x = 10, .y = -20 }, false).?);
    // Ties go horizontal, which is the axis the row is laid out along: at equal magnitudes
    // the two axes mean opposite things here, so this pins the choice rather than allowing
    // either answer.
    s.begin(id, .{ .x = 0, .y = 0 }, 0);
    try testing.expectEqual(@as(f32, -2), s.drag(.{ .x = -20, .y = -20 }, false).?);

    // Shift divides the rate: a hundred pixels is one unit, not ten.
    s.begin(id, .{ .x = 0, .y = 0 }, 0);
    try testing.expectEqual(@as(f32, 1), s.drag(.{ .x = 100, .y = 0 }, true).?);

    // Every frame measures from the press, so revisiting a pixel cannot creep: the same
    // position has to give the same number however many frames it takes to get there.
    s.begin(id, .{ .x = 0, .y = 0 }, 1);
    _ = s.drag(.{ .x = 30, .y = 0 }, false).?;
    try testing.expectEqual(@as(f32, 4), s.drag(.{ .x = 30, .y = 0 }, false).?);
    try testing.expectEqual(@as(f32, 1), s.drag(.{ .x = 0, .y = 0 }, false).?);

    // Cancelling (Escape) leaves nothing to commit.
    s.cancel();
    try testing.expect(!s.busy());
    try testing.expect(!s.end());
}

test "inspector scrub: what a drag writes is a value the field can print and parse" {
    var s = Scrub{};
    var field = Field{};
    field.set(-2.5);
    s.begin(widgets.Id.from(1, "pos"), .{ .x = 0, .y = 0 }, field.parsed().?);

    // Dragged 15 px right from -2.5: -1 exactly, which is what the row will commit.
    const value = s.drag(.{ .x = 15, .y = 0 }, false).?;
    field.set(value);
    try testing.expectEqualStrings("-1", field.text());
    try testing.expectEqual(@as(f32, -1), field.parsed().?);
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
