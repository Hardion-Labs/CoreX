//! Engine versioning and project compatibility policy.
//!
//! See `docs/versioning.md` for the stable compatibility contract. The engine
//! never installs or selects versions; it only reports its own version and
//! checks whether a project is compatible with it.

const std = @import("std");

pub const Version = std.SemanticVersion;

/// The CoreXEngine version. Bumped according to Semantic Versioning.
pub const engine: Version = .{ .major = 0, .minor = 1, .patch = 0, .pre = "dev" };

/// The Zig compiler version this engine targets.
pub const zig_version = "0.17.0";

/// The `.corex` manifest format version this engine understands.
pub const manifest_format: u32 = 1;

/// Result of comparing a project's target engine version against this engine.
pub const Compatibility = enum {
    compatible,
    incompatible_major,
    incompatible_minor,

    pub fn isCompatible(self: Compatibility) bool {
        return self == .compatible;
    }

    pub fn describe(self: Compatibility) []const u8 {
        return switch (self) {
            .compatible => "compatible",
            .incompatible_major => "incompatible: project targets a different major engine version",
            .incompatible_minor => "incompatible: project targets an unsupported minor engine version",
        };
    }
};

/// Check whether a project targeting `project` can run on this `engine` version.
///
/// Policy (see docs/versioning.md):
/// - Different major -> incompatible.
/// - Major 0: minor must match exactly (0.x minor bumps may break).
/// - Major >= 1: project minor must be <= engine minor (backward compatible).
/// - Patch, pre-release and build metadata do not affect compatibility.
pub fn check(project: Version, running: Version) Compatibility {
    if (project.major != running.major) return .incompatible_major;
    if (running.major == 0) {
        if (project.minor != running.minor) return .incompatible_minor;
    } else {
        if (project.minor > running.minor) return .incompatible_minor;
    }
    return .compatible;
}

/// Format a version into a caller-provided buffer. Returns the written slice.
pub fn format(version: Version, buf: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    version.format(&writer) catch return buf[0..0];
    return writer.buffered();
}

test "engine metadata is present" {
    try std.testing.expectEqual(@as(usize, 0), engine.major);
    try std.testing.expectEqual(@as(usize, 1), engine.minor);
    try std.testing.expectEqualStrings("0.17.0", zig_version);
    try std.testing.expectEqual(@as(u32, 1), manifest_format);
}

test "compatibility: same 0.x minor is compatible" {
    const project = Version{ .major = 0, .minor = 1, .patch = 5 };
    try std.testing.expectEqual(Compatibility.compatible, check(project, engine));
}

test "compatibility: different 0.x minor is incompatible" {
    const project = Version{ .major = 0, .minor = 2, .patch = 0 };
    try std.testing.expectEqual(Compatibility.incompatible_minor, check(project, engine));
}

test "compatibility: different major is incompatible" {
    const project = Version{ .major = 1, .minor = 0, .patch = 0 };
    try std.testing.expectEqual(Compatibility.incompatible_major, check(project, engine));
}

test "compatibility: stable 1.x allows older or equal minor" {
    const running = Version{ .major = 1, .minor = 3, .patch = 0 };
    try std.testing.expectEqual(Compatibility.compatible, check(.{ .major = 1, .minor = 2, .patch = 9 }, running));
    try std.testing.expectEqual(Compatibility.compatible, check(.{ .major = 1, .minor = 3, .patch = 0 }, running));
    try std.testing.expectEqual(Compatibility.incompatible_minor, check(.{ .major = 1, .minor = 4, .patch = 0 }, running));
}

test "compatibility: patch and pre-release do not affect compatibility" {
    const a = Version{ .major = 0, .minor = 1, .patch = 0, .pre = "dev" };
    const b = Version{ .major = 0, .minor = 1, .patch = 99, .pre = "rc.1", .build = "abc" };
    try std.testing.expectEqual(Compatibility.compatible, check(a, b));
}

test "format renders semver" {
    var buf: [64]u8 = undefined;
    const s = format(.{ .major = 1, .minor = 2, .patch = 3, .pre = "dev" }, &buf);
    try std.testing.expectEqualStrings("1.2.3-dev", s);
}
