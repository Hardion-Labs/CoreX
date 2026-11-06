//! Benchmark for the software rasterizer: flat vs textured shading, the cost of
//! alpha compositing against an opaque write, and the cost of antialiasing.
//! Method: ReleaseFast, best of five runs, 1024 quads (2048 triangles) tiled
//! across the target (full coverage, integer tile counts). Invoked manually:
//!
//!   zig build bench -Doptimize=ReleaseFast
//!
//! Not part of CI; numbers in docs/render-raster.md come from this harness.
const std = @import("std");
const corex = @import("corex");

const R = corex.render;

const grid = 32;
const quad_count = grid * grid; // 1024
const tile: f32 = 2.0 / @as(f32, @floatFromInt(grid));

const positions = [_][3]f32{
    .{ -tile / 2, -tile / 2, 0 }, .{ tile / 2, -tile / 2, 0 },
    .{ tile / 2, tile / 2, 0 },   .{ -tile / 2, tile / 2, 0 },
};
const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
const shared_mesh = R.RasterMesh{ .positions = &positions, .indices = &indices, .uvs = &uvs };
const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
// 50% alpha so the blend modes do their full arithmetic in the benchmark.
const translucent = [4]f32{ 1.0, 0.5, 0.25, 0.5 };

const AlphaResources = struct {
    pub fn mesh(self: AlphaResources, handle: u32) ?R.RasterMesh {
        _ = self;
        _ = handle;
        return shared_mesh;
    }
    pub fn color(self: AlphaResources, handle: u32) ?[4]f32 {
        _ = self;
        return if (handle == 0) translucent else null;
    }
};

// 64x64 RGBA8 gradient (per-texel variation so filtering has real work).
var texture_pixels: [64 * 64 * 4]u8 = undefined;
var tex64: R.RasterTexture = undefined;

const FlatResources = struct {
    pub fn mesh(self: FlatResources, handle: u32) ?R.RasterMesh {
        _ = self;
        _ = handle;
        return shared_mesh;
    }
    pub fn color(self: FlatResources, handle: u32) ?[4]f32 {
        _ = self;
        return if (handle == 0) white else null;
    }
};

const TexResources = struct {
    filt: R.TextureFilter,
    pub fn mesh(self: TexResources, handle: u32) ?R.RasterMesh {
        _ = self;
        _ = handle;
        return shared_mesh;
    }
    pub fn color(self: TexResources, handle: u32) ?[4]f32 {
        _ = self;
        return if (handle == 0) white else null;
    }
    pub fn texture(self: TexResources, handle: u32) ?R.RasterTexture {
        _ = handle;
        tex64.filter = self.filt;
        return tex64;
    }
};

fn commands(gpa: std.mem.Allocator) ![]R.DrawCommand {
    const cmds = try gpa.alloc(R.DrawCommand, quad_count);
    const bounds = R.Aabb.fromMinMax(.{ -2, -2, -2 }, .{ 2, 2, 2 });
    for (0..grid) |gy| for (0..grid) |gx| {
        const i = gy * grid + gx;
        var world = corex.scene.transform.identity();
        world[12] = -1.0 + tile / 2 + @as(f32, @floatFromInt(gx)) * tile;
        world[13] = -1.0 + tile / 2 + @as(f32, @floatFromInt(gy)) * tile;
        cmds[i] = .{
            .entity = .{ .index = @intCast(i + 1), .generation = 0 },
            .mesh = 0,
            .material = 0,
            .world = world,
            .bounds = bounds,
            .depth = @floatFromInt(i),
        };
    };
    return cmds;
}

fn monotonicNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const Run = struct { ns: i128, pixels: usize };

