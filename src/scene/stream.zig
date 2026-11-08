//! Scene streaming: residency-managed sectors over a live scene.
//!
//! A **stream manifest** (`.corexstream`) is a strict, versioned JSON document
//! listing named sectors. Each sector points at an ordinary `.scene` document and
//! carries a spherical volume (center + radius) with a separate, larger unload
//! radius. A `Stream` loads and unloads those sectors into a **borrowed** target
//! scene, either explicitly or from a listener position, and tracks exactly which
//! entities it created so an unload removes precisely that set and nothing else.
//!
//! Design points that matter:
//!
//! - **No new scene format.** Sector payloads are ordinary scene documents,
//!   parsed by `Scene.load` and instantiated by `Scene.cloneSubtree`. This module
//!   owns residency only; it does not duplicate serialization or ECS storage.
//! - **Exact, allocation-free ownership.** Stable IDs are monotonic, so the set a
//!   load created is exactly the range `[nextStableId() before, after)`. Capturing
//!   it needs no allocation, and releasing it with `Scene.destroySet` is a single
//!   pass that never rescans the scene per entity.
//! - **Hysteresis.** A sector loads inside `radius` and unloads only beyond
//!   `unload_radius >= radius`, so a listener sitting on the boundary cannot
//!   thrash load/unload every frame.
//! - **Budgeted.** `update` caps loads, unloads and resident entities per call and
//!   reports whether work remains, so a frame cannot spike on a big world.
//! - **Deterministic.** Sectors are canonicalized in name order and each sector's
//!   roots are cloned in ascending source-ID order, so the same manifest and the
//!   same positions always produce the same result.
//! - **Rollback.** A sector that fails partway through loading leaves the target
//!   scene exactly as it was; there is no half-resident sector. Because both the
//!   ownership capture and the rollback are allocation-free, that holds even when
//!   the allocator is the thing that failed.
//!
//! Entities added by the caller *under* a streamed entity are not owned by the
//! sector. When the sector unloads they survive and are reparented to the nearest
//! surviving ancestor, matching `Scene.destroyEntity` semantics.
//!
//! This module depends on `scene.zig` in one direction only. `scene.zig` does not
//! import it; `src/scene.zig` re-exports both.

