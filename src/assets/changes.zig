//! Asset change detection — the foundation of hot-reload.
//!
//! A content-addressed cache already avoids re-importing unchanged bytes, but a
//! live editor/runtime also needs to know **which** assets appeared, changed or
//! disappeared so it can reload only what is affected. This module answers that
//! question with a two-tier check:
//!
//! 1. **Cheap tier**: `size` + `mtime` from a single `stat` per file. Files whose
//!    fingerprint is unchanged keep their previously computed hash, so a poll
//!    over an untouched project performs no file reads at all.
//! 2. **Confirmation tier**: only candidates (new files, or files whose
//!    fingerprint moved) are read and hashed with BLAKE3. A file that was merely
//!    touched or re-saved with identical bytes is therefore **not** reported as
//!    modified, which is what keeps hot-reload from reloading untouched textures.
//!
//! `Options.verify_all` disables the cheap tier and hashes every file, for
//! callers that cannot trust timestamps. The cheap tier's blind spot is
//! documented and tested: an edit that preserves both size and mtime is only
//! caught with `verify_all`.
//!
//! Snapshots own their paths and are sorted, so detection is a linear merge join
//! (O(n) after the sort) and results are deterministic. `Snapshot.cacheKeys`
//! derives the **complete** live key set from the stored hashes without importing
//! anything — that is the set to hand to `Cache.gc` after an incremental import,
//! because a filtered `pipeline.Report` only knows about the assets it imported.
//!
//! This module depends on the asset index, the cache (hash/key derivation) and
//! the importer registry. It does not depend on the job system, the scene system
//! or the renderer.

const std = @import("std");
const assets = @import("../core/assets.zig");
const cache_mod = @import("cache.zig");
const importer_mod = @import("importer.zig");
const pipeline = @import("pipeline.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AssetIndex = assets.AssetIndex;
pub const Registry = importer_mod.Registry;
/// Content hash of a source file (BLAKE3-256, same function the cache uses).
pub const Hash = cache_mod.Key;

pub const Error = error{
    OutOfMemory,
    /// A source file could not be stat'ed or read. A file that vanished between
    /// indexing and detection is not an error: it is reported as removed.
    ProjectIo,
};

pub const Options = struct {
    /// Hash every file instead of trusting the size/mtime fingerprint. Use when
    /// timestamps cannot be trusted (restored backups, coarse clocks, editors
    /// that preserve mtime).
    verify_all: bool = false,
    /// Maximum source file size read for hashing. Matches the pipeline's bound
    /// so both layers agree on what is importable.
    max_source_bytes: usize = pipeline.max_source_bytes_default,
};

/// One indexed file with the state needed to detect a change.
pub const Entry = struct {
    /// Project-relative path, owned by the snapshot.
    path: []const u8,
    size: u64,
    /// Modification time in nanoseconds since the epoch.
    mtime: i96,
    hash: Hash,

    /// The cheap fingerprint: identical size and mtime means "assume unchanged".
    fn sameFingerprint(self: Entry, size: u64, mtime: i96) bool {
        return self.size == size and self.mtime == mtime;
    }
};

/// An owned, path-sorted baseline of a project's asset state. Call `deinit`
/// exactly once. Like other owning structs it is move-only.
pub const Snapshot = struct {
    gpa: Allocator,
    entries: []Entry,
    _arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Snapshot) void {
        self.gpa.free(self.entries);
        const child = self._arena.child_allocator;
        self._arena.deinit();
        child.destroy(self._arena);
        self.* = undefined;
    }

    pub fn count(self: Snapshot) usize {
        return self.entries.len;
    }

    pub fn totalBytes(self: Snapshot) u64 {
        var total: u64 = 0;
        for (self.entries) |e| total += e.size;
        return total;
    }

    /// Binary search by project-relative path (entries are sorted).
    pub fn find(self: Snapshot, path: []const u8) ?Entry {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].path, path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.entries[mid],
            }
        }
        return null;
    }

    /// Derive the cache key of every asset in the snapshot, exactly as the
    /// pipeline would, without reading or importing anything. This is the
    /// **complete** live set for `Cache.gc`; a `pipeline.Report` produced with
    /// `Options.only` covers just the assets it imported and must not be used as
    /// the live set on its own. The caller frees the result with `gpa`.
    pub fn cacheKeys(
        self: Snapshot,
        gpa: Allocator,
        registry: Registry,
        options_salt: []const u8,
    ) Allocator.Error![]Hash {
        const keys = try gpa.alloc(Hash, self.entries.len);
        errdefer gpa.free(keys);
        const options_hash = cache_mod.hashBytes(options_salt);
        for (self.entries, keys) |e, *key| {
            const imp = registry.select(std.fs.path.extension(e.path));
            key.* = cache_mod.deriveKey(e.hash, imp.id, imp.version, options_hash);
        }
        return keys;
    }
};

