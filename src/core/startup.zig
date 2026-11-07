//! Startup pipeline — the documented project-open sequence.
//!
//! See `docs/launch-contract.md`. Given launch options, the pipeline runs:
//!   1. Initialize essential services (jobs, diagnostics).
//!   2. Open the splash screen.
//!   3. Validate the manifest and engine compatibility.
//!   4. Load configuration in workers.
//!   5. Index assets (concurrently with configuration).
//!   6. Prepare the initial scene (skipped in `validate` mode).
//!   7. Open the editor / prepare the runtime (skipped in `validate` mode),
//!      including selecting the renderer backend for the configured tier.
//!
//! The engine never depends on the CoreXHub. `--hub-launch` only affects an
//! informational log line.

const std = @import("std");
const cli = @import("cli.zig");
const version = @import("version.zig");
const manifest = @import("manifest.zig");
const paths = @import("paths.zig");
const jobs = @import("jobs.zig");
const config = @import("config.zig");
const assets = @import("assets.zig");
const splash_mod = @import("splash.zig");
const diagnostics = @import("diagnostics.zig");
const scene_mod = @import("../scene.zig");
const render_mod = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.startup);

/// Maximum accepted `.corex` manifest size (1 MiB).
pub const max_manifest_bytes = 1024 * 1024;

pub const StartupError = error{
    InvalidManifest,
    IncompatibleVersion,
    ProjectNotFound,
    PreparationFailed,
    OutOfMemory,
    Internal,
};

/// Map a startup error to the stable process exit code (docs/launch-contract.md).
pub fn exitCode(err: StartupError) u8 {
    return switch (err) {
        error.InvalidManifest => 3,
        error.IncompatibleVersion => 4,
        error.ProjectNotFound => 5,
        error.PreparationFailed => 6,
        error.OutOfMemory, error.Internal => 1,
    };
}

/// A resolved initial-scene request. `path` is project-relative and borrowed
/// from the manifest or launch options; it is valid while those live.
pub const SceneRequest = struct {
    path: []const u8,
    exists: bool,
};

/// Prepared project state returned by a successful startup. Owns the manifest
/// and asset index; call `deinit` to release them.
pub const StartupResult = struct {
    manifest: manifest.Manifest,
    config: config.ProjectConfig,
    asset_index: assets.AssetIndex,
    scene: ?SceneRequest,
    /// Loaded initial scene for `editor`/`runtime`. Null in `validate` mode.
    /// When no initial scene is requested, this is an empty scene.
    scene_data: ?scene_mod.EngineRenderScene,
    mode: cli.Mode,
    /// The renderer tier the project asked for, mapped onto the render contract.
    /// `null` in `validate` mode, which prepares no session.
    render_tier: ?render_mod.Tier,
    /// Absolute project directory, owned here. Asset paths in `asset_index` are
    /// relative to it, so a caller that loads assets needs it after startup.
    project_root: []u8,
    /// The allocator `project_root` was allocated with.
    project_root_allocator: Allocator,

    pub fn deinit(self: *StartupResult) void {
        if (self.scene_data) |*s| s.deinit();
        self.project_root_allocator.free(self.project_root);
        self.manifest.deinit();
        self.asset_index.deinit();
        self.* = undefined;
    }
};

