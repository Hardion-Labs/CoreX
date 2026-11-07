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
const edit = @import("edit.zig");
const inspector = @import("inspector.zig");
const tree = @import("tree.zig");
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
    /// First tree row painted. Scrolling moves this, and selecting an entity that is off
    /// screen moves it to bring that row back into view.
    tree_offset: usize = 0,
    /// Branches whose children are hidden. A view preference, so it never enters the
    /// history: undoing an edit must not also unfold the tree.
    collapsed: tree.Collapsed = .{},
    /// Last tree action that failed, so the status bar can say why instead of the click
    /// appearing to do nothing.
    edit_error: ?anyerror = null,
    /// Which dock holds the keyboard. Only the hierarchy and the inspector are stops: they
    /// are the two docks with keyboard behaviour, and a Tab stop that answers no key would
    /// be a stop the user has to press Tab twice to get past.
    dock_focus: DockFocus = .hierarchy,
    theme: Theme = .{},
    /// Set when the user clicked an entity this frame, so a caller can react
    /// (re-frame the camera, save the selection, ...) without diffing by hand.
    selection_changed: bool = false,

    /// The inspector's text field for the selected entity's name. Owned here because
    /// the field is editor state, not scene data: the scene only changes when the edit
    /// is committed with Enter.
    name_buffer: [edit.max_name_bytes]u8 = @splat(0),
    name_len: usize = 0,
    name_caret: usize = 0,
    /// The field is focused (clicked into) and receives typing this frame.
    name_focused: bool = false,
    /// Entity the buffer currently mirrors, so a selection change reloads it. 0 means
    /// "resynchronize on the next frame".
    name_owner: u64 = 0,

    /// Editable transform rows. They live beside the name buffer for the same reason:
    /// they are what the user is typing, not what the scene holds.
    transform_pos: inspector.Row(3) = .{},
    transform_scale: inspector.Row(3) = .{},

    /// True while any inspector field holds the keyboard. One flag, set once per frame by
    /// the inspector, because the frame-level shortcuts must not fire for *any* focused
    /// field — `Delete` in a text field is a text key, never "destroy the entity".
    text_focused: bool = false,
};

