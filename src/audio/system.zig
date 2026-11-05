//! Scene-driven audio: the bridge from the ECS/scene to the mixer.
//!
//! This is the audio counterpart of `render/draw.zig`. Given a scene (any
//! `Scene(schema)` carrying `AudioSource`) and a `Listener`, `AudioSystem.update`
//! reconciles the scene with the mixer's voices: it starts voices for sources
//! that began playing, spatializes every live voice against the listener,
//! restarts a voice whose clip handle changed, and stops voices whose source
//! stopped playing, lost its component or whose entity was destroyed.
//!
//! Coupling is deliberately one-way: this module knows the scene's transform
//! math and the mixer, but neither the mixer nor the scene knows about it. The
//! mixer stays usable without any scene, and `AudioSource` is a plain-data
//! component that serializes like `Renderable`.
//!
//! Ownership: the system **borrows** the mixer (the caller owns it) and owns only
//! its entity-to-voice map. `deinit` stops the voices it started, so destroying
//! the system never leaves orphan voices behind.
//!
//! Transport semantics (documented because they decide replay behavior):
//! - `playing` is a **request**, and the system never writes to the scene.
//! - A source starts when `playing` is true and it has no voice yet.
//! - A non-looping voice that reaches its end is reported once in
//!   `Stats.finished` and is **not** restarted while `playing` stays true; the
//!   caller toggles `playing` off and on to replay. This keeps one-shots from
//!   accidentally becoming loops and keeps scene documents byte-stable.
//! - Setting `playing` false stops the voice and forgets the source.

const std = @import("std");
const spatial = @import("spatial.zig");
const mixer_mod = @import("mixer.zig");
const clip_mod = @import("clip.zig");
const transform = @import("../scene/transform.zig");
const ecs = @import("../ecs.zig");

const Allocator = std.mem.Allocator;
const Entity = ecs.Entity;

pub const Clip = clip_mod.Clip;
pub const Mixer = mixer_mod.Mixer;
pub const VoiceHandle = mixer_mod.VoiceHandle;
pub const Listener = spatial.Listener;
pub const Attenuation = spatial.Attenuation;
pub const Vec3 = spatial.Vec3;

/// A sound emitter as a plain-data scene component. Add it to a schema with
/// `Component(AudioSource, "audio_source")`; it serializes like any component.
///
/// `clip` is an **opaque handle** into the caller's clip table (the same pattern
/// `Renderable.mesh` uses): resolving asset ids to decoded `CXAW` buffers is the
/// asset layer's job, not the component's.
pub const AudioSource = struct {
    /// Index into the clip table passed to `AudioSystem.update`.
    clip: u32 = 0,
    /// Mixer bus this voice plays on.
    bus: u16 = 0,
    /// Linear gain applied on top of the spatial gain.
    gain: f32 = 1.0,
    /// Base playback rate; the Doppler multiplier is folded into it.
    pitch: f32 = 1.0,
    looping: bool = false,
    /// Transport request: true starts the voice, false stops it.
    playing: bool = false,
    /// 0 = 2D (unity gain, center pan), 1 = fully spatialized.
    spatial_blend: f32 = 1.0,
    attenuation: Attenuation = .{},
    /// Per-source Doppler strength; 0 disables it. The speed of sound and the
    /// pitch clamp come from `AudioSystem.Config`.
    doppler_factor: f32 = 0.0,
    /// World-space velocity used for Doppler. The caller sets it; there is no
    /// automatic differentiation from position deltas.
    velocity: Vec3 = .{ 0, 0, 0 },

    pub fn isValid(self: AudioSource) bool {
        if (!std.math.isFinite(self.gain)) return false;
        if (!std.math.isFinite(self.pitch) or self.pitch <= 0) return false;
        if (!std.math.isFinite(self.spatial_blend)) return false;
        if (self.spatial_blend < 0 or self.spatial_blend > 1) return false;
        if (!std.math.isFinite(self.doppler_factor) or self.doppler_factor < 0) return false;
        for (self.velocity) |v| if (!std.math.isFinite(v)) return false;
        return self.attenuation.isValid();
    }

    fn spatialParams(self: AudioSource, config: Config) spatial.Params {
        return .{
            .attenuation = self.attenuation,
            .doppler = .{
                .factor = self.doppler_factor,
                .speed_of_sound = config.speed_of_sound,
                .max_pitch = config.max_doppler_pitch,
            },
            .blend = self.spatial_blend,
        };
    }
};