const std = @import("std");
const scene_mod = @import("scene.zig");
const paths = @import("../core/paths.zig");
const validation = @import("../core/validation.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const format_version: u32 = 1;
/// A manifest is a small index; sector payloads are bounded by the scene limit.
pub const max_manifest_bytes: usize = 1024 * 1024;
/// Upper bound on sector count, so residency bookkeeping stays bounded.
pub const max_sectors: usize = 4096;

pub const Error = scene_mod.Error || error{
    /// The manifest is structurally valid JSON but not a legal stream manifest.
    InvalidManifest,
    /// Two sectors share a name.
    DuplicateSector,
    /// No sector with that name exists in the manifest.
    SectorNotFound,
    /// A radius/center is non-finite, non-positive, or unload < load radius.
    InvalidVolume,
    /// The manifest exceeds `max_manifest_bytes`.
    ManifestTooLarge,
};

/// One streamed region. `unload_radius` is already resolved (never null).
pub const Sector = struct {
    name: []const u8,
    /// Project-relative path to an ordinary `.scene` document.
    scene: []const u8,
    center: [3]f32,
    radius: f32,
    unload_radius: f32,
    /// Pinned sectors are always resident and are never unloaded by `update`.
    pinned: bool,
};

fn lessSector(_: void, a: Sector, b: Sector) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const RawSector = struct {
    name: []const u8,
    scene: []const u8,
    center: [3]f32 = .{ 0, 0, 0 },
    radius: f32,
    unload_radius: ?f32 = null,
    pinned: bool = false,
};

const RawManifest = struct {
    format_version: u32,
    name: []const u8,
    sectors: []const RawSector = &.{},
};

/// A parsed, validated, canonicalized stream manifest. Owns its strings.
pub const Manifest = struct {
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    /// Sorted by name; indices are stable for the manifest's lifetime.
    sectors: []Sector,

    pub fn deinit(self: *Manifest) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }

    /// Parse a strict manifest document. Unknown fields, duplicate JSON keys,
    /// duplicate sector names, unsafe paths and illegal volumes are rejected.
    pub fn parse(gpa: Allocator, bytes: []const u8) Error!Manifest {
        if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
        var tmp_arena = std.heap.ArenaAllocator.init(gpa);
        defer tmp_arena.deinit();

        const parsed = std.json.parseFromSlice(RawManifest, tmp_arena.allocator(), bytes, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = bytes.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();
        const raw = parsed.value;

        if (raw.format_version != format_version) return error.UnsupportedFormatVersion;
        validation.validateDisplayName(raw.name) catch return error.InvalidName;
        if (raw.sectors.len > max_sectors) return error.InvalidManifest;

        var arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const sectors = try a.alloc(Sector, raw.sectors.len);
        for (raw.sectors, 0..) |rs, i| {
            validation.validateDisplayName(rs.name) catch return error.InvalidName;
            paths.validateRelative(rs.scene) catch return error.UnsafePath;
            if (rs.scene.len == 0) return error.InvalidManifest;
            for (rs.center) |c| {
                if (!std.math.isFinite(c)) return error.InvalidVolume;
            }
            if (!std.math.isFinite(rs.radius) or rs.radius <= 0) return error.InvalidVolume;
            const unload = rs.unload_radius orelse rs.radius;
            if (!std.math.isFinite(unload) or unload < rs.radius) return error.InvalidVolume;
            sectors[i] = .{
                .name = try a.dupe(u8, rs.name),
                .scene = try a.dupe(u8, rs.scene),
                .center = rs.center,
                .radius = rs.radius,
                .unload_radius = unload,
                .pinned = rs.pinned,
            };
        }
        std.mem.sort(Sector, sectors, {}, lessSector);
        for (sectors, 0..) |s, i| {
            if (i > 0 and std.mem.eql(u8, sectors[i - 1].name, s.name)) return error.DuplicateSector;
        }

        return .{
            .arena = arena,
            .name = try a.dupe(u8, raw.name),
            .sectors = sectors,
        };
    }

    /// Load a manifest relative to `dir` (usually the project root).
    pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Manifest {
        paths.validateRelative(path) catch return error.UnsafePath;
        const bytes = dir.readFileAlloc(io, path, gpa, .limited(max_manifest_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProjectIo,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    /// Index of a sector by name, or null. Binary search over the sorted list.
    pub fn find(self: Manifest, name: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = self.sectors.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.sectors[mid].name, name)) {
                .lt => lo = mid + 1,
                .eq => return mid,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Serialize deterministically: sectors in name order, defaults omitted.
    pub fn serialize(self: Manifest, gpa: Allocator) Error![]u8 {
        var tmp_arena = std.heap.ArenaAllocator.init(gpa);
        defer tmp_arena.deinit();
        const a = tmp_arena.allocator();
        const raw_sectors = try a.alloc(RawSector, self.sectors.len);
        for (self.sectors, 0..) |s, i| {
            raw_sectors[i] = .{
                .name = s.name,
                .scene = s.scene,
                .center = s.center,
                .radius = s.radius,
                // Only emit an unload radius when it actually adds hysteresis.
                .unload_radius = if (s.unload_radius == s.radius) null else s.unload_radius,
                .pinned = s.pinned,
            };
        }
        const doc = RawManifest{
            .format_version = format_version,
            .name = self.name,
            .sectors = raw_sectors,
        };
        return std.json.Stringify.valueAlloc(gpa, doc, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        }) catch return error.OutOfMemory;
    }

    /// Save to a project-relative path, creating parent directories.
    pub fn save(self: Manifest, io: Io, dir: Io.Dir, path: []const u8) Error!void {
        paths.validateRelative(path) catch return error.UnsafePath;
        const gpa = self.arena.child_allocator;
        const bytes = try self.serialize(gpa);
        defer gpa.free(bytes);
        if (std.fs.path.dirname(path)) |parent_dir| {
            if (parent_dir.len > 0) {
                dir.createDirPath(io, parent_dir) catch return error.ProjectIo;
            }
        }
        dir.writeFile(io, .{ .sub_path = path, .data = bytes }) catch return error.ProjectIo;
    }
};

/// Squared distance, accumulated in f64 so large world coordinates keep precision.
fn distanceSquared(a: [3]f32, b: [3]f32) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| {
        const d = @as(f64, x) - @as(f64, y);
        sum += d * d;
    }
    return sum;
}

/// Residency manager for the sectors of a manifest, over a borrowed scene.
///
/// The stream **owns the manifest** (freed by `deinit`) and **borrows the target
/// scene**, which must outlive it. `deinit` unloads everything the stream loaded,
/// leaving entities the caller created untouched.
pub fn Stream(comptime schemas: anytype) type {
    const SceneT = scene_mod.Scene(schemas);

    return struct {
        const Self = @This();
        pub const Scene = SceneT;

        /// Per-`update` budgets. The entity cap is a ceiling on entities owned by
        /// the stream, not on the target scene's total size.
        pub const Options = struct {
            max_loads: usize = 4,
            max_unloads: usize = 4,
            max_resident_entities: usize = scene_mod.max_entities,
        };

        pub const Report = struct {
            loaded: usize = 0,
            unloaded: usize = 0,
            resident_sectors: usize = 0,
            resident_entities: usize = 0,
            /// True when a candidate was left unprocessed because a budget ran
            /// out, so the caller knows to call `update` again.
            pending: bool = false,
        };

        const Residency = struct {
            /// Every stable ID this sector created, sorted.
            ids: std.ArrayList(u64) = .empty,
            /// The cloned root IDs, in ascending order, for callers that want a
            /// handle to the sector's top-level entities.
            roots: std.ArrayList(u64) = .empty,

            fn deinit(self: *Residency, gpa: Allocator) void {
                self.ids.deinit(gpa);
                self.roots.deinit(gpa);
            }
        };

        const LoadOutcome = union(enum) {
            loaded: usize,
            already_resident,
            /// The sector would exceed the resident-entity ceiling.
            too_large,
        };

        gpa: Allocator,
        target: *SceneT,
        manifest: Manifest,
        /// Keyed by sector name; the key bytes belong to the manifest arena.
        resident: std.StringHashMap(Residency),
        /// Reverse index: streamed entity ID -> manifest sector index.
        owner: std.AutoHashMap(u64, usize),
        entity_total: usize,

        pub fn init(gpa: Allocator, target: *SceneT, manifest: Manifest) Self {
            return .{
                .gpa = gpa,
                .target = target,
                .manifest = manifest,
                .resident = std.StringHashMap(Residency).init(gpa),
                .owner = std.AutoHashMap(u64, usize).init(gpa),
                .entity_total = 0,
            };
        }

        /// Unload every resident sector, then release the manifest. The target
        /// scene keeps any entities the caller created itself.
        pub fn deinit(self: *Self) void {
            var it = self.resident.valueIterator();
            while (it.next()) |res| {
                _ = self.target.destroySet(res.ids.items);
                res.deinit(self.gpa);
            }
            self.resident.deinit();
            self.owner.deinit();
            self.entity_total = 0;
            self.manifest.deinit();
            self.* = undefined;
        }

        pub fn isResident(self: *const Self, name: []const u8) bool {
            return self.resident.contains(name);
        }

        pub fn residentSectorCount(self: *const Self) usize {
            return self.resident.count();
        }

        /// How many entities the resident sectors own (not the scene total).
        ///
        /// This is tracked ownership: if the caller destroys a streamed entity
        /// itself, it stays counted until that sector unloads. It always equals
        /// the sum of `sectorEntities(name).len` over resident sectors.
        pub fn residentEntityCount(self: *const Self) usize {
            return self.entity_total;
        }

        /// Sorted stable IDs owned by a resident sector, or null. Borrowed;
        /// valid until that sector is unloaded.
        pub fn sectorEntities(self: *const Self, name: []const u8) ?[]const u64 {
            const res = self.resident.getPtr(name) orelse return null;
            return res.ids.items;
        }

        /// Cloned root IDs of a resident sector, or null. Borrowed.
        pub fn sectorRoots(self: *const Self, name: []const u8) ?[]const u64 {
            const res = self.resident.getPtr(name) orelse return null;
            return res.roots.items;
        }

        /// Name of the sector that owns a streamed entity, or null when the
        /// entity was not created by this stream. O(1).
        pub fn sectorOfEntity(self: *const Self, id: u64) ?[]const u8 {
            const index = self.owner.get(id) orelse return null;
            return self.manifest.sectors[index].name;
        }

        /// Load a sector explicitly, ignoring volumes and budgets. Idempotent.
        pub fn loadSector(self: *Self, io: Io, dir: Io.Dir, name: []const u8) Error!void {
            const index = self.manifest.find(name) orelse return error.SectorNotFound;
            _ = try self.loadInner(io, dir, index, std.math.maxInt(usize));
        }

        /// Unload a sector explicitly, even if pinned. Idempotent. Returns how
        /// many entities were actually removed (fewer if the caller destroyed
        /// some of them already).
        pub fn unloadSector(self: *Self, name: []const u8) Error!usize {
            const index = self.manifest.find(name) orelse return error.SectorNotFound;
            return self.unloadInner(index);
        }

        fn unloadInner(self: *Self, index: usize) usize {
            const sector = self.manifest.sectors[index];
            const entry = self.resident.fetchRemove(sector.name) orelse return 0;
            var res = entry.value;
            defer res.deinit(self.gpa);
            for (res.ids.items) |id| _ = self.owner.remove(id);
            const removed = self.target.destroySet(res.ids.items);
            // Subtract the whole tracked set, not just what was still alive: the
            // caller may have destroyed some of them already. This keeps the
            // invariant `entity_total == sum of resident sectors' ids.len`.
            self.entity_total -= res.ids.items.len;
            return removed;
        }

        fn loadInner(self: *Self, io: Io, dir: Io.Dir, index: usize, cap: usize) Error!LoadOutcome {
            const sector = self.manifest.sectors[index];
            if (self.resident.contains(sector.name)) return .already_resident;

            var source = try SceneT.load(self.gpa, io, dir, sector.scene);
            defer source.deinit();

            // Check the ceiling before touching the target, so a rejected sector
            // costs a parse but never a partial mutation.
            const incoming = source.count();
            if (incoming > cap or self.entity_total > cap - incoming) return .too_large;

            const source_roots = try source.rootIds(self.gpa);
            defer self.gpa.free(source_roots);

            var res: Residency = .{};
            errdefer res.deinit(self.gpa);
            try res.roots.ensureTotalCapacity(self.gpa, source_roots.len);
            // Every source entity belongs to exactly one root's subtree, so the
            // clone creates exactly `incoming` entities. Reserving now means the
            // ownership capture below cannot fail once the target is mutated.
            try res.ids.ensureTotalCapacity(self.gpa, incoming);

            // IDs are monotonic, so everything this load creates lands in
            // [id_floor, next). Capturing that range needs no allocation, which
            // is what makes the rollback below work under a failing allocator.
            const id_floor = self.target.nextStableId();
            errdefer self.rollbackFrom(id_floor);

            for (source_roots) |root_id| {
                const inst = try self.target.cloneSubtree(&source, root_id, null);
                res.roots.appendAssumeCapacity(inst.root_id);
            }

            var id = id_floor;
            while (id < self.target.nextStableId()) : (id += 1) {
                if (self.target.entityById(id) != null) res.ids.appendAssumeCapacity(id);
            }

            // Publish bookkeeping only after everything above succeeded.
            try self.resident.put(sector.name, res);
            errdefer {
                _ = self.resident.remove(sector.name);
                self.rollbackFrom(id_floor);
            }
            try self.owner.ensureUnusedCapacity(@intCast(res.ids.items.len));
            for (res.ids.items) |created| self.owner.putAssumeCapacity(created, index);
            self.entity_total += res.ids.items.len;
            return .{ .loaded = res.ids.items.len };
        }

        /// Remove every entity created since `id_floor`, without allocating.
        ///
        /// `destroyEntity` reparents survivors rather than removing subtrees, but
        /// when the whole created set is destroyed the order does not matter: no
        /// member of the set survives to be reparented. This is the failure path
        /// only, so the per-entity scan is acceptable in exchange for being
        /// unable to fail.
        fn rollbackFrom(self: *Self, id_floor: u64) void {
            var id = id_floor;
            while (id < self.target.nextStableId()) : (id += 1) {
                if (self.target.entityById(id)) |entity| self.target.destroyEntity(entity);
            }
        }

        /// Bring residency in line with a listener position, within budget.
        ///
        /// Unloads run first so they free room for loads in the same call.
        /// Pinned sectors are loaded regardless of distance and never unloaded.
        pub fn update(
            self: *Self,
            io: Io,
            dir: Io.Dir,
            position: [3]f32,
            options: Options,
        ) Error!Report {
            var report: Report = .{};

            for (self.manifest.sectors, 0..) |sector, index| {
                if (sector.pinned) continue;
                if (!self.resident.contains(sector.name)) continue;
                const limit = @as(f64, sector.unload_radius);
                if (distanceSquared(position, sector.center) <= limit * limit) continue;
                if (report.unloaded >= options.max_unloads) {
                    report.pending = true;
                    continue;
                }
                _ = self.unloadInner(index);
                report.unloaded += 1;
            }

            for (self.manifest.sectors, 0..) |sector, index| {
                if (self.resident.contains(sector.name)) continue;
                if (!sector.pinned) {
                    const reach = @as(f64, sector.radius);
                    if (distanceSquared(position, sector.center) > reach * reach) continue;
                }
                if (report.loaded >= options.max_loads) {
                    report.pending = true;
                    continue;
                }
                switch (try self.loadInner(io, dir, index, options.max_resident_entities)) {
                    .loaded => report.loaded += 1,
                    .already_resident => {},
                    .too_large => report.pending = true,
                }
            }

            report.resident_sectors = self.resident.count();
            report.resident_entities = self.entity_total;
            return report;
        }
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Transform = @import("components.zig").Transform;
/// The allocation-failure probes below run through `alloc_probe.check`, which counts
/// allocations the way the code path decides them rather than the way the heap
/// happens to be laid out; see `core/alloc_probe.zig`.
const alloc_probe = @import("../core/alloc_probe.zig");

const TestScene = scene_mod.Scene(.{scene_mod.Component(Transform, "transform")});
const TestStream = Stream(.{scene_mod.Component(Transform, "transform")});

const two_sectors =
    \\{ "format_version": 1, "name": "world", "sectors": [
    \\  { "name": "town", "scene": "scenes/town.scene", "center": [0, 0, 0], "radius": 10, "unload_radius": 14 },
    \\  { "name": "cave", "scene": "scenes/cave.scene", "center": [100, 0, 0], "radius": 10 }
    \\] }
;

/// A directory holding two sector documents plus a manifest, for stream tests.
const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn init() !Fixture {
        var self = Fixture{ .tmp = testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        const io = testing.io;
        try self.tmp.dir.createDirPath(io, "scenes");
        // "town" has a hierarchy and two roots: 4 entities total.
        try self.tmp.dir.writeFile(io, .{ .sub_path = "scenes/town.scene", .data =
            \\{ "format_version": 1, "name": "town", "entities": [
            \\  { "id": 1, "name": "TownRoot", "components": { "transform": { "position": [1, 2, 3] } } },
            \\  { "id": 2, "name": "Child", "parent": 1 },
            \\  { "id": 3, "name": "GrandChild", "parent": 2 },
            \\  { "id": 4, "name": "OtherRoot" }
            \\] }
        });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "scenes/cave.scene", .data =
            \\{ "format_version": 1, "name": "cave", "entities": [
            \\  { "id": 1, "name": "CaveRoot" }
            \\] }
        });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "world.corexstream", .data = two_sectors });
        return self;
    }

    fn cleanup(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn manifest(self: *Fixture, gpa: Allocator) !Manifest {
        return Manifest.load(gpa, testing.io, self.tmp.dir, "world.corexstream");
    }
};

test "stream: manifest parses, canonicalizes by name and resolves defaults" {
    const gpa = testing.allocator;
    var m = try Manifest.parse(gpa, two_sectors);
    defer m.deinit();
    try testing.expectEqualStrings("world", m.name);
    try testing.expectEqual(@as(usize, 2), m.sectors.len);
    // Sorted by name: cave before town, regardless of document order.
    try testing.expectEqualStrings("cave", m.sectors[0].name);
    try testing.expectEqualStrings("town", m.sectors[1].name);
    // An omitted unload_radius resolves to the load radius (no hysteresis).
    try testing.expectEqual(@as(f32, 10), m.sectors[0].unload_radius);
    try testing.expectEqual(@as(f32, 14), m.sectors[1].unload_radius);
    try testing.expectEqual(false, m.sectors[0].pinned);
    try testing.expectEqual(@as(?usize, 0), m.find("cave"));
    try testing.expectEqual(@as(?usize, 1), m.find("town"));
    try testing.expectEqual(@as(?usize, null), m.find("missing"));
}

test "stream: manifest serialize is deterministic and roundtrips" {
    const gpa = testing.allocator;
    var m = try Manifest.parse(gpa, two_sectors);
    defer m.deinit();
    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);
    const again = try m.serialize(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);

    var reparsed = try Manifest.parse(gpa, bytes);
    defer reparsed.deinit();
    const round = try reparsed.serialize(gpa);
    defer gpa.free(round);
    try testing.expectEqualSlices(u8, bytes, round);
    // The resolved-but-equal unload radius is omitted, hysteresis is kept.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"unload_radius\": 14") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "unload_radius"));
}

