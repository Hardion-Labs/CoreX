//! Benchmark for render **extraction** with and without the software occlusion
//! pass: `corex.render.draw.RenderFrame.refillWithOcclusion`.
//!
//! The scene is the shape the pass exists for — a handful of large near walls and
//! many small objects queued behind them. Without occlusion every one of those
//! objects becomes a `DrawCommand` and is then rasterized, shaded and depth-tested
//! per pixel; with it they never reach the backend.
//!
//! Method: `ReleaseFast`, best of five, monotonic clock, the draw list refilled into
//! a reused `RenderFrame` (so neither configuration pays for the buffers after the
//! warm-up). Invoked manually:
//!
//!   zig build bench-extract -Doptimize=ReleaseFast
//!
//! Not part of CI; the numbers in `docs/render-extraction.md` come from here.
const std = @import("std");
const corex = @import("corex");

const D = corex.render.draw;
const culling = corex.render.culling;

/// Entities: `walls` large slabs plus `hidden` small boxes behind them.
const wall_count = 8;
const hidden_per_wall = 250;

const Scene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.components.Transform, "transform"),
    corex.scene.Component(D.Renderable, "renderable"),
});

fn monotonicNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn buildScene(gpa: std.mem.Allocator) !Scene {
    var s = try Scene.init(gpa, "bench");
    errdefer s.deinit();
    // Walls at increasing distance, each covering a slice of the view. The camera
    // sits at z = 10 looking down -Z, so nearer means a larger z.
    for (0..wall_count) |i| {
        const e = try s.createEntity(null, null);
        const z = 2.0 - @as(f32, @floatFromInt(i)) * 1.5;
        try s.addComponent(e, corex.scene.components.Transform{ .position = .{ 0, 0, z } });
        try s.addComponent(e, D.Renderable{
            .mesh = 1,
            .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 2.5, 2.5, 0.05 } },
        });
        // Small objects spread behind the wall, inside its silhouette.
        for (0..hidden_per_wall) |j| {
            const h = try s.createEntity(null, null);
            const fx: f32 = @as(f32, @floatFromInt(j % 10)) / 40.0 - 0.125;
            const fy: f32 = @as(f32, @floatFromInt(j / 10)) / 40.0 - 0.125;
            try s.addComponent(h, corex.scene.components.Transform{ .position = .{ fx, fy, z - 0.6 } });
            try s.addComponent(h, D.Renderable{
                .mesh = 2,
                .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 0.02, 0.02, 0.02 } },
            });
        }
    }
    return s;
}

const Run = struct { ns: i128, commands: usize, occlusion_culled: usize };

fn run(fr: *D.RenderFrame, scene: *Scene, cam: D.Camera, config: ?D.Occlusion) !Run {
    const t0 = monotonicNs();
    const r = try fr.refillWithOcclusion(scene, cam, .front_to_back, config);
    const ns = monotonicNs() - t0;
    return .{ .ns = ns, .commands = fr.count(), .occlusion_culled = r.occlusion_culled };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var scene = try buildScene(gpa);
    defer scene.deinit();

    var fr = try D.RenderFrame.init(gpa);
    defer fr.deinit();
    const cam = corex.render.camera.Camera.perspectiveLookAt(
        .{ 0, 0, 10 },
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        std.math.pi / 3.0,
        16.0 / 9.0,
        0.5,
        200,
    );

    for ([_]struct { name: []const u8, config: ?D.Occlusion }{
        .{ .name = "frustum only", .config = null },
        .{ .name = "occlusion   ", .config = .{} },
        .{ .name = "occl 128x72 ", .config = .{ .tiles_x = 128, .tiles_y = 72 } },
        .{ .name = "occl 32x18  ", .config = .{ .tiles_x = 32, .tiles_y = 18 } },
    }) |mode| {
        // Warm-up: grows the draw list, the queues and the arena once.
        _ = try run(&fr, &scene, cam, mode.config);
        _ = try run(&fr, &scene, cam, mode.config);
        var best: i128 = std.math.maxInt(i128);
        var last: Run = undefined;
        for (0..5) |_| {
            const r = try run(&fr, &scene, cam, mode.config);
            best = @min(best, r.ns);
            last = r;
        }
        std.debug.print(
            "{s}  refill={d:.3}ms  commands={d}  occlusion_culled={d}  (occluders={d})\n",
            .{
                mode.name,
                @as(f64, @floatFromInt(best)) / 1e6,
                last.commands,
                last.occlusion_culled,
                wall_count,
            },
        );
    }
    // The per-frame cost is only half the story: the draw list is also what the
    // backend iterates, so one number for how much work the pass removes.
    std.debug.print("scene entities={d} (walls={d}, hidden={d})\n", .{
        wall_count * (1 + hidden_per_wall),
        wall_count,
        wall_count * hidden_per_wall,
    });
    _ = culling;
}
