//! Device-independent audio mixer: the CPU contract a playback backend consumes.
//!
//! This is the audio counterpart of the render extraction layer. It mixes a
//! fixed pool of voices into an interleaved float32 output buffer with gain,
//! pan, buses, pitch and resampling. There is **no device
//! dependency and no allocation in `render`**, so it is fully testable headlessly
//! and deterministic: the same sequence of calls produces bit-identical output on
//! a given build. (The equal-power pan law uses `@cos`/`@sin`, whose last bit can
//! differ across libm implementations; `.linear` is exact everywhere.)
//!
//! Design:
//! - **Fixed capacity.** Voices and buses are allocated once in `init`. `play`
//!   pops a slot from a preallocated free stack (O(1)); `render` never allocates,
//!   never grows and never frees.
//! - **Generational handles.** A `VoiceHandle` is a slot index plus a generation.
//!   Releasing a voice bumps the generation, so a stale handle can never address
//!   a recycled voice. Setters on a dead handle are safe no-ops; queries return
//!   `null`. A slot whose generation would wrap is retired instead of reused.
//! - **Borrowed clips.** A voice holds a `Clip` (pointer + layout), never a copy.
//!   The caller must keep the samples alive while the voice plays.
//! - **Optional voice stealing.** With `Config.steal_policy = .lowest_priority`,
//!   a full pool recycles the least important voice instead of failing: lowest
//!   `PlayOptions.priority` first, ties broken by oldest start. A voice of
//!   *higher* priority is never taken, and `terminationOf` reports why a handle
//!   died (`.stopped`, `.finished` or `.stolen`) even after its slot is reused.
//!   The default `.none` keeps `play` a hard failure on a full pool.
//! - **One output pass.** Voices accumulate into the caller's buffer; master
//!   gain, non-finite sanitizing, clamping and peak metering happen in a single
//!   final pass, so there is no scratch buffer.
//!
//! Threading contract: a `Mixer` is **single-threaded**. The thread that owns the
//! device callback owns the mixer; other threads must post commands to it (or
//! synchronize externally). Nothing here locks or uses atomics.
//!
//! Resampling always uses a float64 cursor. Two qualities are available:
//! `.linear` (the default) is two-point interpolation — cheap, allocation free,
//! exact at unity rate, but it aliases when decimating because it is not a
//! low-pass filter. `.sinc` is band-limited windowed-sinc (`resample.zig`): one
//! ~16 KiB prototype table built in `init`, cutoff scaled by the decimation
//! ratio, unity DC gain, and no per-sample allocation. An integral cursor at
//! unit step bypasses both and copies samples bit-exactly. See
//! `docs/audio-mixer.md` for the measured trade-offs.

const std = @import("std");
const clip_mod = @import("clip.zig");
const resample_mod = @import("resample.zig");

const Allocator = std.mem.Allocator;

pub const Clip = clip_mod.Clip;
pub const ChannelMap = clip_mod.ChannelMap;
/// Resampling quality for voices whose rate or pitch differs from the output.
pub const Resample = resample_mod.Quality;
pub const PanLaw = clip_mod.PanLaw;
pub const panGains = clip_mod.panGains;
pub const max_sample_rate = clip_mod.max_sample_rate;

/// Lowest accepted playback pitch multiplier.
pub const min_pitch: f32 = 0.01;
/// Highest accepted playback pitch multiplier.
pub const max_pitch: f32 = 100.0;
/// Upper bound on the voice pool, so a typo cannot request an absurd allocation.
pub const max_voice_limit: u32 = 4096;
/// Upper bound on the bus count.
pub const max_bus_limit: u32 = 64;