test "stream: manifest rejects malformed and unsafe documents" {
    const gpa = testing.allocator;
    const bad = [_]struct { name: []const u8, json: []const u8, err: Error }{
        .{ .name = "bad json", .json = "{", .err = error.InvalidJson },
        .{ .name = "version", .json =
        \\{ "format_version": 2, "name": "w", "sectors": [] }
        , .err = error.UnsupportedFormatVersion },
        .{ .name = "unknown field", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [], "extra": 1 }
        , .err = error.InvalidJson },
        .{ .name = "duplicate key", .json =
        \\{ "format_version": 1, "name": "w", "name": "x", "sectors": [] }
        , .err = error.InvalidJson },
        .{ .name = "bad name", .json =
        \\{ "format_version": 1, "name": "", "sectors": [] }
        , .err = error.InvalidName },
        .{ .name = "bad sector name", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "", "scene": "a.scene", "radius": 1 } ] }
        , .err = error.InvalidName },
        .{ .name = "duplicate sector", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "a.scene", "radius": 1 },
        \\  { "name": "a", "scene": "b.scene", "radius": 2 } ] }
        , .err = error.DuplicateSector },
        .{ .name = "unsafe path", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "../escape.scene", "radius": 1 } ] }
        , .err = error.UnsafePath },
        .{ .name = "absolute path", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "/etc/passwd", "radius": 1 } ] }
        , .err = error.UnsafePath },
        .{ .name = "zero radius", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "a.scene", "radius": 0 } ] }
        , .err = error.InvalidVolume },
        .{ .name = "negative radius", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "a.scene", "radius": -5 } ] }
        , .err = error.InvalidVolume },
        .{ .name = "unload below load", .json =
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "a", "scene": "a.scene", "radius": 10, "unload_radius": 9 } ] }
        , .err = error.InvalidVolume },
    };
    for (bad) |case| {
        if (Manifest.parse(gpa, case.json)) |*ok| {
            var m = ok.*;
            m.deinit();
            std.debug.print("\nmanifest case '{s}' was accepted\n", .{case.name});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != case.err) {
                std.debug.print("\nmanifest case '{s}': got {s}, want {s}\n", .{
                    case.name, @errorName(err), @errorName(case.err),
                });
                return err;
            }
        }
    }
}

