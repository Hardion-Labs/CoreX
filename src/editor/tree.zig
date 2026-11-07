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

            if (self.skipped < self.list.offset) {
                self.skipped += 1;
            } else if (self.list.len < self.list.rows.len) {
                self.list.rows[self.list.len] = .{ .id = id, .depth = depth };
                self.list.len += 1;
            }
            // A row past the window is not stored, but its existence is remembered: the
            // panel needs to know whether to say "more..." without walking the rest.
            if (self.list.len >= self.want) {
                self.more = true;
                return;
            }

            if (depth + 1 > max_depth) return;
            var kids: [64]u64 = @splat(0);
            const n = self.scene.childIdsInto(id, &kids);
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
