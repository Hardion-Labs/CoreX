//! Pure image decoders for the asset pipeline. Every decoder normalizes to
//! tightly-packed RGBA8 (8 bits per channel, row-major, top-down) so the
//! renderer can upload pixels without re-parsing the source format.
//!
//! Supported source formats (dependency-free, standard library only):
//! - BMP  — uncompressed (`BI_RGB`) 24-bit and 32-bit, bottom-up or top-down.
//! - TGA  — uncompressed and RLE true-color, 24-bit and 32-bit.
//! - QOI  — Quite OK Image, decode and encode (encode enables lossless
//!          roundtrip tests and a future export path).
//!
//! Decoders are pure functions `source bytes -> Image`; the caller owns
//! `Image.pixels` and frees it with `Image.deinit`. All allocations are bounded
//! (`max_dimension`, `max_pixel_bytes`) and every read is bounds-checked, so a
//! malformed or truncated file is rejected with `error.InvalidImage` rather than
//! causing an out-of-bounds access. This module depends only on `std`, so it is
//! independently testable and loosely coupled from the pipeline/cache.
//!
//! PNG lives in `png.zig` (it needs the DEFLATE decoder in `inflate.zig`) and
//! normalizes to the same RGBA8 `Image`, so the artifact and pipeline layers do
//! not care which decoder produced the pixels.
//!
//! JPEG lives in `jpeg.zig` for the same reason: it needs its own Huffman,
//! bit-reader and IDCT machinery, and normalizes to the same RGBA8 `Image`.
//!
//! Not yet supported (honest limitations, rejected rather than faked): compressed
//! BMP, palette/indexed TGA and HDR. These remain `raw` imports until dedicated
//! decoders exist.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DecodeError = error{
    /// The source bytes are not a valid image of the expected format.
    InvalidImage,
    OutOfMemory,
};

/// Maximum width/height accepted from a source file (a sane GPU texture bound).
pub const max_dimension: u32 = 16384;
/// Maximum decoded pixel buffer size (matches the cache artifact ceiling).
pub const max_pixel_bytes: usize = 256 * 1024 * 1024;

/// A decoded RGBA8 image. `pixels.len == width * height * 4`.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// Validate dimensions and allocate an RGBA8 buffer, guarding overflow and the
/// size ceiling. Returns `error.InvalidImage` for out-of-range sizes. Shared by
/// every decoder in this subsystem (including `png.zig`) so the bounds policy
/// lives in exactly one place. The caller owns the returned buffer.
pub fn allocPixels(gpa: Allocator, width: u32, height: u32) DecodeError![]u8 {
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > max_dimension or height > max_dimension) return error.InvalidImage;
    const count = @as(usize, width) * @as(usize, height);
    const bytes = std.math.mul(usize, count, 4) catch return error.InvalidImage;
    if (bytes > max_pixel_bytes) return error.InvalidImage;
    return gpa.alloc(u8, bytes) catch return error.OutOfMemory;
}

// --- BMP -------------------------------------------------------------------

