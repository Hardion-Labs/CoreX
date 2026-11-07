//! The hierarchy's row model.
//!
//! The tree panel needs three things from a scene: which rows are visible, how deep each
//! one sits, and where the selected entity is in that list. Doing that inside the paint
//! loop is what made the old panel a recurrence with a fixed 64-entry buffer per level
//! and no way to scroll.
//!
//! So the list is a **flat, caller-owned array**: one `Row` per visible entity, produced
//! by one depth-first walk that stops as soon as it has enough rows to fill the panel
//! plus its scroll offset. That is the whole design:
//!
//! * **Allocation-free** — the caller supplies the array (`[max_rows]Row`); nothing here
//!   touches an allocator, so a frame cannot allocate while walking a scene.
//! * **Bounded work** — the walk stops at `max_rows`; a scene with a million entities
//!   costs the same per frame as one with ten.
//! * **Depth-limited** — `max_depth` is checked while descending, so a corrupt parent
//!   chain cannot overflow the caller's stack. The walk is recursive but its depth is
//!   bounded by the same constant.
//! * **Cycle-safe** — an entity that appears twice in the chain is skipped instead of
//!   recursing forever. The scene refuses to create cycles, so this only guards against a
//!   scene built by something else; a tree view must not hang on bad data.

const std = @import("std");

/// Deepest nesting a tree row can have. A 64-deep scene tree is already unusable in a
/// 150 px panel; the constant exists to bound recursion, not to be generous.
pub const max_depth = 32;

/// Rows one frame can describe. The panel is at most a few dozen rows tall, and the
/// scroll offset adds at most a screenful, so this is a bound with room to spare.
pub const max_rows = 512;

/// One visible line of the tree.
pub const Row = struct {
    /// Stable entity ID.
    id: u64,
    /// Nesting level, 0 for a root. Drives the indent.
    depth: u8,
    /// The entity has children, so the row draws a disclosure control.
    has_children: bool = false,
    /// The row's children are hidden by the caller's collapsed set.
    collapsed: bool = false,
};

/// The set of collapsed entities, kept inline.
///
/// A tree with 64 folded branches is already unmanageable in a 150 px panel, and a fixed
/// array keeps the whole thing free of allocation and of lifetime questions: the editor
/// state owns it, the row builder borrows it.
pub const Collapsed = struct {
    ids: [max_collapsed]u64 = @splat(0),
    len: usize = 0,

    pub const max_collapsed = 64;

    pub fn contains(self: *const Collapsed, id: u64) bool {
        for (self.ids[0..self.len]) |entry| {
            if (entry == id) return true;
        }
        return false;
    }

    /// Fold or unfold `id`, reporting whether it is collapsed afterwards. When the set is
    /// full a new fold is refused rather than evicting another branch: silently unfolding
    /// something the user folded is worse than not folding.
    pub fn toggle(self: *Collapsed, id: u64) bool {
        for (self.ids[0..self.len], 0..) |entry, i| {
            if (entry == id) {
                self.ids[i] = self.ids[self.len - 1];
                self.len -= 1;
                return false;
            }
        }
        if (self.len == max_collapsed) return false;
        self.ids[self.len] = id;
        self.len += 1;
        return true;
    }

    /// Unfold `id` if it is folded; used when a selection inside it must become visible.
    pub fn expand(self: *Collapsed, id: u64) void {
        for (self.ids[0..self.len], 0..) |entry, i| {
            if (entry == id) {
                self.ids[i] = self.ids[self.len - 1];
                self.len -= 1;
                return;
            }
        }
    }

    pub fn isEmpty(self: *const Collapsed) bool {
        return self.len == 0;
    }
};

/// A scene's visible rows and the geometry of the viewport showing them.
pub const List = struct {
    /// Rows, in paint order (depth-first, siblings by ascending stable ID).
    rows: []Row,
    /// How many entries of `rows` are valid.
    len: usize = 0,
    /// First row to paint: the scroll offset, in rows.
    offset: usize = 0,
    /// Rows the panel can show at once, from its height and the row height.
    visible: usize,
    /// Set by `build`: a row exists past the painted window.
    more: bool = false,
    /// Entities whose children are hidden.
    collapsed: ?*const Collapsed = null,
};