test "stream: manifest accepts an empty sector list and enforces its size limit" {
    const gpa = testing.allocator;
    var m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "empty", "sectors": [] }
    );
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.sectors.len);
    try testing.expectEqual(@as(?usize, null), m.find("any"));

    const huge = try gpa.alloc(u8, max_manifest_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, ' ');
    try testing.expectError(error.ManifestTooLarge, Manifest.parse(gpa, huge));
}

test "stream: manifest load/save file roundtrip and unsafe path rejection" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var m = try fx.manifest(gpa);
    defer m.deinit();
    try m.save(testing.io, fx.tmp.dir, "out/world.corexstream");
    var loaded = try Manifest.load(gpa, testing.io, fx.tmp.dir, "out/world.corexstream");
    defer loaded.deinit();
    const a = try m.serialize(gpa);
    defer gpa.free(a);
    const b = try loaded.serialize(gpa);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expectError(error.UnsafePath, Manifest.load(gpa, testing.io, fx.tmp.dir, "../x"));
    try testing.expectError(error.ProjectIo, Manifest.load(gpa, testing.io, fx.tmp.dir, "missing"));
}

test "stream: explicit load captures the whole sector and unload removes exactly it" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    // An entity the caller owns, which must survive every unload.
    const player = try target.createEntity("Player", null);
    const player_id = target.idOf(player).?;

    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();

    try s.loadSector(testing.io, fx.tmp.dir, "town");
    try testing.expect(s.isResident("town"));
    try testing.expectEqual(@as(usize, 4), s.residentEntityCount());
    try testing.expectEqual(@as(usize, 5), target.count());
    try testing.expectEqual(@as(usize, 2), s.sectorRoots("town").?.len);
    // Descendants are owned too, not just the roots.
    try testing.expectEqual(@as(usize, 4), s.sectorEntities("town").?.len);
    for (s.sectorEntities("town").?) |id| {
        try testing.expectEqualStrings("town", s.sectorOfEntity(id).?);
    }
    try testing.expectEqual(@as(?[]const u8, null), s.sectorOfEntity(player_id));

    // Loading twice is a no-op, not a duplicate.
    try s.loadSector(testing.io, fx.tmp.dir, "town");
    try testing.expectEqual(@as(usize, 4), s.residentEntityCount());

    try testing.expectEqual(@as(usize, 4), try s.unloadSector("town"));
    try testing.expect(!s.isResident("town"));
    try testing.expectEqual(@as(usize, 0), s.residentEntityCount());
    try testing.expectEqual(@as(usize, 1), target.count());
    try testing.expect(target.alive(player));
    try testing.expectEqual(@as(?[]const u8, null), s.sectorOfEntity(player_id));
    // Unloading again is a no-op.
    try testing.expectEqual(@as(usize, 0), try s.unloadSector("town"));
    try testing.expectError(error.SectorNotFound, s.unloadSector("nope"));
    try testing.expectError(error.SectorNotFound, s.loadSector(testing.io, fx.tmp.dir, "nope"));
}

