//! Band-limited (windowed-sinc) resampling for the mixer.
//!
//! Linear interpolation is cheap but it is not a low-pass filter: when the
//! playback step is greater than 1 (a source above the output rate, or a pitch
//! above 1), frequencies above the output Nyquist fold back as aliasing. This
//! module implements the classic **windowed-sinc** alternative: a Blackman-
//! windowed sinc prototype, evaluated through a precomputed table with linear
//! interpolation between phases, whose cutoff follows the decimation ratio so
//! the signal is low-passed *before* it is decimated.
//!
//! Design:
//! - The prototype is sampled once into two views of the same filter: a flat
//!   table of `taps * phases + 1` floats for arbitrary cutoffs, and a
//!   **polyphase bank** of `(phases + 1) * taps` floats whose rows are the
//!   coefficient sets at unity cutoff. Together ~33 KiB, allocated in
//!   `Mixer.init` only when the caller opts into `.sinc`; nothing here allocates
//!   per sample. At unity cutoff a kernel is one contiguous row pair (vectorized
//!   linear interpolation between phases) instead of `taps` scattered lookups.
//! - For a step `s`, the cutoff scales by `min(1, 1/s)` and the filter support
//!   stretches by the same factor, so downsampling reads more source samples
//!   instead of aliasing. The support is capped at `max_support` source samples
//!   to bound the per-sample cost; beyond that ratio the anti-aliasing is
//!   partial, which is documented rather than hidden.
//! - Coefficients are normalized to sum to 1, so DC gain is exactly unity at any
//!   ratio and the filter cannot drift the loudness of a signal.
//! - Reads near the clip edges clamp (hold the edge sample) or wrap when the
//!   voice loops, and the interior path skips the bounds logic entirely.
//!
//! This module is pure: it knows nothing about voices, buses or the mixer, so
//! the filter can be tested against analytic signals on its own.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Resampling quality selectable on the mixer.
pub const Quality = enum {
    /// Two-point linear interpolation. Cheap, no table, no allocation. Fine for
    /// upsampling; aliases when decimating.
    linear,
    /// Band-limited windowed sinc. Costs one table at init and more MACs per
    /// sample, and removes the aliasing of large downsampling ratios.
    sinc,
};

/// Prototype filter length in taps (at unity cutoff).
pub const taps: usize = 32;
/// Table phases per unit of the prototype coordinate.
pub const phases: usize = 128;
/// Hard cap on source samples read per output sample, bounding the cost of
/// extreme decimation ratios.
pub const max_support: usize = 256;

/// Half-support of the prototype in its own coordinate.
const half: f32 = @floatFromInt(taps / 2);
const table_len: usize = taps * phases + 1;