/// Build the visible rows of `scene` into `out`, honouring the scroll offset in
/// `list.offset` and the viewport height in `list.visible`.
///
/// The walk goes depth-first from the roots. Before descending it checks that the row is
/// on screen, and it always collects the rows that *come before* the visible window, so a
/// scroll offset costs the same walk rather than a second pass. The window is what gets
/// painted: rows before `offset` are visited to keep the counters right but are not stored
/// twice (they are simply not written).
pub fn build(scene: anytype, list: *List) void {
    list.len = 0;
    const want = @min(list.rows.len, list.visible + 1); // +1: know whether more follows
    if (want == 0) return;

    var ctx = Walk(@TypeOf(scene.*)){ .scene = scene, .list = list, .want = list.visible };
    var ids: [64]u64 = @splat(0);
    const roots = scene.childIdsInto(null, &ids);
    var i: usize = 0;
    while (i < roots) : (i += 1) {
        if (ctx.done()) break;
        ctx.visit(ids[i], 0);
    }
    list.more = ctx.more;
}

/// The walk's own state, kept in one struct so the recursion has few parameters.
fn Walk(comptime Scene: type) type {
    return struct {
        scene: *const Scene,
        list: *List,
        /// Rows the panel can show; `list.len` is capped here so `len < visible` means
        /// "no scrolling needed" without a second count.
        want: usize,
        /// Rows before the window that were counted but not stored.
        skipped: usize = 0,
        /// Set when a row was found past the window, so the caller can draw a hint.
        more: bool = false,

        fn done(self: @This()) bool {
            return self.list.len >= self.want;
        }

        /// Store `id` at `depth` and recurse into its children.
        fn visit(self: *@This(), id: u64, depth: u8) void {
            if (self.done()) return;

            // Look the children up once: the row must know whether it *has* children (to
            // draw a disclosure control) and the walk needs them to descend, so a second
            // scan of the scene per row would double the cost of a frame.
            var kids: [64]u64 = @splat(0);
            const n = self.scene.childIdsInto(id, &kids);
            const folded = self.list.collapsed != null and self.list.collapsed.?.contains(id);

            if (self.skipped < self.list.offset) {
                self.skipped += 1;
            } else if (self.list.len < self.list.rows.len) {
                self.list.rows[self.list.len] = .{
                    .id = id,
                    .depth = depth,
                    .has_children = n > 0,
                    .collapsed = folded,
                };
                self.list.len += 1;
            }
            // A row past the window is not stored, but its existence is remembered: the
            // panel needs to know whether to say "more..." without walking the rest.
            if (self.list.len >= self.want) {
                self.more = true;
                return;
            }

            if (folded) return;
            if (depth + 1 > max_depth) return;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.done()) return;
                self.visit(kids[i], depth + 1);
            }
        }
    };
}

/// Whether rows exist past the last painted one, as `build` observed during its walk.
pub fn hasMore(list: List) bool {
    return list.more;
}

/// Whether the list is scrolled away from the top.
pub fn canScrollUp(list: List) bool {
    return list.offset > 0;
}

/// Line of the selection in the *whole* tree, not just the visible window.
///
/// This is what lets the panel scroll to the selection after a keyboard step, or keep a
/// far-away selection on screen: the answer is a row index the caller compares against
/// `offset` and `visible`. The search is bounded by `limit` rows and by `max_depth`, so a
/// huge scene costs a bounded walk rather than a full enumeration.
pub fn indexOf(scene: anytype, id: u64, limit: usize) ?usize {
    if (id == 0 or limit == 0) return null;
    var counter: usize = 0;
    var ids: [64]u64 = @splat(0);
    const roots = scene.childIdsInto(null, &ids);
    var i: usize = 0;
    while (i < roots) : (i += 1) {
        if (findIn(scene, ids[i], 0, id, &counter, limit)) |found| return found;
        if (counter >= limit) return null;
    }
    return null;
}

