//! Audio DSP: insert effects for bus and master chains.
//!
//! This module is **pure signal processing**. It imports only `std` and the
//! sibling `resample` module (also pure DSP, for the shared filter prototype):
//! it knows nothing about voices, buses, the mixer, scenes or assets, so a filter
//! can be tested against its analytic transfer function on its own. The mixer owns the
//! chains and calls `Chain.process` on an interleaved buffer; nothing here
//! allocates, and every effect keeps its state inline.
//!
//! Design rules that the rest of the audio stack relies on:
//! - **Validate once, process cheaply.** Coefficients are computed by the
//!   constructors (`Effect.biquad`, `Effect.compressor`), which reject invalid
//!   parameters. A constructed `Effect` is always valid, so `process` carries no
//!   parameter checks and no transcendentals on the coefficient path.
//! - **No allocation, ever.** Inline filter state is a fixed `[max_channels]`
//!   array; effects that need delay lines borrow a caller-owned buffer instead.
//!   Either way an effect is a value in a preallocated slot array.
//! - **Robust to bad input.** A non-finite input sample is treated as silence
//!   instead of poisoning the filter state forever, and state below an inaudible
//!   threshold is flushed to zero so silence does not leave denormals behind
//!   (which cost orders of magnitude on x86).
//! - **Deterministic.** Same input and same state produce the same output on a
//!   given build. `@exp`/`@log`/`@cos`/`@sin` are used only where the algorithm
//!   needs them, and their last bit may differ across libm implementations —
//!   the same caveat the equal-power pan law already documents.
//!
//! Implemented: RBJ biquad filters (low/high pass, band pass, notch, peaking,
//! low/high shelf), a feed-forward stereo-linked compressor with a soft knee, a
//! feedback delay with damping, a Freeverb-style reverb (eight damped comb
//! filters into four diffusion sections per channel; see `allpassStep`), a
//! lookahead brickwall limiter with optional true-peak detection (see `Limiter`
//! and `SlidingMax`), and an oversampled waveshaping saturator.
//!
//! **Delay-based effects borrow their memory from the caller**, exactly like a
//! `Clip` borrows its samples: `requiredSamples` on `Delay`, `Reverb` and
//! `Limiter` says how much to allocate, `init` carves the lines out of that
//! buffer, and the effect keeps a slice. Nothing here allocates, so a reverb costs no mixer
//! memory and `render` stays allocation-free. The instance must outlive every
//! slot that references it, and two slots must not share one instance or one
//! buffer — the mixer rejects both (see `Effect.borrowedMemory` /
//! `Effect.stateAddress`).
//!
//! Not implemented: convolution, chorus/flanger (modulated delay taps),
//! side-chain input.

const std = @import("std");
/// Sibling pure-DSP module. Only its filter prototype is used, so the
/// oversampling kernels and the resampler's polyphase bank can never drift apart.
const resample = @import("resample.zig");

/// Channel layouts an effect can process. Matches the mixer's output contract
/// (mono or stereo) and keeps the state inline and allocation-free.
pub const max_channels: usize = 2;

/// Anything below this magnitude is flushed to zero. It is ~-300 dBFS, far below
/// audibility, and it keeps recursive filters from crawling through denormals
/// after a signal stops.
const flush_threshold: f32 = 1e-15;

/// Invalid effect parameters (also used for an out-of-range slot or bus by the
/// mixer, which re-exports its own `ParamError`).
pub const Error = error{InvalidValue};

/// Snap an inaudible value to exact zero. Recursive paths that only flush at
/// block boundaries would otherwise crawl through the denormal range for
/// seconds inside a long reverb tail.
inline fn flushSmall(value: f32) f32 {
    return if (@abs(value) < flush_threshold) 0 else value;
}

/// A non-finite sample must never enter a feedback loop: it would circulate
/// forever and silence the effect permanently.
inline fn finite(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

// --- biquad ----------------------------------------------------------------

/// RBJ "Audio EQ Cookbook" biquad kinds.
pub const BiquadKind = enum {
    low_pass,
    high_pass,
    /// Constant peak gain: unity at the center frequency.
    band_pass,
    notch,
    peaking,
    low_shelf,
    high_shelf,
};

pub const BiquadParams = struct {
    kind: BiquadKind = .low_pass,
    /// Corner/center frequency in Hz; must be inside `(0, sample_rate / 2)`.
    cutoff_hz: f32 = 1000,
    /// Quality factor. Higher is narrower for band/notch/peaking and more
    /// resonant for the pass filters. Must be > 0.
    q: f32 = 0.70710678,
    /// Boost/cut in dB, used only by `peaking`, `low_shelf` and `high_shelf`.
    gain_db: f32 = 0,
};

/// Normalized transfer-function coefficients (`a0` already divided out).
pub const Coefficients = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,

    /// Magnitude of `H(e^{jw})` at `freq_hz`. Analytic, used by the tests to
    /// check the filter against the theory rather than against itself.
    pub fn magnitudeAt(self: Coefficients, sample_rate: u32, freq_hz: f64) f64 {
        const w = 2.0 * std.math.pi * freq_hz / @as(f64, @floatFromInt(sample_rate));
        // e^{-jw} and e^{-2jw}
        const c1 = @cos(w);
        const s1 = -@sin(w);
        const c2 = @cos(2.0 * w);
        const s2 = -@sin(2.0 * w);
        const num_re = @as(f64, self.b0) + @as(f64, self.b1) * c1 + @as(f64, self.b2) * c2;
        const num_im = @as(f64, self.b1) * s1 + @as(f64, self.b2) * s2;
        const den_re = 1.0 + @as(f64, self.a1) * c1 + @as(f64, self.a2) * c2;
        const den_im = @as(f64, self.a1) * s1 + @as(f64, self.a2) * s2;
        return @sqrt((num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im));
    }
};

/// Compute RBJ coefficients in double precision, then narrow to f32.
pub fn biquadCoefficients(sample_rate: u32, params: BiquadParams) Error!Coefficients {
    if (sample_rate == 0) return error.InvalidValue;
    const rate: f64 = @floatFromInt(sample_rate);
    if (!std.math.isFinite(params.cutoff_hz) or params.cutoff_hz <= 0) return error.InvalidValue;
    if (!std.math.isFinite(params.q) or params.q <= 0) return error.InvalidValue;
    if (!std.math.isFinite(params.gain_db)) return error.InvalidValue;
    const f0: f64 = params.cutoff_hz;
    if (f0 >= rate * 0.5) return error.InvalidValue;

    const w0 = 2.0 * std.math.pi * f0 / rate;
    const cos_w = @cos(w0);
    const sin_w = @sin(w0);
    const alpha = sin_w / (2.0 * @as(f64, params.q));
    // The cookbook's A is 10^(dB/40) because it appears squared in the formulas.
    const a_lin = std.math.pow(f64, 10.0, @as(f64, params.gain_db) / 40.0);

    var b0: f64 = 0;
    var b1: f64 = 0;
    var b2: f64 = 0;
    var a0: f64 = 0;
    var a1: f64 = 0;
    var a2: f64 = 0;
    switch (params.kind) {
        .low_pass => {
            b0 = (1.0 - cos_w) * 0.5;
            b1 = 1.0 - cos_w;
            b2 = b0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cos_w;
            a2 = 1.0 - alpha;
        },
        .high_pass => {
            b0 = (1.0 + cos_w) * 0.5;
            b1 = -(1.0 + cos_w);
            b2 = b0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cos_w;
            a2 = 1.0 - alpha;
        },
        .band_pass => {
            b0 = alpha;
            b1 = 0;
            b2 = -alpha;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cos_w;
            a2 = 1.0 - alpha;
        },
        .notch => {
            b0 = 1;
            b1 = -2.0 * cos_w;
            b2 = 1;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cos_w;
            a2 = 1.0 - alpha;
        },
        .peaking => {
            b0 = 1.0 + alpha * a_lin;
            b1 = -2.0 * cos_w;
            b2 = 1.0 - alpha * a_lin;
            a0 = 1.0 + alpha / a_lin;
            a1 = -2.0 * cos_w;
            a2 = 1.0 - alpha / a_lin;
        },
        .low_shelf => {
            const s = 2.0 * @sqrt(a_lin) * alpha;
            b0 = a_lin * ((a_lin + 1.0) - (a_lin - 1.0) * cos_w + s);
            b1 = 2.0 * a_lin * ((a_lin - 1.0) - (a_lin + 1.0) * cos_w);
            b2 = a_lin * ((a_lin + 1.0) - (a_lin - 1.0) * cos_w - s);
            a0 = (a_lin + 1.0) + (a_lin - 1.0) * cos_w + s;
            a1 = -2.0 * ((a_lin - 1.0) + (a_lin + 1.0) * cos_w);
            a2 = (a_lin + 1.0) + (a_lin - 1.0) * cos_w - s;
        },
        .high_shelf => {
            const s = 2.0 * @sqrt(a_lin) * alpha;
            b0 = a_lin * ((a_lin + 1.0) + (a_lin - 1.0) * cos_w + s);
            b1 = -2.0 * a_lin * ((a_lin - 1.0) + (a_lin + 1.0) * cos_w);
            b2 = a_lin * ((a_lin + 1.0) + (a_lin - 1.0) * cos_w - s);
            a0 = (a_lin + 1.0) - (a_lin - 1.0) * cos_w + s;
            a1 = 2.0 * ((a_lin - 1.0) - (a_lin + 1.0) * cos_w);
            a2 = (a_lin + 1.0) - (a_lin - 1.0) * cos_w - s;
        },
    }
    if (!(a0 > 0) or !std.math.isFinite(a0)) return error.InvalidValue;
    const coeffs = Coefficients{
        .b0 = @floatCast(b0 / a0),
        .b1 = @floatCast(b1 / a0),
        .b2 = @floatCast(b2 / a0),
        .a1 = @floatCast(a1 / a0),
        .a2 = @floatCast(a2 / a0),
    };
    // Poles must be inside the unit circle, otherwise the filter would grow
    // without bound on a finite input. For the RBJ forms this holds by
    // construction; checking it turns any future formula mistake into an
    // error at set time instead of a blow-up at runtime.
    if (!stable(coeffs)) return error.InvalidValue;
    return coeffs;
}

/// Jury stability test for a second-order denominator `1 + a1 z^-1 + a2 z^-2`.
fn stable(c: Coefficients) bool {
    const a1: f64 = c.a1;
    const a2: f64 = c.a2;
    if (!std.math.isFinite(a1) or !std.math.isFinite(a2)) return false;
    if (!std.math.isFinite(@as(f64, c.b0) + @as(f64, c.b1) + @as(f64, c.b2))) return false;
    return @abs(a2) < 1.0 and @abs(a1) < 1.0 + a2;
}

/// Two-sample history for one channel.
const BiquadState = struct {
    s1: f32 = 0,
    s2: f32 = 0,
};

/// A biquad with inline per-channel state, processed in **transposed direct
/// form II**, which keeps the internal signals better scaled than direct form I
/// for the same coefficients.
pub const Biquad = struct {
    coeffs: Coefficients,
    state: [max_channels]BiquadState = @splat(.{}),

    pub fn process(self: *Biquad, buffer: []f32, channels: usize) void {
        const frames = buffer.len / channels;
        const c = self.coeffs;
        for (0..channels) |ch| {
            var state = &self.state[ch];
            var s1 = state.s1;
            var s2 = state.s2;
            var i: usize = ch;
            var n: usize = 0;
            while (n < frames) : (n += 1) {
                const raw = buffer[i];
                const x = if (std.math.isFinite(raw)) raw else 0;
                const y = c.b0 * x + s1;
                s1 = c.b1 * x - c.a1 * y + s2;
                s2 = c.b2 * x - c.a2 * y;
                buffer[i] = y;
                i += channels;
            }
            // Flush once per block instead of per sample. A decay can still
            // cross the denormal range inside one block, but the state lands on
            // exact zero at the boundary, so the cost is bounded to a single
            // block per decay rather than two compares on every sample.
            state.s1 = if (@abs(s1) < flush_threshold) 0 else s1;
            state.s2 = if (@abs(s2) < flush_threshold) 0 else s2;
        }
    }

    pub fn reset(self: *Biquad) void {
        self.state = @splat(.{});
    }
};

// --- compressor ------------------------------------------------------------

pub const CompressorParams = struct {
    /// Level above which gain reduction starts, in dBFS.
    threshold_db: f32 = -12,
    /// Compression ratio (1 = no compression, 20 = near limiting).
    ratio: f32 = 4,
    /// Width of the soft knee in dB, centered on the threshold. 0 = hard knee.
    knee_db: f32 = 6,
    /// Time to reach ~63% of a gain-reduction increase.
    attack_ms: f32 = 5,
    /// Time to recover ~63% of the way back to unity.
    release_ms: f32 = 80,
    /// Output gain applied after compression, in dB.
    makeup_db: f32 = 0,
};

/// Feed-forward peak compressor, **stereo linked**: the detector follows the
/// loudest channel and applies one gain to both, so compression never shifts
/// the stereo image.
///
/// The static curve is evaluated in dB and the gain reduction is smoothed with
/// separate attack/release one-pole coefficients. Below the threshold with a
/// settled envelope the whole detector is skipped, which is the common case for
/// game audio and keeps the transcendental calls off that path.
pub const Compressor = struct {
    threshold_db: f32,
    /// `1/ratio - 1`, the slope of the gain-reduction curve above the knee.
    slope: f32,
    knee_db: f32,
    /// `1 / (2 * knee)`, precomputed for the quadratic knee segment.
    inv_two_knee: f32,
    attack_coeff: f32,
    release_coeff: f32,
    /// Linear gain applied to every sample (makeup only).
    makeup: f32,
    /// Linear threshold, for the below-threshold fast path.
    threshold_lin: f32,
    /// Smoothed gain reduction in dB (<= 0).
    envelope_db: f32 = 0,

    pub fn init(sample_rate: u32, params: CompressorParams) Error!Compressor {
        if (sample_rate == 0) return error.InvalidValue;
        inline for (.{ "threshold_db", "ratio", "knee_db", "attack_ms", "release_ms", "makeup_db" }) |field| {
            if (!std.math.isFinite(@field(params, field))) return error.InvalidValue;
        }
        if (params.ratio < 1 or params.ratio > 1000) return error.InvalidValue;
        if (params.knee_db < 0 or params.knee_db > 60) return error.InvalidValue;
        if (params.attack_ms <= 0 or params.attack_ms > 10_000) return error.InvalidValue;
        if (params.release_ms <= 0 or params.release_ms > 10_000) return error.InvalidValue;
        if (params.threshold_db < -120 or params.threshold_db > 24) return error.InvalidValue;
        if (params.makeup_db < -60 or params.makeup_db > 60) return error.InvalidValue;

        const rate: f64 = @floatFromInt(sample_rate);
        return .{
            .threshold_db = params.threshold_db,
            .slope = 1.0 / params.ratio - 1.0,
            .knee_db = params.knee_db,
            .inv_two_knee = if (params.knee_db > 0) 1.0 / (2.0 * params.knee_db) else 0,
            .attack_coeff = timeCoefficient(params.attack_ms, rate),
            .release_coeff = timeCoefficient(params.release_ms, rate),
            .makeup = dbToLinear(params.makeup_db),
            .threshold_lin = dbToLinear(params.threshold_db),
        };
    }

    /// Target gain reduction (dB, <= 0) for an input level in dBFS.
    pub fn reductionFor(self: *const Compressor, level_db: f32) f32 {
        const over = level_db - self.threshold_db;
        if (self.knee_db > 0 and 2.0 * over > -self.knee_db) {
            if (2.0 * over <= self.knee_db) {
                const t = over + self.knee_db * 0.5;
                return self.slope * t * t * self.inv_two_knee;
            }
        } else if (over <= 0) {
            return 0;
        }
        return self.slope * over;
    }

    pub fn process(self: *Compressor, buffer: []f32, channels: usize) void {
        const frames = buffer.len / channels;
        // 20/ln(10) and ln(10)/20 convert between natural log and dB without
        // calling log10/pow per sample.
        const to_db: f32 = 8.6858896380650366;
        const from_db: f32 = 0.11512925464970229;
        var env = self.envelope_db;
        var index: usize = 0;
        var n: usize = 0;
        while (n < frames) : (n += 1) {
            var peak: f32 = 0;
            for (0..channels) |ch| {
                const raw = buffer[index + ch];
                const value = if (std.math.isFinite(raw)) raw else 0;
                buffer[index + ch] = value;
                peak = @max(peak, @abs(value));
            }
            if (peak < self.threshold_lin and env == 0) {
                // Below threshold and settled: makeup only, no detector.
                for (0..channels) |ch| buffer[index + ch] *= self.makeup;
            } else {
                const level_db = to_db * @log(@max(peak, 1e-10));
                const target = self.reductionFor(level_db);
                const coeff = if (target < env) self.attack_coeff else self.release_coeff;
                env = coeff * env + (1.0 - coeff) * target;
                if (@abs(env) < 1e-6) env = 0;
                const gain = @exp((env * from_db)) * self.makeup;
                for (0..channels) |ch| buffer[index + ch] *= gain;
            }
            index += channels;
        }
        self.envelope_db = env;
    }

    pub fn reset(self: *Compressor) void {
        self.envelope_db = 0;
    }
};