test "stream: caller entities parented under a sector survive its unload" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();

    try s.loadSector(testing.io, fx.tmp.dir, "town");
    const root_id = s.sectorRoots("town").?[0];
    // The caller attaches its own entity under a streamed one.
    const mine = try target.createEntity("Mine", root_id);
    const mine_id = target.idOf(mine).?;
    try testing.expectEqual(@as(?[]const u8, null), s.sectorOfEntity(mine_id));

    try testing.expectEqual(@as(usize, 4), try s.unloadSector("town"));
    try testing.expect(target.alive(mine));
    try testing.expectEqual(@as(usize, 1), target.count());
    // Its streamed ancestors are gone, so it becomes a root.
    try testing.expectEqual(@as(?u64, null), target.records.get(mine_id).?.parent);
}

test "stream: unload tolerates entities the caller already destroyed" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();
    try s.loadSector(testing.io, fx.tmp.dir, "town");
    const doomed = s.sectorEntities("town").?[0];
    target.destroyEntity(target.entityById(doomed).?);
    // Only three remain, and the accounting must not underflow.
    try testing.expectEqual(@as(usize, 3), try s.unloadSector("town"));
    try testing.expectEqual(@as(usize, 0), s.residentEntityCount());
    try testing.expectEqual(@as(usize, 0), target.count());
}