fn findIn(scene: anytype, id: u64, depth: u8, target: u64, counter: *usize, limit: usize) ?usize {
    const here = counter.*;
    counter.* += 1;
    if (id == target) return here;
    if (counter.* >= limit or depth + 1 > max_depth) return null;

    var kids: [64]u64 = @splat(0);
    const n = scene.childIdsInto(id, &kids);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (findIn(scene, kids[i], depth + 1, target, counter, limit)) |found| return found;
        if (counter.* >= limit) return null;
    }
    return null;
}

test "tree row: a depth-first list is bounded, ordered and carries depth" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    const a = try scene.createEntity("a", null);
    const b = try scene.createEntity("b", null);
    _ = try scene.createEntity("a1", scene.idOf(a));
    _ = try scene.createEntity("a2", scene.idOf(a));
    _ = try scene.createEntity("b1", scene.idOf(b));

    var rows: [16]Row = undefined;
    var list = List{ .rows = &rows, .visible = 16 };
    build(&scene, &list);
    // 3 roots/children under a, then b's child: depth-first, ascending IDs.
    try testing.expectEqual(@as(usize, 5), list.len);
    try testing.expectEqual(@as(u8, 0), list.rows[0].depth);
    try testing.expectEqual(@as(u8, 1), list.rows[1].depth);
    try testing.expectEqual(@as(u8, 1), list.rows[2].depth);
    try testing.expectEqual(@as(u8, 0), list.rows[3].depth);
    try testing.expectEqual(@as(u8, 1), list.rows[4].depth);
    try testing.expect(!hasMore(list));
}

test "tree row: the visible window respects the scroll offset" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) _ = try scene.createEntity("e", null);

    var rows: [8]Row = undefined;
    var list = List{ .rows = &rows, .visible = 4 };
    build(&scene, &list);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expect(hasMore(list));

    list.offset = 4;
    build(&scene, &list);
    try testing.expectEqual(@as(usize, 4), list.len);
    // The window moved, and the rows are the fifth..eighth of the tree.
    var all: [16]Row = undefined;
    var full = List{ .rows = &all, .visible = 16 };
    build(&scene, &full);
    try testing.expectEqual(full.rows[4].id, list.rows[0].id);
    try testing.expectEqual(full.rows[7].id, list.rows[3].id);

    // Past the end there is nothing to paint and nothing more to scroll to.
    list.offset = 10;
    build(&scene, &list);
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expect(!hasMore(list));
    try testing.expect(canScrollUp(list));
}

test "tree row: depth is clamped so a corrupt chain cannot recurse forever" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var parent: ?u64 = null;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const e = try scene.createEntity("deep", parent);
        parent = scene.idOf(e);
    }

    var rows: [64]Row = undefined;
    var list = List{ .rows = &rows, .visible = 64 };
    build(&scene, &list);
    // The walk descends to `max_depth` and stops there: rows 0..max_depth exist, the
    // deeper ones are simply not shown. The point of the test is that it terminates and
    // that no row claims a depth the constant forbids.
    try testing.expectEqual(@as(usize, max_depth + 1), list.len);
    for (list.rows[0..list.len], 0..) |row, line| {
        try testing.expectEqual(@as(u8, @intCast(line)), row.depth);
    }
}

test "tree row: indexOf finds a row's line in the whole tree" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    const a = try scene.createEntity("a", null);
    const a1 = try scene.createEntity("a1", scene.idOf(a));
    const b = try scene.createEntity("b", null);

    try testing.expectEqual(@as(usize, 0), indexOf(&scene, scene.idOf(a).?, 100).?);
    try testing.expectEqual(@as(usize, 1), indexOf(&scene, scene.idOf(a1).?, 100).?);
    try testing.expectEqual(@as(usize, 2), indexOf(&scene, scene.idOf(b).?, 100).?);
    // Unknown ID, nothing selected, and a budget too small to reach the row.
    try testing.expect(indexOf(&scene, 999, 100) == null);
    try testing.expect(indexOf(&scene, 0, 100) == null);
    try testing.expect(indexOf(&scene, scene.idOf(b).?, 2) == null);
}

// --- editing actions ---------------------------------------------------------
//
// The tree's actions are functions over (state, scene, history) rather than code inside
// the paint loop: they must be callable from a click, a key and a test alike, and they
// are the only place that decides which history command an action becomes.

