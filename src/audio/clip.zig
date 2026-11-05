//! Clip descriptors and sample-level helpers for the audio runtime.
//!
//! A `Clip` is a **borrowed** view of interleaved float32 PCM: sample rate,
//! channel count, frame count and the sample slice. It is deliberately a plain
//! data descriptor with no dependency on the asset layer, so the mixer stays
//! loosely coupled: `corex.assets.audio.AudioView` (the `CXAW` artifact) maps to
//! it field by field, and so does any buffer produced elsewhere.
//!
//! The helpers here are the pieces of the mixing contract that are independent
//! of voice state: channel-layout mapping, pan laws and the float-to-PCM16
//! conversion a device backend will need. They are pure functions, so they are
//! testable on their own.
//!
//! Sample values are expected in [-1, 1] but **headroom is legal**: the decoder
//! preserves float samples beyond full scale and the mixer does not clamp per
//! voice. Clamping (when enabled) happens once, on the mixed output.

const std = @import("std");

/// Highest sample rate the runtime accepts. Matches the `CXAW` artifact ceiling
/// so every importable clip is playable.
pub const max_sample_rate: u32 = 384_000;

/// A borrowed, interleaved float32 clip. The caller keeps the samples alive for
/// as long as any voice plays them; the mixer never copies or frees them.
pub const Clip = struct {
    sample_rate: u32,
    channels: u16,
    frames: u32,
    /// Interleaved samples; `samples.len == frames * channels`.
    samples: []const f32,

    /// Validate structure only. Sample **finiteness is not scanned** here: that
    /// would be O(n) per play, and the `CXAW` parser already guarantees finite
    /// samples. The mixer's output stage sanitizes non-finite mixes regardless,
    /// so a bad buffer can never reach a device.
    pub fn validate(self: Clip) error{InvalidClip}!void {
        if (self.sample_rate == 0 or self.sample_rate > max_sample_rate) return error.InvalidClip;
        if (self.channels == 0) return error.InvalidClip;
        if (self.frames == 0) return error.InvalidClip;
        const count = std.math.mul(usize, self.frames, self.channels) catch return error.InvalidClip;
        if (self.samples.len != count) return error.InvalidClip;
    }

    pub fn durationSeconds(self: Clip) f64 {
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// One channel of one frame. Bounds-checked by Zig's slice indexing.
    pub fn frameAt(self: Clip, frame: usize, channel: usize) f32 {
        return self.samples[frame * @as(usize, self.channels) + channel];
    }
};

/// How a clip's channels are mapped onto the mixer's output layout.
///
/// The rules are explicit and lossy only where a downmix is by definition lossy:
///
/// | source        | output | rule                                        |
/// |---------------|--------|---------------------------------------------|
/// | mono          | mono   | passthrough                                  |
/// | mono          | stereo | duplicated to both channels, then panned     |
/// | stereo        | stereo | 1:1, then panned                             |
/// | stereo        | mono   | `(L + R) / 2`                                |
/// | N > 2         | mono   | equal-weight mean of all N channels          |
/// | N > 2         | stereo | **rejected** (`UnsupportedChannelLayout`)    |
///
/// Surround-to-stereo needs a downmix matrix (center/LFE/surround coefficients)
/// that this stage does not implement, so it is refused instead of silently
/// dropping channels.
pub const ChannelMap = enum {
    mono_to_mono,
    mono_to_stereo,
    stereo_to_stereo,
    stereo_to_mono,
    many_to_mono,

    pub fn resolve(source_channels: u16, output_channels: u16) error{UnsupportedChannelLayout}!ChannelMap {
        if (output_channels == 1) {
            return switch (source_channels) {
                0 => error.UnsupportedChannelLayout,
                1 => .mono_to_mono,
                2 => .stereo_to_mono,
                else => .many_to_mono,
            };
        }
        if (output_channels == 2) {
            return switch (source_channels) {
                1 => .mono_to_stereo,
                2 => .stereo_to_stereo,
                else => error.UnsupportedChannelLayout,
            };
        }
        return error.UnsupportedChannelLayout;
    }

    /// Output channel count (1 or 2).
    pub fn outputChannels(self: ChannelMap) u16 {
        return switch (self) {
            .mono_to_mono, .stereo_to_mono, .many_to_mono => 1,
            .mono_to_stereo, .stereo_to_stereo => 2,
        };
    }

    /// Source channel count, or `null` when it is the clip's runtime count
    /// (`many_to_mono`).
    pub fn sourceChannels(self: ChannelMap) ?u16 {
        return switch (self) {
            .mono_to_mono, .mono_to_stereo => 1,
            .stereo_to_stereo, .stereo_to_mono => 2,
            .many_to_mono => null,
        };
    }
};

/// Stereo pan law. Pan is only meaningful for a stereo output; a mono output
/// ignores it (documented, not silently attenuated).
pub const PanLaw = enum {
    /// Constant gain: `L = clamp(1 - pan)`, `R = clamp(1 + pan)`. Center is
    /// unity on both channels; hard left/right is unity on one and silence on
    /// the other. Cheap and exact at the endpoints.
    linear,
    /// Constant power: `L = cos(theta)`, `R = sin(theta)` with
    /// `theta = (pan + 1) * pi / 4`. Center is `-3.01 dB` on both channels, so a
    /// swept pan keeps perceived loudness roughly constant.
    equal_power,
};

/// Left/right pan multipliers for a pan position in [-1, 1]. Out-of-range input
/// is clamped; the result is always finite and in [0, 1].
pub fn panGains(law: PanLaw, pan: f32) [2]f32 {
    const p = std.math.clamp(pan, -1.0, 1.0);
    return switch (law) {
        .linear => .{
            std.math.clamp(1.0 - p, 0.0, 1.0),
            std.math.clamp(1.0 + p, 0.0, 1.0),
        },
        .equal_power => blk: {
            const theta = (p + 1.0) * (std.math.pi / 4.0);
            break :blk .{ @cos(theta), @sin(theta) };
        },
    };
}

/// Convert mixed float32 samples to signed 16-bit PCM, the format most device
/// backends accept. `dst.len` must equal `src.len`.
///
/// Rules (documented because they decide round-trip exactness):
/// - Non-finite input becomes silence.
/// - Values are clamped to [-1, 1], scaled by 32768 and rounded to nearest.
/// - The result is clamped to the i16 range, so `+1.0` maps to 32767 (32768 is
///   not representable) while `-1.0` maps to -32768 exactly.
///
/// Scaling by 32768 in both directions makes a PCM16 -> f32 -> PCM16 round trip
/// **exact for every i16 value**, which the decoder's `value / 32768` rule
/// guarantees on the way in.
pub fn toPcm16(dst: []i16, src: []const f32) error{InvalidBuffer}!void {
    if (dst.len != src.len) return error.InvalidBuffer;
    for (dst, src) |*out, value| {
        if (!std.math.isFinite(value)) {
            out.* = 0;
            continue;
        }
        const clamped = std.math.clamp(value, -1.0, 1.0);
        const scaled = @round(clamped * 32768.0);
        out.* = @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "clip: validate accepts a well-formed descriptor and rejects broken ones" {
    const samples = [_]f32{ 0, 0.25, -0.25, 0.5, -0.5, 1.0 };
    const good = Clip{ .sample_rate = 48000, .channels = 2, .frames = 3, .samples = &samples };
    try good.validate();
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 48000.0), good.durationSeconds(), 1e-15);
    try testing.expectEqual(@as(f32, -0.25), good.frameAt(1, 0));
    try testing.expectEqual(@as(f32, 0.5), good.frameAt(1, 1));

    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 0, .channels = 2, .frames = 3, .samples = &samples }).validate());
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = max_sample_rate + 1, .channels = 2, .frames = 3, .samples = &samples }).validate());
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 48000, .channels = 0, .frames = 3, .samples = &samples }).validate());
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 48000, .channels = 2, .frames = 0, .samples = &samples }).validate());
    // Length mismatch in both directions.
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 48000, .channels = 2, .frames = 4, .samples = &samples }).validate());
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 48000, .channels = 2, .frames = 2, .samples = &samples }).validate());
    // Overflowing frame/channel product must not wrap into a valid length.
    try testing.expectError(error.InvalidClip, (Clip{ .sample_rate = 48000, .channels = 65535, .frames = std.math.maxInt(u32), .samples = &samples }).validate());
}

