//! FLAC (Free Lossless Audio Codec) decoding, normalizing to interleaved f32.
//!
//! Supported, dependency-free subset — which is the whole baseline format:
//! - `STREAMINFO` plus any number of `PADDING`, `APPLICATION`, `SEEKTABLE`,
//!   `VORBIS_COMMENT`, `CUESHEET` and `PICTURE` metadata blocks (skipped).
//! - Fixed and variable block-size strategies, every legal block-size and
//!   sample-rate code, and UTF-8 coded frame/sample numbers.
//! - 1..8 independent channels and the three stereo decorrelation modes
//!   (left/side, right/side, mid/side).
//! - All four subframe types: `CONSTANT`, `VERBATIM`, `FIXED` (orders 0..4) and
//!   `LPC` (orders 1..32), with wasted-bit flags.
//! - Both residual coding methods (4-bit and 5-bit Rice parameters), any
//!   partition order, and the escaped raw-residual partition.
//! - Sample sizes 4..32 bits; the header CRC-8 and frame CRC-16 are verified.
//!
//! Normalization matches the WAV path exactly (see `audio.zig`): a sample is
//! divided by 2^(bits-1), so full scale maps to [-1, 1). No resampling,
//! downmixing or channel reordering is performed.
//!
//! Rejected with `error.InvalidAudio`, never approximated: a bad sync code or
//! reserved bit, reserved block-size/sample-rate/sample-size codes, a frame whose
//! geometry disagrees with `STREAMINFO`, reserved subframe types, an LPC shift
//! with the forbidden negative-precision code, a partition order that does not
//! divide the block, a truncated frame, a CRC mismatch, or a frame count that
//! disagrees with the declared total.
//!
//! Memory safety and performance: every field is read through a bounds-checked
//! bit reader over the frame's own slice, so a malformed frame cannot read past
//! it. Sample storage is `i64`, which makes every predictor and decorrelation
//! step overflow-free by construction rather than by a per-bit-depth argument —
//! including the `mid * 2` step at 32 bits. One block buffer sized from
//! `STREAMINFO` is allocated once and reused for every frame, and the residual is
//! decoded directly into the sample slots it will occupy, so there is no
//! per-frame allocation and no intermediate residual array. The fixed predictors
//! are specialized at comptime per order.
//!
//! This module depends on `std` and `audio.zig` (for the shared `Audio` type,
//! limits and artifact serializer) in one direction only. `audio.zig` does not
//! import this file; the engine registry in `assets.zig` composes both binding
//! lists, so there is no import cycle.

const std = @import("std");
const audio = @import("audio.zig");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const DecodeError = audio.DecodeError;
const ImportError = importer.ImportError;
const Importer = importer.Importer;

pub const magic = "fLaC";

/// FLAC allows up to 8 channels; the engine's own ceiling is the same.
pub const max_channels = audio.max_channels;
/// Largest block size the format can express (16-bit block-size code).
pub const max_block_size: u32 = 65535;
/// LPC predictor order is bounded by the 6-bit subframe type field.
pub const max_lpc_order: u32 = 32;

// --- CRC -------------------------------------------------------------------

/// FLAC uses non-reflected CRCs with a zero initial value: CRC-8 with polynomial
/// 0x07 over the frame header, CRC-16 with 0x8005 over the whole frame.
const crc8_table = makeCrcTable(u8, 0x07);
const crc16_table = makeCrcTable(u16, 0x8005);

fn makeCrcTable(comptime T: type, comptime poly: T) [256]T {
    @setEvalBranchQuota(20000);
    var table: [256]T = undefined;
    const bits = @bitSizeOf(T);
    const top = @as(T, 1) << (bits - 1);
    for (0..256) |i| {
        var r: T = @as(T, @intCast(i)) << (bits - 8);
        for (0..8) |_| {
            r = if (r & top != 0) (r << 1) ^ poly else r << 1;
        }
        table[i] = r;
    }
    return table;
}

fn crc8(bytes: []const u8) u8 {
    var r: u8 = 0;
    for (bytes) |b| r = crc8_table[r ^ b];
    return r;
}

fn crc16(bytes: []const u8) u16 {
    var r: u16 = 0;
    for (bytes) |b| r = (r << 8) ^ crc16_table[@as(u8, @truncate(r >> 8)) ^ b];
    return r;
}

// --- bit reader ------------------------------------------------------------