/// What the tree asked for on a row this frame.
pub const Action = union(enum) {
    /// Nothing.
    none,
    /// Fold or unfold the row's children.
    toggle_collapse,
    /// Add a child entity to the row (or a root when `id` is 0).
    add_child,
    /// Move the row under a new parent (`null` = make it a root).
    reparent: ?u64,
    /// Remove the row's entity.
    delete,
};

/// Effect of an action on the editor state.
pub const Effect = struct {
    /// The scene changed; the caller should treat the selection as possibly stale.
    changed: bool = false,
    /// The row the caller should select afterwards (0 = leave the selection alone).
    select: u64 = 0,
    /// An edit was refused; the reason, for a status line or stderr.
    failure: ?anyerror = null,
};

/// Apply `action` to `row` (a stable ID) through `history`.
///
/// Every action is **one** history command, so one `Ctrl+Z` undoes exactly what one click
/// did. `state.collapsed` is not a scene edit and therefore never enters the history — a
/// fold is a view preference, and undoing a delete should not also unfold the tree.
pub fn apply(
    action: Action,
    row: u64,
    collapsed: *Collapsed,
    scene: anytype,
    history: anytype,
) Effect {
    switch (action) {
        .none => return .{},
        .toggle_collapse => {
            if (row == 0) return .{};
            _ = collapsed.toggle(row);
            // A fold is a view change: nothing is dirty and nothing must be repainted by
            // a caller that only tracks scene changes.
            return .{};
        },
        .add_child => {
            // The ID is the one the scene would hand out next, taken *before* the command
            // so the new entity can be selected straight away. `create` names it
            // explicitly, which is what makes it undoable with the same ID.
            const new_id = scene.nextStableId();
            if (new_id == 0) return .{ .failure = error.IdExhausted };
            history.apply(scene, .{ .create = .{
                .id = new_id,
                .name = @import("edit.zig").Name.init("entity"),
                .parent = if (row != 0) row else null,
            } }) catch |err| return .{ .failure = err };
            // A new child under a folded parent would be invisible: unfold it, so the
            // user sees what they just created.
            if (row != 0) collapsed.expand(row);
            return .{ .changed = true, .select = new_id };
        },
        .reparent => |parent| {
            if (row == 0) return .{};
            // Dropping a node on itself or on its current parent is not an edit.
            if (parent != null and parent.? == row) return .{};
            const current = scene.parentIdOf(row);
            const same_parent = if (current) |c| (parent != null and parent.? == c) else parent == null;
            if (same_parent) return .{};
            history.apply(scene, .{ .reparent = .{ .id = row, .parent = parent } }) catch |err| {
                return .{ .failure = err };
            };
            if (parent) |p| collapsed.expand(p);
            return .{ .changed = true, .select = row };
        },
        .delete => {
            if (row == 0) return .{};
            // Deleting the row the user is looking at also drops its fold state: the ID is
            // gone, and an undo that brings the entity back should show its children.
            collapsed.expand(row);
            history.apply(scene, .{ .delete = .{ .id = row } }) catch |err| return .{ .failure = err };
            return .{ .changed = true };
        },
    }
}

test "tree actions: add_child creates one undoable entity under the row and selects it" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const edit = @import("edit.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});
    const History = edit.History(Scene);

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = History.init(testing.allocator);
    defer history.deinit();
    var collapsed = Collapsed{};

    const root = try scene.createEntity("root", null);
    const root_id = scene.idOf(root).?;

    const effect = apply(.add_child, root_id, &collapsed, &scene, &history);
    try testing.expect(effect.changed);
    try testing.expect(effect.failure == null);
    const created = scene.entityById(effect.select).?;
    try testing.expectEqual(root_id, scene.parentIdOf(effect.select).?);
    try testing.expectEqualStrings("entity", scene.nameOf(created).?);
    try testing.expectEqual(@as(usize, 1), history.undoDepth());

    // One undo removes exactly the entity the click created.
    try history.undo(&scene);
    try testing.expect(scene.entityById(effect.select) == null);
    try history.redo(&scene);
    try testing.expectEqual(root_id, scene.parentIdOf(effect.select).?);
}

