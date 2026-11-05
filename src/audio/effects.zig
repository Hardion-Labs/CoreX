//! Audio DSP: insert effects for bus and master chains.
//!
//! This module is **pure signal processing**. It imports only `std`: it knows
//! nothing about voices, buses, the mixer, scenes or assets, so a filter can be
//! tested against its analytic transfer function on its own. The mixer owns the
//! chains and calls `Chain.process` on an interleaved buffer; nothing here
//! allocates, and every effect keeps its state inline.
//!
//! Design rules that the rest of the audio stack relies on:
//! - **Validate once, process cheaply.** Coefficients are computed by the
//!   constructors (`Effect.biquad`, `Effect.compressor`), which reject invalid
//!   parameters. A constructed `Effect` is always valid, so `process` carries no
//!   parameter checks and no transcendentals on the coefficient path.
//! - **No allocation, ever.** Filter state is a fixed `[max_channels]` array, so
//!   an effect is a value that can be stored in a preallocated slot array.
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
//! feedback delay with damping, and a Freeverb-style reverb (eight damped comb
//! filters into four diffusion sections per channel; see `allpassStep`).
//!
//! **Delay-based effects borrow their memory from the caller**, exactly like a
//! `Clip` borrows its samples: `Delay.requiredSamples` / `Reverb.requiredSamples`
//! say how much to allocate, `init` carves the lines out of that buffer, and the
//! effect keeps a slice. Nothing here allocates, so a reverb costs no mixer
//! memory and `render` stays allocation-free. The instance must outlive every
//! slot that references it, and two slots must not share one instance or one
//! buffer — the mixer rejects both (see `Effect.borrowedMemory` /
//! `Effect.stateAddress`).
//!
//! Not implemented: convolution, chorus/flanger (modulated delay taps),
//! lookahead limiting, oversampled saturation.

const std = @import("std");

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

    /// Layout this effect was built for, or 0 when it adapts to any layout.
    /// Delay lines are allocated per channel, so they cannot be reinterpreted.
    pub fn channelCount(self: Effect) u16 {
        return switch (self.kind) {
            .delay => |instance| @intCast(instance.channels),
            .reverb => |instance| @intCast(instance.channels),
            else => 0,
        };
    }

    /// The delay memory this effect borrows, if any. The host uses it to reject
    /// two inserts whose buffers overlap, which would corrupt both.
    pub fn borrowedMemory(self: Effect) ?[]const f32 {
        return switch (self.kind) {
            .delay => |instance| instance.memory,
            .reverb => |instance| instance.memory,
            else => null,
        };
    }

    /// Address of the borrowed instance, if any. Two slots holding the same
    /// instance would advance its cursors twice per sample.
    pub fn stateAddress(self: Effect) ?usize {
        return switch (self.kind) {
            .delay => |instance| @intFromPtr(instance),
            .reverb => |instance| @intFromPtr(instance),
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