/// MSB-first bit reader over one frame. Every read is bounds-checked against the
/// frame slice; running past the end is `InvalidAudio`, never an out-of-bounds
/// access or a silent zero fill.
const BitReader = struct {
    data: []const u8,
    /// Bit position from the start of `data`.
    pos: usize = 0,

    fn remaining(self: *const BitReader) usize {
        return self.data.len * 8 - self.pos;
    }

    fn read(self: *BitReader, comptime T: type, n: u7) DecodeError!T {
        if (n == 0) return 0;
        if (n > @bitSizeOf(T)) return error.InvalidAudio;
        if (self.remaining() < n) return error.InvalidAudio;
        var acc: u64 = 0;
        var left: u7 = n;
        while (left > 0) {
            const byte = self.data[self.pos >> 3];
            const bit_off: u3 = @intCast(self.pos & 7);
            const avail: u7 = @as(u7, 8) - bit_off;
            const take: u7 = @min(avail, left);
            const shift: u3 = @intCast(avail - take);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(take)) - 1);
            acc = (acc << @intCast(take)) | ((byte >> shift) & mask);
            self.pos += take;
            left -= take;
        }
        // For a signed field, truncating keeps the low n bits and reinterprets
        // them as two's complement, which is exactly the field's value.
        if (@typeInfo(T).int.signedness == .signed) return @truncate(@as(i64, @bitCast(acc)));
        return @intCast(acc);
    }

    /// Signed field, sign-extended from `n` bits.
    fn readSigned(self: *BitReader, n: u7) DecodeError!i64 {
        if (n == 0 or n > 64) return error.InvalidAudio;
        const raw = try self.read(u64, n);
        if (n == 64) return @bitCast(raw);
        const sign_bit = @as(u64, 1) << @intCast(n - 1);
        if (raw & sign_bit == 0) return @intCast(raw);
        // Sign-extend without relying on shifts of a full-width value.
        return @as(i64, @intCast(raw)) - @as(i64, @intCast(sign_bit << 1));
    }

    /// Unary count of zero bits before the terminating one (Rice quotient).
    fn readUnary(self: *BitReader) DecodeError!u32 {
        var count: u32 = 0;
        while (true) {
            if (self.remaining() == 0) return error.InvalidAudio;
            const byte = self.data[self.pos >> 3];
            const bit_off: u3 = @intCast(self.pos & 7);
            const window = @as(u8, byte << bit_off);
            if (window == 0) {
                const consumed: u32 = @as(u32, 8) - bit_off;
                count += consumed;
                self.pos += consumed;
                // A quotient larger than any legal residual magnitude means the
                // frame is corrupt; bail out instead of looping for megabytes.
                if (count > 64 * 8) return error.InvalidAudio;
                continue;
            }
            const zeros: u32 = @clz(window);
            count += zeros;
            self.pos += zeros + 1;
            return count;
        }
    }

    fn alignToByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }
};

// --- stream info -----------------------------------------------------------

const StreamInfo = struct {
    min_block: u32 = 0,
    max_block: u32 = 0,
    min_frame: u32 = 0,
    max_frame: u32 = 0,
    sample_rate: u32 = 0,
    channels: u16 = 0,
    bits: u16 = 0,
    total_samples: u64 = 0,
};

fn readU24(b: []const u8, at: usize) u32 {
    return (@as(u32, b[at]) << 16) | (@as(u32, b[at + 1]) << 8) | b[at + 2];
}

/// Walk the metadata blocks, returning `STREAMINFO` and the offset of the first
/// audio frame.
fn parseMetadata(source: []const u8) DecodeError!struct { info: StreamInfo, frames_at: usize } {
    if (source.len < 4 + 4 + 34) return error.InvalidAudio;
    if (!std.mem.eql(u8, source[0..4], magic)) return error.InvalidAudio;

    var pos: usize = 4;
    var info: ?StreamInfo = null;
    while (true) {
        if (pos + 4 > source.len) return error.InvalidAudio;
        const header = source[pos];
        const last = header & 0x80 != 0;
        const kind = header & 0x7F;
        if (kind == 127) return error.InvalidAudio;
        const len = readU24(source, pos + 1);
        pos += 4;
        if (pos + len > source.len) return error.InvalidAudio;
        const body = source[pos .. pos + len];

        if (info == null) {
            // STREAMINFO must be the first metadata block.
            if (kind != 0 or len != 34) return error.InvalidAudio;
            var si = StreamInfo{};
            si.min_block = std.mem.readInt(u16, body[0..2], .big);
            si.max_block = std.mem.readInt(u16, body[2..4], .big);
            si.min_frame = readU24(body, 4);
            si.max_frame = readU24(body, 7);
            const fields = std.mem.readInt(u64, body[10..18], .big);
            si.sample_rate = @intCast(fields >> 44);
            si.channels = @as(u16, @intCast((fields >> 41) & 7)) + 1;
            si.bits = @as(u16, @intCast((fields >> 36) & 31)) + 1;
            si.total_samples = fields & ((@as(u64, 1) << 36) - 1);
            if (si.sample_rate == 0 or si.sample_rate > audio.max_sample_rate) return error.InvalidAudio;
            if (si.channels > max_channels) return error.InvalidAudio;
            if (si.bits < 4 or si.bits > 32) return error.InvalidAudio;
            if (si.min_block < 16 or si.max_block > max_block_size) return error.InvalidAudio;
            if (si.min_block > si.max_block) return error.InvalidAudio;
            info = si;
        } else if (kind == 0) {
            return error.InvalidAudio; // duplicate STREAMINFO
        }
        pos += len;
        if (last) break;
    }
    if (pos >= source.len) return error.InvalidAudio; // no audio frames
    return .{ .info = info.?, .frames_at = pos };
}

// --- frame header ----------------------------------------------------------

const Channels = enum { independent, left_side, right_side, mid_side };

const FrameHeader = struct {
    block_size: u32,
    sample_rate: u32,
    channels: u16,
    layout: Channels,
    bits: u16,
    /// Frame number (fixed strategy) or first sample number (variable).
    number: u64,
    variable: bool,
    header_len: usize,
};

const block_sizes = [16]u32{
    0,   192, 576,  1152, 2304, 4608, 0,     0,
    256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
};

const rate_codes = [12]u32{
    0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
};

const bit_codes = [8]u16{ 0, 8, 12, 0, 16, 20, 24, 32 };

