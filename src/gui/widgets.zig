//! Immediate-mode widgets on top of `canvas`, `text`, `layout` and `input`.
//!
//! The model is the one ImGui made standard, reduced to what an editor actually
//! needs: a `Context` holds the frame's input, the theme, the canvas and the
//! bookkeeping (which widget is hot, active, focused); a widget is a function
//! that takes the context, an identity, a rect and a value, draws itself, and
//! returns a `Response` saying what the user did to it.
//!
//! Two behaviours are worth stating because they are what make the layer correct
//! rather than merely convenient:
//!
//! * **Identity is stable.** `Id` is derived from a caller-supplied seed plus a
//!   string, so the same button keeps its hot/active state across frames without
//!   the caller allocating anything or holding a pointer to a widget object.
//! * **A click is claimed once.** The topmost widget that the pointer is inside
//!   claims the pointer for the frame (`Input.claimPointer`); anything painted
//!   earlier in the frame (which is below it) sees `Response.blocked` and does not
//!   react. Without that, a button inside a panel would fire together with the
//!   panel behind it.
//!
//! There is no widget tree, no retained state per widget and no allocation: all
//! state lives in the `Context` for the duration of a frame plus a few scalars
//! the host keeps between frames (hot, active, focus).

const std = @import("std");
const canvas = @import("canvas.zig");
const font = @import("font.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const input_mod = @import("input.zig");
const theme_mod = @import("theme.zig");

pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const Padding = layout.Padding;
pub const Size = layout.Size;
pub const Layout = layout.Layout;
pub const Theme = theme_mod.Theme;
pub const Input = input_mod.Input;
pub const Response = input_mod.Response;
pub const Key = input_mod.Key;

/// Stable widget identity. Derived, never handed out by the caller.
pub const Id = struct {
    value: u64,

    pub fn from(seed: u64, name: []const u8) Id {
        var h = std.hash.Wyhash.init(seed);
        h.update(name);
        // A zero hash is never produced for a label in practice, but reserving it
        // gives `Id.zero` a meaning without a separate "valid" flag.
        return .{ .value = h.final() | 1 };
    }

    pub const zero: Id = .{ .value = 0 };

    pub fn eql(a: Id, b: Id) bool {
        return a.value == b.value;
    }
};

/// One painted widget, remembered for hit-testing.
///
/// The GUI paints back-to-front, so the widget that *wins* the pointer is the one
/// painted last, and which one that is only becomes known once the frame is
/// built. Recording each widget's rectangle and whether it is still reachable is
/// cheap (a host-sized table, no allocation) and makes pointer resolution a pure
/// function of the previous frame's paint order — which is why it can be tested
/// without a window.
pub const Entry = struct {
    id: Id,
    rect: Rect,
    /// False when an overlay painted above it covers the overlap, so the widget
    /// underneath cannot be reached by the pointer even though its rectangle
    /// still contains it.
    reachable: bool = true,
};

/// Frame state shared by every widget.
pub const Context = struct {
    canvas: canvas.Canvas,
    theme: Theme,
    input: Input,

    /// Widgets painted last frame, in paint order. Read at `beginFrame` to decide
    /// which widget the pointer is over.
    entries: []Entry = &.{},
    entry_count: usize = 0,
    /// Widgets painted this frame, in paint order. Separate from `entries` so the
    /// hit-test reads a complete, stable frame while the new one is built.
    next: []Entry = &.{},
    next_count: usize = 0,

    /// Widget the pointer is over, resolved from last frame's paint order.
    hot: Id = Id.zero,
    /// Widget holding the pointer across frames (a pressed button, a slider drag).
    active: Id = Id.zero,
    /// Keyboard focus.
    focus: Id = Id.zero,

    /// `entries` and `next` are supplied by the host, both the same length, so the
    /// GUI never allocates and a caller knows exactly what a frame may draw.
    pub fn init(c: canvas.Canvas, t: Theme, frame_input: Input, entries: []Entry, next: []Entry) Context {
        std.debug.assert(entries.len == next.len);
        return .{
            .canvas = c,
            .theme = t,
            .input = frame_input,
            .entries = entries,
            .next = next,
        };
    }

    /// Begin a frame with new input, resolving the pointer against last frame's
    /// widgets. No widgets have been painted before the first `endFrame`, so the
    /// very first frame reports no hover — the host draws one frame before input
    /// can act, which is one frame earlier than a window would show anyway.
    pub fn beginFrame(self: *Context, frame_input: Input) void {
        self.input = frame_input;
        self.next_count = 0;

        self.hot = Id.zero;
        if (frame_input.pointer_in_window) {
            var i = self.entry_count;
            while (i > 0) {
                i -= 1;
                const e = self.entries[i];
                if (!e.reachable) continue;
                if (!e.rect.containsPoint(frame_input.pointer)) continue;
                self.hot = e.id;
                break;
            }
        }
        if (frame_input.pointer_pressed) {
            // Pressing empty space drops both the drag and the focus.
            if (self.hot.eql(Id.zero)) self.active = Id.zero;
            self.focus = self.hot;
        }
    }

    /// End the frame: publish this frame's widgets for the next hit-test and drop
    /// a drag once the button is up.
    pub fn endFrame(self: *Context) void {
        const keep = @min(self.next_count, self.entries.len);
        @memcpy(self.entries[0..keep], self.next[0..keep]);
        self.entry_count = keep;
        if (!self.input.pointer_down) self.active = Id.zero;
    }

    /// Resolve pointer state for a widget and reserve its place in paint order.
    /// Widgets call this first, then paint, then return the `Response`.
    pub fn interact(self: *Context, id: Id, rect: Rect) Response {
        var r = Response{ .rect = rect };
        const inside = self.input.pointer_in_window and rect.containsPoint(self.input.pointer);
        const is_hot = self.hot.eql(id);
        const is_active = self.active.eql(id);

        r.hovered = inside;
        r.owns_pointer = inside and is_hot;
        r.blocked = inside and !is_hot;
        r.focused = self.focus.eql(id);

        if (r.owns_pointer and self.input.pointer_pressed) {
            self.active = id;
            self.focus = id;
            r.focused = true;
        }
        // A drag keeps reporting `pressed` when the pointer leaves the rectangle,
        // so a slider keeps following the pointer outside its own row.
        r.pressed = (is_active or r.owns_pointer) and self.input.pointer_down;
        r.clicked = is_active and self.input.pointer_released and inside;

        if (self.next_count < self.next.len) {
            self.next[self.next_count] = .{ .id = id, .rect = rect };
            self.next_count += 1;
        }
        return r;
    }

    /// Declare `rect` an overlay: everything painted *before* it that it covers
    /// stops being reachable, so the widgets underneath a modal dialog do not take
    /// clicks. Widgets painted after it (its own children) stay reachable, which is
    /// why this cannot simply block the rest of the frame.
    pub fn blockBelow(self: *Context, rect: Rect) void {
        var i: usize = 0;
        while (i < self.next_count) : (i += 1) {
            const e = &self.next[i];
            if (e.rect.intersects(rect) and !rect.containsRect(e.rect)) e.reachable = false;
        }
    }

    /// Move keyboard focus explicitly (a host restoring it, or Shift-Tab).
    pub fn setFocus(self: *Context, id: Id) void {
        self.focus = id;
    }

    /// Whether `key` was pressed this frame.
    ///
    /// `Input` carries one key per frame (the host reports the last one it saw), so this
    /// is a single comparison rather than a queue: a UI that must not miss two keys in
    /// one frame is a UI with two handlers, and the host decides which one wins.
    pub fn keyPressed(self: Context, key: input_mod.Key) bool {
        const got = self.input.key orelse return false;
        return got == key;
    }

    /// Declare that a widget consumed this frame's typed bytes, so a host does not also
    /// treat them as a shortcut. Returns whether there was anything typed.
    pub fn claimTextInput(self: *Context) bool {
        const had = self.input.text.len > 0;
        self.input.text = "";
        return had;
    }

    /// Slots left in this frame's table. A host can check it to warn instead of
    /// silently losing a widget's hit area.
    pub fn remainingSlots(self: Context) usize {
        return self.next.len - self.next_count;
    }
};

/// Draw a filled panel with a border and a title bar, and return the content
/// rectangle inside it. The panel does not intercept clicks by itself — it is a
/// background — so a button inside it still gets the pointer.
pub fn panel(ctx: *Context, rect: Rect, title: []const u8) Rect {
    const t = ctx.theme;
    ctx.canvas.fillRect(rect, t.surface);
    ctx.canvas.strokeRect(rect, t.border);

    var title_height: i32 = 0;
    if (title.len > 0) {
        title_height = @as(i32, @intCast(font.line_height)) + 2 * t.panel_padding.top;
        const bar = Rect.init(rect.x + 1, rect.y + 1, @max(rect.w - 2, 0), title_height - 1);
        ctx.canvas.fillRect(bar, t.button);
        _ = text.draw(
            ctx.canvas,
            bar.x + t.panel_padding.left,
            bar.y + t.panel_padding.top,
            title,
            .{ .color = t.text, .clip = bar },
        );
        title_height += 1;
    }

    const inner = Rect.init(
        rect.x + t.panel_padding.left,
        rect.y + title_height + t.panel_padding.top,
        @max(rect.w - t.panel_padding.horizontal(), 0),
        @max(rect.h - title_height - t.panel_padding.vertical(), 0),
    );
    return inner;
}

/// Draw a single line of text, clipped to `rect`. Returns the size the text
/// actually occupies so a caller can advance its own cursor.
pub fn label(ctx: *Context, rect: Rect, msg: []const u8) Size {
    const used = text.draw(ctx.canvas, rect.x, rect.y, msg, .{ .color = ctx.theme.text, .clip = rect });
    return .{ .w = layout.textSize(msg, 1).w, .h = used };
}

/// A push button. `clicked` on the frame the pointer is released inside it.
pub fn button(ctx: *Context, id: Id, rect: Rect, label_text: []const u8) Response {
    var r = ctx.interact(id, rect);
    const t = ctx.theme;
    const fill = if (r.pressed) t.button_active else if (r.isHovered()) t.button_hover else t.button;
    ctx.canvas.fillRect(rect, fill);
    ctx.canvas.strokeRect(rect, t.border);

    const content = t.button_padding.apply(rect);
    const ink = t.textOn(fill);
    const size = layout.textSize(label_text, 1);
    const x = content.x + @divTrunc(@max(content.w - size.w, 0), 2);
    const y = content.y + @divTrunc(@max(content.h - size.h, 0), 2);
    _ = text.draw(ctx.canvas, x, y, label_text, .{ .color = ink, .clip = content });
    if (r.focused) ctx.canvas.strokeRect(rect.inset(1), t.accent);
    r.changed = r.clicked;
    return r;
}

/// A checkbox with a label. Clicking anywhere in `rect` toggles `value`.
pub fn checkbox(ctx: *Context, id: Id, rect: Rect, label_text: []const u8, value: *bool) Response {
    var r = ctx.interact(id, rect);
    const t = ctx.theme;
    const box_size = @min(@as(i32, @intCast(font.line_height)), rect.h);
    const box = Rect.init(rect.x, rect.y + @divTrunc(rect.h - box_size, 2), box_size, box_size);

    ctx.canvas.fillRect(box, if (r.pressed) t.button_active else t.button);
    ctx.canvas.strokeRect(box, if (r.isHovered()) t.accent else t.border);
    if (value.*) {
        // A filled square inside the frame: legible at this size, and no glyph
        // dependency for a check mark the 8x8 table cannot draw crisply.
        ctx.canvas.fillRect(box.inset(2), t.accent);
    }
    const text_rect = Rect.init(box.right() + 4, rect.y, @max(rect.w - box_size - 4, 0), rect.h);
    const content = Rect.init(
        text_rect.x,
        text_rect.y + @divTrunc(@max(rect.h - @as(i32, @intCast(font.line_height)), 0), 2),
        text_rect.w,
        @as(i32, @intCast(font.line_height)),
    );
    _ = text.draw(ctx.canvas, content.x, content.y, label_text, .{ .color = t.text, .clip = content });

    if (r.clicked) {
        value.* = !value.*;
        r.changed = true;
    }
    if (r.focused and ctx.input.key == .space) {
        value.* = !value.*;
        r.changed = true;
    }
    return r;
}

/// A horizontal slider over `[min, max]`. Dragging updates `value` continuously
/// (integer steps) and reports `changed` on the frames it moved.
pub fn slider(ctx: *Context, id: Id, rect: Rect, label_text: []const u8, min: i32, max: i32, value: *i32) Response {
    var r = ctx.interact(id, rect);
    const t = ctx.theme;
    const lo = @min(min, max);
    const hi = @max(min, max);

    const label_size = layout.textSize(label_text, 1);
    const label_w = if (label_text.len == 0) 0 else label_size.w + 6;
    const track_rect = Rect.init(
        rect.x + label_w,
        rect.y + @divTrunc(@max(rect.h - 2, 0), 2),
        @max(rect.w - label_w, 1),
        2,
    );
    ctx.canvas.fillRect(track_rect, t.track);

    // Normalise a caller's out-of-range value once, up front: the knob and the
    // stored value can never disagree afterwards.
    value.* = clampInt(value.*, lo, hi);

    // All range arithmetic in i64: a full-range [min, max] pair overflows i32.
    const steps: i64 = @as(i64, hi) - @as(i64, lo);
    const knob_w: i32 = 6;
    const travel = @max(track_rect.w - knob_w, 0);
    const range: i64 = @max(steps, 1);
    const offset = if (hi == lo) 0 else blk: {
        const raw = @divTrunc((@as(i64, value.*) - lo) * @as(i64, travel), range);
        break :blk @as(i32, @intCast(std.math.clamp(raw, @as(i64, 0), @as(i64, travel))));
    };
    const knob = Rect.init(track_rect.x + clampInt(offset, 0, travel), rect.y, knob_w, rect.h);
    ctx.canvas.fillRect(knob, if (r.pressed) t.button_active else if (r.isHovered()) t.button_hover else t.button);
    ctx.canvas.strokeRect(knob, t.border);

    if (label_text.len > 0) {
        const label_rect = Rect.init(rect.x, rect.y, @max(label_w - 6, 0), rect.h);
        const y = rect.y + @divTrunc(@max(rect.h - label_size.h, 0), 2);
        _ = text.draw(ctx.canvas, label_rect.x, y, label_text, .{ .color = t.text_muted, .clip = label_rect });
    }

    if (r.pressed and travel > 0 and hi > lo) {
        const rel = clampInt(ctx.input.pointer.x - track_rect.x - @divTrunc(knob_w, 2), 0, travel);
        const next64 = @as(i64, lo) + @divTrunc(@as(i64, rel) * range + @as(i64, @divTrunc(travel, 2)), @as(i64, travel));
        const clamped = @as(i32, @intCast(std.math.clamp(next64, @as(i64, lo), @as(i64, hi))));
        if (clamped != value.*) {
            value.* = clamped;
            r.changed = true;
        }
    } else if (r.focused) {
        const step = switch (ctx.input.key orelse .escape) {
            .left => @as(i32, -1),
            .right => @as(i32, 1),
            .home => lo - value.*,
            .end => hi - value.*,
            else => 0,
        };
        if (step != 0) {
            const next = clampInt(value.* + step, lo, hi);
            if (next != value.*) {
                value.* = next;
                r.changed = true;
            }
        }
    }
    return r;
}

/// A single-line text field over a caller-owned fixed buffer.
///
/// `buffer` is the storage and `len` the number of valid bytes in it; the field
/// never reallocates, so a caller can size it exactly and the engine never has to
/// hand out a slice it owns. Returns the layout used so a caller can advance.
pub const TextField = struct {
    buffer: []u8,
    len: usize = 0,
    /// Caret position, in bytes, always within `0..len`.
    caret: usize = 0,
};

pub fn textField(ctx: *Context, id: Id, rect: Rect, field: *TextField) Response {
    var r = ctx.interact(id, rect);
    const t = ctx.theme;
    const focused = ctx.focus.eql(id);
    r.focused = focused;

    const content = Rect.init(rect.x + 4, rect.y, @max(rect.w - 8, 0), rect.h);
    const fill = if (focused) t.button_hover else t.button;
    ctx.canvas.fillRect(rect, fill);
    ctx.canvas.strokeRect(rect, if (focused) t.accent else t.border);

    if (focused) {
        applyTextInput(ctx.input, field);
    }

    // Scroll horizontally so the caret stays visible, without mutating the buffer.
    const cell: i32 = @intCast(font.cell_width);
    const caret_x = @as(i32, @intCast(field.caret)) * cell;
    const shift: i32 = if (caret_x > content.w - cell) caret_x - (content.w - cell) else 0;

    const y = rect.y + @divTrunc(@max(rect.h - @as(i32, @intCast(font.line_height)), 0), 2);
    _ = text.draw(ctx.canvas, content.x - shift, y, field.buffer[0..field.len], .{ .color = t.text, .clip = content });

    if (focused) {
        const cursor = Rect.init(content.x - shift + caret_x, y, 1, @as(i32, @intCast(font.glyph_height)));
        ctx.canvas.fillRect(cursor, t.accent);
    }

    if (r.clicked) {
        // Place the caret at the clicked byte.
        const rel = clampInt(ctx.input.pointer.x - content.x + shift, 0, @as(i32, @intCast(field.len)) * cell);
        field.caret = @intCast(@divTrunc(rel, cell));
        r.changed = false;
    }
    return r;
}

/// Apply this frame's typed bytes and editing keys to `field`. Exposed because a
/// caller may want the same editing rules on its own buffer.
pub fn applyTextInput(frame_input: Input, field: *TextField) void {
    if (field.caret > field.len) field.caret = field.len;
    for (frame_input.text) |byte| {
        if (byte < 0x20 or byte > 0x7e) continue;
        if (field.len >= field.buffer.len) break;
        var i = field.len;
        while (i > field.caret) : (i -= 1) field.buffer[i] = field.buffer[i - 1];
        field.buffer[field.caret] = byte;
        field.len += 1;
        field.caret += 1;
    }
    switch (frame_input.key orelse return) {
        .backspace => {
            if (field.caret > 0) {
                var i = field.caret - 1;
                while (i + 1 < field.len) : (i += 1) field.buffer[i] = field.buffer[i + 1];
                field.len -= 1;
                field.caret -= 1;
            }
        },
        .delete => {
            if (field.caret < field.len) {
                var i = field.caret;
                while (i + 1 < field.len) : (i += 1) field.buffer[i] = field.buffer[i + 1];
                field.len -= 1;
            }
        },
        .left => {
            if (field.caret > 0) field.caret -= 1;
        },
        .right => {
            if (field.caret < field.len) field.caret += 1;
        },
        .home => field.caret = 0,
        .end => field.caret = field.len,
        else => {},
    }
}

fn clampInt(value: i32, lo: i32, hi: i32) i32 {
    return layout.clampInt(value, lo, hi);
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// A headless frame: a small canvas plus the two hit-test tables a host would
/// own. Every widget test drives this instead of a window.
const Harness = struct {
    buffer: [96 * 96 * 4]u8 = @splat(0),
    entries: [16]Entry = @splat(undefined),
    next: [16]Entry = @splat(undefined),
    ctx: Context = undefined,

    fn init(self: *Harness) void {
        const c = canvas.Canvas.init(96, 96, &self.buffer) catch unreachable;
        self.ctx = Context.init(c, .{}, .{}, &self.entries, &self.next);
    }

    fn begin(self: *Harness, frame_input: Input) void {
        self.ctx.beginFrame(frame_input);
    }

    fn end(self: *Harness) void {
        self.ctx.endFrame();
    }

    /// Number of pixels with any alpha set, for "did this paint" assertions.
    fn painted(self: *Harness) usize {
        var count: usize = 0;
        for (self.buffer, 0..) |byte, i| {
            if (i % 4 == 3 and byte != 0) count += 1;
        }
        return count;
    }
};

const go_rect = Rect.init(2, 2, 20, 12);
const go_text = "Go";
const go_id = Id.from(7, "go");

fn clickAt(x: i32, y: i32) Input {
    return .{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .pointer_down = true, .pointer_pressed = true };
}
fn dragAt(x: i32, y: i32) Input {
    return .{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .pointer_down = true };
}
fn releaseAt(x: i32, y: i32) Input {
    return .{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .pointer_released = true };
}

test "widgets: an id is stable for the same label and differs for another" {
    try testing.expect(Id.from(1, "ok").eql(Id.from(1, "ok")));
    try testing.expect(!Id.from(1, "ok").eql(Id.from(1, "cancel")));
    try testing.expect(!Id.from(1, "ok").eql(Id.from(2, "ok")));
    try testing.expect(Id.from(0, "").value != Id.zero.value);
}

test "widgets: the first frame paints but cannot resolve hover yet" {
    var h = Harness{};
    h.init();
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 4, .y = 4 } });
    _ = button(&h.ctx, go_id, go_rect, go_text);
    h.end();

    try testing.expect(h.painted() > 0);
    try testing.expectEqual(@as(usize, 1), h.ctx.entry_count);
    try testing.expectEqual(go_id.value, h.ctx.entries[0].id.value);
    // Resolution reads last frame's table, which was empty.
    try testing.expect(Id.zero.eql(h.ctx.hot));
}