fn timeCoefficient(ms: f32, rate: f64) f32 {
    const seconds = @as(f64, ms) * 0.001;
    return @floatCast(@exp(-1.0 / (seconds * rate)));
}

fn dbToLinear(db: f32) f32 {
    return @exp(@as(f32, db) * 0.11512925464970229);
}

// --- delay lines -----------------------------------------------------------

/// A circular mono delay line over borrowed memory. Reading and then writing at
/// the same cursor yields a delay of exactly `data.len` samples.
const Line = struct {
    data: []f32,
    index: usize = 0,

    inline fn read(self: *const Line) f32 {
        return self.data[self.index];
    }

    inline fn write(self: *Line, value: f32) void {
        // Flushing on write is what keeps a long tail out of the denormal range:
        // once a value is below the threshold, feedback < 1 keeps it there.
        self.data[self.index] = flushSmall(value);
        self.index += 1;
        if (self.index == self.data.len) self.index = 0;
    }
};

/// Longest delay the parameters may ask for, bounding the size arithmetic.
pub const max_delay_ms: f32 = 10_000;

pub const DelayParams = struct {
    /// Delay time in milliseconds, rounded up to whole samples.
    delay_ms: f32 = 250,
    /// Amount fed back into the line. Must be < 1 so the echo always decays.
    feedback: f32 = 0.35,
    /// 0 = dry only (bit-exact passthrough), 1 = wet only.
    mix: f32 = 0.3,
    /// One-pole low pass in the feedback path, in Hz. 0 disables damping, so
    /// repeats keep their brightness; a few kHz makes them darken naturally.
    damping_hz: f32 = 0,
};

/// Feedback delay (echo). The caller owns the memory: allocate
/// `requiredSamples(...)` floats, keep them alive while the effect is inserted,
/// and never hand the same buffer to two instances.
pub const Delay = struct {
    sample_rate: u32,
    channels: usize,
    lines: [max_channels]Line,
    damp_state: [max_channels]f32 = @splat(0),
    /// Pole of the feedback low pass; 0 means no damping.
    damp_coeff: f32,
    feedback: f32,
    wet: f32,
    dry: f32,
    memory: []f32,

    /// Number of f32 samples the caller must provide.
    pub fn requiredSamples(sample_rate: u32, channels: usize, params: DelayParams) Error!usize {
        const frames = try delayFrames(sample_rate, params.delay_ms);
        try validateChannels(channels);
        return frames * channels;
    }

    pub fn init(sample_rate: u32, channels: usize, params: DelayParams, buffer: []f32) Error!Delay {
        const frames = try delayFrames(sample_rate, params.delay_ms);
        try validateChannels(channels);
        if (!std.math.isFinite(params.feedback) or params.feedback < 0 or params.feedback >= 1) return error.InvalidValue;
        if (!std.math.isFinite(params.mix) or params.mix < 0 or params.mix > 1) return error.InvalidValue;
        if (!std.math.isFinite(params.damping_hz) or params.damping_hz < 0) return error.InvalidValue;
        if (params.damping_hz >= @as(f32, @floatFromInt(sample_rate)) * 0.5) return error.InvalidValue;
        const need = frames * channels;
        if (buffer.len < need) return error.InvalidValue;

        var lines: [max_channels]Line = @splat(.{ .data = buffer[0..0] });
        for (0..channels) |c| lines[c] = .{ .data = buffer[c * frames ..][0..frames] };
        @memset(buffer[0..need], 0);

        const rate: f64 = @floatFromInt(sample_rate);
        const coeff: f32 = if (params.damping_hz > 0)
            @floatCast(@exp(-2.0 * std.math.pi * @as(f64, params.damping_hz) / rate))
        else
            0;
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .lines = lines,
            .damp_coeff = coeff,
            .feedback = params.feedback,
            .wet = params.mix,
            .dry = 1.0 - params.mix,
            .memory = buffer[0..need],
        };
    }

    pub fn process(self: *Delay, buffer: []f32, channels: usize) void {
        std.debug.assert(channels == self.channels);
        const frames = buffer.len / channels;
        // Planar traversal: one line stays hot in cache for the whole block.
        for (0..channels) |c| {
            const line = &self.lines[c];
            var damp = self.damp_state[c];
            var i: usize = c;
            var n: usize = 0;
            while (n < frames) : (n += 1) {
                const x = finite(buffer[i]);
                const delayed = line.read();
                damp = delayed * (1.0 - self.damp_coeff) + damp * self.damp_coeff;
                line.write(x + self.feedback * damp);
                buffer[i] = x * self.dry + delayed * self.wet;
                i += channels;
            }
            self.damp_state[c] = flushSmall(damp);
        }
    }

    /// Silence the line and the damping history, keeping the settings.
    pub fn reset(self: *Delay) void {
        @memset(self.memory, 0);
        for (&self.lines) |*line| line.index = 0;
        self.damp_state = @splat(0);
    }
};

fn validateChannels(channels: usize) Error!void {
    if (channels < 1 or channels > max_channels) return error.InvalidValue;
}

fn delayFrames(sample_rate: u32, delay_ms: f32) Error!usize {
    if (sample_rate == 0) return error.InvalidValue;
    if (!std.math.isFinite(delay_ms) or delay_ms <= 0 or delay_ms > max_delay_ms) return error.InvalidValue;
    const rate: f64 = @floatFromInt(sample_rate);
    const frames = @ceil(@as(f64, delay_ms) * 0.001 * rate);
    if (!(frames >= 1) or frames > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return error.InvalidValue;
    return @intFromFloat(frames);
}

// --- reverb ----------------------------------------------------------------

/// Freeverb's comb and all-pass tunings at 44.1 kHz, scaled to the running rate.
/// The lengths are mutually prime-ish, which is what spreads the resonances out
/// instead of stacking them into a metallic ring.
pub const comb_count: usize = 8;
pub const allpass_count: usize = 4;
const comb_tunings = [comb_count]u32{ 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
const allpass_tunings = [allpass_count]u32{ 556, 441, 341, 225 };
/// Extra samples on the right channel, so the two tails decorrelate.
const stereo_spread: u32 = 23;
const reference_rate: f64 = 44100;
/// All-pass section gain; 0.5 is the classic lossless-ish choice.
const allpass_feedback: f32 = 0.5;
/// Comb outputs are summed, so normalize by the count to keep `wet` meaningful.
const comb_gain: f32 = 1.0 / @as(f32, comb_count);

pub const ReverbParams = struct {
    /// 0 = small/dead, 1 = long tail. Maps to comb feedback 0.70..0.98.
    room_size: f32 = 0.7,
    /// 0 = bright tail, 1 = heavily damped (soft surfaces).
    damping: f32 = 0.5,
    /// Level of the reverberated signal.
    wet: f32 = 0.35,
    /// Level of the dry signal; 1 with `wet = 0` is bit-exact passthrough.
    dry: f32 = 1.0,
};

/// One diffusion step, in Freeverb's form: `v[n] = x[n] + g*v[n-N]` is written to
/// the line and `y[n] = v[n-N] - v[n]` is returned, so
/// `H(z) = (z^-N - 1) / (1 - g*z^-N)`.
///
/// This is *not* a textbook all pass: it has a null at DC and rises to `2/(1+g)`
/// where `z^N = -1`. The null is deliberate and is why the reference uses this
/// form — the comb filters have a DC gain of `1/(1-feedback)` (over 13x at
/// `room_size = 1`), so a flat-magnitude all pass would let an impulse build a
/// slow low-frequency rumble that takes seconds to decay. Diffusing the phase
/// while rejecting DC is what keeps the tail clean.
inline fn allpassStep(line: *Line, input: f32, feedback: f32) f32 {
    const stored = line.read();
    const written = input + stored * feedback;
    line.write(written);
    return stored - written;
}

const Comb = struct {
    line: Line,
    damp: f32 = 0,
};

/// Freeverb-style reverb: eight parallel damped comb filters into four series
/// all-pass sections, per channel, with a stereo spread on the right.
///
/// Like `Delay`, the memory is **borrowed**: allocate `requiredSamples(...)`
/// floats (about 114 KiB for stereo at 48 kHz), keep them alive, and never share
/// them between instances.
pub const Reverb = struct {
    sample_rate: u32,
    channels: usize,
    combs: [max_channels][comb_count]Comb,
    allpasses: [max_channels][allpass_count]Line,
    feedback: f32,
    damp1: f32,
    damp2: f32,
    wet: f32,
    dry: f32,
    memory: []f32,

    pub fn requiredSamples(sample_rate: u32, channels: usize) Error!usize {
        try validateChannels(channels);
        const scale = try rateScale(sample_rate);
        var total: usize = 0;
        for (0..channels) |c| {
            const spread: u32 = if (c == 1) stereo_spread else 0;
            for (comb_tunings) |t| total += scaledLength(t + spread, scale);
            for (allpass_tunings) |t| total += scaledLength(t + spread, scale);
        }
        return total;
    }

    pub fn init(sample_rate: u32, channels: usize, params: ReverbParams, buffer: []f32) Error!Reverb {
        try validateChannels(channels);
        const scale = try rateScale(sample_rate);
        inline for (.{ "room_size", "damping", "wet", "dry" }) |field| {
            const value = @field(params, field);
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidValue;
        }
        const need = try requiredSamples(sample_rate, channels);
        if (buffer.len < need) return error.InvalidValue;

        const empty = Line{ .data = buffer[0..0] };
        var combs: [max_channels][comb_count]Comb = @splat(@splat(.{ .line = empty }));
        var allpasses: [max_channels][allpass_count]Line = @splat(@splat(empty));
        var offset: usize = 0;
        for (0..channels) |c| {
            const spread: u32 = if (c == 1) stereo_spread else 0;
            for (comb_tunings, 0..) |t, k| {
                const len = scaledLength(t + spread, scale);
                combs[c][k] = .{ .line = .{ .data = buffer[offset..][0..len] } };
                offset += len;
            }
            for (allpass_tunings, 0..) |t, k| {
                const len = scaledLength(t + spread, scale);
                allpasses[c][k] = .{ .data = buffer[offset..][0..len] };
                offset += len;
            }
        }
        std.debug.assert(offset == need);
        @memset(buffer[0..need], 0);

        const damp1 = params.damping * 0.4;
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .combs = combs,
            .allpasses = allpasses,
            .feedback = params.room_size * 0.28 + 0.7,
            .damp1 = damp1,
            .damp2 = 1.0 - damp1,
            .wet = params.wet,
            .dry = params.dry,
            .memory = buffer[0..need],
        };
    }

    pub fn process(self: *Reverb, buffer: []f32, channels: usize) void {
        std.debug.assert(channels == self.channels);
        const frames = buffer.len / channels;
        for (0..channels) |c| {
            const combs = &self.combs[c];
            const allpasses = &self.allpasses[c];
            var i: usize = c;
            var n: usize = 0;
            while (n < frames) : (n += 1) {
                const x = finite(buffer[i]);
                var acc: f32 = 0;
                for (combs) |*comb| {
                    const out = comb.line.read();
                    comb.damp = out * self.damp2 + comb.damp * self.damp1;
                    comb.line.write(x + comb.damp * self.feedback);
                    acc += out;
                }
                acc *= comb_gain;
                for (allpasses) |*ap| acc = allpassStep(ap, acc, allpass_feedback);
                buffer[i] = x * self.dry + acc * self.wet;
                i += channels;
            }
            for (combs) |*comb| comb.damp = flushSmall(comb.damp);
        }
    }

    /// Silence every line and damping history, keeping the settings.
    pub fn reset(self: *Reverb) void {
        @memset(self.memory, 0);
        for (&self.combs) |*channel| {
            for (channel) |*comb| {
                comb.line.index = 0;
                comb.damp = 0;
            }
        }
        for (&self.allpasses) |*channel| {
            for (channel) |*ap| ap.index = 0;
        }
    }
};

fn rateScale(sample_rate: u32) Error!f64 {
    if (sample_rate == 0) return error.InvalidValue;
    return @as(f64, @floatFromInt(sample_rate)) / reference_rate;
}

fn scaledLength(tuning: u32, scale: f64) usize {
    const scaled = @round(@as(f64, @floatFromInt(tuning)) * scale);
    return @max(1, @as(usize, @intFromFloat(scaled)));
}

// --- oversampling ----------------------------------------------------------

/// Taps per polyphase branch. At 4x this is the 48-tap filter ITU-R BS.1770
/// specifies for true-peak measurement, which is why the limiter uses it too.
pub const oversample_taps: usize = 12;
/// Highest supported factor. 1 means "process at the base rate".
pub const max_oversample: usize = 4;

/// Round-trip latency of the oversampled path, in base-rate frames. It falls out
/// of the two causal shifts (interpolation needs `taps/2 - 1` future samples,
/// decimation the rest) and is independent of the factor.
pub const oversample_latency: usize = oversample_taps - 1;
/// Where the dry tap sits in the input history: the sample delayed by exactly
/// `oversample_latency`, so a dry/wet mix stays phase-aligned.
const dry_tap: usize = oversample_taps - 1 - oversample_latency;
/// How far ahead the interpolator must look, in base frames.
const interp_delay: usize = oversample_taps / 2 - 1;

/// Up kernels indexed `[phase][tap]`, oldest tap first. Phase 0 is exactly a
/// delta, so it reproduces the input sample and costs nothing to reason about.
fn buildUpKernel(comptime factor: usize) [factor][oversample_taps]f32 {
    @setEvalBranchQuota(100_000);
    const h: f64 = @floatFromInt(oversample_taps / 2);
    var out: [factor][oversample_taps]f32 = undefined;
    for (0..factor) |p| {
        if (p == 0) {
            // Phase 0 is a delta mathematically; `sin(pi*k)` is only ~1e-35 in
            // floating point, so build it exactly rather than nearly.
            for (&out[p]) |*v| v.* = 0;
            out[p][oversample_taps / 2] = 1;
            continue;
        }
        const frac = @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(factor));
        var sum: f64 = 0;
        for (0..oversample_taps) |i| {
            const v = resample.prototype(h - @as(f64, @floatFromInt(i)) + frac, h);
            out[p][i] = @floatCast(v);
            sum += v;
        }
        // Normalize per phase so a constant signal stays exactly constant.
        for (0..oversample_taps) |i| out[p][i] = @floatCast(@as(f64, out[p][i]) / sum);
    }
    return out;
}

