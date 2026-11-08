//! JPEG (sequential DCT, Huffman) decoding, normalizing to RGBA8.
//!
//! Supported, dependency-free subset:
//! - `SOF0` (baseline) and `SOF1` (extended sequential), 8-bit samples, Huffman
//!   entropy coding. These share one entropy-coded structure.
//! - Grayscale (1 component) and YCbCr (3 components).
//! - Any legal sampling factors in 1..4, which covers 4:4:4, 4:4:0, 4:2:2,
//!   4:2:0 and 4:1:1, including non-interleaved single-component scans.
//! - 8-bit and 16-bit quantization tables, arbitrary Huffman tables, restart
//!   markers (`DRI`/`RSTn`), and any number of `APPn`/`COM` segments.
//!
//! Rejected with `error.InvalidImage`, never approximated: progressive and
//! hierarchical frames, arithmetic coding, lossless, 12-bit samples, and
//! 4-component (CMYK/YCCK) frames.
//!
//! Fidelity: colour conversion uses libjpeg's exact fixed-point constants and
//! chroma upsampling reproduces libjpeg's "fancy" triangle filter, so the only
//! divergence from a libjpeg decode is IDCT rounding. The test suite pins the
//! measured per-channel tolerance against libjpeg-generated references.
//!
//! Memory safety and performance: every marker, table index and coefficient
//! count is bounds-checked; plane sizes use checked arithmetic and are bounded
//! by `max_plane_bytes` before any allocation. The bit reader understands
//! `0xFF00` byte stuffing and stops at markers instead of reading through them.
//! The IDCT is a separable transform that skips all-zero coefficient rows and
//! takes a constant-time path for DC-only blocks, which is most of a typical
//! photograph. Decoding runs in place into one plane per component, then a
//! single fused pass upsamples and converts to RGBA8.

const std = @import("std");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const DecodeError = image.DecodeError;
const Image = image.Image;

/// Maximum number of components in a frame this decoder accepts.
pub const max_components: usize = 3;

/// Ceiling for the intermediate component planes. The RGBA8 output is already
/// bounded by `image.max_pixel_bytes`; for the densest accepted layout (4:4:4)
/// the planes need 3 bytes per pixel against the output's 4, so this bound never
/// rejects an image whose output would fit. Peak memory is therefore at most
/// `max_pixel_bytes + max_plane_bytes`.
pub const max_plane_bytes: usize = image.max_pixel_bytes;

/// Coefficient scan order: zigzag index -> natural (row-major) index.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Separable IDCT basis: `basis[u][x] = alpha(u)/2 * cos((2x+1) u pi / 16)`.
/// Computed once at comptime; the two transform passes are 8x8 products against
/// this matrix, with all-zero rows skipped.
const basis = blk: {
    @setEvalBranchQuota(20000);
    var b: [8][8]f32 = undefined;
    for (0..8) |u| {
        const alpha: f32 = if (u == 0) @as(f32, @sqrt(0.5)) else 1.0;
        for (0..8) |x| {
            const angle = @as(f32, @floatFromInt(2 * x + 1)) * @as(f32, @floatFromInt(u)) * (std.math.pi / 16.0);
            b[u][x] = alpha * 0.5 * @cos(angle);
        }
    }
    break :blk b;
};

// --- Huffman ---------------------------------------------------------------

/// Codes up to this length are resolved with a single table lookup.
const fast_bits: u5 = 10;

const Huffman = struct {
    /// Symbol for a `fast_bits`-wide peek, valid when `fast_len != 0`.
    fast_sym: [1 << fast_bits]u8 = undefined,
    fast_len: [1 << fast_bits]u8 = undefined,
    /// Slow path for the rare codes longer than `fast_bits`.
    min_code: [17]i32 = undefined,
    max_code: [17]i32 = undefined,
    val_ptr: [17]u16 = undefined,
    symbols: [256]u8 = undefined,

    /// Build canonical JPEG Huffman tables. `counts[l]` is the number of codes
    /// of length `l+1`; `symbols` holds exactly `sum(counts)` values.
    fn build(counts: [16]u8, symbols: []const u8) DecodeError!Huffman {
        var total: usize = 0;
        for (counts) |c| total += c;
        if (total == 0 or total > 256 or total != symbols.len) return error.InvalidImage;

        var h = Huffman{};
        @memset(&h.fast_len, 0);
        @memset(&h.min_code, 0);
        @memset(&h.max_code, -1);
        @memset(&h.val_ptr, 0);
        @memcpy(h.symbols[0..total], symbols);

        var code: i32 = 0;
        var k: usize = 0;
        for (0..16) |i| {
            const len = i + 1;
            const n = counts[i];
            if (n == 0) {
                h.max_code[len] = -1;
            } else {
                h.val_ptr[len] = @intCast(k);
                h.min_code[len] = code;
                // A code space must never be over-subscribed.
                if (code + @as(i32, @intCast(n)) > (@as(i32, 1) << @intCast(len))) return error.InvalidImage;
                for (0..n) |_| {
                    const sym = h.symbols[k];
                    const slen: u8 = @intCast(len);
                    if (len <= fast_bits) {
                        // Replicate the entry across every peek whose high bits
                        // are this code, so one lookup resolves it.
                        const shift: u5 = @intCast(fast_bits - len);
                        const base: usize = @as(usize, @intCast(code)) << shift;
                        const span = @as(usize, 1) << shift;
                        for (base..base + span) |idx| {
                            h.fast_sym[idx] = sym;
                            h.fast_len[idx] = slen;
                        }
                    }
                    code += 1;
                    k += 1;
                }
                h.max_code[len] = code - 1;
            }
            code <<= 1;
        }
        return h;
    }
};

// --- bit reader ------------------------------------------------------------

