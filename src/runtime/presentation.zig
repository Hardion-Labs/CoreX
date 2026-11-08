//! Presentation: the surface a frame loop draws into, owned across frames.
//!
//! Until now the engine binary rendered exactly one frame and exited, allocating
//! colour and depth for it and freeing them immediately: that is enough to prove the
//! pipeline works, but it is not a loop. A loop needs a surface that **outlives** the
//! frame, because resizing, clearing and (one day) presenting are all per-frame
//! operations on the same buffers — reallocating them per frame would defeat the
//! per-frame allocator hand-off the renderer already has.
//!
//! `SurfaceTarget` is that ownership, and nothing more: it owns the two buffers,
//! reports whether they changed size, and hands out the borrowed `BackendSurface` the
//! render contract takes. It deliberately knows nothing about windows, swapchains or
//! event loops — those are the parts that need a platform library, and inventing an
//! abstraction for them before one exists would be speculative. What it does give is
//! the piece every one of them needs: a stable frame-sized target that only
//! reallocates when the size actually changes.
//!
//! Clearing is explicit: the render contract says the rasterizer never clears on its
//! own, and folding it into `render` would cost a full-surface pass on a warm frame
//! that already has depth. `clear` is the caller's one call per frame.
//!
//! `FrameLoop` is the loop itself, minus the window: it owns the target, the renderer
//! and the frame accounting, and runs a bounded number of frames. Bounded is a
//! deliberate limit — nothing can stop it yet, because there is no input and no window
//! to close — so a headless run is a measurable number of frames rather than a promise
//! that something will end it.

const std = @import("std");
const r = @import("../render.zig");
const pipeline = r.pipeline;
const scene_render = @import("../scene/render_scene.zig");
const EngineFrameReport = scene_render.EngineFrameReport;
const Pacer = @import("pacing.zig").Pacer;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    /// Zero, or larger than the rasterizer's `max_dimension`.
    InvalidSurface,
    OutOfMemory,
    /// The pacer was asked for a zero rate.
    InvalidTargetFps,
    /// A waited frame was interrupted; the caller decides whether to keep looping.
    Canceled,
};

/// A frame-sized colour + depth target owned across frames.
///
/// Colour is RGBA8 (`width * height * 4` bytes) and depth is `f32`, exactly the
/// layout `render.backend.Surface` validates, so the target is what a backend writes
/// and never a conversion of it.
pub const SurfaceTarget = struct {
    gpa: Allocator,
    width: u32 = 0,
    height: u32 = 0,
    /// RGBA8, `width * height * 4` bytes. Empty until the first `resize`.
    color: []u8 = &.{},
    /// `f32`, `width * height` values. Empty until the first `resize`.
    depth: []f32 = &.{},

    pub fn init(gpa: Allocator, width: u32, height: u32) Error!SurfaceTarget {
        var self = SurfaceTarget{ .gpa = gpa };
        errdefer self.deinit();
        _ = try self.resize(width, height);
        return self;
    }

    pub fn deinit(self: *SurfaceTarget) void {
        self.gpa.free(self.color);
        self.gpa.free(self.depth);
        self.* = undefined;
    }

    /// Resize in place, returning whether the buffers were actually reallocated.
    ///
    /// The cheap case is the common one: a loop asks for the same size every frame and
    /// this is a comparison. Both allocations happen **before** either slice is
    /// replaced, so a failure leaves the target untouched and still usable at its
    /// previous size — a resize that cannot be honoured must not destroy the frame the
    /// caller already has.
    ///
    /// Zero-sized or oversized requests are refused rather than accepted: a zero-pixel
    /// surface is what a minimised window reports, and rendering into it would make
    /// every draw count zero pixels and every statistic meaningless.
    pub fn resize(self: *SurfaceTarget, width: u32, height: u32) Error!bool {
        if (width == 0 or height == 0) return error.InvalidSurface;
        if (width > r.raster.max_dimension or height > r.raster.max_dimension) return error.InvalidSurface;
        if (width == self.width and height == self.height and self.color.len != 0) return false;

        const pixels = @as(usize, width) * @as(usize, height);
        const color = try self.gpa.alloc(u8, pixels * 4);
        errdefer self.gpa.free(color);
        const depth = try self.gpa.alloc(f32, pixels);
        // No `errdefer` for `depth`: from here on nothing can fail, so the two slices
        // are swapped in together and the old pair is released once.
        self.gpa.free(self.color);
        self.gpa.free(self.depth);
        self.color = color;
        self.depth = depth;
        self.width = width;
        self.height = height;
        return true;
    }

    /// The surface to render into. Borrowed, valid until the next `resize`/`deinit`.
    pub fn surface(self: *SurfaceTarget) r.BackendSurface {
        return .{ .width = self.width, .height = self.height, .color = self.color, .depth = self.depth };
    }

    pub fn pixelCount(self: SurfaceTarget) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    /// Bytes owned by the two buffers, for reporting.
    pub fn byteSize(self: SurfaceTarget) usize {
        return self.color.len + self.depth.len * @sizeOf(f32);
    }

    /// Reset the frame: `rgba` everywhere and the far plane in depth.
    pub fn clear(self: *SurfaceTarget, rgba: [4]u8, depth_value: f32) void {
        self.surface().clear(rgba, depth_value);
    }
};