/// Decimation kernel, oldest tap first, normalized to unity DC gain.
///
/// The length is **odd** (`factor * taps + 1`) on purpose. An even-length kernel
/// is symmetric about a half-sample, which at an even decimation factor is a
/// fractional delay at the base rate; an odd one is symmetric about a real tap,
/// so the filter is exactly linear-phase and its group delay is a whole number
/// of base frames. The two end taps land where the window is zero.
fn buildDownKernel(comptime factor: usize) [factor * oversample_taps + 1]f32 {
    @setEvalBranchQuota(100_000);
    const h: f64 = @floatFromInt(oversample_taps / 2);
    const f: f64 = @floatFromInt(factor);
    const n = factor * oversample_taps + 1;
    var out: [n]f32 = undefined;
    var sum: f64 = 0;
    for (0..n) |j| {
        const v = resample.prototype(h - @as(f64, @floatFromInt(j)) / f, h) / f;
        out[j] = @floatCast(v);
        sum += v;
    }
    for (&out) |*v| v.* = @floatCast(@as(f64, v.*) / sum);
    return out;
}

const up_kernel_2 = buildUpKernel(2);
const up_kernel_4 = buildUpKernel(4);
const down_kernel_2 = buildDownKernel(2);
const down_kernel_4 = buildDownKernel(4);
/// High-rate history length: enough for the longest decimator plus the `F - 1`
/// samples it reads back from the newest, so every factor uses the same array.
const hi_history_len: usize = max_oversample * (oversample_taps + 1);

/// Fixed-length history whose live window is always **contiguous**: every write
/// is mirrored into a second copy of the buffer, so the dot products run over a
/// plain slice with no modular indexing in the inner loop. Two stores per sample
/// buy a vectorizable inner loop, which is the whole point at these tap counts.
fn History(comptime n: usize) type {
    return struct {
        data: [2 * n]f32 = @splat(0),
        pos: usize = 0,

        const Self = @This();

        inline fn push(self: *Self, value: f32) void {
            self.data[self.pos] = value;
            self.data[self.pos + n] = value;
            self.pos += 1;
            if (self.pos == n) self.pos = 0;
        }

        /// The last `n` values, oldest first. Valid until the next push.
        inline fn window(self: *const Self) *const [n]f32 {
            return self.data[self.pos..][0..n];
        }

        inline fn clear(self: *Self) void {
            self.data = @splat(0);
            self.pos = 0;
        }
    };
}

inline fn dot(comptime n: usize, kernel: *const [n]f32, values: *const [n]f32) f32 {
    var acc: f32 = 0;
    for (kernel, values) |h, v| acc += h * v;
    return acc;
}

/// Soft clipper. `tanh` is odd, monotonic and bounded by 1, so the shaped signal
/// cannot run away however hard it is driven.
inline fn shape(x: f32, drive: f32) f32 {
    return std.math.tanh(drive * x);
}

pub const SaturatorParams = struct {
    /// Gain into the shaper. 1 is gentle, 10 is heavy; the output stays bounded
    /// by 1 either way.
    drive: f32 = 1.0,
    /// 0 is bit-exact dry, 1 is fully shaped.
    mix: f32 = 1.0,
    /// 1, 2 or 4. Above 1 the shaper runs at the higher rate, so the harmonics it
    /// creates above the base Nyquist are filtered out instead of folding back.
    ///
    /// The default is 2, not 4: with this filter length the decimator's stopband
    /// is the limiting factor, so 4x measures within a few percent of 2x on a
    /// hard-driven tone while costing ~40% more. Reach for 4 when the drive is
    /// extreme enough to put real energy above twice the base Nyquist.
    oversample: usize = 2,
};

/// Waveshaping saturator with optional 2x/4x oversampling.
///
/// A nonlinearity generates harmonics far above the input bandwidth. At the base
/// rate those fold back as inharmonic aliasing, which is the characteristic
/// "digital" harshness of naive distortion. Running the shaper at 2x or 4x and
/// filtering on the way back down moves the fold-back point above the audible
/// band.
///
/// All state is fixed-size and inline, so this effect needs **no borrowed
/// buffer** at all — only the instance itself, which the caller owns. Memory is
/// independent of the block size.
pub const Saturator = struct {
    sample_rate: u32,
    channels: usize,
    factor: usize,
    up: []const [oversample_taps]f32,
    down: []const f32,
    drive: f32,
    wet: f32,
    dry: f32,
    in_hist: [max_channels]History(oversample_taps),
    hi_hist: [max_channels]History(hi_history_len),

    pub fn init(sample_rate: u32, channels: usize, params: SaturatorParams) Error!Saturator {
        if (sample_rate == 0) return error.InvalidValue;
        try validateChannels(channels);
        if (!std.math.isFinite(params.drive) or params.drive < 0.01 or params.drive > 100) return error.InvalidValue;
        if (!std.math.isFinite(params.mix) or params.mix < 0 or params.mix > 1) return error.InvalidValue;
        const factor = params.oversample;
        if (factor != 1 and factor != 2 and factor != 4) return error.InvalidValue;
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .factor = factor,
            .up = switch (factor) {
                2 => &up_kernel_2,
                4 => &up_kernel_4,
                else => &.{},
            },
            .down = switch (factor) {
                2 => &down_kernel_2,
                4 => &down_kernel_4,
                else => &.{},
            },
            .drive = params.drive,
            .wet = params.mix,
            .dry = 1.0 - params.mix,
            .in_hist = @splat(.{}),
            .hi_hist = @splat(.{}),
        };
    }

    pub fn process(self: *Saturator, buffer: []f32, channels: usize) void {
        std.debug.assert(channels == self.channels);
        const drive = self.drive;
        const wet = self.wet;
        const dry = self.dry;

        if (self.factor == 1) {
            // No oversampling, no latency, no filtering.
            for (buffer) |*v| {
                const x = finite(v.*);
                v.* = x * dry + shape(x, drive) * wet;
            }
            return;
        }

        const frames = buffer.len / channels;
        var i: usize = 0;
        var n: usize = 0;
        while (n < frames) : (n += 1) {
            for (0..channels) |c| {
                const x = finite(buffer[i + c]);
                const in_hist = &self.in_hist[c];
                in_hist.push(x);
                const window = in_hist.window();

                // Interpolate, shape at the high rate, keep the shaped samples.
                const hi = &self.hi_hist[c];
                for (self.up) |*kernel| hi.push(shape(dot(oversample_taps, kernel, window), drive));

                // Decimate back down, filtering out everything the shaper put
                // above the base Nyquist. The kernel is symmetric, so it pairs
                // directly with the oldest-first window; it ends `factor - 1`
                // samples before the newest, which is what makes the group
                // delay a whole number of base frames.
                const hw = hi.window();
                const start = hi_history_len - self.factor * (oversample_taps + 1);
                const span = hw[start..][0..self.down.len];
                var acc: f32 = 0;
                for (self.down, span) |h, v| acc += h * v;

                // The dry path is tapped from the same history at exactly the
                // round-trip delay, so mixing never comb-filters.
                buffer[i + c] = window[dry_tap] * dry + acc * wet;
            }
            i += channels;
        }
    }

    /// Latency added by the oversampled path, in frames per channel. Zero when
    /// `oversample == 1`.
    pub fn latencyFrames(self: *const Saturator) usize {
        return if (self.factor == 1) 0 else oversample_latency;
    }

    pub fn reset(self: *Saturator) void {
        for (&self.in_hist) |*h| h.clear();
        for (&self.hi_hist) |*h| h.clear();
    }
};

// --- lookahead limiter -----------------------------------------------------

/// Longest lookahead the limiter accepts, in milliseconds. It bounds the borrowed
/// buffer and the latency a caller can accidentally ask for.
pub const max_lookahead_ms: f32 = 100;

/// Brickwall ceiling range. A limiter attenuates; it never makes anything louder,
/// so the ceiling is at most 0 dBFS. The floor keeps `ceiling / peak` well away
/// from the denormal range.
pub const min_ceiling_db: f32 = -120;

pub const LimiterParams = struct {
    /// Output ceiling in dBFS, in `[-120, 0]`.
    ceiling_db: f32 = -1.0,
    /// How far ahead the detector looks. **This is also the added latency**, in
    /// frames `ceil(lookahead_ms * rate / 1000)`. 0 is allowed and gives a
    /// zero-latency limiter that reacts within the same sample.
    lookahead_ms: f32 = 5.0,
    /// One-pole recovery towards unity after the peak leaves the window.
    /// 0 means instant recovery.
    release_ms: f32 = 100.0,
    /// Detect **inter-sample** peaks by measuring the 4x oversampled waveform,
    /// as ITU-R BS.1770 does. A sample-peak limiter can let the reconstructed
    /// analogue signal exceed the ceiling between samples; this closes that gap
    /// at the cost of the interpolator's MACs and `interp_delay` extra frames of
    /// latency (reported by `latencyFrames`). Off by default, so existing
    /// instances are bit-identical.
    true_peak: bool = false,
};

/// Sliding-window maximum in O(1) amortized, built from two stacks that each
/// carry a running aggregate (a "sliding window aggregation", or SWAG).
///
/// Every entry is **two f32**: the value, and the maximum of everything at or
/// below it in that stack. The window maximum is then the larger of the two
/// stack aggregates. That f32-only layout is the point: the structure shares the
/// same borrowed `[]f32` as the delay lines. A monotonic deque would need integer
/// expiry stamps, which cannot live in an f32 buffer without an alignment cast.
///
/// The window is fixed, so there is exactly one push and at most one pop per
/// sample. The stacks grow towards each other inside one region of `capacity`
/// entries and their lengths always sum to at most `capacity`, so they can never
/// collide. Transferring the back stack to the front reverses the order and
/// recomputes the aggregates; each entry is moved at most once, which is where
/// the amortized bound comes from.
const SlidingMax = struct {
    /// `capacity` entries of `[value, aggregate]`.
    slots: []f32,
    capacity: usize,
    front_len: usize = 0,
    back_len: usize = 0,

    fn init(storage: []f32, capacity: usize) SlidingMax {
        std.debug.assert(capacity >= 1);
        std.debug.assert(storage.len >= capacity * 2);
        return .{ .slots = storage[0 .. capacity * 2], .capacity = capacity };
    }

    inline fn frontAggregate(self: *const SlidingMax) f32 {
        return if (self.front_len == 0) 0 else self.slots[(self.front_len - 1) * 2 + 1];
    }

    inline fn backAggregate(self: *const SlidingMax) f32 {
        return if (self.back_len == 0) 0 else self.slots[(self.capacity - self.back_len) * 2 + 1];
    }

    inline fn len(self: *const SlidingMax) usize {
        return self.front_len + self.back_len;
    }

    inline fn max(self: *const SlidingMax) f32 {
        return @max(self.frontAggregate(), self.backAggregate());
    }

    fn push(self: *SlidingMax, value: f32) void {
        std.debug.assert(self.len() < self.capacity);
        const entry = self.capacity - self.back_len - 1;
        const aggregate = @max(value, self.backAggregate());
        self.slots[entry * 2] = value;
        self.slots[entry * 2 + 1] = aggregate;
        self.back_len += 1;
    }

    fn pop(self: *SlidingMax) void {
        if (self.front_len == 0) {
            while (self.back_len > 0) {
                // Read before writing: when the region is full these are the
                // same slot, and the value must survive the move.
                const value = self.slots[(self.capacity - self.back_len) * 2];
                self.back_len -= 1;
                const aggregate = @max(value, self.frontAggregate());
                self.slots[self.front_len * 2] = value;
                self.slots[self.front_len * 2 + 1] = aggregate;
                self.front_len += 1;
            }
        }
        std.debug.assert(self.front_len > 0);
        self.front_len -= 1;
    }

    fn clear(self: *SlidingMax) void {
        self.front_len = 0;
        self.back_len = 0;
    }
};