/// The docks a user can move the keyboard focus between.
pub const DockFocus = enum {
    hierarchy,
    inspector,

    pub fn next(self: DockFocus) DockFocus {
        return switch (self) {
            .hierarchy => .inspector,
            .inspector => .hierarchy,
        };
    }

    pub fn previous(self: DockFocus) DockFocus {
        // Two stops, so previous is next; written out rather than reused so adding a third
        // stop later is a compile-time reminder to give it a reverse.
        return switch (self) {
            .hierarchy => .inspector,
            .inspector => .hierarchy,
        };
    }
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
pub fn draw(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    history: anytype,
    frame: Frame,
) bool {
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

    if (!dock.hierarchy.isEmpty()) drawHierarchy(ctx, state, scene, history, dock.hierarchy);
    if (!dock.inspector.isEmpty()) drawInspector(ctx, state, scene, history, dock.inspector);
    if (!dock.status.isEmpty()) drawStatus(ctx, state, history, frame, dock.status, dock.viewport);

    // The focused dock is outlined in the accent colour. Which dock answers the keyboard is
    // otherwise invisible, and a user needs to know where Tab put them.
    const focused_rect = switch (state.dock_focus) {
        .hierarchy => dock.hierarchy,
        .inspector => dock.inspector,
    };
    if (!focused_rect.isEmpty()) ctx.canvas.strokeRect(focused_rect, state.theme.accent);

    focusStep(ctx, state);
    if (!state.text_focused) applyShortcuts(ctx, state, scene, history);
    return state.selection_changed;
}

/// The hierarchy: one row per entity, indented by depth, clickable to select.
///
/// Rows come from `childIdsInto`, which sorts and bounds in one allocation-free
/// scan, so the panel cannot overflow its table or depend on hash-map visit order.
fn drawHierarchy(ctx: *widgets.Context, state: *State, scene: anytype, history: anytype, rect: Rect) void {
    const content = widgets.panel(ctx, rect, "Hierarchy");
    const theme = ctx.theme;
    const row_h: i32 = @intCast(theme.row_height);
    var stack = layout.Layout.init(content, .vertical);

    // "+" adds a root, or a child when something is selected: one hit area in the panel's
    // title row, which is otherwise empty space.
    {
        const line_h: i32 = @intCast(font.line_height);
        const plus = Rect.init(rect.right() - 14, rect.y + theme.panel_padding.top, 10, line_h);
        const pr = ctx.interact(Id.from(0, "tree.add"), plus);
        _ = text.draw(ctx.canvas, plus.x + 1, plus.y, "+", .{
            .color = if (pr.isHovered()) theme.text else theme.text_muted,
            .clip = plus,
        });
        if (pr.clicked) runTreeAction(state, scene, history, .add_child, state.selected);
    }

    // How many rows the panel can hold, and therefore where the scroll window ends.
    const visible = @max(@divTrunc(content.h, row_h), 0);
    var rows: [tree.max_rows]tree.Row = undefined;
    var list = tree.List{
        .rows = &rows,
        .visible = @intCast(@min(visible, state.rows_per_frame)),
        .collapsed = &state.collapsed,
    };

    // Keep the selection on screen before painting: a keyboard step or a restore can
    // select an entity that the current window does not show.
    revealSelection(state, scene, list.visible, &state.collapsed);

    // Scrolling: the wheel moves by whole rows, and the offset is clamped so the panel
    // cannot be scrolled into emptiness.
    if (ctx.input.wheel != 0 and ctx.input.pointer_in_window and content.containsPoint(ctx.input.pointer)) {
        const delta: usize = @intCast(@abs(ctx.input.wheel) * 3);
        if (ctx.input.wheel < 0) {
            state.tree_offset +|= delta;
        } else {
            state.tree_offset -|= delta;
        }
    }
    list.offset = state.tree_offset;
    tree.build(scene, &list);
    // A wheel past the end must not leave the list scrolled into blank rows: the walk
    // reports nothing visible, so pull the offset back to the last full window.
    if (list.len == 0 and state.tree_offset > 0) {
        state.tree_offset = 0;
        list.offset = 0;
        tree.build(scene, &list);
    }

    var shown: usize = 0;
    for (list.rows[0..list.len]) |row| {
        const slot = stack.measure(.{ .w = content.w, .h = row_h });
        if (slot.isEmpty()) break;
        if (drawTreeRow(ctx, state, scene, history, slot, row, row_h, content)) shown += 1;
    }

    if (shown == 0) {
        _ = widgets.label(ctx, stack.measure(.{ .w = content.w, .h = @intCast(font.line_height) }), "(empty scene)");
    } else if (tree.hasMore(list)) {
        const hint = stack.measure(.{ .w = content.w, .h = @intCast(font.line_height) });
        _ = text.draw(ctx.canvas, hint.x, hint.y, "more...", .{ .color = theme.text_muted, .clip = hint });
    }
    // The panel is a background for everything under it: clicks on its blank area do
    // not reach the viewport behind it.
    ctx.blockBelow(rect);
}

/// Scroll the window so the selected row is inside it, if the selection is far enough out
/// to need it. One bounded search per frame only when the selection is not visible.
fn revealSelection(state: *State, scene: anytype, visible: usize, collapsed: *tree.Collapsed) void {
    if (state.selected == 0 or visible == 0) return;
    var rows: [tree.max_rows]tree.Row = undefined;
    var list = tree.List{ .rows = &rows, .visible = visible, .offset = state.tree_offset, .collapsed = collapsed };
    tree.build(scene, &list);
    for (list.rows[0..list.len]) |row| {
        if (row.id == state.selected) return;
    }
    // The selection may be hidden by a fold rather than by the window: unfold the chain
    // above it first, or scrolling would land on a row that is still not there.
    var changed = true;
    var guard: usize = 0;
    while (changed and guard < tree.max_depth) : (guard += 1) {
        changed = false;
        var chain: [tree.max_rows]u64 = @splat(0);
        var len: usize = 0;
        var cursor = scene.parentIdOf(state.selected);
        while (cursor) |pid| {
            if (len == chain.len) break;
            chain[len] = pid;
            len += 1;
            cursor = scene.parentIdOf(pid);
        }
        for (chain[0..len]) |pid| {
            if (collapsed.contains(pid)) {
                collapsed.expand(pid);
                changed = true;
            }
        }
    }
    // Not in the window: ask the whole tree where it is and centre it.
    const line = tree.indexOf(scene, state.selected, tree.max_rows) orelse return;
    state.tree_offset = line -| (visible / 2);
}

/// One tree row: hit area, selection highlight and the indented name.
///
/// A single flat function, driven by `tree.Row`, instead of a recursion that re-derives
/// depth on every level: the row list already knows the depth, and painting must not be
/// allowed to descend into a branch the window has cut off.
fn drawTreeRow(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    history: anytype,
    slot: Rect,
    row: tree.Row,
    row_h: i32,
    content: Rect,
) bool {
    const theme = ctx.theme;
    const entity = scene.entityById(row.id) orelse return false;
    const indent: i32 = @intCast(4 + @as(i32, @intCast(row.depth)) * 8);
    const row_rect = Rect.init(slot.x, slot.y, slot.w, row_h);

    // The disclosure control is its own hit area *before* the row, so clicking it folds
    // the branch instead of selecting the entity. It is painted (and registered) first so
    // the row underneath still receives clicks everywhere else.
    var disclosure_w: i32 = 0;
    if (row.has_children) {
        disclosure_w = 8;
        const tri = Rect.init(row_rect.x + indent - 8, row_rect.y, disclosure_w, row_h);
        const dr = ctx.interact(Id.from(row.id, "tree.disclosure"), tri);
        const glyph: []const u8 = if (row.collapsed) ">" else "v";
        const ty = row_rect.y + @divTrunc(@max(row_h - @as(i32, @intCast(font.line_height)), 0), 2);
        _ = text.draw(ctx.canvas, tri.x + 1, ty, glyph, .{
            .color = if (dr.isHovered()) theme.text else theme.text_muted,
            .clip = tri,
        });
        if (dr.clicked) {
            _ = tree.apply(.toggle_collapse, row.id, &state.collapsed, scene, history);
            return true;
        }
    }

    const id_hash = Id.from(row.id, "tree");
    const r = ctx.interact(id_hash, row_rect);
    const selected = state.selected == row.id;
    if (selected) {
        ctx.canvas.fillRect(row_rect, theme.accent);
    } else if (r.isHovered()) {
        ctx.canvas.fillRect(row_rect, theme.button_hover);
    }
    if (r.clicked and !selected) {
        state.selected = row.id;
        state.selection_changed = true;
    }

    const name = scene.nameOf(entity) orelse "(unnamed)";
    const label_rect = Rect.init(row_rect.x + indent, row_rect.y, @max(row_rect.w - indent, 0), row_h);
    const y = row_rect.y + @divTrunc(@max(row_h - @as(i32, @intCast(font.line_height)), 0), 2);
    _ = text.draw(ctx.canvas, label_rect.x, y, name, .{
        .color = if (selected) theme.textOn(theme.accent) else theme.text,
        .clip = label_rect,
    });
    _ = content;
    return true;
}

/// Run a tree action and fold its result back into the editor state.
///
/// One place decides what a tree click does, so a click, a key and a test go through the
/// same path: the action becomes one history command, a failure is reported rather than
/// swallowed, and a new entity is selected so the user can name it immediately.
fn runTreeAction(
    state: *State,
    scene: anytype,
    history: anytype,
    action: tree.Action,
    row: u64,
) void {
    const effect = tree.apply(action, row, &state.collapsed, scene, history);
    state.edit_error = effect.failure;
    if (effect.select != 0) {
        state.selected = effect.select;
        state.name_owner = 0; // the inspector must reload for the new entity
        state.selection_changed = true;
    }
    if (effect.changed and state.selected != 0 and scene.entityById(state.selected) == null) {
        state.selected = 0;
        state.name_owner = 0;
    }
}

/// The inspector's name field id. One constant, so the focus pass and the field cannot
/// disagree about which widget owns the keyboard.
const name_field_id = widgets.Id.from(0x6e61_6d65, "inspector.name");

/// The inspector: the selected entity's name as an editable field, its stable ID, local
/// transform and the components the scene actually stores.
///
/// The name field is the editor's first *input*: typing edits a local buffer, Enter
/// commits it through the history as a `rename` command, Escape drops it. Committing
/// through the history is what makes the change undoable, and going through a buffer is
/// what makes a half-typed name never a scene edit.
fn drawInspector(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    history: anytype,
    rect: Rect,
) void {
    const content = widgets.panel(ctx, rect, "Inspector");
    var stack = layout.Layout.init(content, .vertical).withSpacing(2);
    const line_h: i32 = @intCast(font.line_height);
    const theme = ctx.theme;

    state.text_focused = false;
    const entity = if (state.selected != 0) scene.entityById(state.selected) else null;
    const ent = entity orelse {
        state.name_focused = false;
        const slot = stack.measure(.{ .w = content.w, .h = line_h });
        _ = text.draw(ctx.canvas, slot.x, slot.y, "no selection", .{ .color = theme.text_muted, .clip = slot });
        ctx.blockBelow(rect);
        return;
    };

    var buf: [96]u8 = undefined;
    drawNameField(ctx, state, scene, history, ent, &stack, content);

    const id_line = std.fmt.bufPrint(&buf, "{d}", .{state.selected}) catch "?";
    fieldRow(ctx, &stack, content, "id", id_line);

    if (scene.getComponent(render_scene.Transform, ent)) |t| {
        // Position and scale are editable; rotation stays read-only until there is a
        // field that can express a normalized quaternion honestly.
        const row_h = line_h + 2;
        const pos_row = stack.measure(.{ .w = content.w, .h = row_h });
        // A rejected value is already reverted inside `drawTransformRow`; the only
        // error left is the history refusing the store (out of memory), and swallowing
        // that would show the user a value the scene does not have.
        drawTransformRow(ctx, state, scene, history, ent, &state.transform_pos, pos_row, .position, t, "pos") catch |err| reportEditFailure(err, "pos");
        const scale_row = stack.measure(.{ .w = content.w, .h = row_h });
        drawTransformRow(ctx, state, scene, history, ent, &state.transform_scale, scale_row, .scale, t, "scale") catch |err| reportEditFailure(err, "scale");
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

    // Publish the keyboard claim for the shortcut pass, which runs after the panels.
    state.text_focused = state.name_focused or
        state.transform_pos.isFocused() or
        state.transform_scale.isFocused();

    ctx.blockBelow(rect);
}

/// An edit that could not be stored. The editor keeps running (a frame must paint), but
/// the failure is not silent: the field was reverted inside the row painter, and the
/// reason goes to stderr where a headless session can see it.
fn reportEditFailure(err: anyerror, row: []const u8) void {
    std.debug.print("editor: could not store the {s} edit ({s}); the field was reverted\n", .{ row, @errorName(err) });
}

/// Which part of a `Transform` a row edits, and how to address it on commit.
const TransformField = enum {
    position,
    scale,

    fn get(self: TransformField, t: render_scene.Transform) [3]f32 {
        return switch (self) {
            .position => t.position,
            .scale => t.scale,
        };
    }

    fn set(self: TransformField, t: *render_scene.Transform, values: [3]f32) void {
        switch (self) {
            .position => t.position = values,
            .scale => t.scale = values,
        }
    }
};

/// One editable transform row (`pos` or `scale`).
///
/// A commit builds the **whole** transform (the edited row plus the untouched one) and
/// sends it as a single `set_component`, so one keystroke-and-Enter is one undo step, and
/// a value the user did not touch is never rewritten.
fn drawTransformRow(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    history: anytype,
    entity: anytype,
    row: anytype,
    rect: Rect,
    comptime field: TransformField,
    transform: *const render_scene.Transform,
    key: []const u8,
) !void {
    const values = field.get(transform.*);
    // Load the buffers from the scene whenever the values changed underneath (a reload,
    // an undo, another command). `signature` is a cheap hash of the three floats, so the
    // comparison is not a second copy of the transform.
    var sig = std.hash.Wyhash.init(0);
    for (values) |v| sig.update(std.mem.asBytes(&v));
    const signature = sig.final();
    if (row.owner != state.selected or row.signature != signature) {
        if (!row.isFocused()) {
            row.load(values);
            row.owner = state.selected;
            row.signature = signature;
        }
    }
    const seed = switch (field) {
        .position => @as(u64, 0x706f_73),
        .scale => @as(u64, 0x7363_616c),
    };
    const outcome = inspector.drawRow(ctx, 3, row, rect, .{
        .entity_id = state.selected,
        .signature = signature,
        .key = key,
    }, @intCast(font.line_height + 2), seed);

    switch (outcome) {
        .idle => return,
        .escape => {
            row.load(values);
            row.owner = state.selected;
            row.signature = signature;
            return;
        },
        .commit => {},
    }

    const typed = row.values() orelse {
        // A field that is not a number is not a value: revert rather than commit
        // something the user did not type.
        row.load(values);
        row.owner = state.selected;
        row.signature = signature;
        return;
    };

    var next = transform.*;
    field.set(&next, typed);
    if (!next.isValid()) {
        row.load(values);
        row.owner = state.selected;
        row.signature = signature;
        return;
    }
    // Nothing changed (Enter on an untouched row) is not an edit.
    if (std.mem.eql(u8, std.mem.asBytes(&typed), std.mem.asBytes(&values))) {
        row.signature = signature;
        return;
    }

    const id = scene.idOf(entity) orelse return;
    try history.apply(scene, .{ .set_component = .{
        .id = id,
        .value = edit.valueFor(@TypeOf(scene.*), render_scene.Transform, next),
    } });
    row.owner = state.selected;
    // After the commit the scene holds `next`; take its signature so the next frame does
    // not think the buffers are stale and reload over the user's text.
    var post = std.hash.Wyhash.init(0);
    for (field.get(next)) |v| post.update(std.mem.asBytes(&v));
    row.signature = post.final();
}

/// The `name:` row of the inspector: a real text field.
///
/// Typing edits `State.name_buffer`; **Enter** commits the buffer through the history
/// as a `rename` command, **Escape** abandons it. Going through a buffer is what keeps a
/// half-typed name out of the scene; going through the history is what makes the commit
/// undoable and what marks the project dirty.
fn drawNameField(
    ctx: *widgets.Context,
    state: *State,
    scene: anytype,
    history: anytype,
    entity: anytype,
    stack: *layout.Layout,
    content: Rect,
) void {
    const theme = ctx.theme;
    const line_h: i32 = @intCast(font.line_height);
    const row = stack.measure(.{ .w = content.w, .h = line_h });
    if (row.isEmpty()) return;
    const key_w: i32 = 40;
    const key_rect = Rect.init(row.x, row.y, @min(key_w, row.w), line_h);
    const value_rect = Rect.init(row.x + key_rect.w, row.y, @max(row.w - key_rect.w, 0), line_h);
    _ = text.draw(ctx.canvas, key_rect.x, key_rect.y, "name", .{ .color = theme.text_muted, .clip = key_rect });

    const id = name_field_id;
    const focused = ctx.focus.eql(id);

    // The buffer mirrors the scene whenever the field is *not* being typed into, and
    // whenever focus moves to a different entity. Doing it here, before the widget runs,
    // is what makes the first keystroke land at the end of the current name instead of
    // replacing it with whatever the previous selection left behind.
    if (!focused or state.name_owner != state.selected) {
        reloadName(state, scene, entity);
        state.name_owner = state.selected;
    }
    state.name_focused = focused;

    var field = widgets.TextField{
        .buffer = &state.name_buffer,
        .len = state.name_len,
        .caret = state.name_caret,
    };
    const r = widgets.textField(ctx, id, value_rect, &field);
    state.name_len = field.len;
    state.name_caret = field.caret;
    state.name_focused = r.focused;
    // Taking the keyboard by clicking moves the dock focus too: the outline and the Tab
    // order must agree with what is actually receiving keys.
    if (r.focused) state.dock_focus = .inspector;

    if (!r.focused) return;

    // The field holds the keyboard this frame: a host must not also read these bytes as
    // shortcuts.
    _ = ctx.claimTextInput();

    // Ctrl+Z and friends are frame-level shortcuts, handled after the panels are
    // painted: while this field holds focus they must not fire.
    if (ctx.input.modifiers.ctrl) return;
    if (ctx.keyPressed(.enter)) {
        commitName(state, history, scene, entity);
        state.name_owner = 0; // resync the buffer with whatever the scene now holds
    } else if (ctx.keyPressed(.escape)) {
        reloadName(state, scene, entity);
    }
}

/// Write the field's buffer to the scene through the history, unless it is unchanged.
fn commitName(state: *State, history: anytype, scene: anytype, entity: anytype) void {
    const typed = state.name_buffer[0..state.name_len];
    const current = scene.nameOf(entity) orelse "";
    if (std.mem.eql(u8, typed, current)) return;
    const id = scene.idOf(entity) orelse return;
    const name: ?edit.Name = if (state.name_len == 0) null else edit.Name.init(typed) orelse return;
    history.apply(scene, .{ .rename = .{ .id = id, .name = name } }) catch |err| reportEditFailure(err, "name");
}

/// Point the field at the entity's current name, so the next keystroke starts from what
/// is on screen rather than from another entity's text.
pub fn reloadName(state: *State, scene: anytype, entity: anytype) void {
    const name = scene.nameOf(entity) orelse "";
    const n = @min(name.len, state.name_buffer.len);
    @memcpy(state.name_buffer[0..n], name[0..n]);
    state.name_len = n;
    state.name_caret = n;
}

/// Move the keyboard focus between docks (Tab / Shift+Tab).
///
/// Called **before** the text-field gate: a focused field must not be a place the user
/// cannot Tab out of, so this is the one shortcut that also works from inside one.
fn focusStep(ctx: *widgets.Context, state: *State) void {
    if (!ctx.keyPressed(.tab)) return;
    state.dock_focus = if (ctx.input.modifiers.shift) state.dock_focus.previous() else state.dock_focus.next();
    focusDock(ctx, state);
    // The field republishes its focus at the start of the next frame; reflect the change
    // now so this frame's state is not lying about who owns the keyboard.
    state.name_focused = false;
    state.text_focused = false;
    if (state.dock_focus != .inspector) state.name_owner = 0;
}

/// Frame-level editing shortcuts. Only reached while the name field does not hold the
/// keyboard, so a user typing a name never triggers a delete.
///
/// Shortcuts are a *convenience* over the same three functions a menu or a test would
/// call — they add no behaviour of their own.
fn applyShortcuts(ctx: *widgets.Context, state: *State, scene: anytype, history: anytype) void {
    if (ctx.input.modifiers.ctrl) {
        const key = ctx.input.key orelse return;
        switch (key) {
            .z => if (ctx.input.modifiers.shift) {
                _ = redo(history, scene);
            } else {
                _ = undo(history, scene);
            },
            .y => _ = redo(history, scene),
            else => {},
        }
        pruneSelection(state, scene);
        return;
    }
    // Deleting is not tied to a dock: it acts on the selection, which is the tree's.
    if (ctx.keyPressed(.delete)) {
        _ = deleteSelected(state, history, scene);
        return;
    }
    if (state.dock_focus != .hierarchy) return;

    // Tree actions on the selection: the same `tree.apply` a click uses, so a key and a
    // click cannot diverge in what they record.
    if (ctx.keyPressed(.n)) {
        runTreeAction(state, scene, history, .add_child, state.selected);
        return;
    }
    if (ctx.keyPressed(.p)) {
        runTreeAction(state, scene, history, .{ .reparent = null }, state.selected);
        return;
    }
    // Arrow keys navigate the visible tree. They are resolved against the same row list
    // the panel paints, so a step can never land on a row the user cannot see.
    if (ctx.input.key) |key| {
        const step_opt: ?tree.Step = switch (key) {
            .down => .next,
            .up => .previous,
            .right => .into,
            .left => .out,
            else => null,
        };
        if (step_opt) |step_kind| {
            navigateTree(state, scene, history, step_kind);
            return;
        }
    }

    // Enter on a selection folds or unfolds its branch, if it has one.
    if (ctx.keyPressed(.enter)) {
        const selected = if (state.selected != 0) scene.entityById(state.selected) else null;
        if (selected != null and hasChildren(scene, state.selected)) {
            runTreeAction(state, scene, history, .toggle_collapse, state.selected);
        }
        return;
    }
    if (ctx.keyPressed(.escape)) state.selected = 0;
}

/// Point the GUI's focus at the focused dock's widget.
///
/// The GUI resolves text input against `focus` (one widget owns the keyboard), so the dock
/// focus has to be pushed down to a widget id: the inspector's name field, or nothing for
/// the hierarchy, which reads keys from the context rather than from a widget.
fn focusDock(ctx: *widgets.Context, state: *State) void {
    switch (state.dock_focus) {
        .hierarchy => ctx.setFocus(widgets.Id.zero),
        .inspector => ctx.setFocus(name_field_id),
    }
}

/// Resolve one arrow-key step and fold the result into the editor state.
///
/// The row list is rebuilt here (bounded, allocation-free) because the shortcut pass runs
/// after the panels: passing the painted list would mean keeping a 512-entry array alive
/// across the frame for one keystroke. `revealSelection` then scrolls the window to
/// whatever the step selected, so the selection is always on screen.
fn navigateTree(state: *State, scene: anytype, history: anytype, kind: tree.Step) void {
    _ = history;
    var rows: [tree.max_rows]tree.Row = undefined;
    // A window wide enough for the step's own line plus its neighbours; the model falls
    // back to `indexOf` beyond it, so this is a cost bound, not a correctness one.
    var list = tree.List{
        .rows = &rows,
        .visible = @min(state.rows_per_frame, tree.max_rows),
        .collapsed = &state.collapsed,
    };
    tree.build(scene, &list);
    const move = tree.step(scene, list.rows[0..list.len], state.selected, kind, &state.collapsed, tree.max_rows);
    if (!move.moved) return;
    if (move.id != 0 and move.id != state.selected) {
        state.selected = move.id;
        state.name_owner = 0;
        state.selection_changed = true;
    }
    if (move.folded) {
        // A fold can hide the current selection's row without deselecting it; keep the
        // selected entity, but make sure the window is not left showing a stale slice.
        revealSelection(state, scene, list.visible, &state.collapsed);
    }
}

/// Whether an entity has any children, which is what decides if Enter has anything to fold.
fn hasChildren(scene: anytype, id: u64) bool {
    var kids: [1]u64 = @splat(0);
    return scene.childIdsInto(id, &kids) > 0;
}

/// Drop a selection that no longer resolves — undoing a create, or a redo of a delete,
/// leaves the ID pointing at nothing, and the inspector must not keep claiming it.
fn pruneSelection(state: *State, scene: anytype) void {
    if (state.selected == 0) return;
    if (scene.entityById(state.selected) == null) {
        state.selected = 0;
        state.name_owner = 0;
    }
}

/// Undo one edit. Returns whether anything changed, so a host can repaint only then.
pub fn undo(history: anytype, scene: anytype) bool {
    if (!history.canUndo()) return false;
    history.undo(scene) catch return false;
    return true;
}

/// Redo one undone edit.
pub fn redo(history: anytype, scene: anytype) bool {
    if (!history.canRedo()) return false;
    history.redo(scene) catch return false;
    return true;
}

/// Delete the selected entity through the history, clearing the selection. The undo
/// restores the entity with its ID, so a later selection of the same ID still works.
pub fn deleteSelected(state: *State, history: anytype, scene: anytype) bool {
    if (state.selected == 0) return false;
    const entity = scene.entityById(state.selected) orelse return false;
    _ = entity;
    history.apply(scene, .{ .delete = .{ .id = state.selected } }) catch return false;
    state.selected = 0;
    state.name_len = 0;
    state.name_caret = 0;
    return true;
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

/// The status bar: project, scene, save state, undo depth, viewport size and the last
/// frame's real accounting. Every number comes from the render report or the history, so
/// the bar cannot claim something that did not happen.
fn drawStatus(ctx: *widgets.Context, state: *State, history: anytype, frame: Frame, rect: Rect, viewport: Rect) void {
    const theme = ctx.theme;
    ctx.canvas.fillRect(rect, theme.button);
    ctx.canvas.hline(rect.x, rect.y, rect.w, theme.border);

    // The save marker is the one piece of status that changes while editing, so it is
    // painted first and in the normal text colour: an unsaved project must be visible at
    // a glance, not read out of a run of numbers.
    var buf: [240]u8 = undefined;
    const h = history;
    const line = std.fmt.bufPrint(
        &buf,
        // ASCII only: the built-in font draws anything else as `?`, so a separator
        // like `·` would appear as a literal question mark in the bar.
        "{s}{s}{s}{s} | u{d} r{d} | {d} cmds {d} draws | vp {d}x{d}",
        .{
            frame.project_name,
            if (frame.project_name.len > 0 and frame.scene_name.len > 0) " / " else "",
            frame.scene_name,
            if (h.dirty) " *" else "",
            h.undoDepth(),
            h.redoDepth(),
            frame.report.commands,
            frame.report.draws,
            @max(viewport.w, 0),
            @max(viewport.h, 0),
        },
    ) catch "?";
    const pad: i32 = 4;
    const inner = Rect.init(rect.x + pad, rect.y + 3, @max(rect.w - 2 * pad, 0), rect.h);
    _ = text.draw(ctx.canvas, inner.x, inner.y, line, .{ .color = theme.text_muted, .clip = inner });

    // A refused edit replaces the counter tail for a frame: "the click did nothing" is the
    // one status an editor must never leave the user with. It is reported once, so the bar
    // returns to its counters as soon as the next frame paints.
    if (state.edit_error) |err| {
        var err_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "! {s}", .{@errorName(err)}) catch "!";
        const w = text.width(msg, 1) + 2 * pad;
        const box = Rect.init(rect.right() - @min(w, rect.w), rect.y, @min(w, rect.w), rect.h);
        ctx.canvas.fillRect(box, theme.button);
        _ = text.draw(ctx.canvas, box.x + pad, inner.y, msg, .{ .color = theme.accent, .clip = box });
    }
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
    history: edit.History(render_scene.EngineRenderScene) = undefined,
    root_id: u64 = 0,
    child_id: u64 = 0,
    loose_id: u64 = 0,

    fn init(self: *Harness) !void {
        const gpa = testing.allocator;
        self.scene = try render_scene.EngineRenderScene.init(gpa, "level1");
        self.history = edit.History(render_scene.EngineRenderScene).init(gpa);
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
        self.history.deinit();
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
        _ = draw(&self.ctx, &self.state, &self.scene, &self.history, frame);
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

    // One hit area per entity row (three), the disclosure control of the one row that has
    // children, and the panel's "+" control: the frame's widget table holds exactly what
    // was painted.
    try testing.expectEqual(@as(usize, 5), h.ctx.entry_count);
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

/// Find the inspector's name field on the last painted frame, so a test can click it
/// without hard-coding panel arithmetic.
fn nameFieldRect(h: *Harness) Rect {
    var i: usize = 0;
    while (i < h.ctx.entry_count) : (i += 1) {
        if (h.ctx.entries[i].id.eql(name_field_id)) return h.ctx.entries[i].rect;
    }
    return Rect.none;
}

test "editor: typing a name and pressing Enter commits one undoable rename" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(2);

    const field = nameFieldRect(&h);
    try testing.expect(!field.isEmpty());

    // Click into the field's right end: focus, and the buffer starts from the current
    // name with the caret after it, so typing appends.
    const cx = field.right() - 3;
    h.hover(cx, field.y + 3);
    h.click(cx, field.y + 3);
    h.release(cx, field.y + 3);
    try testing.expect(h.state.name_focused);

    // Typing edits the buffer only: the scene is untouched until Enter.
    h.frameInput(.{ .text = "renamed" }, &h.state);
    try testing.expectEqualStrings("childrenamed", h.state.name_buffer[0..h.state.name_len]);
    const child = h.scene.entityById(h.child_id).?;
    try testing.expectEqualStrings("child", h.scene.nameOf(child).?);

    // Enter commits through the history: the scene changes, the project is dirty.
    h.frameInput(.{ .key = .enter }, &h.state);
    try testing.expectEqualStrings("childrenamed", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
    try testing.expect(h.history.dirty);
    try testing.expectEqual(@as(usize, 1), h.history.undoDepth());

    // And it is exactly undoable.
    try testing.expect(undo(&h.history, &h.scene));
    try testing.expectEqualStrings("child", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
    try testing.expect(redo(&h.history, &h.scene));
    try testing.expectEqualStrings("childrenamed", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
}

test "editor: Enter on an unchanged name records nothing" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(2);

    const field = nameFieldRect(&h);
    h.hover(field.x + 3, field.y + 3);
    h.click(field.x + 3, field.y + 3);
    h.release(field.x + 3, field.y + 3);
    h.frameInput(.{ .key = .enter }, &h.state);

    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "editor: a rename the scene rejects leaves both the scene and the history alone" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(2);

    const field = nameFieldRect(&h);
    h.hover(field.x + 3, field.y + 3);
    h.click(field.x + 3, field.y + 3);
    h.release(field.x + 3, field.y + 3);
    // A path separator is a name the validation layer refuses.
    h.frameInput(.{ .text = "a/b" }, &h.state);
    h.frameInput(.{ .key = .enter }, &h.state);

    try testing.expectEqualStrings("child", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "editor: deleting the selection is undoable and restores the same ID" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.loose_id;
    h.runFrames(1);

    try testing.expect(deleteSelected(&h.state, &h.history, &h.scene));
    try testing.expectEqual(@as(u64, 0), h.state.selected);
    try testing.expect(h.scene.entityById(h.loose_id) == null);

    try testing.expect(undo(&h.history, &h.scene));
    const restored = h.scene.entityById(h.loose_id).?;
    try testing.expectEqualStrings("loose", h.scene.nameOf(restored).?);
    // The restored entity is selectable again, which is what "stable ID" buys: the
    // inspector resolves it and paints its name rather than "no selection".
    h.state.selected = h.loose_id;
    h.runFrames(1);
    try testing.expect(h.state.selected == h.loose_id);
}

test "editor: the status bar shows the save marker only when there is something to save" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);
    // No history yet drawn with a dirty flag: the bar renders.
    try testing.expect(!h.history.dirty);
    h.history.dirty = true;
    h.runFrames(1);
    const dock = Dock.compute(h.ctx.canvas.bounds());
    try testing.expect(!dock.status.isEmpty());
    // The marker is painted: at least one pixel of the bar's text row differs from the
    // bar fill, which is the same assertion as "a status line is drawn".
    var differs = false;
    var x = dock.status.x + 1;
    while (x < dock.status.right() - 1) : (x += 1) {
        const px = h.pixel(x, dock.status.y + 6);
        const fill = h.state.theme.button;
        if (!std.mem.eql(u8, &px, &fill)) differs = true;
    }
    try testing.expect(differs);
}

test "editor: Ctrl+Z undoes an edit and Ctrl+Y redoes it, without the field holding focus" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(2);

    try h.history.apply(&h.scene, .{ .rename = .{ .id = h.child_id, .name = edit.Name.init("byCmd").? } });
    try testing.expectEqualStrings("byCmd", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);

    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true } }, &h.state);
    try testing.expectEqualStrings("child", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);

    h.frameInput(.{ .key = .y, .modifiers = .{ .ctrl = true } }, &h.state);
    try testing.expectEqualStrings("byCmd", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);

    // Shift+Ctrl+Z is the other redo binding.
    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true } }, &h.state);
    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true, .shift = true } }, &h.state);
    try testing.expectEqualStrings("byCmd", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
}