test "widgets: hover comes from the previous frame, press focuses, release clicks" {
    var h = Harness{};
    h.init();

    // Frame 1: pointer outside, button paints.
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 40, .y = 20 } });
    _ = button(&h.ctx, go_id, go_rect, go_text);
    h.end();
    try testing.expect(Id.zero.eql(h.ctx.hot));

    // Frame 2: pointer inside — now `hot`, because frame 1 recorded the rect.
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 5, .y = 5 } });
    const hovered = button(&h.ctx, go_id, go_rect, go_text);
    h.end();
    try testing.expect(go_id.eql(h.ctx.hot));
    try testing.expect(hovered.isHovered());
    try testing.expect(!hovered.clicked);

    // Frame 3: press inside — the button becomes active and takes focus.
    h.begin(clickAt(5, 5));
    const pressed = button(&h.ctx, go_id, go_rect, go_text);
    h.end();
    try testing.expect(go_id.eql(h.ctx.active));
    try testing.expect(go_id.eql(h.ctx.focus));
    try testing.expect(pressed.pressed);
    try testing.expect(!pressed.clicked);

    // Frame 4: release inside — that is the click, and the drag is over.
    h.begin(releaseAt(5, 5));
    const released = button(&h.ctx, go_id, go_rect, go_text);
    h.end();
    try testing.expect(released.clicked);
    try testing.expect(Id.zero.eql(h.ctx.active));

    // Frame 5: the frame after, nothing is clicked any more.
    h.begin(releaseAt(5, 5));
    const after = button(&h.ctx, go_id, go_rect, go_text);
    h.end();
    try testing.expect(!after.clicked);
}