/// Lookahead brickwall limiter.
///
/// The detector runs on the **input** while the audio is delayed by the same
/// amount, so by the time a transient reaches the output the gain has already
/// been pulled down. The detector keeps the maximum over a window of
/// `lookahead + 1` samples ending at the current input, which covers the sample
/// being emitted and everything that will replace it before the next one.
///
/// The envelope takes the lower of the target and a one-pole recovery towards
/// unity: instant attack, gradual release, and never above what the window
/// actually needs. That last clamp is what makes overshoot impossible rather
/// than merely unlikely — a release-only envelope can climb back above the
/// target between two peaks and let a sample through.
///
/// The recovery state is the *distance* from unity, not the gain, so it reaches
/// exactly 1.0 instead of stalling a few 1e-5 short (see `Limiter.distance`).
pub const Limiter = struct {
    sample_rate: u32,
    channels: usize,
    lines: [max_channels]Line,
    detector: SlidingMax,
    true_peak: bool,
    /// Per-channel interpolation history for true-peak detection. Inline and
    /// fixed-size, so enabling the option needs no extra borrowed memory.
    interp: [max_channels]History(oversample_taps),
    delay_frames: usize,
    window: usize,
    ceiling: f32,
    release_coeff: f32,
    /// Last gain actually applied. A meter, never fed back into the recurrence.
    envelope: f32 = 1,
    /// `1 - gain`, the authoritative release state. Keeping the *distance* rather
    /// than the gain is what lets recovery reach exactly unity: near 1.0 an f32
    /// gain has only ~6e-8 of absolute resolution, so a per-frame increment of
    /// `distance * (1 - r)` vanishes into rounding and the envelope stalls
    /// ~7e-5 short of unity. The distance decays with full relative precision
    /// instead, and is never reconstructed from the rounded gain.
    distance: f32 = 0,
    memory: []f32,

    /// Number of f32 samples the caller must provide: the audio delay lines plus
    /// the detector's two-stack region.
    pub fn requiredSamples(sample_rate: u32, channels: usize, params: LimiterParams) Error!usize {
        const look = try lookaheadFrames(sample_rate, params.lookahead_ms);
        try validateChannels(channels);
        try validateLimiter(params);
        const delay = look + truePeakDelay(params.true_peak);
        return delay * channels + (look + 1) * 2;
    }

    pub fn init(sample_rate: u32, channels: usize, params: LimiterParams, buffer: []f32) Error!Limiter {
        const look = try lookaheadFrames(sample_rate, params.lookahead_ms);
        try validateChannels(channels);
        try validateLimiter(params);
        // The detector reports the peak of the sample `interp_delay` frames back,
        // because interpolation needs future samples. Delaying the audio by the
        // same extra amount keeps the emitted sample inside the detector window,
        // so the ceiling guarantee is unchanged.
        const frames = look + truePeakDelay(params.true_peak);
        const window = look + 1;
        const need = frames * channels + window * 2;
        if (buffer.len < need) return error.InvalidValue;

        var lines: [max_channels]Line = @splat(.{ .data = buffer[0..0] });
        for (0..channels) |c| lines[c] = .{ .data = buffer[c * frames ..][0..frames] };
        @memset(buffer[0..need], 0);

        const rate: f64 = @floatFromInt(sample_rate);
        const coeff: f32 = if (params.release_ms > 0)
            @floatCast(@exp(-1.0 / (@as(f64, params.release_ms) * 0.001 * rate)))
        else
            0;
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .lines = lines,
            .detector = SlidingMax.init(buffer[frames * channels ..][0 .. window * 2], window),
            .true_peak = params.true_peak,
            .interp = @splat(.{}),
            .delay_frames = frames,
            .window = window,
            .ceiling = @floatCast(std.math.pow(f64, 10.0, @as(f64, params.ceiling_db) / 20.0)),
            .release_coeff = coeff,
            .memory = buffer[0..need],
        };
    }

    pub fn process(self: *Limiter, buffer: []f32, channels: usize) void {
        std.debug.assert(channels == self.channels);
        const ceiling = self.ceiling;
        const r = self.release_coeff;
        const delayed_path = self.delay_frames != 0;
        var distance = self.distance;
        // Seed from the current meter so an empty block leaves it alone.
        var env: f32 = self.envelope;
        var i: usize = 0;
        while (i < buffer.len) : (i += channels) {
            // One detector across all channels: linking the peak is what keeps
            // limiting from pulling the stereo image towards the quieter side.
            var x: [max_channels]f32 = @splat(0);
            var peak: f32 = 0;
            for (0..channels) |c| {
                x[c] = finite(buffer[i + c]);
                peak = @max(peak, @abs(x[c]));
            }
            if (self.true_peak) {
                // Measure the waveform the DAC will actually reconstruct, not
                // just the samples. Phase 0 is a delta, so this also covers the
                // base-rate peak of the sample being reported.
                for (0..channels) |c| {
                    self.interp[c].push(x[c]);
                    const w = self.interp[c].window();
                    for (&up_kernel_4) |*kernel| {
                        peak = @max(peak, @abs(dot(oversample_taps, kernel, w)));
                    }
                }
            }

            if (self.detector.len() == self.window) self.detector.pop();
            self.detector.push(peak);

            const loudest = self.detector.max();
            const target: f32 = if (loudest > ceiling) ceiling / loudest else 1;
            distance = flushSmall(distance * r);
            const recovered = 1.0 - distance;
            if (target < recovered) {
                // Instant attack. Snapping the state to the target keeps the
                // release starting from where the gain actually is.
                distance = 1.0 - target;
                env = target;
            } else {
                // Gradual release, and `env <= target` holds in both branches:
                // that is what makes overshoot impossible rather than unlikely.
                env = recovered;
            }

            for (0..channels) |c| {
                const line = &self.lines[c];
                const out = if (delayed_path) line.read() else x[c];
                if (delayed_path) line.write(x[c]);
                buffer[i + c] = out * env;
            }
        }
        self.distance = distance;
        self.envelope = env;
    }

    /// Silence the delay lines and the detector and restore unity gain, keeping
    /// the settings.
    pub fn reset(self: *Limiter) void {
        @memset(self.memory, 0);
        for (&self.lines) |*line| line.index = 0;
        self.detector.clear();
        for (&self.interp) |*h| h.clear();
        self.envelope = 1;
        self.distance = 0;
    }

    /// Latency this instance adds, in frames per channel. Report it to anything
    /// that needs to stay aligned with the limited signal.
    pub fn latencyFrames(self: *const Limiter) usize {
        return self.delay_frames;
    }

    /// Current gain reduction in dB (0 when unity, negative while limiting).
    /// Floored at -240 dB so a fully muted envelope still returns a finite value.
    pub fn gainReductionDb(self: *const Limiter) f32 {
        return @floatCast(20.0 * @log10(@as(f64, @max(self.envelope, 1e-12))));
    }
};

/// Extra audio delay the true-peak detector needs so the sample it reports is
/// the one being emitted.
inline fn truePeakDelay(enabled: bool) usize {
    return if (enabled) interp_delay else 0;
}

fn validateLimiter(params: LimiterParams) Error!void {
    if (!std.math.isFinite(params.ceiling_db) or params.ceiling_db > 0 or params.ceiling_db < min_ceiling_db) return error.InvalidValue;
    if (!std.math.isFinite(params.release_ms) or params.release_ms < 0 or params.release_ms > 10_000) return error.InvalidValue;
}

fn lookaheadFrames(sample_rate: u32, lookahead_ms: f32) Error!usize {
    if (sample_rate == 0) return error.InvalidValue;
    if (!std.math.isFinite(lookahead_ms) or lookahead_ms < 0 or lookahead_ms > max_lookahead_ms) return error.InvalidValue;
    const frames = @ceil(@as(f64, lookahead_ms) * @as(f64, @floatFromInt(sample_rate)) / 1000.0);
    return @intFromFloat(frames);
}

// --- effect + chain --------------------------------------------------------

/// One insert slot. The `sample_rate` it was designed for travels with it, so a
/// host can reject an effect built for a different rate instead of silently
/// filtering at the wrong frequency.
pub const Effect = struct {
    sample_rate: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        bypass,
        biquad: Biquad,
        compressor: Compressor,
        /// Borrowed instance: the caller owns the struct *and* its delay memory.
        /// A pointer keeps `Effect` small — a reverb carries ~750 bytes of line
        /// state, and inlining that would bloat every insert slot on every bus.
        delay: *Delay,
        reverb: *Reverb,
        limiter: *Limiter,
        saturator: *Saturator,
    };

    /// Identity. `process` returns immediately, and a chain of these is bit-exact.
    pub const bypass: Effect = .{ .sample_rate = 0, .kind = .bypass };

    pub fn biquad(sample_rate: u32, params: BiquadParams) Error!Effect {
        return .{
            .sample_rate = sample_rate,
            .kind = .{ .biquad = .{ .coeffs = try biquadCoefficients(sample_rate, params) } },
        };
    }

    pub fn compressor(sample_rate: u32, params: CompressorParams) Error!Effect {
        return .{
            .sample_rate = sample_rate,
            .kind = .{ .compressor = try Compressor.init(sample_rate, params) },
        };
    }

    /// Wrap an initialized `Delay`. Infallible: the instance validated its own
    /// parameters and buffer in `init`. Keep it alive and unshared while it is
    /// inserted — the host checks both (see `borrowedMemory`/`stateAddress`).
    pub fn delay(instance: *Delay) Effect {
        return .{ .sample_rate = instance.sample_rate, .kind = .{ .delay = instance } };
    }

    /// Wrap an initialized `Reverb`. Same ownership rules as `delay`.
    pub fn reverb(instance: *Reverb) Effect {
        return .{ .sample_rate = instance.sample_rate, .kind = .{ .reverb = instance } };
    }

    /// Wrap an initialized `Limiter`. Same ownership rules as `delay`. As a
    /// master insert it runs **before** `master_gain` and the output clamp.
    pub fn limiter(instance: *Limiter) Effect {
        return .{ .sample_rate = instance.sample_rate, .kind = .{ .limiter = instance } };
    }

    /// Wrap an initialized `Saturator`. The instance is borrowed like the others,
    /// but it owns all its state inline, so there is no buffer to keep alive.
    pub fn saturator(instance: *Saturator) Effect {
        return .{ .sample_rate = instance.sample_rate, .kind = .{ .saturator = instance } };
    }

    /// Layout this effect was built for, or 0 when it adapts to any layout.
    /// Delay lines are allocated per channel, so they cannot be reinterpreted.
    pub fn channelCount(self: Effect) u16 {
        return switch (self.kind) {
            .delay => |instance| @intCast(instance.channels),
            .reverb => |instance| @intCast(instance.channels),
            .limiter => |instance| @intCast(instance.channels),
            .saturator => |instance| @intCast(instance.channels),
            else => 0,
        };
    }

    /// The delay memory this effect borrows, if any. The host uses it to reject
    /// two inserts whose buffers overlap, which would corrupt both.
    pub fn borrowedMemory(self: Effect) ?[]const f32 {
        return switch (self.kind) {
            .delay => |instance| instance.memory,
            .reverb => |instance| instance.memory,
            .limiter => |instance| instance.memory,
            else => null,
        };
    }

    /// Address of the borrowed instance, if any. Two slots holding the same
    /// instance would advance its cursors twice per sample.
    pub fn stateAddress(self: Effect) ?usize {
        return switch (self.kind) {
            .delay => |instance| @intFromPtr(instance),
            .reverb => |instance| @intFromPtr(instance),
            .limiter => |instance| @intFromPtr(instance),
            .saturator => |instance| @intFromPtr(instance),
            else => null,
        };
    }

    pub fn process(self: *Effect, buffer: []f32, channels: usize) void {
        std.debug.assert(channels >= 1 and channels <= max_channels);
        std.debug.assert(buffer.len % channels == 0);
        switch (self.kind) {
            .bypass => {},
            .biquad => |*filter| filter.process(buffer, channels),
            .compressor => |*comp| comp.process(buffer, channels),
            .delay => |instance| instance.process(buffer, channels),
            .reverb => |instance| instance.process(buffer, channels),
            .limiter => |instance| instance.process(buffer, channels),
            .saturator => |instance| instance.process(buffer, channels),
        }
    }

    /// Clear the internal history, keeping the settings. Call after a seek or a
    /// device underrun so an old tail does not bleed into the new material.
    pub fn reset(self: *Effect) void {
        switch (self.kind) {
            .bypass => {},
            .biquad => |*filter| filter.reset(),
            .compressor => |*comp| comp.reset(),
            .delay => |instance| instance.reset(),
            .reverb => |instance| instance.reset(),
            .limiter => |instance| instance.reset(),
            .saturator => |instance| instance.reset(),
        }
    }
};

/// An ordered insert chain over a borrowed slice of slots. The host owns the
/// storage (the mixer preallocates one chain per bus plus a master chain), so
/// processing allocates nothing and a bypassed slot costs one tag check.
pub const Chain = struct {
    effects: []Effect,

    pub fn process(self: Chain, buffer: []f32, channels: usize) void {
        for (self.effects) |*effect| effect.process(buffer, channels);
    }

    pub fn reset(self: Chain) void {
        for (self.effects) |*effect| effect.reset();
    }

    /// True when at least one slot does something. The mixer uses this to decide
    /// whether a bus needs its own submix buffer or can write straight to the
    /// output, which is what keeps the bypassed path bit-exact.
    pub fn active(self: Chain) bool {
        for (self.effects) |effect| {
            if (effect.kind != .bypass) return true;
        }
        return false;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Run a filter over `frames` of a unit sine and return the settled amplitude.
///
/// The estimator is RMS over a whole number of periods, not a sample peak: a
/// filter shifts the phase, so the output peak generally falls *between*
/// samples and a peak reading would under-report the gain by several percent.
fn measureGain(effect: *Effect, rate: u32, freq: f64, frames: usize) !f32 {
    const gpa = testing.allocator;
    const buf = try gpa.alloc(f32, frames);
    defer gpa.free(buf);
    const w = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(rate));
    for (buf, 0..) |*v, i| v.* = @floatCast(@sin(w * @as(f64, @floatFromInt(i))));

    effect.reset();
    effect.process(buf, 1);
    // Skip the settling transient, then integrate over complete cycles only.
    const settle = frames / 2;
    const period: usize = @intFromFloat(@round(@as(f64, @floatFromInt(rate)) / freq));
    const usable = ((frames - settle) / period) * period;
    try testing.expect(usable > 0);
    var sum_sq: f64 = 0;
    for (buf[settle..][0..usable]) |v| sum_sq += @as(f64, v) * @as(f64, v);
    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(usable)));
    return @floatCast(rms * @sqrt(2.0));
}

test "effects: biquad parameters are validated at construction" {
    const rate = 48000;
    try testing.expectError(error.InvalidValue, biquadCoefficients(0, .{}));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .cutoff_hz = 0 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .cutoff_hz = -100 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .cutoff_hz = 24000 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .cutoff_hz = 30000 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .cutoff_hz = std.math.nan(f32) }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .q = 0 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .q = -1 }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .q = std.math.inf(f32) }));
    try testing.expectError(error.InvalidValue, biquadCoefficients(rate, .{ .gain_db = std.math.nan(f32) }));
    // A valid one is accepted and carries its rate.
    const effect = try Effect.biquad(rate, .{ .kind = .low_pass, .cutoff_hz = 1000 });
    try testing.expectEqual(@as(u32, rate), effect.sample_rate);
}

test "effects: low pass and high pass match the analytic response" {
    const rate = 48000;
    const cutoff = 2000.0;
    // 12000/m Hz puts the sine's peak exactly on a sample at 48 kHz.
    const freqs = [_]f64{ 100, 500, 2000, 4000, 12000 };
    for ([_]BiquadKind{ .low_pass, .high_pass }) |kind| {
        var effect = try Effect.biquad(rate, .{ .kind = kind, .cutoff_hz = cutoff, .q = 0.70710678 });
        const coeffs = effect.kind.biquad.coeffs;
        for (freqs) |freq| {
            const measured = try measureGain(&effect, rate, freq, 8192);
            const expected: f32 = @floatCast(coeffs.magnitudeAt(rate, freq));
            try testing.expectApproxEqAbs(expected, measured, 0.02);
        }
    }
}

test "effects: every biquad kind matches its transfer function" {
    const rate = 48000;
    const kinds = [_]BiquadKind{ .low_pass, .high_pass, .band_pass, .notch, .peaking, .low_shelf, .high_shelf };
    for (kinds) |kind| {
        var effect = try Effect.biquad(rate, .{
            .kind = kind,
            .cutoff_hz = 1500,
            .q = 1.2,
            .gain_db = 9,
        });
        const coeffs = effect.kind.biquad.coeffs;
        for ([_]f64{ 150, 1500, 6000 }) |freq| {
            const measured = try measureGain(&effect, rate, freq, 8192);
            const expected: f32 = @floatCast(coeffs.magnitudeAt(rate, freq));
            try testing.expectApproxEqAbs(expected, measured, 0.02);
        }
    }
}