/// World-level audio settings shared by every source.
pub const Config = struct {
    /// Speed of sound in world units per second, used for Doppler.
    speed_of_sound: f32 = 343.3,
    /// Symmetric clamp on the Doppler pitch multiplier.
    max_doppler_pitch: f32 = 2.0,
    /// Skip **starting** a voice whose spatialized gain is exactly zero (fully
    /// attenuated). A voice already playing is never culled, so a source that
    /// becomes audible again is not cut off.
    cull_silent: bool = true,

    pub fn isValid(self: Config) bool {
        return (spatial.Doppler{
            .factor = 1,
            .speed_of_sound = self.speed_of_sound,
            .max_pitch = self.max_doppler_pitch,
        }).isValid();
    }
};

/// Per-update diagnostics.
pub const Stats = struct {
    /// `AudioSource` components visited.
    sources: usize = 0,
    /// Voices started this update (including restarts after a clip change).
    started: usize = 0,
    /// Live voices whose gain/pan/pitch were refreshed.
    updated: usize = 0,
    /// Voices stopped because the source stopped playing or became invalid.
    stopped: usize = 0,
    /// Voices that reached their end since the previous update.
    finished: usize = 0,
    /// Sources not started because their spatialized gain was zero.
    culled: usize = 0,
    /// Sources that could not start because the voice pool was full.
    unplayed: usize = 0,
    /// Sources skipped for an invalid component or an out-of-range clip handle.
    invalid: usize = 0,
};

const Entry = struct {
    voice: VoiceHandle,
    clip: u32,
    /// Update tick that last saw this source; drives the stale-entry sweep.
    seen: u64,
    /// The voice reached its end; kept as a tombstone so a one-shot is not
    /// restarted while `playing` remains true.
    finished: bool,
};

