//! Launch argument parsing — the stable CoreXEngine startup contract.
//!
//! See `docs/launch-contract.md`. The engine accepts the same arguments whether
//! launched directly or by the CoreXHub. `--hub-launch` is an informational
//! origin marker only; it never creates a dependency on the Hub.

const std = @import("std");
const version = @import("version.zig");

pub const Mode = enum {
    editor,
    runtime,
    validate,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "editor")) return .editor;
        if (std.mem.eql(u8, s, "runtime")) return .runtime;
        if (std.mem.eql(u8, s, "validate")) return .validate;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .editor => "editor",
            .runtime => "runtime",
            .validate => "validate",
        };
    }
};

pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,

    pub fn fromString(s: []const u8) ?LogLevel {
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        return null;
    }
};

/// Parsed launch options. String fields borrow from the argument slice passed
/// to `parse`; the caller must keep that slice alive while using the options.
pub const LaunchOptions = struct {
    mode: Mode = .editor,
    project_path: ?[]const u8 = null,
    hub_launch: bool = false,
    hub_engine_version: ?[]const u8 = null,
    scene_override: ?[]const u8 = null,
    headless: bool = false,
    /// How many frames a session renders before exiting. `null` keeps the documented
    /// default: one frame, then exit. There is no window to close yet, so a loop must
    /// be bounded by the caller.
    frames: ?usize = null,
    /// null means "choose automatically" (logical cores minus one, min 1).
    jobs: ?usize = null,
    log_level: LogLevel = .info,
    show_help: bool = false,
    show_version: bool = false,
};

pub const ParseError = error{
    UnknownArgument,
    MissingValue,
    MissingProject,
    DuplicateArgument,
    InvalidMode,
    InvalidLogLevel,
    InvalidJobs,
    InvalidFrames,
};

/// Parse launch arguments (excluding argv[0]).
pub fn parse(args: []const []const u8) ParseError!LaunchOptions {
    var opts = LaunchOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "--help") or eq(arg, "-h")) {
            opts.show_help = true;
        } else if (eq(arg, "--version") or eq(arg, "-v")) {
            opts.show_version = true;
        } else if (eq(arg, "--hub-launch")) {
            opts.hub_launch = true;
        } else if (eq(arg, "--headless")) {
            opts.headless = true;
        } else if (eq(arg, "--project") or eq(arg, "-p")) {
            if (opts.project_path != null) return error.DuplicateArgument;
            opts.project_path = try nextValue(args, &i);
        } else if (eq(arg, "--engine-version")) {
            if (opts.hub_engine_version != null) return error.DuplicateArgument;
            opts.hub_engine_version = try nextValue(args, &i);
        } else if (eq(arg, "--mode") or eq(arg, "-m")) {
            const value = try nextValue(args, &i);
            opts.mode = Mode.fromString(value) orelse return error.InvalidMode;
        } else if (eq(arg, "--scene")) {
            if (opts.scene_override != null) return error.DuplicateArgument;
            opts.scene_override = try nextValue(args, &i);
        } else if (eq(arg, "--frames")) {
            if (opts.frames != null) return error.DuplicateArgument;
            const value = try nextValue(args, &i);
            const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidFrames;
            if (n == 0) return error.InvalidFrames;
            opts.frames = n;
        } else if (eq(arg, "--jobs")) {
            const value = try nextValue(args, &i);
            const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidJobs;
            if (n == 0) return error.InvalidJobs;
            opts.jobs = n;
        } else if (eq(arg, "--log-level")) {
            const value = try nextValue(args, &i);
            opts.log_level = LogLevel.fromString(value) orelse return error.InvalidLogLevel;
        } else {
            return error.UnknownArgument;
        }
    }

    // Every non-help/non-version invocation needs a project. An empty argument
    // list is handled by the caller (it prints help).
    if (args.len > 0 and !opts.show_help and !opts.show_version and opts.project_path == null) {
        return error.MissingProject;
    }
    return opts;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

pub const help_text =
    \\CoreXEngine — modular game engine in Zig
    \\
    \\Usage:
    \\  corex-engine --project <path.corex> [options]
    \\
    \\Options:
    \\  -p, --project <path>       Project entry point (.corex file). Required.
    \\      --hub-launch           Informational: launched by CoreXHub.
    \\      --engine-version <v>   Informational: engine version selected by the Hub.
    \\  -m, --mode <mode>          editor (default) | runtime | validate
    \\      --scene <path>         Override the initial scene (project-relative).
    \\      --headless             Run without a graphical window.
    \\      --frames <n>           Render n frames before exiting (default: 1).
    \\      --jobs <n>             Worker count for the job system (default: auto).
    \\      --log-level <level>    error | warn | info (default) | debug
    \\  -v, --version              Print the engine version and exit.
    \\  -h, --help                 Print this help and exit.
    \\
    \\The engine never depends on the CoreXHub to run.
    \\See docs/launch-contract.md for the stable startup contract.
    \\