/// A generational voice handle. Copyable by value; `VoiceHandle.invalid` is
/// never live. Distinct from an ECS `Entity` on purpose: voice slots are a fixed
/// pool owned by the mixer, with no allocator and no ECS dependency.
pub const VoiceHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: VoiceHandle = .{
        .index = std.math.maxInt(u32),
        .generation = std.math.maxInt(u32),
    };

    pub fn eql(a: VoiceHandle, b: VoiceHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Generation that marks a slot as permanently retired (never reused).
const retired_generation: u32 = std.math.maxInt(u32);

pub const State = enum {
    /// Free slot; never reported for a live handle.
    idle,
    playing,
    paused,
};

/// What happens when `play` is called with a full voice pool.
pub const StealPolicy = enum {
    /// Refuse the new voice with `error.NoVoiceAvailable` (the default, and the
    /// behavior of every earlier version).
    none,
    /// Recycle the least important voice: lowest `priority` first, oldest start
    /// as the tie-break. A voice with a **higher** priority than the request is
    /// never stolen, so a low-priority request still fails when the pool is full
    /// of more important voices.
    lowest_priority,
};

pub const Config = struct {
    /// Output sample rate in Hz (1..384000).
    sample_rate: u32 = 48_000,
    /// Output layout: 1 (mono) or 2 (stereo).
    channels: u16 = 2,
    /// Voice pool capacity.
    max_voices: u32 = 64,
    /// How voices are interpolated when their step is not exactly 1. `.linear`
    /// (the default) is two-point and allocation-free; `.sinc` is band-limited
    /// and allocates one ~16 KiB prototype table at init.
    resample: Resample = .linear,
    /// Bus count; bus 0 is the default bus every voice starts on.
    max_buses: u32 = 8,
    pan_law: PanLaw = .equal_power,
    master_gain: f32 = 1.0,
    /// Clamp the mixed output to [-1, 1]. Disable for offline rendering that
    /// wants the unclamped sum (metering still reports the peak).
    clamp_output: bool = true,
    steal_policy: StealPolicy = .none,
};

pub const PlayOptions = struct {
    /// Linear gain; may exceed 1 and may be negative (phase inversion).
    gain: f32 = 1.0,
    /// Stereo position in [-1, 1]; clamped. Ignored for a mono output.
    pan: f32 = 0.0,
    /// Playback rate multiplier. Must be > 0; positive values are clamped to
    /// [min_pitch, max_pitch]. Zero or negative pitch is rejected (there is no
    /// "stopped" or reverse playback via pitch).
    pitch: f32 = 1.0,
    looping: bool = false,
    bus: u16 = 0,
    /// First source frame to play; must be inside the clip.
    start_frame: u32 = 0,
    /// Start paused (renders silence and does not advance until resumed).
    paused: bool = false,
    /// Importance for voice stealing: 0 is the least, 255 the most. Only used
    /// when the mixer's `steal_policy` is not `.none`.
    priority: u8 = 128,
    /// Allow this request to steal a voice under the mixer's policy. Set false
    /// to retry a previously stolen source without taking a slot from anyone
    /// else (which is how the scene bridge avoids steal ping-pong).
    allow_steal: bool = true,
};

/// Per-render diagnostics. All fields describe the buffer just rendered.
pub const RenderStats = struct {
    frames: usize = 0,
    /// Voices still playing after this render (paused voices are not counted).
    voices_active: usize = 0,
    /// Voices that reached their end during this render and were recycled.
    voices_finished: usize = 0,
    /// Loudest absolute sample after master gain, **before** clamping.
    peak: f32 = 0,
    /// Samples whose magnitude exceeded full scale (whether or not clamping is on).
    clipped_samples: usize = 0,
    /// Non-finite mixes replaced with silence. Always 0 for well-formed clips.
    non_finite_samples: usize = 0,
};

/// Why a voice slot was released. Recorded per slot so the owner of a dead
/// handle can tell a natural end from a steal.
pub const Termination = enum {
    /// `stop`/`stopAll` was called.
    stopped,
    /// The clip reached its end (non-looping).
    finished,
    /// The slot was recycled by a higher-or-equal-priority `play`.
    stolen,
};

pub const InitError = error{ InvalidConfig, OutOfMemory };
pub const PlayError = error{ InvalidClip, InvalidOptions, UnsupportedChannelLayout, NoVoiceAvailable };
pub const ParamError = error{InvalidValue};

const Bus = struct {
    gain: f32 = 1.0,
    muted: bool = false,
};

const Voice = struct {
    generation: u32 = 0,
    state: State = .idle,
    clip: Clip = .{ .sample_rate = 0, .channels = 0, .frames = 0, .samples = &.{} },
    map: ChannelMap = .mono_to_mono,
    /// Source-frame cursor. float64 keeps long clips from drifting audibly.
    position: f64 = 0,
    /// Source frames advanced per output frame.
    step: f64 = 1,
    gain: f32 = 1,
    pan: f32 = 0,
    looping: bool = false,
    bus: u16 = 0,
    priority: u8 = 128,
    /// Monotonic start order, the tie-break for stealing (smaller = older).
    seq: u64 = 0,
    /// Generation of the last voice terminated in this slot. Generations are
    /// unique per occupancy, so this identifies one exact dead handle even
    /// after the slot has been reused.
    terminated_generation: u32 = retired_generation,
    last_termination: Termination = .stopped,
};

pub const Mixer = struct {
    gpa: Allocator,
    voices: []Voice,
    buses: []Bus,
    /// Preallocated LIFO of free slot indices; `play`/release never allocate.
    free_slots: []u32,
    free_count: usize,
    live_count: usize,
    sample_rate: u32,
    channels: u16,
    pan_law: PanLaw,
    master_gain: f32,
    clamp_output: bool,
    steal_policy: StealPolicy,
    next_seq: u64,
    stolen_total: u64,
    resample_quality: Resample,
    /// Prototype table, present only when `resample_quality == .sinc`.
    sinc: ?resample_mod.Sinc,

    pub fn init(gpa: Allocator, config: Config) InitError!Mixer {
        if (config.sample_rate == 0 or config.sample_rate > max_sample_rate) return error.InvalidConfig;
        if (config.channels != 1 and config.channels != 2) return error.InvalidConfig;
        if (config.max_voices == 0 or config.max_voices > max_voice_limit) return error.InvalidConfig;
        if (config.max_buses == 0 or config.max_buses > max_bus_limit) return error.InvalidConfig;
        if (!std.math.isFinite(config.master_gain)) return error.InvalidConfig;

        const voices = try gpa.alloc(Voice, config.max_voices);
        errdefer gpa.free(voices);
        @memset(voices, .{});

        const buses = try gpa.alloc(Bus, config.max_buses);
        errdefer gpa.free(buses);
        @memset(buses, .{});

        const free_slots = try gpa.alloc(u32, config.max_voices);
        errdefer gpa.free(free_slots);
        // Descending fill so the first pop yields slot 0: slot order (and thus
        // the mixing order) follows the order voices were started.
        for (free_slots, 0..) |*slot, i| slot.* = @intCast(config.max_voices - 1 - i);

        // The band-limited path needs a prototype table; build it once here so
        // `render` stays allocation-free. `.linear` never allocates it.
        var sinc: ?resample_mod.Sinc = null;
        if (config.resample == .sinc) {
            sinc = try resample_mod.Sinc.init(gpa);
        }
        errdefer if (sinc) |*table| table.deinit(gpa);

        return .{
            .gpa = gpa,
            .voices = voices,
            .buses = buses,
            .free_slots = free_slots,
            .free_count = config.max_voices,
            .live_count = 0,
            .sample_rate = config.sample_rate,
            .channels = config.channels,
            .pan_law = config.pan_law,
            .master_gain = config.master_gain,
            .clamp_output = config.clamp_output,
            .steal_policy = config.steal_policy,
            .next_seq = 0,
            .stolen_total = 0,
            .resample_quality = config.resample,
            .sinc = sinc,
        };
    }

    pub fn deinit(self: *Mixer) void {
        if (self.sinc) |*table| table.deinit(self.gpa);
        self.gpa.free(self.voices);
        self.gpa.free(self.buses);
        self.gpa.free(self.free_slots);
        self.* = undefined;
    }

    // --- voice lifecycle ---------------------------------------------------

    /// Start a voice. The clip is borrowed: keep `clip.samples` alive until the
    /// voice is stopped or finishes. Fails with `NoVoiceAvailable` when the pool
    /// is full and no voice can be stolen (see `Config.steal_policy`).
    pub fn play(self: *Mixer, clip: Clip, options: PlayOptions) PlayError!VoiceHandle {
        try clip.validate();
        if (!std.math.isFinite(options.gain)) return error.InvalidOptions;
        if (!std.math.isFinite(options.pan)) return error.InvalidOptions;
        if (!std.math.isFinite(options.pitch) or options.pitch <= 0) return error.InvalidOptions;
        if (options.bus >= self.buses.len) return error.InvalidOptions;
        if (options.start_frame >= clip.frames) return error.InvalidOptions;
        const map = try ChannelMap.resolve(clip.channels, self.channels);
        const pitch = std.math.clamp(options.pitch, min_pitch, max_pitch);
        const step = (@as(f64, @floatFromInt(clip.sample_rate)) /
            @as(f64, @floatFromInt(self.sample_rate))) * @as(f64, pitch);
        if (!(step > 0) or !std.math.isFinite(step)) return error.InvalidOptions;

        if (self.free_count == 0) {
            const victim = self.stealCandidate(options.priority, options.allow_steal) orelse
                return error.NoVoiceAvailable;
            self.releaseSlot(victim, .stolen);
            self.stolen_total += 1;
        }
        self.free_count -= 1;
        const index = self.free_slots[self.free_count];
        const v = &self.voices[index];
        const seq = self.next_seq;
        self.next_seq += 1;
        v.* = .{
            .generation = v.generation,
            .terminated_generation = v.terminated_generation,
            .last_termination = v.last_termination,
            .state = if (options.paused) .paused else .playing,
            .clip = clip,
            .map = map,
            .position = @floatFromInt(options.start_frame),
            .step = step,
            .gain = options.gain,
            .pan = std.math.clamp(options.pan, -1.0, 1.0),
            .looping = options.looping,
            .bus = options.bus,
            .priority = options.priority,
            .seq = seq,
        };
        self.live_count += 1;
        return .{ .index = index, .generation = v.generation };
    }

    /// Stop a voice and recycle its slot. No-op for a dead handle.
    pub fn stop(self: *Mixer, handle: VoiceHandle) void {
        const index = self.slotOf(handle) orelse return;
        self.releaseSlot(index, .stopped);
    }

    /// Stop every voice. Bus and master settings are kept.
    pub fn stopAll(self: *Mixer) void {
        for (self.voices, 0..) |*v, i| {
            if (v.state == .idle) continue;
            self.releaseSlot(@intCast(i), .stopped);
        }
    }

    /// Pause or resume. No-op for a dead handle.
    pub fn setPaused(self: *Mixer, handle: VoiceHandle, paused: bool) void {
        const v = self.voiceOf(handle) orelse return;
        v.state = if (paused) .paused else .playing;
    }

    pub fn setGain(self: *Mixer, handle: VoiceHandle, gain: f32) ParamError!void {
        if (!std.math.isFinite(gain)) return error.InvalidValue;
        const v = self.voiceOf(handle) orelse return;
        v.gain = gain;
    }

    /// Pan is clamped to [-1, 1]; non-finite input is rejected.
    pub fn setPan(self: *Mixer, handle: VoiceHandle, pan: f32) ParamError!void {
        if (!std.math.isFinite(pan)) return error.InvalidValue;
        const v = self.voiceOf(handle) orelse return;
        v.pan = std.math.clamp(pan, -1.0, 1.0);
    }

    /// Change the playback rate multiplier. Recomputes the resampling step from
    /// the current cursor, so pitch changes do not restart or jump the voice.
    /// Must be > 0; positive values are clamped to [min_pitch, max_pitch].
    pub fn setPitch(self: *Mixer, handle: VoiceHandle, pitch: f32) ParamError!void {
        if (!std.math.isFinite(pitch) or pitch <= 0) return error.InvalidValue;
        const v = self.voiceOf(handle) orelse return;
        const clamped = std.math.clamp(pitch, min_pitch, max_pitch);
        v.step = (@as(f64, @floatFromInt(v.clip.sample_rate)) /
            @as(f64, @floatFromInt(self.sample_rate))) * @as(f64, clamped);
    }

    pub fn setLooping(self: *Mixer, handle: VoiceHandle, looping: bool) void {
        const v = self.voiceOf(handle) orelse return;
        v.looping = looping;
    }

    /// Move the cursor to a source frame. `frames` (the end) is accepted and
    /// makes a non-looping voice finish on the next render.
    pub fn seek(self: *Mixer, handle: VoiceHandle, frame: u32) ParamError!void {
        const v = self.voiceOf(handle) orelse return;
        if (frame > v.clip.frames) return error.InvalidValue;
        v.position = @floatFromInt(frame);
    }

    /// Move a voice to another bus. No-op for a dead handle.
    pub fn setBus(self: *Mixer, handle: VoiceHandle, bus: u16) ParamError!void {
        if (bus >= self.buses.len) return error.InvalidValue;
        const v = self.voiceOf(handle) orelse return;
        v.bus = bus;
    }

    /// Live state, or `null` for a dead handle. Never returns `.idle`.
    pub fn state(self: *const Mixer, handle: VoiceHandle) ?State {
        const v = self.constVoiceOf(handle) orelse return null;
        return v.state;
    }

    pub fn isLive(self: *const Mixer, handle: VoiceHandle) bool {
        return self.constVoiceOf(handle) != null;
    }

    /// Current source-frame cursor, or `null` for a dead handle.
    pub fn positionFrames(self: *const Mixer, handle: VoiceHandle) ?f64 {
        const v = self.constVoiceOf(handle) orelse return null;
        return v.position;
    }

    /// Why the voice behind `handle` was released, or null when the handle never
    /// identified a voice in this slot (or its record has been overwritten by a
    /// later release). Works after the slot has been recycled, so a stolen voice
    /// can be told apart from one that finished.
    pub fn terminationOf(self: *const Mixer, handle: VoiceHandle) ?Termination {
        if (handle.index >= self.voices.len) return null;
        const v = &self.voices[handle.index];
        if (v.terminated_generation != handle.generation) return null;
        return v.last_termination;
    }

    /// Cumulative number of voices recycled by stealing.
    pub fn stolenCount(self: *const Mixer) u64 {
        return self.stolen_total;
    }

    /// Voices holding a slot (playing + paused).
    pub fn liveVoices(self: *const Mixer) usize {
        return self.live_count;
    }

    pub fn voiceCapacity(self: *const Mixer) usize {
        return self.voices.len;
    }

    // --- buses and master --------------------------------------------------

    pub fn setBusGain(self: *Mixer, bus: u16, gain: f32) ParamError!void {
        if (bus >= self.buses.len) return error.InvalidValue;
        if (!std.math.isFinite(gain)) return error.InvalidValue;
        self.buses[bus].gain = gain;
    }

    pub fn busGain(self: *const Mixer, bus: u16) ?f32 {
        if (bus >= self.buses.len) return null;
        return self.buses[bus].gain;
    }

    /// Muting a bus silences its voices but does **not** stop them: they keep
    /// advancing and still finish, which is what a mute control should do.
    pub fn setBusMuted(self: *Mixer, bus: u16, muted: bool) ParamError!void {
        if (bus >= self.buses.len) return error.InvalidValue;
        self.buses[bus].muted = muted;
    }

    pub fn isBusMuted(self: *const Mixer, bus: u16) ?bool {
        if (bus >= self.buses.len) return null;
        return self.buses[bus].muted;
    }

    pub fn setMasterGain(self: *Mixer, gain: f32) ParamError!void {
        if (!std.math.isFinite(gain)) return error.InvalidValue;
        self.master_gain = gain;
    }

    pub fn masterGain(self: *const Mixer) f32 {
        return self.master_gain;
    }

    // --- rendering ---------------------------------------------------------

    /// Mix `out.len / channels` frames into `out` (interleaved float32).
    ///
    /// The buffer is fully overwritten: silence where no voice plays. Allocation
    /// free and infallible apart from the buffer-shape check. Voices that reach
    /// their end are recycled after their last samples are mixed, so the tail of
    /// the buffer is correct.
    pub fn render(self: *Mixer, out: []f32) error{InvalidBuffer}!RenderStats {
        if (out.len % self.channels != 0) return error.InvalidBuffer;
        const frames = out.len / self.channels;
        @memset(out, 0);

        var stats = RenderStats{ .frames = frames };
        if (frames > 0) {
            for (self.voices, 0..) |*v, i| {
                if (v.state != .playing) continue;
                if (self.mixVoice(v, out, frames)) {
                    self.releaseSlot(@intCast(i), .finished);
                    stats.voices_finished += 1;
                }
            }
        }

        // Single output pass: master gain, sanitize, clamp, meter.
        const master = self.master_gain;
        for (out) |*sample| {
            var value = sample.* * master;
            if (!std.math.isFinite(value)) {
                stats.non_finite_samples += 1;
                value = 0;
            }
            const magnitude = @abs(value);
            if (magnitude > stats.peak) stats.peak = magnitude;
            if (magnitude > 1.0) {
                stats.clipped_samples += 1;
                if (self.clamp_output) value = std.math.clamp(value, -1.0, 1.0);
            }
            sample.* = value;
        }

        for (self.voices) |*v| {
            if (v.state == .playing) stats.voices_active += 1;
        }
        return stats;
    }

    // --- internals ---------------------------------------------------------

    fn slotOf(self: *const Mixer, handle: VoiceHandle) ?u32 {
        if (handle.index >= self.voices.len) return null;
        const v = &self.voices[handle.index];
        if (v.state == .idle) return null;
        if (v.generation != handle.generation) return null;
        return handle.index;
    }

    fn voiceOf(self: *Mixer, handle: VoiceHandle) ?*Voice {
        const index = self.slotOf(handle) orelse return null;
        return &self.voices[index];
    }

    fn constVoiceOf(self: *const Mixer, handle: VoiceHandle) ?*const Voice {
        const index = self.slotOf(handle) orelse return null;
        return &self.voices[index];
    }

    /// Pick the least important live voice for a request, or null when nothing
    /// may be stolen. Ascending slot order with strict comparisons keeps the
    /// choice deterministic.
    fn stealCandidate(self: *const Mixer, priority: u8, allow_steal: bool) ?u32 {
        if (self.steal_policy == .none or !allow_steal) return null;
        var best: ?u32 = null;
        var best_priority: u8 = std.math.maxInt(u8);
        var best_seq: u64 = std.math.maxInt(u64);
        for (self.voices, 0..) |*v, i| {
            if (v.state == .idle) continue;
            if (v.priority > priority) continue; // more important than the request
            if (best == null or v.priority < best_priority or
                (v.priority == best_priority and v.seq < best_seq))
            {
                best = @intCast(i);
                best_priority = v.priority;
                best_seq = v.seq;
            }
        }
        return best;
    }

    /// Release a slot in place. Infallible: the free stack was sized for every
    /// slot at init, so pushing back can never allocate or overflow.
    fn releaseSlot(self: *Mixer, index: u32, reason: Termination) void {
        const v = &self.voices[index];
        v.terminated_generation = v.generation;
        v.last_termination = reason;
        v.state = .idle;
        v.clip = .{ .sample_rate = 0, .channels = 0, .frames = 0, .samples = &.{} };
        self.live_count -= 1;
        if (v.generation >= retired_generation - 1) {
            // Retire the slot: no future handle can alias this generation.
            v.generation = retired_generation;
            return;
        }
        v.generation += 1;
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }

    /// Mix one voice; returns true when it reached its end (non-looping).
    fn mixVoice(self: *Mixer, v: *Voice, out: []f32, frames: usize) bool {
        const bus = self.buses[v.bus];
        const bus_gain: f32 = if (bus.muted) 0 else bus.gain;
        const pan = panGains(self.pan_law, v.pan);
        const stereo_out = self.channels == 2;
        const gain_l = v.gain * bus_gain * (if (stereo_out) pan[0] else 1.0);
        const gain_r = v.gain * bus_gain * (if (stereo_out) pan[1] else 1.0);
        // The interpolation-free path is only valid for an integral cursor at
        // unit step; hoisting the decision keeps the hot loop branch-free.
        const needs_resample = v.step != 1.0 or v.position != @floor(v.position);
        const mode: Mode = if (!needs_resample)
            .copy
        else if (self.resample_quality == .sinc) .sinc else .linear;
        switch (v.map) {
            inline else => |map| {
                return switch (mode) {
                    .copy => mixLoop(map, .copy, v, out, frames, gain_l, gain_r, null),
                    .linear => mixLoop(map, .linear, v, out, frames, gain_l, gain_r, null),
                    .sinc => mixLoop(map, .sinc, v, out, frames, gain_l, gain_r, &self.sinc.?),
                };
            },
        }
    }
};

/// Which fetch specialization the hot loop is compiled for.
const Mode = enum {
    /// Integral cursor at unit step: read the sample directly.
    copy,
    /// Two-point linear interpolation.
    linear,
    /// Band-limited windowed sinc over a precomputed prototype.
    sinc,
};

/// Per-frame read cursor. `index0/index1/t` feed the copy and linear paths;
/// `kernel` feeds the sinc path. Unused fields cost nothing: every reader is
/// specialized on a comptime `Mode`, so the dead branches are pruned.
const Reader = struct {
    src: []const f32,
    channels: usize,
    frames: usize,
    looping: bool,
    index0: usize = 0,
    index1: usize = 0,
    t: f32 = 0,
    kernel: *const resample_mod.Kernel,
};

/// One source sample, interpolated only when the specialization needs it.
inline fn readSample(comptime mode: Mode, reader: Reader, channel: usize) f32 {
    if (mode == .sinc) {
        return resample_mod.apply(reader.kernel, reader.src, reader.channels, channel, reader.frames, reader.looping);
    }
    const a = reader.src[reader.index0 * reader.channels + channel];
    if (mode == .copy) return a;
    const b = reader.src[reader.index1 * reader.channels + channel];
    return a + (b - a) * reader.t;
}

/// Left/right source pair for one output frame, before gain and pan.
inline fn fetchPair(comptime map: ChannelMap, comptime mode: Mode, reader: Reader) [2]f32 {
    if (map == .mono_to_mono or map == .mono_to_stereo) {
        const m = readSample(mode, reader, 0);
        return .{ m, m };
    }
    if (map == .stereo_to_stereo) {
        if (mode == .sinc) {
            return resample_mod.applyPair(reader.kernel, reader.src, reader.frames, reader.looping);
        }
        return .{ readSample(mode, reader, 0), readSample(mode, reader, 1) };
    }
    if (map == .stereo_to_mono) {
        if (mode == .sinc) {
            const pair = resample_mod.applyPair(reader.kernel, reader.src, reader.frames, reader.looping);
            return .{ (pair[0] + pair[1]) * 0.5, 0 };
        }
        const l = readSample(mode, reader, 0);
        const r = readSample(mode, reader, 1);
        return .{ (l + r) * 0.5, 0 };
    }
    // many_to_mono: equal-weight mean of every source channel.
    var sum: f32 = 0;
    for (0..reader.channels) |c| sum += readSample(mode, reader, c);
    return .{ sum / @as(f32, @floatFromInt(reader.channels)), 0 };
}

/// The mixing core, monomorphized per (channel map, resampling) pair so the
/// per-sample work has no layout or interpolation branch. Returns true when the
/// voice reached its end.
fn mixLoop(
    comptime map: ChannelMap,
    comptime mode: Mode,
    v: *Voice,
    out: []f32,
    frames: usize,
    gain_l: f32,
    gain_r: f32,
    sinc: ?*const resample_mod.Sinc,
) bool {
    const src = v.clip.samples;
    const src_channels: usize = if (map == .many_to_mono)
        @as(usize, v.clip.channels)
    else
        @as(usize, map.sourceChannels().?);
    const src_frames: usize = v.clip.frames;
    const end: f64 = @floatFromInt(src_frames);
    const step = v.step;
    const looping = v.looping;
    var pos = v.position;
    const stereo_out = comptime map.outputChannels() == 2;
    // One kernel per voice render, refilled per frame: no allocation, and the
    // coefficients are shared by every channel of the frame.
    var kernel: resample_mod.Kernel = undefined;
    // The coefficients depend only on the fractional cursor and the (constant)
    // step, so an exactly repeated fraction reuses them and only moves `start`.
    // Integer and half-integer steps hit this on every frame but the first.
    var cached_frac: f64 = -1;

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        if (pos >= end) {
            if (!looping) break;
            // `@rem` handles any step, including steps larger than the clip.
            pos = @rem(pos, end);
        }
        var reader = Reader{
            .src = src,
            .channels = src_channels,
            .frames = src_frames,
            .looping = looping,
            .kernel = &kernel,
        };
        if (mode == .sinc) {
            const frac = pos - @floor(pos);
            if (frac != cached_frac) {
                sinc.?.build(pos, step, &kernel);
                cached_frac = frac;
            } else {
                kernel.start = @as(i64, @intFromFloat(@floor(pos))) + kernel.first_offset;
            }
        } else {
            reader.index0 = @intFromFloat(pos);
            reader.index1 = reader.index0;
            if (mode == .linear) {
                reader.t = @floatCast(pos - @floor(pos));
                reader.index1 = if (reader.index0 + 1 >= src_frames)
                    (if (looping) 0 else src_frames - 1)
                else
                    reader.index0 + 1;
            }
        }
        const pair = fetchPair(map, mode, reader);
        if (stereo_out) {
            out[frame * 2] += pair[0] * gain_l;
            out[frame * 2 + 1] += pair[1] * gain_r;
        } else {
            out[frame] += pair[0] * gain_l;
        }
        pos += step;
    }

    v.position = pos;
    return !looping and pos >= end;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn monoClip(samples: []const f32, rate: u32) Clip {
    return .{
        .sample_rate = rate,
        .channels = 1,
        .frames = @intCast(samples.len),
        .samples = samples,
    };
}

fn stereoClip(samples: []const f32, rate: u32) Clip {
    return .{
        .sample_rate = rate,
        .channels = 2,
        .frames = @intCast(samples.len / 2),
        .samples = samples,
    };
}

test "mixer: init validates the configuration" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .sample_rate = 0 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .sample_rate = max_sample_rate + 1 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .channels = 0 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .channels = 3 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .max_voices = 0 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .max_voices = max_voice_limit + 1 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .max_buses = 0 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .max_buses = max_bus_limit + 1 }));
    try testing.expectError(error.InvalidConfig, Mixer.init(gpa, .{ .master_gain = std.math.nan(f32) }));

    var mixer = try Mixer.init(gpa, .{ .max_voices = 4, .max_buses = 2 });
    defer mixer.deinit();
    try testing.expectEqual(@as(usize, 4), mixer.voiceCapacity());
    try testing.expectEqual(@as(usize, 0), mixer.liveVoices());
    try testing.expectEqual(@as(?f32, 1.0), mixer.busGain(0));
    try testing.expectEqual(@as(?f32, null), mixer.busGain(2));
}