/// The precomputed prototype and the per-sample evaluation helpers.
pub const Sinc = struct {
    /// `taps * phases + 1` samples of `sinc(x) * blackman(x / half)` for
    /// `x` in `[-half, half]`. Used when the cutoff is scaled (decimation).
    table: []f32,
    /// Polyphase bank: row `p` holds the `taps` coefficients for the fractional
    /// cursor `p / phases` at unity cutoff, in tap order. Contiguous rows make
    /// the common upsampling path a vectorizable copy instead of a gather.
    bank: []f32,
    /// Sum of each bank row, so the interpolated kernel can be normalized
    /// without accumulating per tap.
    row_sums: []f32,

    pub fn init(gpa: Allocator) Allocator.Error!Sinc {
        const phases_f: f64 = @floatFromInt(phases);
        const half_d: f64 = @floatCast(half);
        const half_support: i64 = @intCast(taps / 2);

        const table = try gpa.alloc(f32, table_len);
        errdefer gpa.free(table);
        for (table, 0..) |*entry, i| {
            const x = @as(f64, @floatFromInt(i)) / phases_f - half_d;
            entry.* = @floatCast(prototype(x, half_d));
        }

        const bank = try gpa.alloc(f32, (phases + 1) * taps);
        errdefer gpa.free(bank);
        const row_sums = try gpa.alloc(f32, phases + 1);
        errdefer gpa.free(row_sums);
        for (0..phases + 1) |p| {
            const frac = @as(f64, @floatFromInt(p)) / phases_f;
            var sum: f32 = 0;
            for (0..taps) |i| {
                // Tap i reads the prototype at `frac - (i - half + 1)`.
                const d = @as(f64, @floatFromInt(@as(i64, @intCast(i)) - half_support + 1));
                const value: f32 = @floatCast(prototype(frac - d, half_d));
                bank[p * taps + i] = value;
                sum += value;
            }
            row_sums[p] = sum;
        }
        return .{ .table = table, .bank = bank, .row_sums = row_sums };
    }

    pub fn deinit(self: *Sinc, gpa: Allocator) void {
        gpa.free(self.table);
        gpa.free(self.bank);
        gpa.free(self.row_sums);
        self.* = undefined;
    }

    /// Prototype value at `x`, read from the table with linear interpolation
    /// between phases. Outside the support the value is exactly zero.
    pub fn lookup(self: *const Sinc, x: f32) f32 {
        const t = (x + half) * @as(f32, @floatFromInt(phases));
        if (!(t >= 0) or t >= @as(f32, @floatFromInt(table_len - 1))) return 0;
        const i: usize = @intFromFloat(t);
        const frac = t - @as(f32, @floatFromInt(i));
        const a = self.table[i];
        return a + (self.table[i + 1] - a) * frac;
    }

    /// Build the coefficient set for one output sample. `pos` is the fractional
    /// source cursor and `step` the source frames advanced per output frame.
    ///
    /// The table coordinate of consecutive taps is an arithmetic sequence, so
    /// the walk is one subtract per tap and the out-of-range head/tail are split
    /// off: the interior loop carries no bounds test of its own.
    pub fn build(self: *const Sinc, pos: f64, step: f64, out: *Kernel) void {
        const scale: f32 = @floatCast(@min(1.0, 1.0 / step));
        const wanted = @ceil(half / scale);
        const support_half: usize = @min(max_support / 2, @as(usize, @intFromFloat(wanted)));
        const center: i64 = @intFromFloat(@floor(pos));
        const frac: f32 = @floatCast(pos - @floor(pos));
        const first_offset: i64 = 1 - @as(i64, @intCast(support_half));

        out.first_offset = first_offset;
        out.start = center + first_offset;
        out.count = support_half * 2;

        const phases_f: f32 = @floatFromInt(phases);
        if (scale == 1.0) {
            // Unity cutoff (upsampling or unit step): the coefficients are one
            // contiguous bank row pair, interpolated between phases. No gather,
            // no per-tap index math, and the norm comes from the row sums.
            const tp = frac * phases_f;
            const p: usize = @intFromFloat(tp);
            const f = tp - @as(f32, @floatFromInt(p));
            const row0 = self.bank[p * taps ..][0..taps];
            const row1 = self.bank[(p + 1) * taps ..][0..taps];
            for (out.coeffs[0..taps], row0, row1) |*coeff, a, b| coeff.* = a + (b - a) * f;
            const sum = self.row_sums[p] + (self.row_sums[p + 1] - self.row_sums[p]) * f;
            out.count = taps;
            out.inv_norm = if (sum > 0) 1.0 / sum else 0;
            return;
        }

        const limit: f32 = @floatFromInt(table_len - 1);
        const stride = scale * phases_f;
        const t0 = ((frac - @as(f32, @floatFromInt(first_offset))) * scale + half) * phases_f;

        // Taps whose coordinate falls off the top of the table contribute zero.
        var lead: usize = 0;
        var t = t0;
        while (lead < out.count and t >= limit) : (lead += 1) t -= stride;
        // Then the in-range interior, then the tail below zero.
        var interior: usize = 0;
        var probe = t;
        while (interior < out.count - lead and probe >= 0) : (interior += 1) probe -= stride;

        @memset(out.coeffs[0..lead], 0);
        @memset(out.coeffs[lead + interior .. out.count], 0);

        // The `scale` factor is common to every coefficient and cancels in the
        // normalization, so it is folded into `inv_norm` instead of costing a
        // multiply per tap.
        // Four partial sums: a single accumulator would serialize the loop on
        // the latency of `+`, which dominates a gather this short.
        var norm: @Vector(4, f32) = @splat(0);
        var chunk: usize = 0;
        const interior_coeffs = out.coeffs[lead .. lead + interior];
        while (chunk + 4 <= interior) : (chunk += 4) {
            var values: @Vector(4, f32) = undefined;
            inline for (0..4) |lane| {
                const i: usize = @intFromFloat(t);
                const f = t - @as(f32, @floatFromInt(i));
                const a = self.table[i];
                values[lane] = a + (self.table[i + 1] - a) * f;
                t -= stride;
            }
            interior_coeffs[chunk..][0..4].* = values;
            norm += values;
        }
        var tail_sum: f32 = 0;
        for (interior_coeffs[chunk..]) |*coeff| {
            const i: usize = @intFromFloat(t);
            const f = t - @as(f32, @floatFromInt(i));
            const a = self.table[i];
            const value = a + (self.table[i + 1] - a) * f;
            coeff.* = value;
            tail_sum += value;
            t -= stride;
        }
        const total = @reduce(.Add, norm) + tail_sum;
        // Unity DC gain regardless of truncation or phase interpolation error.
        out.inv_norm = if (total > 0) 1.0 / total else 0;
    }
};

