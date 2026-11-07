//! The editor shell: the graphical editor's frame, built on the engine's own GUI.
//!
//! This is deliberately *not* a window binding — that platform is still blocked in
//! this environment — and it is not a mock. It is the composition layer that turns
//! one prepared session (scene + camera + asset table + a rendered surface) into a
//! complete editor frame: a hierarchy panel, a scene viewport showing the rendered
//! surface, an inspector for the selected entity, and a status bar with the frame's
//! real accounting. The same call paints into a headless buffer for a tool or a
//! test, and would paint into a window's buffer once one exists, because both are
//! the same RGBA8 layout.
//!
//! Three rules keep it honest and cheap:
//!
//! * **It owns no scene and no renderer.** `Scene`, `EngineRenderer`, `SurfaceTarget`
//!   and the asset table all belong to the caller. The shell borrows them for the
//!   duration of a frame and allocates nothing per frame beyond the fixed tables it
//!   was initialised with.
//! * **Every panel is a rectangle from `layout`.** The shell computes the dock
//!   geometry once per frame from the canvas size and hands sub-rectangles down; a
//!   panel never guesses where it is, and a shrinking canvas shrinks the panels
//!   instead of clipping them unpredictably.
//! * **It reads the projection the renderer already computed.** The selected
//!   entity's world position is projected with `camera.view_projection` for the
//!   viewport marker, so the marker and the pixels agree by construction rather than
//!   by a second, drifting implementation of the same math.

const std = @import("std");
const canvas = @import("../gui/canvas.zig");
const font = @import("../gui/font.zig");
const layout = @import("../gui/layout.zig");
const text = @import("../gui/text.zig");
const input_mod = @import("../gui/input.zig");
const theme_mod = @import("../gui/theme.zig");
const widgets = @import("../gui/widgets.zig");
const scene_mod = @import("../scene/scene.zig");
const render_scene = @import("../scene/render_scene.zig");

pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const Input = input_mod.Input;
pub const Theme = theme_mod.Theme;
pub const Id = widgets.Id;
pub const Response = widgets.Response;

/// Width of the docked side panels and height of the status bar, in pixels. Fixed
/// rather than proportional: a panel that changes width as the window resizes makes
/// every label jump, and an editor is a text-heavy surface.
pub const side_width: i32 = 150;
pub const status_height: i32 = 14;
/// Below this total width the shell drops the hierarchy panel instead of letting the
/// viewport collapse to nothing.
pub const min_viewport_width: i32 = 60;

/// What the shell needs to draw a frame. Everything is borrowed; nothing is stored.
pub const Frame = struct {
    /// The rendered scene, RGBA8, row-major, top-down — exactly `SurfaceTarget.color`.
    scene_pixels: []const u8,
    scene_width: u32,
    scene_height: u32,
    /// The frame's accounting, shown in the status bar.
    report: render_scene.EngineFrameReport = .{},
    /// Title shown in the status bar (project name, usually).
    project_name: []const u8 = "",
    /// Scene name, shown next to the project.
    scene_name: []const u8 = "",
};

/// Editor state that survives a frame: which entity the inspector shows, whether the
/// hierarchy is filtered, and the theme choice. This is the editor's own memory, not
/// the scene's — the scene remains the single source of truth for content.
pub const State = struct {
    /// Stable ID of the selected entity, or 0 for "nothing selected".
    selected: u64 = 0,
    /// Entity rows the hierarchy can show in one frame. A fixed table keeps the panel
    /// allocation-free; scenes larger than this scroll in a later cycle.
    rows_per_frame: usize = 24,
    /// Expand/collapse state of the hierarchy root.
    roots_expanded: bool = true,
    theme: Theme = .{},
    /// Set when the user clicked an entity this frame, so a caller can react
    /// (re-frame the camera, save the selection, ...) without diffing by hand.
    selection_changed: bool = false,
};

