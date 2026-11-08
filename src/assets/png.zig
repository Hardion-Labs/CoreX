//! PNG (Portable Network Graphics) decoding, normalizing to RGBA8.
//!
//! Supported, dependency-free subset (the format's full range, interlaced or not):
//! - Color types: grayscale (0), truecolor (2), indexed (3), grayscale+alpha (4)
//!   and truecolor+alpha (6).
//! - Bit depths: 1/2/4/8 for grayscale and indexed, 8/16 for the other types,
//!   exactly as the specification allows.
//! - All five row filters (None, Sub, Up, Average, Paeth) and any number of
//!   IDAT chunks; ancillary chunks are skipped, critical unknown chunks rejected.
//! - `tRNS` transparency: palette alpha, grayscale color key and RGB color key.
//! - Every chunk CRC-32 and the zlib Adler-32 are verified.
//!
//! Normalization rules (documented, not silent):
//! - 16-bit samples are reduced to 8 bits by taking the high byte, because the
//!   engine artifact (`CXTX`) is RGBA8. Color-key comparison still happens at the
//!   source bit depth, so transparency is exact.
//! - Sub-byte grayscale samples are scaled to the full 0..255 range (bit
//!   replication), so a 1-bit white pixel becomes 255 rather than 1.
//! - Adam7 interlacing is decoded properly: the seven passes are unfiltered
//!   independently and scattered to their final positions, so an interlaced file
//!   produces exactly the same pixels as its non-interlaced equivalent.
//!
//! Memory safety and performance: chunk parsing is bounds-checked, the inflated
//! scanline buffer is bounded by the dimensions declared in `IHDR` (so a
//! decompression bomb cannot exceed the image's own size), unfiltering runs in
//! place row by row, and the pixel conversion is specialized at comptime per
//! (bit depth, channel count) so the inner loop has no per-pixel branching on
//! format. A single IDAT chunk is inflated in place with no copy.
//!
//! Ownership: `decode` returns an `image.Image` whose `pixels` the caller owns
//! (`Image.deinit`). This module depends only on `std`, `image.zig` and
//! `inflate.zig`.

const std = @import("std");
const image = @import("image.zig");
const inflate = @import("inflate.zig");

const Allocator = std.mem.Allocator;
const DecodeError = image.DecodeError;
const Image = image.Image;

/// The 8-byte PNG signature.
pub const signature = "\x89PNG\r\n\x1a\n";

/// Maximum number of palette entries allowed by the format.
pub const max_palette_entries: usize = 256;

/// Upper bound for the inflated scanline buffer: 16-bit RGBA needs twice the
/// RGBA8 pixel budget, plus one filter byte per row.
pub const max_raw_bytes: usize = image.max_pixel_bytes * 2 + image.max_dimension;

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    palette = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

fn channelsOf(color: ColorType) u8 {
    return switch (color) {
        .grayscale, .palette => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
    };
}

fn depthAllowed(color: ColorType, depth: u8) bool {
    return switch (color) {
        .grayscale => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        .palette => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        .rgb, .grayscale_alpha, .rgba => depth == 8 or depth == 16,
    };
}

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: ColorType,
    /// Bytes per reconstructed scanline (without the filter byte).
    row_bytes: usize,
    /// Bytes per complete pixel, rounded up, minimum 1 (the filter offset).
    bpp: usize,
    /// Exact expected size of the inflated scanline data. For an interlaced
    /// image this is the sum over the non-empty Adam7 passes.
    raw_bytes: usize,
    /// Adam7 interlacing. Each pass is an independent sub-image with its own
    /// filter history.
    interlaced: bool,
};

/// Adam7 pass geometry: where the pass starts and how far apart its pixels are.
const adam7 = [7][4]u32{
    .{ 0, 0, 8, 8 },
    .{ 4, 0, 8, 8 },
    .{ 0, 4, 4, 8 },
    .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 },
    .{ 1, 0, 2, 2 },
    .{ 0, 1, 1, 2 },
};