test "widgets: a widget covered by a later one never sees the pointer" {
    var h = Harness{};
    h.init();
    const lower_id = Id.from(1, "lower");
    const upper_id = Id.from(1, "upper");
    const area = Rect.init(0, 0, 30, 20);

    // Paint both; the upper one is last, so it is topmost in the table.
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 4, .y = 4 } });
    _ = button(&h.ctx, lower_id, area, "A");
    _ = button(&h.ctx, upper_id, area, "B");
    h.end();

    h.begin(clickAt(4, 4));
    const lower = button(&h.ctx, lower_id, area, "A");
    const upper = button(&h.ctx, upper_id, area, "B");
    h.end();

    try testing.expect(upper_id.eql(h.ctx.active));
    try testing.expect(upper.pressed);
    try testing.expect(!lower.pressed);
    // The lower widget knows it is under the pointer but not in charge of it.
    try testing.expect(lower.hovered);
    try testing.expect(lower.blocked);
    try testing.expect(!lower.isHovered());

    h.begin(releaseAt(4, 4));
    const lower_up = button(&h.ctx, lower_id, area, "A");
    const upper_up = button(&h.ctx, upper_id, area, "B");
    h.end();
    try testing.expect(upper_up.clicked);
    try testing.expect(!lower_up.clicked);
}