fn runOnce(gpa: std.mem.Allocator, comptime textured: bool, size: u32, filt: R.TextureFilter, blend: R.Blend, cmds: []const R.DrawCommand) !Run {
    const n = @as(usize, size) * size;
    const color = try gpa.alloc(u8, n * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, n);
    defer gpa.free(depth);
    const vp = corex.render.orthographic(-1, 1, -1, 1, 0, 2);
    var target = try R.Target.init(size, size, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const t0 = monotonicNs();
    const options = R.RasterOptions{ .blend = blend, .antialias = .none };
    // One-sample path: no allocator, no scratch, the historical measurement.
    const stats = if (comptime textured)
        try R.rasterize(&target, cmds, vp, TexResources{ .filt = filt }, options)
    else if (blend == .none)
        try R.rasterize(&target, cmds, vp, FlatResources{}, options)
    else
        try R.rasterize(&target, cmds, vp, AlphaResources{}, options);
    const ns = monotonicNs() - t0;
    return .{ .ns = ns, .pixels = stats.pixels };
}

/// Antialiased flat shade of the shifted tiles, through the public
/// `rasterizeAlloc` entry point — scratch allocation included in the measured
/// span, because that is the cost a caller pays for `.edge`.
fn runAntialiased(gpa: std.mem.Allocator, size: u32, cmds: []const R.DrawCommand) !Run {
    const n = @as(usize, size) * size;
    const color = try gpa.alloc(u8, n * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, n);
    defer gpa.free(depth);
    // Shift the projection half a pixel along +x so no tile edge lands on a pixel
    // boundary (an edge there is degenerate and would cost no coverage work).
    const dx = 1.0 / @as(f32, @floatFromInt(size));
    const vp = corex.render.orthographic(-1 - dx, 1 - dx, -1, 1, 0, 2);
    var target = try R.Target.init(size, size, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const t0 = monotonicNs();
    const stats = try R.rasterizeAlloc(gpa, &target, cmds, vp, FlatResources{}, .{ .antialias = .edge });
    const ns = monotonicNs() - t0;
    return .{ .ns = ns, .pixels = stats.pixels };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    for (0..64) |y| for (0..64) |x| {
        const o = (y * 64 + x) * 4;
        texture_pixels[o] = @intCast((x * 4 + y) % 256);
        texture_pixels[o + 1] = @intCast((y * 4 + x * 2) % 256);
        texture_pixels[o + 2] = @intCast((x + y * 3) % 256);
        texture_pixels[o + 3] = 255;
    };
    tex64 = .{ .width = 64, .height = 64, .pixels = &texture_pixels, .filter = .bilinear };

    const cmds = try commands(gpa);
    defer gpa.free(cmds);

    for ([_]u32{ 256, 512, 1024 }) |size| {
        var best_flat: i128 = std.math.maxInt(i128);
        var px: usize = 0;
        for (0..5) |_| {
            const r = try runOnce(gpa, false, size, .nearest, .none, cmds);
            px = r.pixels;
            best_flat = @min(best_flat, r.ns);
        }
        var best_bi: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_bi = @min(best_bi, (try runOnce(gpa, true, size, .bilinear, .none, cmds)).ns);
        var best_near: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_near = @min(best_near, (try runOnce(gpa, true, size, .nearest, .none, cmds)).ns);
        var best_alpha: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_alpha = @min(best_alpha, (try runOnce(gpa, false, size, .nearest, .alpha, cmds)).ns);
        var best_add: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_add = @min(best_add, (try runOnce(gpa, false, size, .nearest, .additive, cmds)).ns);
        // Antialiased flat shade, with the tile edges shifted half a pixel off the
        // pixel grid so every tile has four partially covered edge rows/columns.
        // Best of five for the same reason as above, but the whole frame is timed:
        // scratch sizing, the accumulated pass and the resolve. One warm-up run
        // first, so the scratch allocation does not dominate the first sample.
        var best_aa: i128 = std.math.maxInt(i128);
        _ = try runAntialiased(gpa, size, cmds);
        for (0..5) |_| best_aa = @min(best_aa, (try runAntialiased(gpa, size, cmds)).ns);
        std.debug.print("{d}x{d} covered={d} flat={d:.3}ms bilinear={d:.3}ms nearest={d:.3}ms alpha={d:.3}ms additive={d:.3}ms aa={d:.3}ms\n", .{
            size,                                      size,                                    px,
            @as(f64, @floatFromInt(best_flat)) / 1e6,  @as(f64, @floatFromInt(best_bi)) / 1e6,  @as(f64, @floatFromInt(best_near)) / 1e6,
            @as(f64, @floatFromInt(best_alpha)) / 1e6, @as(f64, @floatFromInt(best_add)) / 1e6, @as(f64, @floatFromInt(best_aa)) / 1e6,
        });
    }
}
