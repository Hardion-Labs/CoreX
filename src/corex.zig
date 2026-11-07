//! CoreXEngine public module.
//!
//! This is the concentrated public surface of the engine. Subsystems are
//! re-exported here as they are implemented. See `docs/scope.md` for the
//! definitive project scope and `docs/architecture.md` for the subsystem map
//! and implementation status.

const std = @import("std");

/// Engine version (Semantic Versioning).
pub const version = @import("core/version.zig").engine;
/// Zig compiler version targeted by this project.
pub const zig_version = @import("core/version.zig").zig_version;

/// Engine core subsystems (startup spine).
pub const core = struct {
    pub const version = @import("core/version.zig");
    pub const cli = @import("core/cli.zig");
    pub const manifest = @import("core/manifest.zig");
    pub const paths = @import("core/paths.zig");
    pub const jobs = @import("core/jobs.zig");
    pub const config = @import("core/config.zig");
    pub const assets = @import("core/assets.zig");
    pub const splash = @import("core/splash.zig");
    pub const diagnostics = @import("core/diagnostics.zig");
    pub const startup = @import("core/startup.zig");
    pub const validation = @import("core/validation.zig");
};

/// Entity-Component-System: generational entities, sparse-set component pools,
/// and a type-safe world with multi-component views.
pub const ecs = @import("ecs.zig");

/// Scene system: versioned scene documents, stable entity IDs, hierarchy and
/// ECS-backed components.
pub const scene = @import("scene.zig");

/// Asset subsystem: indexing, content-addressed import cache, importers and
/// the parallel import pipeline.
pub const assets = @import("assets.zig");

/// Render subsystem: backend-independent camera math, frustum culling and
/// draw-list extraction (the CPU foundation the GPU tiers will consume).
pub const render = @import("render.zig");

/// Runtime subsystem: presentation (the frame-sized target a loop owns) and, as the
/// platform layers land, the loop itself.
pub const runtime = @import("runtime.zig");

/// GUI subsystem: immediate-mode UI (built-in bitmap font, 2D canvas, layout).
pub const gui = @import("gui.zig");
pub const editor = @import("editor.zig");

/// Audio subsystem: device-independent mixing (voices, buses, gain/pan, pitch,
/// resampling) — the CPU foundation the OS playback backends will consume.
pub const audio = @import("audio.zig");

// Pull every submodule's tests into the test build.
test {
    std.testing.refAllDecls(@This());
    _ = core.version;
    _ = core.cli;
    _ = core.manifest;
    _ = core.paths;
    _ = core.jobs;
    _ = core.config;
    _ = core.assets;
    _ = core.splash;
    _ = core.diagnostics;
    _ = core.startup;
    _ = core.validation;
    _ = ecs;
    _ = scene;
    _ = assets;
    _ = runtime;
    _ = audio;
    _ = gui;
    _ = editor;
    _ = @import("audio/cxaw_playback_test.zig");
    _ = @import("ecs/schedule_jobs_test.zig");
    _ = @import("ecs/frame_jobs_test.zig");
    _ = @import("assets/pipeline_jobs_test.zig");
    _ = @import("render/raster_image_test.zig");
}