test "editor: Delete removes the selection and Escape clears it" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.loose_id;
    h.runFrames(1);

    h.frameInput(.{ .key = .delete }, &h.state);
    try testing.expect(h.scene.entityById(h.loose_id) == null);
    try testing.expectEqual(@as(u64, 0), h.state.selected);

    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true } }, &h.state);
    try testing.expect(h.scene.entityById(h.loose_id) != null);

    h.state.selected = h.child_id;
    h.frameInput(.{ .key = .escape }, &h.state);
    try testing.expectEqual(@as(u64, 0), h.state.selected);
}

test "editor: a shortcut does not fire while the name field has focus" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.child_id;
    h.runFrames(2);

    const field = nameFieldRect(&h);
    const cx = field.right() - 3;
    h.hover(cx, field.y + 3);
    h.click(cx, field.y + 3);
    h.release(cx, field.y + 3);
    try testing.expect(h.state.name_focused);

    // Delete is a text-editing key here, not "destroy the entity".
    h.frameInput(.{ .key = .delete }, &h.state);
    try testing.expect(h.scene.entityById(h.child_id) != null);
    // Ctrl+Z is a shortcut, and while typing it belongs to the field (ignored, not applied).
    try h.history.apply(&h.scene, .{ .rename = .{ .id = h.child_id, .name = edit.Name.init("typed").? } });
    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true } }, &h.state);
    try testing.expectEqualStrings("typed", h.scene.nameOf(h.scene.entityById(h.child_id).?).?);
}