/// Decode an uncompressed BMP (`BI_RGB`, 24 or 32 bpp). 24-bit pixels are BGR
/// with rows padded to a 4-byte boundary; 32-bit pixels are BGRA (the fourth
/// byte is taken as alpha). A negative height means top-down rows; otherwise
/// rows are bottom-up and are flipped to top-down on output.
pub fn decodeBmp(gpa: Allocator, source: []const u8) DecodeError!Image {
    if (source.len < 54) return error.InvalidImage; // 14-byte file header + 40-byte DIB
    if (source[0] != 'B' or source[1] != 'M') return error.InvalidImage;

    const data_offset = std.mem.readInt(u32, source[10..14], .little);
    const dib_size = std.mem.readInt(u32, source[14..18], .little);
    if (dib_size < 40) return error.InvalidImage;

    const width_i = std.mem.readInt(i32, source[18..22], .little);
    const height_i = std.mem.readInt(i32, source[22..26], .little);
    const planes = std.mem.readInt(u16, source[26..28], .little);
    const bit_count = std.mem.readInt(u16, source[28..30], .little);
    const compression = std.mem.readInt(u32, source[30..34], .little);

    if (planes != 1) return error.InvalidImage;
    if (compression != 0) return error.InvalidImage; // BI_RGB only
    if (bit_count != 24 and bit_count != 32) return error.InvalidImage;

    const w64: i64 = width_i;
    const h64: i64 = height_i;
    if (w64 <= 0 or h64 == 0) return error.InvalidImage;
    const top_down = h64 < 0;
    const aw: u64 = @intCast(w64);
    const ah: u64 = @intCast(@abs(h64));
    if (aw > max_dimension or ah > max_dimension) return error.InvalidImage;
    const width: u32 = @intCast(aw);
    const height: u32 = @intCast(ah);

    const bpp: usize = if (bit_count == 24) 3 else 4;
    const row_bytes = @as(usize, width) * bpp;
    const stride = (row_bytes + 3) & ~@as(usize, 3);
    const total = std.math.mul(usize, stride, height) catch return error.InvalidImage;
    const off: usize = data_offset;
    if (off > source.len or total > source.len - off) return error.InvalidImage;
    const data = source[off..];

    var img = Image{ .width = width, .height = height, .pixels = try allocPixels(gpa, width, height) };
    errdefer gpa.free(img.pixels);

    const dst_row_bytes = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row: usize = if (top_down) y else height - 1 - y;
        const row = data[src_row * stride ..][0..row_bytes];
        const dst = img.pixels[@as(usize, y) * dst_row_bytes ..][0..dst_row_bytes];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const s = @as(usize, x) * bpp;
            const d = @as(usize, x) * 4;
            dst[d + 0] = row[s + 2]; // R
            dst[d + 1] = row[s + 1]; // G
            dst[d + 2] = row[s + 0]; // B
            dst[d + 3] = if (bpp == 4) row[s + 3] else 255;
        }
    }
    return img;
}

// --- TGA -------------------------------------------------------------------

/// Decode a true-color TGA (image type 2 = uncompressed, 10 = RLE), 24 or 32
/// bpp. Pixels are BGR(A); bit 5 of the image descriptor selects top-down rows.
/// Palette/color-mapped and grayscale types are rejected.
pub fn decodeTga(gpa: Allocator, source: []const u8) DecodeError!Image {
    if (source.len < 18) return error.InvalidImage;
    const id_len: usize = source[0];
    const cmap_type = source[1];
    const img_type = source[2];
    const width = std.mem.readInt(u16, source[12..14], .little);
    const height = std.mem.readInt(u16, source[14..16], .little);
    const depth = source[16];
    const descriptor = source[17];

    if (img_type != 2 and img_type != 10) return error.InvalidImage;
    if (cmap_type != 0) return error.InvalidImage;
    if (depth != 24 and depth != 32) return error.InvalidImage;
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > max_dimension or height > max_dimension) return error.InvalidImage;

    const top_down = (descriptor & 0x20) != 0;
    const bpp: usize = if (depth == 24) 3 else 4;

    // Skip the image ID and any color map (none for true-color, but honor it).
    const cmap_len: usize = std.mem.readInt(u16, source[5..7], .little);
    const cmap_entry_bits: usize = source[7];
    const cmap_bytes = cmap_len * ((cmap_entry_bits + 7) / 8);
    var pos: usize = 18 + id_len + cmap_bytes;
    if (pos > source.len) return error.InvalidImage;

    const w: usize = width;
    const count = w * @as(usize, height);
    var img = Image{ .width = width, .height = height, .pixels = try allocPixels(gpa, width, height) };
    errdefer gpa.free(img.pixels);

    if (img_type == 2) {
        const need = std.math.mul(usize, count, bpp) catch return error.InvalidImage;
        if (need > source.len - pos) return error.InvalidImage;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const px = source[pos + i * bpp ..][0..bpp];
            writeTgaPixel(&img, i, top_down, px, bpp);
        }
    } else {
        var i: usize = 0;
        while (i < count) {
            if (pos >= source.len) return error.InvalidImage;
            const packet = source[pos];
            pos += 1;
            const run = @as(usize, packet & 0x7F) + 1;
            if (i + run > count) return error.InvalidImage;
            if (packet & 0x80 != 0) {
                if (pos + bpp > source.len) return error.InvalidImage;
                const px = source[pos..][0..bpp];
                pos += bpp;
                var j: usize = 0;
                while (j < run) : (j += 1) {
                    writeTgaPixel(&img, i, top_down, px, bpp);
                    i += 1;
                }
            } else {
                const need = std.math.mul(usize, run, bpp) catch return error.InvalidImage;
                if (need > source.len - pos) return error.InvalidImage;
                var j: usize = 0;
                while (j < run) : (j += 1) {
                    const px = source[pos..][0..bpp];
                    pos += bpp;
                    writeTgaPixel(&img, i, top_down, px, bpp);
                    i += 1;
                }
            }
        }
    }
    return img;
}

