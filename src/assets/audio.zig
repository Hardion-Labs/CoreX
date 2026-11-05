//! WAV audio decoding and the engine-ready audio artifact (`CXAW`).
//!
//! The importer decodes a RIFF/WAVE source into interleaved **float32** samples
//! and serializes them into a self-describing `CXAW` container the audio runtime
//! can mix without re-parsing the source. The container is the derived artifact
//! stored in the content-addressed cache; its identity is the importer
//! `id` + `version`, so changing the layout and bumping the version invalidates
//! affected entries automatically.
//!
//! Supported subset (documented, honest — unsupported codecs are rejected):
//! - Uncompressed integer PCM: 8-bit unsigned, 16/24/32-bit signed, little-endian.
//! - IEEE float 32-bit (`WAVE_FORMAT_IEEE_FLOAT`).
//! - `WAVE_FORMAT_EXTENSIBLE` with a PCM or IEEE-float subformat GUID; the
//!   channel mask is read past but channel **order** is preserved as stored.
//! - 1..8 channels, any sample rate up to 384 kHz, any number of frames within
//!   the size ceiling. Ancillary chunks (`LIST`, `fact`, `cue `, `id3 `, ...) are
//!   skipped; `fmt ` must precede `data`, and exactly one of each is required.
//!
//! Normalization rules (documented, not silent):
//! - Integer samples are divided by 2^(bits-1), so full scale maps to [-1, 1).
//!   8-bit PCM is unsigned in the source and is re-centered on 128.
//! - 24-bit samples are sign-extended from three bytes.
//! - Float samples pass through **unchanged**, including values outside [-1, 1]
//!   (float headroom is legal and useful for mixing). Non-finite samples
//!   (NaN/Infinity) are rejected.
//! - No resampling, downmixing or channel reordering is performed: the artifact
//!   keeps the source rate, channel count and channel order.
//!
//! Rejected rather than faked: ADPCM, A-law/µ-law, GSM and every other compressed
//! codec; 64-bit float; more than 8 channels; a `data` chunk that is not a whole
//! number of frames; a RIFF size that disagrees with the file length.
//!
//! Layout (little-endian):
//!   bytes 0..4    magic "CXAW"
//!   bytes 4..8    format_version (u32 = 1)
//!   bytes 8..12   sample_rate    (u32, Hz)
//!   bytes 12..14  channels       (u16)
//!   bytes 14..16  sample_format  (u16 = 0, interleaved f32)
//!   bytes 16..20  frame_count    (u32)
//!   bytes 20..    frame_count*channels interleaved f32 samples
//!
//! `parse` is zero-copy and alignment-safe: it returns a byte view plus accessors
//! that read little-endian fields explicitly (no pointer casts), and validates
//! structure and float finiteness in one linear pass so downstream consumers
//! never see a NaN. This module depends only on `std` and `importer.zig`, so it
//! stays independently testable and loosely coupled from the pipeline/cache.

const std = @import("std");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const ImportError = importer.ImportError;
const Importer = importer.Importer;

pub const DecodeError = error{
    /// The source bytes are not a valid WAV of the supported subset.
    InvalidAudio,
    OutOfMemory,
};

/// Maximum channel count accepted (7.1 surround).
pub const max_channels: u16 = 8;
/// Maximum sample rate accepted, in Hz.
pub const max_sample_rate: u32 = 384_000;
/// Maximum decoded sample buffer size (matches the cache artifact ceiling).
pub const max_sample_bytes: usize = 256 * 1024 * 1024;
/// Maximum frame count implied by the size ceiling for a mono stream.
pub const max_frames: u32 = @intCast(max_sample_bytes / 4);

pub const format_version: u32 = 1;
pub const magic = "CXAW";
pub const header_size: usize = 20;

/// Sample layouts understood by the audio runtime. Only interleaved f32 exists
/// today; planar and compressed layouts are future work and are rejected.
pub const SampleFormat = enum(u16) {
    f32_interleaved = 0,
};