/// What a `FrameLoop` run produced, aggregated over its frames.
pub const RunReport = struct {
    frames: usize = 0,
    /// Frames in which the scene authored no camera; nothing was drawn.
    empty_frames: usize = 0,
    /// Frames that changed the reusable buffers (draw list or per-frame arena). A
    /// steady-state loop reaches zero after the first two frames.
    allocating_frames: usize = 0,
    /// The last frame's accounting, for a caller that wants the final state.
    last: EngineFrameReport = .{},
    /// Total time the loop spent waiting for frame deadlines. Zero when unpaced.
    slept_ns: u64 = 0,
    /// Total duration of all rendered frames, waiting included.
    elapsed_ns: u64 = 0,
    /// Frames that overran their budget (only possible when paced).
    late_frames: usize = 0,
};

/// Drives the engine's renderer over a sequence of frames into an owned surface.
///
/// This is the headless form of the frame loop: the same object a windowed loop will
/// use, with the platform parts (window, input, vsync, swapchain) left out because
/// they do not exist yet. What is real here is the part that matters for
/// performance: the surface is allocated **once** and only reallocated when the size
/// changes, and the renderer's draw list and per-frame arena are reused, so frames
/// after the warm-up allocate nothing.
pub const FrameLoop = struct {
    gpa: Allocator,
    target: SurfaceTarget,
    renderer: scene_render.EngineRenderer,
    /// Per-frame scratch for finding the camera. `findCamera` resolves the entity's
    /// world matrix, which needs a transform snapshot; that snapshot is dead before
    /// the frame is drawn, so it comes from here and one reset per frame releases it —
    /// the same hand-off `RenderFrame` already does for its own extraction. Without
    /// this, locating the camera would allocate every single frame.
    camera_scratch: std.heap.ArenaAllocator,
    /// Frame parameters applied to every frame (clear colour, antialiasing, light).
    params: pipeline.FrameParams = .{},
    /// Frame pacing. Disabled by default: with nothing on screen, rendering as fast as
    /// possible is the useful default for a scripted run.
    pacer: Pacer = Pacer.disabled,
    /// What `run` accumulated; reset at the start of every `run`.
    report: RunReport = .{},

    /// `target_fps` paces the loop; `null` renders as fast as the machine can. A zero
    /// rate is refused rather than silently meaning "unpaced": the two are different
    /// requests and confusing them hides a configuration mistake.
    pub fn init(gpa: Allocator, tier: r.Tier, width: u32, height: u32, target_fps: ?u32) Error!FrameLoop {
        var target = try SurfaceTarget.init(gpa, width, height);
        errdefer target.deinit();
        // The pacer is validated before the renderer is built: an invalid rate must
        // fail without leaving a renderer's buffers behind, and every exit below this
        // point owns something that needs releasing.
        var pacer: Pacer = Pacer.disabled;
        if (target_fps) |fps| pacer = try Pacer.init(fps);
        var renderer = try scene_render.EngineRenderer.init(gpa, tier);
        errdefer renderer.deinit();
        return .{
            .gpa = gpa,
            .target = target,
            .renderer = renderer,
            .camera_scratch = std.heap.ArenaAllocator.init(gpa),
            .pacer = pacer,
        };
    }

    /// The rate the loop is paced at, or null when unpaced.
    pub fn targetFps(self: FrameLoop) ?u32 {
        return self.pacer.targetFps();
    }

    pub fn deinit(self: *FrameLoop) void {
        self.camera_scratch.deinit();
        self.renderer.deinit();
        self.target.deinit();
        self.* = undefined;
    }

    /// Resize the frame target. Returns whether the buffers were reallocated; the
    /// next `frame` reports through the same renderer, whose draw list is unaffected
    /// by the surface size.
    pub fn resize(self: *FrameLoop, width: u32, height: u32) Error!bool {
        return self.target.resize(width, height);
    }

    /// Render exactly one frame into the owned target, waiting for the frame budget
    /// afterwards when the loop is paced.
    ///
    /// Returns null when the scene authors no camera: there is nothing to frame, and
    /// drawing a cleared surface would be a lie about the project's content. The
    /// target is not cleared in that case either, so a caller inspecting the pixels
    /// sees exactly what the last real frame wrote.
    pub fn frame(self: *FrameLoop, scene: anytype, resources: r.DrawResources, io: ?Io) !?pipeline.FrameReport {
        // The pacing clock starts before the work, so the wait covers the whole frame.
        // `io == null` renders without ever sleeping: the headless tests measure work,
        // not wall-clock time.
        const started = if (io) |io_| self.pacer.begin(io_) else null;

        _ = self.camera_scratch.reset(.retain_capacity);
        const found = try scene_render.EngineRenderer.findCamera(scene, self.camera_scratch.allocator()) orelse {
            // No camera: nothing was framed, so the pace folds nothing into the
            // report — an empty frame must not masquerade as a rendered one.
            return null;
        };
        defer if (io) |io_| self.paceAfter(io_, started);
        const surface = self.target.surface();
        self.target.clear(self.params.clear, self.params.clear_depth);
        const report = try self.renderer.render(
            surface,
            scene,
            found.component,
            found.camera,
            resources,
            self.params,
        );
        self.report.frames += 1;
        if (self.renderer.last.allocated) self.report.allocating_frames += 1;
        self.report.last = self.renderer.last;
        return report;
    }

    /// Wait out the rest of the frame budget and fold the result into `report`.
    fn paceAfter(self: *FrameLoop, io: Io, started: ?Io.Clock.Timestamp) void {
        const pacing = self.pacer.end(io, started) catch |err| switch (err) {
            // An interrupted wait ends the pacing for this frame, not the loop: the
            // frame was rendered, it just was not held back.
            error.Canceled => return,
            // `end` only reports a bad rate, which `init` already refused at
            // construction, so reaching it is a programming error with no recovery.
            error.InvalidTargetFps => unreachable,
        };
        self.report.slept_ns += pacing.slept_ns;
        self.report.elapsed_ns += pacing.work_ns + pacing.slept_ns;
        if (pacing.late) self.report.late_frames += 1;
    }

    /// Render `count` frames of the same scene, accumulating `report`.
    ///
    /// A scene with no camera stops the loop: nothing is rendered, `frames` stays 0 and
    /// `empty_frames` reports the frames the loop declined to draw. Repeating an answer
    /// that cannot change would only cost time, and calling those frames "rendered"
    /// would misreport what happened.
    pub fn run(self: *FrameLoop, scene: anytype, resources: r.DrawResources, count: usize, io: ?Io) !RunReport {
        self.report = .{};
        self.pacer.reschedule();
        for (0..count) |_| {
            if (try self.frame(scene, resources, io) == null) {
                self.report.empty_frames = count - self.report.frames;
                break;
            }
        }
        return self.report;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "presentation: a surface target owns colour and depth at the requested size" {
    var target = try SurfaceTarget.init(testing.allocator, 32, 16);
    defer target.deinit();

    try testing.expectEqual(@as(u32, 32), target.width);
    try testing.expectEqual(@as(u32, 16), target.height);
    try testing.expectEqual(@as(usize, 512), target.pixelCount());
    try testing.expectEqual(@as(usize, 512 * 4), target.color.len);
    try testing.expectEqual(@as(usize, 512), target.depth.len);
    try testing.expectEqual(@as(usize, 512 * 8), target.byteSize());

    // The borrowed surface describes exactly those buffers and validates.
    const surface = target.surface();
    try surface.validate();
    try testing.expectEqual(target.color.ptr, surface.color.ptr);
    try testing.expectEqual(target.depth.ptr, surface.depth.ptr);
}

test "presentation: resizing the same size is free, a real resize reallocates" {
    var target = try SurfaceTarget.init(testing.allocator, 8, 8);
    defer target.deinit();
    const color_before = target.color.ptr;

    // The per-frame call in a loop: same size, nothing happens.
    try testing.expect(!try target.resize(8, 8));
    try testing.expectEqual(color_before, target.color.ptr);
    try testing.expectEqual(@as(usize, 256), target.color.len);

    // A real resize reaches the new size and keeps the contract valid.
    try testing.expect(try target.resize(16, 4));
    try testing.expectEqual(@as(usize, 16 * 4 * 4), target.color.len);
    try testing.expectEqual(@as(usize, 16 * 4), target.depth.len);
    try target.surface().validate();
}

test "presentation: a failed resize leaves the owned target intact" {
    // Zero and oversized requests are refused before anything is freed, so a caller
    // that keeps rendering after a rejected resize still has a valid frame.
    var target = try SurfaceTarget.init(testing.allocator, 4, 4);
    defer target.deinit();
    const color = target.color.ptr;

    try testing.expectError(error.InvalidSurface, target.resize(0, 4));
    try testing.expectError(error.InvalidSurface, target.resize(4, 0));
    try testing.expectError(error.InvalidSurface, target.resize(r.raster.max_dimension + 1, 4));

    try testing.expectEqual(@as(u32, 4), target.width);
    try testing.expectEqual(color, target.color.ptr);
    try target.surface().validate();

    // An allocation failure mid-resize also leaves it intact, in both orders: the
    // colour buffer failing (nothing allocated) and the depth buffer failing (colour
    // allocated and rolled back). Those are the two places this function can fail,
    // and both must leave the caller a usable frame.
    for ([_]usize{ 0, 1 }) |fail_index| {
        var fragile = try SurfaceTarget.init(testing.allocator, 4, 4);
        defer fragile.deinit();

        var fails = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        fragile.gpa = fails.allocator();
        try testing.expectError(error.OutOfMemory, fragile.resize(8, 8));
        fragile.gpa = testing.allocator;

        try testing.expectEqual(@as(u32, 4), fragile.width);
        try testing.expectEqual(@as(u32, 4), fragile.height);
        try testing.expectEqual(@as(usize, 4 * 4 * 4), fragile.color.len);
        try testing.expectEqual(@as(usize, 4 * 4), fragile.depth.len);
        try fragile.surface().validate();
    }
}

/// A counting allocator wrapper: how many bytes a stretch of code asked for.
const Counter = struct {
    parent: Allocator,
    bytes: usize = 0,
    calls: usize = 0,

    fn allocator(self: *Counter) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bytes += len;
        self.calls += 1;
        return out;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (self.parent.rawResize(buf, alignment, new_len, ret_addr)) {
            self.bytes += new_len -| buf.len;
            self.calls += 1;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.bytes += new_len -| buf.len;
        self.calls += 1;
        return out;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

const testing_scene = @import("../scene/render_scene.zig");

/// A one-quad scene seen by a camera on +Z, plus the table its handles resolve
/// against. Mirrors the shipped example project at a small size.
fn buildScene(scene: *testing_scene.EngineRenderScene, table: *pipeline.ResourceTable) !void {
    const quad = try scene.createEntity("quad", null);
    try scene.addComponent(quad, testing_scene.Transform{});
    try scene.addComponent(quad, testing_scene.Renderable{ .bounds = .{ .center = .{ 0, 0, 0 }, .extents = .{ 1, 1, 0.01 } } });

    const camera = try scene.createEntity("cam", null);
    try scene.addComponent(camera, testing_scene.Transform{ .position = .{ 0, 0, 4 } });
    try scene.addComponent(camera, testing_scene.CameraComponent{ .fov = std.math.pi / 2.0 });

    const positions = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const mesh_handle = try table.setMesh(0, .{ .positions = &positions, .indices = &indices });
    const color_handle = try table.setColor(0, .{ 0, 1, 0, 1 });
    scene.getComponent(testing_scene.Renderable, quad).?.mesh = mesh_handle.toBits();
    scene.getComponent(testing_scene.Renderable, quad).?.material = color_handle.toBits();
}

test "presentation: the loop renders frames into the surface it owns" {
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);

    var loop = try FrameLoop.init(gpa, .medium, 32, 24, null);
    defer loop.deinit();
    loop.params.antialias = .none;

    const report = try loop.run(&scene, table.resources(true), 3, null);
    try testing.expectEqual(@as(usize, 3), report.frames);
    try testing.expectEqual(@as(usize, 0), report.empty_frames);
    try testing.expect(report.last.commands == 1 and report.last.draws == 1);
    try testing.expect(report.last.pixels > 0);
    // The target is the size the loop was created with, and holds real pixels.
    try testing.expectEqual(@as(u32, 32), loop.target.width);
    try testing.expectEqual(@as(usize, 32 * 24), loop.target.pixelCount());
    var non_clear: usize = 0;
    for (0..loop.target.pixelCount()) |i| {
        const px = loop.target.color[i * 4 ..][0..4];
        if (px[0] != 0 or px[1] != 0 or px[2] != 0) non_clear += 1;
    }
    try testing.expect(non_clear > 0);
}

test "presentation: frames after the warm-up allocate nothing" {
    // The property the per-frame hand-off exists for, stated one level up: a loop
    // that renders the same scene repeatedly asks the general allocator for nothing.
    const gpa = testing.allocator;
    var counter = Counter{ .parent = gpa };

    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);
    const resources = table.resources(true);

    var loop = try FrameLoop.init(counter.allocator(), .medium, 16, 16, null);
    defer {
        loop.gpa = gpa; // the counter borrows local state; free with the real one
        loop.deinit();
    }
    loop.params.antialias = .none;

    // Warm-up: the surface is allocated once and both draw-list buffers grow once.
    _ = try loop.run(&scene, resources, 3, null);
    try testing.expect(loop.report.allocating_frames > 0);

    counter.bytes = 0;
    counter.calls = 0;
    const steady = try loop.run(&scene, resources, 8, null);
    try testing.expectEqual(@as(usize, 8), steady.frames);
    try testing.expectEqual(@as(usize, 0), steady.allocating_frames);
    try testing.expectEqual(@as(usize, 0), counter.calls);
    try testing.expectEqual(@as(usize, 0), counter.bytes);
}

test "presentation: a resize keeps the loop rendering, only when the size changes" {
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);
    const resources = table.resources(true);

    var loop = try FrameLoop.init(gpa, .medium, 16, 16, null);
    defer loop.deinit();
    loop.params.antialias = .none;
    _ = try loop.run(&scene, resources, 2, null);

    // Same size: no reallocation, and the frame still renders.
    try testing.expect(!try loop.resize(16, 16));
    _ = try loop.run(&scene, resources, 2, null);

    // A new size reallocates once and every later frame keeps that size.
    try testing.expect(try loop.resize(40, 20));
    const report = try loop.run(&scene, resources, 2, null);
    try testing.expectEqual(@as(usize, 2), report.frames);
    try testing.expectEqual(@as(u32, 40), loop.target.width);
    try testing.expectEqual(@as(u32, 20), loop.target.height);
    try testing.expect(report.last.pixels > 0);
    try testing.expect(!try loop.resize(40, 20));

    // A rejected resize leaves the loop usable at its current size.
    try testing.expectError(error.InvalidSurface, loop.resize(0, 20));
    try testing.expectEqual(@as(u32, 40), loop.target.width);
    _ = try loop.run(&scene, resources, 1, null);
}

test "presentation: a scene without a camera renders no frames and says so" {
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    const e = try scene.createEntity("quad", null);
    try scene.addComponent(e, testing_scene.Transform{});
    try scene.addComponent(e, testing_scene.Renderable{});
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);

    var loop = try FrameLoop.init(gpa, .medium, 8, 8, null);
    defer loop.deinit();
    const report = try loop.run(&scene, table.resources(false), 5, null);
    try testing.expectEqual(@as(usize, 0), report.frames);
    try testing.expectEqual(@as(usize, 5), report.empty_frames);
    // Nothing was drawn, so the loop is still ready for a scene that has a camera.
    try testing.expect(try loop.frame(&scene, table.resources(false), null) == null);

    var with_camera = try testing_scene.EngineRenderScene.init(gpa, "cam");
    defer with_camera.deinit();
    var table2 = try pipeline.ResourceTable.init(gpa, 1);
    defer table2.deinit(gpa);
    try buildScene(&with_camera, &table2);
    try testing.expect(try loop.frame(&with_camera, table2.resources(true), null) != null);
}