/// Map a linear file-order pixel index to its top-down RGBA8 destination.
fn writeTgaPixel(img: *Image, i: usize, top_down: bool, px: []const u8, bpp: usize) void {
    const w: usize = img.width;
    const h: usize = img.height;
    const file_row = i / w;
    const col = i % w;
    const dest_row = if (top_down) file_row else h - 1 - file_row;
    const d = (dest_row * w + col) * 4;
    img.pixels[d + 0] = px[2]; // R
    img.pixels[d + 1] = px[1]; // G
    img.pixels[d + 2] = px[0]; // B
    img.pixels[d + 3] = if (bpp == 4) px[3] else 255;
}

// --- QOI -------------------------------------------------------------------
// Quite OK Image format: https://qoiformat.org/qoi-specification.pdf

fn qoiHash(r: u8, g: u8, b: u8, a: u8) usize {
    return (@as(usize, r) * 3 + @as(usize, g) * 5 + @as(usize, b) * 7 + @as(usize, a) * 11) % 64;
}

/// Wrapping u8 add used by QOI DIFF/LUMA (arithmetic is modulo 256).
fn addWrap(v: u8, delta: i32) u8 {
    return @truncate(@as(u32, @bitCast(@as(i32, v) + delta)));
}

/// Decode a QOI stream to RGBA8.
pub fn decodeQoi(gpa: Allocator, source: []const u8) DecodeError!Image {
    if (source.len < 14) return error.InvalidImage;
    if (!std.mem.eql(u8, source[0..4], "qoif")) return error.InvalidImage;
    const width = std.mem.readInt(u32, source[4..8], .big);
    const height = std.mem.readInt(u32, source[8..12], .big);
    const channels = source[12];
    const colorspace = source[13];
    if (channels != 3 and channels != 4) return error.InvalidImage;
    if (colorspace > 1) return error.InvalidImage;
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > max_dimension or height > max_dimension) return error.InvalidImage;

    const count = @as(usize, width) * @as(usize, height);
    var img = Image{ .width = width, .height = height, .pixels = try allocPixels(gpa, width, height) };
    errdefer gpa.free(img.pixels);

    var index = std.mem.zeroes([64][4]u8);
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;
    var pos: usize = 14;
    const end = source.len;
    var i: usize = 0;

    while (i < count) {
        if (pos >= end) return error.InvalidImage;
        const b1 = source[pos];
        pos += 1;
        var run: usize = 1;

        if (b1 == 0xFE) { // QOI_OP_RGB
            if (pos + 3 > end) return error.InvalidImage;
            r = source[pos];
            g = source[pos + 1];
            b = source[pos + 2];
            pos += 3;
        } else if (b1 == 0xFF) { // QOI_OP_RGBA
            if (pos + 4 > end) return error.InvalidImage;
            r = source[pos];
            g = source[pos + 1];
            b = source[pos + 2];
            a = source[pos + 3];
            pos += 4;
        } else switch (b1 & 0xC0) {
            0x00 => { // QOI_OP_INDEX
                const px = index[b1 & 0x3F];
                r = px[0];
                g = px[1];
                b = px[2];
                a = px[3];
            },
            0x40 => { // QOI_OP_DIFF
                const dr = @as(i32, (b1 >> 4) & 0x03) - 2;
                const dg = @as(i32, (b1 >> 2) & 0x03) - 2;
                const db = @as(i32, b1 & 0x03) - 2;
                r = addWrap(r, dr);
                g = addWrap(g, dg);
                b = addWrap(b, db);
            },
            0x80 => { // QOI_OP_LUMA
                if (pos >= end) return error.InvalidImage;
                const b2 = source[pos];
                pos += 1;
                const dg = @as(i32, b1 & 0x3F) - 32;
                const dr = dg + (@as(i32, (b2 >> 4) & 0x0F) - 8);
                const db = dg + (@as(i32, b2 & 0x0F) - 8);
                r = addWrap(r, dr);
                g = addWrap(g, dg);
                b = addWrap(b, db);
            },
            0xC0 => { // QOI_OP_RUN
                run = @as(usize, b1 & 0x3F) + 1;
            },
            else => unreachable,
        }

        if (i + run > count) return error.InvalidImage;
        index[qoiHash(r, g, b, a)] = .{ r, g, b, a };
        var j: usize = 0;
        while (j < run) : (j += 1) {
            const d = (i + j) * 4;
            img.pixels[d + 0] = r;
            img.pixels[d + 1] = g;
            img.pixels[d + 2] = b;
            img.pixels[d + 3] = a;
        }
        i += run;
    }

    // The stream must terminate with the 8-byte end marker.
    if (pos + 8 > end) return error.InvalidImage;
    const marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    if (!std.mem.eql(u8, source[pos..][0..8], &marker)) return error.InvalidImage;
    return img;
}

