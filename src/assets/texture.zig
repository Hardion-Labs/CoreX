//! Engine-ready texture artifact (`CXTX`) and texture importers.
//!
//! The importers decode a source image (BMP/TGA/QOI in `image.zig`, PNG in
//! `png.zig`, JPEG in `jpeg.zig`) to RGBA8 and serialize it into a self-describing `CXTX` container
//! that the renderer can upload directly without re-parsing the source format. The container is
//! the derived artifact stored in the content-addressed cache; its identity is
//! the importer `id` + `version`, so changing the layout and bumping the version
//! invalidates affected cache entries automatically.
//!
//! Layout (little-endian):
//!   bytes 0..4   magic "CXTX"
//!   bytes 4..8   format_version (u32)
//!   bytes 8..12  width  (u32)
//!   bytes 12..16 height (u32)
//!   bytes 16..20 pixel_format (u32, 0 = RGBA8)
//!   bytes 20..   width*height*4 RGBA8 pixels (row-major, top-down)
//!
//! `parse` is zero-copy: it returns a view into the artifact bytes, which the
//! caller owns. This module depends only on `std`, `image.zig` and `importer.zig`
//! (all standard-library-only), so it stays independently testable.

const std = @import("std");
const image = @import("image.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const ImportError = importer.ImportError;
const Importer = importer.Importer;

pub const format_version: u32 = 1;
pub const magic = "CXTX";
pub const header_size: usize = 20;

/// Pixel layouts understood by the renderer. Only RGBA8 exists today; HDR and
/// compressed formats are future work and are rejected, not faked.
pub const PixelFormat = enum(u32) {
    rgba8 = 0,
};

/// A parsed, zero-copy view into a `CXTX` artifact. The caller owns the backing
/// bytes; this struct holds no allocation of its own.
pub const Texture = struct {
    width: u32,
    height: u32,
    pixel_format: PixelFormat,
    pixels: []const u8,
};

/// Serialize an RGBA8 image into a `CXTX` artifact. The caller frees the result.
pub fn serialize(gpa: Allocator, img: image.Image) ImportError![]u8 {
    const count = @as(usize, img.width) * @as(usize, img.height);
    const pixel_bytes = std.math.mul(usize, count, 4) catch return error.InvalidAsset;
    if (img.pixels.len != pixel_bytes) return error.InvalidAsset;
    const total = std.math.add(usize, pixel_bytes, header_size) catch return error.InvalidAsset;

    const out = gpa.alloc(u8, total) catch return error.OutOfMemory;
    errdefer gpa.free(out);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], format_version, .little);
    std.mem.writeInt(u32, out[8..12], img.width, .little);
    std.mem.writeInt(u32, out[12..16], img.height, .little);
    std.mem.writeInt(u32, out[16..20], @backingInt(PixelFormat.rgba8), .little);
    @memcpy(out[header_size..], img.pixels);
    return out;
}

/// Parse a `CXTX` artifact into a zero-copy view, validating magic, version,
/// pixel format, dimensions and exact length.
pub fn parse(bytes: []const u8) error{InvalidAsset}!Texture {
    if (bytes.len < header_size) return error.InvalidAsset;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidAsset;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != format_version) return error.InvalidAsset;
    const width = std.mem.readInt(u32, bytes[8..12], .little);
    const height = std.mem.readInt(u32, bytes[12..16], .little);
    const pf = std.mem.readInt(u32, bytes[16..20], .little);
    if (pf != @backingInt(PixelFormat.rgba8)) return error.InvalidAsset;
    if (width == 0 or height == 0) return error.InvalidAsset;
    if (width > image.max_dimension or height > image.max_dimension) return error.InvalidAsset;

    const count = @as(usize, width) * @as(usize, height);
    const pixel_bytes = std.math.mul(usize, count, 4) catch return error.InvalidAsset;
    const expected = std.math.add(usize, pixel_bytes, header_size) catch return error.InvalidAsset;
    if (bytes.len != expected) return error.InvalidAsset;

    return .{
        .width = width,
        .height = height,
        .pixel_format = .rgba8,
        .pixels = bytes[header_size..],
    };
}