const Pass = struct {
    x0: u32,
    y0: u32,
    dx: u32,
    dy: u32,
    width: u32,
    height: u32,
    row_bytes: usize,
    /// Bytes this pass occupies in the inflated stream, filter bytes included.
    raw_bytes: usize,

    fn empty() Pass {
        return .{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .width = 0, .height = 0, .row_bytes = 0, .raw_bytes = 0 };
    }
};

/// Geometry of one pass, or a zero-sized pass when the image is too small to
/// reach its starting offset. Such passes contribute **no** bytes at all -- not
/// even a filter byte -- which is the detail most easily got wrong.
fn passGeometry(header: Header, index: usize) DecodeError!Pass {
    const g = adam7[index];
    const x0 = g[0];
    const y0 = g[1];
    const dx = g[2];
    const dy = g[3];
    if (header.width <= x0 or header.height <= y0) return Pass.empty();
    const pw = (header.width - x0 + dx - 1) / dx;
    const ph = (header.height - y0 + dy - 1) / dy;
    const bits: usize = @as(usize, channelsOf(header.color)) * header.depth;
    const row_bytes = (@as(usize, pw) * bits + 7) / 8;
    const total = std.math.mul(usize, row_bytes + 1, ph) catch return error.InvalidImage;
    return .{ .x0 = x0, .y0 = y0, .dx = dx, .dy = dy, .width = pw, .height = ph, .row_bytes = row_bytes, .raw_bytes = total };
}

const Transparency = struct {
    /// Grayscale color key at the source bit depth.
    gray_key: ?u16 = null,
    /// RGB color key at the source bit depth.
    rgb_key: ?[3]u16 = null,
    /// Per-palette-entry alpha; entries past the end are opaque.
    palette_alpha: []const u8 = &.{},
};

// --- CRC-32 (as used by PNG chunks) ----------------------------------------

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
        entry.* = c;
    }
    break :blk table;
};

/// PNG CRC-32 (reflected polynomial 0xEDB88320) over `data`.
pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |byte| c = crc_table[(c ^ byte) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

// --- chunk parsing ---------------------------------------------------------

const Chunk = struct {
    kind: [4]u8,
    data: []const u8,

    fn is(self: Chunk, name: []const u8) bool {
        return std.mem.eql(u8, &self.kind, name);
    }

    /// An unknown chunk is critical when its first letter is uppercase.
    fn isCritical(self: Chunk) bool {
        return self.kind[0] & 0x20 == 0;
    }
};

fn nextChunk(source: []const u8, pos: *usize) DecodeError!Chunk {
    if (pos.* > source.len or source.len - pos.* < 12) return error.InvalidImage;
    const len = std.mem.readInt(u32, source[pos.*..][0..4], .big);
    if (len > 0x7FFFFFFF) return error.InvalidImage; // high bit is reserved
    const kind: [4]u8 = source[pos.* + 4 ..][0..4].*;
    const data_start = pos.* + 8;
    const data_end = data_start + len;
    if (data_end + 4 > source.len) return error.InvalidImage;
    const stored = std.mem.readInt(u32, source[data_end..][0..4], .big);
    if (crc32(source[pos.* + 4 .. data_end]) != stored) return error.InvalidImage;
    pos.* = data_end + 4;
    return .{ .kind = kind, .data = source[data_start..data_end] };
}

fn parseHeader(data: []const u8) DecodeError!Header {
    if (data.len != 13) return error.InvalidImage;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const depth = data[8];
    const color: ColorType = switch (data[9]) {
        0 => .grayscale,
        2 => .rgb,
        3 => .palette,
        4 => .grayscale_alpha,
        6 => .rgba,
        else => return error.InvalidImage,
    };
    if (data[10] != 0) return error.InvalidImage; // compression method: deflate
    if (data[11] != 0) return error.InvalidImage; // filter method: adaptive
    const interlaced = switch (data[12]) {
        0 => false,
        1 => true,
        else => return error.InvalidImage, // only None and Adam7 are defined
    };
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > image.max_dimension or height > image.max_dimension) return error.InvalidImage;
    if (!depthAllowed(color, depth)) return error.InvalidImage;

    const channels: usize = channelsOf(color);
    const bits_per_pixel = channels * depth;
    const row_bytes = (@as(usize, width) * bits_per_pixel + 7) / 8;
    const bpp = @max(1, (bits_per_pixel + 7) / 8);
    var header = Header{
        .width = width,
        .height = height,
        .depth = depth,
        .color = color,
        .row_bytes = row_bytes,
        .bpp = bpp,
        .raw_bytes = 0,
        .interlaced = interlaced,
    };
    header.raw_bytes = if (interlaced) blk: {
        var total: usize = 0;
        for (0..adam7.len) |i| {
            const pass = try passGeometry(header, i);
            total = std.math.add(usize, total, pass.raw_bytes) catch return error.InvalidImage;
        }
        break :blk total;
    } else std.math.mul(usize, row_bytes + 1, height) catch return error.InvalidImage;
    if (header.raw_bytes == 0 or header.raw_bytes > max_raw_bytes) return error.InvalidImage;

    // Reject images whose RGBA8 output could not be allocated before inflating.
    const pixels = std.math.mul(usize, @as(usize, width) * @as(usize, height), 4) catch return error.InvalidImage;
    if (pixels > image.max_pixel_bytes) return error.InvalidImage;

    return header;
}