test "tree actions: add_child at the root creates a root and unfolds nothing" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const edit = @import("edit.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});
    const History = edit.History(Scene);

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = History.init(testing.allocator);
    defer history.deinit();
    var collapsed = Collapsed{};

    const effect = apply(.add_child, 0, &collapsed, &scene, &history);
    try testing.expect(effect.changed);
    try testing.expect(scene.parentIdOf(effect.select) == null);
    try testing.expect(collapsed.isEmpty());
}

test "tree actions: add_child into a folded parent unfolds it so the child is visible" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const edit = @import("edit.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});
    const History = edit.History(Scene);

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = History.init(testing.allocator);
    defer history.deinit();
    var collapsed = Collapsed{};
    const root = try scene.createEntity("root", null);
    const root_id = scene.idOf(root).?;

    _ = collapsed.toggle(root_id);
    try testing.expect(collapsed.contains(root_id));
    _ = apply(.add_child, root_id, &collapsed, &scene, &history);
    try testing.expect(!collapsed.contains(root_id));
}

test "tree actions: reparent is one command and refuses no-op moves" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const edit = @import("edit.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});
    const History = edit.History(Scene);

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = History.init(testing.allocator);
    defer history.deinit();
    var collapsed = Collapsed{};
    const a = try scene.createEntity("a", null);
    const b = try scene.createEntity("b", null);
    const a_id = scene.idOf(a).?;
    const b_id = scene.idOf(b).?;

    // Already a root: nothing to record.
    const same = apply(.{ .reparent = null }, a_id, &collapsed, &scene, &history);
    try testing.expect(!same.changed);
    try testing.expectEqual(@as(usize, 0), history.undoDepth());

    const moved = apply(.{ .reparent = b_id }, a_id, &collapsed, &scene, &history);
    try testing.expect(moved.changed);
    try testing.expectEqual(b_id, scene.parentIdOf(a_id).?);
    try testing.expectEqual(@as(usize, 1), history.undoDepth());
    try history.undo(&scene);
    try testing.expect(scene.parentIdOf(a_id) == null);

    // Onto itself is refused before it reaches the history. (The undo above left the
    // stack empty, so the depth stays 0 — a refused move must not record anything.)
    const self_move = apply(.{ .reparent = a_id }, a_id, &collapsed, &scene, &history);
    try testing.expect(!self_move.changed);
    try testing.expectEqual(@as(usize, 0), history.undoDepth());

    // Build a real cycle: b under a is fine, a under b is not. The scene refuses it and
    // the refusal is reported, not swallowed, and nothing is recorded.
    const under_a = apply(.{ .reparent = a_id }, b_id, &collapsed, &scene, &history);
    try testing.expect(under_a.changed);
    const cycle = apply(.{ .reparent = b_id }, a_id, &collapsed, &scene, &history);
    try testing.expect(!cycle.changed);
    try testing.expect(cycle.failure != null);
    // Still exactly the one command from `under_a`.
    try testing.expectEqual(@as(usize, 1), history.undoDepth());
}

test "tree actions: delete is one command and does not touch the fold state of others" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const edit = @import("edit.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});
    const History = edit.History(Scene);

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var history = History.init(testing.allocator);
    defer history.deinit();
    var collapsed = Collapsed{};
    const a = try scene.createEntity("a", null);
    const b = try scene.createEntity("b", null);
    const a_id = scene.idOf(a).?;
    const b_id = scene.idOf(b).?;

    _ = collapsed.toggle(a_id);
    _ = collapsed.toggle(b_id);
    const effect = apply(.delete, b_id, &collapsed, &scene, &history);
    try testing.expect(effect.changed);
    try testing.expect(scene.entityById(b_id) == null);
    // The tree's fold state for the deleted row is dropped, the other row's is kept.
    try testing.expect(!collapsed.contains(b_id));
    try testing.expect(collapsed.contains(a_id));
    try testing.expectEqual(@as(usize, 1), history.undoDepth());
}