pub const ChangeKind = enum { added, modified, removed };

/// The difference between two snapshots. Paths are **owned by the change set**,
/// so it stays valid after either snapshot is released. Each list is sorted by
/// path, making results deterministic.
pub const ChangeSet = struct {
    added: [][]const u8,
    modified: [][]const u8,
    removed: [][]const u8,
    _arena: *std.heap.ArenaAllocator,
    gpa: Allocator,

    pub fn deinit(self: *ChangeSet) void {
        const child = self._arena.child_allocator;
        self._arena.deinit();
        child.destroy(self._arena);
        self.gpa.free(self.added);
        self.gpa.free(self.modified);
        self.gpa.free(self.removed);
        self.* = undefined;
    }

    pub fn total(self: ChangeSet) usize {
        return self.added.len + self.modified.len + self.removed.len;
    }

    pub fn isEmpty(self: ChangeSet) bool {
        return self.total() == 0;
    }

    /// Added + modified paths, in that order — the set to pass as
    /// `pipeline.Options.only` to re-import exactly what changed. The slice is
    /// owned by the caller; the path bytes are borrowed from the change set and
    /// stay valid while it lives.
    pub fn changedPaths(self: ChangeSet, gpa: Allocator) Allocator.Error![][]const u8 {
        const paths = try gpa.alloc([]const u8, self.added.len + self.modified.len);
        errdefer gpa.free(paths);
        @memcpy(paths[0..self.added.len], self.added);
        @memcpy(paths[self.added.len..], self.modified);
        return paths;
    }
};

/// The outcome of a detection pass: what changed, plus the new baseline to keep
/// for the next pass. Call `deinit` exactly once.
pub const Result = struct {
    changes: ChangeSet,
    snapshot: Snapshot,

    pub fn deinit(self: *Result) void {
        self.changes.deinit();
        self.snapshot.deinit();
        self.* = undefined;
    }
};

/// Capture a baseline: stat and hash every indexed file. This is a full scan
/// (one read per asset); later `detect` passes only read candidates.
pub fn capture(
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    index: AssetIndex,
    options: Options,
) Error!Snapshot {
    return build(gpa, io, project_root, index, null, options);
}

/// Compare the current project state against `previous` and produce both the
/// change set and the new baseline. `previous` is not modified.
pub fn detect(
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    previous: *const Snapshot,
    index: AssetIndex,
    options: Options,
) Error!Result {
    const snapshot = try build(gpa, io, project_root, index, previous, options);
    errdefer {
        var tmp = snapshot;
        tmp.deinit();
    }
    const changes = try diff(gpa, previous.entries, snapshot.entries);
    return .{ .changes = changes, .snapshot = snapshot };
}

// --- internals -------------------------------------------------------------