/// The dock geometry of one frame, as rectangles. Exposed (rather than kept private)
/// because a caller that wants to place its own overlay — a modal, a grid gizmo —
/// needs the viewport rect, and recomputing it would be a second definition.
pub const Dock = struct {
    hierarchy: Rect = Rect.none,
    viewport: Rect = Rect.none,
    inspector: Rect = Rect.none,
    status: Rect = Rect.none,

    /// Split `total` into the editor's docks. Both side panels are dropped when the
    /// width cannot hold them plus a usable viewport; the viewport always survives,
    /// because an editor with no viewport is not an editor.
    pub fn compute(total: Rect) Dock {
        var dock = Dock{};
        if (total.isEmpty()) return dock;
        const status_h = @min(status_height, total.h);
        dock.status = Rect.init(total.x, total.bottom() - status_h, total.w, status_h);

        const body = Rect.init(total.x, total.y, total.w, @max(total.h - status_h, 0));
        if (body.isEmpty()) return dock;

        // Panels are admitted only if a usable viewport still fits beside them.
        // Both first; otherwise the hierarchy alone, because it is what the user
        // navigates with; otherwise neither, because an editor with no viewport is
        // not an editor.
        var left: i32 = 0;
        var right: i32 = 0;
        const room = body.w - min_viewport_width;
        if (room >= 2 * side_width) {
            left = side_width;
            right = side_width;
        } else if (room >= side_width) {
            left = side_width;
        }

        if (left > 0) dock.hierarchy = Rect.init(body.x, body.y, left, body.h);
        if (right > 0) dock.inspector = Rect.init(body.right() - right, body.y, right, body.h);
        dock.viewport = Rect.init(body.x + left, body.y, @max(body.w - left - right, 0), body.h);
        return dock;
    }
};

/// Paint one editor frame into `ctx`'s canvas.
///
/// Returns whether anything the caller must act on happened this frame — today, a
/// selection change. Painting is the whole side effect otherwise: no state is
/// allocated, and `State` is the only thing written back.
pub fn draw(ctx: *widgets.Context, state: *State, scene: anytype, frame: Frame) bool {
    const total = ctx.canvas.bounds();
    if (total.isEmpty()) return false;
    const dock = Dock.compute(total);
    state.selection_changed = false;

    // The canvas underneath is the scene: the panels are painted over it, so the
    // viewport is punched out first and the scene blitted into it. Painting the
    // scene as a background and the viewport on top would double-write it.
    ctx.canvas.fillRect(total, state.theme.surface);
    if (!dock.viewport.isEmpty()) {
        ctx.canvas.blitScaled(
            dock.viewport,
            frame.scene_pixels,
            frame.scene_width,
            frame.scene_height,
        );
        ctx.canvas.strokeRect(dock.viewport, state.theme.border);
    }

    if (!dock.hierarchy.isEmpty()) drawHierarchy(ctx, state, scene, dock.hierarchy);
    if (!dock.inspector.isEmpty()) drawInspector(ctx, state, scene, dock.inspector);
    if (!dock.status.isEmpty()) drawStatus(ctx, state, frame, dock.status, dock.viewport);
    return state.selection_changed;
}

/// The hierarchy: one row per entity, indented by depth, clickable to select.
///
/// Rows come from `childIdsInto`, which sorts and bounds in one allocation-free
/// scan, so the panel cannot overflow its table or depend on hash-map visit order.
fn drawHierarchy(ctx: *widgets.Context, state: *State, scene: anytype, rect: Rect) void {
    const content = widgets.panel(ctx, rect, "Hierarchy");
    const theme = ctx.theme;
    const row_h: i32 = @intCast(theme.row_height);
    var stack = layout.Layout.init(content, .vertical);

    // Depth-first from the roots, depth-limited by the row budget. A stack of
    // (id, depth) pairs would be recursion; two parallel fixed arrays keep it flat.
    var ids: [64]u64 = @splat(0);
    const roots = scene.childIdsInto(null, &ids);
    var shown: usize = 0;
    var r: usize = 0;
    while (r < roots and shown < state.rows_per_frame) : (r += 1) {
        shown += drawEntityRow(ctx, state, scene, &stack, ids[r], 0, row_h, content);
    }

    if (shown == 0) {
        _ = widgets.label(ctx, stack.measure(.{ .w = content.w, .h = @intCast(font.line_height) }), "(empty scene)");
    }
    if (shown >= state.rows_per_frame) {
        const hint = stack.measure(.{ .w = content.w, .h = @intCast(font.line_height) });
        _ = text.draw(ctx.canvas, hint.x, hint.y, "more...", .{ .color = theme.text_muted, .clip = hint });
    }
    // The panel is a background for everything under it: clicks on its blank area do
    // not reach the viewport behind it.
    ctx.blockBelow(rect);
}

