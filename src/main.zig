const std = @import("std");
const corex = @import("corex");

pub fn main() void {
    std.debug.print("CoreX {s} — Zig {s}\n", .{ corex.version, corex.zig_version });
    std.debug.print("Scaffold inicial; consulte README.md para o roadmap.\n", .{});
}