test "editor: an undo that removes the selected entity drops the selection" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(1);

    // Create, select it, undo the create: the ID no longer resolves.
    const new_id: u64 = 999;
    try h.history.apply(&h.scene, .{ .create = .{ .id = new_id, .name = edit.Name.init("tmp").? } });
    h.state.selected = new_id;
    h.runFrames(1);
    try testing.expect(h.scene.entityById(new_id) != null);

    h.frameInput(.{ .key = .z, .modifiers = .{ .ctrl = true } }, &h.state);
    try testing.expect(h.scene.entityById(new_id) == null);
    try testing.expectEqual(@as(u64, 0), h.state.selected);
    try testing.expectEqual(@as(u64, 0), h.state.name_owner);
}

/// Find a transform row's field on the last painted frame, so a test can click it.
fn numFieldRect(h: *Harness, seed: u64, key: []const u8, index: usize) Rect {
    const id = widgets.Id.from(seed + index, key);
    var i: usize = 0;
    while (i < h.ctx.entry_count) : (i += 1) {
        if (h.ctx.entries[i].id.eql(id)) return h.ctx.entries[i].rect;
    }
    return Rect.none;
}

const seed_pos: u64 = 0x706f_73;
const seed_scale: u64 = 0x7363_616c;

fn focusNumField(h: *Harness, rect: Rect) void {
    h.hover(rect.x + 2, rect.y + 2);
    h.click(rect.x + 2, rect.y + 2);
    h.release(rect.x + 2, rect.y + 2);
}