/// Encode an RGBA8 image as a QOI stream (channels = 4, sRGB). Lossless; used for
/// roundtrip verification and as a future export path. Worst-case output is
/// bounded by `14 + width*height*5 + 8` bytes.
pub fn encodeQoi(gpa: Allocator, img: Image) DecodeError![]u8 {
    const count = @as(usize, img.width) * @as(usize, img.height);
    const cap = std.math.mul(usize, count, 5) catch return error.OutOfMemory;
    const total = std.math.add(usize, cap, 14 + 8) catch return error.OutOfMemory;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, total) catch return error.OutOfMemory;

    out.appendSliceAssumeCapacity("qoif");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, img.width, .big);
    out.appendSliceAssumeCapacity(&be);
    std.mem.writeInt(u32, &be, img.height, .big);
    out.appendSliceAssumeCapacity(&be);
    out.appendAssumeCapacity(4); // channels
    out.appendAssumeCapacity(0); // colorspace: sRGB with linear alpha

    var index = std.mem.zeroes([64][4]u8);
    var prev = [4]u8{ 0, 0, 0, 255 };
    var run: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const d = i * 4;
        const px = [4]u8{ img.pixels[d], img.pixels[d + 1], img.pixels[d + 2], img.pixels[d + 3] };

        if (std.mem.eql(u8, &px, &prev)) {
            run += 1;
            if (run == 62 or i == count - 1) {
                out.appendAssumeCapacity(0xC0 | @as(u8, @intCast(run - 1)));
                run = 0;
            }
            continue;
        }
        if (run > 0) {
            out.appendAssumeCapacity(0xC0 | @as(u8, @intCast(run - 1)));
            run = 0;
        }

        const h = qoiHash(px[0], px[1], px[2], px[3]);
        if (std.mem.eql(u8, &index[h], &px)) {
            out.appendAssumeCapacity(@as(u8, @intCast(h)));
        } else {
            index[h] = px;
            if (px[3] == prev[3]) {
                const dr = @as(i32, px[0]) - @as(i32, prev[0]);
                const dg = @as(i32, px[1]) - @as(i32, prev[1]);
                const db = @as(i32, px[2]) - @as(i32, prev[2]);
                const dr_dg = dr - dg;
                const db_dg = db - dg;
                if (dr >= -2 and dr <= 1 and dg >= -2 and dg <= 1 and db >= -2 and db <= 1) {
                    const byte = 0x40 |
                        (@as(u8, @intCast(dr + 2)) << 4) |
                        (@as(u8, @intCast(dg + 2)) << 2) |
                        @as(u8, @intCast(db + 2));
                    out.appendAssumeCapacity(byte);
                } else if (dg >= -32 and dg <= 31 and dr_dg >= -8 and dr_dg <= 7 and db_dg >= -8 and db_dg <= 7) {
                    out.appendAssumeCapacity(0x80 | @as(u8, @intCast(dg + 32)));
                    out.appendAssumeCapacity((@as(u8, @intCast(dr_dg + 8)) << 4) | @as(u8, @intCast(db_dg + 8)));
                } else {
                    out.appendAssumeCapacity(0xFE);
                    out.appendAssumeCapacity(px[0]);
                    out.appendAssumeCapacity(px[1]);
                    out.appendAssumeCapacity(px[2]);
                }
            } else {
                out.appendAssumeCapacity(0xFF);
                out.appendSliceAssumeCapacity(&px);
            }
        }
        prev = px;
    }

    out.appendSliceAssumeCapacity(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 });
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const alloc_probe = @import("../core/alloc_probe.zig");