test "effects: pass filters have the expected limits at DC and Nyquist" {
    const rate = 48000;
    // DC through a low pass is unity; through a high pass it is zero.
    var lp = try Effect.biquad(rate, .{ .kind = .low_pass, .cutoff_hz = 1000 });
    var hp = try Effect.biquad(rate, .{ .kind = .high_pass, .cutoff_hz = 1000 });
    var dc: [4096]f32 = @splat(0.5);
    lp.process(&dc, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dc[dc.len - 1], 1e-4);
    var dc2: [4096]f32 = @splat(0.5);
    hp.process(&dc2, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), dc2[dc2.len - 1], 1e-4);

    // An alternating signal is Nyquist: the low pass kills it, the high pass keeps it.
    var nyq: [4096]f32 = undefined;
    for (&nyq, 0..) |*v, i| v.* = if (i % 2 == 0) 0.5 else -0.5;
    lp.reset();
    lp.process(&nyq, 1);
    var peak: f32 = 0;
    for (nyq[2048..]) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak < 0.01);

    var nyq2: [4096]f32 = undefined;
    for (&nyq2, 0..) |*v, i| v.* = if (i % 2 == 0) 0.5 else -0.5;
    hp.process(&nyq2, 1);
    peak = 0;
    for (nyq2[2048..]) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);
}

test "effects: a peaking filter at 0 dB is transparent" {
    const rate = 48000;
    var effect = try Effect.biquad(rate, .{ .kind = .peaking, .cutoff_hz = 1000, .q = 2, .gain_db = 0 });
    const c = effect.kind.biquad.coeffs;
    // With no boost the numerator equals the denominator, so H(z) == 1.
    try testing.expectApproxEqAbs(@as(f32, 1), c.b0, 1e-6);
    try testing.expectApproxEqAbs(c.a1, c.b1, 1e-6);
    try testing.expectApproxEqAbs(c.a2, c.b2, 1e-6);

    var buf = [_]f32{ 0.1, -0.4, 0.9, -0.2, 0.33, 0.7, -0.85, 0.05 };
    const original = buf;
    effect.process(&buf, 1);
    for (buf, original) |got, want| try testing.expectApproxEqAbs(want, got, 1e-6);
}

test "effects: shelves reach their rated boost at the extremes" {
    const rate = 48000;
    const boost_db = 12.0;
    const expected = std.math.pow(f32, 10.0, boost_db / 20.0);

    var low = try Effect.biquad(rate, .{ .kind = .low_shelf, .cutoff_hz = 1000, .gain_db = boost_db });
    var high = try Effect.biquad(rate, .{ .kind = .high_shelf, .cutoff_hz = 1000, .gain_db = boost_db });

    // Low shelf boosts DC, leaves Nyquist alone.
    var dc: [8192]f32 = @splat(0.1);
    low.process(&dc, 1);
    try testing.expectApproxEqAbs(0.1 * expected, dc[dc.len - 1], 1e-3);
    // High shelf boosts Nyquist, leaves DC alone.
    var dc2: [8192]f32 = @splat(0.1);
    high.process(&dc2, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.1), dc2[dc2.len - 1], 1e-4);

    var nyq: [8192]f32 = undefined;
    for (&nyq, 0..) |*v, i| v.* = if (i % 2 == 0) 0.1 else -0.1;
    high.reset();
    high.process(&nyq, 1);
    var peak: f32 = 0;
    for (nyq[4096..]) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(0.1 * expected, peak, 2e-3);
}

test "effects: the impulse response is stable and decays to exact zero" {
    const rate = 48000;
    var effect = try Effect.biquad(rate, .{ .kind = .low_pass, .cutoff_hz = 500, .q = 4 });
    var buf: [8192]f32 = @splat(0);
    buf[0] = 1;
    effect.process(&buf, 1);

    var energy: f64 = 0;
    for (buf) |v| {
        try testing.expect(std.math.isFinite(v));
        try testing.expect(@abs(v) <= 2.0);
        energy += @as(f64, @abs(v));
    }
    try testing.expect(energy > 0.1);
    // The tail falls below the flush threshold and the *state* lands on exact
    // zero, so the next silent block does no denormal arithmetic at all.
    try testing.expect(@abs(buf[buf.len - 1]) < flush_threshold);
    try testing.expectEqual(@as(f32, 0), effect.kind.biquad.state[0].s1);
    try testing.expectEqual(@as(f32, 0), effect.kind.biquad.state[0].s2);
    // A second silent block is therefore exactly silent, sample for sample.
    var silence: [256]f32 = @splat(0);
    effect.process(&silence, 1);
    for (silence) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: channels are filtered independently and reset clears history" {
    const rate = 48000;
    var effect = try Effect.biquad(rate, .{ .kind = .low_pass, .cutoff_hz = 800 });
    // Left is DC, right is silence: no crosstalk in either direction.
    var buf: [2048]f32 = undefined;
    for (0..1024) |i| {
        buf[i * 2] = 0.4;
        buf[i * 2 + 1] = 0;
    }
    effect.process(&buf, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.4), buf[buf.len - 2], 1e-4);
    for (0..1024) |i| try testing.expectEqual(@as(f32, 0), buf[i * 2 + 1]);

    // State is non-zero after the DC block, and reset clears both channels.
    try testing.expect(effect.kind.biquad.state[0].s1 != 0);
    effect.reset();
    try testing.expectEqual(@as(f32, 0), effect.kind.biquad.state[0].s1);
    try testing.expectEqual(@as(f32, 0), effect.kind.biquad.state[1].s2);
}

test "effects: a non-finite sample is silenced, not latched into the state" {
    const rate = 48000;
    var effect = try Effect.biquad(rate, .{ .kind = .low_pass, .cutoff_hz = 1000 });
    var poison = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 0.5 };
    effect.process(&poison, 1);
    for (poison) |v| try testing.expect(std.math.isFinite(v));

    // The filter still works afterwards: DC passes through at unity.
    var dc: [4096]f32 = @splat(0.25);
    effect.process(&dc, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dc[dc.len - 1], 1e-4);
}

test "effects: compressor parameters are validated" {
    const rate = 48000;
    try testing.expectError(error.InvalidValue, Compressor.init(0, .{}));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .ratio = 0.5 }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .ratio = std.math.nan(f32) }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .knee_db = -1 }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .attack_ms = 0 }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .release_ms = -5 }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .threshold_db = std.math.inf(f32) }));
    try testing.expectError(error.InvalidValue, Compressor.init(rate, .{ .makeup_db = 100 }));
    _ = try Effect.compressor(rate, .{});
}

test "effects: the compressor static curve follows the soft-knee formula" {
    const comp = try Compressor.init(48000, .{ .threshold_db = -20, .ratio = 4, .knee_db = 8 });
    // Well below the knee: no reduction.
    try testing.expectEqual(@as(f32, 0), comp.reductionFor(-40));
    try testing.expectEqual(@as(f32, 0), comp.reductionFor(-24.5));
    // Center of the knee: the quadratic segment gives slope*(k/2)^2/(2k).
    const center = comp.reductionFor(-20);
    try testing.expectApproxEqAbs(@as(f32, -0.75), center, 1e-5);
    // Well above the knee: the straight 1/ratio line.
    try testing.expectApproxEqAbs(@as(f32, -15), comp.reductionFor(0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -30), comp.reductionFor(20), 1e-5);
    // The curve is monotonic and continuous across both knee edges.
    var prev: f32 = 0;
    var level: f32 = -40;
    while (level < 10) : (level += 0.25) {
        const value = comp.reductionFor(level);
        try testing.expect(value <= prev + 1e-5);
        prev = value;
    }
    // A hard knee has no quadratic segment.
    const hard = try Compressor.init(48000, .{ .threshold_db = -20, .ratio = 4, .knee_db = 0 });
    try testing.expectEqual(@as(f32, 0), hard.reductionFor(-20));
    try testing.expectApproxEqAbs(@as(f32, -15), hard.reductionFor(0), 1e-5);
}

test "effects: ratio 1 is transparent and makeup is applied exactly" {
    const rate = 48000;
    var unity = try Effect.compressor(rate, .{ .ratio = 1, .threshold_db = -40, .makeup_db = 0 });
    var buf: [512]f32 = undefined;
    for (&buf, 0..) |*v, i| v.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    const original = buf;
    unity.process(&buf, 1);
    for (buf, original) |got, want| try testing.expectApproxEqAbs(want, got, 1e-5);

    // +6.02 dB is a factor of two.
    var boost = try Effect.compressor(rate, .{ .ratio = 1, .makeup_db = 6.0206 });
    var quiet: [64]f32 = @splat(0.1);
    boost.process(&quiet, 1);
    for (quiet) |v| try testing.expectApproxEqAbs(@as(f32, 0.2), v, 1e-4);
}

test "effects: the compressor reduces a loud block toward its static target" {
    const rate = 48000;
    var comp = try Effect.compressor(rate, .{
        .threshold_db = -20,
        .ratio = 4,
        .knee_db = 0,
        .attack_ms = 1,
        .release_ms = 10,
    });
    // 0 dBFS in, hard knee at -20 with ratio 4 -> -15 dB of reduction,
    // i.e. an output level of -15 dBFS (~0.1778).
    var loud: [4096]f32 = @splat(1.0);
    comp.process(&loud, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.17783), loud[loud.len - 1], 2e-3);
    // The attack is a ramp, not a jump: the first sample is barely touched.
    try testing.expect(loud[0] > 0.9);
    try testing.expect(loud[0] > loud[100]);

    // Release brings the gain back toward unity once the input drops.
    var quiet: [48000]f32 = @splat(0.001);
    comp.process(&quiet, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.001), quiet[quiet.len - 1], 1e-5);
    try testing.expectEqual(@as(f32, 0), comp.kind.compressor.envelope_db);

    comp.reset();
    try testing.expectEqual(@as(f32, 0), comp.kind.compressor.envelope_db);
}

test "effects: the compressor is stereo linked" {
    const rate = 48000;
    var comp = try Effect.compressor(rate, .{
        .threshold_db = -20,
        .ratio = 8,
        .knee_db = 0,
        .attack_ms = 0.1,
        .release_ms = 50,
    });
    // Loud left, quiet right: both must get the SAME gain, so the ratio between
    // the channels is preserved and the image does not move.
    var buf: [4096]f32 = undefined;
    for (0..2048) |i| {
        buf[i * 2] = 1.0;
        buf[i * 2 + 1] = 0.1;
    }
    comp.process(&buf, 2);
    const left = buf[buf.len - 2];
    const right = buf[buf.len - 1];
    try testing.expect(left < 0.5);
    try testing.expectApproxEqAbs(@as(f32, 10.0), left / right, 1e-3);
}

test "effects: a compressor recovers from non-finite input" {
    var comp = try Effect.compressor(48000, .{});
    var poison = [_]f32{ std.math.nan(f32), std.math.inf(f32), 0.2, 0.2 };
    comp.process(&poison, 1);
    for (poison) |v| try testing.expect(std.math.isFinite(v));
    try testing.expect(std.math.isFinite(comp.kind.compressor.envelope_db));
}

test "effects: bypass is bit-exact, chains run in order and reset" {
    var slots = [_]Effect{ Effect.bypass, Effect.bypass, Effect.bypass };
    const chain = Chain{ .effects = &slots };
    try testing.expect(!chain.active());

    var buf = [_]f32{ 0.123456789, -0.987654321, 0.5, -0.5, 1.5, -2.0 };
    const original = buf;
    chain.process(&buf, 2);
    try testing.expectEqualSlices(f32, &original, &buf);

    // Two different filters in series: order matters, and the chain is active.
    const rate = 48000;
    slots[0] = try Effect.biquad(rate, .{ .kind = .low_shelf, .cutoff_hz = 500, .gain_db = 12 });
    slots[1] = try Effect.compressor(rate, .{ .threshold_db = -30, .ratio = 4 });
    try testing.expect(chain.active());
    var forward: [512]f32 = undefined;
    for (&forward, 0..) |*v, i| v.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
    const source = forward;
    chain.process(&forward, 1);

    slots[0] = try Effect.compressor(rate, .{ .threshold_db = -30, .ratio = 4 });
    slots[1] = try Effect.biquad(rate, .{ .kind = .low_shelf, .cutoff_hz = 500, .gain_db = 12 });
    var reversed = source;
    chain.process(&reversed, 1);
    var differs = false;
    for (forward, reversed) |a, b| {
        try testing.expect(std.math.isFinite(a) and std.math.isFinite(b));
        if (a != b) differs = true;
    }
    try testing.expect(differs);

    chain.reset();
    try testing.expectEqual(@as(f32, 0), slots[0].kind.compressor.envelope_db);
    try testing.expectEqual(@as(f32, 0), slots[1].kind.biquad.state[0].s1);
}

test "effects: processing is deterministic for identical state" {
    const rate = 48000;
    var a = [_]Effect{
        try Effect.biquad(rate, .{ .kind = .peaking, .cutoff_hz = 900, .q = 1.5, .gain_db = 6 }),
        try Effect.compressor(rate, .{ .threshold_db = -18, .ratio = 3 }),
    };
    var b = a;
    var buf_a: [1024]f32 = undefined;
    var buf_b: [1024]f32 = undefined;
    for (&buf_a, 0..) |*v, i| {
        const value: f32 = 0.7 * @sin(@as(f32, @floatFromInt(i)) * 0.037);
        v.* = value;
        buf_b[i] = value;
    }
    // Process in unequal block sizes: the DSP is sequential, so the result must
    // not depend on how the host chops the stream.
    Chain.process(.{ .effects = &a }, &buf_a, 2);
    var offset: usize = 0;
    while (offset < buf_b.len) : (offset += 64) {
        Chain.process(.{ .effects = &b }, buf_b[offset..][0..64], 2);
    }
    try testing.expectEqualSlices(f32, &buf_a, &buf_b);
}

test "effects: delay parameters and buffer size are validated" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = DelayParams{ .delay_ms = 1 };
    // 1 ms at 48 kHz is exactly 48 frames.
    try testing.expectEqual(@as(usize, 48), try Delay.requiredSamples(rate, 1, params));
    try testing.expectEqual(@as(usize, 96), try Delay.requiredSamples(rate, 2, params));
    // A sub-sample delay still needs one frame.
    try testing.expectEqual(@as(usize, 1), try Delay.requiredSamples(rate, 1, .{ .delay_ms = 0.001 }));

    try testing.expectError(error.InvalidValue, Delay.requiredSamples(0, 1, params));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 0, params));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 3, params));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 1, .{ .delay_ms = 0 }));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 1, .{ .delay_ms = -5 }));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 1, .{ .delay_ms = max_delay_ms + 1 }));
    try testing.expectError(error.InvalidValue, Delay.requiredSamples(rate, 1, .{ .delay_ms = std.math.nan(f32) }));

    const buf = try gpa.alloc(f32, try Delay.requiredSamples(rate, 1, params));
    defer gpa.free(buf);
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, .{ .feedback = 1 }, buf));
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, .{ .feedback = -0.1 }, buf));
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, .{ .mix = 1.5 }, buf));
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, .{ .damping_hz = 24000 }, buf));
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, .{ .damping_hz = -1 }, buf));
    // One sample short is rejected rather than silently truncating the delay.
    try testing.expectError(error.InvalidValue, Delay.init(rate, 1, params, buf[0 .. buf.len - 1]));
    _ = try Delay.init(rate, 1, params, buf);
}