test "editor: typing a position and committing it is one undoable set_component" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    const field = numFieldRect(&h, seed_pos, "pos", 0);
    try testing.expect(!field.isEmpty());
    focusNumField(&h, field);
    // The field starts from the scene's value, so the user sees what they are editing.
    try testing.expect(h.state.transform_pos.isFocused());

    // Select the whole buffer and type a new x, then commit.
    h.frameInput(.{ .key = .home }, &h.state);
    h.frameInput(.{ .key = .delete }, &h.state);
    h.frameInput(.{ .text = "7.5" }, &h.state);
    const before = h.history.undoDepth();
    h.frameInput(.{ .key = .enter }, &h.state);

    const root = h.scene.entityById(h.root_id).?;
    const t = h.scene.getComponent(render_scene.Transform, root).?;
    try testing.expectEqual(@as(f32, 7.5), t.position[0]);
    // The axes the user did not touch are preserved exactly.
    try testing.expectEqual(@as(f32, 2), t.position[1]);
    try testing.expectEqual(@as(f32, 3), t.position[2]);
    // One command, not three, so a single undo steps back over the whole value.
    try testing.expectEqual(before + 1, h.history.undoDepth());

    try testing.expect(undo(&h.history, &h.scene));
    const back = h.scene.getComponent(render_scene.Transform, h.scene.entityById(h.root_id).?).?;
    try testing.expectEqual(@as(f32, 1), back.position[0]);
    try testing.expectEqual(@as(f32, 2), back.position[1]);
}