test "mixer: init and play survive allocation failure" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator) !void {
            var mixer = try Mixer.init(alloc, .{ .max_voices = 2, .max_buses = 2 });
            defer mixer.deinit();
            const handle = try mixer.play(monoClip(&samples, 48000), .{});
            var out: [8]f32 = undefined;
            _ = try mixer.render(&out);
            mixer.stop(handle);
        }
    }.f, .{});
    // The band-limited path adds one table allocation; it must unwind cleanly.
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator) !void {
            var mixer = try Mixer.init(alloc, .{ .max_voices = 2, .max_buses = 2, .resample = .sinc });
            defer mixer.deinit();
            const handle = try mixer.play(monoClip(&samples, 44100), .{});
            var out: [8]f32 = undefined;
            _ = try mixer.render(&out);
            mixer.stop(handle);
        }
    }.f, .{});
}

test "mixer: an idle mixer renders digital silence" {
    const gpa = testing.allocator;
    var mixer = try Mixer.init(gpa, .{});
    defer mixer.deinit();

    var out: [16]f32 = undefined;
    @memset(&out, 123.0); // render must overwrite, not accumulate onto garbage
    const stats = try mixer.render(&out);
    for (out) |sample| try testing.expectEqual(@as(f32, 0), sample);
    try testing.expectEqual(@as(usize, 8), stats.frames);
    try testing.expectEqual(@as(usize, 0), stats.voices_active);
    try testing.expectEqual(@as(usize, 0), stats.voices_finished);
    try testing.expectEqual(@as(f32, 0), stats.peak);

    // An empty buffer is valid and changes nothing.
    const empty = try mixer.render(&[_]f32{});
    try testing.expectEqual(@as(usize, 0), empty.frames);
    // A buffer that is not a whole number of frames is rejected.
    var odd: [3]f32 = undefined;
    try testing.expectError(error.InvalidBuffer, mixer.render(&odd));
}