/// A decoded audio clip. `samples.len == frames * channels`, interleaved.
pub const Audio = struct {
    sample_rate: u32,
    channels: u16,
    frames: u32,
    samples: []f32,

    pub fn deinit(self: *Audio, gpa: Allocator) void {
        gpa.free(self.samples);
        self.* = undefined;
    }

    pub fn sampleCount(self: Audio) usize {
        return @as(usize, self.frames) * @as(usize, self.channels);
    }

    pub fn durationSeconds(self: Audio) f64 {
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// A parsed, zero-copy view into a `CXAW` artifact. The caller owns the backing
/// bytes; this struct holds no allocation of its own.
pub const AudioView = struct {
    sample_rate: u32,
    channels: u16,
    frames: u32,
    sample_format: SampleFormat,
    sample_bytes: []const u8,

    pub fn sampleCount(self: AudioView) usize {
        return @as(usize, self.frames) * @as(usize, self.channels);
    }

    pub fn durationSeconds(self: AudioView) f64 {
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Interleaved sample `i` (frame `i / channels`, channel `i % channels`).
    pub fn sampleAt(self: AudioView, i: usize) f32 {
        return readF32(self.sample_bytes, i * 4);
    }

    /// Sample of one channel of one frame.
    pub fn frameAt(self: AudioView, frame: usize, channel: usize) f32 {
        return self.sampleAt(frame * @as(usize, self.channels) + channel);
    }
};

fn readF32(bytes: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
}

fn writeF32(bytes: []u8, off: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(value), .little);
}

// --- RIFF/WAVE parsing -----------------------------------------------------

const SampleKind = enum { pcm, float };

const Format = struct {
    channels: u16,
    sample_rate: u32,
    bits: u16,
    block_align: u16,
    kind: SampleKind,

    fn bytesPerSample(self: Format) usize {
        return @as(usize, self.bits) / 8;
    }
};

/// The shared tail of every KSDATAFORMAT_SUBTYPE GUID: Data2, Data3 and Data4.
/// Only Data1's low 16 bits (the format tag) differ between PCM and float.
const subformat_guid_tail = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };

fn parseFmt(data: []const u8) DecodeError!Format {
    if (data.len < 16) return error.InvalidAudio;
    const tag = std.mem.readInt(u16, data[0..2], .little);
    const channels = std.mem.readInt(u16, data[2..4], .little);
    const sample_rate = std.mem.readInt(u32, data[4..8], .little);
    // bytes 8..12 are the derived byte rate; it is not used and not trusted.
    const block_align = std.mem.readInt(u16, data[12..14], .little);
    const bits = std.mem.readInt(u16, data[14..16], .little);

    const kind: SampleKind = switch (tag) {
        0x0001 => .pcm,
        0x0003 => .float,
        0xFFFE => blk: {
            // WAVE_FORMAT_EXTENSIBLE: cbSize, valid bits, channel mask, GUID.
            if (data.len < 40) return error.InvalidAudio;
            const cb_size = std.mem.readInt(u16, data[16..18], .little);
            if (cb_size < 22) return error.InvalidAudio;
            const valid_bits = std.mem.readInt(u16, data[18..20], .little);
            if (valid_bits != 0 and valid_bits != bits) return error.InvalidAudio;
            const guid = data[24..40];
            if (!std.mem.eql(u8, guid[2..], &subformat_guid_tail)) return error.InvalidAudio;
            break :blk switch (std.mem.readInt(u16, guid[0..2], .little)) {
                0x0001 => SampleKind.pcm,
                0x0003 => SampleKind.float,
                else => return error.InvalidAudio,
            };
        },
        else => return error.InvalidAudio,
    };

    if (channels == 0 or channels > max_channels) return error.InvalidAudio;
    if (sample_rate == 0 or sample_rate > max_sample_rate) return error.InvalidAudio;
    switch (kind) {
        .pcm => if (bits != 8 and bits != 16 and bits != 24 and bits != 32) return error.InvalidAudio,
        .float => if (bits != 32) return error.InvalidAudio,
    }
    if (block_align != channels * (bits / 8)) return error.InvalidAudio;

    return .{
        .channels = channels,
        .sample_rate = sample_rate,
        .bits = bits,
        .block_align = block_align,
        .kind = kind,
    };
}

const Container = struct {
    format: Format,
    data: []const u8,
};

fn parseContainer(source: []const u8) DecodeError!Container {
    if (source.len < 12) return error.InvalidAudio;
    if (!std.mem.eql(u8, source[0..4], "RIFF")) return error.InvalidAudio;
    if (!std.mem.eql(u8, source[8..12], "WAVE")) return error.InvalidAudio;
    const riff_size = std.mem.readInt(u32, source[4..8], .little);
    if (riff_size != source.len - 8) return error.InvalidAudio;

    var pos: usize = 12;
    var format: ?Format = null;
    var data: ?[]const u8 = null;
    while (pos < source.len) {
        if (source.len - pos < 8) return error.InvalidAudio;
        const tag = source[pos..][0..4];
        const size = std.mem.readInt(u32, source[pos + 4 ..][0..4], .little);
        const start = pos + 8;
        if (size > source.len - start) return error.InvalidAudio;
        const payload = source[start..][0..size];

        if (std.mem.eql(u8, tag, "fmt ")) {
            if (format != null) return error.InvalidAudio; // duplicate header
            format = try parseFmt(payload);
        } else if (std.mem.eql(u8, tag, "data")) {
            if (format == null) return error.InvalidAudio; // fmt must come first
            if (data != null) return error.InvalidAudio; // one data chunk
            data = payload;
        }
        // Every other chunk is ancillary and skipped.

        pos = start + size;
        // Chunks are word-aligned. A missing final pad byte at EOF is tolerated
        // (some writers omit it); a pad byte before another chunk is required.
        if (size % 2 == 1 and pos < source.len) pos += 1;
    }

    const f = format orelse return error.InvalidAudio;
    const d = data orelse return error.InvalidAudio;
    if (d.len == 0) return error.InvalidAudio;
    if (d.len % f.block_align != 0) return error.InvalidAudio;
    return .{ .format = f, .data = d };
}

/// Convert one interleaved sample buffer at comptime-selected width. Integer
/// widths scale by 2^(bits-1); float passes through and must be finite.
fn convert(comptime bits: u16, comptime is_float: bool, dst: []f32, data: []const u8) DecodeError!void {
    const width: usize = bits / 8;
    for (dst, 0..) |*out, i| {
        const off = i * width;
        if (is_float) {
            const value = readF32(data, off);
            if (!std.math.isFinite(value)) return error.InvalidAudio;
            out.* = value;
        } else if (bits == 8) {
            const value: i32 = @as(i32, data[off]) - 128;
            out.* = @as(f32, @floatFromInt(value)) / 128.0;
        } else if (bits == 16) {
            const value = std.mem.readInt(i16, data[off..][0..2], .little);
            out.* = @as(f32, @floatFromInt(value)) / 32768.0;
        } else if (bits == 24) {
            const raw: u32 = @as(u32, data[off]) |
                (@as(u32, data[off + 1]) << 8) |
                (@as(u32, data[off + 2]) << 16);
            const extended = if (raw & 0x800000 != 0) raw | 0xFF000000 else raw;
            const value: i32 = @bitCast(extended);
            out.* = @as(f32, @floatFromInt(value)) / 8388608.0;
        } else {
            const value = std.mem.readInt(i32, data[off..][0..4], .little);
            out.* = @as(f32, @floatFromInt(value)) / 2147483648.0;
        }
    }
}

/// Decode a RIFF/WAVE source into interleaved float32. The caller owns
/// `Audio.samples` and releases it with `Audio.deinit`.
pub fn decodeWav(gpa: Allocator, source: []const u8) DecodeError!Audio {
    const container = try parseContainer(source);
    const f = container.format;
    const frames = container.data.len / f.block_align;
    if (frames == 0 or frames > max_frames) return error.InvalidAudio;
    const count = std.math.mul(usize, frames, f.channels) catch return error.InvalidAudio;
    const bytes = std.math.mul(usize, count, 4) catch return error.InvalidAudio;
    if (bytes > max_sample_bytes) return error.InvalidAudio;

    const samples = gpa.alloc(f32, count) catch return error.OutOfMemory;
    errdefer gpa.free(samples);

    switch (f.kind) {
        .pcm => switch (f.bits) {
            inline 8, 16, 24, 32 => |bits| try convert(bits, false, samples, container.data),
            else => return error.InvalidAudio,
        },
        .float => try convert(32, true, samples, container.data),
    }

    return .{
        .sample_rate = f.sample_rate,
        .channels = f.channels,
        .frames = @intCast(frames),
        .samples = samples,
    };
}

// --- CXAW artifact ---------------------------------------------------------

/// Serialize a decoded clip into a `CXAW` artifact. The caller frees the result.
pub fn serialize(gpa: Allocator, clip: Audio) ImportError![]u8 {
    if (clip.channels == 0 or clip.channels > max_channels) return error.InvalidAsset;
    if (clip.sample_rate == 0 or clip.sample_rate > max_sample_rate) return error.InvalidAsset;
    if (clip.frames == 0 or clip.frames > max_frames) return error.InvalidAsset;
    const count = std.math.mul(usize, clip.frames, clip.channels) catch return error.InvalidAsset;
    if (clip.samples.len != count) return error.InvalidAsset;
    const payload = std.math.mul(usize, count, 4) catch return error.InvalidAsset;
    if (payload > max_sample_bytes) return error.InvalidAsset;
    const total = std.math.add(usize, payload, header_size) catch return error.InvalidAsset;

    const out = gpa.alloc(u8, total) catch return error.OutOfMemory;
    errdefer gpa.free(out);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], format_version, .little);
    std.mem.writeInt(u32, out[8..12], clip.sample_rate, .little);
    std.mem.writeInt(u16, out[12..14], clip.channels, .little);
    std.mem.writeInt(u16, out[14..16], @backingInt(SampleFormat.f32_interleaved), .little);
    std.mem.writeInt(u32, out[16..20], clip.frames, .little);
    for (clip.samples, 0..) |value, i| {
        if (!std.math.isFinite(value)) return error.InvalidAsset;
        writeF32(out, header_size + i * 4, value);
    }
    return out;
}