/// JPEG entropy-coded bit reader.
///
/// Bytes are pulled only as far as the current symbol needs, never far ahead, so
/// a restart marker can be located by discarding the bits left in the current
/// byte. `0xFF00` un-stuffs to `0xFF`; `0xFFFF` is a fill byte; any other marker
/// stops the stream without consuming it, leaving `pos` on the `0xFF`.
const BitReader = struct {
    data: []const u8,
    pos: usize,
    acc: u32 = 0,
    nbits: u6 = 0,
    /// Set when a marker (rather than data) was reached.
    marker: ?u8 = null,
    /// Set when the source ran out with no marker at all: a truncated scan.
    truncated: bool = false,

    fn pullByte(self: *BitReader) u8 {
        while (self.pos < self.data.len) {
            const b = self.data[self.pos];
            if (b != 0xFF) {
                self.pos += 1;
                return b;
            }
            if (self.pos + 1 >= self.data.len) {
                self.truncated = true;
                return 0;
            }
            const nb = self.data[self.pos + 1];
            if (nb == 0x00) {
                self.pos += 2;
                return 0xFF;
            }
            if (nb == 0xFF) {
                self.pos += 1; // fill byte, keep scanning
                continue;
            }
            // A real marker: do not consume it.
            self.marker = nb;
            return 0;
        }
        self.truncated = true;
        return 0;
    }

    fn ensure(self: *BitReader, n: u6) void {
        while (self.nbits < n) {
            const b: u32 = if (self.marker == null) self.pullByte() else 0;
            self.acc = (self.acc << 8) | b;
            self.nbits += 8;
        }
    }

    fn peek(self: *BitReader, n: u6) u32 {
        self.ensure(n);
        return (self.acc >> @intCast(self.nbits - n)) & ((@as(u32, 1) << @intCast(n)) - 1);
    }

    fn consume(self: *BitReader, n: u6) void {
        self.nbits -= n;
        self.acc &= (@as(u32, 1) << @intCast(self.nbits)) - 1;
    }

    fn getBits(self: *BitReader, n: u6) u32 {
        if (n == 0) return 0;
        const v = self.peek(n);
        self.consume(n);
        return v;
    }

    fn decodeSymbol(self: *BitReader, h: *const Huffman) DecodeError!u8 {
        const idx = self.peek(fast_bits);
        const len = h.fast_len[idx];
        if (len != 0) {
            self.consume(@intCast(len));
            return h.fast_sym[idx];
        }
        // Long code: walk the canonical code space one bit at a time.
        var code: i32 = @intCast(self.getBits(1));
        var len2: usize = 1;
        while (len2 <= 16) : (len2 += 1) {
            if (h.max_code[len2] >= code) {
                const off = code - h.min_code[len2];
                if (off < 0) return error.InvalidImage;
                const at = @as(usize, h.val_ptr[len2]) + @as(usize, @intCast(off));
                if (at >= 256) return error.InvalidImage;
                return h.symbols[at];
            }
            if (len2 == 16) break;
            code = (code << 1) | @as(i32, @intCast(self.getBits(1)));
        }
        return error.InvalidImage;
    }

    /// Sign-extend a JPEG "received" value of `n` bits (the DC/AC magnitude).
    fn extend(v: u32, n: u6) i32 {
        if (n == 0) return 0;
        const shift: u5 = @intCast(n - 1);
        const bias = @as(i32, 1) << shift;
        const iv: i32 = @intCast(v);
        return if (iv < bias) iv - (@as(i32, 1) << @intCast(n)) + 1 else iv;
    }

    /// Discard the padding bits of the current byte and consume the expected
    /// restart marker, leaving the reader ready for the next interval.
    fn restart(self: *BitReader, expected: u8) DecodeError!void {
        self.acc = 0;
        self.nbits = 0;
        self.marker = null;
        // The marker may already have been spotted while peeking, or still be
        // ahead in the byte stream.
        if (self.pos + 1 >= self.data.len) return error.InvalidImage;
        if (self.data[self.pos] != 0xFF) return error.InvalidImage;
        var at = self.pos;
        while (at + 1 < self.data.len and self.data[at + 1] == 0xFF) at += 1;
        if (at + 1 >= self.data.len) return error.InvalidImage;
        if (self.data[at + 1] != expected) return error.InvalidImage;
        self.pos = at + 2;
    }
};

// --- frame -----------------------------------------------------------------

const Component = struct {
    id: u8 = 0,
    h: usize = 1,
    v: usize = 1,
    tq: usize = 0,
    td: usize = 0,
    ta: usize = 0,
    dc_pred: i32 = 0,
    /// Padded plane geometry (whole blocks, MCU-aligned).
    stride: usize = 0,
    rows: usize = 0,
    /// Real sample count, used to clamp upsampling at the image edge.
    samples_w: usize = 0,
    samples_h: usize = 0,
    plane: []u8 = &.{},
};

const Frame = struct {
    width: u32 = 0,
    height: u32 = 0,
    comps: [max_components]Component = .{ .{}, .{}, .{} },
    count: usize = 0,
    h_max: usize = 1,
    v_max: usize = 1,
    mcu_x: usize = 0,
    mcu_y: usize = 0,
    restart_interval: usize = 0,
    /// Single-component scans are non-interleaved: one block per MCU.
    interleaved: bool = true,
};

const Tables = struct {
    quant: [4][64]u16 = undefined,
    quant_seen: [4]bool = .{ false, false, false, false },
    dc: [4]Huffman = undefined,
    ac: [4]Huffman = undefined,
    dc_seen: [4]bool = .{ false, false, false, false },
    ac_seen: [4]bool = .{ false, false, false, false },
};