test "mixer: mono and stereo passthrough are bit-exact at unity gain" {
    const gpa = testing.allocator;
    const mono = [_]f32{ 0.0, 0.25, -0.5, 0.75, -1.0, 1.0 };
    var mono_mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000 });
    defer mono_mixer.deinit();
    _ = try mono_mixer.play(monoClip(&mono, 48000), .{});
    var mono_out: [mono.len]f32 = undefined;
    _ = try mono_mixer.render(&mono_out);
    try testing.expectEqualSlices(f32, &mono, &mono_out);

    const stereo = [_]f32{ 0.1, -0.1, 0.2, -0.2, 0.3, -0.3 };
    var stereo_mixer = try Mixer.init(gpa, .{ .channels = 2, .sample_rate = 44100, .pan_law = .linear });
    defer stereo_mixer.deinit();
    _ = try stereo_mixer.play(stereoClip(&stereo, 44100), .{});
    var stereo_out: [stereo.len]f32 = undefined;
    _ = try stereo_mixer.render(&stereo_out);
    try testing.expectEqualSlices(f32, &stereo, &stereo_out);
}

test "mixer: mono to stereo duplicates and stereo to mono averages" {
    const gpa = testing.allocator;
    const mono = [_]f32{ 0.5, -0.25, 1.0 };
    var up = try Mixer.init(gpa, .{ .channels = 2, .pan_law = .linear });
    defer up.deinit();
    _ = try up.play(monoClip(&mono, 48000), .{});
    var up_out: [6]f32 = undefined;
    _ = try up.render(&up_out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5, -0.25, -0.25, 1.0, 1.0 }, &up_out);

    const stereo = [_]f32{ 1.0, 0.0, -0.5, 0.5, 0.25, 0.75 };
    var down = try Mixer.init(gpa, .{ .channels = 1 });
    defer down.deinit();
    _ = try down.play(stereoClip(&stereo, 48000), .{});
    var down_out: [3]f32 = undefined;
    _ = try down.render(&down_out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.0, 0.5 }, &down_out);
}