/// Collects IDAT payload without copying when there is a single chunk (the
/// common case); multiple chunks are concatenated into one owned buffer.
const Idat = struct {
    first: []const u8 = &.{},
    joined: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn push(self: *Idat, gpa: Allocator, data: []const u8) DecodeError!void {
        self.count += 1;
        if (self.count == 1) {
            self.first = data;
            return;
        }
        if (self.count == 2) {
            self.joined.appendSlice(gpa, self.first) catch return error.OutOfMemory;
        }
        self.joined.appendSlice(gpa, data) catch return error.OutOfMemory;
    }

    fn bytes(self: *const Idat) []const u8 {
        return if (self.count <= 1) self.first else self.joined.items;
    }

    fn deinit(self: *Idat, gpa: Allocator) void {
        self.joined.deinit(gpa);
        self.* = .{};
    }
};

// --- row unfiltering -------------------------------------------------------

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Reconstruct scanlines in place. `prev` is the already-reconstructed previous
/// row, or empty for the first row (the specification treats it as zeros).
fn unfilter(raw: []u8, header: Header) DecodeError!void {
    const stride = header.row_bytes + 1;
    const bpp = header.bpp;
    var prev: []const u8 = &.{};
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const start = y * stride;
        const filter = raw[start];
        const row = raw[start + 1 ..][0..header.row_bytes];
        switch (filter) {
            0 => {},
            1 => {
                var i: usize = bpp;
                while (i < row.len) : (i += 1) row[i] +%= row[i - bpp];
            },
            2 => {
                if (prev.len != 0) {
                    for (row, prev) |*byte, up| byte.* +%= up;
                }
            },
            3 => {
                if (prev.len == 0) {
                    var i: usize = bpp;
                    while (i < row.len) : (i += 1) row[i] +%= row[i - bpp] / 2;
                } else {
                    var i: usize = 0;
                    while (i < row.len) : (i += 1) {
                        const a: u16 = if (i >= bpp) row[i - bpp] else 0;
                        row[i] +%= @intCast((a + prev[i]) / 2);
                    }
                }
            },
            4 => {
                var i: usize = 0;
                while (i < row.len) : (i += 1) {
                    const a: u8 = if (i >= bpp) row[i - bpp] else 0;
                    const b: u8 = if (i < prev.len) prev[i] else 0;
                    const c: u8 = if (i >= bpp and i - bpp < prev.len) prev[i - bpp] else 0;
                    row[i] +%= paeth(a, b, c);
                }
            },
            else => return error.InvalidImage,
        }
        prev = row;
    }
}

// --- sample access and RGBA8 conversion ------------------------------------

/// Read sample `index` of a reconstructed row at the source bit depth.
fn sample(comptime depth: u8, row: []const u8, index: usize) u16 {
    if (depth == 16) return std.mem.readInt(u16, row[index * 2 ..][0..2], .big);
    if (depth == 8) return row[index];
    const per_byte: usize = 8 / depth;
    const byte = row[index / per_byte];
    const shift: u3 = @intCast(8 - depth - (index % per_byte) * depth);
    const mask: u8 = (1 << depth) - 1;
    return (byte >> shift) & mask;
}