/// Parse a `CXAW` artifact into a zero-copy view, validating magic, version,
/// sample format, dimensions, exact length and float finiteness.
pub fn parse(bytes: []const u8) error{InvalidAsset}!AudioView {
    if (bytes.len < header_size) return error.InvalidAsset;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidAsset;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.InvalidAsset;
    const sample_rate = std.mem.readInt(u32, bytes[8..12], .little);
    const channels = std.mem.readInt(u16, bytes[12..14], .little);
    const sample_format = std.mem.readInt(u16, bytes[14..16], .little);
    const frames = std.mem.readInt(u32, bytes[16..20], .little);

    if (sample_rate == 0 or sample_rate > max_sample_rate) return error.InvalidAsset;
    if (channels == 0 or channels > max_channels) return error.InvalidAsset;
    if (sample_format != @backingInt(SampleFormat.f32_interleaved)) return error.InvalidAsset;
    if (frames == 0 or frames > max_frames) return error.InvalidAsset;

    const count = std.math.mul(usize, frames, channels) catch return error.InvalidAsset;
    const payload = std.math.mul(usize, count, 4) catch return error.InvalidAsset;
    if (payload > max_sample_bytes) return error.InvalidAsset;
    const expected = std.math.add(usize, payload, header_size) catch return error.InvalidAsset;
    if (bytes.len != expected) return error.InvalidAsset;

    const sample_bytes = bytes[header_size..];
    var off: usize = 0;
    while (off < payload) : (off += 4) {
        if (!std.math.isFinite(readF32(sample_bytes, off))) return error.InvalidAsset;
    }

    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .frames = frames,
        .sample_format = .f32_interleaved,
        .sample_bytes = sample_bytes,
    };
}