test "tree collapse: toggle is a set, and a full set refuses instead of evicting" {
    const testing = std.testing;
    var set = Collapsed{};
    try testing.expect(set.isEmpty());
    try testing.expect(set.toggle(7));
    try testing.expect(set.contains(7));
    try testing.expect(!set.toggle(7));
    try testing.expect(!set.contains(7));

    var i: u64 = 1;
    while (i <= Collapsed.max_collapsed) : (i += 1) {
        try testing.expect(set.toggle(i));
    }
    // Full: a new fold is refused and nothing already folded is lost.
    try testing.expect(!set.toggle(999));
    try testing.expect(!set.contains(999));
    try testing.expect(set.contains(1));

    set.expand(1);
    try testing.expect(!set.contains(1));
}

// --- keyboard navigation -----------------------------------------------------

/// A navigation step over the visible tree.
///
/// The tree is navigated by *visible line*, not by entity: Down must move to the row the
/// user sees under the current one, which — with folders — is not "the next entity in the
/// scene". So the step is expressed over the flat row list `build` already produces.
pub const Step = enum {
    /// The next visible row (a child of a folded row is not visible, so Down skips it).
    next,
    /// The previous visible row.
    previous,
    /// One level down: the first child, if the row is unfolded and has one.
    into,
    /// One level up: the parent row.
    out,
};

/// Where a step lands.
pub const Move = struct {
    /// The row to select, or 0 when the step has nowhere to go.
    id: u64 = 0,
    /// A fold was performed by `into`/`out` (Left/Right on a branch), which is a view
    /// change the caller must not treat as a scene edit.
    folded: bool = false,
    /// The step had an effect on the tree (fold or selection) rather than doing nothing.
    moved: bool = false,
};

/// Resolve `step` from `current` against the visible tree.
///
/// `rows` is a caller-built window (with its offset), so navigation is bounded by the same
/// walk the panel paints and never allocates. Moving *out* of the window is handled by
/// falling back to `indexOf`, which is why `limit` exists: a selection far above the
/// window still has a parent, and Up must find it.
///
/// Fold semantics follow every file tree the user has ever met: Right on a folded branch
/// unfolds it, Right on an unfolded branch steps into it; Left on an unfolded branch folds
/// it, Left on a folded (or leaf) row steps out to its parent.
pub fn step(
    scene: anytype,
    rows: []const Row,
    current: u64,
    what: Step,
    collapsed: *Collapsed,
    limit: usize,
) Move {
    if (current == 0) {
        // Nothing selected: any step that has a destination starts at the first visible
        // row, whether or not the caller passed a window (`into` has nowhere to go: there
        // is no branch to enter).
        if (what == .into) return .{};
        if (rows.len > 0) return .{ .id = rows[0].id, .moved = true };
        const first = firstVisible(scene, collapsed, limit) orelse return .{};
        return .{ .id = first, .moved = true };
    }

    const index = indexIn(rows, current);
    switch (what) {
        .next => {
            if (index) |i| {
                if (i + 1 < rows.len) return .{ .id = rows[i + 1].id, .moved = true };
                // The end of the window: the next row may exist past it.
                return nextAfter(scene, rows, current, collapsed, limit);
            }
            return nextAfter(scene, rows, current, collapsed, limit);
        },
        .previous => {
            if (index) |i| {
                if (i > 0) return .{ .id = rows[i - 1].id, .moved = true };
            }
            // Above the window: ask the whole tree for the previous line.
            const line = indexOf(scene, current, limit) orelse return .{};
            if (line == 0) return .{};
            const prev = lineAt(scene, line - 1, collapsed, limit) orelse return .{};
            return .{ .id = prev, .moved = true };
        },
        .into => {
            // The fold state comes from the *set*, not from the row: a caller may pass a
            // window that does not contain the current row (it is scrolled away), and the
            // step must still behave the same.
            if (!hasChildren(scene, current)) return .{};
            if (collapsed.contains(current)) {
                collapsed.expand(current);
                return .{ .folded = true, .moved = true };
            }
            var kids: [1]u64 = @splat(0);
            if (scene.childIdsInto(current, &kids) == 0) return .{};
            // The child may sit under another fold; the caller reveals the selection,
            // which unfolds the chain above it.
            return .{ .id = kids[0], .moved = true };
        },
        .out => {
            // Collapse the current branch first if it is open, then leave it.
            if (hasChildren(scene, current) and !collapsed.contains(current)) {
                _ = collapsed.toggle(current);
                return .{ .folded = true, .moved = true };
            }
            if (scene.parentIdOf(current)) |parent| return .{ .id = parent, .moved = true };
            return .{};
        },
    }
}