/// Reduce a sample to 8 bits: high byte for 16-bit sources, bit replication for
/// sub-byte sources, identity for 8-bit sources.
fn scale8(comptime depth: u8, value: u16) u8 {
    if (depth == 16) return @truncate(value >> 8);
    if (depth == 8) return @truncate(value);
    const max_value: u32 = (1 << depth) - 1;
    return @intCast((@as(u32, value) * 255) / max_value);
}

fn convertRows(
    comptime depth: u8,
    comptime channels: u8,
    comptime is_palette: bool,
    dst: []u8,
    raw: []const u8,
    header: Header,
    palette: []const u8,
    palette_count: usize,
    trns: Transparency,
) DecodeError!void {
    const stride = header.row_bytes + 1;
    const width: usize = header.width;
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row = raw[y * stride + 1 ..][0..header.row_bytes];
        const out = dst[y * width * 4 ..][0 .. width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const d = x * 4;
            if (is_palette) {
                const index = sample(depth, row, x);
                if (index >= palette_count) return error.InvalidImage;
                const p = index * 3;
                out[d + 0] = palette[p + 0];
                out[d + 1] = palette[p + 1];
                out[d + 2] = palette[p + 2];
                out[d + 3] = if (index < trns.palette_alpha.len) trns.palette_alpha[index] else 255;
            } else if (channels == 1) {
                const s = sample(depth, row, x);
                const v = scale8(depth, s);
                out[d + 0] = v;
                out[d + 1] = v;
                out[d + 2] = v;
                out[d + 3] = if (trns.gray_key) |key| (if (s == key) 0 else 255) else 255;
            } else if (channels == 2) {
                const s = sample(depth, row, x * 2);
                const v = scale8(depth, s);
                out[d + 0] = v;
                out[d + 1] = v;
                out[d + 2] = v;
                out[d + 3] = scale8(depth, sample(depth, row, x * 2 + 1));
            } else if (channels == 3) {
                const r = sample(depth, row, x * 3 + 0);
                const g = sample(depth, row, x * 3 + 1);
                const b = sample(depth, row, x * 3 + 2);
                out[d + 0] = scale8(depth, r);
                out[d + 1] = scale8(depth, g);
                out[d + 2] = scale8(depth, b);
                out[d + 3] = if (trns.rgb_key) |key|
                    (if (r == key[0] and g == key[1] and b == key[2]) 0 else 255)
                else
                    255;
            } else {
                out[d + 0] = scale8(depth, sample(depth, row, x * 4 + 0));
                out[d + 1] = scale8(depth, sample(depth, row, x * 4 + 1));
                out[d + 2] = scale8(depth, sample(depth, row, x * 4 + 2));
                out[d + 3] = scale8(depth, sample(depth, row, x * 4 + 3));
            }
        }
    }
}

fn convertDepth(
    comptime channels: u8,
    comptime is_palette: bool,
    dst: []u8,
    raw: []const u8,
    header: Header,
    palette: []const u8,
    palette_count: usize,
    trns: Transparency,
) DecodeError!void {
    switch (header.depth) {
        inline 1, 2, 4, 8, 16 => |depth| {
            if (comptime depthAllowed(if (is_palette) .palette else switch (channels) {
                1 => ColorType.grayscale,
                2 => .grayscale_alpha,
                3 => .rgb,
                else => .rgba,
            }, depth)) {
                return convertRows(depth, channels, is_palette, dst, raw, header, palette, palette_count, trns);
            }
            return error.InvalidImage;
        },
        else => return error.InvalidImage,
    }
}

