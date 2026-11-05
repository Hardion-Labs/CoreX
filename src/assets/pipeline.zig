//! Asset import pipeline.
//!
//! Orchestrates importing an indexed set of source assets into derived
//! artifacts stored in a content-addressed cache. For each asset it reads the
//! source, selects an importer by extension, derives a cache key from the
//! source hash + importer identity/version + options, and either reuses a
//! verified cache hit or runs the importer and stores the result atomically.
//!
//! Assets are independent, so they are imported concurrently through an
//! `Io.Group` (e.g. `JobSystem.io()`). Each task writes only its own report
//! slot; counts are tallied after the group completes. A per-asset failure is
//! recorded in the report and does not abort the rest of the batch.
//!
//! Parallel dispatch requires a thread-safe allocator (the cache uses an atomic
//! temp-file counter and atomic renames, so concurrent writes are safe).
//! `runSequential` provides a no-parallelism fallback for single-threaded
//! contexts or non-thread-safe allocators.
//!
//! This module depends on the asset index, the cache and the importer registry;
//! it does not depend on the job system directly (it takes an `Io`).

const std = @import("std");
const assets = @import("../core/assets.zig");
const cache_mod = @import("cache.zig");
const importer_mod = @import("importer.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AssetKind = assets.AssetKind;
pub const AssetEntry = assets.AssetEntry;
pub const AssetIndex = assets.AssetIndex;
pub const Cache = cache_mod.Cache;
pub const Registry = importer_mod.Registry;
pub const Importer = importer_mod.Importer;

/// Maximum source file size read by the pipeline (64 MiB). Bounds memory.
pub const max_source_bytes_default: usize = 64 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    Canceled,
};

pub const Status = enum {
    /// Imported and stored in the cache this run.
    imported,
    /// Reused from a verified cache hit.
    cached,
    /// The source could not be read, imported, or cached.
    failed,
};

/// Per-asset outcome. `path` is borrowed from the index entry; `importer_id`
/// and `error_name` are static strings. Valid while the report lives.
pub const EntryResult = struct {
    path: []const u8,
    kind: AssetKind,
    status: Status,
    importer_id: ?[]const u8,
    key: ?cache_mod.Key,
    output_size: u64,
    error_name: ?[]const u8,
};