fn build(
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    index: AssetIndex,
    previous: ?*const Snapshot,
    options: Options,
) Error!Snapshot {
    const arena = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, index.count());

    for (index.entries.items) |asset| {
        const stat = project_root.statFile(io, asset.path, .{}) catch |err| switch (err) {
            // Deleted between indexing and detection: leave it out of the new
            // baseline so the merge reports it as removed.
            error.FileNotFound => continue,
            else => return error.ProjectIo,
        };
        const mtime = stat.mtime.nanoseconds;

        const hash: Hash = blk: {
            if (previous) |prev| {
                if (!options.verify_all) {
                    if (prev.find(asset.path)) |old| {
                        if (old.sameFingerprint(stat.size, mtime)) break :blk old.hash;
                    }
                }
            }
            const bytes = project_root.readFileAlloc(io, asset.path, gpa, .limited(options.max_source_bytes)) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProjectIo,
            };
            defer gpa.free(bytes);
            break :blk cache_mod.hashBytes(bytes);
        };

        const path = a.dupe(u8, asset.path) catch return error.OutOfMemory;
        list.appendAssumeCapacity(.{ .path = path, .size = stat.size, .mtime = mtime, .hash = hash });
    }

    std.mem.sort(Entry, list.items, {}, entryLessThan);
    const entries = list.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return .{ .gpa = gpa, .entries = entries, ._arena = arena };
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Linear merge join over two path-sorted entry arrays.
fn diff(gpa: Allocator, old: []const Entry, new: []const Entry) Error!ChangeSet {
    const arena = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var added: std.ArrayList([]const u8) = .empty;
    errdefer added.deinit(gpa);
    var modified: std.ArrayList([]const u8) = .empty;
    errdefer modified.deinit(gpa);
    var removed: std.ArrayList([]const u8) = .empty;
    errdefer removed.deinit(gpa);

    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len and j < new.len) {
        switch (std.mem.order(u8, old[i].path, new[j].path)) {
            .lt => {
                try removed.append(gpa, try a.dupe(u8, old[i].path));
                i += 1;
            },
            .gt => {
                try added.append(gpa, try a.dupe(u8, new[j].path));
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, &old[i].hash, &new[j].hash)) {
                    try modified.append(gpa, try a.dupe(u8, new[j].path));
                }
                i += 1;
                j += 1;
            },
        }
    }
    while (i < old.len) : (i += 1) try removed.append(gpa, try a.dupe(u8, old[i].path));
    while (j < new.len) : (j += 1) try added.append(gpa, try a.dupe(u8, new[j].path));

    return .{
        .added = try added.toOwnedSlice(gpa),
        .modified = try modified.toOwnedSlice(gpa),
        .removed = try removed.toOwnedSlice(gpa),
        ._arena = arena,
        .gpa = gpa,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const alloc_probe = @import("../core/alloc_probe.zig");

fn seed(tmp: *testing.TmpDir, io: Io, path: []const u8, data: []const u8) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn rootPath(tmp: *testing.TmpDir, io: Io, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "changes: capture records hashes, sizes and sorted paths" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/b.txt", "beta");
    try seed(&tmp, io, "assets/a.txt", "alpha");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);

    var snap = try capture(gpa, io, root, index, .{});
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.count());
    try testing.expectEqualStrings("assets/a.txt", snap.entries[0].path);
    try testing.expectEqualStrings("assets/b.txt", snap.entries[1].path);
    try testing.expectEqual(@as(u64, 9), snap.totalBytes());
    try testing.expectEqualSlices(u8, &cache_mod.hashBytes("alpha"), &snap.entries[0].hash);

    const found = snap.find("assets/b.txt").?;
    try testing.expectEqual(@as(u64, 4), found.size);
    try testing.expect(snap.find("assets/missing.txt") == null);
}

test "changes: an untouched project reports no changes and reads nothing new" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/a.txt", "alpha");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();

    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();
    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();

    try testing.expect(result.changes.isEmpty());
    try testing.expectEqual(@as(usize, 1), result.snapshot.count());
    try testing.expectEqualSlices(u8, &before.entries[0].hash, &result.snapshot.entries[0].hash);
    try testing.expectEqual(before.entries[0].mtime, result.snapshot.entries[0].mtime);
}

test "changes: added, modified and removed files are classified" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/keep.txt", "keep");
    try seed(&tmp, io, "assets/edit.txt", "one");
    try seed(&tmp, io, "assets/gone.txt", "bye");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();

    try seed(&tmp, io, "assets/edit.txt", "a longer value");
    try seed(&tmp, io, "assets/new.txt", "fresh");
    try tmp.dir.deleteFile(io, "assets/gone.txt");
    index.deinit();
    index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});

    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.changes.added.len);
    try testing.expectEqualStrings("assets/new.txt", result.changes.added[0]);
    try testing.expectEqual(@as(usize, 1), result.changes.modified.len);
    try testing.expectEqualStrings("assets/edit.txt", result.changes.modified[0]);
    try testing.expectEqual(@as(usize, 1), result.changes.removed.len);
    try testing.expectEqualStrings("assets/gone.txt", result.changes.removed[0]);
    try testing.expectEqual(@as(usize, 3), result.changes.total());

    const paths = try result.changes.changedPaths(gpa);
    defer gpa.free(paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("assets/new.txt", paths[0]);
    try testing.expectEqualStrings("assets/edit.txt", paths[1]);

    // The change set owns its paths: it survives the old baseline.
    before.deinit();
    try testing.expectEqualStrings("assets/gone.txt", result.changes.removed[0]);
    before = try capture(gpa, io, root, index, .{});
}

