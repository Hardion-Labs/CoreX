//! Path utilities: safe project-relative path validation and absolute
//! resolution of the project entry point.
//!
//! Security rule: paths that come from a project manifest or from user input
//! must stay within the project root. Absolute paths, traversal (`..`),
//! self-reference (`.`) and control characters are rejected.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PathError = error{
    UnsafePath,
    OutOfMemory,
};

/// Validate that `p` is a safe project-relative path. Does not touch the file
/// system. Rejects absolute paths, `..`, `.`, empty components and control
/// characters.
pub fn validateRelative(p: []const u8) PathError!void {
    if (p.len == 0) return error.UnsafePath;
    if (std.fs.path.isAbsolute(p)) return error.UnsafePath;
    if (p[0] == '/' or p[0] == '\\') return error.UnsafePath;
    for (p) |c| {
        if (c < 0x20) return error.UnsafePath;
    }
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return error.UnsafePath;
    }
}

/// Resolve the project entry point to an absolute path. Relative paths are
/// resolved against the current working directory. Caller owns the result.
pub fn resolveAbsolute(gpa: Allocator, io: Io, path: []const u8) PathError![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return gpa.dupe(u8, path) catch return error.OutOfMemory;
    }
    const cwd = std.process.currentPathAlloc(io, gpa) catch return error.OutOfMemory;
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path }) catch return error.OutOfMemory;
}

test "validateRelative accepts safe paths" {
    try validateRelative("assets");
    try validateRelative("scenes/main.scene");
    try validateRelative("a/b/c.lua");
}

test "validateRelative rejects unsafe paths" {
    const bad = [_][]const u8{
        "",
        "/abs",
        "../escape",
        "a/../../etc",
        "a/./b",
        "with\x00null",
        ".",
        "..",
    };
    for (bad) |p| {
        try std.testing.expectError(error.UnsafePath, validateRelative(p));
    }
}

test "resolveAbsolute makes relative paths absolute" {
    const io = std.testing.io;
    const resolved = try resolveAbsolute(std.testing.allocator, io, "game.corex");
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "game.corex"));
}

test "resolveAbsolute preserves absolute paths" {
    const io = std.testing.io;
    const resolved = try resolveAbsolute(std.testing.allocator, io, "/tmp/game.corex");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/game.corex", resolved);
}
