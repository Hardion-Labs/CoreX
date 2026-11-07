//! Editor public module.
//!
//! The graphical editor's composition layer: one frame of docks, a scene viewport,
//! a hierarchy and an inspector, painted with the engine's own GUI. The platform
//! parts of an editor (a window, a swapchain, real input) are still blocked in this
//! build, so what exists here is the part that can be built and verified honestly:
//! everything from "a prepared session" to "pixels on an RGBA8 surface".
const std = @import("std");
pub const shell = @import("editor/shell.zig");
pub const edit = @import("editor/edit.zig");
pub const tree = @import("editor/tree.zig");
pub const inspector = @import("editor/inspector.zig");

test {
    std.testing.refAllDecls(@This());
    _ = shell;
    _ = edit;
}