pub const AudioSystem = struct {
    gpa: Allocator,
    /// Borrowed; the caller owns the mixer and must keep it alive.
    mixer: *Mixer,
    config: Config,
    voices: std.AutoHashMapUnmanaged(u64, Entry) = .{},
    tick: u64 = 0,

    /// Validate the configuration at the boundary: an out-of-range speed of
    /// sound or Doppler clamp would otherwise reach `std.math.clamp` with
    /// `min > max` inside the mixing path.
    pub fn init(gpa: Allocator, mixer: *Mixer, config: Config) error{InvalidConfig}!AudioSystem {
        if (!config.isValid()) return error.InvalidConfig;
        return .{ .gpa = gpa, .mixer = mixer, .config = config };
    }

    /// Stop every voice this system started and release the map. The borrowed
    /// mixer is left usable (its bus/master settings are untouched).
    pub fn deinit(self: *AudioSystem) void {
        self.stopAll();
        self.voices.deinit(self.gpa);
        self.* = undefined;
    }

    /// Stop every voice this system started and forget all sources. A source
    /// still marked `playing` starts again on the next update.
    pub fn stopAll(self: *AudioSystem) void {
        var it = self.voices.valueIterator();
        while (it.next()) |entry| self.mixer.stop(entry.voice);
        self.voices.clearRetainingCapacity();
    }

    /// The voice currently bound to an entity, or null. A finished one-shot keeps
    /// its (dead) handle until the source is toggled, so this can return a handle
    /// that is no longer live; check `Mixer.isLive`.
    pub fn voiceFor(self: *const AudioSystem, entity: Entity) ?VoiceHandle {
        const entry = self.voices.get(entity.key()) orelse return null;
        return entry.voice;
    }

    /// Number of tracked sources (playing, paused or finished tombstones).
    pub fn trackedCount(self: *const AudioSystem) usize {
        return self.voices.count();
    }

    /// Reconcile `scene` with the mixer as heard from `listener`.
    ///
    /// `scene` is a `*Scene(schema)` whose schema includes `AudioSource`;
    /// `clips` is the clip table indexed by `AudioSource.clip`. The world
    /// transform snapshot is computed once (the same O(n) pass the render
    /// extraction uses). Entities without a `Transform` use the identity
    /// transform, so they sound from the world origin.
    ///
    /// The only allocation is the transform snapshot plus map growth; every
    /// mixer call is allocation free. On allocation failure the scene and the
    /// voices already started remain consistent.
    pub fn update(self: *AudioSystem, scene: anytype, listener: Listener, clips: []const Clip) !Stats {
        self.tick += 1;
        var stats = Stats{};

        var wt = try scene.computeWorldTransforms(self.gpa);
        defer wt.deinit();

        var view = scene.ecsWorld().view(.{AudioSource});
        while (view.next()) |item| {
            const entity = item[0];
            // Plain data: copy the component so the mixer calls below never run
            // while holding a pointer into the ECS pool.
            const source = item[1].*;
            const key = entity.key();
            stats.sources += 1;

            if (!source.playing) {
                if (self.voices.fetchRemove(key)) |kv| {
                    self.mixer.stop(kv.value.voice);
                    stats.stopped += 1;
                }
                continue;
            }

            if (!source.isValid() or source.clip >= clips.len) {
                if (self.voices.fetchRemove(key)) |kv| {
                    self.mixer.stop(kv.value.voice);
                    stats.stopped += 1;
                }
                stats.invalid += 1;
                continue;
            }

            const world = wt.get(entity) orelse transform.identity();
            const position: Vec3 = .{ world[12], world[13], world[14] };
            const result = spatial.spatialize(listener, position, source.velocity, source.spatialParams(self.config));
            const gain = source.gain * result.gain;
            const pitch = source.pitch * result.pitch;

            if (self.voices.getPtr(key)) |entry| {
                entry.seen = self.tick;
                if (!self.mixer.isLive(entry.voice)) {
                    if (!entry.finished) {
                        entry.finished = true;
                        stats.finished += 1;
                    }
                    continue;
                }
                if (entry.clip != source.clip) {
                    // Clip changed: restart on the new clip, keeping the source.
                    self.mixer.stop(entry.voice);
                    const handle = self.startVoice(clips[source.clip], source, gain, result.pan, pitch) catch |err| {
                        _ = self.voices.remove(key);
                        countStartFailure(&stats, err);
                        continue;
                    };
                    entry.* = .{ .voice = handle, .clip = source.clip, .seen = self.tick, .finished = false };
                    stats.started += 1;
                    continue;
                }
                self.mixer.setGain(entry.voice, gain) catch {
                    stats.invalid += 1;
                    continue;
                };
                self.mixer.setPan(entry.voice, result.pan) catch {
                    stats.invalid += 1;
                    continue;
                };
                self.mixer.setPitch(entry.voice, pitch) catch {
                    stats.invalid += 1;
                    continue;
                };
                self.mixer.setLooping(entry.voice, source.looping);
                self.mixer.setBus(entry.voice, source.bus) catch {
                    stats.invalid += 1;
                    continue;
                };
                stats.updated += 1;
                continue;
            }

            if (self.config.cull_silent and gain == 0) {
                stats.culled += 1;
                continue;
            }
            const handle = self.startVoice(clips[source.clip], source, gain, result.pan, pitch) catch |err| {
                countStartFailure(&stats, err);
                continue;
            };
            // If the map cannot grow, do not leak the voice we just started.
            self.voices.put(self.gpa, key, .{
                .voice = handle,
                .clip = source.clip,
                .seen = self.tick,
                .finished = false,
            }) catch {
                self.mixer.stop(handle);
                return error.OutOfMemory;
            };
            stats.started += 1;
        }

        // Sweep sources that disappeared (entity destroyed or component
        // removed). Removal only tombstones a slot and never rehashes, so it is
        // safe while iterating as long as nothing is inserted here.
        var it = self.voices.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.seen == self.tick) continue;
            self.mixer.stop(kv.value_ptr.voice);
            self.voices.removeByPtr(kv.key_ptr);
            stats.stopped += 1;
        }
        return stats;
    }

    fn startVoice(self: *AudioSystem, clip: Clip, source: AudioSource, gain: f32, pan: f32, pitch: f32) mixer_mod.PlayError!VoiceHandle {
        return self.mixer.play(clip, .{
            .gain = gain,
            .pan = pan,
            .pitch = pitch,
            .looping = source.looping,
            .bus = source.bus,
        });
    }
};