fn mapDecodeError(err: DecodeError) ImportError {
    return switch (err) {
        error.InvalidAudio => error.InvalidAsset,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Decode a WAV source then serialize it to a `CXAW` artifact.
pub fn importWav(gpa: Allocator, source: []const u8) ImportError![]u8 {
    var clip = decodeWav(gpa, source) catch |err| return mapDecodeError(err);
    defer clip.deinit(gpa);
    return serialize(gpa, clip);
}

pub const wav_importer = Importer{ .id = "wav", .version = 1, .importFn = importWav };

/// Extension bindings for the engine registry (prepended by `assets.zig`).
pub const bindings = [_]importer.Registry.Binding{
    .{ .extensions = &[_][]const u8{".wav"}, .importer = wav_importer },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const vectors = @import("audio_vectors.zig");

fn unhex(gpa: Allocator, hex: []const u8) ![]u8 {
    const bytes = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

test "audio: every valid vector decodes to the reference f32 samples" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        const expected = try unhex(gpa, vector.f32_hex);
        defer gpa.free(expected);

        var clip = try decodeWav(gpa, source);
        defer clip.deinit(gpa);
        errdefer std.debug.print("failed vector: {s}\n", .{vector.name});
        try testing.expectEqual(vector.channels, clip.channels);
        try testing.expectEqual(vector.sample_rate, clip.sample_rate);
        try testing.expectEqual(vector.frames, clip.frames);
        try testing.expectEqual(clip.sampleCount(), clip.samples.len);
        try testing.expectEqual(expected.len, clip.samples.len * 4);
        // Compare bit patterns so -0.0 and rounding differences cannot hide.
        for (clip.samples, 0..) |value, i| {
            const actual: u32 = @bitCast(value);
            const want = std.mem.readInt(u32, expected[i * 4 ..][0..4], .little);
            try testing.expectEqual(want, actual);
        }
    }
}

test "audio: malformed files are rejected" {
    const gpa = testing.allocator;
    for (vectors.invalid) |vector| {
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        errdefer std.debug.print("vector accepted but should fail: {s}\n", .{vector.name});
        try testing.expectError(error.InvalidAudio, decodeWav(gpa, source));
        try testing.expectError(error.InvalidAsset, importWav(gpa, source));
    }
}

test "audio: artifact roundtrip preserves rate, channels, frames and samples" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        var clip = try decodeWav(gpa, source);
        defer clip.deinit(gpa);

        const artifact = try serialize(gpa, clip);
        defer gpa.free(artifact);
        try testing.expectEqual(header_size + clip.samples.len * 4, artifact.len);

        const view = try parse(artifact);
        try testing.expectEqual(clip.sample_rate, view.sample_rate);
        try testing.expectEqual(clip.channels, view.channels);
        try testing.expectEqual(clip.frames, view.frames);
        try testing.expectEqual(SampleFormat.f32_interleaved, view.sample_format);
        try testing.expectEqual(clip.sampleCount(), view.sampleCount());
        for (clip.samples, 0..) |value, i| {
            try testing.expectEqual(@as(u32, @bitCast(value)), @as(u32, @bitCast(view.sampleAt(i))));
        }
        try testing.expectApproxEqAbs(clip.durationSeconds(), view.durationSeconds(), 1e-12);
    }
}