/// Coefficients for one output sample. The caller owns one of these on its
/// stack and refills it per frame; nothing is allocated.
pub const Kernel = struct {
    /// Index of the first source frame the coefficients apply to.
    start: i64 = 0,
    /// `start - floor(pos)`. The coefficients depend only on the fractional
    /// cursor and the step, so a caller that sees the same fraction again can
    /// reuse them and just move `start` by this offset.
    first_offset: i64 = 0,
    /// Number of active coefficients (<= `max_support`).
    count: usize = 0,
    inv_norm: f32 = 0,
    coeffs: [max_support]f32 = undefined,
};

/// True when every tap index is inside the buffer, so the read loop can drop
/// the per-tap bounds policy.
inline fn isInterior(kernel: *const Kernel, frames: usize) bool {
    return kernel.start >= 0 and kernel.start + @as(i64, @intCast(kernel.count)) <= @as(i64, @intCast(frames));
}

/// Guarded read: clamp to the edge, or wrap when the voice loops.
inline fn edgeIndex(kernel: *const Kernel, tap: usize, frames: usize, looping: bool) usize {
    const raw = kernel.start + @as(i64, @intCast(tap));
    const frames_i: i64 = @intCast(frames);
    return @intCast(if (looping) @mod(raw, frames_i) else std.math.clamp(raw, 0, frames_i - 1));
}

/// Apply a kernel to one channel of an interleaved buffer. `frames` is the
/// source frame count; out-of-range reads clamp to the edge, or wrap when the
/// voice loops.
pub fn apply(
    kernel: *const Kernel,
    src: []const f32,
    channels: usize,
    channel: usize,
    frames: usize,
    looping: bool,
) f32 {
    const coeffs = kernel.coeffs[0..kernel.count];
    var sum: f32 = 0;
    if (isInterior(kernel, frames)) {
        var index: usize = @intCast(kernel.start);
        if (channels == 1) {
            // Contiguous mono: four taps per SIMD step, one reduction at the end.
            var acc: @Vector(4, f32) = @splat(0);
            var i: usize = 0;
            while (i + 4 <= coeffs.len) : (i += 4) {
                const samples: @Vector(4, f32) = src[index..][0..4].*;
                const weights: @Vector(4, f32) = coeffs[i..][0..4].*;
                acc += samples * weights;
                index += 4;
            }
            sum = @reduce(.Add, acc);
            for (coeffs[i..]) |coeff| {
                sum += src[index] * coeff;
                index += 1;
            }
        } else {
            for (coeffs) |coeff| {
                sum += src[index * channels + channel] * coeff;
                index += 1;
            }
        }
    } else {
        for (coeffs, 0..) |coeff, i| {
            sum += src[edgeIndex(kernel, i, frames, looping) * channels + channel] * coeff;
        }
    }
    return sum * kernel.inv_norm;
}