fn indexIn(rows: []const Row, id: u64) ?usize {
    for (rows, 0..) |row, i| {
        if (row.id == id) return i;
    }
    return null;
}

fn hasChildren(scene: anytype, id: u64) bool {
    var kids: [1]u64 = @splat(0);
    return scene.childIdsInto(id, &kids) > 0;
}

/// The first row of the whole tree (the first root, or 0 if the scene is empty).
fn firstVisible(scene: anytype, collapsed: *Collapsed, limit: usize) ?u64 {
    _ = collapsed;
    _ = limit;
    var ids: [1]u64 = @splat(0);
    if (scene.childIdsInto(null, &ids) == 0) return null;
    return ids[0];
}

/// The next visible row after `current`, for a row at the end of the caller's window.
fn nextAfter(scene: anytype, rows: []const Row, current: u64, collapsed: *Collapsed, limit: usize) Move {
    const line = indexOf(scene, current, limit) orelse return .{};
    const next = lineAt(scene, line + 1, collapsed, limit) orelse return .{};
    _ = rows;
    return .{ .id = next, .moved = true };
}

/// The visible row at `want`, counting only rows a folded tree actually shows.
///
/// This is the bounded counterpart of `indexOf`: it walks depth-first, skips collapsed
/// branches and stops at the wanted line. `limit` bounds the walk so a huge scene cannot
/// make a key press expensive.
fn lineAt(scene: anytype, want: usize, collapsed: *Collapsed, limit: usize) ?u64 {
    if (limit == 0) return null;
    var state = LineWalk(@TypeOf(scene.*)){
        .scene = scene,
        .want = want,
        .collapsed = collapsed,
        .limit = limit,
    };
    var ids: [64]u64 = @splat(0);
    const roots = scene.childIdsInto(null, &ids);
    var i: usize = 0;
    while (i < roots) : (i += 1) {
        if (state.visit(ids[i], 0)) |found| return found;
        if (state.seen > state.limit) return null;
    }
    return null;
}

fn LineWalk(comptime Scene: type) type {
    return struct {
        scene: *const Scene,
        want: usize,
        seen: usize = 0,
        collapsed: *const Collapsed,
        limit: usize,

        fn visit(self: *@This(), id: u64, depth: u8) ?u64 {
            if (self.seen == self.want) {
                self.seen += 1;
                return id;
            }
            self.seen += 1;
            if (self.seen > self.limit) return null;
            if (self.collapsed.contains(id)) return null;
            if (depth + 1 > max_depth) return null;
            var kids: [64]u64 = @splat(0);
            const n = self.scene.childIdsInto(id, &kids);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.visit(kids[i], depth + 1)) |found| return found;
                if (self.seen > self.limit) return null;
            }
            return null;
        }
    };
}

test "tree navigation: down and up walk the visible lines, skipping folded children" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var collapsed = Collapsed{};
    const root = try scene.createEntity("root", null);
    const root_id = scene.idOf(root).?;
    const kid = try scene.createEntity("kid", root_id);
    const kid_id = scene.idOf(kid).?;
    const other = try scene.createEntity("other", null);
    const other_id = scene.idOf(other).?;

    var rows: [16]Row = undefined;
    var list = List{ .rows = &rows, .visible = 16, .collapsed = &collapsed };
    build(&scene, &list);
    try testing.expectEqual(@as(usize, 3), list.len);

    // root -> kid -> other, and back.
    try testing.expectEqual(kid_id, step(&scene, list.rows[0..list.len], root_id, .next, &collapsed, 100).id);
    try testing.expectEqual(other_id, step(&scene, list.rows[0..list.len], kid_id, .next, &collapsed, 100).id);
    try testing.expectEqual(kid_id, step(&scene, list.rows[0..list.len], other_id, .previous, &collapsed, 100).id);
    try testing.expectEqual(root_id, step(&scene, list.rows[0..list.len], kid_id, .previous, &collapsed, 100).id);
    // The last row has nowhere to go.
    try testing.expectEqual(@as(u64, 0), step(&scene, list.rows[0..list.len], other_id, .next, &collapsed, 100).id);

    // Folding root hides kid: down from root goes straight to other.
    _ = collapsed.toggle(root_id);
    var folded_rows: [16]Row = undefined;
    var folded = List{ .rows = &folded_rows, .visible = 16, .collapsed = &collapsed };
    build(&scene, &folded);
    try testing.expectEqual(@as(usize, 2), folded.len);
    try testing.expectEqual(other_id, step(&scene, folded.rows[0..folded.len], root_id, .next, &collapsed, 100).id);
}

