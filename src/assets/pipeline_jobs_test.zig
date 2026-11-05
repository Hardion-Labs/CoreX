//! Integration tests: the asset import pipeline dispatched over the engine job
//! system. Kept in a separate file so the pipeline module itself remains
//! independent of `core.jobs`; the public test build imports this file.

const std = @import("std");
const jobs = @import("../core/jobs.zig");
const assets = @import("../assets.zig");

const Io = std.Io;

fn seedProject(tmp: *std.testing.TmpDir, io: Io, n: usize) !void {
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "cache");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "assets/f{d}.txt", .{i});
        var data_buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "line\r\n{d}", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }
}

test "pipeline integration: parallel import over JobSystem workers" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 4);
    defer js.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try seedProject(&tmp, io, 24);

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root_path = buf[0..n];

    var idx = try assets.indexDirectories(std.testing.allocator, io, root_path, &.{"assets"});
    defer idx.deinit();
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var cache_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{root_path});
    var cache = try assets.Cache.open(io, cache_path);
    defer cache.deinit();

    var first = try assets.pipeline.run(std.testing.allocator, js.io(), root, idx, &cache, .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 24), first.imported);
    try std.testing.expectEqual(@as(usize, 0), first.failed);

    var second = try assets.pipeline.run(std.testing.allocator, js.io(), root, idx, &cache, .{});
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 24), second.cached);
    try std.testing.expectEqual(@as(usize, 0), second.imported);
    try std.testing.expectEqual(@as(usize, 0), second.failed);
}

test "pipeline integration: a bad asset does not abort parallel batch" {
    var js: jobs.JobSystem = undefined;
    js.init(std.testing.allocator, 2);
    defer js.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try seedProject(&tmp, io, 8);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/bad.json", .data = "{not json" });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root_path = buf[0..n];

    var idx = try assets.indexDirectories(std.testing.allocator, io, root_path, &.{"assets"});
    defer idx.deinit();
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    var cache_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{root_path});
    var cache = try assets.Cache.open(io, cache_path);
    defer cache.deinit();

    var report = try assets.pipeline.run(std.testing.allocator, js.io(), root, idx, &cache, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 8), report.imported);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
}
