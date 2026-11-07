//! Renders one editor frame of a real project and writes it as a QOI file.
//!
//! This is the editor shell's smoke test and its visual reference: it runs the
//! documented startup pipeline to prepare a session, loads the project's render
//! assets, renders one frame of the scene through the engine's own renderer, and
//! paints the editor around it with `corex.editor.shell` — hierarchy, viewport,
//! inspector and status bar — into a headless surface.
//!
//!   zig build editor-frame -- <project.corex> [out.qoi] [selected-id]
//!
//! Nothing here is a mock of the editor: it is the same `draw` call a windowed shell
//! will make, driven by a synthetic input frame. The parts that genuinely do not
//! exist yet — a window, a swapchain, real input — are exactly the parts this tool
//! does not pretend to have.
const std = @import("std");
const corex = @import("corex");

const cli = corex.core.cli;
const startup = corex.core.startup;
const splash = corex.core.splash;
const shell = corex.editor.shell;
const edit = corex.editor.edit;
const gui = corex.gui;
const render_scene = corex.scene.render_scene;

const width: u32 = 640;
const height: u32 = 360;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.debug.print("editor-frame: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| try args_list.append(gpa, arg);
    const args = args_list.items;
    if (args.len == 0) {
        std.debug.print("usage: editor-frame <project.corex> [out.qoi] [selected-id] [dirty]\n", .{});
        return error.MissingProject;
    }
    const out_path = if (args.len > 1) args[1] else "editor-frame.qoi";

    // The documented startup path, so the editor shows what a real session holds.
    // `--project` is passed explicitly: the launcher's contract is a flag, not a
    // positional argument, and inventing a second form here would be a second
    // contract to keep in sync.
    var opts = try cli.parse(&.{ "--project", args[0] });
    opts.mode = .editor;
    opts.frames = 1;
    var headless_splash = splash.HeadlessSplash{};
    var result = try startup.run(gpa, io, opts, headless_splash.interface());
    defer result.deinit();
    const scene: ?*render_scene.EngineRenderScene = if (result.scene_data) |*s| s else null;

    var dockest = shell.State{};
    if (args.len > 2) {
        dockest.selected = std.fmt.parseInt(u64, args[2], 10) catch 0;
    }

    // The rendered frame: one surface, cleared and rendered once, exactly as the
    // runtime loop does it. When the project has no scene or camera the viewport
    // shows a cleared surface instead of a stale one.
    const scene_color: []u8 = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(scene_color);
    const scene_depth: []f32 = try gpa.alloc(f32, width * height);
    defer gpa.free(scene_depth);
    @memset(scene_color, 0);
    @memset(scene_depth, 1.0);

    // A project may legitimately have no scene (an empty project, or a scene that
    // failed to load); the editor still has to paint, so it gets an empty one.
    var owned_scene: ?render_scene.EngineRenderScene = null;
    defer if (owned_scene) |*s| s.deinit();
    const shown: *render_scene.EngineRenderScene = scene orelse blk: {
        owned_scene = try render_scene.EngineRenderScene.init(gpa, "empty");
        break :blk &owned_scene.?;
    };

    var report = render_scene.EngineFrameReport{};
    // Assets are loaded from the project the startup pipeline prepared. A project
    // whose assets cannot be loaded still gets an editor, with an empty viewport and
    // the reason on stderr — refusing to open the project would be worse.
    if (render_scene.loadAssets(
        gpa,
        io,
        result.project_root,
        result.asset_index,
        .{ .capacity = 64, .vertices_per_slot = 65536, .indices_per_slot = 98304 },
    )) |assets_value| {
        var assets = assets_value;
        defer assets.deinit();
        var target = try corex.render.Target.init(width, height, scene_color, scene_depth);
        target.clear(.{ 0x0b, 0x0c, 0x10, 0xff }, 1.0);
        if (try render_scene.EngineRenderer.findCamera(shown, gpa)) |found| {
            var engine = try render_scene.EngineRenderer.init(gpa, result.render_tier.?);
            defer engine.deinit();
            _ = try engine.render(
                corex.render.BackendSurface.of(&target),
                shown,
                found.component,
                found.camera,
                assets.table.resources(true),
                .{},
            );
            report = engine.last;
        } else {
            std.debug.print("editor-frame: scene has no camera; viewport stays empty\n", .{});
        }
    } else |err| {
        std.debug.print("editor-frame: assets unavailable ({s}), rendering empty\n", .{@errorName(err)});
    }

    const pixels = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(pixels);
    const canvas = try gui.canvas.Canvas.init(width, height, pixels);
    canvas.clear(.{ 0x1e, 0x1f, 0x24, 0xff });

    // The editing model rides along even though this tool does not edit: the shell
    // paints the save marker and the undo depth from it, so the image shows the status
    // bar a real session shows rather than a second, imaginary variant.
    var history = edit.History(render_scene.EngineRenderScene).init(gpa);
    defer history.deinit();
    if (args.len > 3) history.dirty = std.mem.eql(u8, args[3], "dirty");

    var entries: [128]gui.widgets.Entry = @splat(undefined);
    var next: [128]gui.widgets.Entry = @splat(undefined);
    var ctx = gui.widgets.Context.init(canvas, dockest.theme, .{}, &entries, &next);

    const frame = shell.Frame{
        .scene_pixels = scene_color,
        .scene_width = width,
        .scene_height = height,
        .report = report,
        .project_name = result.manifest.name,
        .scene_name = shown.name,
    };

    // Hit-testing resolves against the previous frame, so the widget the pointer is
    // over is only known one frame later. Two passes put the pointer (over the
    // first hierarchy row) in its hover state for the image.
    const frame_input: gui.input.Input = .{
        .pointer = .{ .x = 20, .y = 40 },
        .pointer_in_window = true,
    };
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        ctx.beginFrame(frame_input);
        _ = shell.draw(&ctx, &dockest, shown, &history, frame);
        ctx.endFrame();
    }

    const image = corex.assets.image.Image{ .width = width, .height = height, .pixels = pixels };
    const encoded = try corex.assets.image.encodeQoi(gpa, image);
    defer gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = encoded });

    std.debug.print("editor-frame: {d}x{d}, {d} entities, {d} widgets, {d} bytes -> {s}\n", .{
        width, height, shown.count(), ctx.entry_count, encoded.len, out_path,
    });
}