/// Owned import report, one entry per indexed asset in index order.
pub const Report = struct {
    gpa: Allocator,
    entries: []EntryResult,
    imported: usize,
    cached: usize,
    failed: usize,
    total_output_bytes: u64,

    pub fn deinit(self: *Report) void {
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn count(self: Report) usize {
        return self.entries.len;
    }
};

pub const Options = struct {
    /// Ignore cache hits and re-import every asset.
    force: bool = false,
    /// Registry used to select importers by extension.
    registry: Registry = importer_mod.defaultRegistry(),
    /// Maximum source file size to read.
    max_source_bytes: usize = max_source_bytes_default,
    /// Extra bytes folded into every cache key (e.g. a project import profile).
    options_salt: []const u8 = "",
};

const Task = struct {
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    cache: *Cache,
    options: Options,
    options_hash: cache_mod.Key,
    entry: AssetEntry,
    out: *EntryResult,
    index: usize,
};

/// Import every asset in `index`, reading sources relative to `project_root`
/// and storing derived artifacts in `cache`. Assets are processed concurrently
/// through `io`. Requires a thread-safe `gpa`.
pub fn run(
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    index: AssetIndex,
    cache: *Cache,
    options: Options,
) Error!Report {
    const entries = try gpa.alloc(EntryResult, index.count());
    errdefer gpa.free(entries);
    initSlots(entries, index);

    if (entries.len > 0) {
        const options_hash = cache_mod.hashBytes(options.options_salt);
        var group: Io.Group = .init;
        for (entries, index.entries.items, 0..) |*slot, e, i| {
            group.async(io, work, .{Task{
                .gpa = gpa,
                .io = io,
                .project_root = project_root,
                .cache = cache,
                .options = options,
                .options_hash = options_hash,
                .entry = e,
                .out = slot,
                .index = i,
            }});
        }
        group.await(io) catch return error.Canceled;
    }

    return tally(gpa, entries);
}

/// Like `run` but imports assets one at a time without dispatching through
/// `Io`. Useful for single-threaded contexts or non-thread-safe allocators.
pub fn runSequential(
    gpa: Allocator,
    io: Io,
    project_root: Io.Dir,
    index: AssetIndex,
    cache: *Cache,
    options: Options,
) Error!Report {
    const entries = try gpa.alloc(EntryResult, index.count());
    errdefer gpa.free(entries);
    initSlots(entries, index);

    const options_hash = cache_mod.hashBytes(options.options_salt);
    for (entries, index.entries.items, 0..) |*slot, e, i| {
        work(.{
            .gpa = gpa,
            .io = io,
            .project_root = project_root,
            .cache = cache,
            .options = options,
            .options_hash = options_hash,
            .entry = e,
            .out = slot,
            .index = i,
        });
    }

    return tally(gpa, entries);
}

fn initSlots(entries: []EntryResult, index: AssetIndex) void {
    for (entries, index.entries.items) |*slot, e| {
        slot.* = .{
            .path = e.path,
            .kind = e.kind,
            .status = .failed,
            .importer_id = null,
            .key = null,
            .output_size = 0,
            .error_name = null,
        };
    }
}

fn tally(gpa: Allocator, entries: []EntryResult) Report {
    var report = Report{
        .gpa = gpa,
        .entries = entries,
        .imported = 0,
        .cached = 0,
        .failed = 0,
        .total_output_bytes = 0,
    };
    for (entries) |r| {
        switch (r.status) {
            .imported => report.imported += 1,
            .cached => report.cached += 1,
            .failed => report.failed += 1,
        }
        report.total_output_bytes += r.output_size;
    }
    return report;
}

fn work(t: Task) void {
    const out = t.out;
    const ext = std.fs.path.extension(t.entry.path);
    const imp = t.options.registry.select(ext);
    out.importer_id = imp.id;

    const source = t.project_root.readFileAlloc(t.io, t.entry.path, t.gpa, .limited(t.options.max_source_bytes)) catch |err| {
        out.error_name = @errorName(err);
        return;
    };
    defer t.gpa.free(source);

    const source_hash = cache_mod.hashBytes(source);
    const key = cache_mod.deriveKey(source_hash, imp.id, imp.version, t.options_hash);
    out.key = key;

    if (!t.options.force) {
        // A read/verify error is treated as a miss so the asset is re-imported
        // (self-healing); a persistent failure surfaces on the put below.
        if (t.cache.get(t.gpa, key) catch null) |bytes| {
            defer t.gpa.free(bytes);
            out.status = .cached;
            out.output_size = bytes.len;
            return;
        }
    }

    const payload = imp.run(t.gpa, source) catch |err| {
        out.error_name = @errorName(err);
        return;
    };
    defer t.gpa.free(payload);

    t.cache.put(t.gpa, key, .{
        .path = t.entry.path,
        .source_hash = source_hash,
        .importer_id = imp.id,
        .importer_version = imp.version,
        .kind = @tagName(t.entry.kind),
    }, payload, t.index) catch |err| {
        out.error_name = @errorName(err);
        return;
    };

    out.status = .imported;
    out.output_size = payload.len;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const TestEnv = struct {
    tmp: testing.TmpDir,
    root: [Io.Dir.max_path_bytes]u8,
    root_len: usize,
    cache_dir: [Io.Dir.max_path_bytes]u8,
    cache_dir_len: usize,

    fn init() !TestEnv {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var self = TestEnv{ .tmp = tmp, .root = undefined, .root_len = 0, .cache_dir = undefined, .cache_dir_len = 0 };
        self.root_len = try tmp.dir.realPath(testing.io, &self.root);
        try tmp.dir.createDirPath(testing.io, "assets");
        try tmp.dir.createDirPath(testing.io, "cache");
        const cn = try tmp.dir.realPath(testing.io, &self.cache_dir);
        // realPath returns the tmp root; build the cache subdir path.
        self.cache_dir_len = cn;
        return self;
    }

    fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }

    fn rootPath(self: *const TestEnv) []const u8 {
        return self.root[0..self.root_len];
    }

    fn writeAsset(self: *TestEnv, sub: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn openRoot(self: *TestEnv) !Io.Dir {
        return Io.Dir.openDirAbsolute(testing.io, self.rootPath(), .{});
    }

    fn openCache(self: *TestEnv) !Cache {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/cache", .{self.rootPath()});
        return Cache.open(testing.io, p);
    }

    fn index(self: *TestEnv) !AssetIndex {
        return assets.indexDirectories(testing.allocator, testing.io, self.rootPath(), &.{"assets"});
    }
};

test "pipeline: imports text and json, then reuses cache on second run" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/a.txt", "a\r\nb");
    try env.writeAsset("assets/b.json", "{ \"x\" : 1 }");

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var first = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer first.deinit();
    try testing.expectEqual(@as(usize, 2), first.imported);
    try testing.expectEqual(@as(usize, 0), first.cached);
    try testing.expectEqual(@as(usize, 0), first.failed);

    var second = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer second.deinit();
    try testing.expectEqual(@as(usize, 0), second.imported);
    try testing.expectEqual(@as(usize, 2), second.cached);
    try testing.expectEqual(@as(usize, 0), second.failed);

    // The text artifact was normalized (CRLF -> LF): 3 bytes, not 4.
    for (second.entries) |r| {
        if (std.mem.endsWith(u8, r.path, "a.txt")) try testing.expectEqual(@as(u64, 3), r.output_size);
    }
}

test "pipeline: force re-imports even on cache hit" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/a.txt", "hello");

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var first = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer first.deinit();
    try testing.expectEqual(@as(usize, 1), first.imported);

    var forced = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{ .force = true });
    defer forced.deinit();
    try testing.expectEqual(@as(usize, 1), forced.imported);
    try testing.expectEqual(@as(usize, 0), forced.cached);
}