fn countStartFailure(stats: *Stats, err: mixer_mod.PlayError) void {
    switch (err) {
        error.NoVoiceAvailable => stats.unplayed += 1,
        else => stats.invalid += 1,
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");

const TestScene = scene_mod.Scene(.{
    scene_mod.Component(components.Transform, "transform"),
    scene_mod.Component(AudioSource, "audio_source"),
});

const sample_data = [_]f32{ 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.125, -0.125 };
const other_data = [_]f32{ 0.0625, 0.0625, 0.0625, 0.0625 };

const test_clips = [_]Clip{
    .{ .sample_rate = 48000, .channels = 1, .frames = sample_data.len, .samples = &sample_data },
    .{ .sample_rate = 48000, .channels = 1, .frames = other_data.len, .samples = &other_data },
};

/// Heap-allocated so the mixer never moves: `AudioSystem` holds a pointer to it.
const Harness = struct {
    mixer: Mixer,
    system: AudioSystem,
    scene: TestScene,

    fn init(config: Config) !*Harness {
        const gpa = testing.allocator;
        const h = try gpa.create(Harness);
        errdefer gpa.destroy(h);
        h.mixer = try Mixer.init(gpa, .{
            .channels = 2,
            .sample_rate = 48000,
            .max_voices = 4,
            .pan_law = .linear,
        });
        errdefer h.mixer.deinit();
        h.scene = try TestScene.init(gpa, "audio");
        errdefer h.scene.deinit();
        h.system = try AudioSystem.init(gpa, &h.mixer, config);
        return h;
    }

    fn deinit(self: *Harness) void {
        self.system.deinit();
        self.scene.deinit();
        self.mixer.deinit();
        testing.allocator.destroy(self);
    }

    fn addSource(self: *Harness, position: Vec3, source: AudioSource) !Entity {
        const e = try self.scene.createEntity(null, null);
        try self.scene.addComponent(e, components.Transform{ .position = position });
        try self.scene.addComponent(e, source);
        return e;
    }
};

fn playingSource() AudioSource {
    return .{ .playing = true, .looping = true, .spatial_blend = 0 };
}

test "audio system: an empty scene starts nothing" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const stats = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 0), stats.sources);
    try testing.expectEqual(@as(usize, 0), stats.started);
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());
    try testing.expectEqual(@as(usize, 0), h.system.trackedCount());
}

test "audio system: init rejects an invalid configuration" {
    const gpa = testing.allocator;
    var mixer = try Mixer.init(gpa, .{});
    defer mixer.deinit();

    try testing.expectError(error.InvalidConfig, AudioSystem.init(gpa, &mixer, .{ .speed_of_sound = 0 }));
    try testing.expectError(error.InvalidConfig, AudioSystem.init(gpa, &mixer, .{ .speed_of_sound = -1 }));
    try testing.expectError(error.InvalidConfig, AudioSystem.init(gpa, &mixer, .{ .speed_of_sound = std.math.nan(f32) }));
    // A clamp below 1 would invert the clamp range inside the mixing path.
    try testing.expectError(error.InvalidConfig, AudioSystem.init(gpa, &mixer, .{ .max_doppler_pitch = 0 }));
    try testing.expectError(error.InvalidConfig, AudioSystem.init(gpa, &mixer, .{ .max_doppler_pitch = 0.5 }));
    try testing.expect(!(Config{ .max_doppler_pitch = std.math.inf(f32) }).isValid());
    try testing.expect((Config{}).isValid());

    var system = try AudioSystem.init(gpa, &mixer, .{});
    defer system.deinit();
    try testing.expectEqual(@as(usize, 0), system.trackedCount());
}

test "audio system: playing starts a voice and stopping releases it" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const e = try h.addSource(.{ 0, 0, 0 }, playingSource());
    const stats = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), stats.sources);
    try testing.expectEqual(@as(usize, 1), stats.started);
    try testing.expectEqual(@as(usize, 1), h.mixer.liveVoices());
    const voice = h.system.voiceFor(e).?;
    try testing.expect(h.mixer.isLive(voice));

    // A second update refreshes instead of restarting.
    const again = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 0), again.started);
    try testing.expectEqual(@as(usize, 1), again.updated);
    try testing.expect(h.system.voiceFor(e).?.eql(voice));

    // Toggling playing off stops the voice and forgets the source.
    h.scene.getComponent(AudioSource, e).?.playing = false;
    const stopped = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), stopped.stopped);
    try testing.expect(!h.mixer.isLive(voice));
    try testing.expectEqual(@as(?VoiceHandle, null), h.system.voiceFor(e));
    try testing.expectEqual(@as(usize, 0), h.system.trackedCount());

    // Toggling it back on starts a fresh voice.
    h.scene.getComponent(AudioSource, e).?.playing = true;
    const restarted = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), restarted.started);
    try testing.expect(!h.system.voiceFor(e).?.eql(voice));
}

