//! Mip-chain construction for the software rasterizer.
//!
//! A mip chain is the texture halved repeatedly until 1x1; the rasterizer picks
//! a level from the screen-space UV derivatives (`Options.sample`), which is what
//! removes minification aliasing. This module only *builds* chains — it has no
//! dependency on `raster.zig`, so the sampler owns level selection and this owns
//! resampling.
//!
//! Determinism: the box filter is integer arithmetic with a single round-half-up
//! per channel, so a chain is bit-identical on every platform and can be pinned
//! against a reference. Levels are borrowed slices; the chain owns one
//! allocation holding them all.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// One mip level: RGBA8, row-major, top-down, exactly the framebuffer's layout.
pub const Level = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes.
    pixels: []const u8,
};

/// Number of levels a chain of this size has: level 0 plus every halving down to
/// 1x1. A 1x1 texture has one level; a 8x2 texture has four (`8x2`, `4x1`,
/// `2x1`, `1x1`).
pub fn levelCount(width: u32, height: u32) u32 {
    var count: u32 = 1;
    var w = width;
    var h = height;
    while (w > 1 or h > 1) {
        w = @max(1, w / 2);
        h = @max(1, h / 2);
        count += 1;
    }
    return count;
}

/// Size of `level` below a `width`x`height` level 0, never smaller than 1.
pub fn levelDims(width: u32, height: u32, level: u32) [2]u32 {
    var w = width;
    var h = height;
    var i: u32 = 0;
    while (i < level) : (i += 1) {
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }
    return .{ w, h };
}

/// An owned chain of mip levels, level 0 first. `levels()` borrows into
/// `storage`, so the slice is valid for as long as the chain lives.
pub const Chain = struct {
    storage: []u8,
    level_slices: []Level,

    /// Build every level below the caller's level 0 by box-filtering. Each
    /// destination texel averages the source span it covers — for an even
    /// source that is exactly a 2x2 block; an odd axis shares its last row or
    /// column with the previous destination texel instead of dropping it, so the
    /// chain conserves energy. Per channel the result is
    /// `(sum + count / 2) / count` in integers: one round-half-up, no float.
    ///
    /// `pixels` must hold `width * height * 4` bytes. The returned chain does
    /// **not** include level 0: it holds `levelCount - 1` levels, exactly the
    /// shape `raster.Texture.mips` expects.
    pub fn generate(
        gpa: Allocator,
        width: u32,
        height: u32,
        pixels: []const u8,
    ) Error!Chain {
        const total_levels = levelCount(width, height);
        const below = total_levels - 1;
        const level_slices = gpa.alloc(Level, below) catch return error.OutOfMemory;
        errdefer gpa.free(level_slices);

        var total_bytes: usize = 0;
        {
            var l: u32 = 1;
            while (l <= below) : (l += 1) {
                const d = levelDims(width, height, l);
                total_bytes += @as(usize, d[0]) * @as(usize, d[1]) * 4;
            }
        }
        const storage = gpa.alloc(u8, total_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(storage);

        var cursor: usize = 0;
        var prev_w = width;
        var prev_h = height;
        var prev: []const u8 = pixels;
        var l: u32 = 0;
        while (l < below) : (l += 1) {
            const d = levelDims(width, height, l + 1);
            const len = @as(usize, d[0]) * @as(usize, d[1]) * 4;
            const slice = storage[cursor..][0..len];
            downsample(prev, prev_w, prev_h, slice, d[0], d[1]);
            level_slices[l] = .{ .width = d[0], .height = d[1], .pixels = slice };
            cursor += len;
            prev = slice;
            prev_w = d[0];
            prev_h = d[1];
        }
        return .{ .storage = storage, .level_slices = level_slices };
    }

    /// The generated levels below level 0, largest first.
    pub fn levels(self: Chain) []const Level {
        return self.level_slices;
    }

    pub fn deinit(self: *Chain, gpa: Allocator) void {
        gpa.free(self.level_slices);
        gpa.free(self.storage);
        self.* = undefined;
    }
};

/// Box-filter `src` (`sw`x`sh`) into `dst` (`dw`x`dh`), one integer round-up per
/// channel. `dw` is `sw / 2` and `dh` is `sh / 2`, both at least 1.
fn downsample(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32) void {
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            const count: u32 = (x1 - x0) * (y1 - y0);

            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const off = (@as(usize, sy) * sw + sx) * 4;
                    for (0..4) |c| acc[c] += src[off + c];
                }
            }
            const out = (@as(usize, dy) * dw + dx) * 4;
            for (0..4) |c| dst[out + c] = @intCast((acc[c] + count / 2) / count);
        }
    }
}