test "changes: a touch or identical re-save is not a modification" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/a.txt", "same bytes");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();

    // Re-save identical content and push mtime forward: fingerprint moves, hash
    // does not, so the confirmation tier suppresses the change.
    try seed(&tmp, io, "assets/a.txt", "same bytes");
    try tmp.dir.setTimestamps(io, "assets/a.txt", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = before.entries[0].mtime + 5_000_000_000 } },
    });

    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();
    try testing.expect(result.changes.isEmpty());
    try testing.expect(result.snapshot.entries[0].mtime != before.entries[0].mtime);
    try testing.expectEqualSlices(u8, &before.entries[0].hash, &result.snapshot.entries[0].hash);
}

test "changes: size+mtime preserving edits need verify_all (documented blind spot)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/a.txt", "aaaa");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();

    // Same length, and mtime restored to the recorded value.
    try seed(&tmp, io, "assets/a.txt", "bbbb");
    try tmp.dir.setTimestamps(io, "assets/a.txt", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = before.entries[0].mtime } },
    });

    var cheap = try detect(gpa, io, root, &before, index, .{});
    defer cheap.deinit();
    try testing.expect(cheap.changes.isEmpty()); // the cheap tier cannot see it

    var strict = try detect(gpa, io, root, &before, index, .{ .verify_all = true });
    defer strict.deinit();
    try testing.expectEqual(@as(usize, 1), strict.changes.modified.len);
    try testing.expectEqualStrings("assets/a.txt", strict.changes.modified[0]);
}

test "changes: a rename is a removal plus an addition" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/old.txt", "payload");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();

    try tmp.dir.rename("assets/old.txt", tmp.dir, "assets/new.txt", io);
    index.deinit();
    index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});

    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.changes.added.len);
    try testing.expectEqualStrings("assets/new.txt", result.changes.added[0]);
    try testing.expectEqual(@as(usize, 1), result.changes.removed.len);
    try testing.expectEqualStrings("assets/old.txt", result.changes.removed[0]);
    try testing.expectEqual(@as(usize, 0), result.changes.modified.len);
}

test "changes: a file deleted after indexing is reported as removed, not an error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/a.txt", "alpha");
    try seed(&tmp, io, "assets/b.txt", "beta");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();
    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();

    // The index still lists b.txt, but the file is gone from disk.
    try tmp.dir.deleteFile(io, "assets/b.txt");
    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.snapshot.count());
    try testing.expectEqual(@as(usize, 1), result.changes.removed.len);
    try testing.expectEqualStrings("assets/b.txt", result.changes.removed[0]);
}

test "changes: empty projects and empty change sets" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();

    var before = try capture(gpa, io, root, index, .{});
    defer before.deinit();
    try testing.expectEqual(@as(usize, 0), before.count());
    var result = try detect(gpa, io, root, &before, index, .{});
    defer result.deinit();
    try testing.expect(result.changes.isEmpty());
    const paths = try result.changes.changedPaths(gpa);
    defer gpa.free(paths);
    try testing.expectEqual(@as(usize, 0), paths.len);
    const keys = try result.snapshot.cacheKeys(gpa, importer_mod.defaultRegistry(), "");
    defer gpa.free(keys);
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "changes: capture and detect survive allocation failure" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try seed(&tmp, io, "assets/a.txt", "alpha");
    try seed(&tmp, io, "assets/b.txt", "beta");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);

    try alloc_probe.check(
        struct {
            fn f(alloc: Allocator, path: []const u8, io_in: Io) !void {
                var index = try assets.indexDirectories(alloc, io_in, path, &.{"assets"});
                defer index.deinit();
                var root = try Io.Dir.openDirAbsolute(io_in, path, .{});
                defer root.close(io_in);
                var snap = try capture(alloc, io_in, root, index, .{});
                defer snap.deinit();
                const keys = try snap.cacheKeys(alloc, importer_mod.defaultRegistry(), "");
                alloc.free(keys);
                var result = try detect(alloc, io_in, root, &snap, index, .{});
                defer result.deinit();
                const paths = try result.changes.changedPaths(alloc);
                alloc.free(paths);
            }
        }.f,
        .{ root_path, io },
    );
}

