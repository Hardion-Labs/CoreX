//! Decode a QOI image to raw RGBA, for inspecting a headless frame (a test, a doc
//! image, a diff) without adding an image decoder to the library's surface.
//!
//! `zig build qoi-decode -- frame.qoi frame.rgba`

const std = @import("std");
const corex = @import("corex");

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, gpa) catch |err| {
        std.debug.print("qoi-decode: cannot read arguments ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| args_list.append(gpa, arg) catch |err| {
        std.debug.print("qoi-decode: out of memory reading arguments ({s})\n", .{@errorName(err)});
        return 1;
    };
    const args = args_list.items;
    if (args.len < 2) {
        std.debug.print("usage: qoi-decode <in.qoi> <out.rgba>\n", .{});
        return 2;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, args[0], gpa, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("qoi-decode: cannot read {s} ({s})\n", .{ args[0], @errorName(err) });
        return 1;
    };
    defer gpa.free(raw);
    const image = corex.assets.image.decodeQoi(gpa, raw) catch |err| {
        std.debug.print("qoi-decode: {s} is not a valid QOI image ({s})\n", .{ args[0], @errorName(err) });
        return 1;
    };
    defer gpa.free(image.pixels);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = image.pixels }) catch |err| {
        std.debug.print("qoi-decode: cannot write {s} ({s})\n", .{ args[1], @errorName(err) });
        return 1;
    };
    std.debug.print("qoi-decode: {s} -> {s} ({d}x{d})\n", .{ args[0], args[1], image.width, image.height });
    return 0;
}