test "audio: parse rejects bad magic, version, format, dimensions and length" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.valid[1].wav_hex);
    defer gpa.free(source);
    var clip = try decodeWav(gpa, source);
    defer clip.deinit(gpa);
    const artifact = try serialize(gpa, clip);
    defer gpa.free(artifact);

    const bad = try gpa.dupe(u8, artifact);
    defer gpa.free(bad);

    bad[0] = 'X';
    try testing.expectError(error.InvalidAsset, parse(bad));
    bad[0] = 'C';

    std.mem.writeInt(u32, bad[4..8], 99, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[4..8], format_version, .little);

    std.mem.writeInt(u16, bad[14..16], 7, .little); // unknown sample format
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u16, bad[14..16], 0, .little);

    std.mem.writeInt(u16, bad[12..14], 0, .little); // zero channels
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u16, bad[12..14], max_channels + 1, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u16, bad[12..14], clip.channels, .little);

    std.mem.writeInt(u32, bad[8..12], 0, .little); // zero sample rate
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[8..12], max_sample_rate + 1, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[8..12], clip.sample_rate, .little);

    std.mem.writeInt(u32, bad[16..20], 0, .little); // zero frames
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[16..20], clip.frames, .little);

    // A NaN payload must be rejected by the linear validation pass.
    std.mem.writeInt(u32, bad[header_size..][0..4], 0x7FC00000, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));

    try testing.expectError(error.InvalidAsset, parse(artifact[0 .. artifact.len - 4]));
    try testing.expectError(error.InvalidAsset, parse(artifact[0..10]));
}