test "mixer: surround clips downmix to mono by mean and are refused for stereo" {
    const gpa = testing.allocator;
    // Two frames of 6-channel audio.
    const six = [_]f32{ 1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 0 };
    const clip = Clip{ .sample_rate = 48000, .channels = 6, .frames = 2, .samples = &six };

    var mono = try Mixer.init(gpa, .{ .channels = 1 });
    defer mono.deinit();
    _ = try mono.play(clip, .{});
    var out: [2]f32 = undefined;
    _ = try mono.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, &out);

    var stereo = try Mixer.init(gpa, .{ .channels = 2 });
    defer stereo.deinit();
    try testing.expectError(error.UnsupportedChannelLayout, stereo.play(clip, .{}));
}

test "mixer: voice, bus and master gains multiply" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_buses = 2 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 48000), .{ .gain = 0.5, .bus = 1, .looping = true });
    try mixer.setBusGain(1, 0.5);
    try mixer.setMasterGain(0.5);
    try testing.expectEqual(@as(f32, 0.5), mixer.masterGain());

    var out: [4]f32 = undefined;
    _ = try mixer.render(&out);
    // 1.0 * 0.5 (voice) * 0.5 (bus) * 0.5 (master) = 0.125
    for (out) |sample| try testing.expectEqual(@as(f32, 0.125), sample);

    // Negative gain inverts phase.
    try mixer.setGain(handle, -1.0);
    try mixer.setBusGain(1, 1.0);
    try mixer.setMasterGain(1.0);
    _ = try mixer.render(&out);
    for (out) |sample| try testing.expectEqual(@as(f32, -1.0), sample);
}

test "mixer: a muted bus is silent but its voices still advance and finish" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 1.0, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 48000), .{});
    try mixer.setBusMuted(0, true);
    try testing.expectEqual(@as(?bool, true), mixer.isBusMuted(0));

    var out: [2]f32 = undefined;
    const stats = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0 }, &out);
    try testing.expectEqual(@as(usize, 1), stats.voices_finished);
    try testing.expect(!mixer.isLive(handle));
}

test "mixer: panning follows the configured law" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 1.0, 1.0 };

    var linear = try Mixer.init(gpa, .{ .pan_law = .linear });
    defer linear.deinit();
    const left = try linear.play(monoClip(&samples, 48000), .{ .pan = -1.0, .looping = true });
    var out: [4]f32 = undefined;
    _ = try linear.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 0, 1, 0 }, &out);
    try linear.setPan(left, 1.0);
    try linear.seek(left, 0);
    _ = try linear.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 1, 0, 1 }, &out);

    var equal = try Mixer.init(gpa, .{ .pan_law = .equal_power });
    defer equal.deinit();
    _ = try equal.play(monoClip(&samples, 48000), .{});
    _ = try equal.render(&out);
    for (out) |sample| try testing.expectApproxEqAbs(@as(f32, 0.70710678), sample, 1e-6);

    // A mono output ignores pan instead of attenuating one side away.
    var mono = try Mixer.init(gpa, .{ .channels = 1 });
    defer mono.deinit();
    _ = try mono.play(monoClip(&samples, 48000), .{ .pan = -1.0 });
    var mono_out: [2]f32 = undefined;
    _ = try mono.render(&mono_out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1 }, &mono_out);
}

test "mixer: resampling interpolates linearly in both directions" {
    const gpa = testing.allocator;
    // 96 kHz -> 48 kHz takes every other source frame (no interpolation error).
    const fast = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0, -1.0 };
    var down = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000 });
    defer down.deinit();
    _ = try down.play(monoClip(&fast, 96000), .{});
    var down_out: [3]f32 = undefined;
    const down_stats = try down.render(&down_out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 0.5, 1.0 }, &down_out);
    // Frames 0, 2 and 4 consume the whole 6-frame source, so the voice is done.
    try testing.expectEqual(@as(usize, 1), down_stats.voices_finished);

    // 24 kHz -> 48 kHz inserts midpoints.
    const slow = [_]f32{ 0.0, 1.0, -1.0 };
    var up = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000 });
    defer up.deinit();
    _ = try up.play(monoClip(&slow, 24000), .{});
    var up_out: [5]f32 = undefined;
    _ = try up.render(&up_out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 0.5, 1.0, 0.0, -1.0 }, &up_out);

    // The last source frame is held, never wrapped, for a non-looping clip.
    var tail: [2]f32 = undefined;
    const tail_stats = try up.render(&tail);
    try testing.expectEqualSlices(f32, &[_]f32{ -1.0, 0.0 }, &tail);
    try testing.expectEqual(@as(usize, 1), tail_stats.voices_finished);
}

test "mixer: pitch scales the cursor step without restarting the voice" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 48000), .{ .pitch = 2.0, .looping = true });
    var out: [2]f32 = undefined;
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 0.5 }, &out);
    try testing.expectEqual(@as(?f64, 4.0), mixer.positionFrames(handle));

    // Halving the pitch mid-flight continues from the current cursor.
    try mixer.seek(handle, 1);
    try mixer.setPitch(handle, 0.5);
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.25, 0.375 }, &out);
    try testing.expectEqual(@as(?f64, 2.0), mixer.positionFrames(handle));

    // Out-of-range pitch is clamped into the documented band, not rejected.
    try mixer.setPitch(handle, 1000.0);
    try mixer.seek(handle, 0);
    _ = try mixer.render(&out);
    try testing.expectEqual(@as(?f64, max_pitch), mixer.positionFrames(handle));
    try testing.expectError(error.InvalidValue, mixer.setPitch(handle, 0));
    try testing.expectError(error.InvalidValue, mixer.setPitch(handle, -2.0));
}

test "mixer: looping wraps and interpolates across the loop boundary" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.0, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 24000), .{ .looping = true });
    var out: [8]f32 = undefined;
    const stats = try mixer.render(&out);
    // 0, 0.5, 1, 0.5 (wrap to frame 0), 0, 0.5, 1, 0.5
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 0.5, 1.0, 0.5, 0.0, 0.5, 1.0, 0.5 }, &out);
    try testing.expectEqual(@as(usize, 0), stats.voices_finished);
    try testing.expectEqual(@as(usize, 1), stats.voices_active);
    try testing.expect(mixer.isLive(handle));

    // A step larger than the clip still lands inside it.
    try mixer.setPitch(handle, 4.0); // step = 0.5 * 4 = 2 frames
    try mixer.seek(handle, 0);
    var wide: [4]f32 = undefined;
    _ = try mixer.render(&wide);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 0.0, 0.0, 0.0 }, &wide);
    try testing.expect(mixer.isLive(handle));

    // Turning looping off lets the voice finish.
    mixer.setLooping(handle, false);
    try mixer.setPitch(handle, 1.0);
    try mixer.seek(handle, 1);
    var last: [4]f32 = undefined;
    const done = try mixer.render(&last);
    try testing.expectEqual(@as(usize, 1), done.voices_finished);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 1.0, 0.0, 0.0 }, &last);
}

test "mixer: a one-shot finishes exactly at its end and the tail is silence" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.5, -0.5, 0.25 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 48000), .{});
    var out: [5]f32 = undefined;
    const stats = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, -0.5, 0.25, 0, 0 }, &out);
    try testing.expectEqual(@as(usize, 1), stats.voices_finished);
    try testing.expectEqual(@as(usize, 0), stats.voices_active);
    try testing.expectEqual(@as(usize, 0), mixer.liveVoices());
    try testing.expect(!mixer.isLive(handle));
    try testing.expectEqual(@as(?State, null), mixer.state(handle));
    try testing.expectEqual(@as(?f64, null), mixer.positionFrames(handle));

    // The recycled slot is handed out again with a new generation.
    const second = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(handle.index, second.index);
    try testing.expect(!handle.eql(second));
    try testing.expect(!mixer.isLive(handle));
    try testing.expect(mixer.isLive(second));
}

