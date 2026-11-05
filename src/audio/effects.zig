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
//! low/high shelf) and a feed-forward stereo-linked compressor with a soft knee.
//! Not implemented: reverb, delay, convolution, lookahead limiting, oversampled
//! saturation. Those need delay lines and are a separate stage.

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

    pub fn process(self: *Effect, buffer: []f32, channels: usize) void {
        std.debug.assert(channels >= 1 and channels <= max_channels);
        std.debug.assert(buffer.len % channels == 0);
        switch (self.kind) {
            .bypass => {},
            .biquad => |*filter| filter.process(buffer, channels),
            .compressor => |*comp| comp.process(buffer, channels),
        }
    }

    /// Clear the internal history, keeping the settings. Call after a seek or a
    /// device underrun so an old tail does not bleed into the new material.
    pub fn reset(self: *Effect) void {
        switch (self.kind) {
            .bypass => {},
            .biquad => |*filter| filter.reset(),
            .compressor => |*comp| comp.reset(),
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