/// Decode a UTF-8 coded number, which FLAC uses for the frame/sample index.
/// Only the canonical shortest form is accepted, so a frame cannot smuggle an
/// over-long encoding past the header CRC.
fn readUtf8Number(br: *BitReader) DecodeError!u64 {
    const first = try br.read(u8, 8);
    if (first < 0x80) return first;
    if (first < 0xC0) return error.InvalidAudio; // continuation byte or over-long
    // The two leading ones of the shortest multi-byte form already account for
    // one continuation byte; each further leading one adds another. So the scan
    // starts at bit 5, not bit 6.
    var extra: u7 = 1;
    var mask: u8 = 0x20;
    while (extra < 6 and first & mask != 0) : (mask >>= 1) extra += 1;
    if (first & mask != 0) return error.InvalidAudio; // 0xFE/0xFF are not valid leads
    const payload_bits: u3 = @intCast(6 - extra);
    var acc: u64 = first & ((@as(u8, 1) << payload_bits) - 1);
    for (0..extra) |_| {
        const b = try br.read(u8, 8);
        if (b & 0xC0 != 0x80) return error.InvalidAudio;
        acc = (acc << 6) | (b & 0x3F);
    }
    // Reject over-long encodings: the value must need this many bytes.
    const min_for_len = [_]u64{ 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000, 0x80000000 };
    if (acc < min_for_len[extra]) return error.InvalidAudio;
    return acc;
}

fn parseFrameHeader(bytes: []const u8, info: StreamInfo) DecodeError!FrameHeader {
    var br = BitReader{ .data = bytes };
    const sync = try br.read(u16, 14);
    if (sync != 0x3FFE) return error.InvalidAudio;
    if (try br.read(u1, 1) != 0) return error.InvalidAudio; // reserved
    const variable = try br.read(u1, 1) == 1;
    const block_code = try br.read(u4, 4);
    const rate_code = try br.read(u4, 4);
    const chan_code = try br.read(u4, 4);
    const bits_code = try br.read(u3, 3);
    if (try br.read(u1, 1) != 0) return error.InvalidAudio; // reserved

    const number = try readUtf8Number(&br);

    var block_size: u32 = block_sizes[block_code];
    switch (block_code) {
        0 => return error.InvalidAudio, // reserved
        6 => block_size = @as(u32, try br.read(u8, 8)) + 1,
        7 => block_size = @as(u32, try br.read(u16, 16)) + 1,
        else => {},
    }

    var sample_rate: u32 = info.sample_rate;
    switch (rate_code) {
        0 => {},
        12 => sample_rate = @as(u32, try br.read(u8, 8)) * 1000,
        13 => sample_rate = try br.read(u16, 16),
        14 => sample_rate = @as(u32, try br.read(u16, 16)) * 10,
        15 => return error.InvalidAudio, // forbidden, invalidates the frame
        else => sample_rate = rate_codes[rate_code],
    }

    var layout: Channels = .independent;
    var channels: u16 = 0;
    switch (chan_code) {
        0...7 => channels = @as(u16, chan_code) + 1,
        8 => {
            layout = .left_side;
            channels = 2;
        },
        9 => {
            layout = .right_side;
            channels = 2;
        },
        10 => {
            layout = .mid_side;
            channels = 2;
        },
        else => return error.InvalidAudio,
    }

    const bits: u16 = if (bits_code == 0) info.bits else bit_codes[bits_code];
    if (bits == 0) return error.InvalidAudio; // codes 3 is reserved

    // The header CRC-8 covers every byte up to and including itself.
    br.alignToByte();
    const header_len = br.pos / 8;
    if (header_len + 1 > bytes.len) return error.InvalidAudio;
    if (crc8(bytes[0..header_len]) != bytes[header_len]) return error.InvalidAudio;

    // A frame must agree with the stream it claims to belong to.
    if (channels != info.channels) return error.InvalidAudio;
    if (sample_rate != info.sample_rate) return error.InvalidAudio;
    if (bits != info.bits) return error.InvalidAudio;
    if (block_size > info.max_block) return error.InvalidAudio;
    if (sample_rate == 0 or sample_rate > audio.max_sample_rate) return error.InvalidAudio;

    return .{
        .block_size = block_size,
        .sample_rate = sample_rate,
        .channels = channels,
        .layout = layout,
        .bits = bits,
        .number = number,
        .variable = variable,
        .header_len = header_len + 1,
    };
}

// --- subframes -------------------------------------------------------------

/// Rice-coded residual, decoded straight into the sample slots it belongs to.
/// `warmup` slots already hold the predictor's history and are left untouched.
fn decodeResidual(br: *BitReader, dst: []i64, warmup: usize, block_size: usize) DecodeError!void {
    const method = try br.read(u2, 2);
    if (method > 1) return error.InvalidAudio;
    const param_bits: u7 = if (method == 0) 4 else 5;
    const escape: u32 = if (method == 0) 15 else 31;
    const order = try br.read(u4, 4);
    const partitions = @as(usize, 1) << @intCast(order);
    if (block_size % partitions != 0) return error.InvalidAudio;
    const part_len = block_size / partitions;
    if (part_len < warmup) return error.InvalidAudio;
    if (partitions > 1 and part_len == 0) return error.InvalidAudio;

    var at: usize = warmup;
    for (0..partitions) |p| {
        const count = if (p == 0) part_len - warmup else part_len;
        const param = try br.read(u5, @intCast(param_bits));
        if (param == escape) {
            // Escaped partition: residuals are stored raw at an explicit width.
            const raw_bits = try br.read(u5, 5);
            if (raw_bits > 64) return error.InvalidAudio;
            for (0..count) |_| {
                dst[at] = try br.readSigned(@intCast(raw_bits));
                at += 1;
            }
            continue;
        }
        for (0..count) |_| {
            const q = try br.readUnary();
            const r = try br.read(u32, @intCast(param));
            if (q > (@as(u32, std.math.maxInt(u32)) >> @intCast(param))) return error.InvalidAudio;
            const unsigned = (q << @intCast(param)) | r;
            // Fold the unsigned Rice value back to a signed residual.
            const signed: i64 = if (unsigned & 1 == 0)
                @as(i64, unsigned >> 1)
            else
                -@as(i64, unsigned >> 1) - 1;
            dst[at] = signed;
            at += 1;
        }
    }
    if (at != block_size) return error.InvalidAudio;
}