test "audio system: a source that is not playing never starts" {
    const h = try Harness.init(.{});
    defer h.deinit();

    _ = try h.addSource(.{ 0, 0, 0 }, .{ .playing = false });
    const stats = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), stats.sources);
    try testing.expectEqual(@as(usize, 0), stats.started);
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());
}

test "audio system: a one-shot finishes once and is not restarted" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const e = try h.addSource(.{ 0, 0, 0 }, .{ .playing = true, .looping = false, .spatial_blend = 0 });
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const voice = h.system.voiceFor(e).?;

    // Drain the 8-frame clip.
    var out: [16]f32 = undefined;
    const rendered = try h.mixer.render(&out);
    try testing.expectEqual(@as(usize, 1), rendered.voices_finished);

    const after = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), after.finished);
    try testing.expectEqual(@as(usize, 0), after.started);
    try testing.expect(!h.mixer.isLive(voice));

    // Further updates neither report it again nor restart it.
    const quiet = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 0), quiet.finished);
    try testing.expectEqual(@as(usize, 0), quiet.started);
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());

    // Toggling replays it.
    const src = h.scene.getComponent(AudioSource, e).?;
    src.playing = false;
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    src.playing = true;
    const replay = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), replay.started);
    try testing.expect(h.mixer.isLive(h.system.voiceFor(e).?));
}

test "audio system: spatialization drives gain and pan from the world transform" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // 10 units to the listener's right, inverse attenuation with reference 1.
    const e = try h.addSource(.{ 10, 0, 0 }, .{
        .playing = true,
        .looping = true,
        .spatial_blend = 1,
        .attenuation = .{ .model = .inverse, .min_distance = 1, .max_distance = 100 },
    });
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const voice = h.system.voiceFor(e).?;
    try testing.expectApproxEqAbs(@as(f32, 0.1), h.mixer.voices[voice.index].gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), h.mixer.voices[voice.index].pan, 1e-6);

    // Move the entity to the listener's left and closer: gain and pan follow.
    h.scene.getComponent(components.Transform, e).?.position = .{ -2, 0, 0 };
    const moved = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), moved.updated);
    try testing.expectApproxEqAbs(@as(f32, 0.5), h.mixer.voices[voice.index].gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), h.mixer.voices[voice.index].pan, 1e-6);

    // A rotated listener changes the pan without moving anything.
    const turned = Listener{ .forward = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 } };
    _ = try h.system.update(&h.scene, turned, &test_clips);
    try testing.expectApproxEqAbs(@as(f32, 0), h.mixer.voices[voice.index].pan, 1e-6);
}

test "audio system: parent transforms are honored through the world snapshot" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const parent = try h.scene.createEntity(null, null);
    try h.scene.addComponent(parent, components.Transform{ .position = .{ 0, 0, 0 } });
    const child = try h.scene.createEntity(null, h.scene.idOf(parent).?);
    try h.scene.addComponent(child, components.Transform{ .position = .{ 4, 0, 0 } });
    try h.scene.addComponent(child, AudioSource{
        .playing = true,
        .looping = true,
        .attenuation = .{ .model = .inverse, .min_distance = 1, .max_distance = 100 },
    });

    h.scene.getComponent(components.Transform, parent).?.position = .{ 6, 0, 0 };
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const voice = h.system.voiceFor(child).?;
    // World position is 10 units away: gain 1/10.
    try testing.expectApproxEqAbs(@as(f32, 0.1), h.mixer.voices[voice.index].gain, 1e-6);
}

test "audio system: an entity without a Transform sounds from the origin" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const e = try h.scene.createEntity(null, null);
    try h.scene.addComponent(e, AudioSource{
        .playing = true,
        .looping = true,
        .attenuation = .{ .model = .inverse, .min_distance = 1, .max_distance = 100 },
    });
    _ = try h.system.update(&h.scene, Listener{ .position = .{ 0, 0, -4 } }, &test_clips);
    const voice = h.system.voiceFor(e).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), h.mixer.voices[voice.index].gain, 1e-6);
}

