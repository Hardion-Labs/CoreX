//! Headless GUI frame renderer: paints one frame of real widgets into an RGBA8
//! buffer with no window, and writes it as a QOI file.
//!
//! This is the verifiable end of the GUI stack. Everything below the frame
//! (`font`, `canvas`, `text`, `layout`, `widgets`) is pure computation, so a frame
//! can be produced and inspected anywhere — in CI, in a terminal-only sandbox, or
//! by an editor that wants to snapshot its own layout. It is also the honest
//! demonstration of the widget layer: the same calls an editor shell will make,
//! driven by a synthetic input frame instead of a platform event queue.
//!
//!   zig build gui-frame -- out.qoi
//!
//! The output is QOI (already supported by `assets.image`) so any image viewer or
//! the engine's own decoder can read it.
const std = @import("std");
const corex = @import("corex");

const gui = corex.gui;
const Canvas = gui.canvas.Canvas;
const Rect = gui.canvas.Rect;
const Id = gui.widgets.Id;

const width: u32 = 220;
const height: u32 = 132;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.debug.print("gui-frame: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The optional output path is the first non-`argv[0]` argument.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| try args_list.append(gpa, arg);
    const out_path = if (args_list.items.len > 0) args_list.items[0] else "gui-frame.qoi";

    const pixels = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(pixels);
    var canvas = try Canvas.init(width, height, pixels);
    canvas.clear(.{ 0x12, 0x12, 0x14, 0xff });

    // Hit-test tables, one slot per widget per frame. Sized generously so the
    // demo never silently drops a widget.
    var entries: [32]gui.widgets.Entry = @splat(undefined);
    var next: [32]gui.widgets.Entry = @splat(undefined);
    var ctx = gui.widgets.Context.init(canvas, .{}, .{}, &entries, &next);

    // One synthetic frame. The pointer sits over the primary button so the render
    // shows the hover state, and the checkbox/slider/field carry real values.
    const frame_input: gui.input.Input = .{
        .pointer = .{ .x = 96, .y = 92 },
        .pointer_in_window = true,
    };

    // Two passes: the first records the widgets so the second can resolve which one
    // the pointer is over (hit-testing uses the previous frame, by design).
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        ctx.beginFrame(frame_input);
        drawEditor(&ctx, pass);
        ctx.endFrame();
    }

    const image = corex.assets.image.Image{ .width = width, .height = height, .pixels = pixels };
    const encoded = try corex.assets.image.encodeQoi(gpa, image);
    defer gpa.free(encoded);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = encoded });
    std.debug.print("gui-frame: {d}x{d}, {d} widgets, {d} bytes -> {s}\n", .{
        width, height, ctx.entry_count, encoded.len, out_path,
    });
}

/// The layout an editor sidebar would use: title panel, label, button row, then a
/// checkbox, a slider and a text field, all stacked by `Layout`.
fn drawEditor(ctx: *gui.widgets.Context, pass: usize) void {
    const theme = ctx.theme;

    const panel_rect = Rect.init(8, 8, width - 16, height - 16);
    const content = gui.widgets.panel(ctx, panel_rect, "CoreX GUI");
    var stack = gui.layout.Layout.init(content, .vertical).withSpacing(theme.spacing);

    const row = gui.layout.Size.init(content.w, theme.row_height);
    const label_rect = stack.measure(.{ .w = row.w, .h = @intCast(gui.font.line_height) });
    _ = gui.widgets.label(ctx, label_rect, "immediate mode, no window");

    const button_w = @divTrunc(row.w - theme.spacing, 2);
    var line = gui.layout.Layout.init(stack.measure(.{ .w = row.w, .h = theme.row_height }), .horizontal).withSpacing(theme.spacing);
    const b1 = gui.widgets.button(ctx, Id.from(1, "apply"), line.measure(.{ .w = button_w, .h = theme.row_height }), "Apply");
    _ = b1;
    const b2 = gui.widgets.button(ctx, Id.from(1, "reset"), line.measure(.{ .w = button_w, .h = theme.row_height }), "Reset");
    _ = b2;

    var enabled = pass == 1;
    _ = gui.widgets.checkbox(ctx, Id.from(2, "snap"), stack.measure(row), "snap to grid", &enabled);

    var amount: i32 = 35;
    _ = gui.widgets.slider(ctx, Id.from(3, "scale"), stack.measure(row), "scale", 0, 100, &amount);

    var name_storage: [16]u8 = @splat(0);
    var field = gui.widgets.TextField{ .buffer = &name_storage, .len = 9 };
    @memcpy(name_storage[0..9], "untitled1");
    field.caret = field.len;
    _ = gui.widgets.textField(ctx, Id.from(4, "name"), stack.measure(row), &field);

    // A separator and a muted hint fill the rest of the panel, which exercises the
    // "consume what is left" path a real sidebar needs for its footer.
    const rest = stack.fillRemaining();
    ctx.canvas.hline(rest.x, rest.y, rest.w, theme.border);
    _ = gui.widgets.label(ctx, Rect.init(rest.x, rest.y + 2, rest.w, @intCast(gui.font.line_height)), "esc to close");
}