test "presentation: repeated frames of an unchanged scene are pixel-identical" {
    // A loop is only usable if the same scene produces the same image every frame; a
    // buffer that is reused must not leak state from the previous frame into the next.
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);
    const resources = table.resources(true);

    var loop = try FrameLoop.init(gpa, .medium, 24, 18, null);
    defer loop.deinit();
    loop.params.antialias = .none;

    _ = try loop.frame(&scene, resources, null);
    const first = try gpa.dupe(u8, loop.target.color);
    defer gpa.free(first);

    for (0..4) |_| {
        _ = try loop.frame(&scene, resources, null);
        try testing.expectEqualSlices(u8, first, loop.target.color);
    }

    // A change to the scene shows up in the next frame: the reuse is not hiding it.
    // Moving the quad off-centre changes where the pixels land.
    scene.getComponent(testing_scene.Transform, scene.entityById(1).?).?.position = .{ 0.8, 0, 0 };
    _ = try loop.frame(&scene, resources, null);
    try testing.expect(!std.mem.eql(u8, first, loop.target.color));
    try testing.expectEqual(@as(usize, 1), loop.report.last.draws);
}

test "presentation: a zero target rate is refused at construction" {
    // Zero is not \"unpaced\" — that is `null` — so it must be rejected instead of
    // quietly rendering flat out.
    try testing.expectError(error.InvalidTargetFps, FrameLoop.init(testing.allocator, .medium, 8, 8, 0));
}

