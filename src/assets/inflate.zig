//! DEFLATE (RFC 1951) and zlib (RFC 1950) decompression.
//!
//! This is the dependency-free foundation the PNG decoder needs; it is also a
//! general-purpose facility for any future compressed container. It implements
//! the complete DEFLATE format: stored blocks, fixed-Huffman blocks and
//! dynamic-Huffman blocks, with canonical code construction, length/distance
//! back-references and multi-block streams.
//!
//! Design notes (performance and safety):
//! - Huffman decoding is O(1) per symbol through a flat lookup table indexed by
//!   the next `max_code_length` bits, instead of walking a tree bit by bit. The
//!   table is rebuilt in place per block (one bounded allocation per tree, reused
//!   across blocks via `realloc`).
//! - The bit reader keeps a 64-bit accumulator and refills whole bytes, so the
//!   inner loop does not touch memory per bit. Bits above the valid count are
//!   always zero, which makes a short peek at end-of-stream safe: a symbol whose
//!   code length exceeds the bits actually available is rejected.
//! - Output growth is bounded by the caller's `max_output_bytes` *exactly* (both
//!   length and capacity), so a decompression bomb cannot exhaust memory.
//! - Every read is bounds-checked and every back-reference is validated against
//!   the bytes already produced; malformed input yields `error.InvalidStream`,
//!   never an out-of-bounds access.
//!
//! Ownership: the returned buffer is allocated with the passed allocator and
//! owned by the caller. This module depends only on `std`.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InflateError = error{
    /// The compressed stream is malformed, truncated or uses an illegal code.
    InvalidStream,
    /// The decoded data would exceed the caller's `max_output_bytes` bound.
    OutputTooLarge,
    OutOfMemory,
};

/// Largest back-reference distance allowed by DEFLATE (32 KiB window).
pub const max_window: usize = 32768;

/// Decompress a raw DEFLATE stream (no zlib header/trailer). The caller owns the
/// returned bytes. At most `max_output_bytes` are produced; exceeding that bound
/// is `error.OutputTooLarge` rather than an unbounded allocation.
pub fn inflate(gpa: Allocator, source: []const u8, max_output_bytes: usize) InflateError![]u8 {
    return run(gpa, source, max_output_bytes, false);
}

/// Decompress a zlib stream (RFC 1950): validates the 2-byte header, inflates the
/// DEFLATE payload and verifies the trailing Adler-32 checksum of the decoded
/// data. Preset dictionaries (`FDICT`) are rejected: they are not used by PNG or
/// by any format this engine imports.
pub fn zlibInflate(gpa: Allocator, source: []const u8, max_output_bytes: usize) InflateError![]u8 {
    return run(gpa, source, max_output_bytes, true);
}

/// Adler-32 checksum (RFC 1950) of `data`.
pub fn adler32(data: []const u8) u32 {
    const base: u32 = 65521;
    const nmax: usize = 5552; // largest run that cannot overflow u32
    var a: u32 = 1;
    var b: u32 = 0;
    var i: usize = 0;
    while (i < data.len) {
        const end = @min(i + nmax, data.len);
        while (i < end) : (i += 1) {
            a += data[i];
            b += a;
        }
        a %= base;
        b %= base;
    }
    return (b << 16) | a;
}

// --- bit reader ------------------------------------------------------------

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    /// Number of valid bits in `acc` (bits at or above this index are zero).
    count: u7 = 0,

    fn refill(self: *BitReader) void {
        while (self.count <= 56 and self.pos < self.data.len) {
            self.acc |= @as(u64, self.data[self.pos]) << @intCast(self.count);
            self.pos += 1;
            self.count += 8;
        }
    }

    /// Low `n` bits of the accumulator. Bits beyond `count` read as zero, so this
    /// is safe even near the end of the stream; callers must check `count` before
    /// consuming the result.
    fn peek(self: *BitReader, n: u6) u32 {
        if (n == 0) return 0;
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        return @truncate(self.acc & mask);
    }

    fn drop(self: *BitReader, n: u6) void {
        self.acc >>= @intCast(n);
        self.count -= n;
    }

    fn bits(self: *BitReader, n: u6) error{InvalidStream}!u32 {
        if (n == 0) return 0;
        self.refill();
        if (self.count < n) return error.InvalidStream;
        const value = self.peek(n);
        self.drop(n);
        return value;
    }

    /// Discard the partial byte and rewind `pos` to the first unread byte, so
    /// byte-oriented sections (stored blocks, the zlib trailer) can read directly
    /// from `data`.
    fn alignByte(self: *BitReader) void {
        const whole = self.count / 8;
        self.pos -= whole;
        self.acc = 0;
        self.count = 0;
    }
};