;

test "parse: defaults" {
    const opts = try parse(&.{ "--project", "game.corex" });
    try std.testing.expectEqual(Mode.editor, opts.mode);
    try std.testing.expectEqualStrings("game.corex", opts.project_path.?);
    try std.testing.expect(!opts.hub_launch);
    try std.testing.expect(!opts.headless);
    try std.testing.expect(opts.jobs == null);
    try std.testing.expectEqual(LogLevel.info, opts.log_level);
}

test "parse: hub launch with all options" {
    const opts = try parse(&.{
        "--project",           "/games/MyGame/MyGame.corex",
        "--hub-launch",        "--engine-version",
        "0.1.0",               "--mode",
        "runtime",             "--scene",
        "scenes/level1.scene", "--headless",
        "--jobs",              "4",
        "--log-level",         "debug",
    });
    try std.testing.expectEqualStrings("/games/MyGame/MyGame.corex", opts.project_path.?);
    try std.testing.expect(opts.hub_launch);
    try std.testing.expectEqualStrings("0.1.0", opts.hub_engine_version.?);
    try std.testing.expectEqual(Mode.runtime, opts.mode);
    try std.testing.expectEqualStrings("scenes/level1.scene", opts.scene_override.?);
    try std.testing.expect(opts.headless);
    try std.testing.expectEqual(@as(usize, 4), opts.jobs.?);
    try std.testing.expectEqual(LogLevel.debug, opts.log_level);
}

test "parse: short flags" {
    const opts = try parse(&.{ "-p", "g.corex", "-m", "validate" });
    try std.testing.expectEqualStrings("g.corex", opts.project_path.?);
    try std.testing.expectEqual(Mode.validate, opts.mode);
}

test "parse: help and version short-circuit project requirement" {
    const h = try parse(&.{"--help"});
    try std.testing.expect(h.show_help);
    const v = try parse(&.{"-v"});
    try std.testing.expect(v.show_version);
}

test "parse: empty args yields defaults (caller prints help)" {
    const opts = try parse(&.{});
    try std.testing.expect(opts.project_path == null);
    try std.testing.expect(!opts.show_help);
}

test "parse: unknown argument" {
    try std.testing.expectError(error.UnknownArgument, parse(&.{"--bogus"}));
}

test "parse: missing value" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--project"}));
}

test "parse: missing project" {
    try std.testing.expectError(error.MissingProject, parse(&.{"--headless"}));
}

test "parse: duplicate project" {
    try std.testing.expectError(error.DuplicateArgument, parse(&.{ "--project", "a.corex", "--project", "b.corex" }));
}

test "parse: invalid mode" {
    try std.testing.expectError(error.InvalidMode, parse(&.{ "--project", "a.corex", "--mode", "bogus" }));
}

test "parse: invalid log level" {
    try std.testing.expectError(error.InvalidLogLevel, parse(&.{ "--project", "a.corex", "--log-level", "loud" }));
}

test "parse: --frames bounds the run and must be positive" {
    const opts = try parse(&.{ "--project", "game.corex", "--frames", "12" });
    try std.testing.expectEqual(@as(?usize, 12), opts.frames);
    // Absent means the documented default of one frame, expressed as null.
    try std.testing.expectEqual(@as(?usize, null), (try parse(&.{ "--project", "game.corex" })).frames);
    try std.testing.expectError(error.InvalidFrames, parse(&.{ "--project", "a.corex", "--frames", "0" }));
    try std.testing.expectError(error.InvalidFrames, parse(&.{ "--project", "a.corex", "--frames", "many" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "--project", "a.corex", "--frames" }));
    try std.testing.expectError(error.DuplicateArgument, parse(&.{ "--project", "a.corex", "--frames", "1", "--frames", "2" }));
}

test "parse: invalid jobs" {
    try std.testing.expectError(error.InvalidJobs, parse(&.{ "--project", "a.corex", "--jobs", "0" }));
    try std.testing.expectError(error.InvalidJobs, parse(&.{ "--project", "a.corex", "--jobs", "abc" }));
}

test "version metadata reachable from cli" {
    try std.testing.expectEqualStrings("0.17.0", version.zig_version);
}