test "presentation: an unpaced loop neither sleeps nor reports timing" {
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);

    var loop = try FrameLoop.init(gpa, .medium, 16, 16, null);
    defer loop.deinit();
    loop.params.antialias = .none;
    try testing.expectEqual(@as(?u32, null), loop.targetFps());

    // `io` is passed, so the clock is available; pacing being off is what decides that
    // nothing is measured or waited for.
    const report = try loop.run(&scene, table.resources(true), 3, testing.io);
    try testing.expectEqual(@as(usize, 3), report.frames);
    try testing.expectEqual(@as(u64, 0), report.slept_ns);
    try testing.expectEqual(@as(u64, 0), report.elapsed_ns);
    try testing.expectEqual(@as(usize, 0), report.late_frames);
}

test "presentation: a paced loop holds every frame for its budget" {
    // The end-to-end behaviour of this cycle: with a rate, the loop waits, and the
    // accumulated statistics are real measurements of that wait. 100 fps keeps the test
    // short (10 ms per frame) while leaving the wait large enough to observe.
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);

    var loop = try FrameLoop.init(gpa, .medium, 16, 16, 100);
    defer loop.deinit();
    loop.params.antialias = .none;
    try testing.expectEqual(@as(?u32, 100), loop.targetFps());

    const report = try loop.run(&scene, table.resources(true), 2, testing.io);
    try testing.expectEqual(@as(usize, 2), report.frames);
    // Two frames at 10 ms: the loop cannot finish faster than one budget, and in
    // practice it waits out both.
    try testing.expect(report.slept_ns > 0);
    try testing.expectEqual(@as(u64, 10_000_000), loop.pacer.budget_ns.?);
    try testing.expect(report.elapsed_ns >= report.slept_ns);
    try testing.expect(report.elapsed_ns >= 10_000_000);
    // Rendering a 16x16 quad is far inside 10 ms, so nothing should be late.
    try testing.expectEqual(@as(usize, 0), report.late_frames);
    try testing.expectEqual(@as(usize, 0), loop.pacer.resyncs);
}