// --- canonical Huffman table ----------------------------------------------

/// A flat decoding table: `entries[peek(max_bits)]` packs the code length in the
/// high nibble and the symbol in the low 12 bits. A zero length marks an unused
/// (invalid) entry.
const Table = struct {
    max_bits: u4 = 0,
    entries: []u16 = &.{},

    fn deinit(self: *Table, gpa: Allocator) void {
        if (self.entries.len != 0) gpa.free(self.entries);
        self.* = .{};
    }

    /// Build the canonical code defined by `lengths` (one code length per symbol,
    /// 0 = symbol unused). Rejects over-subscribed code spaces and incomplete
    /// codes, except the single-code tree zlib emits for a distance alphabet with
    /// one symbol. An all-zero alphabet builds an empty table that fails on use,
    /// which is how a stream with no back-references is represented.
    fn build(self: *Table, gpa: Allocator, lengths: []const u8) InflateError!void {
        var counts: [16]u16 = @splat(0);
        var max_len: u4 = 0;
        var used: usize = 0;
        for (lengths) |len| {
            if (len > 15) return error.InvalidStream;
            if (len == 0) continue;
            counts[len] += 1;
            used += 1;
            if (len > max_len) max_len = @intCast(len);
        }

        if (used == 0) {
            self.entries = gpa.realloc(self.entries, 1) catch return error.OutOfMemory;
            self.entries[0] = 0;
            self.max_bits = 0;
            return;
        }

        // Kraft inequality: `left` is the number of unused codes at depth 15.
        var left: i32 = 1;
        for (1..16) |len| {
            left <<= 1;
            left -= counts[len];
            if (left < 0) return error.InvalidStream; // over-subscribed
        }
        if (left > 0 and used != 1) return error.InvalidStream; // incomplete

        const size = @as(usize, 1) << max_len;
        self.entries = gpa.realloc(self.entries, size) catch return error.OutOfMemory;
        self.max_bits = max_len;
        @memset(self.entries, 0);

        var next_code: [16]u32 = @splat(0);
        var code: u32 = 0;
        for (1..16) |len| {
            code = (code + counts[len - 1]) << 1;
            next_code[len] = code;
        }

        for (lengths, 0..) |len, symbol| {
            if (len == 0) continue;
            const canonical: u16 = @intCast(next_code[len]);
            next_code[len] += 1;
            // DEFLATE packs codes MSB-first, but the bit reader is LSB-first.
            const reversed: u16 = @bitReverse(canonical) >> @intCast(16 - len);
            const entry: u16 = (@as(u16, @intCast(len)) << 12) | @as(u16, @intCast(symbol));
            const step = @as(usize, 1) << @intCast(len);
            var index: usize = reversed;
            while (index < size) : (index += step) self.entries[index] = entry;
        }
    }

    fn decode(self: *const Table, br: *BitReader) error{InvalidStream}!u16 {
        br.refill();
        const entry = self.entries[br.peek(self.max_bits)];
        const len: u6 = @intCast(entry >> 12);
        if (len == 0 or len > br.count) return error.InvalidStream;
        br.drop(len);
        return entry & 0xFFF;
    }
};

const fixed_lit_lengths = blk: {
    var lengths: [288]u8 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    break :blk lengths;
};
/// All 32 five-bit codes are present so the table is complete; symbols 30 and 31
/// are illegal in a stream and are rejected when decoded.
const fixed_dist_lengths: [32]u8 = @splat(5);

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const code_length_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// --- output buffer ---------------------------------------------------------

/// Ensure room for `need` more bytes, never letting length or capacity exceed
/// `max_output_bytes`. Growth is geometric but clamped to the caller's bound.
fn reserve(gpa: Allocator, out: *std.ArrayList(u8), need: usize, max_output: usize) InflateError!void {
    if (need > max_output - out.items.len) return error.OutputTooLarge;
    const required = out.items.len + need;
    if (out.capacity >= required) return;
    const grown = out.capacity + out.capacity / 2 + 64;
    const target = @min(max_output, @max(required, grown));
    out.ensureTotalCapacityPrecise(gpa, target) catch return error.OutOfMemory;
}