test "widgets: blockBelow hides the widgets an overlay covers" {
    var h = Harness{};
    h.init();
    const under = Id.from(3, "under");
    const overlay = Rect.init(0, 0, 40, 24);

    // The button is wider than the dialog, so it is covered rather than contained.
    const big = Rect.init(0, 0, 60, 30);
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 5, .y = 5 } });
    _ = button(&h.ctx, under, big, "under");
    h.ctx.canvas.fillRect(overlay, .{ 0, 0, 0, 200 });
    h.ctx.blockBelow(overlay);
    h.end();
    try testing.expect(!h.ctx.entries[0].reachable);

    // The modal is on screen, so the button under it is not reachable any more.
    h.begin(clickAt(5, 5));
    _ = button(&h.ctx, under, big, "under");
    h.ctx.canvas.fillRect(overlay, .{ 0, 0, 0, 200 });
    h.ctx.blockBelow(overlay);
    h.end();
    try testing.expect(Id.zero.eql(h.ctx.hot));
}

test "widgets: blockBelow keeps a widget fully inside the overlay reachable" {
    var h = Harness{};
    h.init();
    const inner = Id.from(5, "inner");
    const inside = Rect.init(10, 10, 10, 8);
    const overlay = Rect.init(0, 0, 64, 32);

    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 12, .y = 12 } });
    // The inner widget is painted first but lies entirely inside the overlay, so a
    // dialog still gets its own controls: only widgets poking out are hidden.
    _ = button(&h.ctx, inner, inside, "in");
    h.ctx.blockBelow(overlay);
    h.end();
    try testing.expect(h.ctx.entries[0].reachable);

    h.begin(clickAt(12, 12));
    const r = button(&h.ctx, inner, inside, "in");
    h.ctx.blockBelow(overlay);
    h.end();
    try testing.expect(r.owns_pointer);
}