fn expectPixel(img: Image, x: u32, y: u32, rgba: [4]u8) !void {
    const d = (@as(usize, y) * img.width + x) * 4;
    try testing.expectEqualSlices(u8, &rgba, img.pixels[d..][0..4]);
}

// A tiny hand-built 2x2 24-bit bottom-up BMP. Pixels (top-down view):
//   (0,0)=red (1,0)=green / (0,1)=blue (1,1)=white
fn bmp24Fixture() [54 + 16]u8 {
    var b = std.mem.zeroes([70]u8);
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[10..14], 54, .little); // data offset
    std.mem.writeInt(u32, b[14..18], 40, .little); // DIB size
    std.mem.writeInt(i32, b[18..22], 2, .little); // width
    std.mem.writeInt(i32, b[22..26], 2, .little); // height (bottom-up)
    std.mem.writeInt(u16, b[26..28], 1, .little); // planes
    std.mem.writeInt(u16, b[28..30], 24, .little); // bpp
    // stride = 2*3 = 6 -> padded to 8. Bottom row first (image y=1): blue, white.
    b[54] = 255; // B of blue
    b[55] = 0;
    b[56] = 0; // R of blue
    b[57] = 255; // B of white
    b[58] = 255;
    b[59] = 255;
    // row padding b[60], b[61] = 0
    // Top row (image y=0): red, green.
    b[62] = 0; // B of red
    b[63] = 0;
    b[64] = 255; // R of red
    b[65] = 0; // B of green
    b[66] = 255; // G of green
    b[67] = 0;
    return b;
}

test "bmp: decodes 24-bit bottom-up with row padding and BGR order" {
    const src = bmp24Fixture();
    var img = try decodeBmp(testing.allocator, &src);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try expectPixel(img, 0, 0, .{ 255, 0, 0, 255 }); // red
    try expectPixel(img, 1, 0, .{ 0, 255, 0, 255 }); // green
    try expectPixel(img, 0, 1, .{ 0, 0, 255, 255 }); // blue
    try expectPixel(img, 1, 1, .{ 255, 255, 255, 255 }); // white
}

test "bmp: decodes 32-bit top-down with alpha" {
    var b = std.mem.zeroes([70]u8);
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 2, .little);
    std.mem.writeInt(i32, b[22..26], -2, .little); // top-down
    std.mem.writeInt(u16, b[26..28], 1, .little);
    std.mem.writeInt(u16, b[28..30], 32, .little);
    // row 0: (B=10,G=20,R=30,A=40), (B=50,G=60,R=70,A=80)
    b[54] = 10;
    b[55] = 20;
    b[56] = 30;
    b[57] = 40;
    b[58] = 50;
    b[59] = 60;
    b[60] = 70;
    b[61] = 80;
    var img = try decodeBmp(testing.allocator, &b);
    defer img.deinit(testing.allocator);
    try expectPixel(img, 0, 0, .{ 30, 20, 10, 40 });
    try expectPixel(img, 1, 0, .{ 70, 60, 50, 80 });
}

test "bmp: rejects bad magic, compression, bpp and truncation" {
    var src = bmp24Fixture();
    src[0] = 'X';
    try testing.expectError(error.InvalidImage, decodeBmp(testing.allocator, &src));
    src[0] = 'B';
    std.mem.writeInt(u32, src[30..34], 1, .little); // BI_RLE8
    try testing.expectError(error.InvalidImage, decodeBmp(testing.allocator, &src));
    std.mem.writeInt(u32, src[30..34], 0, .little);
    std.mem.writeInt(u16, src[28..30], 16, .little); // unsupported bpp
    try testing.expectError(error.InvalidImage, decodeBmp(testing.allocator, &src));
    try testing.expectError(error.InvalidImage, decodeBmp(testing.allocator, src[0..40])); // truncated
}

test "bmp: rejects a data offset beyond the file" {
    var src = bmp24Fixture();
    std.mem.writeInt(u32, src[10..14], 10000, .little);
    try testing.expectError(error.InvalidImage, decodeBmp(testing.allocator, &src));
}