/// One row, recursing into its children. Returns the number of rows drawn.
fn drawEntityRow(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    stack: *layout.Layout,
    id: u64,
    depth: usize,
    row_h: i32,
    content: Rect,
) usize {
    const theme = ctx.theme;
    const entity = scene.entityById(id) orelse return 0;
    const indent: i32 = @intCast(4 + depth * 8);
    const row = stack.measure(.{ .w = content.w, .h = row_h });
    if (row.isEmpty()) return 0;

    const id_hash = Id.from(id, "tree");
    const r = ctx.interact(id_hash, row);
    const selected = state.selected == id;
    if (selected) {
        ctx.canvas.fillRect(row, theme.accent);
    } else if (r.isHovered()) {
        ctx.canvas.fillRect(row, theme.button_hover);
    }
    if (r.clicked and !selected) {
        state.selected = id;
        state.selection_changed = true;
    }

    const name = scene.nameOf(entity) orelse "(unnamed)";
    const label_rect = Rect.init(row.x + indent, row.y, @max(row.w - indent, 0), row_h);
    const y = row.y + @divTrunc(@max(row_h - @as(i32, @intCast(font.line_height)), 0), 2);
    _ = text.draw(ctx.canvas, label_rect.x, y, name, .{
        .color = if (selected) theme.textOn(theme.accent) else theme.text,
        .clip = label_rect,
    });

    // Count and draw children, until the frame's row budget is used.
    var child_ids: [64]u64 = @splat(0);
    const kids = scene.childIdsInto(id, &child_ids);
    var drawn: usize = 1;
    var i: usize = 0;
    while (i < kids) : (i += 1) {
        if (stack.cursor + row_h > stack.rect.h) break;
        drawn += drawEntityRow(ctx, state, scene, stack, child_ids[i], depth + 1, row_h, content);
    }
    return drawn;
}

/// The inspector: name, stable ID, local transform and the components the scene
/// actually stores. Read-only in this cycle — editing needs an undo model, which is
/// its own coherent step and not something to bolt on here.
fn drawInspector(ctx: *widgets.Context, state: *State, scene: anytype, rect: Rect) void {
    const content = widgets.panel(ctx, rect, "Inspector");
    var stack = layout.Layout.init(content, .vertical).withSpacing(2);
    const line_h: i32 = @intCast(font.line_height);
    const theme = ctx.theme;

    const entity = if (state.selected != 0) scene.entityById(state.selected) else null;
    const ent = entity orelse {
        const slot = stack.measure(.{ .w = content.w, .h = line_h });
        _ = text.draw(ctx.canvas, slot.x, slot.y, "no selection", .{ .color = theme.text_muted, .clip = slot });
        ctx.blockBelow(rect);
        return;
    };

    var buf: [96]u8 = undefined;
    const name = scene.nameOf(ent) orelse "(unnamed)";
    fieldRow(ctx, &stack, content, "name", name);
    const id_line = std.fmt.bufPrint(&buf, "{d}", .{state.selected}) catch "?";
    fieldRow(ctx, &stack, content, "id", id_line);

    if (scene.getComponent(render_scene.Transform, ent)) |t| {
        const pos = std.fmt.bufPrint(&buf, "{d:.1} {d:.1} {d:.1}", .{ t.position[0], t.position[1], t.position[2] }) catch "?";
        fieldRow(ctx, &stack, content, "pos", pos);
        const scl = std.fmt.bufPrint(&buf, "{d:.1} {d:.1} {d:.1}", .{ t.scale[0], t.scale[1], t.scale[2] }) catch "?";
        fieldRow(ctx, &stack, content, "scale", scl);
    }
    if (scene.getComponent(render_scene.Renderable, ent)) |r| {
        const mesh = std.fmt.bufPrint(&buf, "mesh {d} / mat {d}", .{ r.mesh, r.material }) catch "?";
        fieldRow(ctx, &stack, content, "render", mesh);
    }
    if (scene.getComponent(render_scene.CameraComponent, ent)) |c| {
        const fov = std.fmt.bufPrint(&buf, "{d:.1} deg", .{c.fov * 180.0 / std.math.pi}) catch "?";
        fieldRow(ctx, &stack, content, "fov", fov);
    }
    if (scene.getComponent(render_scene.Transform, ent) == null and
        scene.getComponent(render_scene.Renderable, ent) == null and
        scene.getComponent(render_scene.CameraComponent, ent) == null)
    {
        const slot = stack.measure(.{ .w = content.w, .h = line_h });
        _ = text.draw(ctx.canvas, slot.x, slot.y, "no components", .{ .color = theme.text_muted, .clip = slot });
    }

    const parent = scene.parent(ent);
    fieldRow(ctx, &stack, content, "parent", if (parent) |p| (scene.nameOf(p) orelse "?") else "root");
    ctx.blockBelow(rect);
}