test "clip: channel maps follow the documented matrix" {
    try testing.expectEqual(ChannelMap.mono_to_mono, try ChannelMap.resolve(1, 1));
    try testing.expectEqual(ChannelMap.mono_to_stereo, try ChannelMap.resolve(1, 2));
    try testing.expectEqual(ChannelMap.stereo_to_stereo, try ChannelMap.resolve(2, 2));
    try testing.expectEqual(ChannelMap.stereo_to_mono, try ChannelMap.resolve(2, 1));
    try testing.expectEqual(ChannelMap.many_to_mono, try ChannelMap.resolve(6, 1));
    try testing.expectEqual(ChannelMap.many_to_mono, try ChannelMap.resolve(8, 1));
    // Surround to stereo is refused rather than guessed.
    try testing.expectError(error.UnsupportedChannelLayout, ChannelMap.resolve(6, 2));
    try testing.expectError(error.UnsupportedChannelLayout, ChannelMap.resolve(0, 1));
    try testing.expectError(error.UnsupportedChannelLayout, ChannelMap.resolve(0, 2));
    try testing.expectError(error.UnsupportedChannelLayout, ChannelMap.resolve(1, 3));

    try testing.expectEqual(@as(u16, 1), ChannelMap.many_to_mono.outputChannels());
    try testing.expectEqual(@as(u16, 2), ChannelMap.mono_to_stereo.outputChannels());
    try testing.expectEqual(@as(?u16, 2), ChannelMap.stereo_to_mono.sourceChannels());
    try testing.expectEqual(@as(?u16, null), ChannelMap.many_to_mono.sourceChannels());
}