test "effects: a dry delay is bit-exact and a wet delay echoes on schedule" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = DelayParams{ .delay_ms = 1, .feedback = 0.5, .mix = 1 };
    const buf = try gpa.alloc(f32, try Delay.requiredSamples(rate, 1, params));
    defer gpa.free(buf);
    var echo = try Delay.init(rate, 1, params, buf);

    // Dry only: every sample passes through untouched. This needs its own
    // buffer -- copying the struct would alias the same delay line, which is
    // exactly what the mixer's overlap check refuses.
    const dry_buf = try gpa.alloc(f32, buf.len);
    defer gpa.free(dry_buf);
    var dry = try Delay.init(rate, 1, .{ .delay_ms = 1, .feedback = 0.5, .mix = 0 }, dry_buf);
    var signal = [_]f32{ 0.1, -0.4, 0.9, -0.2, 0.33, 0.7, -0.85, 0.05 };
    const original = signal;
    dry.process(&signal, 1);
    try testing.expectEqualSlices(f32, &original, &signal);

    // Wet only with feedback 0.5: an impulse returns at 48, 96, 144, 192 with
    // halving amplitude, and nowhere else. Powers of two make this exact.
    const total = 48 * 4 + 1;
    const impulse = try gpa.alloc(f32, total);
    defer gpa.free(impulse);
    @memset(impulse, 0);
    impulse[0] = 1;
    echo.process(impulse, 1);
    try testing.expectEqual(@as(f32, 1), impulse[48]);
    try testing.expectEqual(@as(f32, 0.5), impulse[96]);
    try testing.expectEqual(@as(f32, 0.25), impulse[144]);
    try testing.expectEqual(@as(f32, 0.125), impulse[192]);
    for (impulse, 0..) |v, i| {
        if (i == 48 or i == 96 or i == 144 or i == 192) continue;
        try testing.expectEqual(@as(f32, 0), v);
    }
}

test "effects: delay damping darkens the repeats and the tail reaches zero" {
    const gpa = testing.allocator;
    const rate = 48000;
    const plain_params = DelayParams{ .delay_ms = 1, .feedback = 0.5, .mix = 1 };
    const plain_buf = try gpa.alloc(f32, try Delay.requiredSamples(rate, 1, plain_params));
    defer gpa.free(plain_buf);
    var plain = try Delay.init(rate, 1, plain_params, plain_buf);

    const damped_params = DelayParams{ .delay_ms = 1, .feedback = 0.5, .mix = 1, .damping_hz = 500 };
    const damped_buf = try gpa.alloc(f32, try Delay.requiredSamples(rate, 1, damped_params));
    defer gpa.free(damped_buf);
    var damped = try Delay.init(rate, 1, damped_params, damped_buf);

    const total = 4096;
    const a = try gpa.alloc(f32, total);
    defer gpa.free(a);
    const b = try gpa.alloc(f32, total);
    defer gpa.free(b);
    @memset(a, 0);
    @memset(b, 0);
    a[0] = 1;
    b[0] = 1;
    plain.process(a, 1);
    damped.process(b, 1);

    // The first repeat is the raw impulse in both; the second is heavily
    // attenuated by the feedback low pass in the damped one.
    try testing.expectEqual(@as(f32, 1), a[48]);
    try testing.expectEqual(@as(f32, 1), b[48]);
    try testing.expectEqual(@as(f32, 0.5), a[96]);
    try testing.expect(b[96] < 0.1);
    try testing.expect(b[96] > 0);

    // Feedback below 1 plus the write flush means the tail lands on exact zero
    // instead of crawling through denormals forever.
    try testing.expectEqual(@as(f32, 0), a[total - 1]);
    try testing.expectEqual(@as(f32, 0), b[total - 1]);
    // 0.5^k drops below the 1e-15 flush threshold at k = 50, i.e. frame 2400;
    // the next read is already exact zero, so everything after is silence.
    var silent = true;
    for (a[2560..]) |v| {
        if (v != 0) silent = false;
    }
    try testing.expect(silent);
}

test "effects: delay channels are independent, reset silences, NaN recovers" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = DelayParams{ .delay_ms = 1, .feedback = 0.5, .mix = 1 };
    const buf = try gpa.alloc(f32, try Delay.requiredSamples(rate, 2, params));
    defer gpa.free(buf);
    var echo = try Delay.init(rate, 2, params, buf);

    const frames = 200;
    const signal = try gpa.alloc(f32, frames * 2);
    defer gpa.free(signal);
    @memset(signal, 0);
    signal[0] = 1; // left impulse only
    echo.process(signal, 2);
    for (0..frames) |i| try testing.expectEqual(@as(f32, 0), signal[i * 2 + 1]);
    try testing.expectEqual(@as(f32, 1), signal[48 * 2]);

    // Reset clears the line, so the same impulse produces the same echo again.
    echo.reset();
    @memset(signal, 0);
    signal[0] = 1;
    echo.process(signal, 2);
    try testing.expectEqual(@as(f32, 1), signal[48 * 2]);
    try testing.expectEqual(@as(f32, 0.5), signal[96 * 2]);

    // A non-finite sample must not circulate in the feedback loop forever.
    echo.reset();
    @memset(signal, 0);
    signal[0] = std.math.nan(f32);
    signal[2] = std.math.inf(f32);
    signal[4] = 1;
    echo.process(signal, 2);
    for (signal) |v| try testing.expect(std.math.isFinite(v));
    try testing.expectEqual(@as(f32, 1), signal[48 * 2 + 4]);
}

test "effects: reverb parameters and buffer size are validated" {
    const gpa = testing.allocator;
    const rate = 48000;
    const mono = try Reverb.requiredSamples(rate, 1);
    const stereo = try Reverb.requiredSamples(rate, 2);
    try testing.expect(mono > 10_000);
    // The right channel is longer by the stereo spread on every line.
    try testing.expect(stereo > mono * 2);
    try testing.expect(try Reverb.requiredSamples(96000, 1) > mono);
    try testing.expectError(error.InvalidValue, Reverb.requiredSamples(0, 1));
    try testing.expectError(error.InvalidValue, Reverb.requiredSamples(rate, 0));
    try testing.expectError(error.InvalidValue, Reverb.requiredSamples(rate, 3));

    const buf = try gpa.alloc(f32, mono);
    defer gpa.free(buf);
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 1, .{ .room_size = 1.1 }, buf));
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 1, .{ .damping = -0.1 }, buf));
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 1, .{ .wet = std.math.nan(f32) }, buf));
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 1, .{ .dry = 2 }, buf));
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 1, .{}, buf[0 .. buf.len - 1]));
    // A stereo instance cannot be carved out of a mono-sized buffer.
    try testing.expectError(error.InvalidValue, Reverb.init(rate, 2, .{}, buf));
    _ = try Reverb.init(rate, 1, .{}, buf);
}

test "effects: reverb dry/wry extremes are exact" {
    const gpa = testing.allocator;
    const rate = 48000;
    const buf = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 1));
    defer gpa.free(buf);

    var bypassed = try Reverb.init(rate, 1, .{ .wet = 0, .dry = 1 }, buf);
    var signal = [_]f32{ 0.1, -0.4, 0.9, -0.2, 0.33, 0.7, -0.85, 0.05 };
    const original = signal;
    bypassed.process(&signal, 1);
    try testing.expectEqualSlices(f32, &original, &signal);

    // A second instance needs its own memory, not a copy of the first.
    const other = try gpa.alloc(f32, buf.len);
    defer gpa.free(other);
    var muted = try Reverb.init(rate, 1, .{ .wet = 0, .dry = 0 }, other);
    muted.process(&signal, 1);
    for (signal) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: reverb produces a bounded, decaying tail after the direct sound" {
    const gpa = testing.allocator;
    const rate = 48000;
    const memory = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 1));
    defer gpa.free(memory);
    var reverb = try Reverb.init(rate, 1, .{ .wet = 1, .dry = 0, .room_size = 0.8 }, memory);

    const frames = 16384;
    const signal = try gpa.alloc(f32, frames);
    defer gpa.free(signal);
    @memset(signal, 0);
    signal[0] = 1;
    reverb.process(signal, 1);

    // Nothing can come back before the shortest comb delay (~1215 at 48 kHz).
    for (signal[0..1000]) |v| try testing.expectEqual(@as(f32, 0), v);

    // Equal-length windows, so this compares decay rather than window size.
    const window = 2000;
    var early: f64 = 0;
    var late: f64 = 0;
    for (signal[2000..][0..window]) |v| {
        try testing.expect(std.math.isFinite(v));
        try testing.expect(@abs(v) < 2);
        early += @as(f64, @abs(v));
    }
    for (signal[14000..][0..window]) |v| {
        try testing.expect(std.math.isFinite(v));
        late += @as(f64, @abs(v));
    }
    try testing.expect(early > 0.01);
    try testing.expect(late < early);

    // Reset silences it completely.
    reverb.reset();
    @memset(signal, 0);
    reverb.process(signal, 1);
    for (signal) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: reverb stays stable at maximum room size" {
    const gpa = testing.allocator;
    const rate = 48000;
    const memory = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 1));
    defer gpa.free(memory);
    // room_size 1 is the highest feedback the mapping allows (0.98).
    var reverb = try Reverb.init(rate, 1, .{ .wet = 1, .dry = 0, .room_size = 1, .damping = 0 }, memory);

    const frames = 48000;
    const signal = try gpa.alloc(f32, frames);
    defer gpa.free(signal);
    @memset(signal, 0);
    signal[0] = 1;
    reverb.process(signal, 1);
    var peak: f32 = 0;
    for (signal) |v| {
        try testing.expect(std.math.isFinite(v));
        peak = @max(peak, @abs(v));
    }
    // Feedback < 1 keeps the network bounded even with no damping at all.
    try testing.expect(peak < 10);
    try testing.expect(peak > 0.001);
}

test "effects: reverb channels decorrelate and survive non-finite input" {
    const gpa = testing.allocator;
    const rate = 48000;
    const memory = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 2));
    defer gpa.free(memory);
    var reverb = try Reverb.init(rate, 2, .{ .wet = 1, .dry = 0 }, memory);

    const frames = 8192;
    const signal = try gpa.alloc(f32, frames * 2);
    defer gpa.free(signal);
    @memset(signal, 0);
    // Identical impulses: the stereo spread must still make the tails differ.
    signal[0] = 1;
    signal[1] = 1;
    reverb.process(signal, 2);
    var differences: usize = 0;
    for (0..frames) |i| {
        const l = signal[i * 2];
        const r = signal[i * 2 + 1];
        try testing.expect(std.math.isFinite(l) and std.math.isFinite(r));
        if (l != r) differences += 1;
    }
    try testing.expect(differences > 100);

    reverb.reset();
    @memset(signal, 0);
    signal[0] = std.math.nan(f32);
    signal[1] = std.math.inf(f32);
    signal[2] = 1;
    signal[3] = 1;
    reverb.process(signal, 2);
    for (signal) |v| try testing.expect(std.math.isFinite(v));
    // The impulse after the poison still excites the network.
    var energy: f64 = 0;
    for (signal[3000..]) |v| energy += @as(f64, @abs(v));
    try testing.expect(energy > 0);
}

test "effects: delay-based processing is independent of the block size" {
    const gpa = testing.allocator;
    const rate = 48000;
    const frames = 4096;

    const delay_mem_a = try gpa.alloc(f32, try Delay.requiredSamples(rate, 1, .{ .delay_ms = 3 }));
    defer gpa.free(delay_mem_a);
    const delay_mem_b = try gpa.alloc(f32, delay_mem_a.len);
    defer gpa.free(delay_mem_b);
    var delay_a = try Delay.init(rate, 1, .{ .delay_ms = 3, .feedback = 0.6, .mix = 0.5 }, delay_mem_a);
    var delay_b = try Delay.init(rate, 1, .{ .delay_ms = 3, .feedback = 0.6, .mix = 0.5 }, delay_mem_b);

    const rev_mem_a = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 1));
    defer gpa.free(rev_mem_a);
    const rev_mem_b = try gpa.alloc(f32, rev_mem_a.len);
    defer gpa.free(rev_mem_b);
    var rev_a = try Reverb.init(rate, 1, .{}, rev_mem_a);
    var rev_b = try Reverb.init(rate, 1, .{}, rev_mem_b);

    var chain_a = [_]Effect{ Effect.delay(&delay_a), Effect.reverb(&rev_a) };
    var chain_b = [_]Effect{ Effect.delay(&delay_b), Effect.reverb(&rev_b) };

    const a = try gpa.alloc(f32, frames);
    defer gpa.free(a);
    const b = try gpa.alloc(f32, frames);
    defer gpa.free(b);
    for (a, 0..) |*v, i| {
        const value: f32 = if (i == 0) 1 else 0.2 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
        v.* = value;
        b[i] = value;
    }
    Chain.process(.{ .effects = &chain_a }, a, 1);
    var offset: usize = 0;
    while (offset < frames) : (offset += 97) {
        const n = @min(97, frames - offset);
        Chain.process(.{ .effects = &chain_b }, b[offset..][0..n], 1);
    }
    try testing.expectEqualSlices(f32, a, b);
}

test "effects: the diffusion sections reject DC and stay bounded" {
    const gpa = testing.allocator;
    const rate = 48000;
    const length = 341;
    const memory = try gpa.alloc(f32, length);
    defer gpa.free(memory);

    // DC in, nothing out: this is what stops the comb network's 1/(1-feedback)
    // low-frequency gain from turning an impulse into a slow rumble.
    @memset(memory, 0);
    var dc = Line{ .data = memory };
    var last: f32 = 0;
    for (0..8000) |i| {
        last = allpassStep(&dc, 1, allpass_feedback);
        try testing.expect(std.math.isFinite(last));
        if (i > 7000) try testing.expect(@abs(last) < 1e-4);
    }

    // Across the audio band the response is the documented shelving shape:
    // bounded between 1 and 2/(1+g) = 1.333, never a resonant peak.
    const freqs = [_]f64{ 500, 1500, 4000, 6000, 12000 };
    for (freqs) |freq| {
        @memset(memory, 0);
        var line = Line{ .data = memory };
        const frames = 24000;
        const buf = try gpa.alloc(f32, frames);
        defer gpa.free(buf);
        const w = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(rate));
        for (buf, 0..) |*v, i| v.* = @floatCast(@sin(w * @as(f64, @floatFromInt(i))));
        for (buf) |*v| v.* = allpassStep(&line, v.*, allpass_feedback);

        const period: usize = @intFromFloat(@round(@as(f64, @floatFromInt(rate)) / freq));
        const settle = frames / 2;
        const usable = ((frames - settle) / period) * period;
        var sum_sq: f64 = 0;
        for (buf[settle..][0..usable]) |v| sum_sq += @as(f64, v) * @as(f64, v);
        const gain = @sqrt(sum_sq / @as(f64, @floatFromInt(usable))) * @sqrt(2.0);
        try testing.expect(gain > 0.5 and gain < 1.4);
    }
}