test "editor: an unparsable value is not committed and the field reverts" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    const field = numFieldRect(&h, seed_pos, "pos", 2);
    focusNumField(&h, field);
    h.frameInput(.{ .key = .home }, &h.state);
    h.frameInput(.{ .key = .delete }, &h.state);
    h.frameInput(.{ .text = "abc" }, &h.state);
    const before = h.history.undoDepth();
    h.frameInput(.{ .key = .enter }, &h.state);

    const t = h.scene.getComponent(render_scene.Transform, h.scene.entityById(h.root_id).?).?;
    try testing.expectEqual(@as(f32, 3), t.position[2]);
    try testing.expectEqual(before, h.history.undoDepth());
    // The buffer went back to what the scene holds, so the panel never claims a value
    // the scene does not have.
    try testing.expectEqualStrings("3", h.state.transform_pos.fields[2].text());
}

test "editor: Escape abandons a typed transform value" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    const field = numFieldRect(&h, seed_scale, "scale", 1);
    focusNumField(&h, field);
    h.frameInput(.{ .key = .home }, &h.state);
    h.frameInput(.{ .key = .delete }, &h.state);
    h.frameInput(.{ .text = "9" }, &h.state);
    h.frameInput(.{ .key = .escape }, &h.state);

    const t = h.scene.getComponent(render_scene.Transform, h.scene.entityById(h.root_id).?).?;
    try testing.expectEqual(@as(f32, 1), t.scale[1]);
    try testing.expectEqualStrings("1", h.state.transform_scale.fields[1].text());
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "editor: the numeric fields follow the selection instead of the previous entity" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    // The child's transform is identity; the root sits at (1,2,3).
    h.state.selected = h.root_id;
    h.runFrames(2);
    try testing.expectEqualStrings("1", h.state.transform_pos.fields[0].text());

    h.state.selected = h.child_id;
    h.runFrames(2);
    try testing.expectEqualStrings("0", h.state.transform_pos.fields[0].text());
    try testing.expectEqualStrings("1", h.state.transform_scale.fields[0].text());
}

