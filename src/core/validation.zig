//! Shared validation rules for project-facing text fields.
//!
//! These rules are used by the `.corex` manifest and by scene documents so the
//! engine does not duplicate display-name policy across subsystems.

const std = @import("std");

pub const NameError = error{InvalidName};

/// Validate a human-readable display name (project or scene).
///
/// Rules: non-empty, at most 128 bytes, no control characters and no path
/// separators. The name is not a path and is never used to open files.
pub fn validateDisplayName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > 128) return error.InvalidName;
    for (name) |c| {
        if (c < 0x20 or c == '/' or c == '\\') return error.InvalidName;
    }
}

test "validateDisplayName accepts ordinary names" {
    try validateDisplayName("MyGame");
    try validateDisplayName("Main Scene");
    try validateDisplayName("Scene-1");
}

test "validateDisplayName rejects empty, long, control and separator names" {
    try std.testing.expectError(error.InvalidName, validateDisplayName(""));
    try std.testing.expectError(error.InvalidName, validateDisplayName("a/b"));
    try std.testing.expectError(error.InvalidName, validateDisplayName("a\\b"));
    try std.testing.expectError(error.InvalidName, validateDisplayName("a\nb"));
    var long: [129]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectError(error.InvalidName, validateDisplayName(&long));
}
