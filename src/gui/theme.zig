//! Colours and metrics for the built-in widgets.
//!
//! A theme is a plain value: nothing global, nothing mutable, no lookup by name.
//! Widgets take a `*const Theme` so a host can swap it per frame (light editor,
//! dark editor) without the widgets knowing where it came from.
//!
//! The palette is deliberately small — one surface colour, one accent, and the
//! three button states — because every extra colour is one more thing an editor
//! must keep coherent. Derived states come from `canvas.shade`, so a theme author
//! sets the idle colour and gets hover/pressed for free unless they override them.

const canvas = @import("canvas.zig");

pub const Color = canvas.Color;
pub const Padding = @import("layout.zig").Padding;

pub const Theme = struct {
    /// Window/panel background.
    surface: Color = .{ 0x1e, 0x1f, 0x24, 0xff },
    /// One-pixel border around panels and controls.
    border: Color = .{ 0x3a, 0x3d, 0x46, 0xff },
    /// Primary text.
    text: Color = .{ 0xe6, 0xe7, 0xea, 0xff },
    /// Secondary text (labels on a filled accent, hints).
    text_muted: Color = .{ 0x9a, 0x9d, 0xa6, 0xff },
    /// Fill behind a focused or selected control.
    accent: Color = .{ 0x4c, 0x8d, 0xff, 0xff },
    /// Button fill when idle / hovered / pressed.
    button: Color = .{ 0x2b, 0x2e, 0x36, 0xff },
    button_hover: Color = .{ 0x35, 0x39, 0x44, 0xff },
    button_active: Color = .{ 0x4c, 0x8d, 0xff, 0xff },
    /// Slider groove and the filled part of it.
    track: Color = .{ 0x14, 0x15, 0x18, 0xff },
    /// Inner padding of a panel and of a button.
    panel_padding: Padding = Padding.all(6),
    button_padding: Padding = Padding.symmetric(6, 4),
    /// Space between items a layout stacks.
    spacing: i32 = 4,
    /// Height of a standard control row.
    row_height: i32 = 16,

    /// A light theme with the same structure, for editors on a white background.
    pub fn light() Theme {
        return .{
            .surface = .{ 0xf4, 0xf4, 0xf6, 0xff },
            .border = .{ 0xc4, 0xc6, 0xcc, 0xff },
            .text = .{ 0x1b, 0x1c, 0x20, 0xff },
            .text_muted = .{ 0x5a, 0x5d, 0x66, 0xff },
            .accent = .{ 0x1f, 0x5f, 0xd8, 0xff },
            .button = .{ 0xe4, 0xe5, 0xea, 0xff },
            .button_hover = .{ 0xd6, 0xd8, 0xde, 0xff },
            .button_active = .{ 0x1f, 0x5f, 0xd8, 0xff },
            .track = .{ 0xd0, 0xd2, 0xd8, 0xff },
        };
    }

    /// Text colour that reads on `background`: white on a dark fill, the theme's
    /// own text colour otherwise.
    pub fn textOn(self: Theme, background: Color) Color {
        const luma = 299 * @as(u32, background[0]) + 587 * @as(u32, background[1]) + 114 * @as(u32, background[2]);
        return if (luma < 140_000) .{ 0xff, 0xff, 0xff, 0xff } else self.text;
    }
};