fn mapDecodeError(err: image.DecodeError) ImportError {
    return switch (err) {
        error.InvalidImage => error.InvalidAsset,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Decode with `decode` then serialize to a `CXTX` artifact.
fn importImage(
    gpa: Allocator,
    source: []const u8,
    comptime decode: fn (Allocator, []const u8) image.DecodeError!image.Image,
) ImportError![]u8 {
    var img = decode(gpa, source) catch |err| return mapDecodeError(err);
    defer img.deinit(gpa);
    return serialize(gpa, img);
}

pub fn importBmp(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return importImage(gpa, source, image.decodeBmp);
}

pub fn importTga(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return importImage(gpa, source, image.decodeTga);
}

pub fn importQoi(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return importImage(gpa, source, image.decodeQoi);
}

/// Decode a PNG (see `png.zig`) and serialize it to a `CXTX` artifact.
pub fn importPng(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return importImage(gpa, source, png.decode);
}

/// Decode a sequential JPEG (see `jpeg.zig`) and serialize it to a `CXTX`
/// artifact. JPEG has no alpha channel, so the artifact is fully opaque.
pub fn importJpeg(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return importImage(gpa, source, jpeg.decode);
}

pub const bmp_importer = Importer{ .id = "bmp", .version = 1, .importFn = importBmp };
pub const tga_importer = Importer{ .id = "tga", .version = 1, .importFn = importTga };
pub const qoi_importer = Importer{ .id = "qoi", .version = 1, .importFn = importQoi };
pub const png_importer = Importer{ .id = "png", .version = 1, .importFn = importPng };
pub const jpeg_importer = Importer{ .id = "jpeg", .version = 1, .importFn = importJpeg };

/// Extension bindings for the engine registry (prepended by `assets.zig`).
pub const bindings = [_]importer.Registry.Binding{
    .{ .extensions = &[_][]const u8{".png"}, .importer = png_importer },
    .{ .extensions = &[_][]const u8{ ".jpg", ".jpeg" }, .importer = jpeg_importer },
    .{ .extensions = &[_][]const u8{".bmp"}, .importer = bmp_importer },
    .{ .extensions = &[_][]const u8{".tga"}, .importer = tga_importer },
    .{ .extensions = &[_][]const u8{".qoi"}, .importer = qoi_importer },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn sampleImage() !image.Image {
    const pixels = try testing.allocator.dupe(u8, &[_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 128, // green, half alpha
        0, 0, 255, 255, // blue
        9, 8, 7, 6, // arbitrary
    });
    return .{ .width = 2, .height = 2, .pixels = pixels };
}

test "texture: serialize/parse roundtrip preserves dimensions and pixels" {
    var img = try sampleImage();
    defer img.deinit(testing.allocator);
    const bytes = try serialize(testing.allocator, img);
    defer testing.allocator.free(bytes);

    const tex = try parse(bytes);
    try testing.expectEqual(@as(u32, 2), tex.width);
    try testing.expectEqual(@as(u32, 2), tex.height);
    try testing.expectEqual(PixelFormat.rgba8, tex.pixel_format);
    try testing.expectEqualSlices(u8, img.pixels, tex.pixels);
    try testing.expectEqual(bytes.len, header_size + img.pixels.len);
}

test "texture: parse rejects bad magic, version, format, dims and length" {
    var img = try sampleImage();
    defer img.deinit(testing.allocator);
    const bytes = try serialize(testing.allocator, img);
    defer testing.allocator.free(bytes);

    var bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);

    bad[0] = 'X';
    try testing.expectError(error.InvalidAsset, parse(bad));
    bad[0] = 'C';

    std.mem.writeInt(u32, bad[4..8], 99, .little); // bad version
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[4..8], format_version, .little);

    std.mem.writeInt(u32, bad[16..20], 7, .little); // bad pixel format
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[16..20], 0, .little);

    std.mem.writeInt(u32, bad[8..12], 0, .little); // zero width
    try testing.expectError(error.InvalidAsset, parse(bad));

    try testing.expectError(error.InvalidAsset, parse(bytes[0 .. bytes.len - 1])); // truncated
    try testing.expectError(error.InvalidAsset, parse(bytes[0..10])); // short header
}

test "texture: importBmp produces a valid CXTX artifact" {
    // Reuse the BMP fixture shape: 2x2 24-bit bottom-up.
    var b = std.mem.zeroes([70]u8);
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 2, .little);
    std.mem.writeInt(i32, b[22..26], 2, .little);
    std.mem.writeInt(u16, b[26..28], 1, .little);
    std.mem.writeInt(u16, b[28..30], 24, .little);
    b[54] = 255; // blue (bottom row)
    b[62] = 0;
    b[63] = 0;
    b[64] = 255; // red (top row)

    const bytes = try importBmp(testing.allocator, &b);
    defer testing.allocator.free(bytes);
    const tex = try parse(bytes);
    try testing.expectEqual(@as(u32, 2), tex.width);
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, tex.pixels[0..4]); // top-left red
}

test "texture: importQoi roundtrips through the artifact" {
    var img = try sampleImage();
    defer img.deinit(testing.allocator);
    const qoi = try image.encodeQoi(testing.allocator, img);
    defer testing.allocator.free(qoi);

    const bytes = try importQoi(testing.allocator, qoi);
    defer testing.allocator.free(bytes);
    const tex = try parse(bytes);
    try testing.expectEqualSlices(u8, img.pixels, tex.pixels);
}

test "texture: importers reject invalid sources" {
    try testing.expectError(error.InvalidAsset, importBmp(testing.allocator, "not a bmp"));
    try testing.expectError(error.InvalidAsset, importTga(testing.allocator, "no"));
    try testing.expectError(error.InvalidAsset, importQoi(testing.allocator, "nope"));
    try testing.expectError(error.InvalidAsset, importPng(testing.allocator, "not a png"));
}