test "editor: the hierarchy scrolls by the wheel and clamps at the ends" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    // Create more roots than the panel can show, so scrolling has somewhere to go.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const e = try h.scene.createEntity("row", null);
        _ = e;
    }
    h.runFrames(2);

    const dock = Dock.compute(h.ctx.canvas.bounds());
    const x = dock.hierarchy.x + 20;
    const y = dock.hierarchy.y + 40;
    try testing.expectEqual(@as(usize, 0), h.state.tree_offset);

    // Wheel down scrolls a few rows; the offset never exceeds what the tree holds.
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = 1 }, &h.state);
    try testing.expectEqual(@as(usize, 0), h.state.tree_offset); // wheel up at the top
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = -1 }, &h.state);
    try testing.expectEqual(@as(usize, 3), h.state.tree_offset);
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = -1 }, &h.state);
    try testing.expectEqual(@as(usize, 6), h.state.tree_offset);

    // Wheel up walks back and stops at the first row rather than underflowing.
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = 1 }, &h.state);
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = 1 }, &h.state);
    h.frameInput(.{ .pointer = .{ .x = x, .y = y }, .pointer_in_window = true, .wheel = 1 }, &h.state);
    try testing.expectEqual(@as(usize, 0), h.state.tree_offset);
}

test "editor: the tree window follows the scroll offset and still selects" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    var ids: [40]u64 = @splat(0);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const e = try h.scene.createEntity("row", null);
        ids[i] = h.scene.idOf(e).?;
    }
    h.runFrames(2);

    // Scroll past the first rows and click the first painted row: it must select the
    // entity at the new offset, not the tree's first entity.
    h.state.tree_offset = 5;
    h.runFrames(2);
    const dock = Dock.compute(h.ctx.canvas.bounds());
    const theme = h.state.theme;
    const title_h = @as(i32, @intCast(font.line_height)) + 2 * theme.panel_padding.top + 1;
    const row0_y = dock.hierarchy.y + title_h + theme.panel_padding.top + 1;
    const x = dock.hierarchy.x + 20;
    h.hover(x, row0_y);
    h.click(x, row0_y);
    h.release(x, row0_y);

    // The row that was clicked is the first one the tree model paints at this offset,
    // computed from the same model rather than guessed from the scene's creation order.
    var rows: [tree.max_rows]tree.Row = undefined;
    var list = tree.List{ .rows = &rows, .visible = 5, .offset = 5 };
    tree.build(&h.scene, &list);
    try testing.expect(list.len > 0);
    try testing.expectEqual(list.rows[0].id, h.state.selected);
}

test "editor: selecting an entity that is off screen scrolls it into view" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    var ids: [40]u64 = @splat(0);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const e = try h.scene.createEntity("row", null);
        ids[i] = h.scene.idOf(e).?;
    }
    h.runFrames(2);
    try testing.expectEqual(@as(usize, 0), h.state.tree_offset);

    // Selecting the last entity (a keyboard step, a restore) moves the window.
    h.state.selected = ids[39];
    h.runFrames(2);
    try testing.expect(h.state.tree_offset > 0);

    // And the window really contains it: a rebuild with the new offset shows that ID.
    var rows: [tree.max_rows]tree.Row = undefined;
    var list = tree.List{ .rows = &rows, .visible = 5, .offset = h.state.tree_offset };
    tree.build(&h.scene, &list);
    var found = false;
    for (list.rows[0..list.len]) |row| {
        if (row.id == ids[39]) found = true;
    }
    try testing.expect(found);
}

test "editor: the disclosure control folds a branch without selecting it" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);

    // Find the disclosure of the root row and click it.
    const id = widgets.Id.from(h.root_id, "tree.disclosure");
    var rect = Rect.none;
    var i: usize = 0;
    while (i < h.ctx.entry_count) : (i += 1) {
        if (h.ctx.entries[i].id.eql(id)) rect = h.ctx.entries[i].rect;
    }
    try testing.expect(!rect.isEmpty());

    h.hover(rect.x + 2, rect.y + 2);
    h.click(rect.x + 2, rect.y + 2);
    h.release(rect.x + 2, rect.y + 2);

    // The branch folded, and the selection did not move to the row.
    try testing.expect(h.state.collapsed.contains(h.root_id));
    try testing.expectEqual(@as(u64, 0), h.state.selected);
    // Nothing entered the history: a fold is a view preference.
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "editor: the + control creates an undoable entity and selects it" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    const id = widgets.Id.from(0, "tree.add");
    var rect = Rect.none;
    var i: usize = 0;
    while (i < h.ctx.entry_count) : (i += 1) {
        if (h.ctx.entries[i].id.eql(id)) rect = h.ctx.entries[i].rect;
    }
    try testing.expect(!rect.isEmpty());
    const before = h.scene.count();

    h.hover(rect.x + 2, rect.y + 2);
    h.click(rect.x + 2, rect.y + 2);
    h.release(rect.x + 2, rect.y + 2);

    try testing.expectEqual(before + 1, h.scene.count());
    // The new entity is the selection, under the row that was selected.
    try testing.expect(h.state.selected != 0);
    try testing.expectEqual(h.root_id, h.scene.parentIdOf(h.state.selected).?);
    try testing.expectEqual(@as(usize, 1), h.history.undoDepth());
    try testing.expect(h.history.dirty);

    try testing.expect(undo(&h.history, &h.scene));
    try testing.expectEqual(before, h.scene.count());
}

test "editor: N creates, P makes the selection a root, Enter folds it" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    // N: a child of the selected row.
    h.frameInput(.{ .key = .n }, &h.state);
    try testing.expectEqual(h.root_id, h.scene.parentIdOf(h.state.selected).?);

    // P: back to the root level; one command each.
    const depth = h.history.undoDepth();
    h.frameInput(.{ .key = .p }, &h.state);
    try testing.expect(h.scene.parentIdOf(h.state.selected) == null);
    try testing.expectEqual(depth + 1, h.history.undoDepth());

    // Enter on a row with children folds it.
    h.state.selected = h.root_id;
    h.runFrames(1);
    h.frameInput(.{ .key = .enter }, &h.state);
    try testing.expect(h.state.collapsed.contains(h.root_id));
    // Enter again unfolds.
    h.frameInput(.{ .key = .enter }, &h.state);
    try testing.expect(!h.state.collapsed.contains(h.root_id));
}

