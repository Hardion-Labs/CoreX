//! Benchmark for the software rasterizer: flat vs textured shading, the cost of
//! alpha compositing against an opaque write, the cost of antialiasing, and the
//! cost of mip selection when minifying.
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
// 512x512 RGBA8 gradient with 1-texel detail. The minified mesh below maps 8 UV
// units of it across each 32-pixel tile: 8 * 512 / 32 = 128 texels per pixel,
// i.e. level 7 — the case mipmaps exist for.
var big_pixels: [512 * 512 * 4]u8 = undefined;
var tex_big: R.RasterTexture = undefined;
var tex_big_mipped: R.RasterTexture = undefined;
const minified_uvs = [_][2]f32{
    .{ 0, 0 }, .{ 8, 0 }, .{ 8, 8 }, .{ 0, 8 },
};
const minified_mesh = R.RasterMesh{ .positions = &positions, .indices = &indices, .uvs = &minified_uvs };

/// Serves the shared tiles with the 512x512 texture, with or without the mip
/// chain, so the two runs differ in level selection only.
const MinifiedResources = struct {
    mipped: bool,
    filt: R.TextureFilter,
    mode: R.Mipmap = .trilinear,
    pub fn mesh(self: MinifiedResources, handle: u32) ?R.RasterMesh {
        _ = self;
        _ = handle;
        return minified_mesh;
    }
    pub fn color(self: MinifiedResources, handle: u32) ?[4]f32 {
        _ = self;
        return if (handle == 0) white else null;
    }
    pub fn texture(self: MinifiedResources, handle: u32) ?R.RasterTexture {
        _ = handle;
        var tex = if (self.mipped) tex_big_mipped else tex_big;
        tex.filter = self.filt;
        return tex;
    }
};