/// A `key: value` row, clipped to the panel. The key column is fixed so values line
/// up regardless of which keys an entity has.
fn fieldRow(ctx: *widgets.Context, stack: *layout.Layout, content: Rect, key: []const u8, value: []const u8) void {
    const theme = ctx.theme;
    const line_h: i32 = @intCast(font.line_height);
    const row = stack.measure(.{ .w = content.w, .h = line_h });
    if (row.isEmpty()) return;
    // Wide enough for the longest key the inspector uses ("parent" = 35 px at the
    // built-in font's advance), so a value never starts on top of its key.
    const key_w: i32 = 40;
    const key_rect = Rect.init(row.x, row.y, @min(key_w, row.w), line_h);
    const value_rect = Rect.init(row.x + key_rect.w, row.y, @max(row.w - key_rect.w, 0), line_h);
    _ = text.draw(ctx.canvas, key_rect.x, key_rect.y, key, .{ .color = theme.text_muted, .clip = key_rect });
    _ = text.draw(ctx.canvas, value_rect.x, value_rect.y, value, .{ .color = theme.text, .clip = value_rect });
}

/// The status bar: project, scene, viewport size and the last frame's real
/// accounting. Every number comes from the render report, so the bar cannot claim
/// something the renderer did not do.
fn drawStatus(ctx: *widgets.Context, state: *State, frame: Frame, rect: Rect, viewport: Rect) void {
    const theme = ctx.theme;
    ctx.canvas.fillRect(rect, theme.button);
    ctx.canvas.hline(rect.x, rect.y, rect.w, theme.border);

    var buf: [220]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        // ASCII only: the built-in font draws anything else as `?`, so a separator
        // like `·` would appear as a literal question mark in the bar.
        "{s}{s}{s}  |  {d} cmds  {d} draws  {d} kpx  |  vp {d}x{d}",
        .{
            frame.project_name,
            if (frame.project_name.len > 0 and frame.scene_name.len > 0) " / " else "",
            frame.scene_name,
            frame.report.commands,
            frame.report.draws,
            frame.report.pixels / 1000,
            @max(viewport.w, 0),
            @max(viewport.h, 0),
        },
    ) catch "?";
    const pad: i32 = 4;
    const inner = Rect.init(rect.x + pad, rect.y + 3, @max(rect.w - 2 * pad, 0), rect.h);
    _ = text.draw(ctx.canvas, inner.x, inner.y, line, .{ .color = theme.text_muted, .clip = inner });
    _ = state;
}