/// Run the startup pipeline. The splash is opened after services are ready and
/// closed on every exit path. On success, the caller owns the returned result.
pub fn run(
    gpa: Allocator,
    io: Io,
    opts: cli.LaunchOptions,
    splash: splash_mod.SplashScreen,
) StartupError!StartupResult {
    const total = diagnostics.Timer.start(io);
    var profiler = diagnostics.Profiler.init(gpa, io);
    defer profiler.deinit();
    var stage_timer = diagnostics.Timer.start(io);

    // Step 1: essential services.
    var js: jobs.JobSystem = undefined;
    js.init(gpa, opts.jobs);
    defer js.deinit();
    log.debug("services initialized ({d} workers)", .{js.worker_count});

    const project_path = opts.project_path orelse return error.Internal;
    const abs_path = paths.resolveAbsolute(gpa, io, project_path) catch return error.ProjectNotFound;
    defer gpa.free(abs_path);
    const project_root = std.fs.path.dirname(abs_path) orelse return error.InvalidManifest;
    const project_root_owned = gpa.dupe(u8, project_root) catch return error.OutOfMemory;
    errdefer gpa.free(project_root_owned);

    // Step 2: splash screen.
    splash.show(std.fs.path.basename(abs_path));
    defer splash.hide();
    splash.setProgress("initializing services", 0.1);

    // Informational: the version the Hub selected (never acted upon).
    if (opts.hub_launch) log.info("launched via CoreXHub", .{});
    if (opts.hub_engine_version) |hv| {
        if (version.Version.parse(hv)) |selected| {
            var a: [64]u8 = undefined;
            var b: [64]u8 = undefined;
            if (selected.order(version.engine) != .eq) {
                log.warn("Hub selected engine {s}, but this binary is {s}", .{
                    version.format(selected, &a), version.format(version.engine, &b),
                });
            }
        } else |_| {
            log.warn("Hub reported an invalid engine version: {s}", .{hv});
        }
    }

    // Step 3: validate manifest and compatibility.
    splash.setProgress("validating manifest", 0.2);
    const bytes = Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .limited(max_manifest_bytes)) catch
        return error.ProjectNotFound;
    defer gpa.free(bytes);

    var man = manifest.parse(gpa, bytes) catch |err| return mapManifestError(err);
    errdefer man.deinit();

    const compat = man.compatibility(version.engine);
    if (!compat.isCompatible()) {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        // Warn (not err): this is an expected, handled rejection. The caller
        // receives error.IncompatibleVersion and maps it to exit code 4.
        log.warn("project \"{s}\" targets engine {s}; running {s} ({s})", .{
            man.name,
            version.format(man.engine_version, &a),
            version.format(version.engine, &b),
            compat.describe(),
        });
        return error.IncompatibleVersion;
    }
    profiler.record("manifest", stage_timer.elapsedNanoseconds());
    stage_timer.restart();
    splash.setProgress("manifest validated", 0.35);

    // Steps 4 & 5: load configuration and index assets concurrently in workers.
    splash.setProgress("loading configuration and indexing assets", 0.45);
    var assets_future = js.spawn(assets.indexDirectories, .{ gpa, js.io(), project_root, man.asset_directories });
    var config_future = js.spawn(config.load, .{ gpa, js.io(), project_root });

    // Await both jobs so neither is left running. `config.load` returns a value
    // type (no heap ownership), so discarding it on the assets-error path is
    // leak-free; the asset index owns memory and is cleaned via errdefer.
    const assets_result = assets_future.await(js.io());
    const config_result = config_future.await(js.io());

    var index = assets_result catch |err| return mapAssetsError(err);
    errdefer index.deinit();
    const cfg = config_result catch |err| return mapConfigError(err);
    profiler.record("config+assets", stage_timer.elapsedNanoseconds());
    stage_timer.restart();
    splash.setProgress("configuration loaded and assets indexed", 0.7);
    log.info("indexed {d} assets ({d} bytes)", .{ index.count(), index.totalBytes() });

    // Step 6: prepare and load the initial scene.
    var scene_data: ?scene_mod.EngineRenderScene = null;
    errdefer {
        if (scene_data) |*s| s.deinit();
    }
    var scene_req: ?SceneRequest = null;
    if (opts.mode != .validate) {
        splash.setProgress("preparing initial scene", 0.8);
        scene_req = try prepareScene(io, project_root, man.initial_scene, opts.scene_override);
        if (scene_req) |req| {
            var dir = Io.Dir.openDirAbsolute(io, project_root, .{}) catch return error.PreparationFailed;
            defer dir.close(io);
            // Loaded with the renderable schema: a scene may author `renderable`
            // and `camera`, and the serializer rejects components the schema does
            // not declare. `EngineScene` (transform only) is still the schema for
            // documents that carry nothing else.
            scene_data = scene_mod.EngineRenderScene.load(gpa, io, dir, req.path) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                log.warn("failed to load scene \"{s}\": {s}", .{ req.path, @errorName(err) });
                return error.PreparationFailed;
            };
            log.info("scene \"{s}\" loaded ({d} entities)", .{ scene_data.?.name, scene_data.?.count() });
        } else {
            scene_data = scene_mod.EngineRenderScene.init(gpa, "empty") catch return error.OutOfMemory;
        }
        profiler.record("scene", stage_timer.elapsedNanoseconds());
        stage_timer.restart();
    }

    // Step 7: open the editor / prepare the runtime.
    var render_tier: ?render_mod.Tier = null;
    if (opts.mode != .validate) {
        splash.setProgress("selecting renderer", 0.9);
        // The tier comes from `settings.json`; a project may name a tier no
        // backend implements yet (Advanced), which is a configuration error
        // reported here rather than a session that silently renders at a lower
        // quality.
        const tier = render_mod.tierFromConfig(cfg.renderer);
        render_tier = tier;
        if (render_mod.backendFor(tier, gpa) == null) {
            // Warn, not err: this is an expected, handled rejection of a project
            // configuration (like an incompatible version), reported to the
            // caller as `error.PreparationFailed` and exit code 6.
            log.warn("renderer tier \"{s}\" has no backend in this build", .{@tagName(cfg.renderer)});
            return error.PreparationFailed;
        }
        log.info("renderer tier: {s}", .{@tagName(cfg.renderer)});

        splash.setProgress("opening editor", 0.95);
        // The graphical editor and GUI library are planned subsystems; until
        // they exist the session is opened headless and readiness is reported.
        log.info("{s} session ready (headless)", .{opts.mode.name()});
        profiler.record("editor", stage_timer.elapsedNanoseconds());
    }

    log.info("startup completed in {d:.1} ms", .{total.elapsedMilliseconds()});
    return .{
        .manifest = man,
        .config = cfg,
        .asset_index = index,
        .scene = scene_req,
        .scene_data = scene_data,
        .mode = opts.mode,
        .render_tier = render_tier,
        .project_root = project_root_owned,
        .project_root_allocator = gpa,
    };
}