test "mixer: stale handles are inert, never aliasing a recycled voice" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 1 });
    defer mixer.deinit();

    const first = try mixer.play(monoClip(&samples, 48000), .{});
    mixer.stop(first);
    try testing.expect(!mixer.isLive(first));
    // Every setter is a safe no-op on a dead handle.
    mixer.stop(first);
    mixer.setPaused(first, true);
    mixer.setLooping(first, true);
    try mixer.setGain(first, 0.0);
    try mixer.setPan(first, 1.0);
    try mixer.setPitch(first, 2.0);
    try mixer.seek(first, 0);
    try mixer.setBus(first, 0);

    const second = try mixer.play(monoClip(&samples, 48000), .{});
    // The stale handle must not touch the new voice.
    try mixer.setGain(first, 0.0);
    mixer.stop(first);
    try testing.expect(mixer.isLive(second));
    var out: [2]f32 = undefined;
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 1.0 }, &out);

    // A handle from beyond the pool, and the invalid sentinel, are inert.
    const foreign = VoiceHandle{ .index = 999, .generation = 0 };
    try testing.expect(!mixer.isLive(foreign));
    try testing.expect(!mixer.isLive(VoiceHandle.invalid));
    mixer.stop(VoiceHandle.invalid);
    try testing.expectEqual(@as(?State, null), mixer.state(VoiceHandle.invalid));
}

test "mixer: the voice pool is a hard limit and recycles on stop" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.1, 0.2 };
    var mixer = try Mixer.init(gpa, .{ .max_voices = 2 });
    defer mixer.deinit();

    const a = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    const b = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    try testing.expectEqual(@as(usize, 2), mixer.liveVoices());
    try testing.expectError(error.NoVoiceAvailable, mixer.play(monoClip(&samples, 48000), .{}));

    mixer.stop(a);
    const c = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    try testing.expectEqual(a.index, c.index);
    try testing.expectEqual(@as(usize, 2), mixer.liveVoices());

    mixer.stopAll();
    try testing.expectEqual(@as(usize, 0), mixer.liveVoices());
    try testing.expect(!mixer.isLive(b));
    try testing.expect(!mixer.isLive(c));
    var out: [4]f32 = undefined;
    const stats = try mixer.render(&out);
    try testing.expectEqual(@as(f32, 0), stats.peak);
}

test "mixer: play validates the clip and the options" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.1, 0.2 };
    var mixer = try Mixer.init(gpa, .{ .max_buses = 1 });
    defer mixer.deinit();

    try testing.expectError(error.InvalidClip, mixer.play(monoClip(&.{}, 48000), .{}));
    try testing.expectError(error.InvalidClip, mixer.play(monoClip(&samples, 0), .{}));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .gain = std.math.nan(f32) }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .pan = std.math.inf(f32) }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .pitch = std.math.nan(f32) }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .pitch = 0 }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .pitch = -1 }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .start_frame = 99 }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .bus = 1 }));
    try testing.expectError(error.InvalidOptions, mixer.play(monoClip(&samples, 48000), .{ .start_frame = 2 }));
    try testing.expectEqual(@as(usize, 0), mixer.liveVoices());

    // A valid start frame is honored.
    const handle = try mixer.play(monoClip(&samples, 48000), .{ .start_frame = 1 });
    try testing.expectEqual(@as(?f64, 1.0), mixer.positionFrames(handle));
    try testing.expectError(error.InvalidValue, mixer.seek(handle, 3));
    try testing.expectError(error.InvalidValue, mixer.setBus(handle, 1));
    try testing.expectError(error.InvalidValue, mixer.setGain(handle, std.math.nan(f32)));
    try testing.expectError(error.InvalidValue, mixer.setPan(handle, std.math.inf(f32)));
    try testing.expectError(error.InvalidValue, mixer.setPitch(handle, std.math.nan(f32)));
    try testing.expectError(error.InvalidValue, mixer.setBusGain(1, 1.0));
    try testing.expectError(error.InvalidValue, mixer.setBusMuted(1, true));
    try testing.expectError(error.InvalidValue, mixer.setMasterGain(std.math.nan(f32)));
}

test "mixer: pause holds the cursor and resume continues" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.25, 0.5, 0.75, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1 });
    defer mixer.deinit();

    const handle = try mixer.play(monoClip(&samples, 48000), .{ .paused = true });
    try testing.expectEqual(@as(?State, .paused), mixer.state(handle));
    var out: [2]f32 = undefined;
    const paused = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0 }, &out);
    try testing.expectEqual(@as(?f64, 0.0), mixer.positionFrames(handle));
    try testing.expectEqual(@as(usize, 0), paused.voices_active);
    try testing.expectEqual(@as(usize, 1), mixer.liveVoices());

    mixer.setPaused(handle, false);
    try testing.expectEqual(@as(?State, .playing), mixer.state(handle));
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.25, 0.5 }, &out);
    mixer.setPaused(handle, true);
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0 }, &out);
    try testing.expectEqual(@as(?f64, 2.0), mixer.positionFrames(handle));
    mixer.setPaused(handle, false);
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.75, 1.0 }, &out);
}

test "mixer: voices sum, clip and report peak and clipped samples" {
    const gpa = testing.allocator;
    const loud = [_]f32{ 0.8, 0.8 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 4 });
    defer mixer.deinit();
    _ = try mixer.play(monoClip(&loud, 48000), .{});
    _ = try mixer.play(monoClip(&loud, 48000), .{});

    var out: [2]f32 = undefined;
    const stats = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 1.0 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.6), stats.peak, 1e-6);
    try testing.expectEqual(@as(usize, 2), stats.clipped_samples);
    try testing.expectEqual(@as(usize, 0), stats.non_finite_samples);

    // With clamping disabled the unclamped sum reaches the caller.
    var raw = try Mixer.init(gpa, .{ .channels = 1, .clamp_output = false });
    defer raw.deinit();
    _ = try raw.play(monoClip(&loud, 48000), .{});
    _ = try raw.play(monoClip(&loud, 48000), .{});
    const raw_stats = try raw.render(&out);
    try testing.expectApproxEqAbs(@as(f32, 1.6), out[0], 1e-6);
    try testing.expectEqual(@as(usize, 2), raw_stats.clipped_samples);
}

test "mixer: non-finite samples are sanitized at the output stage" {
    const gpa = testing.allocator;
    const poisoned = [_]f32{ std.math.nan(f32), 0.5, std.math.inf(f32), -std.math.inf(f32) };
    var mixer = try Mixer.init(gpa, .{ .channels = 1 });
    defer mixer.deinit();
    _ = try mixer.play(monoClip(&poisoned, 48000), .{});

    var out: [4]f32 = undefined;
    const stats = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0.5, 0, 0 }, &out);
    try testing.expectEqual(@as(usize, 3), stats.non_finite_samples);
    for (out) |sample| try testing.expect(std.math.isFinite(sample));
}

test "mixer: routing a voice to another bus takes effect immediately" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_buses = 2 });
    defer mixer.deinit();
    try mixer.setBusGain(1, 0.25);

    const handle = try mixer.play(monoClip(&samples, 48000), .{});
    var out: [2]f32 = undefined;
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 1.0 }, &out);
    try mixer.setBus(handle, 1);
    _ = try mixer.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.25, 0.25 }, &out);
    try testing.expectEqual(@as(?f32, 0.25), mixer.busGain(1));
}

test "mixer: rendering is deterministic and allocation free" {
    const gpa = testing.allocator;
    const a = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6 };
    const b = [_]f32{ -0.5, 0.25, 0.75 };
    const b_stereo = [_]f32{ -0.5, 0.25, 0.75, -0.125 };

    // Two independent mixers driven by the same call sequence must agree bit
    // for bit, and rendering must not allocate (the API takes no allocator).
    var first = try Mixer.init(gpa, .{ .channels = 2, .sample_rate = 48000 });
    defer first.deinit();
    var second = try Mixer.init(gpa, .{ .channels = 2, .sample_rate = 48000 });
    defer second.deinit();

    for ([_]*Mixer{ &first, &second }) |mixer| {
        _ = try mixer.play(monoClip(&a, 44100), .{ .gain = 0.7, .pan = -0.3, .looping = true });
        _ = try mixer.play(stereoClip(&b_stereo, 22050), .{ .gain = 0.4, .pan = 0.6 });
        _ = try mixer.play(monoClip(&b, 96000), .{ .pitch = 1.5 });
    }

    var out_a: [64]f32 = undefined;
    var out_b: [64]f32 = undefined;
    var block: usize = 0;
    while (block < 32) : (block += 1) {
        const sa = try first.render(&out_a);
        const sb = try second.render(&out_b);
        try testing.expectEqualSlices(f32, &out_a, &out_b);
        try testing.expectEqual(sa.voices_active, sb.voices_active);
        try testing.expectEqual(sa.voices_finished, sb.voices_finished);
        try testing.expectEqual(sa.peak, sb.peak);
        for (out_a) |sample| try testing.expect(std.math.isFinite(sample));
    }
    // `testing.allocator` is leak-checked: nothing above may retain memory.
}

