const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const corex_module = b.createModule(.{
        .root_source_file = b.path("src/corex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "corex-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corex", .module = corex_module }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    // Forward `zig build run -- <args>` to the engine. Zig 0.17 removed
    // `Build.args`; passthru args are the supported mechanism.
    run_cmd.addPassthruArgs();
    b.step("run", "Run the CoreXEngine").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = corex_module });
    b.step("test", "Run CoreXEngine tests").dependOn(&b.addRunArtifact(tests).step);

    // Optional microbenchmark for the rasterizer (best run with
    // `-Doptimize=ReleaseFast`). Not executed by CI or `zig build`.
    const bench = b.addExecutable(.{
        .name = "bench-raster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_raster.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corex", .module = corex_module }},
        }),
    });
    b.step("bench", "Run the rasterizer benchmark (use -Doptimize=ReleaseFast)").dependOn(&b.addRunArtifact(bench).step);

    // Extraction benchmark: occlusion on/off through the real `RenderFrame`.
    const bench_extract = b.addExecutable(.{
        .name = "bench-extract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_extract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corex", .module = corex_module }},
        }),
    });
    b.step("bench-extract", "Run the extraction/occlusion benchmark (use -Doptimize=ReleaseFast)").dependOn(&b.addRunArtifact(bench_extract).step);

    // GUI frame: renders one headless frame of real widgets and writes it as QOI.
    // Used to inspect the GUI without a window, and by the smoke check.
    const gui_frame = b.addExecutable(.{
        .name = "gui-frame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gui_frame.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corex", .module = corex_module }},
        }),
    });
    const gui_frame_run = b.addRunArtifact(gui_frame);
    gui_frame_run.addPassthruArgs();
    b.step("gui-frame", "Render one headless GUI frame to a QOI file (zig build gui-frame -- out.qoi)").dependOn(&gui_frame_run.step);

    // Editor frame: renders one real editor frame of a project (hierarchy, viewport,
    // inspector, status) headlessly and writes it as QOI.
    const editor_frame = b.addExecutable(.{
        .name = "editor-frame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/editor_frame.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corex", .module = corex_module }},
        }),
    });
    const editor_frame_run = b.addRunArtifact(editor_frame);
    editor_frame_run.addPassthruArgs();
    b.step("editor-frame", "Render one headless editor frame of a project (zig build editor-frame -- <project.corex> out.qoi)").dependOn(&editor_frame_run.step);
}