fn runMinifiedMode(
    gpa: std.mem.Allocator,
    size: u32,
    cmds: []const R.DrawCommand,
    mipped: bool,
    filt: R.TextureFilter,
    mode: R.Mipmap,
) !Run {
    const n = @as(usize, size) * size;
    const color = try gpa.alloc(u8, n * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, n);
    defer gpa.free(depth);
    const vp = corex.render.orthographic(-1, 1, -1, 1, 0, 2);
    var target = try R.Target.init(size, size, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const resources = MinifiedResources{ .mipped = mipped, .filt = filt, .mode = mode };
    const t0 = monotonicNs();
    const stats = try R.rasterize(&target, cmds, vp, resources, .{ .mipmap = mode });
    const ns = monotonicNs() - t0;
    return .{ .ns = ns, .pixels = stats.pixels };
}

fn runMinified(gpa: std.mem.Allocator, size: u32, cmds: []const R.DrawCommand, mipped: bool, filt: R.TextureFilter) !Run {
    return runMinifiedMode(gpa, size, cmds, mipped, filt, .trilinear);
}

/// A grazing footprint: the tile maps 8 UV units across x but only 0.25 across y,
/// so the pixel footprint is ~32:1 elongated. This is the case anisotropic
/// filtering exists for, and the only one where the taps cost anything real.
const grazing_uvs = [_][2]f32{
    .{ 0, 0 }, .{ 8, 0 }, .{ 8, 0.25 }, .{ 0, 0.25 },
};
const grazing_mesh = R.RasterMesh{ .positions = &positions, .indices = &indices, .uvs = &grazing_uvs };

const GrazingResources = struct {
    pub fn mesh(self: GrazingResources, handle: u32) ?R.RasterMesh {
        _ = self;
        _ = handle;
        return grazing_mesh;
    }
    pub fn color(self: GrazingResources, handle: u32) ?[4]f32 {
        _ = self;
        _ = handle;
        return white;
    }
    pub fn texture(self: GrazingResources, handle: u32) ?R.RasterTexture {
        _ = self;
        _ = handle;
        return tex_big_mipped;
    }
};

fn runGrazing(gpa: std.mem.Allocator, size: u32, cmds: []const R.DrawCommand, mode: R.Mipmap) !Run {
    return runGrazingSampling(gpa, size, cmds, mode, .{});
}

/// The same grazing draw with explicit sampling controls: the tap cap is the knob
/// a material uses to trade the correction for time, so the harness measures what a
/// cap actually buys instead of asserting it.
fn runGrazingSampling(
    gpa: std.mem.Allocator,
    size: u32,
    cmds: []const R.DrawCommand,
    mode: R.Mipmap,
    sampling: R.Sampling,
) !Run {
    const n = @as(usize, size) * size;
    const color = try gpa.alloc(u8, n * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, n);
    defer gpa.free(depth);
    const vp = corex.render.orthographic(-1, 1, -1, 1, 0, 2);
    var target = try R.Target.init(size, size, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    const t0 = monotonicNs();
    const stats = try R.rasterize(&target, cmds, vp, GrazingResources{}, .{ .mipmap = mode, .sampling = sampling });
    const ns = monotonicNs() - t0;
    return .{ .ns = ns, .pixels = stats.pixels };
}

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

    for (0..512) |y| for (0..512) |x| {
        const o = (y * 512 + x) * 4;
        big_pixels[o] = @intCast((x * 3 + y) % 256);
        big_pixels[o + 1] = @intCast((y * 3 + x * 5) % 256);
        big_pixels[o + 2] = @intCast((x ^ y) % 256);
        big_pixels[o + 3] = 255;
    };
    // Build the chain once, outside the timed spans, and hand the levels
    // straight to the texture. `Chain` owns the storage, so it is deliberately
    // never freed: this is a one-shot process benchmark.
    const chain = try R.mipmap.Chain.generate(gpa, 512, 512, &big_pixels);
    tex_big = .{ .width = 512, .height = 512, .pixels = &big_pixels, .filter = .bilinear };
    tex_big_mipped = .{ .width = 512, .height = 512, .pixels = &big_pixels, .filter = .bilinear, .mips = chain.levels() };

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
        // Mip selection, at 128 texels per pixel: the level-0 run is the classic
        // aliasing case, the mipped run is the same draw with trilinear sampling.
        var best_min_raw: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_min_raw = @min(best_min_raw, (try runMinified(gpa, size, cmds, false, .bilinear)).ns);
        var best_min_mip: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_min_mip = @min(best_min_mip, (try runMinified(gpa, size, cmds, true, .bilinear)).ns);
        // Antialiased flat shade, with the tile edges shifted half a pixel off the
        // pixel grid so every tile has four partially covered edge rows/columns.
        // The whole frame is timed: scratch sizing, the accumulated pass and the
        // resolve. One warm-up run first, so the scratch allocation does not
        // dominate the first sample.
        // Anisotropic minification at the same 128 texels/pixel, and at the
        // grazing footprint where the taps actually trigger.
        var best_min_aniso: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_min_aniso = @min(best_min_aniso, (try runMinifiedMode(gpa, size, cmds, true, .bilinear, .anisotropic)).ns);
        var best_graze_tri: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_graze_tri = @min(best_graze_tri, (try runGrazing(gpa, size, cmds, .trilinear)).ns);
        var best_graze_aniso: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_graze_aniso = @min(best_graze_aniso, (try runGrazing(gpa, size, cmds, .anisotropic)).ns);
        // The same 8:1 grazing footprint with the taps capped to four and to one:
        // cap 1 is the trilinear image by construction, so the two numbers bracket
        // what the correction costs and what a material can buy back.
        var best_graze_cap4: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_graze_cap4 = @min(best_graze_cap4, (try runGrazingSampling(gpa, size, cmds, .anisotropic, .{ .max_samples = 4 })).ns);
        var best_graze_cap1: i128 = std.math.maxInt(i128);
        for (0..5) |_| best_graze_cap1 = @min(best_graze_cap1, (try runGrazingSampling(gpa, size, cmds, .anisotropic, .{ .max_samples = 1 })).ns);
        var best_aa: i128 = std.math.maxInt(i128);
        _ = try runAntialiased(gpa, size, cmds);
        for (0..5) |_| best_aa = @min(best_aa, (try runAntialiased(gpa, size, cmds)).ns);
        std.debug.print("{d}x{d} covered={d} flat={d:.3}ms bilinear={d:.3}ms nearest={d:.3}ms alpha={d:.3}ms additive={d:.3}ms aa={d:.3}ms minify={d:.3}ms minify_mip={d:.3}ms minify_aniso={d:.3}ms graze_tri={d:.3}ms graze_aniso={d:.3}ms graze_cap4={d:.3}ms graze_cap1={d:.3}ms\n", .{
            size,                                           size,                                            px,
            @as(f64, @floatFromInt(best_flat)) / 1e6,       @as(f64, @floatFromInt(best_bi)) / 1e6,          @as(f64, @floatFromInt(best_near)) / 1e6,
            @as(f64, @floatFromInt(best_alpha)) / 1e6,      @as(f64, @floatFromInt(best_add)) / 1e6,         @as(f64, @floatFromInt(best_aa)) / 1e6,
            @as(f64, @floatFromInt(best_min_raw)) / 1e6,    @as(f64, @floatFromInt(best_min_mip)) / 1e6,     @as(f64, @floatFromInt(best_min_aniso)) / 1e6,
            @as(f64, @floatFromInt(best_graze_tri)) / 1e6,  @as(f64, @floatFromInt(best_graze_aniso)) / 1e6, @as(f64, @floatFromInt(best_graze_cap4)) / 1e6,
            @as(f64, @floatFromInt(best_graze_cap1)) / 1e6,
        });
    }
}