test "effects: borrowed variants do not inflate an insert slot" {
    // The delay/reverb variants are pointers on purpose: inlining their line
    // state (752 bytes for a reverb) would grow every slot on every bus,
    // including biquad-only chains. Measured: 48 bytes on x86-64 -- the pointer
    // variants raise the union's alignment to 8, costing 4 bytes of padding over
    // the inline-only layout. That is the whole price of the indirection.
    try testing.expect(@sizeOf(Effect) <= @sizeOf(Biquad) + 16);
    try testing.expect(@sizeOf(Effect) * 8 < @sizeOf(Reverb));
}

test "effects: borrowed instances expose their memory and identity" {
    const gpa = testing.allocator;
    const rate = 48000;
    const memory = try gpa.alloc(f32, try Reverb.requiredSamples(rate, 2));
    defer gpa.free(memory);
    var reverb = try Reverb.init(rate, 2, .{}, memory);
    const effect = Effect.reverb(&reverb);

    try testing.expectEqual(@as(u16, 2), effect.channelCount());
    try testing.expectEqual(@as(usize, @intFromPtr(&reverb)), effect.stateAddress().?);
    try testing.expectEqual(memory.len, effect.borrowedMemory().?.len);
    try testing.expectEqual(@intFromPtr(memory.ptr), @intFromPtr(effect.borrowedMemory().?.ptr));

    // Inline effects adapt to any layout and borrow nothing.
    const filter = try Effect.biquad(rate, .{});
    try testing.expectEqual(@as(u16, 0), filter.channelCount());
    try testing.expectEqual(@as(?[]const f32, null), filter.borrowedMemory());
    try testing.expectEqual(@as(?usize, null), filter.stateAddress());
    try testing.expectEqual(@as(u16, 0), Effect.bypass.channelCount());

    // Effect.reset reaches through the pointer.
    var slot = effect;
    slot.process(memory[0..2], 2);
    slot.reset();
    for (reverb.memory) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: the sliding maximum matches a naive scan" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const count = 1500;
    const values = try gpa.alloc(f32, count);
    defer gpa.free(values);

    // Random, monotone up, monotone down and constant: the last three are the
    // shapes that stress the two-stack transfer in opposite directions.
    const patterns = [_]usize{ 0, 1, 2, 3 };
    const windows = [_]usize{ 1, 2, 3, 7, 64, 241 };
    for (windows) |window| {
        const storage = try gpa.alloc(f32, window * 2);
        defer gpa.free(storage);
        for (patterns) |pattern| {
            for (values, 0..) |*v, i| {
                const t: f32 = @floatFromInt(i);
                v.* = switch (pattern) {
                    0 => random.float(f32),
                    1 => t,
                    2 => @floatFromInt(count - i),
                    else => 0.5,
                };
            }
            var sw = SlidingMax.init(storage, window);
            for (values, 0..) |v, i| {
                if (sw.len() == window) sw.pop();
                sw.push(v);
                const start = if (i + 1 >= window) i + 1 - window else 0;
                var expect: f32 = 0;
                for (values[start .. i + 1]) |u| expect = @max(expect, u);
                try testing.expectEqual(expect, sw.max());
                try testing.expectEqual(i + 1 - start, sw.len());
                // The two stacks share one region and must never overlap.
                try testing.expect(sw.len() <= window);
            }
            sw.clear();
            try testing.expectEqual(@as(usize, 0), sw.len());
            try testing.expectEqual(@as(f32, 0), sw.max());
        }
    }
}

test "effects: limiter parameters and buffer size are validated" {
    const gpa = testing.allocator;
    const rate = 48000;
    // 5 ms at 48 kHz is 240 frames: 240 stereo frames plus a 241-entry detector.
    const params = LimiterParams{};
    try testing.expectEqual(@as(usize, 240), try lookaheadFrames(rate, params.lookahead_ms));
    try testing.expectEqual(@as(usize, 240 * 2 + 241 * 2), try Limiter.requiredSamples(rate, 2, params));
    try testing.expectEqual(@as(usize, 240 + 241 * 2), try Limiter.requiredSamples(rate, 1, params));
    // Zero lookahead still needs the one-entry detector.
    try testing.expectEqual(@as(usize, 2), try Limiter.requiredSamples(rate, 1, .{ .lookahead_ms = 0 }));
    try testing.expectEqual(@as(usize, 1), try lookaheadFrames(rate, 0.001));

    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(0, 1, params));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 0, params));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 3, params));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .ceiling_db = 0.5 }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .ceiling_db = -121 }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .ceiling_db = std.math.nan(f32) }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .lookahead_ms = -1 }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .lookahead_ms = max_lookahead_ms + 1 }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .release_ms = -1 }));
    try testing.expectError(error.InvalidValue, Limiter.requiredSamples(rate, 1, .{ .release_ms = 10_001 }));

    const buf = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, params));
    defer gpa.free(buf);
    try testing.expectError(error.InvalidValue, Limiter.init(rate, 1, params, buf[0 .. buf.len - 1]));
    const limited = try Limiter.init(rate, 1, params, buf);
    try testing.expectEqual(@as(usize, 240), limited.latencyFrames());
    try testing.expectEqual(@as(f32, 0), limited.gainReductionDb());
    // The ceiling is the linear form of ceiling_db.
    try testing.expectApproxEqAbs(@as(f32, 0.8912509), limited.ceiling, 1e-6);
}

test "effects: the limiter never lets a sample past its ceiling" {
    const gpa = testing.allocator;
    const rate = 48000;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();

    // Every combination that could break the guarantee: with and without
    // lookahead, fast and slow release, mono and stereo, several ceilings.
    const lookaheads = [_]f32{ 0, 0.1, 5 };
    const releases = [_]f32{ 0, 1, 100 };
    const ceilings = [_]f32{ 0, -1, -12 };
    for (lookaheads) |lookahead| {
        for (releases) |release| {
            for (ceilings) |ceiling_db| {
                const params = LimiterParams{ .ceiling_db = ceiling_db, .lookahead_ms = lookahead, .release_ms = release };
                const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 2, params));
                defer gpa.free(memory);
                var limiter = try Limiter.init(rate, 2, params, memory);
                const ceiling = limiter.ceiling;

                const frames = 4096;
                const signal = try gpa.alloc(f32, frames * 2);
                defer gpa.free(signal);
                for (signal, 0..) |*v, i| {
                    // Loud random audio, well over full scale, with isolated
                    // full-scale spikes and silences mixed in.
                    var value = (random.float(f32) * 2.0 - 1.0) * 4.0;
                    if (i % 257 == 0) value = 8.0;
                    if (i % 1024 < 64) value = 0;
                    v.* = value;
                }
                limiter.process(signal, 2);
                for (signal) |v| {
                    try testing.expect(std.math.isFinite(v));
                    // Float rounding in ceiling/peak and the multiply can land
                    // an ulp above; anything beyond that is a real overshoot.
                    try testing.expect(@abs(v) <= ceiling * (1.0 + 1e-6));
                }
            }
        }
    }
}

test "effects: the limiter clamps a recovering envelope, not just a falling one" {
    const gpa = testing.allocator;
    const rate = 48000;
    // A release-only envelope climbs back towards unity and would sail past the
    // target while the signal is still loud. This is the case the final min()
    // exists for: quiet enough to raise the target, loud enough to still need
    // reduction, for long enough that the recovery crosses it.
    const params = LimiterParams{ .ceiling_db = -1, .lookahead_ms = 1, .release_ms = 20 };
    const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, params));
    defer gpa.free(memory);
    var limiter = try Limiter.init(rate, 1, params, memory);
    const ceiling = limiter.ceiling;

    const frames = 12000;
    const signal = try gpa.alloc(f32, frames);
    defer gpa.free(signal);
    for (signal, 0..) |*v, i| v.* = if (i < 1000) 1.0 else 0.95;
    limiter.process(signal, 1);

    var reached_ceiling = false;
    for (signal[2000..]) |v| {
        try testing.expect(@abs(v) <= ceiling * (1.0 + 1e-6));
        if (@abs(v) > ceiling * 0.999) reached_ceiling = true;
    }
    // It really is limiting there, not just attenuating everything.
    try testing.expect(reached_ceiling);
}

test "effects: limiter latency is exact and quiet audio is untouched" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = LimiterParams{ .lookahead_ms = 1, .release_ms = 50 };
    const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, params));
    defer gpa.free(memory);
    var limiter = try Limiter.init(rate, 1, params, memory);
    const latency = limiter.latencyFrames();
    try testing.expectEqual(@as(usize, 48), latency);

    // Everything below the ceiling passes at unity, delayed by exactly latency.
    const frames = 512;
    const signal = try gpa.alloc(f32, frames);
    defer gpa.free(signal);
    const original = try gpa.alloc(f32, frames);
    defer gpa.free(original);
    for (signal, 0..) |*v, i| {
        const value: f32 = 0.25 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        v.* = value;
        original[i] = value;
    }
    limiter.process(signal, 1);
    for (signal[0..latency]) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expectEqualSlices(f32, original[0 .. frames - latency], signal[latency..]);
    try testing.expectEqual(@as(f32, 0), limiter.gainReductionDb());

    // A single over-scale impulse emerges at exactly `latency`, at the ceiling.
    limiter.reset();
    @memset(signal, 0);
    signal[0] = 4.0;
    limiter.process(signal, 1);
    try testing.expectEqual(@as(f32, 0), signal[0]);
    try testing.expectApproxEqAbs(limiter.ceiling, signal[latency], 1e-6);
    for (signal[1..latency]) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expect(limiter.gainReductionDb() < 0);
}

test "effects: limiter release recovers, and zero release recovers immediately" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = LimiterParams{ .lookahead_ms = 0, .release_ms = 50 };
    const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, params));
    defer gpa.free(memory);
    var slow = try Limiter.init(rate, 1, params, memory);

    const fast_mem = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, .{ .lookahead_ms = 0, .release_ms = 0 }));
    defer gpa.free(fast_mem);
    var fast = try Limiter.init(rate, 1, .{ .lookahead_ms = 0, .release_ms = 0 }, fast_mem);

    // One second is 20 time constants of a 50 ms release, so the envelope has
    // provably settled by the end; 6000 frames would only be 2.5 of them.
    const frames = 48000;
    const a = try gpa.alloc(f32, frames);
    defer gpa.free(a);
    const b = try gpa.alloc(f32, frames);
    defer gpa.free(b);
    for (a, 0..) |*v, i| {
        // A loud burst, then a quiet tail that needs no reduction at all.
        const value: f32 = if (i < 100) 2.0 else 0.1;
        v.* = value;
        b[i] = value;
    }
    slow.process(a, 1);
    fast.process(b, 1);

    // Zero lookahead means zero latency: the burst is limited in place.
    try testing.expectApproxEqAbs(slow.ceiling, a[0], 1e-6);
    // Instant release: the very next sample is already back at unity.
    try testing.expectEqual(@as(f32, 0.1), b[100]);
    // Slow release: still reduced right after the burst, and back to *exactly*
    // unity by the end. Storing the gain instead of the distance to unity stalls
    // ~7e-5 short of 1.0 in f32, which would leave the limiter permanently
    // attenuating by a hair; this pins the fix.
    try testing.expect(a[100] < 0.1);
    try testing.expectEqual(@as(f32, 0.1), a[frames - 1]);
    try testing.expectEqual(@as(f32, 1), slow.envelope);
    // The residual distance is ~1e-9, far below half an ulp of 1.0, so the gain
    // is already exactly unity even though the state has not flushed to zero.
    try testing.expect(slow.distance < 1e-8);
    try testing.expectEqual(@as(f32, 0), slow.gainReductionDb());
}

test "effects: limiter links channels so the stereo image is preserved" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = LimiterParams{ .lookahead_ms = 0, .release_ms = 0 };
    const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 2, params));
    defer gpa.free(memory);
    var limiter = try Limiter.init(rate, 2, params, memory);

    // Left is hot, right is quiet. Both must be scaled by the same gain, so the
    // ratio between them survives.
    var signal = [_]f32{ 4.0, 1.0, -4.0, -1.0, 2.0, 0.5 };
    limiter.process(&signal, 2);
    for (0..3) |i| {
        const l = signal[i * 2];
        const r = signal[i * 2 + 1];
        try testing.expectApproxEqAbs(limiter.ceiling, @abs(l), 1e-6);
        try testing.expectApproxEqAbs(@abs(l) / 4.0, @abs(r), 1e-6);
        try testing.expect(std.math.sign(l) == std.math.sign(r));
    }
}

test "effects: limiter reset, non-finite input and block-size independence" {
    const gpa = testing.allocator;
    const rate = 48000;
    const params = LimiterParams{ .lookahead_ms = 2, .release_ms = 30 };
    const mem_a = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 2, params));
    defer gpa.free(mem_a);
    const mem_b = try gpa.alloc(f32, mem_a.len);
    defer gpa.free(mem_b);
    var a = try Limiter.init(rate, 2, params, mem_a);
    var b = try Limiter.init(rate, 2, params, mem_b);

    const frames = 3000;
    const buf_a = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf_a);
    const buf_b = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf_b);
    for (buf_a, 0..) |*v, i| {
        const value: f32 = if (i == 0) std.math.nan(f32) else if (i == 1) std.math.inf(f32) else 1.5 * @sin(@as(f32, @floatFromInt(i)) * 0.07);
        v.* = value;
        buf_b[i] = value;
    }
    a.process(buf_a, 2);
    var offset: usize = 0;
    while (offset < buf_b.len) : (offset += 134) {
        const n = @min(134, buf_b.len - offset);
        b.process(buf_b[offset..][0..n], 2);
    }
    try testing.expectEqualSlices(f32, buf_a, buf_b);
    for (buf_a) |v| try testing.expect(std.math.isFinite(v));

    // An empty block is a no-op, including for the meter.
    const before_env = a.envelope;
    const before_distance = a.distance;
    a.process(buf_a[0..0], 2);
    try testing.expectEqual(before_env, a.envelope);
    try testing.expectEqual(before_distance, a.distance);

    // Reset restores unity gain and clears both the lines and the detector.
    a.reset();
    try testing.expectEqual(@as(f32, 1), a.envelope);
    try testing.expectEqual(@as(usize, 0), a.detector.len());
    for (a.memory) |v| try testing.expectEqual(@as(f32, 0), v);
    @memset(buf_a, 0);
    a.process(buf_a, 2);
    for (buf_a) |v| try testing.expectEqual(@as(f32, 0), v);

    // The poisoned samples were treated as silence, so the impulse that follows
    // still comes through at the right time.
    a.reset();
    @memset(buf_a, 0);
    buf_a[0] = std.math.nan(f32);
    buf_a[2] = std.math.inf(f32);
    buf_a[4] = 0.5;
    a.process(buf_a, 2);
    for (buf_a) |v| try testing.expect(std.math.isFinite(v));
    try testing.expectEqual(@as(f32, 0.5), buf_a[a.latencyFrames() * 2 + 4]);
}