test "mixer: a full pool renders every voice in slot order" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.125, 0.125, 0.125, 0.125 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 8 });
    defer mixer.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try mixer.play(monoClip(&samples, 48000), .{});
    }
    var out: [4]f32 = undefined;
    const stats = try mixer.render(&out);
    for (out) |sample| try testing.expectEqual(@as(f32, 1.0), sample); // 8 * 0.125
    try testing.expectEqual(@as(usize, 8), stats.voices_finished);
    try testing.expectEqual(@as(usize, 0), mixer.liveVoices());

    // Every slot is reusable after the batch finished.
    i = 0;
    while (i < 8) : (i += 1) {
        _ = try mixer.play(monoClip(&samples, 48000), .{});
    }
    try testing.expectEqual(@as(usize, 8), mixer.liveVoices());
}

test "mixer: stereo and surround clips resample on every channel" {
    const gpa = testing.allocator;
    // 24 kHz stereo -> 48 kHz stereo: midpoints on both channels.
    const stereo = [_]f32{ 0.0, 1.0, 0.5, -1.0 };
    var up = try Mixer.init(gpa, .{ .channels = 2, .sample_rate = 48000, .pan_law = .linear });
    defer up.deinit();
    _ = try up.play(stereoClip(&stereo, 24000), .{});
    var out: [6]f32 = undefined;
    _ = try up.render(&out);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.0, 1.0, 0.25, 0.0, 0.5, -1.0 }, &out);

    // 24 kHz 6-channel -> 48 kHz mono: the mean is interpolated per channel.
    const six = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var many = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000 });
    defer many.deinit();
    _ = try many.play(.{ .sample_rate = 24000, .channels = 6, .frames = 2, .samples = &six }, .{});
    var mono_out: [3]f32 = undefined;
    _ = try many.render(&mono_out);
    // Frame 0 sums to 2, frame 1 to 0; the mean is interpolated per channel.
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 6.0), mono_out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 6.0), mono_out[1], 1e-6);
    try testing.expectEqual(@as(f32, 0), mono_out[2]);
}

test "mixer: a slot whose generation would wrap is retired, never reused" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.5, 0.5 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 2 });
    defer mixer.deinit();

    const first = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(@as(u32, 0), first.index);
    // White-box: drive the slot to the last usable generation.
    mixer.voices[first.index].generation = retired_generation - 1;
    const last = VoiceHandle{ .index = first.index, .generation = retired_generation - 1 };
    try testing.expect(mixer.isLive(last));
    mixer.stop(last);
    try testing.expect(!mixer.isLive(last));
    try testing.expectEqual(retired_generation, mixer.voices[first.index].generation);

    // The retired slot is not handed out again; the other slot is.
    const other = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(@as(u32, 1), other.index);
    try testing.expectError(error.NoVoiceAvailable, mixer.play(monoClip(&samples, 48000), .{}));
    // A handle forged at the retired generation is still inert.
    const forged = VoiceHandle{ .index = first.index, .generation = retired_generation };
    try testing.expect(!mixer.isLive(forged));
}

test "mixer: the default policy refuses a full pool and never steals" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.5, 0.5 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 2 });
    defer mixer.deinit();

    const a = try mixer.play(monoClip(&samples, 48000), .{ .looping = true, .priority = 0 });
    _ = try mixer.play(monoClip(&samples, 48000), .{ .looping = true, .priority = 0 });
    try testing.expectError(error.NoVoiceAvailable, mixer.play(monoClip(&samples, 48000), .{ .priority = 255 }));
    try testing.expectEqual(@as(u64, 0), mixer.stolenCount());
    try testing.expect(mixer.isLive(a));
    try testing.expectEqual(@as(?Termination, null), mixer.terminationOf(a));
}

test "mixer: lowest-priority stealing recycles the least important voice" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.5, 0.5 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 2, .steal_policy = .lowest_priority });
    defer mixer.deinit();

    const music = try mixer.play(monoClip(&samples, 48000), .{ .looping = true, .priority = 200 });
    const ambience = try mixer.play(monoClip(&samples, 48000), .{ .looping = true, .priority = 10 });

    const shot = try mixer.play(monoClip(&samples, 48000), .{ .looping = true, .priority = 128 });
    try testing.expect(!mixer.isLive(ambience));
    try testing.expect(mixer.isLive(music));
    try testing.expect(mixer.isLive(shot));
    try testing.expectEqual(@as(u64, 1), mixer.stolenCount());
    // The stolen slot is reused, and the reason is still attributable.
    try testing.expectEqual(ambience.index, shot.index);
    try testing.expectEqual(@as(?Termination, .stolen), mixer.terminationOf(ambience));
    try testing.expectEqual(@as(usize, 2), mixer.liveVoices());

    // A request below every live voice cannot steal anything.
    try testing.expectError(error.NoVoiceAvailable, mixer.play(monoClip(&samples, 48000), .{ .priority = 5 }));
    try testing.expectEqual(@as(u64, 1), mixer.stolenCount());

    // Opting out of stealing fails even when a victim exists.
    try testing.expectError(error.NoVoiceAvailable, mixer.play(monoClip(&samples, 48000), .{
        .priority = 255,
        .allow_steal = false,
    }));
    try testing.expectEqual(@as(u64, 1), mixer.stolenCount());
}

test "mixer: equal priority steals the oldest voice, deterministically" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.5, 0.5 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 3, .steal_policy = .lowest_priority });
    defer mixer.deinit();

    const first = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    const second = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    const third = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });

    const fourth = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(first.index, fourth.index);
    try testing.expect(!mixer.isLive(first));
    try testing.expect(mixer.isLive(second));
    try testing.expect(mixer.isLive(third));

    // The next steal takes the next-oldest, not the just-started voice.
    const fifth = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(second.index, fifth.index);
    try testing.expect(mixer.isLive(fourth));
    try testing.expectEqual(@as(u64, 2), mixer.stolenCount());

    // A paused voice still holds a slot and is stealable.
    mixer.setPaused(third, true);
    const sixth = try mixer.play(monoClip(&samples, 48000), .{});
    try testing.expectEqual(third.index, sixth.index);
    try testing.expectEqual(@as(?Termination, .stolen), mixer.terminationOf(third));
}

test "mixer: termination reasons distinguish stop, finish and steal" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.25, 0.25 };
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 1, .steal_policy = .lowest_priority });
    defer mixer.deinit();

    // Natural end.
    const one_shot = try mixer.play(monoClip(&samples, 48000), .{});
    var out: [2]f32 = undefined;
    _ = try mixer.render(&out);
    try testing.expectEqual(@as(?Termination, .finished), mixer.terminationOf(one_shot));

    // Explicit stop, and the record survives the slot being reused.
    const looping = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    mixer.stop(looping);
    try testing.expectEqual(@as(?Termination, .stopped), mixer.terminationOf(looping));
    const reused = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    try testing.expectEqual(looping.index, reused.index);
    try testing.expectEqual(@as(?Termination, .stopped), mixer.terminationOf(looping));
    try testing.expectEqual(@as(?Termination, null), mixer.terminationOf(reused));

    // A steal records the new occupancy's termination; the slot keeps only the
    // most recent record, so the older handle's reason is no longer available.
    const stealer = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
    try testing.expectEqual(@as(?Termination, .stolen), mixer.terminationOf(reused));
    try testing.expectEqual(@as(?Termination, null), mixer.terminationOf(looping));
    try testing.expect(mixer.isLive(stealer));

    // Unknown handles have no record.
    try testing.expectEqual(@as(?Termination, null), mixer.terminationOf(VoiceHandle.invalid));
    try testing.expectEqual(@as(?Termination, null), mixer.terminationOf(.{ .index = 99, .generation = 0 }));
}

fn sineClip(gpa: Allocator, frames: usize, rate: f64, freq: f64) ![]f32 {
    const buf = try gpa.alloc(f32, frames);
    for (buf, 0..) |*v, i| {
        v.* = @floatCast(@sin(2.0 * std.math.pi * freq * @as(f64, @floatFromInt(i)) / rate));
    }
    return buf;
}

test "mixer: band-limited resampling removes the aliasing of a 2:1 downsample" {
    const gpa = testing.allocator;
    // 16 kHz at 48 kHz is above the 12 kHz Nyquist of the 24 kHz output.
    const src = try sineClip(gpa, 2048, 48000, 16000);
    defer gpa.free(src);

    var linear = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 24000, .max_voices = 1 });
    defer linear.deinit();
    var sinc = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 24000, .max_voices = 1, .resample = .sinc });
    defer sinc.deinit();
    _ = try linear.play(monoClip(src, 48000), .{});
    _ = try sinc.play(monoClip(src, 48000), .{});

    var linear_out: [512]f32 = undefined;
    var sinc_out: [512]f32 = undefined;
    _ = try linear.render(&linear_out);
    _ = try sinc.render(&sinc_out);

    // Skip the head, where the filter reads clamped edge samples.
    var linear_peak: f32 = 0;
    var sinc_peak: f32 = 0;
    for (linear_out[64..], sinc_out[64..]) |l, value| {
        linear_peak = @max(linear_peak, @abs(l));
        sinc_peak = @max(sinc_peak, @abs(value));
    }
    try testing.expect(linear_peak > 0.8);
    try testing.expect(sinc_peak < 0.2);
    try testing.expect(sinc_peak < linear_peak * 0.25);
}

