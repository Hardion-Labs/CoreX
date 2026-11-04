//! `.corex` project manifest parsing and validation.
//!
//! See `docs/project-format.md`. The `.corex` file is the project entry point.
//! The engine reads and validates it; it never creates projects. All paths in
//! the manifest must be project-relative and free of traversal (`..`).

const std = @import("std");
const version = @import("version.zig");
const paths = @import("paths.zig");

const Allocator = std.mem.Allocator;

pub const default_asset_directories = [_][]const u8{"assets"};
pub const default_script_directories = [_][]const u8{"scripts"};

/// A validated project manifest. Owns its strings through an arena; call
/// `deinit` to release them. Construct with `parse`.
pub const Manifest = struct {
    format_version: u32,
    name: []const u8,
    id: ?[]const u8,
    engine_version: version.Version,
    initial_scene: ?[]const u8,
    asset_directories: []const []const u8,
    script_directories: []const []const u8,

    _arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Manifest) void {
        const child = self._arena.child_allocator;
        self._arena.deinit();
        child.destroy(self._arena);
        self.* = undefined;
    }

    /// Check this manifest's target engine version against a running engine.
    pub fn compatibility(self: Manifest, running: version.Version) version.Compatibility {
        return version.check(self.engine_version, running);
    }
};

/// The raw JSON shape. Only used internally during parsing.
const RawManifest = struct {
    format_version: u32,
    name: []const u8,
    id: ?[]const u8 = null,
    engine_version: []const u8,
    initial_scene: ?[]const u8 = null,
    asset_directories: ?[]const []const u8 = null,
    script_directories: ?[]const []const u8 = null,
};

pub const ParseError = error{
    InvalidJson,
    UnsupportedFormatVersion,
    InvalidName,
    InvalidEngineVersion,
    UnsafePath,
    OutOfMemory,
};

/// Parse and structurally validate a `.corex` manifest from its bytes.
///
/// This checks the format version, name, engine version syntax and path safety.
/// It does NOT check compatibility against the running engine; call
/// `Manifest.compatibility` for that (kept separate so invalid manifests and
/// incompatible projects map to distinct exit codes).
pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Manifest {
    var arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(RawManifest, gpa, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const raw = parsed.value;

    if (raw.format_version != version.manifest_format) return error.UnsupportedFormatVersion;
    try validateName(raw.name);
    const eng = version.Version.parse(raw.engine_version) catch return error.InvalidEngineVersion;

    if (raw.initial_scene) |scene| try validateRelPath(scene);

    const asset_dirs = try dupePaths(a, raw.asset_directories orelse &default_asset_directories);
    const script_dirs = try dupePaths(a, raw.script_directories orelse &default_script_directories);

    const name = try a.dupe(u8, raw.name);
    const id = if (raw.id) |s| try a.dupe(u8, s) else null;
    const scene = if (raw.initial_scene) |s| try a.dupe(u8, s) else null;

    return .{
        .format_version = raw.format_version,
        .name = name,
        .id = id,
        .engine_version = eng,
        .initial_scene = scene,
        .asset_directories = asset_dirs,
        .script_directories = script_dirs,
        ._arena = arena,
    };
}

fn dupePaths(a: Allocator, dir_paths: []const []const u8) ParseError![]const []const u8 {
    const out = try a.alloc([]const u8, dir_paths.len);
    for (dir_paths, 0..) |p, i| {
        try validateRelPath(p);
        out[i] = try a.dupe(u8, p);
    }
    return out;
}

fn validateName(name: []const u8) ParseError!void {
    if (name.len == 0 or name.len > 128) return error.InvalidName;
    for (name) |c| {
        if (c < 0x20 or c == '/' or c == '\\') return error.InvalidName;
    }
}

/// Reject absolute paths, traversal (`..`), self-reference (`.`), empty
/// components and control characters. Paths must stay within the project root.
/// Delegates to the shared path-safety rule in `paths.zig`.
fn validateRelPath(p: []const u8) ParseError!void {
    paths.validateRelative(p) catch |err| switch (err) {
        error.UnsafePath => return error.UnsafePath,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "parse: minimal manifest uses defaults" {
    const src =
        \\{ "format_version": 1, "name": "MyGame", "engine_version": "0.1.0" }
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectEqualStrings("MyGame", m.name);
    try std.testing.expect(m.id == null);
    try std.testing.expect(m.initial_scene == null);
    try std.testing.expectEqual(@as(usize, 1), m.asset_directories.len);
    try std.testing.expectEqualStrings("assets", m.asset_directories[0]);
    try std.testing.expectEqualStrings("scripts", m.script_directories[0]);
    try std.testing.expectEqual(version.Compatibility.compatible, m.compatibility(version.engine));
}

test "parse: full manifest" {
    const src =
        \\{
        \\  "format_version": 1,
        \\  "name": "MyGame",
        \\  "id": "abc-123",
        \\  "engine_version": "0.1.0",
        \\  "initial_scene": "scenes/main.scene",
        \\  "asset_directories": ["assets", "shared"],
        \\  "script_directories": ["scripts"]
        \\}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectEqualStrings("abc-123", m.id.?);
    try std.testing.expectEqualStrings("scenes/main.scene", m.initial_scene.?);
    try std.testing.expectEqual(@as(usize, 2), m.asset_directories.len);
    try std.testing.expectEqualStrings("shared", m.asset_directories[1]);
}

test "parse: malformed json" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "{ not json"));
}

test "parse: missing required field" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "X" }
    ));
}

test "parse: unknown field rejected" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "bogus": 1 }
    ));
}

test "parse: unsupported format version" {
    try std.testing.expectError(error.UnsupportedFormatVersion, parse(std.testing.allocator,
        \\{ "format_version": 99, "name": "X", "engine_version": "0.1.0" }
    ));
}

test "parse: invalid name" {
    try std.testing.expectError(error.InvalidName, parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "", "engine_version": "0.1.0" }
    ));
    try std.testing.expectError(error.InvalidName, parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "a/b", "engine_version": "0.1.0" }
    ));
}

test "parse: invalid engine version" {
    try std.testing.expectError(error.InvalidEngineVersion, parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "X", "engine_version": "not-semver" }
    ));
}

test "parse: unsafe paths rejected" {
    const cases = [_][]const u8{
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "initial_scene": "../escape.scene" }
        ,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "initial_scene": "/abs.scene" }
        ,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "asset_directories": ["assets/../../etc"] }
        ,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "asset_directories": [""] }
        ,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.1.0", "initial_scene": "a/./b.scene" }
        ,
    };
    for (cases) |src| {
        try std.testing.expectError(error.UnsafePath, parse(std.testing.allocator, src));
    }
}

test "parse: incompatible project version is still structurally valid" {
    var m = try parse(std.testing.allocator,
        \\{ "format_version": 1, "name": "X", "engine_version": "0.9.0" }
    );
    defer m.deinit();
    try std.testing.expectEqual(version.Compatibility.incompatible_minor, m.compatibility(version.engine));
}