fn storedBlock(gpa: Allocator, br: *BitReader, out: *std.ArrayList(u8), max_output: usize) InflateError!void {
    br.alignByte();
    if (br.pos + 4 > br.data.len) return error.InvalidStream;
    const len = std.mem.readInt(u16, br.data[br.pos..][0..2], .little);
    const nlen = std.mem.readInt(u16, br.data[br.pos + 2 ..][0..2], .little);
    br.pos += 4;
    if (len != ~nlen) return error.InvalidStream;
    const count: usize = len;
    if (count > br.data.len - br.pos) return error.InvalidStream;
    try reserve(gpa, out, count, max_output);
    out.appendSliceAssumeCapacity(br.data[br.pos..][0..count]);
    br.pos += count;
}

fn dynamicTables(gpa: Allocator, br: *BitReader, lit: *Table, dist: *Table) InflateError!void {
    const hlit: usize = try br.bits(5) + 257;
    const hdist: usize = try br.bits(5) + 1;
    const hclen: usize = try br.bits(4) + 4;
    if (hlit > 288 or hdist > 32) return error.InvalidStream;

    var code_lengths: [19]u8 = @splat(0);
    for (0..hclen) |i| {
        code_lengths[code_length_order[i]] = @intCast(try br.bits(3));
    }
    var cl_table: Table = .{};
    defer cl_table.deinit(gpa);
    try cl_table.build(gpa, &code_lengths);

    var lengths: [288 + 32]u8 = @splat(0);
    const total = hlit + hdist;
    var i: usize = 0;
    while (i < total) {
        const symbol = try cl_table.decode(br);
        if (symbol < 16) {
            lengths[i] = @intCast(symbol);
            i += 1;
            continue;
        }
        var repeat: usize = 0;
        var value: u8 = 0;
        switch (symbol) {
            16 => {
                if (i == 0) return error.InvalidStream;
                value = lengths[i - 1];
                repeat = 3 + try br.bits(2);
            },
            17 => repeat = 3 + try br.bits(3),
            18 => repeat = 11 + try br.bits(7),
            else => return error.InvalidStream,
        }
        if (i + repeat > total) return error.InvalidStream;
        @memset(lengths[i..][0..repeat], value);
        i += repeat;
    }

    try lit.build(gpa, lengths[0..hlit]);
    try dist.build(gpa, lengths[hlit..total]);
}

fn decodeSymbols(
    gpa: Allocator,
    br: *BitReader,
    out: *std.ArrayList(u8),
    lit: *const Table,
    dist: *const Table,
    max_output: usize,
) InflateError!void {
    while (true) {
        const symbol = try lit.decode(br);
        if (symbol < 256) {
            if (out.items.len == out.capacity) try reserve(gpa, out, 1, max_output);
            out.appendAssumeCapacity(@intCast(symbol));
            continue;
        }
        if (symbol == 256) return; // end of block
        if (symbol > 285) return error.InvalidStream;

        const li = symbol - 257;
        const length = @as(usize, length_base[li]) + try br.bits(@intCast(length_extra[li]));
        const dsymbol = try dist.decode(br);
        if (dsymbol > 29) return error.InvalidStream;
        const distance = @as(usize, distance_base[dsymbol]) + try br.bits(@intCast(distance_extra[dsymbol]));
        if (distance > out.items.len) return error.InvalidStream;

        try reserve(gpa, out, length, max_output);
        // Overlapping copy must be byte-wise: distance may be smaller than length.
        var k: usize = 0;
        while (k < length) : (k += 1) {
            out.appendAssumeCapacity(out.items[out.items.len - distance]);
        }
    }
}