/// Apply a kernel to both channels of an interleaved **stereo** buffer in one
/// pass. Sharing the tap loop halves the coefficient traffic and lets the
/// interior path read eight contiguous floats per step.
pub fn applyPair(kernel: *const Kernel, src: []const f32, frames: usize, looping: bool) [2]f32 {
    const coeffs = kernel.coeffs[0..kernel.count];
    var left: f32 = 0;
    var right: f32 = 0;
    if (isInterior(kernel, frames)) {
        var index: usize = @as(usize, @intCast(kernel.start)) * 2;
        var acc: @Vector(8, f32) = @splat(0);
        var i: usize = 0;
        while (i + 4 <= coeffs.len) : (i += 4) {
            const weights: @Vector(4, f32) = coeffs[i..][0..4].*;
            // Duplicate each weight across the channel pair: {c0,c0,c1,c1,...}.
            const paired = @shuffle(f32, weights, weights, [8]i32{ 0, 0, 1, 1, 2, 2, 3, 3 });
            const samples: @Vector(8, f32) = src[index..][0..8].*;
            acc += samples * paired;
            index += 8;
        }
        left = acc[0] + acc[2] + acc[4] + acc[6];
        right = acc[1] + acc[3] + acc[5] + acc[7];
        while (i < coeffs.len) : (i += 1) {
            left += src[index] * coeffs[i];
            right += src[index + 1] * coeffs[i];
            index += 2;
        }
    } else {
        for (coeffs, 0..) |coeff, i| {
            const base = edgeIndex(kernel, i, frames, looping) * 2;
            left += src[base] * coeff;
            right += src[base + 1] * coeff;
        }
    }
    return .{ left * kernel.inv_norm, right * kernel.inv_norm };
}

/// Windowed sinc in double precision, used only to build the table.
/// Blackman-windowed sinc at `x`, zero outside `|x| >= half_support`.
///
/// This is the shared filter prototype for the whole audio stack: the resampler
/// builds its polyphase bank from it, and the effects module builds its
/// oversampling kernels from it. Exported so the two never drift apart.
pub fn prototype(x: f64, half_support: f64) f64 {
    const sinc = if (@abs(x) < 1e-12) 1.0 else @sin(std.math.pi * x) / (std.math.pi * x);
    const u = x / half_support;
    // Blackman: zero at |u| == 1, so the truncated filter tapers smoothly.
    const window = 0.42 + 0.5 * @cos(std.math.pi * u) + 0.08 * @cos(2.0 * std.math.pi * u);
    return sinc * window;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn sineBuffer(gpa: Allocator, frames: usize, rate: f64, freq: f64) ![]f32 {
    const buf = try gpa.alloc(f32, frames);
    for (buf, 0..) |*v, i| {
        v.* = @floatCast(@sin(2.0 * std.math.pi * freq * @as(f64, @floatFromInt(i)) / rate));
    }
    return buf;
}

test "resample: the prototype is a symmetric windowed sinc with zero endpoints" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    try testing.expectEqual(table_len, sinc.table.len);
    // Center is sinc(0) * window(0) = 1.
    try testing.expectApproxEqAbs(@as(f32, 1), sinc.table[table_len / 2], 1e-6);
    // The Blackman window reaches zero at both ends of the support.
    try testing.expectApproxEqAbs(@as(f32, 0), sinc.table[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), sinc.table[table_len - 1], 1e-6);
    // Symmetry, and zero outside the support.
    for (0..table_len) |i| {
        try testing.expectApproxEqAbs(sinc.table[i], sinc.table[table_len - 1 - i], 1e-6);
    }
    try testing.expectEqual(@as(f32, 0), sinc.lookup(-half - 1));
    try testing.expectEqual(@as(f32, 0), sinc.lookup(half + 1));
    try testing.expectEqual(@as(f32, 0), sinc.lookup(std.math.nan(f32)));
    // The first zero crossing of sinc is at |x| == 1.
    try testing.expectApproxEqAbs(@as(f32, 0), sinc.lookup(1.0), 1e-3);
}

test "resample: init survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            var sinc = try Sinc.init(alloc);
            defer sinc.deinit(alloc);
            var kernel: Kernel = undefined;
            sinc.build(3.5, 1.0, &kernel);
            try testing.expect(kernel.count > 0);
        }
    }.f, .{});
}

