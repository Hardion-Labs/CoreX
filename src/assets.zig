//! CoreXEngine asset subsystem.
//!
//! Unifies asset indexing (`core/assets.zig`), the content-addressed import
//! cache (`assets/cache.zig`), the importer framework (`assets/importer.zig`)
//! and the import pipeline (`assets/pipeline.zig`). It also registers the
//! engine's scene importer, which reuses the scene system to validate and
//! canonicalize `.scene` documents at import time.
//!
//! Example:
//! ```zig
//! const corex = @import("corex");
//! const A = corex.assets;
//! var idx = try A.indexDirectories(gpa, io, project_root, &.{"assets"});
//! defer idx.deinit();
//! var cache = try A.Cache.open(io, cache_dir);
//! defer cache.deinit();
//! var root = try Io.Dir.openDirAbsolute(io, project_root, .{});
//! defer root.close(io);
//! var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
//!     .registry = A.engineRegistry(),
//! });
//! defer report.deinit();
//! ```
//!
//! See `docs/asset-import.md` for the cache format, importer contract and
//! incremental-import guarantees.

const std = @import("std");

const Io = std.Io;

/// Asset indexing (kind + size) used by the startup spine.
pub const index = @import("core/assets.zig");
/// Content-addressed derived-data cache.
pub const cache = @import("assets/cache.zig");
/// Importer framework and built-in raw/text/json importers.
pub const importer = @import("assets/importer.zig");
/// Import orchestration over the job system.
pub const pipeline = @import("assets/pipeline.zig");

const scene_mod = @import("scene.zig");

pub const AssetKind = index.AssetKind;
pub const AssetEntry = index.AssetEntry;
pub const AssetIndex = index.AssetIndex;
pub const indexDirectories = index.indexDirectories;

pub const Cache = cache.Cache;
pub const Importer = importer.Importer;
pub const Registry = importer.Registry;
pub const ImportError = importer.ImportError;
pub const Report = pipeline.Report;
pub const Options = pipeline.Options;
pub const Status = pipeline.Status;

/// Scene importer: validate a `.scene` document with the scene system and
/// re-serialize it canonically (deterministic, sorted by stable ID). Invalid
/// scenes are rejected at import time. Reuses the scene system; no duplication.
pub fn importScene(gpa: std.mem.Allocator, source: []const u8) ImportError![]u8 {
    var scene = scene_mod.EngineScene.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAsset,
    };
    defer scene.deinit();
    return scene.serialize(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAsset,
    };
}

pub const scene_importer = Importer{ .id = "scene", .version = 1, .importFn = importScene };

const engine_bindings = [_]Registry.Binding{
    .{ .extensions = &[_][]const u8{ ".scene", ".corexscene" }, .importer = scene_importer },
} ++ importer.builtin_bindings;

/// The engine's default import registry: scene + JSON + text importers, with
/// `raw` as the fallback for binary/unknown extensions.
pub fn engineRegistry() Registry {
    return .{ .bindings = &engine_bindings, .fallback = importer.raw_importer };
}

test {
    std.testing.refAllDecls(@This());
    _ = index;
    _ = cache;
    _ = importer;
    _ = pipeline;
}

test "scene importer canonicalizes a valid scene" {
    const src =
        \\{ "format_version": 1, "name": "main", "entities": [
        \\  { "id": 2, "name": "Child", "parent": 1 },
        \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [1, 2, 3] } } }
        \\] }
    ;
    const out = try importScene(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Re-parsing the canonical output must succeed and preserve entity count.
    var scene = try scene_mod.EngineScene.parse(std.testing.allocator, out);
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 2), scene.count());
}

test "scene importer rejects an invalid scene" {
    const bad = "{ \"format_version\": 1, \"name\": \"main\", \"entities\": [ { \"id\": 0 } ] }";
    try std.testing.expectError(error.InvalidAsset, importScene(std.testing.allocator, bad));
}

test "engine registry selects the scene importer for .scene" {
    const reg = engineRegistry();
    try std.testing.expectEqualStrings("scene", reg.select(".scene").id);
    try std.testing.expectEqualStrings("scene", reg.select(".corexscene").id);
    try std.testing.expectEqualStrings("json", reg.select(".json").id);
    try std.testing.expectEqualStrings("text", reg.select(".lua").id);
    try std.testing.expectEqualStrings("raw", reg.select(".png").id);
}

test "pipeline imports a scene through the engine registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/main.scene", .data =
        \\{ "format_version": 1, "name": "main", "entities": [
        \\  { "id": 1, "name": "Root" }
        \\] }
    });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root_path = buf[0..n];

    var idx = try indexDirectories(std.testing.allocator, io, root_path, &.{"assets"});
    defer idx.deinit();
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var cache_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{root_path});
    var store = try Cache.open(io, cache_path);
    defer store.deinit();

    var report = try pipeline.runSequential(std.testing.allocator, io, root, idx, &store, .{
        .registry = engineRegistry(),
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.imported);
    try std.testing.expectEqualStrings("scene", report.entries[0].importer_id.?);
}