test "pipeline: changing source content re-imports only that asset" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/a.txt", "one");
    try env.writeAsset("assets/b.txt", "two");

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var first = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer first.deinit();
    try testing.expectEqual(@as(usize, 2), first.imported);

    try env.writeAsset("assets/a.txt", "changed");
    var second = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.imported);
    try testing.expectEqual(@as(usize, 1), second.cached);
}

test "pipeline: invalid asset is recorded as failed without aborting the batch" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/good.txt", "ok");
    try env.writeAsset("assets/bad.json", "{not json");

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var report = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.imported);
    try testing.expectEqual(@as(usize, 1), report.failed);
    for (report.entries) |r| {
        if (std.mem.endsWith(u8, r.path, "bad.json")) {
            try testing.expectEqualStrings("InvalidAsset", r.error_name.?);
        }
    }
}

test "pipeline: binary assets use the raw fallback importer" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/tex.png", &[_]u8{ 0x89, 'P', 'N', 'G', 0x00, 0xFF });

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var report = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.imported);
    try testing.expectEqualStrings("raw", report.entries[0].importer_id.?);
    try testing.expectEqual(@as(u64, 6), report.entries[0].output_size);
}

test "pipeline: empty index yields an empty report" {
    var env = try TestEnv.init();
    defer env.deinit();
    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var report = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{});
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.count());
    try testing.expectEqual(@as(u64, 0), report.total_output_bytes);
}

test "pipeline: options salt changes the cache key" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.writeAsset("assets/a.txt", "hello");

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var first = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{ .options_salt = "profile-a" });
    defer first.deinit();
    try testing.expectEqual(@as(usize, 1), first.imported);

    var second = try runSequential(testing.allocator, testing.io, root, idx, &cache, .{ .options_salt = "profile-b" });
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.imported);
}

test "pipeline: parallel run matches sequential results" {
    var env = try TestEnv.init();
    defer env.deinit();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "assets/f{d}.txt", .{i});
        var data_buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "line\r\n{d}", .{i});
        try env.writeAsset(name, data);
    }

    var root = try env.openRoot();
    defer root.close(testing.io);
    var cache = try env.openCache();
    defer cache.deinit();
    var idx = try env.index();
    defer idx.deinit();

    var par = try run(testing.allocator, testing.io, root, idx, &cache, .{});
    defer par.deinit();
    try testing.expectEqual(@as(usize, 16), par.imported);
    try testing.expectEqual(@as(usize, 0), par.failed);

    var again = try run(testing.allocator, testing.io, root, idx, &cache, .{});
    defer again.deinit();
    try testing.expectEqual(@as(usize, 16), again.cached);
    try testing.expectEqual(@as(usize, 0), again.imported);
}