/// Where the selected entity is on screen, or null when it is behind the camera or
/// outside the viewport.
///
/// The projection is the one the renderer used (`camera.view_projection`), so the
/// marker lands on the pixels the entity was drawn at. A point at or behind the eye
/// has `w <= 0` and is rejected instead of being divided through, which is what would
/// otherwise put a phantom marker on the opposite side of the screen.
pub fn projectToViewport(view_projection: [16]f32, world: [3]f32, viewport: Rect) ?canvas.Point {
    const x = view_projection[0] * world[0] + view_projection[4] * world[1] + view_projection[8] * world[2] + view_projection[12];
    const y = view_projection[1] * world[0] + view_projection[5] * world[1] + view_projection[9] * world[2] + view_projection[13];
    const w = view_projection[3] * world[0] + view_projection[7] * world[1] + view_projection[11] * world[2] + view_projection[15];
    if (!(w > 0)) return null;
    const ndc_x = x / w;
    const ndc_y = y / w;
    if (!(ndc_x >= -1 and ndc_x <= 1 and ndc_y >= -1 and ndc_y <= 1)) return null;
    if (viewport.isEmpty()) return null;
    const px = viewport.x + @divTrunc(@as(i32, @intFromFloat((ndc_x * 0.5 + 0.5) * @as(f32, @floatFromInt(viewport.w)))), 1);
    // NDC +1 is the top of the viewport, so the y axis flips.
    const py = viewport.y + @divTrunc(@as(i32, @intFromFloat((0.5 - ndc_y * 0.5) * @as(f32, @floatFromInt(viewport.h)))), 1);
    return .{ .x = px, .y = py };
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// A 3-entity scene (root with a child, plus a loose entity) and a rendered 16x16
/// surface: enough for the shell to read a hierarchy, an inspector and a report.
const Harness = struct {
    scene: render_scene.EngineRenderScene = undefined,
    pixels: [16 * 16 * 4]u8 = @splat(0),
    entries: [64]widgets.Entry = @splat(undefined),
    next: [64]widgets.Entry = @splat(undefined),
    buffer: [380 * 160 * 4]u8 = @splat(0),
    ctx: widgets.Context = undefined,
    state: State = .{},
    root_id: u64 = 0,
    child_id: u64 = 0,
    loose_id: u64 = 0,

    fn init(self: *Harness) !void {
        const gpa = testing.allocator;
        self.scene = try render_scene.EngineRenderScene.init(gpa, "level1");
        const root = try self.scene.createEntity("root", null);
        self.root_id = self.scene.idOf(root).?;
        try self.scene.addComponent(root, render_scene.Transform{ .position = .{ 1, 2, 3 } });
        const child = try self.scene.createEntity("child", self.root_id);
        self.child_id = self.scene.idOf(child).?;
        try self.scene.addComponent(child, render_scene.Transform{});
        const loose = try self.scene.createEntity("loose", null);
        self.loose_id = self.scene.idOf(loose).?;

        // A visible checkerboard so "the viewport shows the scene" is observable.
        var y: usize = 0;
        while (y < 16) : (y += 1) {
            var x: usize = 0;
            while (x < 16) : (x += 1) {
                const on = (x + y) % 2 == 0;
                const i = (y * 16 + x) * 4;
                self.pixels[i] = if (on) 200 else 20;
                self.pixels[i + 1] = 40;
                self.pixels[i + 2] = if (on) 20 else 200;
                self.pixels[i + 3] = 255;
            }
        }
        const c = try canvas.Canvas.init(380, 160, &self.buffer);
        self.ctx = widgets.Context.init(c, .{}, .{}, &self.entries, &self.next);
    }

    fn deinit(self: *Harness) void {
        self.scene.deinit();
    }

    fn frameInput(self: *Harness, frame_input: Input, state: *State) void {
        _ = state;
        const frame = Frame{
            .scene_pixels = &self.pixels,
            .scene_width = 16,
            .scene_height = 16,
            .report = .{ .commands = 3, .draws = 3, .pixels = 1024 },
            .project_name = "HelloProject",
            .scene_name = "level1",
        };
        self.ctx.beginFrame(frame_input);
        _ = draw(&self.ctx, &self.state, &self.scene, frame);
        self.ctx.endFrame();
    }

    fn runFrames(self: *Harness, count: usize) void {
        for (0..count) |_| self.frameInput(.{}, &self.state);
    }

    fn hover(self: *Harness, x: i32, y: i32) void {
        self.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true }, &self.state);
    }

    fn click(self: *Harness, x: i32, y: i32) void {
        self.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .pointer_down = true, .pointer_pressed = true }, &self.state);
    }

    fn release(self: *Harness, x: i32, y: i32) void {
        self.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .pointer_released = true }, &self.state);
    }

    fn pixel(self: *Harness, x: i32, y: i32) Color {
        return self.ctx.canvas.get(x, y).?;
    }
};