test "audio: serialize rejects inconsistent clips and non-finite samples" {
    const gpa = testing.allocator;
    var samples = [_]f32{ 0.0, 0.5, -0.5, 1.0 };
    const clip = Audio{ .sample_rate = 48000, .channels = 2, .frames = 2, .samples = &samples };

    const wrong_len = Audio{ .sample_rate = 48000, .channels = 2, .frames = 3, .samples = &samples };
    try testing.expectError(error.InvalidAsset, serialize(gpa, wrong_len));
    const zero_frames = Audio{ .sample_rate = 48000, .channels = 2, .frames = 0, .samples = &samples };
    try testing.expectError(error.InvalidAsset, serialize(gpa, zero_frames));
    const zero_rate = Audio{ .sample_rate = 0, .channels = 2, .frames = 2, .samples = &samples };
    try testing.expectError(error.InvalidAsset, serialize(gpa, zero_rate));
    const too_many = Audio{ .sample_rate = 48000, .channels = max_channels + 1, .frames = 2, .samples = &samples };
    try testing.expectError(error.InvalidAsset, serialize(gpa, too_many));

    samples[1] = std.math.nan(f32);
    try testing.expectError(error.InvalidAsset, serialize(gpa, clip));
    samples[1] = std.math.inf(f32);
    try testing.expectError(error.InvalidAsset, serialize(gpa, clip));
    samples[1] = 0.5;
    const ok = try serialize(gpa, clip);
    gpa.free(ok);
}

test "audio: float headroom is preserved and integers are scaled to full range" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        var clip = try decodeWav(gpa, source);
        defer clip.deinit(gpa);

        if (std.mem.eql(u8, vector.name, "float32_mono")) {
            // 1.5 and -2.0 are outside [-1, 1] and must survive untouched.
            try testing.expectEqual(@as(f32, 1.5), clip.samples[5]);
            try testing.expectEqual(@as(f32, -2.0), clip.samples[6]);
        }
        if (std.mem.eql(u8, vector.name, "pcm16_mono")) {
            try testing.expectEqual(@as(f32, 32767.0 / 32768.0), clip.samples[3]);
            try testing.expectEqual(@as(f32, -1.0), clip.samples[4]);
        }
        if (std.mem.eql(u8, vector.name, "pcm8_mono")) {
            try testing.expectEqual(@as(f32, -1.0), clip.samples[0]);
            try testing.expectEqual(@as(f32, 0.0), clip.samples[2]);
        }
        if (std.mem.eql(u8, vector.name, "pcm24_mono")) {
            // Sign extension: 0xFFFFFF is -1, not 16777215.
            try testing.expectEqual(@as(f32, -1.0 / 8388608.0), clip.samples[2]);
            try testing.expectEqual(@as(f32, -1.0), clip.samples[4]);
        }
        for (clip.samples) |value| try testing.expect(std.math.isFinite(value));
    }
}