test "effects: a limiter insert exposes its borrowed memory" {
    const gpa = testing.allocator;
    const rate = 48000;
    const memory = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 2, .{}));
    defer gpa.free(memory);
    var limiter = try Limiter.init(rate, 2, .{}, memory);
    const effect = Effect.limiter(&limiter);
    try testing.expectEqual(@as(u16, 2), effect.channelCount());
    try testing.expectEqual(@as(usize, @intFromPtr(&limiter)), effect.stateAddress().?);
    try testing.expectEqual(memory.len, effect.borrowedMemory().?.len);

    var slot = effect;
    var signal = [_]f32{ 2.0, 2.0, 0.1, 0.1 };
    slot.process(&signal, 2);
    try testing.expect(limiter.gainReductionDb() < 0);
    slot.reset();
    try testing.expectEqual(@as(f32, 0), limiter.gainReductionDb());
}

/// Amplitude of one frequency in a signal, by direct correlation. The caller
/// picks a whole number of cycles so the estimate is not window-biased.
fn magnitudeAt(signal: []const f32, rate: u32, freq: f64) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    const w = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(rate));
    for (signal, 0..) |v, i| {
        const t = w * @as(f64, @floatFromInt(i));
        re += @as(f64, v) * @cos(t);
        im += @as(f64, v) * @sin(t);
    }
    const n: f64 = @floatFromInt(signal.len);
    return 2.0 * @sqrt(re * re + im * im) / n;
}

test "effects: the mirrored history window is oldest-first and stays in bounds" {
    const n = 12;
    var hist = History(n){};
    var reference: [n]f32 = @splat(0);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const value: f32 = @floatFromInt(i);
        hist.push(value);
        std.mem.copyBackwards(f32, reference[1..], reference[0 .. n - 1]);
        reference[0] = value;
        // reference is newest-first; the window must be the reverse.
        const w = hist.window();
        for (0..n) |k| try testing.expectEqual(reference[n - 1 - k], w[k]);
        try testing.expect(hist.pos < n);
    }
    hist.clear();
    for (hist.window()) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: oversampling kernels have unity DC gain and an identity phase" {
    inline for (.{ 2, 4 }) |factor| {
        const up = comptime buildUpKernel(factor);
        for (up) |phase| {
            var sum: f64 = 0;
            for (phase) |h| sum += h;
            try testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-6);
        }
        // Phase 0 reproduces the input sample exactly: a delta at taps/2.
        for (up[0], 0..) |h, i| {
            if (i == oversample_taps / 2) {
                try testing.expectEqual(@as(f32, 1), h);
            } else {
                try testing.expectEqual(@as(f32, 0), h);
            }
        }
        const down = comptime buildDownKernel(factor);
        var sum: f64 = 0;
        for (down) |h| sum += h;
        try testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-6);
        // The decimator is symmetric, so it is linear-phase.
        for (0..down.len / 2) |i| {
            try testing.expectApproxEqAbs(down[i], down[down.len - 1 - i], 1e-6);
        }
    }
}

test "effects: saturator parameters are validated" {
    const rate = 48000;
    try testing.expectError(error.InvalidValue, Saturator.init(0, 1, .{}));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 0, .{}));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 3, .{}));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .drive = 0 }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .drive = 101 }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .drive = std.math.nan(f32) }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .mix = -0.1 }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .mix = 1.1 }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .oversample = 3 }));
    try testing.expectError(error.InvalidValue, Saturator.init(rate, 1, .{ .oversample = 8 }));

    const plain = try Saturator.init(rate, 1, .{ .oversample = 1 });
    try testing.expectEqual(@as(usize, 0), plain.latencyFrames());
    // Latency comes from the filter, not the factor.
    inline for (.{ 2, 4 }) |f| {
        const sat = try Saturator.init(rate, 1, .{ .oversample = f });
        try testing.expectEqual(oversample_latency, sat.latencyFrames());
    }
}

test "effects: a constant input survives the oversampled round trip" {
    const rate = 48000;
    // Both kernels are DC-normalized, so a constant must come out as exactly
    // shape(constant) once the pipeline has filled. This checks the whole
    // up/shape/down chain end to end, including the tap alignment.
    inline for (.{ 1, 2, 4 }) |f| {
        var sat = try Saturator.init(rate, 1, .{ .drive = 3, .oversample = f });
        const frames = 256;
        var buf: [frames]f32 = @splat(0.4);
        sat.process(&buf, 1);
        const want = std.math.tanh(@as(f32, 3.0) * 0.4);
        for (buf[sat.latencyFrames() + oversample_taps ..]) |v| {
            try testing.expectApproxEqAbs(want, v, 2e-3);
        }
    }
}

test "effects: a dry saturator is bit-exact at exactly its latency" {
    const rate = 48000;
    inline for (.{ 1, 2, 4 }) |f| {
        var sat = try Saturator.init(rate, 1, .{ .drive = 8, .mix = 0, .oversample = f });
        const frames = 200;
        var buf: [frames]f32 = undefined;
        var original: [frames]f32 = undefined;
        for (&buf, 0..) |*v, i| {
            const value: f32 = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.21);
            v.* = value;
            original[i] = value;
        }
        sat.process(&buf, 1);
        const latency = sat.latencyFrames();
        for (buf[0..latency]) |v| try testing.expectEqual(@as(f32, 0), v);
        try testing.expectEqualSlices(f32, original[0 .. frames - latency], buf[latency..]);
    }
}

test "effects: oversampling removes the aliasing of hard saturation" {
    const gpa = testing.allocator;
    const rate = 48000;
    // 5 kHz at 48 kHz: one second is a whole number of cycles for the tone and
    // for every alias measured below, so the correlation is unbiased.
    const frames = 48000;
    const source = try gpa.alloc(f32, frames);
    defer gpa.free(source);
    for (source, 0..) |*v, i| {
        v.* = @floatCast(0.9 * @sin(2.0 * std.math.pi * 5000.0 * @as(f64, @floatFromInt(i)) / 48000.0));
    }
    const a = try gpa.alloc(f32, frames);
    defer gpa.free(a);
    const b = try gpa.alloc(f32, frames);
    defer gpa.free(b);

    var naive = try Saturator.init(rate, 1, .{ .drive = 12, .oversample = 1 });
    var over = try Saturator.init(rate, 1, .{ .drive = 12, .oversample = 4 });
    @memcpy(a, source);
    @memcpy(b, source);
    naive.process(a, 1);
    over.process(b, 1);

    // tanh is odd, so it makes odd harmonics. At the base rate the 7th (35 kHz)
    // and 9th (45 kHz) fold back to 13 and 3 kHz -- neither is a harmonic of the
    // 5 kHz tone, so both are pure aliasing, and both sit well inside the
    // decimator's stopband.
    var naive_far: f64 = 0;
    var over_far: f64 = 0;
    for ([_]f64{ 3000, 13000 }) |freq| {
        naive_far += magnitudeAt(a[1000..], rate, freq);
        over_far += magnitudeAt(b[1000..], rate, freq);
    }
    // The wanted signal is still there in both.
    try testing.expect(magnitudeAt(a[1000..], rate, 5000) > 0.5);
    try testing.expect(magnitudeAt(b[1000..], rate, 5000) > 0.5);
    try testing.expect(naive_far > 0.1);
    try testing.expect(over_far < naive_far * 0.02); // > 34 dB down

    // The 5th harmonic lands at 25 kHz, one kHz above the 24 kHz decimation
    // cutoff, so it folds to 23 kHz. No practical filter removes a component
    // that close to the cutoff without also cutting the audible band, so this
    // one is only partly suppressed. Pinning it keeps the claim honest: the win
    // is on the far aliases, not on harmonics sitting on Nyquist.
    const naive_near = magnitudeAt(a[1000..], rate, 23000);
    const over_near = magnitudeAt(b[1000..], rate, 23000);
    try testing.expect(naive_near > 0.1);
    try testing.expect(over_near < naive_near * 0.75);
    try testing.expect(over_near > naive_near * 0.1);
}

test "effects: saturator output is bounded, resets, and survives bad input" {
    const gpa = testing.allocator;
    const rate = 48000;
    var sat = try Saturator.init(rate, 2, .{ .drive = 50, .oversample = 4 });
    const frames = 2000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    var prng = std.Random.DefaultPrng.init(0x5a7);
    const random = prng.random();
    for (buf, 0..) |*v, i| {
        v.* = if (i == 0) std.math.nan(f32) else if (i == 1) std.math.inf(f32) else (random.float(f32) * 2 - 1) * 20;
    }
    sat.process(buf, 2);
    for (buf) |v| {
        try testing.expect(std.math.isFinite(v));
        // |tanh| < 1 and the decimator's absolute tap sum is a little over 1.
        try testing.expect(@abs(v) < 1.5);
    }
    sat.reset();
    @memset(buf, 0);
    sat.process(buf, 2);
    for (buf) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "effects: saturator channels are independent and block-size invariant" {
    const gpa = testing.allocator;
    const rate = 48000;
    var a = try Saturator.init(rate, 2, .{ .drive = 6, .oversample = 4 });
    var b = try Saturator.init(rate, 2, .{ .drive = 6, .oversample = 4 });
    const frames = 1500;
    const buf_a = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf_a);
    const buf_b = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf_b);
    for (0..frames) |i| {
        const t: f32 = @floatFromInt(i);
        const left = 0.8 * @sin(t * 0.13);
        buf_a[i * 2] = left;
        buf_a[i * 2 + 1] = 0; // right silent: it must stay silent
        buf_b[i * 2] = left;
        buf_b[i * 2 + 1] = 0;
    }
    a.process(buf_a, 2);
    var offset: usize = 0;
    while (offset < buf_b.len) : (offset += 118) {
        const n = @min(118, buf_b.len - offset);
        b.process(buf_b[offset..][0..n], 2);
    }
    try testing.expectEqualSlices(f32, buf_a, buf_b);
    for (0..frames) |i| try testing.expectEqual(@as(f32, 0), buf_a[i * 2 + 1]);
}

test "effects: true-peak detection catches inter-sample overs" {
    const gpa = testing.allocator;
    const rate = 48000;
    // A quarter-rate sine at 45 degrees lands every sample on +/-0.7071 while the
    // waveform it describes peaks at 1.0. A sample-peak limiter sees nothing
    // wrong; the reconstructed signal is 3 dB over.
    const frames = 4096;
    const source = try gpa.alloc(f32, frames);
    defer gpa.free(source);
    for (source, 0..) |*v, i| {
        const t = 2.0 * std.math.pi * 12000.0 * @as(f64, @floatFromInt(i)) / 48000.0 + std.math.pi / 4.0;
        v.* = @floatCast(@sin(t));
    }
    var sample_peak: f32 = 0;
    for (source) |v| sample_peak = @max(sample_peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.7071068), sample_peak, 1e-5);

    const ceiling_db = -2.0; // ~0.794, above the samples but below the real peak
    const a = try gpa.alloc(f32, frames);
    defer gpa.free(a);
    const b = try gpa.alloc(f32, frames);
    defer gpa.free(b);

    const sample_params = LimiterParams{ .ceiling_db = ceiling_db, .lookahead_ms = 2, .release_ms = 20 };
    const true_params = LimiterParams{ .ceiling_db = ceiling_db, .lookahead_ms = 2, .release_ms = 20, .true_peak = true };
    const mem_a = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, sample_params));
    defer gpa.free(mem_a);
    const mem_b = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, true_params));
    defer gpa.free(mem_b);
    var sample_lim = try Limiter.init(rate, 1, sample_params, mem_a);
    var true_lim = try Limiter.init(rate, 1, true_params, mem_b);

    // True-peak mode reports the extra interpolation delay it adds.
    try testing.expectEqual(sample_lim.latencyFrames() + interp_delay, true_lim.latencyFrames());

    @memcpy(a, source);
    @memcpy(b, source);
    sample_lim.process(a, 1);
    true_lim.process(b, 1);

    // The sample-peak limiter passes the tone untouched...
    try testing.expectEqual(@as(f32, 0), sample_lim.gainReductionDb());
    // ...while the true-peak one pulls it down to keep the real peak in range.
    try testing.expect(true_lim.gainReductionDb() < -1.5);
    var peak_a: f32 = 0;
    var peak_b: f32 = 0;
    for (a[512..]) |v| peak_a = @max(peak_a, @abs(v));
    for (b[512..]) |v| peak_b = @max(peak_b, @abs(v));
    try testing.expectApproxEqAbs(sample_peak, peak_a, 1e-4);
    try testing.expect(peak_b < peak_a * 0.9);
    // The source's true peak is 1.0, so the gain it settles on is exactly the
    // ceiling -- referenced to the inter-sample peak, not to the samples.
    try testing.expectApproxEqAbs(true_lim.ceiling, peak_b / peak_a, 0.05);
}

test "effects: true-peak mode still guarantees its ceiling and defaults off" {
    const gpa = testing.allocator;
    const rate = 48000;
    var prng = std.Random.DefaultPrng.init(0x7ae4);
    const random = prng.random();
    const frames = 3000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);

    // Zero lookahead is the tightest case: the detector window is one entry, so
    // the extra delay is exactly what keeps the emitted sample covered.
    for ([_]f32{ 0, 0.5, 5 }) |lookahead| {
        const params = LimiterParams{ .ceiling_db = -3, .lookahead_ms = lookahead, .release_ms = 10, .true_peak = true };
        const mem = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 2, params));
        defer gpa.free(mem);
        var lim = try Limiter.init(rate, 2, params, mem);
        for (buf, 0..) |*v, i| {
            v.* = if (i % 512 == 0) 6.0 else (random.float(f32) * 2 - 1) * 3;
        }
        lim.process(buf, 2);
        for (buf) |v| {
            try testing.expect(std.math.isFinite(v));
            try testing.expect(@abs(v) <= lim.ceiling * (1.0 + 1e-6));
        }
        lim.reset();
        for (&lim.interp) |h| for (h.data) |v| try testing.expectEqual(@as(f32, 0), v);
    }

    // With the flag off, output is bit-identical to a limiter built the old way.
    const off = LimiterParams{ .ceiling_db = -1, .lookahead_ms = 1 };
    const mem = try gpa.alloc(f32, try Limiter.requiredSamples(rate, 1, off));
    defer gpa.free(mem);
    var lim = try Limiter.init(rate, 1, off, mem);
    try testing.expectEqual(@as(usize, 48), lim.latencyFrames());
    try testing.expect(!lim.true_peak);
}

test "effects: a saturator insert borrows only its instance" {
    const rate = 48000;
    var sat = try Saturator.init(rate, 2, .{ .oversample = 2 });
    const effect = Effect.saturator(&sat);
    try testing.expectEqual(@as(u16, 2), effect.channelCount());
    try testing.expectEqual(@as(usize, @intFromPtr(&sat)), effect.stateAddress().?);
    // No buffer to keep alive: all state is inline.
    try testing.expectEqual(@as(?[]const f32, null), effect.borrowedMemory());

    var slot = effect;
    var signal = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    slot.process(&signal, 2);
    slot.reset();
    for (&sat.in_hist) |h| for (h.data) |v| try testing.expectEqual(@as(f32, 0), v);
}
