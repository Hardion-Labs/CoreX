//! End-to-end integration: WAV source -> CXAW artifact -> mixer -> PCM16.
//!
//! This lives in its own file because it is the only place that needs both the
//! asset layer and the audio runtime. Keeping the dependency here (instead of
//! inside `audio/mixer.zig`) is what lets the mixer stay independent of the
//! import pipeline: the mixer only ever sees a plain `Clip`.

const std = @import("std");
const assets = @import("../assets.zig");
const audio = @import("../audio.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const vectors = @import("../assets/audio_vectors.zig");

const testing = std.testing;

fn findVector(name: []const u8) !vectors.Wav {
    for (vectors.valid) |vector| {
        if (std.mem.eql(u8, vector.name, name)) return vector;
    }
    return error.MissingVector;
}

/// Import a WAV fixture and return the owned artifact bytes.
fn importFixture(gpa: std.mem.Allocator, vector: vectors.Wav) ![]u8 {
    const source = try gpa.alloc(u8, vector.wav_hex.len / 2);
    defer gpa.free(source);
    _ = try std.fmt.hexToBytes(source, vector.wav_hex);
    return assets.audio.importWav(gpa, source);
}

/// Copy the artifact's little-endian f32 payload into an aligned sample buffer.
fn samplesOf(gpa: std.mem.Allocator, view: assets.AudioView) ![]f32 {
    const samples = try gpa.alloc(f32, view.sampleCount());
    for (samples, 0..) |*sample, i| sample.* = view.sampleAt(i);
    return samples;
}

test "audio integration: a CXAW artifact plays back bit-exactly at unity gain" {
    const gpa = testing.allocator;
    const vector = try findVector("pcm16_mono");
    const artifact = try importFixture(gpa, vector);
    defer gpa.free(artifact);
    const view = try assets.audio.parse(artifact);
    const samples = try samplesOf(gpa, view);
    defer gpa.free(samples);

    var mixer = try audio.Mixer.init(gpa, .{
        .sample_rate = view.sample_rate,
        .channels = 1,
    });
    defer mixer.deinit();

    const voice = try mixer.play(.{
        .sample_rate = view.sample_rate,
        .channels = view.channels,
        .frames = view.frames,
        .samples = samples,
    }, .{});
    try testing.expect(mixer.isLive(voice));

    // Render two extra frames so the one-shot's end and silence tail are covered.
    const out = try gpa.alloc(f32, view.frames + 2);
    defer gpa.free(out);
    const stats = try mixer.render(out);
    try testing.expectEqualSlices(f32, samples, out[0..view.frames]);
    try testing.expectEqual(@as(f32, 0), out[view.frames]);
    try testing.expectEqual(@as(f32, 0), out[view.frames + 1]);
    try testing.expectEqual(@as(usize, 1), stats.voices_finished);
    try testing.expect(!mixer.isLive(voice));
    try testing.expectApproxEqAbs(view.durationSeconds(), @as(f64, @floatFromInt(view.frames)) /
        @as(f64, @floatFromInt(view.sample_rate)), 1e-15);
}

test "audio integration: a stereo CXAW artifact keeps both channels intact" {
    const gpa = testing.allocator;
    const vector = try findVector("pcm16_stereo");
    const artifact = try importFixture(gpa, vector);
    defer gpa.free(artifact);
    const view = try assets.audio.parse(artifact);
    const samples = try samplesOf(gpa, view);
    defer gpa.free(samples);

    var mixer = try audio.Mixer.init(gpa, .{
        .sample_rate = view.sample_rate,
        .channels = 2,
        .pan_law = .linear, // unity at the center, so the comparison is exact
    });
    defer mixer.deinit();
    _ = try mixer.play(.{
        .sample_rate = view.sample_rate,
        .channels = view.channels,
        .frames = view.frames,
        .samples = samples,
    }, .{});

    const out = try gpa.alloc(f32, view.sampleCount());
    defer gpa.free(out);
    _ = try mixer.render(out);
    try testing.expectEqualSlices(f32, samples, out);
}

test "audio integration: halving the output rate resamples the artifact" {
    const gpa = testing.allocator;
    const vector = try findVector("pcm16_mono");
    const artifact = try importFixture(gpa, vector);
    defer gpa.free(artifact);
    const view = try assets.audio.parse(artifact);
    const samples = try samplesOf(gpa, view);
    defer gpa.free(samples);

    var mixer = try audio.Mixer.init(gpa, .{
        .sample_rate = view.sample_rate / 2,
        .channels = 1,
    });
    defer mixer.deinit();
    _ = try mixer.play(.{
        .sample_rate = view.sample_rate,
        .channels = view.channels,
        .frames = view.frames,
        .samples = samples,
    }, .{});

    const frames = view.frames / 2;
    const out = try gpa.alloc(f32, frames);
    defer gpa.free(out);
    _ = try mixer.render(out);
    // A 2:1 step lands on whole source frames: every other sample, exactly.
    for (out, 0..) |value, i| try testing.expectEqual(samples[i * 2], value);
}

test "audio integration: a mixed buffer converts to PCM16 within one LSB" {
    const gpa = testing.allocator;
    const vector = try findVector("pcm16_stereo");
    const artifact = try importFixture(gpa, vector);
    defer gpa.free(artifact);
    const view = try assets.audio.parse(artifact);
    const samples = try samplesOf(gpa, view);
    defer gpa.free(samples);

    var mixer = try audio.Mixer.init(gpa, .{
        .sample_rate = view.sample_rate,
        .channels = 2,
        .pan_law = .linear,
    });
    defer mixer.deinit();
    const voice = try mixer.play(.{
        .sample_rate = view.sample_rate,
        .channels = view.channels,
        .frames = view.frames,
        .samples = samples,
    }, .{ .looping = true });
    try mixer.setGain(voice, 0.5);

    var buffer: [64]f32 = undefined;
    var pcm: [64]i16 = undefined;
    _ = try mixer.render(&buffer);
    try audio.toPcm16(&pcm, &buffer);
    for (buffer, pcm) |value, quantized| {
        const back = @as(f32, @floatFromInt(quantized)) / 32768.0;
        try testing.expectApproxEqAbs(value, back, 1.0 / 32768.0);
    }
}

test "audio integration: a scene emitter plays a CXAW clip with spatial gain" {
    const gpa = testing.allocator;
    const vector = try findVector("pcm16_mono");
    const artifact = try importFixture(gpa, vector);
    defer gpa.free(artifact);
    const view = try assets.audio.parse(artifact);
    const samples = try samplesOf(gpa, view);
    defer gpa.free(samples);

    const clips = [_]audio.Clip{.{
        .sample_rate = view.sample_rate,
        .channels = view.channels,
        .frames = view.frames,
        .samples = samples,
    }};

    const Scene = scene_mod.Scene(.{
        scene_mod.Component(components.Transform, "transform"),
        scene_mod.Component(audio.AudioSource, "audio_source"),
    });
    var scene = try Scene.init(gpa, "world");
    defer scene.deinit();
    var mixer = try audio.Mixer.init(gpa, .{
        .sample_rate = view.sample_rate,
        .channels = 2,
        .pan_law = .linear,
    });
    defer mixer.deinit();
    var system = try audio.AudioSystem.init(gpa, &mixer, .{});
    defer system.deinit();

    // Two units straight ahead: inverse attenuation gives exactly 0.5 and the
    // pan is centered, so both output channels are the source scaled by 0.5.
    const emitter = try scene.createEntity("emitter", null);
    try scene.addComponent(emitter, components.Transform{ .position = .{ 0, 0, -2 } });
    try scene.addComponent(emitter, audio.AudioSource{
        .playing = true,
        .looping = true,
        .attenuation = .{ .model = .inverse, .min_distance = 1, .max_distance = 100 },
    });

    const stats = try system.update(&scene, audio.Listener{}, &clips);
    try testing.expectEqual(@as(usize, 1), stats.started);
    const voice = system.voiceFor(emitter).?;
    try testing.expect(mixer.isLive(voice));

    const out = try gpa.alloc(f32, view.frames * 2);
    defer gpa.free(out);
    _ = try mixer.render(out);
    for (0..view.frames) |frame| {
        const expected = samples[frame] * 0.5;
        try testing.expectEqual(expected, out[frame * 2]);
        try testing.expectEqual(expected, out[frame * 2 + 1]);
    }

    // Moving the emitter to the listener's left at 4 units quarters the gain and
    // pans hard left, all driven by the scene transform.
    scene.getComponent(components.Transform, emitter).?.position = .{ -4, 0, 0 };
    _ = try system.update(&scene, audio.Listener{}, &clips);
    try mixer.seek(voice, 0);
    _ = try mixer.render(out);
    for (0..view.frames) |frame| {
        try testing.expectEqual(samples[frame] * 0.25, out[frame * 2]);
        try testing.expectEqual(@as(f32, 0), out[frame * 2 + 1]);
    }

    // Clearing the transport flag silences the emitter on the next update.
    scene.getComponent(audio.AudioSource, emitter).?.playing = false;
    const stopped = try system.update(&scene, audio.Listener{}, &clips);
    try testing.expectEqual(@as(usize, 1), stopped.stopped);
    const silence = try mixer.render(out);
    try testing.expectEqual(@as(f32, 0), silence.peak);
}
