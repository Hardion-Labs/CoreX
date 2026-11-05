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
/// Pure image decoders (BMP/TGA/QOI) normalizing to RGBA8.
pub const image = @import("assets/image.zig");
/// Engine-ready `CXTX` texture artifact and texture importers.
pub const texture = @import("assets/texture.zig");
/// Engine-ready `CXMH` mesh artifact and the OBJ mesh importer.
pub const mesh = @import("assets/mesh.zig");

const scene_mod = @import("scene.zig");

pub const AssetKind = index.AssetKind;
pub const AssetEntry = index.AssetEntry;
pub const AssetIndex = index.AssetIndex;
pub const indexDirectories = index.indexDirectories;

pub const Cache = cache.Cache;
pub const GcStats = cache.GcStats;
pub const Importer = importer.Importer;
pub const Registry = importer.Registry;
pub const ImportError = importer.ImportError;
pub const Report = pipeline.Report;
pub const Options = pipeline.Options;
pub const Status = pipeline.Status;
pub const Image = image.Image;
pub const Texture = texture.Texture;
pub const Mesh = mesh.Mesh;
pub const MeshView = mesh.MeshView;

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

/// Prefab importer: validate a single-root `.prefab` document with the scene
/// prefab system and re-serialize it canonically. Invalid prefabs (including
/// documents with zero or multiple roots) are rejected at import time.
pub fn importPrefab(gpa: std.mem.Allocator, source: []const u8) ImportError![]u8 {
    var p = scene_mod.EnginePrefab.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAsset,
    };
    defer p.deinit();
    return p.serialize(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAsset,
    };
}

pub const prefab_importer = Importer{ .id = "prefab", .version = 1, .importFn = importPrefab };

const engine_bindings = texture.bindings ++ mesh.bindings ++ [_]Registry.Binding{
    .{ .extensions = &[_][]const u8{ ".scene", ".corexscene" }, .importer = scene_importer },
    .{ .extensions = &[_][]const u8{ ".prefab", ".corexprefab" }, .importer = prefab_importer },
} ++ importer.builtin_bindings;

/// The engine's default import registry: texture (BMP/TGA/QOI) + mesh (OBJ) +
/// scene + prefab + JSON + text importers, with `raw` as the fallback for
/// binary/unknown extensions (e.g. PNG/JPEG/audio and other model formats, which
/// have no decoder yet).
pub fn engineRegistry() Registry {
    return .{ .bindings = &engine_bindings, .fallback = importer.raw_importer };
}

test {
    std.testing.refAllDecls(@This());
    _ = index;
    _ = cache;
    _ = importer;
    _ = pipeline;
    _ = image;
    _ = texture;
    _ = mesh;
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

test "prefab importer canonicalizes a valid single-root prefab" {
    const src =
        \\{ "format_version": 1, "name": "enemy", "entities": [
        \\  { "id": 2, "name": "Child", "parent": 1 },
        \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [1, 2, 3] } } }
        \\] }
    ;
    const out = try importPrefab(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    var p = try scene_mod.EnginePrefab.parse(std.testing.allocator, out);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(@as(u64, 1), p.root_id);
}

test "prefab importer rejects empty and multi-root documents" {
    const empty = "{ \"format_version\": 1, \"name\": \"empty\", \"entities\": [] }";
    try std.testing.expectError(error.InvalidAsset, importPrefab(std.testing.allocator, empty));
    const multi =
        \\{ "format_version": 1, "name": "multi", "entities": [
        \\  { "id": 1 }, { "id": 2 }
        \\] }
    ;
    try std.testing.expectError(error.InvalidAsset, importPrefab(std.testing.allocator, multi));
}

test "engine registry selects importers by extension" {
    const reg = engineRegistry();
    try std.testing.expectEqualStrings("scene", reg.select(".scene").id);
    try std.testing.expectEqualStrings("scene", reg.select(".corexscene").id);
    try std.testing.expectEqualStrings("prefab", reg.select(".prefab").id);
    try std.testing.expectEqualStrings("prefab", reg.select(".PREFAB").id);
    try std.testing.expectEqualStrings("bmp", reg.select(".bmp").id);
    try std.testing.expectEqualStrings("tga", reg.select(".TGA").id);
    try std.testing.expectEqualStrings("qoi", reg.select(".qoi").id);
    try std.testing.expectEqualStrings("obj", reg.select(".obj").id);
    try std.testing.expectEqualStrings("obj", reg.select(".OBJ").id);
    try std.testing.expectEqualStrings("json", reg.select(".json").id);
    try std.testing.expectEqualStrings("text", reg.select(".lua").id);
    // Formats without a decoder yet still fall back to a verbatim raw copy.
    try std.testing.expectEqualStrings("raw", reg.select(".png").id);
    try std.testing.expectEqualStrings("raw", reg.select(".wav").id);
    try std.testing.expectEqualStrings("raw", reg.select(".gltf").id);
}

test "pipeline imports a texture to a CXTX artifact and caches it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");

    // Encode a known 2x2 RGBA8 image as the QOI source asset.
    const pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const src_img = image.Image{ .width = 2, .height = 2, .pixels = @constCast(&pixels) };
    const qoi = try image.encodeQoi(std.testing.allocator, src_img);
    defer std.testing.allocator.free(qoi);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/tex.qoi", .data = qoi });

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
    try std.testing.expectEqualStrings("qoi", report.entries[0].importer_id.?);
    try std.testing.expectEqual(AssetKind.texture, report.entries[0].kind);

    // Read the cached artifact back and verify it is a valid CXTX texture whose
    // pixels match the original image exactly.
    const key = report.entries[0].key.?;
    const artifact = (try store.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(artifact);
    const tex = try texture.parse(artifact);
    try std.testing.expectEqual(@as(u32, 2), tex.width);
    try std.testing.expectEqual(@as(u32, 2), tex.height);
    try std.testing.expectEqualSlices(u8, &pixels, tex.pixels);

    // A second run is a cache hit (no re-import).
    var report2 = try pipeline.runSequential(std.testing.allocator, io, root, idx, &store, .{
        .registry = engineRegistry(),
    });
    defer report2.deinit();
    try std.testing.expectEqual(@as(usize, 0), report2.imported);
    try std.testing.expectEqual(@as(usize, 1), report2.cached);
}