/// Restore a fixed predictor in place. Specialized per order so the inner loop
/// has no per-sample branch on the order.
fn restoreFixed(comptime order: u32, s: []i64) void {
    var i: usize = order;
    while (i < s.len) : (i += 1) {
        const r = s[i];
        s[i] = switch (order) {
            0 => r,
            1 => r + s[i - 1],
            2 => r + 2 * s[i - 1] - s[i - 2],
            3 => r + 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3],
            4 => r + 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4],
            else => unreachable,
        };
    }
}

fn decodeSubframe(br: *BitReader, dst: []i64, bits: u16) DecodeError!void {
    if (try br.read(u1, 1) != 0) return error.InvalidAudio; // zero padding
    const kind = try br.read(u6, 6);
    const has_wasted = try br.read(u1, 1) == 1;
    var wasted: u7 = 0;
    if (has_wasted) {
        // The unary value is k-1, so the wasted-bit count is one more.
        const u = try br.readUnary();
        if (u >= bits) return error.InvalidAudio;
        wasted = @intCast(u + 1);
        if (wasted >= bits) return error.InvalidAudio;
    }
    const effective: u16 = bits - wasted;
    const n = dst.len;

    switch (kind) {
        0 => { // CONSTANT
            const v = try br.readSigned(@intCast(effective));
            @memset(dst, v);
        },
        1 => { // VERBATIM
            for (0..n) |i| dst[i] = try br.readSigned(@intCast(effective));
        },
        8...12 => { // FIXED, order = kind - 8
            const order: u32 = kind - 8;
            if (order > n) return error.InvalidAudio;
            for (0..order) |i| dst[i] = try br.readSigned(@intCast(effective));
            try decodeResidual(br, dst, order, n);
            switch (order) {
                0 => restoreFixed(0, dst),
                1 => restoreFixed(1, dst),
                2 => restoreFixed(2, dst),
                3 => restoreFixed(3, dst),
                4 => restoreFixed(4, dst),
                else => unreachable,
            }
        },
        32...63 => { // LPC, order = kind - 31
            const order: u32 = kind - 31;
            if (order > n or order > max_lpc_order) return error.InvalidAudio;
            for (0..order) |i| dst[i] = try br.readSigned(@intCast(effective));
            const precision_code = try br.read(u4, 4);
            if (precision_code == 15) return error.InvalidAudio; // forbidden
            const precision: u7 = @as(u7, precision_code) + 1;
            const shift = try br.read(i5, 5);
            if (shift < 0) return error.InvalidAudio; // negative shifts are invalid
            var coeffs: [max_lpc_order]i64 = undefined;
            for (0..order) |i| coeffs[i] = try br.readSigned(@intCast(precision));
            try decodeResidual(br, dst, order, n);
            const sh: u6 = @intCast(shift);
            var i: usize = order;
            while (i < n) : (i += 1) {
                var sum: i64 = 0;
                for (0..order) |j| sum += coeffs[j] * dst[i - 1 - j];
                dst[i] += sum >> sh;
            }
        },
        else => return error.InvalidAudio, // reserved subframe type
    }

    if (wasted != 0) {
        const sh: u6 = @intCast(wasted);
        for (dst) |*v| v.* <<= sh;
    }
}

/// Undo the inter-channel decorrelation in place, leaving channel 0 = left and
/// channel 1 = right. `i64` storage makes the `mid * 2` step safe even at 32 bits.
fn decorrelate(layout: Channels, block: []i64, n: usize) void {
    // Independent frames may have any channel count, including one, so the
    // second channel is only sliced for the two-channel decorrelation modes.
    if (layout == .independent) return;
    const c0 = block[0..n];
    const c1 = block[n..][0..n];
    switch (layout) {
        .independent => unreachable,
        .left_side => {
            // channel 0 = left, channel 1 = side; right = left - side
            for (c0, c1) |l, *side| side.* = l - side.*;
        },
        .right_side => {
            // channel 0 = side, channel 1 = right; left = right + side
            for (c0, c1) |*side, r| {
                const left = r + side.*;
                side.* = left;
            }
            // c0 now holds left and c1 still holds right: already in order.
        },
        .mid_side => {
            for (c0, c1) |*mid, *side| {
                const m = mid.* * 2 + (side.* & 1);
                mid.* = (m + side.*) >> 1;
                side.* = (m - side.*) >> 1;
            }
        },
    }
}

// --- frame decoding --------------------------------------------------------