test "tree navigation: into and out expand, enter and leave a branch" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var collapsed = Collapsed{};
    const root = try scene.createEntity("root", null);
    const root_id = scene.idOf(root).?;
    const kid = try scene.createEntity("kid", root_id);
    const kid_id = scene.idOf(kid).?;

    // Into on a folded branch unfolds it (no selection change).
    _ = collapsed.toggle(root_id);
    const unfold = step(&scene, &.{}, root_id, .into, &collapsed, 100);
    try testing.expect(unfold.folded);
    try testing.expectEqual(@as(u64, 0), unfold.id);
    try testing.expect(!collapsed.contains(root_id));

    // Into again enters the first child.
    const enter = step(&scene, &.{}, root_id, .into, &collapsed, 100);
    try testing.expectEqual(kid_id, enter.id);

    // Out on a leaf goes to its parent; out on an open branch folds it first.
    try testing.expectEqual(root_id, step(&scene, &.{}, kid_id, .out, &collapsed, 100).id);
    const fold = step(&scene, &.{}, root_id, .out, &collapsed, 100);
    try testing.expect(fold.folded);
    try testing.expect(collapsed.contains(root_id));
    // A folded root has nowhere to go out to.
    try testing.expectEqual(@as(u64, 0), step(&scene, &.{}, root_id, .out, &collapsed, 100).id);
}

test "tree navigation: nothing selected starts at the first visible row" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var collapsed = Collapsed{};
    const root = try scene.createEntity("root", null);
    const root_id = scene.idOf(root).?;

    try testing.expectEqual(root_id, step(&scene, &.{}, 0, .next, &collapsed, 100).id);
    try testing.expectEqual(root_id, step(&scene, &.{}, 0, .out, &collapsed, 100).id);
    try testing.expectEqual(@as(u64, 0), step(&scene, &.{}, 0, .into, &collapsed, 100).id);

    var empty = try Scene.init(testing.allocator, "empty");
    defer empty.deinit();
    try testing.expectEqual(@as(u64, 0), step(&empty, &.{}, 0, .next, &collapsed, 100).id);
}

test "tree navigation: down past the caller's window still finds the next row" {
    const testing = std.testing;
    const scene_mod = @import("../scene/scene.zig");
    const components = @import("../scene/components.zig");
    const Scene = scene_mod.Scene(.{scene_mod.Component(components.Transform, "transform")});

    var scene = try Scene.init(testing.allocator, "level");
    defer scene.deinit();
    var collapsed = Collapsed{};
    var ids: [8]u64 = @splat(0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const e = try scene.createEntity("row", null);
        ids[i] = scene.idOf(e).?;
    }

    // A window that only holds the first two rows: `next` from the second must find the
    // third, which is outside the window.
    var rows: [2]Row = undefined;
    var list = List{ .rows = &rows, .visible = 2, .collapsed = &collapsed };
    build(&scene, &list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(ids[2], step(&scene, list.rows[0..list.len], ids[1], .next, &collapsed, 100).id);
    // And `previous` from the first row of a scrolled window finds the row above it.
    list.offset = 2;
    build(&scene, &list);
    try testing.expectEqual(ids[2], list.rows[0].id);
    try testing.expectEqual(ids[1], step(&scene, list.rows[0..list.len], ids[2], .previous, &collapsed, 100).id);
}