test "widgets: checkbox toggles on release and on space when focused" {
    var h = Harness{};
    h.init();
    var value = false;
    const rect = Rect.init(0, 0, 40, 12);
    const id = Id.from(9, "opt");

    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 3, .y = 3 } });
    _ = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();

    h.begin(clickAt(3, 3));
    _ = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();
    try testing.expect(!value); // pressing alone does not toggle

    h.begin(releaseAt(3, 3));
    const toggled = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();
    try testing.expect(value);
    try testing.expect(toggled.changed);
    try testing.expect(id.eql(h.ctx.focus));

    // Space toggles while focused, with the pointer out of the window entirely.
    h.begin(.{ .key = .space });
    _ = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();
    try testing.expect(!value);
}

test "widgets: checkbox click outside its rect does nothing" {
    var h = Harness{};
    h.init();
    var value = false;
    const rect = Rect.init(0, 0, 20, 10);
    const id = Id.from(9, "opt");
    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 50, .y = 25 } });
    _ = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();
    h.begin(releaseAt(50, 25));
    _ = checkbox(&h.ctx, id, rect, "opt", &value);
    h.end();
    try testing.expect(!value);
}

test "widgets: dragging a slider follows the pointer and clamps at both ends" {
    var h = Harness{};
    h.init();
    const rect = Rect.init(0, 0, 36, 10);
    const id = Id.from(4, "vol");
    var value: i32 = -1;

    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 18, .y = 4 } });
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();

    h.begin(clickAt(18, 4));
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    // The track spans the whole 36 px row, so the middle is about half the range.
    try testing.expect(value >= 4 and value <= 6);

    // Dragging past the right edge pins at the maximum, past the left at the minimum.
    h.begin(dragAt(80, 4));
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 10), value);

    h.begin(dragAt(-40, 4));
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 0), value);
}