test "audio system: silent sources are culled and start when they become audible" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const e = try h.addSource(.{ 10, 0, 0 }, .{
        .playing = true,
        .looping = true,
        .attenuation = .{ .model = .linear, .min_distance = 1, .max_distance = 5 },
    });
    const culled = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), culled.culled);
    try testing.expectEqual(@as(usize, 0), culled.started);
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());

    h.scene.getComponent(components.Transform, e).?.position = .{ 2, 0, 0 };
    const audible = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 0), audible.culled);
    try testing.expectEqual(@as(usize, 1), audible.started);

    // A live voice is never culled, even when it moves out of range.
    h.scene.getComponent(components.Transform, e).?.position = .{ 100, 0, 0 };
    const far = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), far.updated);
    try testing.expectEqual(@as(usize, 0), far.culled);
    try testing.expect(h.mixer.isLive(h.system.voiceFor(e).?));

    // Disabling culling starts even fully attenuated sources.
    h.system.config.cull_silent = false;
    const e2 = try h.addSource(.{ 1000, 0, 0 }, .{
        .playing = true,
        .looping = true,
        .attenuation = .{ .model = .linear, .min_distance = 1, .max_distance = 5 },
    });
    const forced = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), forced.started);
    try testing.expect(h.mixer.isLive(h.system.voiceFor(e2).?));
}

test "audio system: changing the clip handle restarts the voice" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const e = try h.addSource(.{ 0, 0, 0 }, playingSource());
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const first = h.system.voiceFor(e).?;

    h.scene.getComponent(AudioSource, e).?.clip = 1;
    const changed = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), changed.started);
    const second = h.system.voiceFor(e).?;
    try testing.expect(!first.eql(second));
    try testing.expect(!h.mixer.isLive(first));
    try testing.expect(h.mixer.isLive(second));
    try testing.expectEqual(@as(u32, 1), h.system.voices.get(e.key()).?.clip);
}

test "audio system: gain, pitch, bus and looping changes reach the live voice" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.mixer.setBusGain(1, 0.5);

    const e = try h.addSource(.{ 0, 0, 0 }, playingSource());
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const voice = h.system.voiceFor(e).?;

    const src = h.scene.getComponent(AudioSource, e).?;
    src.gain = 0.25;
    src.pitch = 2.0;
    src.bus = 1;
    src.looping = false;
    const updated = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), updated.updated);
    try testing.expectEqual(@as(f32, 0.25), h.mixer.voices[voice.index].gain);
    try testing.expectEqual(@as(f64, 2.0), h.mixer.voices[voice.index].step);
    try testing.expectEqual(@as(u16, 1), h.mixer.voices[voice.index].bus);
    try testing.expect(!h.mixer.voices[voice.index].looping);
}

test "audio system: doppler from the component velocity folds into the pitch" {
    const h = try Harness.init(.{ .speed_of_sound = 340, .max_doppler_pitch = 2 });
    defer h.deinit();

    const e = try h.addSource(.{ 0, 0, -100 }, .{
        .playing = true,
        .looping = true,
        .spatial_blend = 1,
        .attenuation = .{ .model = .none },
        .doppler_factor = 1,
        .velocity = .{ 0, 0, 34 }, // approaching the listener
    });
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const voice = h.system.voiceFor(e).?;
    try testing.expectApproxEqAbs(@as(f64, 340.0 / 306.0), h.mixer.voices[voice.index].step, 1e-5);

    // Turning Doppler off returns the pitch to the source's base value.
    h.scene.getComponent(AudioSource, e).?.doppler_factor = 0;
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(f64, 1.0), h.mixer.voices[voice.index].step);
}

test "audio system: destroying an entity or removing the component stops its voice" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const a = try h.addSource(.{ 0, 0, 0 }, playingSource());
    const b = try h.addSource(.{ 1, 0, 0 }, playingSource());
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    const va = h.system.voiceFor(a).?;
    const vb = h.system.voiceFor(b).?;
    try testing.expectEqual(@as(usize, 2), h.mixer.liveVoices());

    h.scene.destroyEntity(a);
    const after_destroy = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), after_destroy.stopped);
    try testing.expect(!h.mixer.isLive(va));
    try testing.expect(h.mixer.isLive(vb));
    try testing.expectEqual(@as(usize, 1), h.system.trackedCount());

    h.scene.removeComponent(AudioSource, b);
    const after_remove = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), after_remove.stopped);
    try testing.expect(!h.mixer.isLive(vb));
    try testing.expectEqual(@as(usize, 0), h.system.trackedCount());
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());
}