/// Decode a non-interlaced PNG into RGBA8. The caller owns `Image.pixels`.
pub fn decode(gpa: Allocator, source: []const u8) DecodeError!Image {
    if (source.len < signature.len + 12) return error.InvalidImage;
    if (!std.mem.eql(u8, source[0..signature.len], signature)) return error.InvalidImage;

    var pos: usize = signature.len;
    const first = try nextChunk(source, &pos);
    if (!first.is("IHDR")) return error.InvalidImage;
    const header = try parseHeader(first.data);

    var palette: []const u8 = &.{};
    var palette_count: usize = 0;
    var trns = Transparency{};
    var idat = Idat{};
    defer idat.deinit(gpa);
    var seen_trns = false;
    var idat_closed = false;
    var ended = false;

    while (!ended) {
        const chunk = try nextChunk(source, &pos);
        if (chunk.is("IDAT")) {
            if (idat_closed) return error.InvalidImage; // IDAT chunks must be consecutive
            if (header.color == .palette and palette_count == 0) return error.InvalidImage;
            try idat.push(gpa, chunk.data);
            continue;
        }
        if (idat.count != 0) idat_closed = true;

        if (chunk.is("IEND")) {
            if (chunk.data.len != 0) return error.InvalidImage;
            if (pos != source.len) return error.InvalidImage; // no trailing bytes
            ended = true;
        } else if (chunk.is("IHDR")) {
            return error.InvalidImage; // duplicate header
        } else if (chunk.is("PLTE")) {
            if (palette_count != 0 or idat.count != 0) return error.InvalidImage;
            if (header.color == .grayscale or header.color == .grayscale_alpha) return error.InvalidImage;
            if (chunk.data.len == 0 or chunk.data.len % 3 != 0) return error.InvalidImage;
            palette_count = chunk.data.len / 3;
            if (palette_count > max_palette_entries) return error.InvalidImage;
            palette = chunk.data;
        } else if (chunk.is("tRNS")) {
            if (seen_trns or idat.count != 0) return error.InvalidImage;
            seen_trns = true;
            switch (header.color) {
                .palette => {
                    if (palette_count == 0 or chunk.data.len > palette_count) return error.InvalidImage;
                    trns.palette_alpha = chunk.data;
                },
                .grayscale => {
                    if (chunk.data.len != 2) return error.InvalidImage;
                    trns.gray_key = std.mem.readInt(u16, chunk.data[0..2], .big);
                },
                .rgb => {
                    if (chunk.data.len != 6) return error.InvalidImage;
                    trns.rgb_key = .{
                        std.mem.readInt(u16, chunk.data[0..2], .big),
                        std.mem.readInt(u16, chunk.data[2..4], .big),
                        std.mem.readInt(u16, chunk.data[4..6], .big),
                    };
                },
                .grayscale_alpha, .rgba => return error.InvalidImage, // already has alpha
            }
        } else if (chunk.isCritical()) {
            return error.InvalidImage; // unknown critical chunk
        }
        // Unknown ancillary chunks are skipped (their CRC was already verified).
    }

    if (idat.count == 0) return error.InvalidImage;
    if (header.color == .palette and palette_count == 0) return error.InvalidImage;

    const raw = inflate.zlibInflate(gpa, idat.bytes(), header.raw_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStream, error.OutputTooLarge => return error.InvalidImage,
    };
    defer gpa.free(raw);
    if (raw.len != header.raw_bytes) return error.InvalidImage;

    const pixels = try image.allocPixels(gpa, header.width, header.height);
    errdefer gpa.free(pixels);
    const img = Image{ .width = header.width, .height = header.height, .pixels = pixels };

    if (header.interlaced) {
        try deinterlace(gpa, pixels, raw, header, palette, palette_count, trns);
        return img;
    }

    try unfilter(raw, header);
    try convertInto(pixels, raw, header, palette, palette_count, trns);
    return img;
}

/// The colour-type dispatch, shared by the whole-image and per-pass paths so the
/// comptime specialization has exactly one call site to keep correct.
fn convertInto(
    dst: []u8,
    raw: []const u8,
    header: Header,
    palette: []const u8,
    palette_count: usize,
    trns: Transparency,
) DecodeError!void {
    switch (header.color) {
        .grayscale => try convertDepth(1, false, dst, raw, header, palette, palette_count, trns),
        .palette => try convertDepth(1, true, dst, raw, header, palette, palette_count, trns),
        .grayscale_alpha => try convertDepth(2, false, dst, raw, header, palette, palette_count, trns),
        .rgb => try convertDepth(3, false, dst, raw, header, palette, palette_count, trns),
        .rgba => try convertDepth(4, false, dst, raw, header, palette, palette_count, trns),
    }
}