// Build a TGA fixture. `rle` selects image type 10 vs 2.
fn tgaFixture(width: u16, height: u16, depth: u8, top_down: bool, pixels: []const u8, rle: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    const header = [_]u8{
        0, // id length
        0, // no color map
        if (rle) 10 else 2, // image type
        0, 0, 0, 0, 0, // color map spec
        0, 0, // x origin
        0,                       0, // y origin
        @intCast(width & 0xFF),  @intCast(width >> 8),
        @intCast(height & 0xFF), @intCast(height >> 8),
        depth,                   if (top_down) 0x20 else 0x00,
    };
    try out.appendSlice(testing.allocator, &header);
    try out.appendSlice(testing.allocator, pixels);
    return out.toOwnedSlice(testing.allocator);
}

test "tga: decodes uncompressed 24-bit bottom-up" {
    // 2x1, bottom-up: file row is image bottom row. BGR: blue, red.
    const pixels = [_]u8{ 255, 0, 0, 0, 0, 255 };
    const src = try tgaFixture(2, 1, 24, false, &pixels, false);
    defer testing.allocator.free(src);
    var img = try decodeTga(testing.allocator, src);
    defer img.deinit(testing.allocator);
    try expectPixel(img, 0, 0, .{ 0, 0, 255, 255 }); // blue
    try expectPixel(img, 1, 0, .{ 255, 0, 0, 255 }); // red
}

test "tga: decodes uncompressed 32-bit top-down with alpha" {
    const pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const src = try tgaFixture(2, 1, 32, true, &pixels, false);
    defer testing.allocator.free(src);
    var img = try decodeTga(testing.allocator, src);
    defer img.deinit(testing.allocator);
    try expectPixel(img, 0, 0, .{ 30, 20, 10, 40 });
    try expectPixel(img, 1, 0, .{ 70, 60, 50, 80 });
}

test "tga: decodes RLE packets (run + literal)" {
    // 4x1 top-down 24-bit: run of 3 red, then 1 literal green.
    const pixels = [_]u8{
        0x82, 0, 0, 255, // RLE packet: count=3, BGR red
        0x00, 0, 255, 0, // raw packet: count=1, BGR green
    };
    const src = try tgaFixture(4, 1, 24, true, &pixels, true);
    defer testing.allocator.free(src);
    var img = try decodeTga(testing.allocator, src);
    defer img.deinit(testing.allocator);
    try expectPixel(img, 0, 0, .{ 255, 0, 0, 255 });
    try expectPixel(img, 1, 0, .{ 255, 0, 0, 255 });
    try expectPixel(img, 2, 0, .{ 255, 0, 0, 255 });
    try expectPixel(img, 3, 0, .{ 0, 255, 0, 255 });
}

test "tga: rejects color-mapped, grayscale and truncated input" {
    const pixels = [_]u8{ 0, 0, 255 };
    const src = try tgaFixture(1, 1, 24, true, &pixels, false);
    defer testing.allocator.free(src);
    var bad = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(bad);
    bad[1] = 1; // color map present
    try testing.expectError(error.InvalidImage, decodeTga(testing.allocator, bad));
    bad[1] = 0;
    bad[2] = 3; // grayscale
    try testing.expectError(error.InvalidImage, decodeTga(testing.allocator, bad));
    try testing.expectError(error.InvalidImage, decodeTga(testing.allocator, src[0..10]));
}

test "tga: rejects an RLE run that overruns the pixel count" {
    const pixels = [_]u8{ 0x83, 0, 0, 255 }; // run of 4 into a 2x1 image
    const src = try tgaFixture(2, 1, 24, true, &pixels, true);
    defer testing.allocator.free(src);
    try testing.expectError(error.InvalidImage, decodeTga(testing.allocator, src));
}

fn makeImage(width: u32, height: u32, fill: fn (usize, usize) [4]u8) !Image {
    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * height * 4);
    errdefer testing.allocator.free(pixels);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px = fill(x, y);
            const d = (y * width + x) * 4;
            @memcpy(pixels[d..][0..4], &px);
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

