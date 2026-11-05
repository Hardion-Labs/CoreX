//! CoreXEngine audio subsystem — device-independent playback runtime.
//!
//! This is the audio counterpart of `corex.render`: pure CPU work with no device
//! dependency, so it is fully testable headlessly and deterministic. It mixes
//! borrowed float32 clips into an interleaved output buffer with gain, pan,
//! buses, pitch, looping and resampling (linear by default, band-limited
//! windowed-sinc on request). When the voice pool is full, an optional
//! priority-based steal policy recycles the least important voice. The OS audio
//! backends (ALSA/WASAPI/CoreAudio) are **planned**; this layer defines the
//! contract they will consume — `render` fills a buffer, `toPcm16` converts it to
//! the format most devices accept.
//!
//! Clips come from the asset pipeline: a `CXAW` artifact parsed with
//! `corex.assets.audio.parse` maps to `corex.audio.Clip` field by field. The
//! mixer itself does not import the asset layer, so the two stay independently
//! testable and loosely coupled.
//!
//! Two layers sit on top of the mixer:
//! - `spatial` is pure math (listener basis, distance attenuation, azimuth pan,
//!   Doppler, 2D/3D blend) with no mixer or ECS dependency.
//! - `system` bridges a scene to the mixer: `AudioSource` is a plain-data
//!   component and `AudioSystem.update` reconciles emitters into voices using
//!   the scene's world-transform snapshot. Coupling is one-way — the mixer and
//!   the scene know nothing about it. See `docs/audio-spatial.md`.
//!
//! Example:
//! ```zig
//! const corex = @import("corex");
//! const A = corex.audio;
//! var mixer = try A.Mixer.init(gpa, .{ .sample_rate = 48_000, .channels = 2 });
//! defer mixer.deinit();
//!
//! // `view` is a parsed CXAW artifact; its samples must outlive the voice.
//! const voice = try mixer.play(.{
//!     .sample_rate = view.sample_rate,
//!     .channels = view.channels,
//!     .frames = view.frames,
//!     .samples = samples_f32,
//! }, .{ .gain = 0.8, .pan = -0.25, .looping = true, .bus = 1 });
//!
//! try mixer.setBusGain(1, 0.5); // music bus
//! var buffer: [512 * 2]f32 = undefined;
//! const stats = try mixer.render(&buffer); // allocation free
//! // stats.peak / .clipped_samples / .voices_active / .voices_finished
//! mixer.stop(voice);
//! ```
//!
//! See `docs/audio-mixer.md` for the mixing contract, channel/pan rules,
//! guarantees and limitations, and `docs/audio-spatial.md` for the spatial layer
//! and the scene bridge.

const std = @import("std");

/// Clip descriptors, channel-layout mapping, pan laws and PCM16 conversion.
pub const clip = @import("audio/clip.zig");
/// The voice pool, buses and the allocation-free mixing core.
pub const mixer = @import("audio/mixer.zig");
/// Spatialization math: listener basis, distance attenuation, pan and Doppler.
pub const spatial = @import("audio/spatial.zig");
/// Scene-driven audio: the `AudioSource` component and the voice reconciler.
pub const system = @import("audio/system.zig");
/// Band-limited (windowed-sinc) resampling prototype and kernels.
pub const resample = @import("audio/resample.zig");

pub const Mixer = mixer.Mixer;
pub const VoiceHandle = mixer.VoiceHandle;
pub const State = mixer.State;
pub const Config = mixer.Config;
pub const PlayOptions = mixer.PlayOptions;
pub const RenderStats = mixer.RenderStats;
pub const StealPolicy = mixer.StealPolicy;
pub const Termination = mixer.Termination;
pub const Resample = mixer.Resample;

pub const AudioSource = system.AudioSource;
pub const AudioSystem = system.AudioSystem;
pub const AudioSystemConfig = system.Config;
pub const AudioUpdateStats = system.Stats;

pub const Listener = spatial.Listener;
pub const Attenuation = spatial.Attenuation;
pub const Doppler = spatial.Doppler;
pub const SpatialParams = spatial.Params;
pub const SpatialResult = spatial.SpatialResult;
pub const spatialize = spatial.spatialize;
pub const dopplerScale = spatial.dopplerScale;
pub const panFor = spatial.panFor;

pub const Clip = clip.Clip;
pub const ChannelMap = clip.ChannelMap;
pub const PanLaw = clip.PanLaw;
pub const panGains = clip.panGains;
pub const toPcm16 = clip.toPcm16;

pub const min_pitch = mixer.min_pitch;
pub const max_pitch = mixer.max_pitch;
pub const max_sample_rate = clip.max_sample_rate;

test {
    std.testing.refAllDecls(@This());
    _ = clip;
    _ = mixer;
    _ = spatial;
    _ = system;
    _ = resample;
}