fn run(gpa: Allocator, source: []const u8, max_output_bytes: usize, zlib_wrapper: bool) InflateError![]u8 {
    var br = BitReader{ .data = source };
    if (zlib_wrapper) {
        const cmf = try br.bits(8);
        const flg = try br.bits(8);
        if (cmf & 0x0F != 8) return error.InvalidStream; // compression method: deflate
        if (cmf >> 4 > 7) return error.InvalidStream; // window larger than 32 KiB
        if ((cmf * 256 + flg) % 31 != 0) return error.InvalidStream; // header check bits
        if (flg & 0x20 != 0) return error.InvalidStream; // preset dictionary unsupported
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lit: Table = .{};
    defer lit.deinit(gpa);
    var dist: Table = .{};
    defer dist.deinit(gpa);
    var fixed_loaded = false;

    while (true) {
        const final = try br.bits(1);
        const kind = try br.bits(2);
        switch (kind) {
            0 => try storedBlock(gpa, &br, &out, max_output_bytes),
            1 => {
                if (!fixed_loaded) {
                    try lit.build(gpa, &fixed_lit_lengths);
                    try dist.build(gpa, &fixed_dist_lengths);
                    fixed_loaded = true;
                }
                try decodeSymbols(gpa, &br, &out, &lit, &dist, max_output_bytes);
            },
            2 => {
                try dynamicTables(gpa, &br, &lit, &dist);
                fixed_loaded = false;
                try decodeSymbols(gpa, &br, &out, &lit, &dist, max_output_bytes);
            },
            else => return error.InvalidStream, // block type 3 is reserved
        }
        if (final == 1) break;
    }

    if (zlib_wrapper) {
        br.alignByte();
        if (br.pos + 4 > br.data.len) return error.InvalidStream;
        const expected = std.mem.readInt(u32, br.data[br.pos..][0..4], .big);
        if (adler32(out.items) != expected) return error.InvalidStream;
    }

    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const vectors = @import("png_vectors.zig");
const alloc_probe = @import("../core/alloc_probe.zig");

fn unhex(gpa: Allocator, hex: []const u8) ![]u8 {
    const bytes = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

test "inflate: raw DEFLATE stream without a zlib wrapper" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.raw_deflate_hex);
    defer gpa.free(source);
    const out = try inflate(gpa, source, 1 << 20);
    defer gpa.free(out);
    try testing.expectEqualStrings(vectors.raw_deflate_text, out);
}

test "inflate: zlib stored blocks" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.zlib_stored_hex);
    defer gpa.free(source);
    const out = try zlibInflate(gpa, source, 1 << 20);
    defer gpa.free(out);
    try testing.expectEqualStrings(vectors.zlib_stored_text, out);
}

test "inflate: zlib fixed-Huffman blocks" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.zlib_fixed_hex);
    defer gpa.free(source);
    const out = try zlibInflate(gpa, source, 1 << 20);
    defer gpa.free(out);
    try testing.expectEqual(vectors.zlib_fixed_len, out.len);
    for (out, 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @intCast((i * i + i) % 251)), byte);
    }
}

test "inflate: multi-block dynamic Huffman over a 200 KiB stream" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.zlib_pattern256_hex);
    defer gpa.free(source);
    const out = try zlibInflate(gpa, source, 1 << 20);
    defer gpa.free(out);
    try testing.expectEqual(vectors.zlib_pattern256_len, out.len);
    for (out, 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @truncate(i)), byte);
    }
}

test "inflate: multiple stored blocks are concatenated" {
    const gpa = testing.allocator;
    var payload: [700]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i % 251);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    // Block 0: BFINAL=0, BTYPE=00, then byte-aligned LEN/NLEN and raw bytes.
    try stream.append(gpa, 0x00);
    try stream.appendSlice(gpa, &[_]u8{ 0x2C, 0x01, 0xD3, 0xFE }); // LEN=300, NLEN=~300
    try stream.appendSlice(gpa, payload[0..300]);
    // Block 1: BFINAL=1, BTYPE=00, LEN=400.
    try stream.append(gpa, 0x01);
    try stream.appendSlice(gpa, &[_]u8{ 0x90, 0x01, 0x6F, 0xFE });
    try stream.appendSlice(gpa, payload[300..]);

    const out = try inflate(gpa, stream.items, 1 << 20);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, &payload, out);
}

test "inflate: rejects reserved block type, bad stored header and empty input" {
    const gpa = testing.allocator;
    // BFINAL=1, BTYPE=11 (reserved).
    try testing.expectError(error.InvalidStream, inflate(gpa, &[_]u8{0x07}, 1024));
    // Stored block whose NLEN is not the complement of LEN.
    try testing.expectError(error.InvalidStream, inflate(gpa, &[_]u8{ 0x01, 0x02, 0x00, 0x00, 0x00, 0xAA, 0xBB }, 1024));
    // Stored block that claims more bytes than remain.
    try testing.expectError(error.InvalidStream, inflate(gpa, &[_]u8{ 0x01, 0xFF, 0xFF, 0x00, 0x00 }, 1024));
    try testing.expectError(error.InvalidStream, inflate(gpa, "", 1024));
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, "", 1024));
}