test "clip: linear pan law is unity at the center and silent on the far side" {
    const center = panGains(.linear, 0.0);
    try testing.expectEqual(@as(f32, 1.0), center[0]);
    try testing.expectEqual(@as(f32, 1.0), center[1]);

    const left = panGains(.linear, -1.0);
    try testing.expectEqual(@as(f32, 1.0), left[0]);
    try testing.expectEqual(@as(f32, 0.0), left[1]);

    const right = panGains(.linear, 1.0);
    try testing.expectEqual(@as(f32, 0.0), right[0]);
    try testing.expectEqual(@as(f32, 1.0), right[1]);

    const quarter = panGains(.linear, 0.5);
    try testing.expectEqual(@as(f32, 0.5), quarter[0]);
    try testing.expectEqual(@as(f32, 1.0), quarter[1]);

    // Out-of-range pan is clamped, never extrapolated into negative gains.
    const clamped = panGains(.linear, -4.0);
    try testing.expectEqual(@as(f32, 1.0), clamped[0]);
    try testing.expectEqual(@as(f32, 0.0), clamped[1]);
}

test "clip: equal-power pan keeps unit power and is -3 dB at the center" {
    const inv_sqrt2 = 0.7071067811865476;
    const center = panGains(.equal_power, 0.0);
    try testing.expectApproxEqAbs(@as(f32, inv_sqrt2), center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, inv_sqrt2), center[1], 1e-6);

    const left = panGains(.equal_power, -1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left[1], 1e-6);

    const right = panGains(.equal_power, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), right[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right[1], 1e-6);

    // Sweeping the pan preserves total power (L^2 + R^2 == 1).
    var i: i32 = -10;
    while (i <= 10) : (i += 1) {
        const g = panGains(.equal_power, @as(f32, @floatFromInt(i)) / 10.0);
        try testing.expectApproxEqAbs(@as(f32, 1.0), g[0] * g[0] + g[1] * g[1], 1e-6);
    }
}

test "clip: f32 to PCM16 round-trips every i16 value exactly" {
    // Exhaustive over the whole i16 domain: decode rule is value / 32768.
    var value: i32 = -32768;
    while (value <= 32767) : (value += 1) {
        const sample: f32 = @as(f32, @floatFromInt(value)) / 32768.0;
        var out: [1]i16 = undefined;
        try toPcm16(&out, &[_]f32{sample});
        try testing.expectEqual(@as(i16, @intCast(value)), out[0]);
    }
}

test "clip: PCM16 conversion clamps, rounds and sanitizes" {
    const src = [_]f32{ 1.0, -1.0, 2.0, -2.0, 0.0, 0.5, -0.5, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    var out: [src.len]i16 = undefined;
    try toPcm16(&out, &src);
    try testing.expectEqualSlices(i16, &[_]i16{ 32767, -32768, 32767, -32768, 0, 16384, -16384, 0, 0, 0 }, &out);

    var mismatch: [2]i16 = undefined;
    try testing.expectError(error.InvalidBuffer, toPcm16(&mismatch, &src));
    // Empty buffers are valid and do nothing.
    try toPcm16(&[_]i16{}, &[_]f32{});
}