/// Find the end of the frame starting at `start`, verifying its CRC-16.
///
/// FLAC frames are not length-prefixed, so the decoder must discover the boundary
/// by decoding the subframes: the bit reader's final position locates the padding
/// and the CRC-16, and the CRC then proves the boundary was right. The decoder
/// never scans for the next sync code, which would mis-frame any payload that
/// happens to contain one. `max_frame` from STREAMINFO only bounds the header
/// slice when the encoder recorded it.
fn decodeFrame(
    source: []const u8,
    start: usize,
    info: StreamInfo,
    block: []i64,
) DecodeError!struct { header: FrameHeader, next: usize } {
    const avail = source.len - start;
    if (avail < 4) return error.InvalidAudio;
    const limit = if (info.max_frame != 0 and info.max_frame < avail) info.max_frame else avail;
    const header = try parseFrameHeader(source[start .. start + limit], info);
    const n: usize = header.block_size;
    const channels: usize = header.channels;
    if (n == 0 or n > info.max_block) return error.InvalidAudio;
    if (n * channels > block.len) return error.InvalidAudio;

    // FLAC frames are not length-prefixed. Decoding the subframes tells us
    // exactly where the padding and CRC-16 begin, and the CRC then proves the
    // boundary was right -- no scanning for the next sync code, no guessing.
    const body_start = start + header.header_len;
    var br = BitReader{ .data = source[body_start..] };
    for (0..channels) |c| {
        // The side channel carries one extra bit. It is channel 1 for left/side
        // and mid/side, but channel 0 for right/side.
        var bits = header.bits;
        const is_side = (header.layout == .right_side and c == 0) or
            (header.layout != .independent and header.layout != .right_side and c == 1);
        if (is_side) bits += 1;
        if (bits > 33) return error.InvalidAudio;
        try decodeSubframe(&br, block[c * n ..][0..n], bits);
    }
    br.alignToByte();
    const crc_at = body_start + br.pos / 8;
    if (crc_at + 2 > source.len) return error.InvalidAudio;
    const stored = std.mem.readInt(u16, source[crc_at..][0..2], .big);
    if (crc16(source[start..crc_at]) != stored) return error.InvalidAudio;

    decorrelate(header.layout, block, n);
    return .{ .header = header, .next = crc_at + 2 };
}

// --- public entry point ----------------------------------------------------

/// Decode a FLAC stream into interleaved float32. The caller owns
/// `Audio.samples` and releases it with `Audio.deinit`.
pub fn decode(gpa: Allocator, source: []const u8) DecodeError!audio.Audio {
    const meta = try parseMetadata(source);
    const info = meta.info;
    const channels: usize = info.channels;

    // Bound the output before allocating anything, using the declared total.
    if (info.total_samples != 0) {
        const count = std.math.mul(usize, @intCast(info.total_samples), channels) catch return error.InvalidAudio;
        const bytes = std.math.mul(usize, count, 4) catch return error.InvalidAudio;
        if (bytes > audio.max_sample_bytes) return error.InvalidAudio;
    }

    // One block buffer, sized from STREAMINFO and reused for every frame.
    const block_cap = @as(usize, info.max_block) * channels;
    const block = gpa.alloc(i64, block_cap) catch return error.OutOfMemory;
    defer gpa.free(block);

    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(gpa);
    if (info.total_samples != 0) {
        const count: usize = @as(usize, @intCast(info.total_samples)) * channels;
        samples.ensureTotalCapacity(gpa, count) catch return error.OutOfMemory;
    }

    const scale: f32 = 1.0 / @as(f32, @floatFromInt(@as(i64, 1) << @intCast(info.bits - 1)));
    var pos = meta.frames_at;
    var frames: u64 = 0;
    var frame_index: u64 = 0;
    var variable_strategy = false;
    while (pos < source.len) {
        const res = try decodeFrame(source, pos, info, block);
        const n: usize = res.header.block_size;

        // The frame index must advance exactly: frame numbers for the fixed
        // strategy, first-sample numbers for the variable one.
        const expected: u64 = if (res.header.variable) frames else frame_index;
        if (res.header.number != expected) return error.InvalidAudio;
        // The blocking strategy is a property of the stream, not of one frame.
        if (frame_index == 0) {
            variable_strategy = res.header.variable;
        } else if (res.header.variable != variable_strategy) {
            return error.InvalidAudio;
        }

        frames += n;
        frame_index += 1;
        if (info.total_samples != 0 and frames > info.total_samples) return error.InvalidAudio;
        const count = std.math.mul(usize, frames, channels) catch return error.InvalidAudio;
        const bytes = std.math.mul(usize, count, 4) catch return error.InvalidAudio;
        if (bytes > audio.max_sample_bytes) return error.InvalidAudio;

        samples.ensureTotalCapacity(gpa, count) catch return error.OutOfMemory;
        for (0..n) |i| {
            for (0..channels) |c| {
                samples.appendAssumeCapacity(@as(f32, @floatFromInt(block[c * n + i])) * scale);
            }
        }
        pos = res.next;
        if (info.total_samples != 0 and frames == info.total_samples) break;
    }
    if (frames == 0) return error.InvalidAudio;
    if (info.total_samples != 0 and frames != info.total_samples) return error.InvalidAudio;
    if (frames > std.math.maxInt(u32)) return error.InvalidAudio;

    return .{
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .frames = @intCast(frames),
        .samples = samples.toOwnedSlice(gpa) catch return error.OutOfMemory,
    };
}

/// Decode a FLAC source and serialize it to a `CXAW` artifact.
pub fn importFlac(gpa: Allocator, source: []const u8) ImportError![]u8 {
    var clip = decode(gpa, source) catch |err| return audio.mapDecodeError(err);
    defer clip.deinit(gpa);
    return audio.serialize(gpa, clip);
}

pub const flac_importer = Importer{ .id = "flac", .version = 1, .importFn = importFlac };