test "texture: bindings select the right importer by extension" {
    const reg = importer.Registry{ .bindings = &bindings, .fallback = importer.raw_importer };
    try testing.expectEqualStrings("bmp", reg.select(".bmp").id);
    try testing.expectEqualStrings("tga", reg.select(".TGA").id);
    try testing.expectEqualStrings("qoi", reg.select(".qoi").id);
    try testing.expectEqualStrings("png", reg.select(".png").id);
    try testing.expectEqualStrings("png", reg.select(".PNG").id);
    try testing.expectEqualStrings("jpeg", reg.select(".jpg").id);
    try testing.expectEqualStrings("jpeg", reg.select(".JPEG").id);
    try testing.expectEqualStrings("raw", reg.select(".gif").id);
}

test "texture: serialize and import survive allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
            const img = image.Image{ .width = 2, .height = 1, .pixels = @constCast(&pixels) };
            const bytes = try serialize(alloc, img);
            alloc.free(bytes);
        }
    }.f, .{});
}

test "texture: importPng produces a CXTX artifact with the reference pixels" {
    const gpa = testing.allocator;
    const vectors = @import("png_vectors.zig");
    for (vectors.valid) |vector| {
        const source = try gpa.alloc(u8, vector.png_hex.len / 2);
        defer gpa.free(source);
        _ = try std.fmt.hexToBytes(source, vector.png_hex);
        const expected = try gpa.alloc(u8, vector.rgba_hex.len / 2);
        defer gpa.free(expected);
        _ = try std.fmt.hexToBytes(expected, vector.rgba_hex);

        const bytes = try importPng(gpa, source);
        defer gpa.free(bytes);
        const tex = try parse(bytes);
        try testing.expectEqual(vector.width, tex.width);
        try testing.expectEqual(vector.height, tex.height);
        try testing.expectEqual(PixelFormat.rgba8, tex.pixel_format);
        try testing.expectEqualSlices(u8, expected, tex.pixels);
    }
}

test "texture: importPng survives allocation failure" {
    const gpa = testing.allocator;
    const vectors = @import("png_vectors.zig");
    const source = try gpa.alloc(u8, vectors.valid[0].png_hex.len / 2);
    defer gpa.free(source);
    _ = try std.fmt.hexToBytes(source, vectors.valid[0].png_hex);
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator, bytes_in: []const u8) !void {
            const bytes = try importPng(alloc, bytes_in);
            alloc.free(bytes);
        }
    }.f, .{source});
}

test "texture: importJpeg produces an opaque CXTX artifact" {
    const gpa = testing.allocator;
    const vectors = @import("jpeg_vectors.zig");
    for (vectors.valid) |vector| {
        const source = try gpa.alloc(u8, vector.jpg_hex.len / 2);
        defer gpa.free(source);
        _ = try std.fmt.hexToBytes(source, vector.jpg_hex);

        const bytes = try importJpeg(gpa, source);
        defer gpa.free(bytes);
        const tex = try parse(bytes);
        try testing.expectEqual(vector.width, tex.width);
        try testing.expectEqual(vector.height, tex.height);
        try testing.expectEqual(PixelFormat.rgba8, tex.pixel_format);
        try testing.expectEqual(@as(usize, vector.width) * @as(usize, vector.height) * 4, tex.pixels.len);
        // The artifact must round-trip through the container unchanged, and
        // JPEG's lack of a colour key means every alpha byte is opaque.
        var direct = try jpeg.decode(gpa, source);
        defer direct.deinit(gpa);
        try testing.expectEqualSlices(u8, direct.pixels, tex.pixels);
        var i: usize = 3;
        while (i < tex.pixels.len) : (i += 4) try testing.expectEqual(@as(u8, 255), tex.pixels[i]);
    }
}

test "texture: importJpeg rejects malformed and unsupported sources" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidAsset, importJpeg(gpa, "not a jpeg"));
    const vectors = @import("jpeg_vectors.zig");
    for (vectors.unsupported) |vector| {
        const source = try gpa.alloc(u8, vector.jpg_hex.len / 2);
        defer gpa.free(source);
        _ = try std.fmt.hexToBytes(source, vector.jpg_hex);
        try testing.expectError(error.InvalidAsset, importJpeg(gpa, source));
    }
}

test "texture: importJpeg survives allocation failure" {
    const gpa = testing.allocator;
    const vectors = @import("jpeg_vectors.zig");
    const source = try gpa.alloc(u8, vectors.valid[8].jpg_hex.len / 2);
    defer gpa.free(source);
    _ = try std.fmt.hexToBytes(source, vectors.valid[8].jpg_hex);
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator, bytes_in: []const u8) !void {
            const bytes = try importJpeg(alloc, bytes_in);
            alloc.free(bytes);
        }
    }.f, .{source});
}
