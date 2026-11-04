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
}
