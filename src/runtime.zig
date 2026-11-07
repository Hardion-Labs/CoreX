//! Runtime subsystem: what drives the engine after startup completes.
//!
//! Today this is presentation — the surface a frame loop owns and draws into — plus
//! pacing, which holds that loop to a target rate and reports real frame timings. A
//! window, a swapchain and an event loop are the parts that need a platform library;
//! `presentation.SurfaceTarget` and `pacing.Pacer` are the pieces they will all need,
//! implemented and tested without one.

const std = @import("std");

pub const presentation = @import("runtime/presentation.zig");
pub const SurfaceTarget = presentation.SurfaceTarget;

pub const pacing = @import("runtime/pacing.zig");
pub const Pacer = pacing.Pacer;
pub const FramePacing = pacing.FramePacing;

test {
    std.testing.refAllDecls(@This());
}