fn readU16(data: []const u8, at: usize) DecodeError!u16 {
    if (at + 2 > data.len) return error.InvalidImage;
    return std.mem.readInt(u16, data[at..][0..2], .big);
}

/// Walk the marker segments up to `SOS`, filling `frame` and `tables`. Returns
/// the offset of the first entropy-coded byte.
fn parseHeaders(source: []const u8, frame: *Frame, tables: *Tables) DecodeError!usize {
    if (source.len < 4) return error.InvalidImage;
    if (source[0] != 0xFF or source[1] != 0xD8) return error.InvalidImage;
    var pos: usize = 2;
    var seen_sof = false;

    while (true) {
        // Markers may be preceded by any number of fill bytes.
        while (pos < source.len and source[pos] == 0xFF) pos += 1;
        if (pos >= source.len) return error.InvalidImage;
        const marker = source[pos];
        pos += 1;
        if (marker == 0xD9) return error.InvalidImage; // EOI before any scan
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) continue; // no payload

        const seg_len = try readU16(source, pos);
        if (seg_len < 2) return error.InvalidImage;
        const seg_start = pos + 2;
        const seg_end = pos + seg_len;
        if (seg_end > source.len) return error.InvalidImage;
        const seg = source[seg_start..seg_end];

        switch (marker) {
            0xC0, 0xC1 => { // SOF0 baseline, SOF1 extended sequential
                if (seen_sof) return error.InvalidImage;
                if (seg.len < 6) return error.InvalidImage;
                if (seg[0] != 8) return error.InvalidImage; // only 8-bit samples
                frame.height = std.mem.readInt(u16, seg[1..3], .big);
                frame.width = std.mem.readInt(u16, seg[3..5], .big);
                const n = seg[5];
                if (n != 1 and n != 3) return error.InvalidImage;
                if (seg.len != 6 + @as(usize, n) * 3) return error.InvalidImage;
                frame.count = n;
                frame.interleaved = n != 1;
                var area: usize = 0;
                for (0..n) |i| {
                    const c = &frame.comps[i];
                    c.id = seg[6 + i * 3];
                    const factors = seg[7 + i * 3];
                    c.h = factors >> 4;
                    c.v = factors & 0x0F;
                    c.tq = seg[8 + i * 3];
                    if (c.h == 0 or c.h > 4 or c.v == 0 or c.v > 4) return error.InvalidImage;
                    if (c.tq >= 4) return error.InvalidImage;
                    // A single-component image is never interleaved; libjpeg
                    // ignores its factors, and so do we.
                    if (n == 1) {
                        c.h = 1;
                        c.v = 1;
                    }
                    area += c.h * c.v;
                    for (0..i) |j| {
                        if (frame.comps[j].id == c.id) return error.InvalidImage; // duplicate id
                    }
                }
                if (area > 10) return error.InvalidImage; // spec ceiling
                seen_sof = true;
            },
            0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => {
                // Progressive, hierarchical, lossless, arithmetic.
                return error.InvalidImage;
            },
            0xC4 => { // DHT
                var at: usize = 0;
                while (at < seg.len) {
                    if (at + 17 > seg.len) return error.InvalidImage;
                    const info = seg[at];
                    const class = info >> 4;
                    const id = info & 0x0F;
                    if (class > 1 or id >= 4) return error.InvalidImage;
                    var counts: [16]u8 = undefined;
                    var total: usize = 0;
                    for (0..16) |i| {
                        counts[i] = seg[at + 1 + i];
                        total += counts[i];
                    }
                    at += 17;
                    if (total > 256 or at + total > seg.len) return error.InvalidImage;
                    const h = try Huffman.build(counts, seg[at .. at + total]);
                    if (class == 0) {
                        tables.dc[id] = h;
                        tables.dc_seen[id] = true;
                    } else {
                        tables.ac[id] = h;
                        tables.ac_seen[id] = true;
                    }
                    at += total;
                }
                if (at != seg.len) return error.InvalidImage;
            },
            0xDB => { // DQT
                var at: usize = 0;
                while (at < seg.len) {
                    const info = seg[at];
                    at += 1;
                    const precision = info >> 4;
                    const id = info & 0x0F;
                    if (precision > 1 or id >= 4) return error.InvalidImage;
                    const need: usize = if (precision == 1) 128 else 64;
                    if (at + need > seg.len) return error.InvalidImage;
                    for (0..64) |k| {
                        const natural = zigzag[k];
                        tables.quant[id][natural] = if (precision == 1)
                            std.mem.readInt(u16, seg[at + k * 2 ..][0..2], .big)
                        else
                            seg[at + k];
                    }
                    // A zero divisor would make the IDCT meaningless.
                    for (tables.quant[id]) |q| {
                        if (q == 0) return error.InvalidImage;
                    }
                    tables.quant_seen[id] = true;
                    at += need;
                }
                if (at != seg.len) return error.InvalidImage;
            },
            0xDD => { // DRI
                if (seg.len != 2) return error.InvalidImage;
                frame.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            0xDA => { // SOS: headers end here
                if (!seen_sof) return error.InvalidImage;
                if (seg.len < 1) return error.InvalidImage;
                const ns = seg[0];
                if (ns != frame.count) return error.InvalidImage; // one scan only
                if (seg.len != 1 + @as(usize, ns) * 2 + 3) return error.InvalidImage;
                for (0..ns) |i| {
                    const cid = seg[1 + i * 2];
                    const sel = seg[2 + i * 2];
                    const td = sel >> 4;
                    const ta = sel & 0x0F;
                    if (td >= 4 or ta >= 4) return error.InvalidImage;
                    var found = false;
                    for (frame.comps[0..frame.count]) |*c| {
                        if (c.id != cid) continue;
                        c.td = td;
                        c.ta = ta;
                        found = true;
                    }
                    if (!found) return error.InvalidImage;
                }
                // Baseline spectral selection: the whole block, no successive
                // approximation. Anything else belongs to progressive scans.
                if (seg[1 + ns * 2] != 0 or seg[2 + ns * 2] != 63 or seg[3 + ns * 2] != 0) return error.InvalidImage;
                for (frame.comps[0..frame.count]) |c| {
                    if (!tables.quant_seen[c.tq]) return error.InvalidImage;
                    if (!tables.dc_seen[c.td] or !tables.ac_seen[c.ta]) return error.InvalidImage;
                }
                return seg_end;
            },
            else => {
                if (marker == 0xC8) return error.InvalidImage; // JPG reserved
                // APPn, COM and other payload-bearing segments are skipped.
            },
        }
        pos = seg_end;
    }
}