test "widgets: a focused slider responds to arrows, home and end" {
    var h = Harness{};
    h.init();
    const rect = Rect.init(0, 0, 36, 10);
    const id = Id.from(4, "vol");
    var value: i32 = 5;
    h.ctx.focus = id;

    h.begin(.{ .key = .right });
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 6), value);

    h.begin(.{ .key = .end });
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 10), value);

    h.begin(.{ .key = .home });
    _ = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 0), value);

    // Already at the minimum: left is a no-op and reports no change.
    h.begin(.{ .key = .left });
    const no_move = slider(&h.ctx, id, rect, "", 0, 10, &value);
    h.end();
    try testing.expectEqual(@as(i32, 0), value);
    try testing.expect(!no_move.changed);
}

test "widgets: a text field inserts, deletes and never overflows its buffer" {
    var storage: [8]u8 = @splat(0);
    var field = TextField{ .buffer = &storage };

    try testing.expectEqual(@as(usize, 8), field.buffer.len);
    applyTextInput(.{ .text = "ab" }, &field);
    try testing.expectEqualStrings("ab", storage[0..field.len]);
    try testing.expectEqual(@as(usize, 2), field.caret);

    applyTextInput(.{ .key = .backspace }, &field);
    try testing.expectEqualStrings("a", storage[0..field.len]);

    applyTextInput(.{ .key = .home }, &field);
    applyTextInput(.{ .key = .left }, &field); // already at 0: stays
    try testing.expectEqual(@as(usize, 0), field.caret);

    // Insertion at the caret shifts the tail right.
    applyTextInput(.{ .text = ">" }, &field);
    try testing.expectEqualStrings(">a", storage[0..field.len]);
    applyTextInput(.{ .key = .delete }, &field);
    try testing.expectEqualStrings(">", storage[0..field.len]);

    // Non-printable bytes are dropped; the buffer refuses to grow past its length.
    applyTextInput(.{ .text = &[2]u8{ 0x01, 0x7f } }, &field);
    try testing.expectEqual(@as(usize, 1), field.len);
    applyTextInput(.{ .text = "1234567890" }, &field);
    try testing.expectEqual(@as(usize, 8), field.len);
    try testing.expectEqualStrings(">1234567", storage[0..field.len]);
    applyTextInput(.{ .key = .end }, &field);
    applyTextInput(.{ .key = .backspace }, &field);
    try testing.expectEqualStrings(">123456", storage[0..field.len]);
    try testing.expectEqual(@as(usize, 7), field.caret);
}

