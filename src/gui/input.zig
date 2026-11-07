//! Input for the immediate-mode GUI: one frame's worth of events, already
//! resolved into the questions a widget asks.
//!
//! The host (an editor shell, or a test) fills an `Input` per frame: where the
//! pointer is, whether its button is down, the wheel delta, the keys pressed, and
//! where the keyboard focus is. Widgets never see platform events; they ask
//! "was I clicked", "am I hovered", "was I typed into". That keeps the whole
//! layer testable headlessly and keeps the platform binding — still blocked in
//! this sandbox — entirely out of the widget code.
//!
//! Consumption is explicit and monotonic. A widget that paints over another one
//! calls `claimPointer` when the pointer is inside it, so the widget underneath
//! sees `pointerAvailable == false` and does not react to the same click. The
//! order of that is the paint order: later (topmost) first, which is why the
//! `Context` propagates the claim backwards through the frame.

const std = @import("std");
const canvas = @import("canvas.zig");
const Rect = canvas.Rect;
const Point = canvas.Point;

/// Logical key identity, independent of scancode or platform.
pub const Key = enum {
    tab,
    enter,
    space,
    escape,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
};

pub const PointerButton = enum { left, right, middle };

/// What one frame observed. Built by the host, read by widgets.
pub const Input = struct {
    /// Pointer position in canvas coordinates.
    pointer: Point = .{},
    pointer_in_window: bool = false,
    pointer_down: bool = false,
    /// Set on the single frame where the button went down.
    pointer_pressed: bool = false,
    /// Set on the single frame where the button came up.
    pointer_released: bool = false,
    /// Wheel delta in notches: positive is up/away from the user.
    wheel: i32 = 0,
    /// Bytes typed this frame (printable ASCII and newline/nothing else).
    text: []const u8 = "",
    key: ?Key = null,
    modifiers: Modifiers = .{},

    /// Clear the one-frame events, keeping held state. A host calls this after
    /// presenting the frame; tests call it between synthetic frames.
    pub fn endFrame(self: *Input) void {
        self.pointer_pressed = false;
        self.pointer_released = false;
        self.wheel = 0;
        self.text = "";
        self.key = null;
    }
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

/// Where a widget stands, as far as input is concerned.
pub const Response = struct {
    /// This widget's rectangle, as laid out.
    rect: Rect,
    hovered: bool = false,
    /// Hovered and the primary button is down on this widget.
    pressed: bool = false,
    /// Pressed and released on this widget: the widget's action fires.
    clicked: bool = false,
    /// This widget holds keyboard focus for the frame.
    focused: bool = false,
    /// This widget owns the pointer, so nothing under it reacts.
    owns_pointer: bool = false,
    /// The pointer is inside but another widget above already claimed it.
    blocked: bool = false,
    /// Changed this frame (checkbox toggled, slider moved, text edited).
    changed: bool = false,

    /// Whether the widget should visually react to the pointer.
    pub fn isHovered(self: Response) bool {
        return self.hovered and !self.blocked;
    }
};

test "input: one-frame events are cleared and held state survives" {
    var input = Input{
        .pointer = .{ .x = 4, .y = 5 },
        .pointer_down = true,
        .pointer_pressed = true,
        .pointer_released = true,
        .wheel = 3,
        .text = "ab",
        .key = .enter,
    };
    input.endFrame();
    try testing.expect(input.pointer_down);
    try testing.expectEqual(Point{ .x = 4, .y = 5 }, input.pointer);
    try testing.expect(!input.pointer_pressed);
    try testing.expect(!input.pointer_released);
    try testing.expectEqual(@as(i32, 0), input.wheel);
    try testing.expectEqual(@as(usize, 0), input.text.len);
    try testing.expectEqual(@as(?Key, null), input.key);
}

test "response: a blocked widget is neither hovered for painting nor for input" {
    const r = Response{ .rect = Rect.init(0, 0, 10, 10), .hovered = true, .blocked = true };
    try testing.expect(!r.isHovered());
    const own = Response{ .rect = Rect.init(0, 0, 10, 10), .hovered = true };
    try testing.expect(own.isHovered());
}

const testing = std.testing;