const testing = std.testing;

test "mipmap: level count and dims match repeated halving down to 1x1" {
    try testing.expectEqual(@as(u32, 1), levelCount(1, 1));
    try testing.expectEqual(@as(u32, 4), levelCount(8, 1)); // 8, 4, 2, 1
    try testing.expectEqual(@as(u32, 4), levelCount(8, 8)); // 8, 4, 2, 1
    try testing.expectEqual(@as(u32, 4), levelCount(8, 2)); // 8x2, 4x1, 2x1, 1x1
    try testing.expectEqual(@as(u32, 3), levelCount(5, 3)); // 5x3, 2x1, 1x1

    try testing.expectEqual([2]u32{ 8, 8 }, levelDims(8, 8, 0));
    try testing.expectEqual([2]u32{ 4, 4 }, levelDims(8, 8, 1));
    try testing.expectEqual([2]u32{ 1, 1 }, levelDims(8, 8, 3));
    try testing.expectEqual([2]u32{ 4, 1 }, levelDims(8, 2, 1));
    try testing.expectEqual([2]u32{ 2, 1 }, levelDims(8, 2, 2));
    try testing.expectEqual([2]u32{ 1, 1 }, levelDims(8, 2, 3));
}

test "mipmap: a 2x2 quad averages to the 1x1 level with one round-half-up" {
    // Red: 0, 1, 2, 200 -> sum 203, /4 = 50.75 -> 51. Green sums to 102 -> 26.
    // Blue picks values that round up and down explicitly: 0,0,0,2 -> 0.5 -> 1.
    const src = [_]u8{
        0,   0,   0, 255,
        1,   0,   0, 255,
        2,   0,   0, 255,
        200, 102, 2, 255,
    };
    var chain = try Chain.generate(testing.allocator, 2, 2, &src);
    defer chain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), chain.levels().len);
    const level = chain.levels()[0];
    try testing.expectEqual([2]u32{ 1, 1 }, .{ level.width, level.height });
    try testing.expectEqualSlices(u8, &.{ 51, 26, 1, 255 }, level.pixels);
}

test "mipmap: odd axes share the last row and column instead of dropping them" {
    // 3x1 -> 1x1 must cover all three texels (2 is the middle one, 3 the last).
    const src = [_]u8{
        10, 0, 0, 255,
        20, 0, 0, 255,
        60, 0, 0, 255,
    };
    var chain = try Chain.generate(testing.allocator, 3, 1, &src);
    defer chain.deinit(testing.allocator);
    // Levels of a 3x1 texture: 3x1 -> 1x1, so there is exactly one level below.
    try testing.expectEqual(@as(usize, 1), chain.levels().len);
    try testing.expectEqualSlices(u8, &.{ 30, 0, 0, 255 }, chain.levels()[0].pixels);
}

test "mipmap: a 1x1 texture generates no further levels" {
    const src = [_]u8{ 7, 8, 9, 255 };
    var chain = try Chain.generate(testing.allocator, 1, 1, &src);
    defer chain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), chain.levels().len);
}

test "mipmap: every generated level is a valid level of the chain it belongs to" {
    var src: [8 * 4 * 4]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 37) % 256);
    var chain = try Chain.generate(testing.allocator, 8, 4, &src);
    defer chain.deinit(testing.allocator);
    // 8x4 -> 4x2 -> 2x1 -> 1x1
    try testing.expectEqual(@as(usize, 3), chain.levels().len);
    const expect_dims = [_][2]u32{ .{ 4, 2 }, .{ 2, 1 }, .{ 1, 1 } };
    for (chain.levels(), expect_dims) |level, want| {
        try testing.expectEqual(want[0], level.width);
        try testing.expectEqual(want[1], level.height);
        try testing.expectEqual(@as(usize, want[0] * want[1] * 4), level.pixels.len);
    }
}

test "mipmap: generation failure surfaces as OutOfMemory and leaks nothing" {
    const Probe = struct {
        fn run(gpa: Allocator, src: []const u8) !void {
            var chain = try Chain.generate(gpa, 8, 8, src);
            defer chain.deinit(gpa);
            try testing.expectEqual(@as(usize, 3), chain.levels().len);
        }
    };
    var src: [8 * 8 * 4]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 251);
    try testing.checkAllAllocationFailures(testing.allocator, Probe.run, .{&src});
}