test "pipeline imports an OBJ mesh to a CXMH artifact and caches it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");

    const obj_src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 1
        \\vt 0 0
        \\vt 1 0
        \\vt 0 1
        \\f 1/1/1 2/2/1 3/3/1
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/tri.obj", .data = obj_src });

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
    try std.testing.expectEqualStrings("obj", report.entries[0].importer_id.?);
    try std.testing.expectEqual(AssetKind.model, report.entries[0].kind);

    // Read the cached artifact back and verify it is a valid CXMH mesh whose
    // geometry matches the source triangle exactly.
    const key = report.entries[0].key.?;
    const artifact = (try store.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(artifact);
    const view = try mesh.parse(artifact);
    try std.testing.expectEqual(@as(u32, 3), view.vertex_count);
    try std.testing.expectEqual(@as(u32, 3), view.index_count);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &view.bounds_min);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 0 }, &view.bounds_max);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 0 }, &view.vertexAt(1).position);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, &.{ view.indexAt(0), view.indexAt(1), view.indexAt(2) });

    // A second run is a cache hit (no re-import).
    var report2 = try pipeline.runSequential(std.testing.allocator, io, root, idx, &store, .{
        .registry = engineRegistry(),
    });
    defer report2.deinit();
    try std.testing.expectEqual(@as(usize, 0), report2.imported);
    try std.testing.expectEqual(@as(usize, 1), report2.cached);
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

test "pipeline imports a prefab through the engine registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/enemy.prefab", .data =
        \\{ "format_version": 1, "name": "enemy", "entities": [
        \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [0, 1, 0] } } },
        \\  { "id": 2, "name": "Child", "parent": 1 }
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
    try std.testing.expectEqualStrings("prefab", report.entries[0].importer_id.?);
    try std.testing.expectEqual(AssetKind.prefab, report.entries[0].kind);

    const key = report.entries[0].key.?;
    const artifact = (try store.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(artifact);
    var p = try scene_mod.EnginePrefab.parse(std.testing.allocator, artifact);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.count());
}

test "pipeline + gc: orphan entries are reclaimed while live artifacts survive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/a.txt", .data = "alpha" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/b.txt", .data = "beta" });

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
    try std.testing.expectEqual(@as(usize, 2), report.imported);

    const live = try report.liveKeys(std.testing.allocator);
    defer std.testing.allocator.free(live);
    try std.testing.expectEqual(@as(usize, 2), live.len);

    // Inject an orphan entry that no live key references.
    const orphan_key = cache.deriveKey(cache.hashBytes("orphan"), "raw", 1, cache.hashBytes(""));
    try store.put(std.testing.allocator, orphan_key, .{
        .path = "gone.bin",
        .source_hash = cache.hashBytes("orphan"),
        .importer_id = "raw",
        .importer_version = 1,
        .kind = "unknown",
    }, "orphan-payload", 0);

    const stats = try store.gc(std.testing.allocator, live);
    try std.testing.expectEqual(@as(usize, 3), stats.scanned);
    try std.testing.expectEqual(@as(usize, 2), stats.kept);
    try std.testing.expectEqual(@as(usize, 1), stats.removed);
    try std.testing.expect(!try store.has(std.testing.allocator, orphan_key));
    for (live) |k| try std.testing.expect(try store.has(std.testing.allocator, k));
}

test "pipeline + gc: removing a source lets gc reclaim its stale artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/a.txt", .data = "alpha" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/b.txt", .data = "beta" });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root_path = buf[0..n];
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var cache_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{root_path});
    var store = try Cache.open(io, cache_path);
    defer store.deinit();

    var idx = try indexDirectories(std.testing.allocator, io, root_path, &.{"assets"});
    defer idx.deinit();
    var report = try pipeline.runSequential(std.testing.allocator, io, root, idx, &store, .{
        .registry = engineRegistry(),
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.imported);

    // Remove one source asset, then re-index and re-import.
    try tmp.dir.deleteFile(io, "assets/b.txt");
    var idx2 = try indexDirectories(std.testing.allocator, io, root_path, &.{"assets"});
    defer idx2.deinit();
    var report2 = try pipeline.runSequential(std.testing.allocator, io, root, idx2, &store, .{
        .registry = engineRegistry(),
    });
    defer report2.deinit();
    try std.testing.expectEqual(@as(usize, 1), report2.count());
    try std.testing.expectEqual(@as(usize, 1), report2.cached); // a.txt is a cache hit

    const live2 = try report2.liveKeys(std.testing.allocator);
    defer std.testing.allocator.free(live2);
    try std.testing.expectEqual(@as(usize, 1), live2.len);

    // Both artifacts are still on disk; GC reclaims only b's.
    const stats = try store.gc(std.testing.allocator, live2);
    try std.testing.expectEqual(@as(usize, 2), stats.scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.kept);
    try std.testing.expectEqual(@as(usize, 1), stats.removed);
    try std.testing.expect(try store.has(std.testing.allocator, live2[0]));
}