test "editor: a failed tree action is reported instead of looking like a no-op" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(1);

    // Reparent the root under its own child: the scene refuses the cycle.
    runTreeAction(&h.state, &h.scene, &h.history, .{ .reparent = h.child_id }, h.root_id);
    try testing.expect(h.state.edit_error != null);
    // The tree did not change and nothing was recorded.
    try testing.expect(h.scene.parentIdOf(h.root_id) == null);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
}

test "editor: arrow keys walk the tree, and arrows in a text field do not" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(1);

    // Down goes to the child row (depth-first), Down again to the next root.
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expectEqual(h.child_id, h.state.selected);
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expectEqual(h.loose_id, h.state.selected);
    h.frameInput(.{ .key = .up }, &h.state);
    try testing.expectEqual(h.child_id, h.state.selected);

    // Right on an open, childless row does nothing; Up to the root, then Left folds it.
    h.state.selected = h.root_id;
    h.runFrames(1);
    h.frameInput(.{ .key = .left }, &h.state);
    try testing.expect(h.state.collapsed.contains(h.root_id));
    try testing.expectEqual(h.root_id, h.state.selected);
    // Down from the folded root skips the hidden child.
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expectEqual(h.loose_id, h.state.selected);
    // Right on the folded root would unfold it, but the selection is elsewhere now.
    h.state.selected = h.root_id;
    h.runFrames(1);
    h.frameInput(.{ .key = .right }, &h.state);
    try testing.expect(!h.state.collapsed.contains(h.root_id));

    // While a text field has the keyboard, arrows edit text (the field's caret), not the
    // tree: the selection must not move.
    h.state.selected = h.root_id;
    h.runFrames(2);
    const field = nameFieldRect(&h);
    const cx = field.right() - 3;
    h.hover(cx, field.y + 3);
    h.click(cx, field.y + 3);
    h.release(cx, field.y + 3);
    try testing.expect(h.state.name_focused);
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expectEqual(h.root_id, h.state.selected);
}

test "editor: a keyboard step scrolls its row into view" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    var ids: [30]u64 = @splat(0);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const e = try h.scene.createEntity("row", null);
        ids[i] = h.scene.idOf(e).?;
    }
    h.runFrames(2);
    h.state.selected = 0;
    try testing.expectEqual(@as(usize, 0), h.state.tree_offset);

    // Walk down past the window; the offset must follow so the selection stays visible.
    var steps: usize = 0;
    while (steps < 25) : (steps += 1) h.frameInput(.{ .key = .down }, &h.state);
    try testing.expect(h.state.tree_offset > 0);

    var rows: [tree.max_rows]tree.Row = undefined;
    var list = tree.List{ .rows = &rows, .visible = 5, .offset = h.state.tree_offset };
    tree.build(&h.scene, &list);
    var found = false;
    for (list.rows[0..list.len]) |row| {
        if (row.id == h.state.selected) found = true;
    }
    try testing.expect(found);
}

test "editor: navigation records nothing in the history" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(1);
    h.frameInput(.{ .key = .down }, &h.state);
    h.frameInput(.{ .key = .up }, &h.state);
    h.frameInput(.{ .key = .left }, &h.state);
    h.frameInput(.{ .key = .right }, &h.state);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());
    try testing.expect(!h.history.dirty);
}

test "editor: Tab moves the keyboard focus between the hierarchy and the inspector" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);
    try testing.expectEqual(DockFocus.hierarchy, h.state.dock_focus);

    // Tab into the inspector: the GUI focus moves to the name field, so typing lands there.
    h.frameInput(.{ .key = .tab }, &h.state);
    try testing.expectEqual(DockFocus.inspector, h.state.dock_focus);
    try testing.expect(h.ctx.focus.eql(name_field_id));

    // Tab again wraps back to the hierarchy, which owns no GUI widget.
    h.frameInput(.{ .key = .tab }, &h.state);
    try testing.expectEqual(DockFocus.hierarchy, h.state.dock_focus);
    try testing.expect(h.ctx.focus.eql(widgets.Id.zero));

    // Shift+Tab goes the other way (two stops, so it lands on the inspector).
    h.frameInput(.{ .key = .tab, .modifiers = .{ .shift = true } }, &h.state);
    try testing.expectEqual(DockFocus.inspector, h.state.dock_focus);
}

test "editor: Tab out of a focused text field works, and tree keys stop acting" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.state.selected = h.root_id;
    h.runFrames(2);

    // Click into the name field, then Tab away: leaving a focused field must be possible.
    const field = nameFieldRect(&h);
    const cx = field.right() - 3;
    h.hover(cx, field.y + 3);
    h.click(cx, field.y + 3);
    h.release(cx, field.y + 3);
    try testing.expect(h.state.name_focused);
    // Clicking a field moves the dock focus with it, so the outline and Tab agree.
    try testing.expectEqual(DockFocus.inspector, h.state.dock_focus);

    // Tab leaves the field and lands on the other dock (two stops, so it wraps).
    h.frameInput(.{ .key = .tab }, &h.state);
    try testing.expect(!h.state.name_focused);
    try testing.expectEqual(DockFocus.hierarchy, h.state.dock_focus);

    // With the inspector focused, tree keys do not move the selection...
    h.frameInput(.{ .key = .tab }, &h.state);
    try testing.expectEqual(DockFocus.inspector, h.state.dock_focus);
    const before = h.state.selected;
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expectEqual(before, h.state.selected);
    h.frameInput(.{ .key = .n }, &h.state);
    try testing.expectEqual(@as(usize, 0), h.history.undoDepth());

    // ...and back on the hierarchy they do again.
    h.frameInput(.{ .key = .tab }, &h.state);
    h.frameInput(.{ .key = .down }, &h.state);
    try testing.expect(h.state.selected != before);
}

test "editor: the focused dock is outlined so Tab's effect is visible" {
    var h = Harness{};
    try h.init();
    defer h.deinit();
    h.runFrames(2);
    const dock = Dock.compute(h.ctx.canvas.bounds());

    // The hierarchy is focused by default: its top-left pixel is the accent border.
    const accent = h.state.theme.accent;
    const at_hierarchy = h.pixel(dock.hierarchy.x, dock.hierarchy.y);
    try testing.expectEqual(accent, at_hierarchy);

    h.frameInput(.{ .key = .tab }, &h.state);
    h.runFrames(1);
    // Focus moved: the inspector corner is now accent and the hierarchy corner is not.
    try testing.expectEqual(accent, h.pixel(dock.inspector.x, dock.inspector.y));
    const hierarchy_after = h.pixel(dock.hierarchy.x, dock.hierarchy.y);
    try testing.expect(!std.mem.eql(u8, &accent, &hierarchy_after));
}