test "resample: DC gain is unity at every ratio and phase" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    const frames = 600;
    const dc = try gpa.alloc(f32, frames);
    defer gpa.free(dc);
    @memset(dc, 0.375);

    const steps = [_]f64{ 0.25, 0.5, 1.0, 1.5, 2.0, 3.7, 8.0 };
    for (steps) |step| {
        var pos: f64 = 40.0;
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            var kernel: Kernel = undefined;
            sinc.build(pos, step, &kernel);
            const value = apply(&kernel, dc, 1, 0, frames, false);
            try testing.expectApproxEqAbs(@as(f32, 0.375), value, 1e-5);
            pos += step;
        }
    }
}

test "resample: upsampling reproduces an analytic sine" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // 1 kHz at 24 kHz, resampled to 48 kHz (step 0.5).
    const frames = 512;
    const src = try sineBuffer(gpa, frames, 24000, 1000);
    defer gpa.free(src);

    var pos: f64 = 32.0;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var kernel: Kernel = undefined;
        sinc.build(pos, 0.5, &kernel);
        const value = apply(&kernel, src, 1, 0, frames, false);
        const expected: f32 = @floatCast(@sin(2.0 * std.math.pi * 1000.0 * pos / 24000.0));
        try testing.expectApproxEqAbs(expected, value, 2e-3);
        pos += 0.5;
    }
}

test "resample: downsampling attenuates what linear interpolation would alias" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // A 16 kHz tone at 48 kHz is above the 12 kHz Nyquist of a 24 kHz output.
    const frames = 2048;
    const src = try sineBuffer(gpa, frames, 48000, 16000);
    defer gpa.free(src);

    var sinc_peak: f32 = 0;
    var linear_peak: f32 = 0;
    var pos: f64 = 200.0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        var kernel: Kernel = undefined;
        sinc.build(pos, 2.0, &kernel);
        const filtered = apply(&kernel, src, 1, 0, frames, false);
        sinc_peak = @max(sinc_peak, @abs(filtered));

        // Plain linear interpolation at the same positions.
        const index0: usize = @intFromFloat(@floor(pos));
        const t: f32 = @floatCast(pos - @floor(pos));
        const a = src[index0];
        const linear = a + (src[index0 + 1] - a) * t;
        linear_peak = @max(linear_peak, @abs(linear));
        pos += 2.0;
    }
    // Linear keeps the full aliased tone; the band-limited filter removes it.
    try testing.expect(linear_peak > 0.8);
    try testing.expect(sinc_peak < 0.2);
    try testing.expect(sinc_peak < linear_peak * 0.25);
}

test "resample: a passband tone survives downsampling" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // 1 kHz is far below the 12 kHz cutoff, so 2:1 decimation must keep it.
    const frames = 2048;
    const src = try sineBuffer(gpa, frames, 48000, 1000);
    defer gpa.free(src);

    var pos: f64 = 200.0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        var kernel: Kernel = undefined;
        sinc.build(pos, 2.0, &kernel);
        const value = apply(&kernel, src, 1, 0, frames, false);
        const expected: f32 = @floatCast(@sin(2.0 * std.math.pi * 1000.0 * pos / 48000.0));
        try testing.expectApproxEqAbs(expected, value, 5e-3);
        pos += 2.0;
    }
}

test "resample: support grows with the ratio and is capped" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);
    var kernel: Kernel = undefined;

    sinc.build(100.0, 1.0, &kernel);
    try testing.expectEqual(taps, kernel.count);
    sinc.build(100.0, 2.0, &kernel);
    try testing.expectEqual(taps * 2, kernel.count);
    sinc.build(100.0, 4.0, &kernel);
    try testing.expectEqual(taps * 4, kernel.count);
    // Upsampling never needs more than the prototype length.
    sinc.build(100.0, 0.25, &kernel);
    try testing.expectEqual(taps, kernel.count);
    // Extreme ratios are capped so the per-sample cost stays bounded.
    sinc.build(1000.0, 100.0, &kernel);
    try testing.expectEqual(max_support, kernel.count);
    try testing.expect(kernel.start >= 0);
}