test "mixer: band-limited resampling keeps DC and passband content intact" {
    const gpa = testing.allocator;
    var dc: [64]f32 = @splat(0.5);
    var dc_mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 44100, .max_voices = 1, .resample = .sinc });
    defer dc_mixer.deinit();
    _ = try dc_mixer.play(monoClip(&dc, 48000), .{});
    var dc_out: [32]f32 = undefined;
    _ = try dc_mixer.render(&dc_out);
    for (dc_out) |value| try testing.expectApproxEqAbs(@as(f32, 0.5), value, 1e-5);

    // A 1 kHz tone is far below the cutoff, so decimating 2:1 must preserve it.
    const src = try sineClip(gpa, 1024, 48000, 1000);
    defer gpa.free(src);
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 24000, .max_voices = 1, .resample = .sinc });
    defer mixer.deinit();
    _ = try mixer.play(monoClip(src, 48000), .{});
    var out: [256]f32 = undefined;
    _ = try mixer.render(&out);
    for (out[32..], 32..) |value, i| {
        const expected: f32 = @floatCast(@sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 24000.0));
        try testing.expectApproxEqAbs(expected, value, 5e-3);
    }
}

test "mixer: band-limited mode keeps the unit-rate fast path bit-exact" {
    const gpa = testing.allocator;
    const samples = [_]f32{ 0.25, -0.5, 0.125, 0.75, -0.25, 0.5 };
    var linear = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 1 });
    defer linear.deinit();
    var sinc = try Mixer.init(gpa, .{ .channels = 1, .max_voices = 1, .resample = .sinc });
    defer sinc.deinit();
    _ = try linear.play(monoClip(&samples, 48000), .{ .looping = true });
    _ = try sinc.play(monoClip(&samples, 48000), .{ .looping = true });

    var linear_out: [16]f32 = undefined;
    var sinc_out: [16]f32 = undefined;
    _ = try linear.render(&linear_out);
    _ = try sinc.render(&sinc_out);
    // Same rate and an integral cursor: both take the copy path, bit for bit.
    try testing.expectEqualSlices(f32, &linear_out, &sinc_out);

    // A fractional pitch leaves the fast path, and then the two modes differ.
    const linear_voice = linear.voices[0];
    const sinc_voice = sinc.voices[0];
    try linear.setPitch(.{ .index = 0, .generation = linear_voice.generation }, 1.5);
    try sinc.setPitch(.{ .index = 0, .generation = sinc_voice.generation }, 1.5);
    _ = try linear.render(&linear_out);
    _ = try sinc.render(&sinc_out);
    var differs = false;
    for (linear_out, sinc_out) |l, value| {
        try testing.expect(std.math.isFinite(value));
        if (l != value) differs = true;
    }
    try testing.expect(differs);
}

test "mixer: band-limited resampling is continuous across a loop boundary" {
    const gpa = testing.allocator;
    // Four whole cycles over 64 frames, so the clip tiles seamlessly.
    const frames = 64;
    const src = try gpa.alloc(f32, frames);
    defer gpa.free(src);
    for (src, 0..) |*v, i| {
        v.* = @floatCast(@sin(2.0 * std.math.pi * 4.0 * @as(f64, @floatFromInt(i)) / @as(f64, frames)));
    }

    var mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 48000, .max_voices = 1, .resample = .sinc });
    defer mixer.deinit();
    _ = try mixer.play(monoClip(src, 24000), .{ .looping = true });

    // 256 output frames at step 0.5 cover two full loops.
    var out: [256]f32 = undefined;
    _ = try mixer.render(&out);
    for (out, 0..) |value, i| {
        const pos = 0.5 * @as(f64, @floatFromInt(i));
        const expected: f32 = @floatCast(@sin(2.0 * std.math.pi * 4.0 * pos / @as(f64, frames)));
        try testing.expectApproxEqAbs(expected, value, 5e-3);
    }
}

test "mixer: band-limited resampling filters every channel independently" {
    const gpa = testing.allocator;
    // Stereo: left is a constant, right its negation.
    const stereo = try gpa.alloc(f32, 256);
    defer gpa.free(stereo);
    for (0..128) |i| {
        stereo[i * 2] = 0.5;
        stereo[i * 2 + 1] = -0.5;
    }
    // Linear pan law at center is unity on both channels, so the assertions
    // below measure the filter rather than the pan attenuations.
    var mixer = try Mixer.init(gpa, .{ .sample_rate = 44100, .max_voices = 1, .resample = .sinc, .pan_law = .linear });
    defer mixer.deinit();
    _ = try mixer.play(stereoClip(stereo, 48000), .{});
    var out: [64]f32 = undefined;
    _ = try mixer.render(&out);
    var i: usize = 0;
    while (i < out.len) : (i += 2) {
        try testing.expectApproxEqAbs(@as(f32, 0.5), out[i], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, -0.5), out[i + 1], 1e-5);
    }

    // Surround to mono still averages the channels, now after filtering.
    const surround = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.4 };
    var mono = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 32000, .max_voices = 1, .resample = .sinc });
    defer mono.deinit();
    _ = try mono.play(.{ .sample_rate = 48000, .channels = 4, .frames = 4, .samples = &surround }, .{});
    var mono_out: [2]f32 = undefined;
    _ = try mono.render(&mono_out);
    for (mono_out) |value| try testing.expectApproxEqAbs(@as(f32, 0.25), value, 1e-5);
}

test "mixer: band-limited rendering is deterministic and allocation free" {
    const gpa = testing.allocator;
    const src = try sineClip(gpa, 512, 48000, 5000);
    defer gpa.free(src);

    var first = try Mixer.init(gpa, .{ .sample_rate = 44100, .max_voices = 2, .resample = .sinc });
    defer first.deinit();
    var second = try Mixer.init(gpa, .{ .sample_rate = 44100, .max_voices = 2, .resample = .sinc });
    defer second.deinit();
    for ([_]*Mixer{ &first, &second }) |mixer| {
        _ = try mixer.play(monoClip(src, 48000), .{ .looping = true, .pan = -0.4 });
        _ = try mixer.play(monoClip(src, 32000), .{ .looping = true, .pan = 0.7, .pitch = 1.25 });
    }

    var a: [128]f32 = undefined;
    var b: [128]f32 = undefined;
    for (0..4) |_| {
        const stats_a = try first.render(&a);
        const stats_b = try second.render(&b);
        try testing.expectEqualSlices(f32, &a, &b);
        try testing.expectEqual(stats_a.peak, stats_b.peak);
        try testing.expectEqual(@as(usize, 2), stats_a.voices_active);
    }
    // Rendering must not allocate: the table was built once at init.
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator) !void {
            const samples = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
            var mixer = try Mixer.init(alloc, .{ .sample_rate = 44100, .resample = .sinc });
            defer mixer.deinit();
            _ = try mixer.play(monoClip(&samples, 48000), .{ .looping = true });
            var out: [32]f32 = undefined;
            _ = try mixer.render(&out);
        }
    }.f, .{});
}

test "mixer: an integer step reuses the kernel and still tracks the loop wrap" {
    const gpa = testing.allocator;
    const frames = 64;
    const src = try gpa.alloc(f32, frames);
    defer gpa.free(src);
    for (src, 0..) |*v, i| {
        v.* = @floatCast(@sin(2.0 * std.math.pi * 4.0 * @as(f64, @floatFromInt(i)) / @as(f64, frames)));
    }

    // Step 2.0 keeps the fractional cursor at exactly 0, so every frame after
    // the first reuses the cached kernel and only relocates its start index.
    var mixer = try Mixer.init(gpa, .{ .channels = 1, .sample_rate = 24000, .max_voices = 1, .resample = .sinc });
    defer mixer.deinit();
    _ = try mixer.play(monoClip(src, 48000), .{ .looping = true });

    var out: [128]f32 = undefined;
    _ = try mixer.render(&out);
    for (out, 0..) |value, i| {
        // At an integral cursor the prototype is a delta, so the output is the
        // source sample itself -- across four passes of the loop boundary.
        const index = (i * 2) % frames;
        try testing.expectApproxEqAbs(src[index], value, 1e-5);
    }
}