test "stream: update loads in range, unloads out of range, and honours hysteresis" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();
    const io = testing.io;

    // At the town centre: town loads (radius 10), cave does not (100 away).
    var r = try s.update(io, fx.tmp.dir, .{ 0, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(s.isResident("town"));
    try testing.expect(!s.isResident("cave"));
    try testing.expect(!r.pending);

    // Inside the hysteresis band (10 < d <= 14): stays resident, no churn.
    r = try s.update(io, fx.tmp.dir, .{ 12, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 0), r.loaded);
    try testing.expectEqual(@as(usize, 0), r.unloaded);
    try testing.expect(s.isResident("town"));

    // Beyond the unload radius: town unloads.
    r = try s.update(io, fx.tmp.dir, .{ 20, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 1), r.unloaded);
    try testing.expect(!s.isResident("town"));

    // Stepping back into the band from outside must NOT reload (d > radius).
    r = try s.update(io, fx.tmp.dir, .{ 12, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 0), r.loaded);
    try testing.expect(!s.isResident("town"));

    // At the cave: cave loads.
    r = try s.update(io, fx.tmp.dir, .{ 100, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(s.isResident("cave"));
    try testing.expectEqual(@as(usize, 1), r.resident_entities);
}

test "stream: update budgets cap work per call and report pending" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    // Both sectors at the origin so both are candidates at once.
    const m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "town", "scene": "scenes/town.scene", "radius": 10 },
        \\  { "name": "cave", "scene": "scenes/cave.scene", "radius": 10 } ] }
    );
    var s = TestStream.init(gpa, &target, m);
    defer s.deinit();
    const io = testing.io;

    var r = try s.update(io, fx.tmp.dir, .{ 0, 0, 0 }, .{ .max_loads = 1 });
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(r.pending);
    try testing.expectEqual(@as(usize, 1), r.resident_sectors);
    // A second call finishes the work and clears pending.
    r = try s.update(io, fx.tmp.dir, .{ 0, 0, 0 }, .{ .max_loads = 1 });
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(!r.pending);
    try testing.expectEqual(@as(usize, 2), r.resident_sectors);

    // Now both must unload, one per call.
    r = try s.update(io, fx.tmp.dir, .{ 1000, 0, 0 }, .{ .max_unloads = 1 });
    try testing.expectEqual(@as(usize, 1), r.unloaded);
    try testing.expect(r.pending);
    r = try s.update(io, fx.tmp.dir, .{ 1000, 0, 0 }, .{ .max_unloads = 1 });
    try testing.expectEqual(@as(usize, 1), r.unloaded);
    try testing.expect(!r.pending);
    try testing.expectEqual(@as(usize, 0), r.resident_sectors);
}