/// Reconstruct an Adam7 image.
///
/// Each pass is an independent sub-image: it is unfiltered with its **own**
/// predictor history, then its pixels are scattered to the full image at the
/// pass stride. Empty passes contribute nothing and are skipped.
///
/// Only one scratch row is allocated, reused across every pass. Passes whose
/// x-step is 1 write straight into the output row and skip the copy entirely --
/// that is the last pass, which carries half the image.
fn deinterlace(
    gpa: Allocator,
    pixels: []u8,
    raw: []u8,
    header: Header,
    palette: []const u8,
    palette_count: usize,
    trns: Transparency,
) DecodeError!void {
    const width: usize = header.width;
    const scratch = try gpa.alloc(u8, width * 4);
    defer gpa.free(scratch);

    var offset: usize = 0;
    for (0..adam7.len) |i| {
        const pass = try passGeometry(header, i);
        if (pass.width == 0 or pass.height == 0) continue;
        // parseHeader already proved the sizes sum to raw.len.
        const region = raw[offset..][0..pass.raw_bytes];
        offset += pass.raw_bytes;

        const pass_header = Header{
            .width = pass.width,
            .height = pass.height,
            .depth = header.depth,
            .color = header.color,
            .row_bytes = pass.row_bytes,
            .bpp = header.bpp,
            .raw_bytes = pass.raw_bytes,
            .interlaced = false,
        };
        try unfilter(region, pass_header);

        const stride = pass.row_bytes + 1;
        const pw: usize = pass.width;
        // A single-row view lets the existing converter run unchanged.
        var row_header = pass_header;
        row_header.height = 1;

        var r: usize = 0;
        while (r < pass.height) : (r += 1) {
            const y: usize = @as(usize, pass.y0) + r * @as(usize, pass.dy);
            std.debug.assert(y < header.height);
            const src_row = region[r * stride ..][0..stride];
            const out_row = pixels[y * width * 4 ..][0 .. width * 4];
            if (pass.dx == 1) {
                // Contiguous: convert directly into the destination, no copy.
                std.debug.assert(pass.x0 == 0 and pw == width);
                try convertInto(out_row, src_row, row_header, palette, palette_count, trns);
                continue;
            }
            try convertInto(scratch[0 .. pw * 4], src_row, row_header, palette, palette_count, trns);
            var x: usize = 0;
            while (x < pw) : (x += 1) {
                const dx_idx: usize = @as(usize, pass.x0) + x * @as(usize, pass.dx);
                std.debug.assert(dx_idx < width);
                @memcpy(out_row[dx_idx * 4 ..][0..4], scratch[x * 4 ..][0..4]);
            }
        }
    }
    std.debug.assert(offset == raw.len);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const vectors = @import("png_vectors.zig");
const adam7_vectors = @import("png_adam7_vectors.zig");
const alloc_probe = @import("../core/alloc_probe.zig");

fn unhex(gpa: Allocator, hex: []const u8) ![]u8 {
    const bytes = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

test "png: every valid vector decodes to the reference RGBA8 pixels" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        const expected = try unhex(gpa, vector.rgba_hex);
        defer gpa.free(expected);

        var img = try decode(gpa, source);
        defer img.deinit(gpa);
        errdefer std.debug.print("failed vector: {s}\n", .{vector.name});
        try testing.expectEqual(vector.width, img.width);
        try testing.expectEqual(vector.height, img.height);
        try testing.expectEqualSlices(u8, expected, img.pixels);
    }
}

test "png: malformed files are rejected" {
    const gpa = testing.allocator;
    for (vectors.invalid) |vector| {
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        errdefer std.debug.print("vector accepted but should fail: {s}\n", .{vector.name});
        try testing.expectError(error.InvalidImage, decode(gpa, source));
    }
}

