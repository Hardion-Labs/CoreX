//! Cross-layer integration: scene -> draw list -> software rasterizer -> QOI.
//!
//! This lives at the composition root rather than inside `render` so that the
//! rasterizer itself keeps no dependency on the asset layer. It proves the two
//! ends actually meet: the rasterizer's borrowed RGBA8 buffer is exactly the
//! layout `assets.image` encodes, so a rendered frame round-trips through a real
//! image codec with no conversion and no pixel change.

const std = @import("std");
const corex = @import("../corex.zig");

const R = corex.render;
const A = corex.assets;
const testing = std.testing;

const TestScene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(R.Renderable, "renderable"),
});

const Resources = struct {
    meshes: []const R.RasterMesh,
    palette: []const [4]f32,

    pub fn mesh(self: Resources, handle: u32) ?R.RasterMesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: Resources, handle: u32) ?[4]f32 {
        if (handle >= self.palette.len) return null;
        return self.palette[handle];
    }
};

test "rendered frame round-trips through the QOI codec unchanged" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    var sc = try TestScene.init(gpa, "main");
    defer sc.deinit();

    // Two overlapping quads at different depths; the nearer one must occlude.
    const far = try sc.createEntity("far", null);
    try sc.addComponent(far, corex.scene.Transform{ .position = .{ 0, 0, -1 } });
    try sc.addComponent(far, R.Renderable{
        .mesh = 0,
        .material = 0,
        .bounds = R.Aabb.fromMinMax(.{ -2, -2, -0.1 }, .{ 2, 2, 0.1 }),
    });
    const near = try sc.createEntity("near", null);
    try sc.addComponent(near, corex.scene.Transform{ .position = .{ 0, 0, 1 } });
    try sc.addComponent(near, R.Renderable{
        .mesh = 1,
        .material = 1,
        .bounds = R.Aabb.fromMinMax(.{ -0.5, -0.5, -0.1 }, .{ 0.5, 0.5, 0.1 }),
    });

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, aspect, 0.5, 100);
    var frame = try R.extractDrawList(&sc, cam, .front_to_back, gpa);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 2), frame.count());

    const big = [_][3]f32{ .{ -2, -2, 0 }, .{ 2, -2, 0 }, .{ 2, 2, 0 }, .{ -2, 2, 0 } };
    const small = [_][3]f32{ .{ -0.5, -0.5, 0 }, .{ 0.5, -0.5, 0 }, .{ 0.5, 0.5, 0 }, .{ -0.5, 0.5, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const meshes = [_]R.RasterMesh{
        .{ .positions = &big, .indices = &indices },
        .{ .positions = &small, .indices = &indices },
    };
    const res = Resources{ .meshes = &meshes, .palette = &.{ .{ 0.1, 0.2, 0.9, 1 }, .{ 1, 0.8, 0, 1 } } };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);
    var target = try R.Target.init(width, height, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);

    const stats = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{});
    try testing.expectEqual(@as(usize, 4), stats.submitted);
    try testing.expect(stats.pixels > 0);

    // The center is covered by both quads; the near (yellow) one must win.
    try testing.expectEqualSlices(u8, &.{ 255, 204, 0, 255 }, &target.colorAt(width / 2, height / 2));
    // A corner is outside the far quad's projection and keeps the clear color.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &target.colorAt(0, 0));

    // Hand the rasterizer's own buffer to the codec: no copy, no reformat.
    const img = A.image.Image{ .width = width, .height = height, .pixels = color };
    const encoded = try A.image.encodeQoi(gpa, img);
    defer gpa.free(encoded);
    var decoded = try A.image.decodeQoi(gpa, encoded);
    defer decoded.deinit(gpa);

    try testing.expectEqual(width, decoded.width);
    try testing.expectEqual(height, decoded.height);
    try testing.expectEqualSlices(u8, color, decoded.pixels);
}