test "stream: the resident-entity ceiling rejects a sector without mutating the scene" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    const m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "cave", "scene": "scenes/cave.scene", "radius": 10 },
        \\  { "name": "town", "scene": "scenes/town.scene", "radius": 10 } ] }
    );
    var s = TestStream.init(gpa, &target, m);
    defer s.deinit();
    const before = try target.serialize(gpa);
    defer gpa.free(before);

    // cave (1 entity) fits; town (4) would exceed the ceiling of 3.
    const r = try s.update(testing.io, fx.tmp.dir, .{ 0, 0, 0 }, .{ .max_resident_entities = 3 });
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(r.pending);
    try testing.expect(s.isResident("cave"));
    try testing.expect(!s.isResident("town"));
    try testing.expectEqual(@as(usize, 1), s.residentEntityCount());

    // A ceiling below every sector leaves the scene byte-identical.
    _ = try s.unloadSector("cave");
    const r2 = try s.update(testing.io, fx.tmp.dir, .{ 0, 0, 0 }, .{ .max_resident_entities = 0 });
    try testing.expectEqual(@as(usize, 0), r2.loaded);
    try testing.expect(r2.pending);
    const after = try target.serialize(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "stream: pinned sectors are always resident and only an explicit call unloads them" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    const m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "cave", "scene": "scenes/cave.scene", "center": [1000, 0, 0], "radius": 1, "pinned": true } ] }
    );
    var s = TestStream.init(gpa, &target, m);
    defer s.deinit();
    // Far outside the radius, yet pinned means resident.
    var r = try s.update(testing.io, fx.tmp.dir, .{ 0, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(s.isResident("cave"));
    r = try s.update(testing.io, fx.tmp.dir, .{ -5000, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 0), r.unloaded);
    try testing.expect(s.isResident("cave"));
    // Explicit unload overrides the pin.
    try testing.expectEqual(@as(usize, 1), try s.unloadSector("cave"));
    try testing.expect(!s.isResident("cave"));
}

test "stream: deinit unloads everything it created and keeps caller entities" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    const player = try target.createEntity("Player", null);
    const before = try target.serialize(gpa);
    defer gpa.free(before);
    {
        var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
        defer s.deinit();
        try s.loadSector(testing.io, fx.tmp.dir, "town");
        try s.loadSector(testing.io, fx.tmp.dir, "cave");
        try testing.expectEqual(@as(usize, 5), s.residentEntityCount());
    }
    try testing.expect(target.alive(player));
    const after = try target.serialize(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "stream: a missing sector file leaves the scene untouched and the sector non-resident" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    const m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "ghost", "scene": "scenes/missing.scene", "radius": 10 } ] }
    );
    var s = TestStream.init(gpa, &target, m);
    defer s.deinit();
    const before = try target.serialize(gpa);
    defer gpa.free(before);
    try testing.expectError(error.ProjectIo, s.loadSector(testing.io, fx.tmp.dir, "ghost"));
    try testing.expect(!s.isResident("ghost"));
    try testing.expectEqual(@as(usize, 0), s.residentEntityCount());
    const after = try target.serialize(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

/// Structural signature of a scene: entities in ascending stable-ID order, with
/// parents expressed as a rank rather than an ID. Monotonic IDs advance on every
/// reload, so comparing raw bytes would be wrong; the shape must not change.
fn shapeSignature(gpa: Allocator, s: *TestScene, ids: []const u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (ids, 0..) |id, rank| {
        const e = s.entityById(id) orelse return error.EntityNotFound;
        const name = s.nameOf(e) orelse "-";
        var parent_rank: i64 = -1;
        if (s.parent(e)) |pe| {
            const pid = s.idOf(pe).?;
            parent_rank = @intCast(std.mem.indexOfScalar(u64, ids, pid) orelse return error.EntityNotFound);
        }
        const t = s.getComponent(Transform, e);
        try out.print(gpa, "{d}:{s}:p{d}:", .{ rank, name, parent_rank });
        if (t) |tv| {
            try out.print(gpa, "{d},{d},{d}|", .{ tv.position[0], tv.position[1], tv.position[2] });
        } else {
            try out.appendSlice(gpa, "none|");
        }
    }
    return out.toOwnedSlice(gpa);
}

test "stream: repeated load/unload cycles are deterministic and leak nothing" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();

    var reference: ?[]u8 = null;
    defer if (reference) |r| gpa.free(r);
    var previous_floor: u64 = 0;
    for (0..6) |_| {
        // IDs advance monotonically across cycles and are never reused.
        try testing.expect(target.nextStableId() >= previous_floor);
        previous_floor = target.nextStableId();

        try s.loadSector(testing.io, fx.tmp.dir, "town");
        const ids = s.sectorEntities("town").?;
        try testing.expectEqual(@as(usize, 4), ids.len);
        const sig = try shapeSignature(gpa, &target, ids);
        if (reference) |r| {
            try testing.expectEqualSlices(u8, r, sig);
            gpa.free(sig);
        } else {
            reference = sig;
        }
        try testing.expectEqual(@as(usize, 4), try s.unloadSector("town"));
        try testing.expectEqual(@as(usize, 0), target.count());
        try testing.expectEqual(@as(usize, 0), s.residentEntityCount());
    }
}