test "qoi: encode/decode roundtrip preserves a gradient with alpha" {
    var img = try makeImage(64, 48, struct {
        fn f(x: usize, y: usize) [4]u8 {
            return .{
                @intCast((x * 4) % 256),
                @intCast((y * 5) % 256),
                @intCast((x + y) % 256),
                @intCast((x * y) % 256),
            };
        }
    }.f);
    defer img.deinit(testing.allocator);

    const encoded = try encodeQoi(testing.allocator, img);
    defer testing.allocator.free(encoded);
    var decoded = try decodeQoi(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(img.width, decoded.width);
    try testing.expectEqual(img.height, decoded.height);
    try testing.expectEqualSlices(u8, img.pixels, decoded.pixels);
}

test "qoi: roundtrip exercises runs, index, diff, luma and rgba chunks" {
    // A mix of solid runs (RUN), repeated colors (INDEX), small deltas (DIFF),
    // medium deltas (LUMA) and alpha changes (RGBA).
    var img = try makeImage(32, 32, struct {
        fn f(x: usize, y: usize) [4]u8 {
            if (y < 8) return .{ 200, 100, 50, 255 }; // solid run
            if (y < 16) return .{ @intCast(200 + (x % 3)), 100, 50, 255 }; // diff
            if (y < 24) return .{ @intCast(100 + x), @intCast(80 + x), @intCast(60 + x), 255 }; // luma
            return .{ @intCast(x * 8 % 256), @intCast(y * 8 % 256), 0, @intCast(x % 2 * 255) }; // rgba
        }
    }.f);
    defer img.deinit(testing.allocator);
    const encoded = try encodeQoi(testing.allocator, img);
    defer testing.allocator.free(encoded);
    var decoded = try decodeQoi(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, img.pixels, decoded.pixels);
}

test "qoi: decodes a known single-pixel RGB stream" {
    // 1x1, channels=4, one QOI_OP_RGB chunk (255,0,0), then end marker.
    const src = [_]u8{
        'q', 'o', 'i', 'f',
        0, 0, 0, 1, // width
        0, 0, 0, 1, // height
        4, 0, // channels, colorspace
        0xFE, 255, 0, 0, // RGB red
        0,    0,   0, 0,
        0, 0, 0, 1, // end marker
    };
    var img = try decodeQoi(testing.allocator, &src);
    defer img.deinit(testing.allocator);
    try expectPixel(img, 0, 0, .{ 255, 0, 0, 255 });
}

test "qoi: rejects bad magic, channels, truncation and missing end marker" {
    const src = [_]u8{
        'q',  'o', 'i', 'f', 0, 0, 0, 1, 0, 0, 0, 1, 4, 0,
        0xFE, 255, 0,   0,   0, 0, 0, 0, 0, 0, 0, 1,
    };
    var bad = try testing.allocator.dupe(u8, &src);
    defer testing.allocator.free(bad);
    bad[0] = 'x';
    try testing.expectError(error.InvalidImage, decodeQoi(testing.allocator, bad));
    bad[0] = 'q';
    bad[12] = 5; // invalid channels
    try testing.expectError(error.InvalidImage, decodeQoi(testing.allocator, bad));
    bad[12] = 4;
    try testing.expectError(error.InvalidImage, decodeQoi(testing.allocator, bad[0 .. bad.len - 1])); // no marker
    try testing.expectError(error.InvalidImage, decodeQoi(testing.allocator, src[0..10])); // truncated header
}

test "image: decoders survive allocation failure" {
    try alloc_probe.check(
        struct {
            fn f(alloc: Allocator) !void {
                const bmp = bmp24Fixture();
                var a = try decodeBmp(alloc, &bmp);
                a.deinit(alloc);
                const qoi_src = [_]u8{
                    'q',  'o', 'i', 'f', 0,    0, 0, 2, 0, 0, 0, 1, 4, 0,
                    0xFE, 1,   2,   3,   0xC0, 0, 0, 0, 0, 0, 0, 0, 1,
                };
                var b = try decodeQoi(alloc, &qoi_src);
                b.deinit(alloc);
            }
        }.f,
        .{},
    );
}

test "image: allocPixels rejects zero and oversized dimensions" {
    try testing.expectError(error.InvalidImage, allocPixels(testing.allocator, 0, 4));
    try testing.expectError(error.InvalidImage, allocPixels(testing.allocator, 4, 0));
    try testing.expectError(error.InvalidImage, allocPixels(testing.allocator, max_dimension + 1, 1));
    try testing.expectError(error.InvalidImage, allocPixels(testing.allocator, max_dimension, max_dimension));
}
