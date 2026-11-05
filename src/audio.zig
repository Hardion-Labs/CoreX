//! CoreXEngine audio subsystem — device-independent playback runtime.
//!
//! This is the audio counterpart of `corex.render`: pure CPU work with no device
//! dependency, so it is fully testable headlessly and deterministic. It mixes
//! borrowed float32 clips into an interleaved output buffer with gain, pan,
//! buses, pitch, looping and linear-interpolated resampling. The OS audio
//! backends (ALSA/WASAPI/CoreAudio) are **planned**; this layer defines the
//! contract they will consume — `render` fills a buffer, `toPcm16` converts it to
//! the format most devices accept.
//!
//! Clips come from the asset pipeline: a `CXAW` artifact parsed with
//! `corex.assets.audio.parse` maps to `corex.audio.Clip` field by field. The
//! mixer itself does not import the asset layer, so the two stay independently
//! testable and loosely coupled.
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
//! guarantees and limitations.

const std = @import("std");

/// Clip descriptors, channel-layout mapping, pan laws and PCM16 conversion.
pub const clip = @import("audio/clip.zig");
/// The voice pool, buses and the allocation-free mixing core.
pub const mixer = @import("audio/mixer.zig");

pub const Mixer = mixer.Mixer;
pub const VoiceHandle = mixer.VoiceHandle;
pub const State = mixer.State;
pub const Config = mixer.Config;
pub const PlayOptions = mixer.PlayOptions;
pub const RenderStats = mixer.RenderStats;

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
}