test "png: truncation at any chunk boundary is rejected" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.valid[0].png_hex);
    defer gpa.free(source);
    var cut: usize = 0;
    while (cut < source.len) : (cut += 1) {
        try testing.expectError(error.InvalidImage, decode(gpa, source[0..cut]));
    }
}

test "png: crc32 matches the reference check values" {
    try testing.expectEqual(@as(u32, 0), crc32(""));
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try testing.expectEqual(@as(u32, 0xAE426082), crc32("IEND"));
}

test "png: decoding is deterministic and independent per call" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.valid[0].png_hex);
    defer gpa.free(source);
    var a = try decode(gpa, source);
    defer a.deinit(gpa);
    var b = try decode(gpa, source);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(u8, a.pixels, b.pixels);
    // Mutating one result must not affect the other (no shared buffers).
    a.pixels[0] ^= 0xFF;
    try testing.expect(a.pixels[0] != b.pixels[0]);
}

test "png: 16-bit sources keep the high byte and exact color-key transparency" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        if (!std.mem.eql(u8, vector.name, "rgb16_color_key")) continue;
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        var img = try decode(gpa, source);
        defer img.deinit(gpa);
        // First pixel is the color key (1000, 2000, 3000) -> fully transparent,
        // with the high bytes of each sample as RGB.
        try testing.expectEqualSlices(u8, &[_]u8{ 1000 >> 8, 2000 >> 8, 3000 >> 8, 0 }, img.pixels[0..4]);
        try testing.expectEqual(@as(u8, 255), img.pixels[7]);
        return;
    }
    return error.MissingVector;
}

test "png: survives allocation failure" {
    const gpa = testing.allocator;
    const names = [_][]const u8{ "rgb8_all_filters", "palette8_trns", "rgb8_multi_idat", "rgba16" };
    for (vectors.valid) |vector| {
        var selected = false;
        for (names) |name| {
            if (std.mem.eql(u8, vector.name, name)) selected = true;
        }
        if (!selected) continue;
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        try alloc_probe.check(
            struct {
                fn f(alloc: Allocator, bytes: []const u8) !void {
                    var img = try decode(alloc, bytes);
                    img.deinit(alloc);
                }
            }.f,
            .{source},
        );
    }
}

// --- Adam7 interlacing ------------------------------------------------------

test "png: every libpng-verified Adam7 vector decodes exactly" {
    const gpa = testing.allocator;
    for (adam7_vectors.valid) |vector| {
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        const expected = try unhex(gpa, vector.rgba_hex);
        defer gpa.free(expected);
        var img = decode(gpa, source) catch |err| {
            std.debug.print("adam7 vector {s} failed: {s}\n", .{ vector.name, @errorName(err) });
            return err;
        };
        defer img.deinit(gpa);
        try testing.expectEqual(vector.width, img.width);
        try testing.expectEqual(vector.height, img.height);
        testing.expectEqualSlices(u8, expected, img.pixels) catch |err| {
            std.debug.print("adam7 vector {s} pixels differ\n", .{vector.name});
            return err;
        };
    }
}

test "png: Adam7 inflated size is the sum over the non-empty passes" {
    const gpa = testing.allocator;
    for (adam7_vectors.valid) |vector| {
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        // Walk the chunks by hand and confirm the header predicted the exact
        // inflated size, independently of `decode`.
        var idat = Idat{};
        defer idat.deinit(gpa);
        var pos: usize = signature.len;
        const first = try nextChunk(source, &pos);
        try testing.expect(first.is("IHDR"));
        const header = try parseHeader(first.data);
        try testing.expect(header.interlaced);
        try testing.expectEqual(vector.raw_len, header.raw_bytes);
        while (true) {
            const ch = try nextChunk(source, &pos);
            if (ch.is("IDAT")) try idat.push(gpa, ch.data);
            if (ch.is("IEND")) break;
        }
        const raw = try inflate.zlibInflate(gpa, idat.bytes(), header.raw_bytes);
        defer gpa.free(raw);
        try testing.expectEqual(vector.raw_len, raw.len);
    }
}