/// Derive MCU and plane geometry, then allocate one plane per component.
fn allocPlanes(gpa: Allocator, frame: *Frame) DecodeError!void {
    if (frame.width == 0 or frame.height == 0) return error.InvalidImage;
    if (frame.width > image.max_dimension or frame.height > image.max_dimension) return error.InvalidImage;

    frame.h_max = 1;
    frame.v_max = 1;
    for (frame.comps[0..frame.count]) |c| {
        frame.h_max = @max(frame.h_max, c.h);
        frame.v_max = @max(frame.v_max, c.v);
    }
    const w: usize = frame.width;
    const h: usize = frame.height;
    if (frame.interleaved) {
        frame.mcu_x = (w + frame.h_max * 8 - 1) / (frame.h_max * 8);
        frame.mcu_y = (h + frame.v_max * 8 - 1) / (frame.v_max * 8);
    } else {
        frame.mcu_x = (w + 7) / 8;
        frame.mcu_y = (h + 7) / 8;
    }
    var total: usize = 0;
    for (frame.comps[0..frame.count]) |*c| {
        if (frame.interleaved) {
            c.stride = std.math.mul(usize, frame.mcu_x * c.h, 8) catch return error.InvalidImage;
            c.rows = std.math.mul(usize, frame.mcu_y * c.v, 8) catch return error.InvalidImage;
            c.samples_w = (w * c.h + frame.h_max - 1) / frame.h_max;
            c.samples_h = (h * c.v + frame.v_max - 1) / frame.v_max;
        } else {
            c.stride = frame.mcu_x * 8;
            c.rows = frame.mcu_y * 8;
            c.samples_w = w;
            c.samples_h = h;
        }
        const bytes = std.math.mul(usize, c.stride, c.rows) catch return error.InvalidImage;
        total = std.math.add(usize, total, bytes) catch return error.InvalidImage;
        if (total > max_plane_bytes) return error.InvalidImage;
    }
    // Bound the planes before allocating any of them, so a hostile header
    // cannot make us allocate one huge plane before rejecting the next.
    var allocated: usize = 0;
    errdefer for (frame.comps[0..allocated]) |*c| gpa.free(c.plane);
    for (frame.comps[0..frame.count]) |*c| {
        c.plane = gpa.alloc(u8, c.stride * c.rows) catch return error.OutOfMemory;
        allocated += 1;
    }
}

// --- entropy-coded scan ----------------------------------------------------

/// Decode one 8x8 block into `out`, returning a bitmask of the coefficient rows
/// that hold any non-zero value (used to skip IDCT work).
fn decodeBlock(br: *BitReader, comp: *Component, tables: *const Tables, out: *[64]f32) DecodeError!u8 {
    @memset(out, 0);
    const q = &tables.quant[comp.tq];

    const t = try br.decodeSymbol(&tables.dc[comp.td]);
    if (t > 15) return error.InvalidImage;
    const diff = BitReader.extend(br.getBits(@intCast(t)), @intCast(t));
    comp.dc_pred += diff;
    out[0] = @floatFromInt(comp.dc_pred * @as(i32, q[0]));

    var rows: u8 = if (out[0] != 0) 1 else 0;
    var k: usize = 1;
    while (k < 64) {
        const rs = try br.decodeSymbol(&tables.ac[comp.ta]);
        const r = rs >> 4;
        const s = rs & 0x0F;
        if (s == 0) {
            if (r == 15) { // ZRL: skip 16 zeros
                k += 16;
                continue;
            }
            break; // EOB
        }
        k += r;
        if (k > 63) return error.InvalidImage;
        const mag = BitReader.extend(br.getBits(@intCast(s)), @intCast(s));
        const natural = zigzag[k];
        const value = mag * @as(i32, q[natural]);
        out[natural] = @floatFromInt(value);
        rows |= @as(u8, 1) << @intCast(natural / 8);
        k += 1;
    }
    return rows;
}