test "changes: snapshots are deterministic and independent" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets/deep");
    try seed(&tmp, io, "assets/deep/z.txt", "z");
    try seed(&tmp, io, "assets/a.txt", "a");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();

    var a = try capture(gpa, io, root, index, .{});
    defer a.deinit();
    var b = try capture(gpa, io, root, index, .{});
    defer b.deinit();
    try testing.expectEqual(a.count(), b.count());
    for (a.entries, b.entries) |x, y| {
        try testing.expectEqualStrings(x.path, y.path);
        try testing.expectEqual(x.size, y.size);
        try testing.expectEqualSlices(u8, &x.hash, &y.hash);
    }
    // Sorted depth-first order is by full path.
    try testing.expectEqualStrings("assets/a.txt", a.entries[0].path);
    try testing.expectEqualStrings("assets/deep/z.txt", a.entries[1].path);
}

test "changes: path ordering helpers agree with the sort" {
    var paths = [_][]const u8{ "b", "a", "c" };
    std.mem.sort([]const u8, &paths, {}, pathLessThan);
    try testing.expectEqualStrings("a", paths[0]);
    try testing.expectEqualStrings("c", paths[2]);
    var entries = [_]Entry{
        .{ .path = "b", .size = 1, .mtime = 2, .hash = cache_mod.hashBytes("b") },
        .{ .path = "a", .size = 1, .mtime = 1, .hash = cache_mod.hashBytes("a") },
    };
    try testing.expect(entries[0].sameFingerprint(1, 2));
    try testing.expect(!entries[0].sameFingerprint(2, 2));
    try testing.expect(!entries[0].sameFingerprint(1, 3));
    std.mem.sort(Entry, &entries, {}, entryLessThan);
    try testing.expectEqualStrings("a", entries[0].path);
}

test "changes: snapshot cache keys match the keys the pipeline derives" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    try seed(&tmp, io, "assets/a.txt", "alpha\r\n");
    try seed(&tmp, io, "assets/b.json", "{ \"x\": 1 }");
    try seed(&tmp, io, "assets/c.bin", "opaque");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try rootPath(&tmp, io, &buf);
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var cache_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{root_path});
    var store = try cache_mod.Cache.open(io, cache_path);
    defer store.deinit();
    var index = try assets.indexDirectories(gpa, io, root_path, &.{"assets"});
    defer index.deinit();

    const registry = importer_mod.defaultRegistry();
    var report = try pipeline.runSequential(gpa, io, root, index, &store, .{ .registry = registry });
    defer report.deinit();
    const imported = try report.liveKeys(gpa);
    defer gpa.free(imported);

    var snap = try capture(gpa, io, root, index, .{});
    defer snap.deinit();
    const derived = try snap.cacheKeys(gpa, registry, "");
    defer gpa.free(derived);

    // Same order (both sorted by path) and identical keys, including the raw
    // fallback and the salt-free options hash.
    try testing.expectEqual(imported.len, derived.len);
    for (imported, derived) |a, b| try testing.expectEqualSlices(u8, &a, &b);

    // A different salt must change every derived key, exactly as the pipeline.
    const salted = try snap.cacheKeys(gpa, registry, "profile-a");
    defer gpa.free(salted);
    for (derived, salted) |a, b| try testing.expect(!std.mem.eql(u8, &a, &b));

    // Editing one asset changes only its key.
    try seed(&tmp, io, "assets/a.txt", "alpha edited\r\n");
    var result = try detect(gpa, io, root, &snap, index, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.changes.modified.len);
    const after = try result.snapshot.cacheKeys(gpa, registry, "");
    defer gpa.free(after);
    var differing: usize = 0;
    for (derived, after) |a, b| {
        if (!std.mem.eql(u8, &a, &b)) differing += 1;
    }
    try testing.expectEqual(@as(usize, 1), differing);
}