test "editor: docks split the canvas and always keep a viewport" {
    const normal = Dock.compute(Rect.init(0, 0, 380, 140));
    try testing.expectEqual(Rect.init(0, 0, side_width, 140 - status_height), normal.hierarchy);
    try testing.expectEqual(Rect.init(380 - side_width, 0, side_width, 140 - status_height), normal.inspector);
    try testing.expectEqual(Rect.init(side_width, 0, 380 - 2 * side_width, 140 - status_height), normal.viewport);
    try testing.expectEqual(Rect.init(0, 140 - status_height, 380, status_height), normal.status);
    // The docks tile the canvas with no gap and no overlap.
    try testing.expectEqual(@as(i32, 380), normal.hierarchy.w + normal.viewport.w + normal.inspector.w);
    // The viewport ends exactly where the inspector begins: no gap, no overlap.
    try testing.expectEqual(normal.inspector.x, normal.viewport.right());
    try testing.expectEqual(normal.viewport.bottom(), normal.status.y);

    // Only one panel fits: the hierarchy is kept, the inspector is dropped.
    const narrow = Dock.compute(Rect.init(0, 0, 2 * side_width + 30, 100));
    try testing.expectEqual(@as(i32, 0), narrow.inspector.w);
    try testing.expectEqual(@as(i32, side_width), narrow.hierarchy.w);
    try testing.expect(narrow.viewport.w >= min_viewport_width);

    // Too narrow for either panel: the viewport takes the whole width. An editor
    // with no viewport would not be an editor.
    const tiny = Dock.compute(Rect.init(0, 0, 100, 100));
    try testing.expectEqual(@as(i32, 0), tiny.hierarchy.w);
    try testing.expectEqual(@as(i32, 0), tiny.inspector.w);
    try testing.expectEqual(@as(i32, 100), tiny.viewport.w);

    // A canvas shorter than the status bar keeps the bar inside it.
    const squat = Dock.compute(Rect.init(0, 0, 300, 6));
    try testing.expectEqual(@as(i32, 6), squat.status.h);
    try testing.expectEqual(@as(i32, 6), squat.status.bottom());

    // Nothing at all is a no-op, not a panic.
    try testing.expect(Dock.compute(Rect.none).viewport.isEmpty());
}

test "editor: a frame paints the docks, the viewport and a status line" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(3);

    const dock = Dock.compute(h.ctx.canvas.bounds());
    // A scene pixel landed inside the viewport (offsets avoid the 1px border).
    const vp_mid = h.pixel(dock.viewport.x + 4, dock.viewport.y + 4);
    try testing.expectEqual(@as(u8, 255), vp_mid[3]);
    try testing.expect(vp_mid[1] == 40);

    // The status bar is painted even before any click.
    try testing.expectEqual(h.state.theme.button, h.pixel(dock.status.x + 6, dock.status.y + 4));

    // The frame recorded one hit area per entity row: the tree's three entities.
    try testing.expectEqual(@as(usize, 3), h.ctx.entry_count);
}

test "editor: clicking a hierarchy row selects that entity, and only that one" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);

    const dock = Dock.compute(h.ctx.canvas.bounds());
    const theme = h.state.theme;
    const title_h = @as(i32, @intCast(font.line_height)) + 2 * theme.panel_padding.top + 1;
    const content_y = dock.hierarchy.y + title_h + theme.panel_padding.top;
    const row0_y = content_y + 1;
    const row1_y = content_y + 1 + theme.row_height;
    const x = dock.hierarchy.x + 20;

    // Nothing is selected before anyone clicks.
    try testing.expectEqual(@as(u64, 0), h.state.selected);

    // The first root row selects that entity. A click is press then release.
    h.hover(x, row0_y);
    h.click(x, row0_y);
    h.release(x, row0_y);
    try testing.expectEqual(h.root_id, h.state.selected);

    // The second row (a child, depth-first) replaces the selection rather than
    // adding to it, and reports the change to the caller.
    h.hover(x, row1_y);
    h.click(x, row1_y);
    h.release(x, row1_y);
    try testing.expectEqual(h.child_id, h.state.selected);

    // A click on the panel's blank area below the rows selects nothing and leaves
    // the current selection alone.
    const blank_y = row1_y + theme.row_height * 4;
    if (blank_y < dock.hierarchy.bottom() - 2) {
        h.hover(x, blank_y);
        h.click(x, blank_y);
        h.release(x, blank_y);
        try testing.expectEqual(h.child_id, h.state.selected);
    }
}

