//! CoreXEngine executable entry point.
//!
//! Parses the launch contract (docs/launch-contract.md), then runs the startup
//! pipeline. Works identically whether launched directly or by the CoreXHub;
//! the engine never depends on the Hub.

const std = @import("std");
const corex = @import("corex");

const cli = corex.core.cli;
const startup = corex.core.startup;
const splash = corex.core.splash;
const version = corex.core.version;

const Io = std.Io;

// Allow runtime log-level filtering via --log-level. The compile-time ceiling
// is debug; the effective level is chosen at runtime below.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runtimeLog,
};

var runtime_log_level: std.log.Level = .info;

fn runtimeLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > @backingInt(runtime_log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    // Collect arguments (excluding argv[0]).
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, gpa) catch return 1;
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        args_list.append(gpa, arg) catch return 1;
    }
    const args = args_list.items;

    if (args.len == 0) {
        writeOut(io, cli.help_text);
        return 0;
    }

    const opts = cli.parse(args) catch |err| {
        writeErr(io, usageMessage(err));
        writeErr(io, "Run 'corex-engine --help' for usage.\n");
        return 2;
    };

    runtime_log_level = switch (opts.log_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };

    if (opts.show_help) {
        writeOut(io, cli.help_text);
        return 0;
    }
    if (opts.show_version) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "CoreXEngine {f} (Zig {s})\n", .{ version.engine, version.zig_version }) catch return 1;
        writeOut(io, line);
        return 0;
    }

    var headless_splash = splash.HeadlessSplash{};
    var result = startup.run(gpa, io, opts, headless_splash.interface()) catch |err| {
        return startup.exitCode(err);
    };
    defer result.deinit();

    printSummary(io, &result);
    return 0;
}

fn printSummary(io: Io, result: *const startup.StartupResult) void {
    var buf: [512]u8 = undefined;
    const scene = if (result.scene) |s| s.path else "(empty scene)";
    const line = std.fmt.bufPrint(&buf,
        \\Project: {s}
        \\Mode: {s}
        \\Assets indexed: {d}
        \\Renderer tier: {s}
        \\Initial scene: {s}
        \\
    , .{
        result.manifest.name,
        result.mode.name(),
        result.asset_index.count(),
        @tagName(result.config.renderer),
        scene,
    }) catch return;
    writeOut(io, line);
    if (result.scene_data) |s| {
        var entity_buf: [64]u8 = undefined;
        const entity_line = std.fmt.bufPrint(&entity_buf, "Scene entities: {d}\n", .{s.count()}) catch return;
        writeOut(io, entity_line);
    }
    if (result.mode == .validate) {
        writeOut(io, "Project is valid and compatible.\n");
    }
}

fn usageMessage(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.UnknownArgument => "error: unknown argument\n",
        error.MissingValue => "error: missing value for argument\n",
        error.MissingProject => "error: --project is required (except with --help/--version)\n",
        error.DuplicateArgument => "error: duplicate argument\n",
        error.InvalidMode => "error: invalid --mode (expected editor, runtime or validate)\n",
        error.InvalidLogLevel => "error: invalid --log-level (expected error, warn, info or debug)\n",
        error.InvalidJobs => "error: invalid --jobs (expected a positive integer)\n",
    };
}

fn writeOut(io: Io, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: Io, bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}