test "widgets: clicking a text field focuses it and positions the caret" {
    var h = Harness{};
    h.init();
    var storage: [8]u8 = @splat(0);
    var field = TextField{ .buffer = &storage };
    applyTextInput(.{ .text = "abc" }, &field);
    field.caret = 0;
    const rect = Rect.init(0, 0, 40, 12);
    const id = Id.from(11, "name");

    h.begin(.{ .pointer_in_window = true, .pointer = .{ .x = 2, .y = 4 } });
    _ = textField(&h.ctx, id, rect, &field);
    h.end();

    h.begin(clickAt(2 + 4 + 6, 4)); // 4 px inset + one cell: after 'a'
    _ = textField(&h.ctx, id, rect, &field);
    h.end();
    h.begin(releaseAt(2 + 4 + 6, 4));
    _ = textField(&h.ctx, id, rect, &field);
    h.end();
    try testing.expect(id.eql(h.ctx.focus));
    try testing.expectEqual(@as(usize, 1), field.caret);

    // Typing now happens at the caret.
    h.begin(.{ .text = "X" });
    _ = textField(&h.ctx, id, rect, &field);
    h.end();
    try testing.expectEqualStrings("aXbc", storage[0..field.len]);
}

test "widgets: a panel returns the content rect inside its border and title" {
    var h = Harness{};
    h.init();
    h.begin(.{});
    const content = panel(&h.ctx, Rect.init(0, 0, 60, 60), "T");
    h.end();

    const t = h.ctx.theme;
    const title_h = @as(i32, @intCast(font.line_height)) + 2 * t.panel_padding.top + 1;
    try testing.expectEqual(t.panel_padding.left, content.x);
    try testing.expectEqual(title_h + t.panel_padding.top, content.y);
    try testing.expectEqual(60 - t.panel_padding.horizontal(), content.w);
    try testing.expectEqual(60 - title_h - t.panel_padding.vertical(), content.h);
    // The panel is painted: surface inside the content area, border on the edge.
    try testing.expectEqual(t.surface, h.ctx.canvas.get(1, 40).?);
    try testing.expectEqual(t.border, h.ctx.canvas.get(0, 59).?);
}