/// Inverse DCT of a dequantized block, writing 64 level-shifted, clamped samples.
/// `rows` marks which coefficient rows are non-zero; zero rows cost nothing.
fn idct(block: *const [64]f32, rows: u8, out: *[64]u8) void {
    if (rows == 0) {
        @memset(out, 128);
        return;
    }
    if (rows == 1) {
        // Only the first coefficient row is populated. If it holds nothing but
        // DC the whole block is flat, which is the common case in smooth areas.
        var ac = false;
        for (1..8) |x| {
            if (block[x] != 0) {
                ac = true;
                break;
            }
        }
        if (!ac) {
            // A flat block is the DC coefficient times the *2D* DC gain, which
            // is basis[0][0]^2 = 1/8, not the single-pass factor.
            const dc = block[0] * (basis[0][0] * basis[0][0]);
            out.* = @splat(clampSample(dc));
            return;
        }
    }

    // Pass 1: transform along u, for each coefficient row v.
    var tmp: [8][8]f32 = @splat(@splat(0));
    for (0..8) |v| {
        if (rows & (@as(u8, 1) << @intCast(v)) == 0) continue;
        for (0..8) |u| {
            const f = block[v * 8 + u];
            if (f == 0) continue;
            const b: @Vector(8, f32) = basis[u];
            const cur: @Vector(8, f32) = tmp[v];
            tmp[v] = cur + b * @as(@Vector(8, f32), @splat(f));
        }
    }
    // Pass 2: transform along v, accumulating into output rows.
    for (0..8) |y| {
        var acc: @Vector(8, f32) = @splat(0);
        for (0..8) |v| {
            if (rows & (@as(u8, 1) << @intCast(v)) == 0) continue;
            const w: @Vector(8, f32) = @splat(basis[v][y]);
            acc += w * @as(@Vector(8, f32), tmp[v]);
        }
        var shifted = acc + @as(@Vector(8, f32), @splat(128.5));
        shifted = @max(shifted, @as(@Vector(8, f32), @splat(0)));
        shifted = @min(shifted, @as(@Vector(8, f32), @splat(255)));
        const ints: @Vector(8, i32) = @intFromFloat(shifted);
        const bytes: [8]u8 = @as(@Vector(8, u8), @intCast(ints));
        @memcpy(out[y * 8 ..][0..8], &bytes);
    }
}

fn clampSample(v: f32) u8 {
    const s = v + 128.5;
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

fn decodeScan(br: *BitReader, frame: *Frame, tables: *const Tables) DecodeError!void {
    const total_mcu = frame.mcu_x * frame.mcu_y;
    var block: [64]f32 = undefined;
    var samples: [64]u8 = undefined;
    var mcu: usize = 0;
    var since_restart: usize = 0;
    var next_rst: u8 = 0xD0;

    while (mcu < total_mcu) : (mcu += 1) {
        if (frame.restart_interval != 0 and since_restart == frame.restart_interval) {
            try br.restart(next_rst);
            next_rst = if (next_rst == 0xD7) 0xD0 else next_rst + 1;
            for (frame.comps[0..frame.count]) |*c| c.dc_pred = 0;
            since_restart = 0;
        }
        const mx = mcu % frame.mcu_x;
        const my = mcu / frame.mcu_x;

        if (!frame.interleaved) {
            const c = &frame.comps[0];
            const rows = try decodeBlock(br, c, tables, &block);
            idct(&block, rows, &samples);
            storeBlock(c, mx * 8, my * 8, &samples);
            since_restart += 1;
            continue;
        }
        for (frame.comps[0..frame.count]) |*c| {
            for (0..c.v) |by| {
                for (0..c.h) |bx| {
                    const rows = try decodeBlock(br, c, tables, &block);
                    idct(&block, rows, &samples);
                    storeBlock(c, (mx * c.h + bx) * 8, (my * c.v + by) * 8, &samples);
                }
            }
        }
        since_restart += 1;
    }
    if (br.truncated) return error.InvalidImage;
}

fn storeBlock(c: *const Component, x0: usize, y0: usize, samples: *const [64]u8) void {
    for (0..8) |y| {
        const dst = c.plane[(y0 + y) * c.stride + x0 ..][0..8];
        @memcpy(dst, samples[y * 8 ..][0..8]);
    }
}

// --- upsampling and colour conversion --------------------------------------

/// libjpeg's triangle filter for 2x expansion, with edge clamping. `bias` is the
/// rounding term libjpeg uses (1 for the first output row, 2 for the second).
fn triangle(a: u8, b: u8, bias: u32) u8 {
    return @intCast((3 * @as(u32, a) + @as(u32, b) + bias) >> 2);
}

/// Horizontal 2x "fancy" expansion of one component row, matching libjpeg's
/// triangle filter. Iterating over the *output* keeps the write bounded even when
/// the image width is odd and `2 * src.len` would overshoot it.
fn expandRow2(src: []const u8, dst: []u8) void {
    const n = src.len;
    if (n == 0) return;
    for (0..dst.len) |x| {
        const i = @min(x >> 1, n - 1);
        const odd = (x & 1) == 1;
        const nb = if (odd)
            (if (i + 1 < n) src[i + 1] else src[i])
        else
            (if (i == 0) src[i] else src[i - 1]);
        dst[x] = triangle(src[i], nb, if (odd) 2 else 1);
    }
}

/// libjpeg's exact fixed-point YCbCr -> RGB (jdcolor.c). `cb`/`cr` are already
/// centred on zero. Reproducing these constants keeps colour conversion
/// bit-identical to libjpeg, leaving only IDCT rounding as a source of drift.
fn ycbcrToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yi: i32 = y;
    const b: i32 = @as(i32, cb) - 128;
    const r: i32 = @as(i32, cr) - 128;
    const rr = yi + ((91881 * r + 32768) >> 16);
    const gg = yi + ((-22554 * b - 46802 * r + 32768) >> 16);
    const bb = yi + ((116130 * b + 32768) >> 16);
    return .{ clamp8(rr), clamp8(gg), clamp8(bb) };
}

fn clamp8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

/// Expand one component row to output resolution.
///
/// Chroma uses libjpeg's "fancy" triangle filter for the 2x1 and 2x2 cases and
/// replication for every other ratio, which is exactly libjpeg's own selection.
/// A ratio of 1 is a straight copy. Working a whole row at a time keeps the
/// colour loop free of per-pixel ratio branching.
/// The vertically adjacent component row for a 2x expansion, clamped at the
/// real sample edges (not the MCU-padded plane edges).
fn neighbourRow(c: *const Component, r: usize, y: usize) []const u8 {
    // The upper output row of a pair sits above its source row, so its
    // second-nearest neighbour is the row ABOVE; the lower row looks BELOW.
    const nr = if ((y & 1) == 0) (if (r == 0) 0 else r - 1) else @min(r + 1, c.samples_h - 1);
    return c.plane[nr * c.stride ..][0..c.samples_w];
}

