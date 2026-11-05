//! Asset indexing.
//!
//! Walks the project's asset directories and builds an index of files with a
//! coarse kind (derived from extension) and byte size. This is the "index
//! assets" startup stage. Importing, caching and dependency tracking are
//! planned extensions of the asset system (see docs/architecture.md).
//!
//! Missing asset directories are skipped (a project may legitimately have no
//! assets yet); unreadable directories are an error.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AssetKind = enum {
    texture,
    audio,
    model,
    script,
    scene,
    shader,
    font,
    data,
    unknown,

    /// Classify by file extension (case-insensitive). `ext` includes the dot.
    pub fn fromExtension(ext: []const u8) AssetKind {
        const table = .{
            .{ AssetKind.texture, &[_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".qoi", ".gif", ".webp", ".hdr", ".exr", ".ktx", ".ktx2", ".dds" } },
            .{ AssetKind.audio, &[_][]const u8{ ".wav", ".ogg", ".mp3", ".flac", ".opus", ".aiff" } },
            .{ AssetKind.model, &[_][]const u8{ ".gltf", ".glb", ".obj", ".fbx", ".dae" } },
            .{ AssetKind.script, &[_][]const u8{".lua"} },
            .{ AssetKind.scene, &[_][]const u8{ ".scene", ".corexscene" } },
            .{ AssetKind.shader, &[_][]const u8{ ".glsl", ".vert", ".frag", ".hlsl", ".wgsl", ".comp", ".shader" } },
            .{ AssetKind.font, &[_][]const u8{ ".ttf", ".otf", ".woff", ".woff2" } },
            .{ AssetKind.data, &[_][]const u8{ ".json", ".xml", ".csv", ".txt", ".bin", ".dat" } },
        };
        inline for (table) |entry| {
            for (entry[1]) |candidate| {
                if (std.ascii.eqlIgnoreCase(ext, candidate)) return entry[0];
            }
        }
        return .unknown;
    }
};

pub const AssetEntry = struct {
    /// Project-relative path, e.g. "assets/textures/hero.png".
    path: []const u8,
    size: u64,
    kind: AssetKind,
};

/// An owned index of asset files. Call `deinit` to release it.
pub const AssetIndex = struct {
    gpa: Allocator,
    entries: std.ArrayList(AssetEntry),
    _arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *AssetIndex) void {
        self.entries.deinit(self.gpa);
        const child = self._arena.child_allocator;
        self._arena.deinit();
        child.destroy(self._arena);
        self.* = undefined;
    }

    pub fn count(self: AssetIndex) usize {
        return self.entries.items.len;
    }

    pub fn countByKind(self: AssetIndex, kind: AssetKind) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }

    pub fn totalBytes(self: AssetIndex) u64 {
        var total: u64 = 0;
        for (self.entries.items) |e| total += e.size;
        return total;
    }
};

pub const IndexError = error{
    ProjectIo,
    OutOfMemory,
};

/// Index all files under `dirs` (project-relative) within `project_root`.
pub fn indexDirectories(
    gpa: Allocator,
    io: Io,
    project_root: []const u8,
    dirs: []const []const u8,
) IndexError!AssetIndex {
    var arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var index = AssetIndex{
        .gpa = gpa,
        .entries = .empty,
        ._arena = arena,
    };
    errdefer index.entries.deinit(gpa);

    var root = Io.Dir.openDirAbsolute(io, project_root, .{}) catch return error.ProjectIo;
    defer root.close(io);

    for (dirs) |sub| {
        var dir = root.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return error.ProjectIo,
        };
        defer dir.close(io);

        var walker = dir.walk(a) catch return error.OutOfMemory;
        defer walker.deinit();

        while (walker.next(io) catch return error.ProjectIo) |entry| {
            if (entry.kind != .file) continue;
            const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const rel = std.fmt.allocPrint(a, "{s}/{s}", .{ sub, entry.path }) catch return error.OutOfMemory;
            index.entries.append(gpa, .{
                .path = rel,
                .size = stat.size,
                .kind = AssetKind.fromExtension(std.fs.path.extension(entry.basename)),
            }) catch return error.OutOfMemory;
        }
    }

    // Deterministic order for reproducible reports and tests.
    std.mem.sort(AssetEntry, index.entries.items, {}, lessThan);
    return index;
}

fn lessThan(_: void, a: AssetEntry, b: AssetEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

test "AssetKind.fromExtension classifies common types" {
    try std.testing.expectEqual(AssetKind.texture, AssetKind.fromExtension(".png"));
    try std.testing.expectEqual(AssetKind.texture, AssetKind.fromExtension(".PNG"));
    try std.testing.expectEqual(AssetKind.texture, AssetKind.fromExtension(".qoi"));
    try std.testing.expectEqual(AssetKind.texture, AssetKind.fromExtension(".bmp"));
    try std.testing.expectEqual(AssetKind.texture, AssetKind.fromExtension(".tga"));
    try std.testing.expectEqual(AssetKind.audio, AssetKind.fromExtension(".ogg"));
    try std.testing.expectEqual(AssetKind.script, AssetKind.fromExtension(".lua"));
    try std.testing.expectEqual(AssetKind.scene, AssetKind.fromExtension(".scene"));
    try std.testing.expectEqual(AssetKind.model, AssetKind.fromExtension(".gltf"));
    try std.testing.expectEqual(AssetKind.unknown, AssetKind.fromExtension(".xyz"));
    try std.testing.expectEqual(AssetKind.unknown, AssetKind.fromExtension(""));
}

test "indexDirectories: indexes files recursively and skips missing dirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "assets/textures");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/textures/hero.png", .data = "png-bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/theme.ogg", .data = "ogg" });
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/main.lua", .data = "print(1)" });

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    var index = try indexDirectories(std.testing.allocator, io, root, &.{ "assets", "scripts", "missing" });
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 3), index.count());
    try std.testing.expectEqual(@as(usize, 1), index.countByKind(.texture));
    try std.testing.expectEqual(@as(usize, 1), index.countByKind(.audio));
    try std.testing.expectEqual(@as(usize, 1), index.countByKind(.script));
    // Sorted order: assets/textures/hero.png, assets/theme.ogg, scripts/main.lua
    // ("textures" < "theme" because 'e' < 'h').
    try std.testing.expectEqualStrings("assets/textures/hero.png", index.entries.items[0].path);
    try std.testing.expectEqual(@as(u64, 9), index.entries.items[0].size);
    try std.testing.expectEqualStrings("assets/theme.ogg", index.entries.items[1].path);
    try std.testing.expect(index.totalBytes() > 0);
}

test "indexDirectories: empty project yields empty index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var index = try indexDirectories(std.testing.allocator, io, buf[0..n], &.{"assets"});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 0), index.count());
}