test "audio system: invalid components and clip handles are reported, not played" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // Out-of-range clip handle.
    const bad_clip = try h.addSource(.{ 0, 0, 0 }, .{ .playing = true, .looping = true, .clip = 99 });
    const stats = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), stats.invalid);
    try testing.expectEqual(@as(usize, 0), stats.started);
    try testing.expectEqual(@as(?VoiceHandle, null), h.system.voiceFor(bad_clip));

    // An invalid component stops a voice that was already playing.
    h.scene.getComponent(AudioSource, bad_clip).?.clip = 0;
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expect(h.mixer.isLive(h.system.voiceFor(bad_clip).?));
    h.scene.getComponent(AudioSource, bad_clip).?.gain = std.math.nan(f32);
    const invalidated = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), invalidated.invalid);
    try testing.expectEqual(@as(usize, 1), invalidated.stopped);
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());

    // The component validator rejects the same values at the scene boundary.
    try testing.expect(!(AudioSource{ .pitch = 0 }).isValid());
    try testing.expect(!(AudioSource{ .spatial_blend = 1.5 }).isValid());
    try testing.expect(!(AudioSource{ .doppler_factor = -1 }).isValid());
    try testing.expect(!(AudioSource{ .velocity = .{ std.math.inf(f32), 0, 0 } }).isValid());
    try testing.expect(!(AudioSource{ .attenuation = .{ .min_distance = 0 } }).isValid());
    try testing.expect((AudioSource{}).isValid());
}

test "audio system: a full pool reports unplayed sources and recovers" {
    const h = try Harness.init(.{});
    defer h.deinit();

    var entities: [5]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = try h.addSource(.{ @floatFromInt(i), 0, 0 }, playingSource());
    }
    const stats = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 4), stats.started); // mixer capacity is 4
    try testing.expectEqual(@as(usize, 1), stats.unplayed);
    try testing.expectEqual(@as(usize, 4), h.mixer.liveVoices());

    // Freeing a slot lets the pending source start on the next update.
    h.scene.getComponent(AudioSource, entities[0]).?.playing = false;
    const recovered = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 1), recovered.stopped);
    try testing.expectEqual(@as(usize, 1), recovered.started);
    try testing.expectEqual(@as(usize, 0), recovered.unplayed);
    try testing.expect(h.mixer.isLive(h.system.voiceFor(entities[4]).?));
}

test "audio system: stopAll and deinit release every voice they started" {
    const h = try Harness.init(.{});
    defer h.deinit();

    _ = try h.addSource(.{ 0, 0, 0 }, playingSource());
    _ = try h.addSource(.{ 1, 0, 0 }, playingSource());
    _ = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 2), h.mixer.liveVoices());

    h.system.stopAll();
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());
    try testing.expectEqual(@as(usize, 0), h.system.trackedCount());
    // The borrowed mixer keeps its configuration and is reusable.
    try testing.expectEqual(@as(?f32, 1.0), h.mixer.busGain(0));

    // Sources still marked playing come back on the next update.
    const again = try h.system.update(&h.scene, Listener{}, &test_clips);
    try testing.expectEqual(@as(usize, 2), again.started);

    h.system.deinit();
    try testing.expectEqual(@as(usize, 0), h.mixer.liveVoices());
    // Re-init so the harness deinit is valid.
    h.system = try AudioSystem.init(testing.allocator, &h.mixer, .{});
}