fn expandRow(c: *const Component, hx: usize, vy: usize, y: usize, dst: []u8) void {
    const w = dst.len;
    const n = c.samples_w;
    const r = @min(y / vy, c.samples_h - 1);
    const cur = c.plane[r * c.stride ..][0..n];

    if (hx == 1 and vy == 1) {
        @memcpy(dst, cur[0..w]);
        return;
    }
    // libjpeg only takes the fancy horizontal path when the component row is
    // wider than two samples; at or below that it replicates.
    const fancy_h = n > 2;
    if (hx == 2 and vy == 1) {
        if (fancy_h) {
            expandRow2(cur, dst);
        } else {
            for (0..w) |x| dst[x] = cur[@min(x >> 1, n - 1)];
        }
        return;
    }
    if (hx == 2 and vy == 2) {
        if (!fancy_h) {
            const src = cur;
            for (0..w) |x| dst[x] = src[@min(x >> 1, n - 1)];
            return;
        }
        // Fused triangle filter: the vertical sums stay unnormalized (x4) so the
        // horizontal pass rounds once, exactly as libjpeg's h2v2 does. Its left
        // taps round with +8 and its right taps with +7.
        const other = neighbourRow(c, r, y);
        for (0..w) |x| {
            const i = @min(x >> 1, n - 1);
            const odd = (x & 1) == 1;
            const j = if (odd) (if (i + 1 < n) i + 1 else i) else (if (i == 0) i else i - 1);
            const sum = 3 * @as(u32, cur[i]) + @as(u32, other[i]);
            const nb = 3 * @as(u32, cur[j]) + @as(u32, other[j]);
            const bias: u32 = if (odd) 7 else 8;
            dst[x] = @intCast(@min(@as(u32, 255), (3 * sum + nb + bias) >> 4));
        }
        return;
    }
    if (hx == 1 and vy == 2) {
        const other = neighbourRow(c, r, y);
        const bias: u32 = if ((y & 1) == 0) 1 else 2;
        for (0..w) |x| {
            const i = @min(x, n - 1);
            dst[x] = triangle(cur[i], other[i], bias);
        }
        return;
    }
    // Ratios libjpeg replicates (3x, 4x, and mixed cases).
    for (0..w) |x| dst[x] = cur[@min(x / hx, n - 1)];
}

fn convert(gpa: Allocator, frame: *const Frame, pixels: []u8) DecodeError!void {
    const w: usize = frame.width;
    const h: usize = frame.height;

    if (frame.count == 1) {
        const c = &frame.comps[0];
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src = c.plane[y * c.stride ..][0..w];
            const dst = pixels[y * w * 4 ..][0 .. w * 4];
            for (0..w) |x| {
                dst[x * 4 + 0] = src[x];
                dst[x * 4 + 1] = src[x];
                dst[x * 4 + 2] = src[x];
                dst[x * 4 + 3] = 255;
            }
        }
        return;
    }

    // Sampling factors must divide the maximum, or the layout is not a legal
    // JPEG sampling hierarchy.
    var hx: [3]usize = undefined;
    var vy: [3]usize = undefined;
    for (frame.comps[0..3], 0..) |c, i| {
        if (frame.h_max % c.h != 0 or frame.v_max % c.v != 0) return error.InvalidImage;
        hx[i] = frame.h_max / c.h;
        vy[i] = frame.v_max / c.v;
    }

    // One allocation: three output-resolution rows, reused for every row.
    const rows_buf = gpa.alloc(u8, w * 3) catch return error.OutOfMemory;
    defer gpa.free(rows_buf);
    const yr = rows_buf[0..w];
    const cb = rows_buf[w..][0..w];
    const cr = rows_buf[2 * w ..][0..w];

    var y: usize = 0;
    while (y < h) : (y += 1) {
        expandRow(&frame.comps[0], hx[0], vy[0], y, yr);
        expandRow(&frame.comps[1], hx[1], vy[1], y, cb);
        expandRow(&frame.comps[2], hx[2], vy[2], y, cr);
        const dst = pixels[y * w * 4 ..][0 .. w * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const rgb = ycbcrToRgb(yr[x], cb[x], cr[x]);
            dst[x * 4 + 0] = rgb[0];
            dst[x * 4 + 1] = rgb[1];
            dst[x * 4 + 2] = rgb[2];
            dst[x * 4 + 3] = 255;
        }
    }
}

// --- public entry point ----------------------------------------------------