fn prepareScene(
    io: Io,
    project_root: []const u8,
    initial_scene: ?[]const u8,
    override: ?[]const u8,
) StartupError!?SceneRequest {
    const rel = override orelse initial_scene orelse return null;
    paths.validateRelative(rel) catch return error.PreparationFailed;

    var dir = Io.Dir.openDirAbsolute(io, project_root, .{}) catch return error.PreparationFailed;
    defer dir.close(io);
    dir.access(io, rel, .{}) catch return error.PreparationFailed;
    return .{ .path = rel, .exists = true };
}

fn mapManifestError(err: manifest.ParseError) StartupError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidManifest,
    };
}

fn mapConfigError(err: config.LoadError) StartupError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PreparationFailed,
    };
}

fn mapAssetsError(err: assets.IndexError) StartupError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PreparationFailed,
    };
}

/// Silence engine log output for the duration of a test that intentionally
/// drives the pipeline down an expected failure path. The Zig test runner
/// prints captured stderr (together with a stale "failed command" line) even
/// when every test passes, which makes a green suite look broken. The
/// warnings still fire in the real engine; they are just noise on a passing
/// test run.
fn suppressEngineLogs() std.log.Level {
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    return prev;
}

// --- tests -----------------------------------------------------------------

const TestProject = struct {
    tmp: std.testing.TmpDir,
    root: [Io.Dir.max_path_bytes]u8,
    root_len: usize,

    fn init() !TestProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var self = TestProject{ .tmp = tmp, .root = undefined, .root_len = 0 };
        self.root_len = try tmp.dir.realPath(std.testing.io, &self.root);
        return self;
    }

    fn deinit(self: *TestProject) void {
        self.tmp.cleanup();
    }

    fn rootPath(self: *const TestProject) []const u8 {
        return self.root[0..self.root_len];
    }

    fn write(self: *TestProject, sub: []const u8, data: []const u8) !void {
        // Ensure parent directories exist.
        if (std.fs.path.dirname(sub)) |parent| {
            if (parent.len > 0) try self.tmp.dir.createDirPath(std.testing.io, parent);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = data });
    }

    fn manifestPath(self: *TestProject, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/Game.corex", .{self.rootPath()});
    }
};

const minimal_manifest =
    \\{ "format_version": 1, "name": "TestGame", "engine_version": "0.1.0" }
;

const empty_scene =
    \\{ "format_version": 1, "name": "main", "entities": [] }
;

test "startup: validate mode succeeds on a minimal project" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .validate, .project_path = mpath, .headless = true };

    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();

    try std.testing.expectEqualStrings("TestGame", result.manifest.name);
    try std.testing.expect(result.scene == null);
    try std.testing.expect(result.scene_data == null);
    try std.testing.expect(!splash.is_open);
}

test "startup: editor mode prepares scene and indexes assets" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex",
        \\{ "format_version": 1, "name": "TestGame", "engine_version": "0.1.0", "initial_scene": "scenes/main.scene" }
    );
    try proj.write("scenes/main.scene", empty_scene);
    try proj.write("assets/tex/hero.png", "png");
    try proj.write("settings.json", "{ \"window_width\": 800 }");

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath, .headless = true };

    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 800), result.config.window_width);
    try std.testing.expectEqual(@as(usize, 1), result.asset_index.countByKind(.texture));
    try std.testing.expectEqualStrings("scenes/main.scene", result.scene.?.path);
    try std.testing.expect(result.scene_data != null);
    try std.testing.expectEqual(@as(usize, 0), result.scene_data.?.count());
    try std.testing.expect(!splash.is_open);
}

test "startup: missing project file -> ProjectNotFound" {
    var proj = try TestProject.init();
    defer proj.deinit();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .validate, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.ProjectNotFound, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
    try std.testing.expect(!splash.is_open);
}

test "startup: invalid manifest -> InvalidManifest" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", "{ not valid json");
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .validate, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.InvalidManifest, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
}