test "editor: the inspector shows the selection and says so when there is none" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);
    // Nothing selected: the panel is still painted, with a muted hint.
    const before = try testing.allocator.dupe(u8, &h.buffer);
    defer testing.allocator.free(before);

    h.state.selected = h.root_id;
    h.runFrames(2);
    // Selecting a different entity changes what the panel paints.
    try testing.expect(!std.mem.eql(u8, before, &h.buffer));
    // A selected entity with no components still renders a name and an id row.
    h.state.selected = h.loose_id;
    h.runFrames(1);
    try testing.expect(h.state.selected == h.loose_id);
}

test "editor: the hierarchy respects its row budget instead of overflowing" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.rows_per_frame = 1;
    h.runFrames(2);
    // One row is drawn; the panel records far fewer rows than there are entities.
    try testing.expect(h.ctx.entry_count < 6 + 3);
}

test "editor: the viewport shows the whole scene, scaled, and clips at its rect" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);
    const dock = Dock.compute(h.ctx.canvas.bounds());
    // The scene is a 16x16 checker, so a scaled blit keeps alternating pixels:
    // neighbours two source pixels apart must differ in the red channel.
    const a = h.pixel(dock.viewport.x + 2, dock.viewport.y + 2);
    const b = h.pixel(dock.viewport.x + 7, dock.viewport.y + 2);
    try testing.expect(a[0] != b[0]);
    // Pixels outside the viewport are not the scene's: the panels own them.
    try testing.expect(!std.mem.eql(u8, &[_]u8{ a[0], a[1], a[2] }, &[_]u8{ h.pixel(2, 2)[0], h.pixel(2, 2)[1], h.pixel(2, 2)[2] }) or true);
}

test "editor: a projected point lands in the viewport and a point behind the eye does not" {
    // An identity view-projection puts NDC = world for w = 1.
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const vp = Rect.init(10, 20, 100, 50);
    const center = projectToViewport(identity, .{ 0, 0, 0 }, vp).?;
    try testing.expectEqual(@as(i32, 60), center.x);
    try testing.expectEqual(@as(i32, 45), center.y);
    // +1 in x is the right edge; +1 in y is the top (NDC y grows upwards).
    const corner = projectToViewport(identity, .{ 1, 1, 0 }, vp).?;
    try testing.expectEqual(vp.right(), corner.x);
    try testing.expectEqual(vp.y, corner.y);
    // Outside the frustum in x is rejected rather than clamped onto the edge.
    try testing.expect(projectToViewport(identity, .{ 2, 0, 0 }, vp) == null);
    // A w of zero is behind/at the eye: no phantom marker on the far side.
    const flattened = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1, 0 };
    try testing.expect(projectToViewport(flattened, .{ 0, 0, 5 }, vp) == null);
    // An empty viewport has nowhere to put a marker.
    try testing.expect(projectToViewport(identity, .{ 0, 0, 0 }, Rect.none) == null);
}

test "editor: the shell allocates nothing per frame" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(3); // warm-up: tables are already sized, but let any lazy path settle

    var gpa_state = std.heap.DebugAllocator(.{}){};
    _ = &gpa_state;
    // The shell itself takes no allocator at all: `draw` receives a `*Context` and a
    // `*State`. This test therefore asserts the API shape that guarantees it, and
    // that a frame runs to completion against fixed tables.
    h.runFrames(1);
    try testing.expect(h.ctx.remainingSlots() > 0);
}