/// Decode a sequential Huffman JPEG into RGBA8. The caller owns `Image.pixels`
/// and frees it with `Image.deinit`. Alpha is always 255: JPEG carries none.
pub fn decode(gpa: Allocator, source: []const u8) DecodeError!Image {
    var frame = Frame{};
    var tables = Tables{};
    const scan_start = try parseHeaders(source, &frame, &tables);

    // Validate the RGBA8 output size before allocating anything.
    const pixels = try image.allocPixels(gpa, frame.width, frame.height);
    errdefer gpa.free(pixels);

    try allocPlanes(gpa, &frame);
    defer for (frame.comps[0..frame.count]) |*c| gpa.free(c.plane);

    var br = BitReader{ .data = source, .pos = scan_start };
    try decodeScan(&br, &frame, &tables);

    try convert(gpa, &frame, pixels);
    return .{ .width = frame.width, .height = frame.height, .pixels = pixels };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const vectors = @import("jpeg_vectors.zig");
const alloc_probe = @import("../core/alloc_probe.zig");

fn unhex(gpa: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadHex;
    const out = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(out);
    for (out, 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.BadHex;
    }
    return out;
}

/// Measured against libjpeg over the whole corpus: worst channel 3 (at quality
/// 10, where coarse quantization amplifies the transform difference) and worst
/// per-image mean 0.199. One extra level of headroom is allowed for floating
/// point contraction differing between optimization modes. The mean bound is
/// the important one: a wrong upsampling filter shifts it by whole levels.
const tolerance_max_diff: u32 = 4;
const tolerance_mean: f64 = 0.25;

test "jpeg: every libjpeg vector decodes within the pinned IDCT tolerance" {
    const gpa = testing.allocator;
    for (vectors.valid) |v| {
        const src = try unhex(gpa, v.jpg_hex);
        defer gpa.free(src);
        const ref = try unhex(gpa, v.rgba_hex);
        defer gpa.free(ref);
        var img = decode(gpa, src) catch |err| {
            std.debug.print("jpeg vector {s} failed: {s}\n", .{ v.name, @errorName(err) });
            return err;
        };
        defer img.deinit(gpa);
        try testing.expectEqual(v.width, img.width);
        try testing.expectEqual(v.height, img.height);
        try testing.expectEqual(ref.len, img.pixels.len);

        var maxd: u32 = 0;
        var sum: u64 = 0;
        for (img.pixels, ref, 0..) |a, b, i| {
            if (i % 4 == 3) {
                // JPEG carries no alpha; the artifact is always opaque.
                try testing.expectEqual(@as(u8, 255), a);
                continue;
            }
            const d = if (a > b) a - b else b - a;
            maxd = @max(maxd, d);
            sum += d;
        }
        const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(img.pixels.len / 4 * 3));
        if (maxd > tolerance_max_diff or mean > tolerance_mean) {
            std.debug.print("jpeg vector {s}: max diff {d}, mean {d:.5}\n", .{ v.name, maxd, mean });
            return error.TestUnexpectedResult;
        }
    }
}

test "jpeg: malformed files are rejected" {
    const gpa = testing.allocator;
    for (vectors.invalid) |v| {
        const src = try unhex(gpa, v.jpg_hex);
        defer gpa.free(src);
        if (decode(gpa, src)) |got| {
            var img = got;
            img.deinit(gpa);
            std.debug.print("jpeg malformed vector {s} was accepted\n", .{v.name});
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.InvalidImage, err);
        }
    }
}

test "jpeg: unsupported coding processes are refused, not partially decoded" {
    const gpa = testing.allocator;
    for (vectors.unsupported) |v| {
        const src = try unhex(gpa, v.jpg_hex);
        defer gpa.free(src);
        if (decode(gpa, src)) |got| {
            var img = got;
            img.deinit(gpa);
            std.debug.print("jpeg unsupported vector {s} was accepted\n", .{v.name});
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.InvalidImage, err);
        }
    }
}

test "jpeg: allocation failures propagate without leaking" {
    const gpa = testing.allocator;
    const src = try unhex(gpa, vectors.valid[0].jpg_hex);
    defer gpa.free(src);
    const Probe = struct {
        fn run(alloc: Allocator, bytes: []const u8) !void {
            var img = try decode(alloc, bytes);
            img.deinit(alloc);
        }
    };
    try alloc_probe.check(Probe.run, .{src});
}

test "jpeg: partial plane allocation is unwound on failure" {
    // The third component's allocation fails after two planes exist; the
    // errdefer must free exactly the planes that were allocated.
    const gpa = testing.allocator;
    const src = try unhex(gpa, vectors.valid[10].jpg_hex);
    defer gpa.free(src);
    const Probe = struct {
        fn run(alloc: Allocator, bytes: []const u8) !void {
            var img = try decode(alloc, bytes);
            img.deinit(alloc);
        }
    };
    try alloc_probe.check(Probe.run, .{src});
}

// --- focused unit tests for paths the reference corpus cannot reach ---------

/// A 3-row, 4-sample component with distinct values, so a wrong neighbour row or
/// rounding bias cannot hide.
const probe_plane = [_]u8{
    10, 20,  30,  40,
    50, 60,  70,  80,
    90, 100, 110, 120,
};

fn probeComponent() Component {
    return .{
        .stride = 4,
        .rows = 3,
        .samples_w = 4,
        .samples_h = 3,
        .plane = @constCast(&probe_plane),
    };
}

test "jpeg: 4:4:0 vertical upsampling uses the row above then below" {
    // libjpeg can emit 4:4:4/4:2:2/4:2:0 but not 4:4:0 through Pillow, so this
    // pins h1v2_fancy directly: upper output row blends with the row ABOVE at
    // bias 1, lower with the row BELOW at bias 2, clamped at the edges.
    const c = probeComponent();
    var dst: [4]u8 = undefined;
    expandRow(&c, 1, 2, 0, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40 }, &dst);
    expandRow(&c, 1, 2, 1, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 20, 30, 40, 50 }, &dst);
    expandRow(&c, 1, 2, 2, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 40, 50, 60, 70 }, &dst);
    expandRow(&c, 1, 2, 3, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 60, 70, 80, 90 }, &dst);
}

test "jpeg: 4:2:2 horizontal upsampling matches libjpeg's edge handling" {
    const c = probeComponent();
    var dst: [8]u8 = undefined;
    expandRow(&c, 2, 1, 0, &dst);
    // The outermost taps are the raw samples, which is what clamping the
    // triangle filter to the edge sample produces.
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 13, 17, 23, 27, 33, 37, 40 }, &dst);
}

test "jpeg: 4:2:0 fused upsampling rounds left +8 and right +7" {
    const c = probeComponent();
    var dst: [8]u8 = undefined;
    expandRow(&c, 2, 2, 0, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 12, 18, 22, 28, 32, 38, 40 }, &dst);
}