test "inflate: rejects a back-reference before the start of output" {
    // Fixed-Huffman block: length symbol 257 (length 3) with distance code 0
    // (distance 1) as the very first symbol, then end-of-block.
    const stream = [_]u8{ 0x03, 0x02, 0x00 };
    try testing.expectError(error.InvalidStream, inflate(testing.allocator, &stream, 1024));
}

test "inflate: rejects an over-subscribed Huffman code space" {
    // Dynamic block header (HLIT=257, HDIST=1, HCLEN=4) whose code-length tree
    // declares three 1-bit codes, which over-subscribes the code space.
    const stream = [_]u8{ 0x05, 0x00, 0x92, 0x00 };
    try testing.expectError(error.InvalidStream, inflate(testing.allocator, &stream, 1024));
}

test "inflate: validates the zlib header and Adler-32 trailer" {
    const gpa = testing.allocator;
    // Bad compression method, bad check bits, and a preset dictionary.
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, &[_]u8{ 0x00, 0x01, 0x03, 0x00 }, 1024));
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, &[_]u8{ 0x78, 0x00, 0x03, 0x00 }, 1024));
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, &[_]u8{ 0x78, 0x20, 0x03, 0x00 }, 1024));
    // Window size larger than 32 KiB (CINFO=8).
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, &[_]u8{ 0x88, 0x1D, 0x03, 0x00 }, 1024));

    const source = try unhex(gpa, vectors.zlib_stored_hex);
    defer gpa.free(source);
    const corrupt = try gpa.dupe(u8, source);
    defer gpa.free(corrupt);
    corrupt[corrupt.len - 1] ^= 0xFF;
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, corrupt, 1 << 20));

    // Missing trailer.
    try testing.expectError(error.InvalidStream, zlibInflate(gpa, source[0 .. source.len - 2], 1 << 20));
}

test "inflate: truncated streams are rejected" {
    const gpa = testing.allocator;
    const hexes = [_][]const u8{
        vectors.raw_deflate_hex,
        vectors.zlib_fixed_hex,
        vectors.zlib_pattern256_hex,
    };
    for (hexes) |hex| {
        const source = try unhex(gpa, hex);
        defer gpa.free(source);
        var cut: usize = 1;
        while (cut < source.len) : (cut += @max(1, source.len / 4)) {
            try testing.expectError(error.InvalidStream, inflate(gpa, source[0..cut], 1 << 20));
        }
    }
}

test "inflate: the output bound is enforced for literals, matches and stored blocks" {
    const gpa = testing.allocator;
    const Case = struct { hex: []const u8, zlib: bool };
    const cases = [_]Case{
        .{ .hex = vectors.raw_deflate_hex, .zlib = false },
        .{ .hex = vectors.zlib_stored_hex, .zlib = true },
        .{ .hex = vectors.zlib_pattern256_hex, .zlib = true },
    };
    for (cases) |case| {
        const source = try unhex(gpa, case.hex);
        defer gpa.free(source);
        const decompress: *const fn (Allocator, []const u8, usize) InflateError![]u8 =
            if (case.zlib) &zlibInflate else &inflate;
        try testing.expectError(error.OutputTooLarge, decompress(gpa, source, 4));
        try testing.expectError(error.OutputTooLarge, decompress(gpa, source, 0));
    }
}

test "inflate: adler32 matches the RFC 1950 reference values" {
    try testing.expectEqual(@as(u32, 1), adler32(""));
    try testing.expectEqual(@as(u32, 0x00620062), adler32("a"));
    try testing.expectEqual(@as(u32, 0x024d0127), adler32("abc"));
    try testing.expectEqual(@as(u32, 0x11e60398), adler32("Wikipedia"));
}

test "inflate: survives allocation failure" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.zlib_fixed_hex);
    defer gpa.free(source);
    try alloc_probe.check(
        struct {
            fn f(alloc: Allocator, bytes: []const u8) !void {
                const out = try zlibInflate(alloc, bytes, 1 << 20);
                alloc.free(out);
            }
        }.f,
        .{source},
    );
}