test "startup: incompatible version -> IncompatibleVersion" {
    const prev_log_level = suppressEngineLogs();
    defer std.testing.log_level = prev_log_level;

    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex",
        \\{ "format_version": 1, "name": "FutureGame", "engine_version": "0.99.0" }
    );
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .validate, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.IncompatibleVersion, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
}

test "startup: missing referenced scene -> PreparationFailed" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex",
        \\{ "format_version": 1, "name": "TestGame", "engine_version": "0.1.0", "initial_scene": "scenes/missing.scene" }
    );
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.PreparationFailed, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
}

test "startup: scene override is used" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);
    try proj.write("scenes/other.scene", empty_scene);
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath, .scene_override = "scenes/other.scene" };
    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();
    try std.testing.expectEqualStrings("scenes/other.scene", result.scene.?.path);
}

test "startup: editor without initial scene prepares an empty scene" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath, .headless = true };
    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();

    try std.testing.expect(result.scene == null);
    try std.testing.expect(result.scene_data != null);
    try std.testing.expectEqual(@as(usize, 0), result.scene_data.?.count());
}

test "startup: invalid scene content -> PreparationFailed" {
    const prev_log_level = suppressEngineLogs();
    defer std.testing.log_level = prev_log_level;

    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex",
        \\{ "format_version": 1, "name": "TestGame", "engine_version": "0.1.0", "initial_scene": "scenes/bad.scene" }
    );
    try proj.write("scenes/bad.scene", "{ not valid json");

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.PreparationFailed, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
    try std.testing.expect(!splash.is_open);
}

test "startup: editor loads scene entities and components" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex",
        \\{ "format_version": 1, "name": "TestGame", "engine_version": "0.1.0", "initial_scene": "scenes/main.scene" }
    );
    try proj.write("scenes/main.scene",
        \\{ "format_version": 1, "name": "main", "entities": [
        \\  { "id": 1, "name": "Root", "components": { "transform": { "position": [1, 2, 3] } } },
        \\  { "id": 2, "name": "Child", "parent": 1 }
        \\] }
    );

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .runtime, .project_path = mpath, .headless = true };
    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();

    var s = &result.scene_data.?;
    try std.testing.expectEqual(@as(usize, 2), s.count());
    const root = s.entityById(1).?;
    const child = s.entityById(2).?;
    try std.testing.expect(s.parent(child).?.eql(root));
    try std.testing.expectEqual(@as(f32, 1), s.getComponent(scene_mod.Transform, root).?.position[0]);
}

test "startup: the session selects the renderer tier from settings.json" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);
    try proj.write("settings.json",
        \\{ "renderer": "low", "window_width": 800, "window_height": 600 }
    );

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .editor, .project_path = mpath, .headless = true };
    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();

    try std.testing.expectEqual(config.RendererTier.low, result.config.renderer);
    // The contract tier, not the config enum: low is implemented by the CPU
    // driver, through the capability gate.
    try std.testing.expectEqual(render_mod.Tier.low, result.render_tier.?);
}

test "startup: a tier with no backend fails instead of rendering lower" {
    const prev_log_level = suppressEngineLogs();
    defer std.testing.log_level = prev_log_level;

    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);
    try proj.write("settings.json",
        \\{ "renderer": "advanced" }
    );

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .runtime, .project_path = mpath, .headless = true };
    var splash = splash_mod.HeadlessSplash{};
    try std.testing.expectError(error.PreparationFailed, run(std.testing.allocator, std.testing.io, opts, splash.interface()));
    // The splash is closed on the failure path, like every other stage.
    try std.testing.expect(!splash.is_open);
}

test "startup: validate mode selects no renderer tier" {
    var proj = try TestProject.init();
    defer proj.deinit();
    try proj.write("Game.corex", minimal_manifest);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const mpath = try proj.manifestPath(&path_buf);
    const opts = cli.LaunchOptions{ .mode = .validate, .project_path = mpath };
    var splash = splash_mod.HeadlessSplash{};
    var result = try run(std.testing.allocator, std.testing.io, opts, splash.interface());
    defer result.deinit();
    // Validation prepares no session, so no backend is selected — and an
    // `advanced` project still validates, because nothing is rendered.
    try std.testing.expect(result.render_tier == null);
}

test "exitCode mapping is stable" {
    try std.testing.expectEqual(@as(u8, 3), exitCode(error.InvalidManifest));
    try std.testing.expectEqual(@as(u8, 4), exitCode(error.IncompatibleVersion));
    try std.testing.expectEqual(@as(u8, 5), exitCode(error.ProjectNotFound));
    try std.testing.expectEqual(@as(u8, 6), exitCode(error.PreparationFailed));
    try std.testing.expectEqual(@as(u8, 1), exitCode(error.Internal));
}