test "jpeg: a two-sample chroma row replicates instead of filtering" {
    // libjpeg only takes the fancy horizontal path above two samples.
    var plane = [_]u8{ 10, 200 };
    const c = Component{ .stride = 2, .rows = 1, .samples_w = 2, .samples_h = 1, .plane = &plane };
    var dst: [4]u8 = undefined;
    expandRow(&c, 2, 1, 0, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 200, 200 }, &dst);
    expandRow(&c, 2, 2, 0, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 200, 200 }, &dst);
}

test "jpeg: an odd output width never overruns the expanded row" {
    // 3 chroma samples expand to 6, but the image is only 5 wide.
    var plane = [_]u8{ 10, 20, 30 };
    const c = Component{ .stride = 3, .rows = 1, .samples_w = 3, .samples_h = 1, .plane = &plane };
    var dst: [5]u8 = undefined;
    expandRow(&c, 2, 1, 0, &dst);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 13, 17, 23, 27 }, &dst);
}

test "jpeg: a DC-only block reconstructs with the 2D gain of one eighth" {
    var block: [64]f32 = @splat(0);
    block[0] = 72; // (137 - 128) * 8
    var out: [64]u8 = undefined;
    idct(&block, 1, &out);
    for (out) |v| try testing.expectEqual(@as(u8, 137), v);
    // An all-zero block is mid grey.
    block[0] = 0;
    idct(&block, 0, &out);
    for (out) |v| try testing.expectEqual(@as(u8, 128), v);
}

test "jpeg: the bit reader un-stuffs bytes, skips fills and stops at markers" {
    // 0xFF00 is a literal 0xFF; 0xFFD9 ends the data without being consumed.
    const data = [_]u8{ 0xAB, 0xFF, 0x00, 0xCD, 0xFF, 0xD9, 0x99 };
    var br = BitReader{ .data = &data, .pos = 0 };
    try testing.expectEqual(@as(u32, 0xAB), br.getBits(8));
    try testing.expectEqual(@as(u32, 0xFF), br.getBits(8));
    try testing.expectEqual(@as(u32, 0xCD), br.getBits(8));
    try testing.expectEqual(@as(?u8, null), br.marker);
    // Peeking past the end must stop at the marker without consuming it.
    _ = br.peek(8);
    try testing.expectEqual(@as(?u8, 0xD9), br.marker);
    try testing.expectEqual(@as(usize, 4), br.pos);
    try testing.expect(!br.truncated);

    // Repeated 0xFF before a stuffed byte are fill bytes, not markers.
    const fills = [_]u8{ 0xFF, 0xFF, 0x00, 0x11 };
    var fr = BitReader{ .data = &fills, .pos = 0 };
    try testing.expectEqual(@as(u32, 0xFF), fr.getBits(8));
    try testing.expectEqual(@as(u32, 0x11), fr.getBits(8));
    try testing.expectEqual(@as(?u8, null), fr.marker);
}

test "jpeg: running out of bytes with no marker is a truncated scan" {
    const data = [_]u8{ 0x01, 0x02 };
    var br = BitReader{ .data = &data, .pos = 0 };
    _ = br.peek(24);
    try testing.expect(br.truncated);
}

test "jpeg: magnitude values sign-extend around the JPEG bias" {
    try testing.expectEqual(@as(i32, 0), BitReader.extend(0, 0));
    try testing.expectEqual(@as(i32, -1), BitReader.extend(0, 1));
    try testing.expectEqual(@as(i32, 1), BitReader.extend(1, 1));
    try testing.expectEqual(@as(i32, -3), BitReader.extend(0, 2));
    try testing.expectEqual(@as(i32, -2), BitReader.extend(1, 2));
    try testing.expectEqual(@as(i32, 2), BitReader.extend(2, 2));
    try testing.expectEqual(@as(i32, 3), BitReader.extend(3, 2));
    try testing.expectEqual(@as(i32, -32767), BitReader.extend(0, 15));
    try testing.expectEqual(@as(i32, 32767), BitReader.extend(32767, 15));
}

test "jpeg: an over-subscribed Huffman code space is rejected" {
    // Three codes of length 1 cannot exist in a 2-symbol space.
    const counts = [_]u8{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const syms = [_]u8{ 1, 2, 3 };
    try testing.expectError(error.InvalidImage, Huffman.build(counts, &syms));
    // A count/symbol mismatch is rejected too.
    const ok_counts = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidImage, Huffman.build(ok_counts, &syms));
    const good = [_]u8{ 1, 2 };
    const h = try Huffman.build(ok_counts, &good);
    try testing.expectEqual(@as(u8, 1), h.fast_sym[0]);
    try testing.expectEqual(@as(u8, 2), h.fast_sym[1 << (fast_bits - 1)]);
}

test "jpeg: colour conversion matches libjpeg's fixed-point constants" {
    // Neutral chroma is a pure grey ramp.
    for (0..256) |y| {
        const rgb = ycbcrToRgb(@intCast(y), 128, 128);
        try testing.expectEqualSlices(u8, &[_]u8{ @intCast(y), @intCast(y), @intCast(y) }, &rgb);
    }
    // Extremes clamp rather than wrap. Full luma with maximum Cr drives red to
    // 433, which saturates at 255, while green lands on 255 - 91. Zero luma with
    // minimum Cr drives red negative (floored at 0) and green up to 91, since
    // green moves opposite to red and blue.
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 164, 255 }, &ycbcrToRgb(255, 128, 255));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 91, 0 }, &ycbcrToRgb(0, 128, 0));
    // Minimum Cb drives blue to -227, which floors at 0.
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 44, 0 }, &ycbcrToRgb(0, 0, 128));
}