test "png: malformed Adam7 files are rejected" {
    const gpa = testing.allocator;
    for (adam7_vectors.invalid) |vector| {
        const source = try unhex(gpa, vector.png_hex);
        defer gpa.free(source);
        _ = decode(gpa, source) catch |err| {
            try testing.expectEqual(error.InvalidImage, err);
            continue;
        };
        std.debug.print("adam7 invalid vector {s} was accepted\n", .{vector.name});
        return error.TestUnexpectedResult;
    }
}

test "png: the seven passes tile the image exactly, with no overlap" {
    // Independent of the decoder: the pass areas must sum to width * height for
    // every size, including ones that leave several passes empty.
    for (1..40) |w| {
        for (1..40) |h| {
            const header = Header{
                .width = @intCast(w),
                .height = @intCast(h),
                .depth = 8,
                .color = .rgba,
                .row_bytes = w * 4,
                .bpp = 4,
                .raw_bytes = 0,
                .interlaced = true,
            };
            var covered: usize = 0;
            for (0..adam7.len) |i| {
                const pass = try passGeometry(header, i);
                covered += @as(usize, pass.width) * @as(usize, pass.height);
            }
            try testing.expectEqual(w * h, covered);
        }
    }
}

test "png: Adam7 pass sizes match the specification for an 8x8 image" {
    const header = Header{
        .width = 8,
        .height = 8,
        .depth = 8,
        .color = .rgb,
        .row_bytes = 24,
        .bpp = 3,
        .raw_bytes = 0,
        .interlaced = true,
    };
    const expected = [7][2]u32{
        .{ 1, 1 }, .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 }, .{ 4, 2 }, .{ 4, 4 }, .{ 8, 4 },
    };
    for (0..adam7.len) |i| {
        const pass = try passGeometry(header, i);
        try testing.expectEqual(expected[i][0], pass.width);
        try testing.expectEqual(expected[i][1], pass.height);
    }
}

test "png: an image smaller than a pass start contributes no bytes for it" {
    const header = Header{
        .width = 1,
        .height = 1,
        .depth = 8,
        .color = .rgb,
        .row_bytes = 3,
        .bpp = 3,
        .raw_bytes = 0,
        .interlaced = true,
    };
    const first = try passGeometry(header, 0);
    try testing.expectEqual(@as(u32, 1), first.width);
    try testing.expectEqual(@as(usize, 4), first.raw_bytes); // one row + filter
    for (1..adam7.len) |i| {
        const pass = try passGeometry(header, i);
        try testing.expectEqual(@as(u32, 0), pass.width);
        try testing.expectEqual(@as(u32, 0), pass.height);
        try testing.expectEqual(@as(usize, 0), pass.raw_bytes);
    }
}

test "png: Adam7 decoding propagates allocation failures without leaking" {
    const gpa = testing.allocator;
    const vector = adam7_vectors.valid[0];
    const source = try unhex(gpa, vector.png_hex);
    defer gpa.free(source);
    const Probe = struct {
        fn run(alloc: Allocator, bytes: []const u8) !void {
            var img = try decode(alloc, bytes);
            img.deinit(alloc);
        }
    };
    try alloc_probe.check(Probe.run, .{source});
}

test "png: a large interlaced image matches its non-interlaced twin exactly" {
    const gpa = testing.allocator;
    const inter = try unhex(gpa, adam7_vectors.large_interlaced_hex);
    defer gpa.free(inter);
    const plain = try unhex(gpa, adam7_vectors.large_plain_hex);
    defer gpa.free(plain);

    var a = try decode(gpa, inter);
    defer a.deinit(gpa);
    var b = try decode(gpa, plain);
    defer b.deinit(gpa);

    const w = adam7_vectors.large_width;
    const h = adam7_vectors.large_height;
    try testing.expectEqual(w, a.width);
    try testing.expectEqual(h, a.height);
    // Both paths must agree with each other and with the documented formula,
    // at a size where every pass ends mid-stride.
    try testing.expectEqualSlices(u8, b.pixels, a.pixels);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                const want: u8 = @intCast((x * 3 + y * 5 + c * 17) % 256);
                try testing.expectEqual(want, a.pixels[(y * w + x) * 4 + c]);
            }
        }
    }
}