test "presentation: an absurd rate overruns and is counted, not slept away" {
    // A budget too small for the work is the common misconfiguration. The loop must
    // keep drawing, count the frames as late, and never block on a past deadline.
    const gpa = testing.allocator;
    var scene = try testing_scene.EngineRenderScene.init(gpa, "main");
    defer scene.deinit();
    var table = try pipeline.ResourceTable.init(gpa, 1);
    defer table.deinit(gpa);
    try buildScene(&scene, &table);

    // One billion fps: a one-nanosecond budget, which no frame can meet.
    var loop = try FrameLoop.init(gpa, .medium, 16, 16, 1_000_000_000);
    defer loop.deinit();
    loop.params.antialias = .none;
    try testing.expectEqual(@as(?u64, 1), loop.pacer.budget_ns);

    const report = try loop.run(&scene, table.resources(true), 3, testing.io);
    // Every frame still rendered — a missed deadline slows the loop, it does not stop it.
    try testing.expectEqual(@as(usize, 3), report.frames);
    try testing.expectEqual(@as(usize, 3), report.late_frames);
    // Late frames do not sleep; their work time is still measured.
    try testing.expectEqual(@as(u64, 0), report.slept_ns);
    try testing.expect(report.elapsed_ns > 0);
    try testing.expectEqual(@as(usize, 3), loop.pacer.late_frames);
}