test "resample: edges clamp and looping wraps without reading out of bounds" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // A tiny clip forces every read through the guarded path.
    const src = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    var kernel: Kernel = undefined;

    sinc.build(0.0, 1.0, &kernel);
    try testing.expect(kernel.start < 0);
    const head = apply(&kernel, &src, 1, 0, src.len, false);
    try testing.expect(std.math.isFinite(head));

    sinc.build(3.0, 1.0, &kernel);
    try testing.expect(kernel.start + @as(i64, @intCast(kernel.count)) > src.len);
    const tail = apply(&kernel, &src, 1, 0, src.len, false);
    // At an integral cursor the prototype is zero at every integer offset, so
    // the kernel degenerates to a delta and returns the sample untouched.
    try testing.expectApproxEqAbs(src[3], tail, 1e-5);

    // At a fractional cursor, looping and clamping disagree at the edges.
    sinc.build(3.5, 1.0, &kernel);
    const tail_frac = apply(&kernel, &src, 1, 0, src.len, false);
    const wrapped = apply(&kernel, &src, 1, 0, src.len, true);
    try testing.expect(std.math.isFinite(tail_frac));
    try testing.expect(std.math.isFinite(wrapped));
    try testing.expect(wrapped != tail_frac);

    // A single-frame clip is constant under both policies.
    const one = [_]f32{0.25};
    sinc.build(0.5, 1.0, &kernel);
    try testing.expectApproxEqAbs(@as(f32, 0.25), apply(&kernel, &one, 1, 0, 1, false), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), apply(&kernel, &one, 1, 0, 1, true), 1e-6);
}

test "resample: interleaved channels are filtered independently" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // Left is a constant, right is its negation: the filter must not mix them.
    const frames = 300;
    const src = try gpa.alloc(f32, frames * 2);
    defer gpa.free(src);
    for (0..frames) |i| {
        src[i * 2] = 0.5;
        src[i * 2 + 1] = -0.5;
    }
    var kernel: Kernel = undefined;
    sinc.build(120.25, 1.5, &kernel);
    try testing.expectApproxEqAbs(@as(f32, 0.5), apply(&kernel, src, 2, 0, frames, false), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -0.5), apply(&kernel, src, 2, 1, frames, false), 1e-5);
}

test "resample: kernels depend only on the fraction, so start can be relocated" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // Same fractional cursor and step, ten frames apart: identical weights,
    // and `start` moved by exactly ten. This is what lets the mixer reuse a
    // kernel across frames instead of rebuilding it.
    const steps = [_]f64{ 1.0, 1.5, 2.0, 0.5, 3.0 };
    for (steps) |step| {
        var a: Kernel = undefined;
        var b: Kernel = undefined;
        sinc.build(100.25, step, &a);
        sinc.build(110.25, step, &b);
        try testing.expectEqualSlices(f32, a.coeffs[0..a.count], b.coeffs[0..b.count]);
        try testing.expectEqual(a.count, b.count);
        try testing.expectEqual(a.inv_norm, b.inv_norm);
        try testing.expectEqual(a.first_offset, b.first_offset);
        try testing.expectEqual(a.start + 10, b.start);
        // Relocating by the documented offset reproduces the rebuilt kernel.
        const relocated = @as(i64, @intFromFloat(@floor(110.25))) + a.first_offset;
        try testing.expectEqual(b.start, relocated);
    }
}

test "resample: the polyphase bank agrees with the flat prototype" {
    const gpa = testing.allocator;
    var sinc = try Sinc.init(gpa);
    defer sinc.deinit(gpa);

    // At unity cutoff the bank row pair must reproduce what the flat table
    // gives, otherwise the two paths would sound different.
    var pos: f64 = 64.0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var kernel: Kernel = undefined;
        sinc.build(pos, 1.0, &kernel);
        try testing.expectEqual(taps, kernel.count);
        const frac: f32 = @floatCast(pos - @floor(pos));
        const half_support: i64 = @intCast(taps / 2);
        for (kernel.coeffs[0..kernel.count], 0..) |coeff, k| {
            const d = @as(f32, @floatFromInt(@as(i64, @intCast(k)) - half_support + 1));
            try testing.expectApproxEqAbs(sinc.lookup(frac - d), coeff, 2e-4);
        }
        pos += 1.0 / 17.0;
    }
}