test "audio: view accessors are alignment-safe and index by frame/channel" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        if (!std.mem.eql(u8, vector.name, "extensible_float32_6ch")) continue;
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        var clip = try decodeWav(gpa, source);
        defer clip.deinit(gpa);
        const artifact = try serialize(gpa, clip);
        defer gpa.free(artifact);

        // Place the artifact at an odd offset: accessors must not cast pointers.
        const shifted = try gpa.alloc(u8, artifact.len + 1);
        defer gpa.free(shifted);
        @memcpy(shifted[1..], artifact);
        const view = try parse(shifted[1..]);
        try testing.expectEqual(@as(u16, 6), view.channels);
        try testing.expectEqual(@as(u32, 2), view.frames);
        for (0..view.frames) |frame| {
            for (0..view.channels) |channel| {
                const want = clip.samples[frame * view.channels + channel];
                try testing.expectEqual(want, view.frameAt(frame, channel));
            }
        }
        return;
    }
    return error.MissingVector;
}

test "audio: duration and sample counts are derived from frames and rate" {
    const gpa = testing.allocator;
    const source = try unhex(gpa, vectors.valid[1].wav_hex);
    defer gpa.free(source);
    var clip = try decodeWav(gpa, source);
    defer clip.deinit(gpa);
    try testing.expectEqual(@as(usize, clip.frames), clip.sampleCount()); // mono
    try testing.expectApproxEqAbs(@as(f64, 8.0 / 44100.0), clip.durationSeconds(), 1e-12);
}

test "audio: bindings select the wav importer" {
    const reg = importer.Registry{ .bindings = &bindings, .fallback = importer.raw_importer };
    try testing.expectEqualStrings("wav", reg.select(".wav").id);
    try testing.expectEqualStrings("wav", reg.select(".WAV").id);
    try testing.expectEqual(@as(u32, 1), wav_importer.version);
    // Other audio containers still have no decoder.
    try testing.expectEqualStrings("raw", reg.select(".ogg").id);
    try testing.expectEqualStrings("raw", reg.select(".mp3").id);
}

test "audio: importWav produces a CXAW artifact for every valid vector" {
    const gpa = testing.allocator;
    for (vectors.valid) |vector| {
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        const expected = try unhex(gpa, vector.f32_hex);
        defer gpa.free(expected);

        const artifact = try importWav(gpa, source);
        defer gpa.free(artifact);
        const view = try parse(artifact);
        try testing.expectEqual(vector.channels, view.channels);
        try testing.expectEqual(vector.sample_rate, view.sample_rate);
        try testing.expectEqual(vector.frames, view.frames);
        try testing.expectEqualSlices(u8, expected, view.sample_bytes);
    }
}

test "audio: decode, serialize and import survive allocation failure" {
    const gpa = testing.allocator;
    const names = [_][]const u8{ "pcm16_stereo", "pcm24_mono", "extensible_float32_6ch" };
    for (vectors.valid) |vector| {
        var selected = false;
        for (names) |name| {
            if (std.mem.eql(u8, vector.name, name)) selected = true;
        }
        if (!selected) continue;
        const source = try unhex(gpa, vector.wav_hex);
        defer gpa.free(source);
        try testing.checkAllAllocationFailures(gpa, struct {
            fn f(alloc: Allocator, bytes: []const u8) !void {
                var clip = try decodeWav(alloc, bytes);
                defer clip.deinit(alloc);
                const artifact = try serialize(alloc, clip);
                alloc.free(artifact);
                const imported = try importWav(alloc, bytes);
                alloc.free(imported);
            }
        }.f, .{source});
    }
}
