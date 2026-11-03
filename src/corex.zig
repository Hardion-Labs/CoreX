//! CoreX public module. Engine subsystems will be exposed from this module.

/// Project version for the initial development scaffold.
pub const version = "0.1.0-dev";

/// Zig compiler version targeted by this project.
pub const zig_version = "0.17.0";

test "project metadata is available" {
    try @import("std").testing.expectEqualStrings("0.1.0-dev", version);
    try @import("std").testing.expectEqualStrings("0.17.0", zig_version);
}
