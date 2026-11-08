//! Project configuration loading.
//!
//! Loads optional `settings.json` from the project root and merges it over
//! sensible defaults. This is the "load configuration in workers" startup
//! stage: `load` is a plain function suitable for dispatching on the job system.
//!
//! The config is a value type (no heap ownership). Missing `settings.json`
//! yields defaults; a malformed or invalid file is an error.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Renderer quality tier. The actual Low/Medium renderers and the Advanced
/// contract are planned subsystems; this is the project's selected tier.
pub const RendererTier = enum {
    low,
    medium,
    advanced,

    pub fn fromString(s: []const u8) ?RendererTier {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "advanced")) return .advanced;
        return null;
    }
};

pub const ProjectConfig = struct {
    window_width: u32 = 1280,
    window_height: u32 = 720,
    renderer: RendererTier = .medium,
    vsync: bool = true,
    target_fps: u32 = 60,
};

const RawConfig = struct {
    window_width: ?u32 = null,
    window_height: ?u32 = null,
    renderer: ?[]const u8 = null,
    vsync: ?bool = null,
    target_fps: ?u32 = null,
};

pub const LoadError = error{
    InvalidJson,
    InvalidConfig,
    ProjectIo,
    OutOfMemory,
};

/// Maximum accepted `settings.json` size (1 MiB).
pub const max_config_bytes = 1024 * 1024;

/// Parse configuration bytes, merging over defaults. Pure and testable.
pub fn parse(gpa: Allocator, bytes: []const u8) LoadError!ProjectConfig {
    const parsed = std.json.parseFromSlice(RawConfig, gpa, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const raw = parsed.value;

    var cfg = ProjectConfig{};
    if (raw.window_width) |w| {
        if (w == 0) return error.InvalidConfig;
        cfg.window_width = w;
    }
    if (raw.window_height) |h| {
        if (h == 0) return error.InvalidConfig;
        cfg.window_height = h;
    }
    if (raw.renderer) |r| {
        cfg.renderer = RendererTier.fromString(r) orelse return error.InvalidConfig;
    }
    if (raw.vsync) |v| cfg.vsync = v;
    if (raw.target_fps) |f| {
        if (f == 0) return error.InvalidConfig;
        cfg.target_fps = f;
    }
    return cfg;
}

/// Load `settings.json` from the project root. Returns defaults when the file
/// is absent. Suitable for running on a worker (`JobSystem.spawn`).
pub fn load(gpa: Allocator, io: Io, project_root: []const u8) LoadError!ProjectConfig {
    var dir = Io.Dir.openDirAbsolute(io, project_root, .{}) catch return error.ProjectIo;
    defer dir.close(io);

    const bytes = dir.readFileAlloc(io, "settings.json", gpa, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return ProjectConfig{},
        // Oversized document: reject it as an invalid config, not an IO error.
        error.StreamTooLong, error.FileTooBig => return error.InvalidConfig,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProjectIo,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes);
}

test "parse: empty object yields defaults" {
    const cfg = try parse(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(u32, 1280), cfg.window_width);
    try std.testing.expectEqual(@as(u32, 720), cfg.window_height);
    try std.testing.expectEqual(RendererTier.medium, cfg.renderer);
    try std.testing.expect(cfg.vsync);
    try std.testing.expectEqual(@as(u32, 60), cfg.target_fps);
}

test "parse: overrides merge over defaults" {
    const cfg = try parse(std.testing.allocator,
        \\{ "window_width": 1920, "renderer": "low", "vsync": false }
    );
    try std.testing.expectEqual(@as(u32, 1920), cfg.window_width);
    try std.testing.expectEqual(@as(u32, 720), cfg.window_height);
    try std.testing.expectEqual(RendererTier.low, cfg.renderer);
    try std.testing.expect(!cfg.vsync);
}

test "parse: invalid json" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "{"));
}

test "parse: invalid values" {
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\{ "window_width": 0 }
    ));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\{ "renderer": "ultra" }
    ));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\{ "target_fps": 0 }
    ));
}

test "load: missing settings file yields defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const cfg = try load(std.testing.allocator, std.testing.io, buf[0..n]);
    try std.testing.expectEqual(@as(u32, 1280), cfg.window_width);
}

test "load: reads settings from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "{ \"window_width\": 800, \"renderer\": \"advanced\" }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const cfg = try load(std.testing.allocator, std.testing.io, buf[0..n]);
    try std.testing.expectEqual(@as(u32, 800), cfg.window_width);
    try std.testing.expectEqual(RendererTier.advanced, cfg.renderer);
}
