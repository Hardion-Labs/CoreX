//! Runtime subsystem: what drives the engine after startup completes.
//!
//! Today this is presentation — the surface a frame loop owns and draws into. A
//! window, a swapchain and an event loop are the parts that need a platform library;
//! `presentation.SurfaceTarget` is the piece they will all need, implemented and
//! tested without one.

const std = @import("std");

pub const presentation = @import("runtime/presentation.zig");
pub const SurfaceTarget = presentation.SurfaceTarget;

test {
    std.testing.refAllDecls(@This());
}