test "audio system: AudioSource serializes and parses as a scene component" {
    const gpa = testing.allocator;
    var scene = try TestScene.init(gpa, "audio");
    defer scene.deinit();

    const e = try scene.createEntity("emitter", null);
    try scene.addComponent(e, components.Transform{ .position = .{ 1, 2, 3 } });
    try scene.addComponent(e, AudioSource{
        .clip = 7,
        .bus = 2,
        .gain = 0.5,
        .pitch = 1.25,
        .looping = true,
        .playing = true,
        .spatial_blend = 0.75,
        .attenuation = .{ .model = .exponential, .min_distance = 2, .max_distance = 50, .rolloff = 1.5 },
        .doppler_factor = 0.5,
        .velocity = .{ 1, 0, -1 },
    });

    const bytes = try scene.serialize(gpa);
    defer gpa.free(bytes);
    var restored = try TestScene.parse(gpa, bytes);
    defer restored.deinit();

    const id = scene.idOf(e).?;
    const restored_entity = restored.entityById(id).?;
    const src = restored.getComponent(AudioSource, restored_entity).?;
    try testing.expectEqual(@as(u32, 7), src.clip);
    try testing.expectEqual(@as(u16, 2), src.bus);
    try testing.expectEqual(@as(f32, 0.5), src.gain);
    try testing.expectEqual(@as(f32, 1.25), src.pitch);
    try testing.expect(src.looping and src.playing);
    try testing.expectEqual(@as(f32, 0.75), src.spatial_blend);
    try testing.expectEqual(Attenuation.Model.exponential, src.attenuation.model);
    try testing.expectEqual(@as(f32, 2), src.attenuation.min_distance);
    try testing.expectEqual(@as(f32, 50), src.attenuation.max_distance);
    try testing.expectEqual(@as(f32, 1.5), src.attenuation.rolloff);
    try testing.expectEqual(@as(f32, 0.5), src.doppler_factor);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 0, -1 }, &src.velocity);

    // Serialization is deterministic and rejects invalid components.
    const again = try scene.serialize(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    scene.getComponent(AudioSource, e).?.pitch = -1;
    try testing.expectError(error.InvalidComponent, scene.serialize(gpa));
}

test "audio system: update survives allocation failure without leaking voices" {
    const gpa = testing.allocator;
    try testing.checkAllAllocationFailures(gpa, struct {
        fn f(alloc: Allocator) !void {
            var mixer = try Mixer.init(alloc, .{ .channels = 2, .max_voices = 4 });
            defer mixer.deinit();
            var scene = try TestScene.init(alloc, "audio");
            defer scene.deinit();
            var system = try AudioSystem.init(alloc, &mixer, .{});
            defer system.deinit();

            const e = try scene.createEntity(null, null);
            try scene.addComponent(e, components.Transform{ .position = .{ 2, 0, 0 } });
            try scene.addComponent(e, AudioSource{ .playing = true, .looping = true });
            const e2 = try scene.createEntity(null, null);
            try scene.addComponent(e2, AudioSource{ .playing = true, .looping = true, .clip = 1 });

            _ = try system.update(&scene, Listener{}, &test_clips);
            _ = try system.update(&scene, Listener{}, &test_clips);
            scene.getComponent(AudioSource, e).?.playing = false;
            _ = try system.update(&scene, Listener{}, &test_clips);
        }
    }.f, .{});
}

test "audio system: two identical scenes produce identical audio" {
    const gpa = testing.allocator;
    var buffers: [2][64]f32 = undefined;

    var index: usize = 0;
    while (index < 2) : (index += 1) {
        var mixer = try Mixer.init(gpa, .{ .channels = 2, .sample_rate = 48000, .max_voices = 4 });
        defer mixer.deinit();
        var scene = try TestScene.init(gpa, "audio");
        defer scene.deinit();
        var system = try AudioSystem.init(gpa, &mixer, .{});
        defer system.deinit();

        const a = try scene.createEntity(null, null);
        try scene.addComponent(a, components.Transform{ .position = .{ 3, 0, -2 } });
        try scene.addComponent(a, AudioSource{ .playing = true, .looping = true, .gain = 0.8 });
        const b = try scene.createEntity(null, null);
        try scene.addComponent(b, components.Transform{ .position = .{ -5, 1, 0 } });
        try scene.addComponent(b, AudioSource{ .playing = true, .clip = 1, .gain = 0.4, .attenuation = .{ .model = .linear } });

        const listener = Listener{ .position = .{ 0, 0, 2 }, .velocity = .{ 0, 0, -1 } };
        _ = try system.update(&scene, listener, &test_clips);
        _ = try mixer.render(&buffers[index]);
    }
    try testing.expectEqualSlices(f32, &buffers[0], &buffers[1]);
}