test "stream: resident entity count always equals the sum of tracked sector sets" {
    const gpa = testing.allocator;
    var fx = try Fixture.init();
    defer fx.cleanup();
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    var s = TestStream.init(gpa, &target, try fx.manifest(gpa));
    defer s.deinit();
    try s.loadSector(testing.io, fx.tmp.dir, "town");
    try s.loadSector(testing.io, fx.tmp.dir, "cave");

    const check = struct {
        fn run(stream: *TestStream) !void {
            var total: usize = 0;
            var it = stream.resident.valueIterator();
            while (it.next()) |res| total += res.ids.items.len;
            try testing.expectEqual(total, stream.residentEntityCount());
            // The reverse index covers exactly the same set.
            try testing.expectEqual(total, stream.owner.count());
        }
    }.run;
    try check(&s);
    // Even after the caller destroys a streamed entity behind the stream's back.
    target.destroyEntity(target.entityById(s.sectorEntities("town").?[0]).?);
    try check(&s);
    _ = try s.unloadSector("town");
    try check(&s);
    _ = try s.unloadSector("cave");
    try check(&s);
    try testing.expectEqual(@as(usize, 0), s.residentEntityCount());
}

test "stream: an empty manifest updates to an empty report" {
    const gpa = testing.allocator;
    var target = try TestScene.init(gpa, "live");
    defer target.deinit();
    const m = try Manifest.parse(gpa,
        \\{ "format_version": 1, "name": "empty", "sectors": [] }
    );
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = TestStream.init(gpa, &target, m);
    defer s.deinit();
    const r = try s.update(testing.io, tmp.dir, .{ 0, 0, 0 }, .{});
    try testing.expectEqual(@as(usize, 0), r.loaded);
    try testing.expectEqual(@as(usize, 0), r.unloaded);
    try testing.expectEqual(@as(usize, 0), r.resident_sectors);
    try testing.expect(!r.pending);
}

fn manifestParseAllocationProbe(allocator: Allocator) !void {
    var m = try Manifest.parse(allocator, two_sectors);
    defer m.deinit();
    const bytes = try m.serialize(allocator);
    allocator.free(bytes);
}

test "stream: manifest parse and serialize survive every allocation failure" {
    try alloc_probe.check(manifestParseAllocationProbe, .{});
}

fn streamLoadAllocationProbe(allocator: Allocator, dir: Io.Dir) !void {
    var target = try TestScene.init(allocator, "live");
    defer target.deinit();
    const player = try target.createEntity("Player", null);
    const m = try Manifest.parse(allocator, two_sectors);
    var s = TestStream.init(allocator, &target, m);
    defer s.deinit();

    const before = target.count();
    s.loadSector(testing.io, dir, "town") catch |err| {
        // The all-or-nothing guarantee has to hold even when the allocator is
        // the thing that failed: no half-resident sector, no orphan entities.
        if (target.count() != before) return error.RollbackLeftEntities;
        if (s.residentEntityCount() != 0) return error.RollbackLeftAccounting;
        if (s.isResident("town")) return error.RollbackLeftResidency;
        if (s.sectorOfEntity(target.nextStableId()) != null) return error.RollbackLeftOwner;
        return err;
    };
    try testing.expectEqual(before + 4, target.count());
    try testing.expect(target.alive(player));
    try testing.expectEqual(@as(usize, 4), s.residentEntityCount());
}

test "stream: a failing allocator never leaves a half-loaded sector" {
    var fx = try Fixture.init();
    defer fx.cleanup();
    try alloc_probe.check(streamLoadAllocationProbe, .{fx.tmp.dir});
}

fn streamUpdateAllocationProbe(allocator: Allocator, dir: Io.Dir) !void {
    var target = try TestScene.init(allocator, "live");
    defer target.deinit();
    const m = try Manifest.parse(allocator,
        \\{ "format_version": 1, "name": "w", "sectors": [
        \\  { "name": "cave", "scene": "scenes/cave.scene", "radius": 10 },
        \\  { "name": "town", "scene": "scenes/town.scene", "radius": 10 } ] }
    );
    var s = TestStream.init(allocator, &target, m);
    defer s.deinit();
    _ = s.update(testing.io, dir, .{ 0, 0, 0 }, .{}) catch |err| return err;
    // Whatever survived, the accounting invariant must still hold.
    var total: usize = 0;
    var it = s.resident.valueIterator();
    while (it.next()) |res| total += res.ids.items.len;
    if (total != s.residentEntityCount()) return error.AccountingDrift;
    if (total != s.owner.count()) return error.OwnerIndexDrift;
}

test "stream: update keeps its invariants under every allocation failure" {
    var fx = try Fixture.init();
    defer fx.cleanup();
    try alloc_probe.check(streamUpdateAllocationProbe, .{fx.tmp.dir});
}

fn streamUnloadAllocationProbe(allocator: Allocator, dir: Io.Dir) !void {
    var target = try TestScene.init(allocator, "live");
    defer target.deinit();
    const m = try Manifest.parse(allocator, two_sectors);
    var s = TestStream.init(allocator, &target, m);
    defer s.deinit();
    try s.loadSector(testing.io, dir, "town");
    _ = try s.unloadSector("town");
}

test "stream: unload survives every allocation failure without leaking" {
    var fx = try Fixture.init();
    defer fx.cleanup();
    try alloc_probe.check(streamUnloadAllocationProbe, .{fx.tmp.dir});
}