/// Extension bindings for the engine registry (composed by `assets.zig`).
pub const bindings = [_]importer.Registry.Binding{
    .{ .extensions = &[_][]const u8{".flac"}, .importer = flac_importer },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const vectors = @import("flac_vectors.zig");
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

fn findVector(name: []const u8) vectors.Flac {
    for (vectors.valid) |v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    unreachable; // a renamed vector must fail loudly, not silently skip
}

test "flac: every libFLAC vector decodes bit-exactly" {
    const gpa = testing.allocator;
    for (vectors.valid) |v| {
        const src = try unhex(gpa, v.flac_hex);
        defer gpa.free(src);
        const expected = try unhex(gpa, v.f32_hex);
        defer gpa.free(expected);

        var clip = decode(gpa, src) catch |err| {
            std.debug.print("\nvector {s} failed: {s}\n", .{ v.name, @errorName(err) });
            return err;
        };
        defer clip.deinit(gpa);

        if (clip.sample_rate != v.sample_rate or clip.channels != v.channels or
            clip.frames != v.frames)
        {
            std.debug.print("\nvector {s}: geometry {d}Hz/{d}ch/{d}f, expected {d}/{d}/{d}\n", .{
                v.name,        clip.sample_rate, clip.channels, clip.frames,
                v.sample_rate, v.channels,       v.frames,
            });
            return error.TestUnexpectedResult;
        }
        // FLAC is lossless: compare the raw f32 bytes, so even a sign-of-zero
        // difference is a failure. There is no tolerance to tune.
        const got = std.mem.sliceAsBytes(clip.samples);
        if (!std.mem.eql(u8, got, expected)) {
            var at: usize = 0;
            while (at < @min(got.len, expected.len) and got[at] == expected[at]) at += 1;
            std.debug.print("\nvector {s}: first differing byte {d} of {d}\n", .{
                v.name, at, expected.len,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "flac: the corpus reaches every format feature it claims to cover" {
    // Guards against the corpus silently losing coverage when it is regenerated.
    var layouts: [4]bool = @splat(false);
    var depths: [33]bool = @splat(false);
    var channels: [9]bool = @splat(false);
    var multi_frame = false;
    for (vectors.valid) |v| {
        depths[v.bits] = true;
        channels[v.channels] = true;
        if (v.frames > 4096) multi_frame = true;
        if (std.mem.startsWith(u8, v.name, "mid_side")) layouts[3] = true;
    }
    for ([_]u16{ 8, 12, 16, 20, 24, 32 }) |b| try testing.expect(depths[b]);
    for (1..9) |c| try testing.expect(channels[c]);
    try testing.expect(layouts[3]);
    try testing.expect(multi_frame);
    try testing.expect(vectors.valid.len >= 66);
    try testing.expect(vectors.invalid.len >= 16);
}

test "flac: malformed streams are rejected" {
    const gpa = testing.allocator;
    for (vectors.invalid) |v| {
        const src = try unhex(gpa, v.flac_hex);
        defer gpa.free(src);
        if (decode(gpa, src)) |*clip| {
            var mutable = clip.*;
            mutable.deinit(gpa);
            std.debug.print("\nmalformed vector {s} was accepted\n", .{v.name});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != error.InvalidAudio) return err;
        }
    }
}

test "flac: allocation failures propagate without leaking" {
    const gpa = testing.allocator;
    const src = try unhex(gpa, findVector("chan2").flac_hex);
    defer gpa.free(src);
    const Probe = struct {
        fn run(alloc: Allocator, bytes: []const u8) !void {
            var clip = try decode(alloc, bytes);
            clip.deinit(alloc);
        }
    };
    try alloc_probe.check(Probe.run, .{src});
}

test "flac: importing produces a CXAW artifact identical to the WAV path" {
    const gpa = testing.allocator;
    const v = findVector("stereo_correlated");
    const src = try unhex(gpa, v.flac_hex);
    defer gpa.free(src);

    const artifact = try importFlac(gpa, src);
    defer gpa.free(artifact);
    const view = try audio.parse(artifact);
    try testing.expectEqual(v.sample_rate, view.sample_rate);
    try testing.expectEqual(v.channels, view.channels);
    try testing.expectEqual(v.frames, view.frames);

    const expected = try unhex(gpa, v.f32_hex);
    defer gpa.free(expected);
    try testing.expectEqualSlices(u8, expected, view.sample_bytes);

    // Re-serializing the parsed view must reproduce the artifact byte for byte.
    var clip = try decode(gpa, src);
    defer clip.deinit(gpa);
    const again = try audio.serialize(gpa, clip);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, artifact, again);
}

test "flac: import errors map to the registry's error set" {
    const gpa = testing.allocator;
    const src = try unhex(gpa, vectors.invalid[0].flac_hex);
    defer gpa.free(src);
    try testing.expectError(error.InvalidAsset, importFlac(gpa, src));
}

test "flac: the importer binding claims only .flac at version 1" {
    try testing.expectEqualStrings("flac", flac_importer.id);
    try testing.expectEqual(@as(u32, 1), flac_importer.version);
    try testing.expectEqual(@as(usize, 1), bindings.len);
    try testing.expectEqualStrings(".flac", bindings[0].extensions[0]);
}

test "flac: CRC tables match the published check values" {
    // CRC-8 (poly 0x07) and CRC-16/BUYPASS (poly 0x8005), both non-reflected
    // with a zero init, check to 0xF4 and 0xFEE8 over "123456789".
    try testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
    try testing.expectEqual(@as(u16, 0xFEE8), crc16("123456789"));
    try testing.expectEqual(@as(u8, 0), crc8(""));
    try testing.expectEqual(@as(u16, 0), crc16(""));
}

test "flac: coded numbers round-trip across every UTF-8 width" {
    const cases = [_]struct { value: u64, bytes: []const u8 }{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 127, .bytes = &.{0x7F} },
        .{ .value = 128, .bytes = &.{ 0xC2, 0x80 } },
        .{ .value = 2047, .bytes = &.{ 0xDF, 0xBF } },
        .{ .value = 2048, .bytes = &.{ 0xE0, 0xA0, 0x80 } },
        .{ .value = 65535, .bytes = &.{ 0xEF, 0xBF, 0xBF } },
        .{ .value = 0x1FFFFF, .bytes = &.{ 0xF7, 0xBF, 0xBF, 0xBF } },
        .{ .value = 0x3FFFFFF, .bytes = &.{ 0xFB, 0xBF, 0xBF, 0xBF, 0xBF } },
        .{ .value = 0x7FFFFFFF, .bytes = &.{ 0xFD, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF } },
        .{ .value = 0xFFFFFFFFF, .bytes = &.{ 0xFE, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF } },
    };
    for (cases) |c| {
        var br = BitReader{ .data = c.bytes };
        try testing.expectEqual(c.value, try readUtf8Number(&br));
        try testing.expectEqual(c.bytes.len * 8, br.pos);
    }
}

test "flac: over-long and malformed coded numbers are rejected" {
    const bad = [_][]const u8{
        &.{0x80}, // bare continuation byte
        &.{0xBF}, // bare continuation byte
        &.{ 0xFF, 0x80 }, // 0xFF is not a valid lead
        &.{ 0xC0, 0x80 }, // over-long encoding of zero
        &.{ 0xE0, 0x80, 0x80 }, // over-long, three bytes
        &.{ 0xC2, 0x41 }, // continuation lacks 10xxxxxx
        &.{0xC2}, // truncated
        &.{ 0xFE, 0x80, 0x80, 0x80, 0x80 }, // truncated seven-byte form
    };
    for (bad) |bytes| {
        var br = BitReader{ .data = bytes };
        try testing.expectError(error.InvalidAudio, readUtf8Number(&br));
    }
}

test "flac: the bit reader never reads past its slice" {
    var br = BitReader{ .data = &.{ 0xAB, 0xCD } };
    try testing.expectEqual(@as(u16, 0xAB), try br.read(u16, 8));
    try testing.expectEqual(@as(u4, 0xC), try br.read(u4, 4));
    try testing.expectEqual(@as(usize, 4), br.remaining());
    try testing.expectError(error.InvalidAudio, br.read(u8, 8));
    try testing.expectError(error.InvalidAudio, br.read(u32, 5));
    try testing.expectEqual(@as(u4, 0xD), try br.read(u4, 4));
    try testing.expectEqual(@as(usize, 0), br.remaining());
    try testing.expectError(error.InvalidAudio, br.read(u1, 1));
}

test "flac: a residual partition shorter than the warmup is rejected" {
    // partitions > 1 with part_len < warmup must be rejected, not underflow.
    // block_size=16, order=3 -> partitions=8 -> part_len=2; warmup=4.
    var dst: [16]i64 = @splat(0);
    // method=0 (Rice, u2), order=3 (u4): 0b00_0011 then anything.
    var br = BitReader{ .data = &.{ 0b0000_0011, 0x00, 0x00 } };
    try testing.expectError(error.InvalidAudio, decodeResidual(&br, &dst, 4, 16));
    // partitions == 2 with part_len < warmup is rejected too.
    var br2 = BitReader{ .data = &.{ 0b0000_0100, 0x00, 0x00 } };
    try testing.expectError(error.InvalidAudio, decodeResidual(&br2, &dst, 4, 4));

    // partitions == 1 with part_len < warmup is rejected too.
    var br1 = BitReader{ .data = &.{ 0b0000_0000, 0x00, 0x00 } };
    try testing.expectError(error.InvalidAudio, decodeResidual(&br1, &dst, 4, 2));
}

test "flac: signed fields sign-extend and unary runs are bounded" {
    var br = BitReader{ .data = &.{ 0xFF, 0x80 } };
    try testing.expectEqual(@as(i64, -1), try br.readSigned(4));
    // The next eight bits straddle the byte boundary: 0xF8, not 0xFF.
    try testing.expectEqual(@as(i64, -8), try br.readSigned(8));
    try testing.expectEqual(@as(i64, 0), try br.readSigned(4));

    // An unterminated unary run must fail rather than spin or overflow.
    var zeros = BitReader{ .data = &@as([80]u8, @splat(0)) };
    try testing.expectError(error.InvalidAudio, zeros.readUnary());
}

test "flac: fixed predictors reconstruct their reference sequences" {
    // A quadratic ramp has zero third-order residual, so order 3 must rebuild it
    // exactly from three warmup samples.
    var s = [_]i64{ 1, 4, 9, 0, 0, 0, 0 };
    restoreFixed(3, &s);
    try testing.expectEqualSlices(i64, &.{ 1, 4, 9, 16, 25, 36, 49 }, &s);

    var lin = [_]i64{ 5, 0, 0, 0 };
    restoreFixed(1, &lin);
    try testing.expectEqualSlices(i64, &.{ 5, 5, 5, 5 }, &lin);

    var ramp = [_]i64{ 2, 5, 0, 0, 0 };
    restoreFixed(2, &ramp);
    try testing.expectEqualSlices(i64, &.{ 2, 5, 8, 11, 14 }, &ramp);

    var cubic = [_]i64{ 1, 8, 27, 64, 0, 0 };
    restoreFixed(4, &cubic);
    try testing.expectEqualSlices(i64, &.{ 1, 8, 27, 64, 125, 216 }, &cubic);

    var raw = [_]i64{ 3, -4, 5 };
    restoreFixed(0, &raw);
    try testing.expectEqualSlices(i64, &.{ 3, -4, 5 }, &raw);
}

test "flac: decorrelation inverts all three stereo modes" {
    const left = [_]i64{ 10, -7, 32767, -32768, 0 };
    const right = [_]i64{ 4, -9, -32768, 32767, 0 };
    const n = left.len;

    // left/side: channel 1 holds left - right.
    var ls: [n * 2]i64 = undefined;
    for (0..n) |i| {
        ls[i] = left[i];
        ls[n + i] = left[i] - right[i];
    }
    decorrelate(.left_side, &ls, n);
    try testing.expectEqualSlices(i64, &left, ls[0..n]);
    try testing.expectEqualSlices(i64, &right, ls[n..]);

    // right/side: channel 0 holds left - right and is the widened one.
    var rs: [n * 2]i64 = undefined;
    for (0..n) |i| {
        rs[i] = left[i] - right[i];
        rs[n + i] = right[i];
    }
    decorrelate(.right_side, &rs, n);
    try testing.expectEqualSlices(i64, &left, rs[0..n]);
    try testing.expectEqualSlices(i64, &right, rs[n..]);

    // mid/side: mid is the arithmetic mean rounded down, side is left - right.
    var ms: [n * 2]i64 = undefined;
    for (0..n) |i| {
        ms[i] = (left[i] + right[i]) >> 1;
        ms[n + i] = left[i] - right[i];
    }
    decorrelate(.mid_side, &ms, n);
    try testing.expectEqualSlices(i64, &left, ms[0..n]);
    try testing.expectEqualSlices(i64, &right, ms[n..]);
}

test "flac: mono decorrelation is a no-op and mid/side survives 32-bit extremes" {
    // The independent path must not slice a second channel that does not exist.
    var mono = [_]i64{ 1, 2, 3 };
    decorrelate(.independent, &mono, 3);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, &mono);

    // mid * 2 at the 32-bit extremes would overflow i32/i40; i64 storage makes
    // it exact by construction.
    const l: i64 = 2147483647;
    const r: i64 = -2147483648;
    var ms = [_]i64{ (l + r) >> 1, l - r };
    decorrelate(.mid_side, &ms, 1);
    try testing.expectEqual(l, ms[0]);
    try testing.expectEqual(r, ms[1]);
}

test "flac: wasted bits are unary-coded as count minus one" {
    // Subframe header: pad 0, type 000001 (VERBATIM), wasted flag 1, then the
    // unary run for k-1. Two zeros followed by a one means three wasted bits,
    // so the 5-bit payloads (5 and -2) are shifted left by three.
    var br = BitReader{ .data = &.{ 0x03, 0x25, 0xF0 } };
    var dst: [2]i64 = undefined;
    try decodeSubframe(&br, &dst, 8);
    try testing.expectEqual(@as(i64, 40), dst[0]);
    try testing.expectEqual(@as(i64, -16), dst[1]);
}

test "flac: block-size, sample-rate and sample-size tables match the format" {
    try testing.expectEqualSlices(u32, &.{
        0,   192, 576,  1152, 2304, 4608, 0,     0,
        256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
    }, &block_sizes);
    try testing.expectEqualSlices(u32, &.{
        0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
    }, &rate_codes);
    try testing.expectEqualSlices(u16, &.{ 0, 8, 12, 0, 16, 20, 24, 32 }, &bit_codes);
}

test "flac: every truncation of a valid stream is rejected without panicking" {
    const gpa = testing.allocator;
    const src = try unhex(gpa, findVector("len2").flac_hex);
    defer gpa.free(src);
    // Every proper prefix must be a clean InvalidAudio: the bit reader and the
    // metadata walker are bounds-checked, so no prefix may trap.
    for (0..src.len) |n| {
        if (decode(gpa, src[0..n])) |*clip| {
            var mutable = clip.*;
            mutable.deinit(gpa);
            std.debug.print("\nprefix of length {d} was accepted\n", .{n});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != error.InvalidAudio) return err;
        }
    }
    var whole = try decode(gpa, src);
    whole.deinit(gpa);
}

test "flac: trailing garbage after the declared total is ignored, not decoded" {
    const gpa = testing.allocator;
    const v = findVector("len2");
    const src = try unhex(gpa, v.flac_hex);
    defer gpa.free(src);
    const padded = try std.mem.concat(gpa, u8, &.{ src, &@as([32]u8, @splat(0xFF)) });
    defer gpa.free(padded);
    // STREAMINFO's total is authoritative, so decoding stops at the last frame.
    var clip = try decode(gpa, padded);
    defer clip.deinit(gpa);
    try testing.expectEqual(v.frames, clip.frames);
}

test "flac: empty and undersized inputs are rejected" {
    const gpa = testing.allocator;
    const tiny_inputs = [_][]const u8{ "", "f", "fLa", "fLaC", "fLaC\x80\x00" };
    for (tiny_inputs) |src| {
        try testing.expectError(error.InvalidAudio, decode(gpa, src));
    }
}