test "widgets: a label is clipped to its rect instead of overflowing" {
    var h = Harness{};
    h.init();
    // A one-pixel row shows only the top glyph row: the text is cropped at the
    // rect, not allowed to spill into the rows below it.
    h.begin(.{});
    _ = label(&h.ctx, Rect.init(0, 0, 10, 1), "MMMMM");
    h.end();
    const clipped = h.painted();
    try testing.expect(clipped > 0);

    var h2 = Harness{};
    h2.init();
    h2.begin(.{});
    _ = label(&h2.ctx, Rect.init(0, 0, 10, 8), "MMMMM");
    h2.end();
    try testing.expect(h2.painted() > clipped);
    // Nothing was painted below the 1-pixel row.
    var y: usize = 1;
    while (y < 96) : (y += 1) {
        var x: usize = 0;
        while (x < 96) : (x += 1) {
            try testing.expectEqual(@as(u8, 0), h.buffer[(y * 96 + x) * 4 + 3]);
        }
    }
}

test "widgets: a full table drops the extra widgets instead of overflowing" {
    var h = Harness{};
    h.init();
    h.begin(.{});
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = button(&h.ctx, Id.from(i, "b"), Rect.init(0, 0, 4, 4), "b");
    }
    try testing.expectEqual(@as(usize, 0), h.ctx.remainingSlots());
    h.end();
    try testing.expectEqual(@as(usize, 16), h.ctx.entry_count);
}
