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

/// Textured variant: its `texture` method makes the material resolve to an
/// RGBA8 texture through the same duck-typed contract the rasterizer detects
/// at comptime. Kept separate from `Resources` so the flat path stays a
/// first-class supported configuration (no `texture` decl, flat shading).
const TexturedResources = struct {
    meshes: []const R.RasterMesh,
    palette: []const [4]f32,
    textures: []const R.RasterTexture,

    pub fn mesh(self: TexturedResources, handle: u32) ?R.RasterMesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: TexturedResources, handle: u32) ?[4]f32 {
        if (handle >= self.palette.len) return null;
        return self.palette[handle];
    }

    pub fn texture(self: TexturedResources, handle: u32) ?R.RasterTexture {
        if (handle >= self.textures.len) return null;
        return self.textures[handle];
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

test "textured render routes through the same codec and wins depth" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    var sc = try TestScene.init(gpa, "main");
    defer sc.deinit();

    // Same two-quad layout as the flat case; both quads carry uvs and sample
    // a 4x4 texture whose red channel depends only on the column, so the
    // sampled column is decidable by screen x alone.
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
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const meshes = [_]R.RasterMesh{
        .{ .positions = &big, .indices = &indices, .uvs = &uvs },
        .{ .positions = &small, .indices = &indices, .uvs = &uvs },
    };

    // Column-tinted opaque 4x4 texture: texel(x, y) = (column*60 + 30, 40, 90, 255).
    var texture_pixels: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        const o = (y * 4 + x) * 4;
        texture_pixels[o] = @intCast(x * 60 + 30);
        texture_pixels[o + 1] = 40;
        texture_pixels[o + 2] = 90;
        texture_pixels[o + 3] = 255;
    };
    const tex = R.RasterTexture{ .width = 4, .height = 4, .pixels = &texture_pixels, .filter = .nearest };
    // Both materials sample the same texture but tint differently: the far
    // quad is half-gray, the near quad is white. The center pixel must show
    // the near (white) texture, exactly like the flat test's depth check.
    const res = TexturedResources{
        .meshes = &meshes,
        .palette = &.{ .{ 0.5, 0.5, 0.5, 1 }, .{ 1.0, 1.0, 1.0, 1.0 } },
        .textures = &.{ tex, tex },
    };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);
    var target = try R.Target.init(width, height, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);

    const stats = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{});
    try testing.expectEqual(@as(usize, 4), stats.submitted);
    try testing.expectEqual(@as(usize, 0), stats.skipped_draws);
    try testing.expect(stats.pixels > 0);

    // The near quad covers the center; with the white tint and nearest
    // sampling of a column-tinted 4x4 texture the red channel is
    // column*60+30 for the column under the screen center. The screen x of
    // pixel 16 is u ~= 0.53, i.e. column 2: red == 150.
    const center = target.colorAt(width / 2, height / 2);
    try testing.expectEqual(@as(u8, 150), center[0]);
    try testing.expectEqual(@as(u8, 255), center[3]);

    // Row 9 is covered by the far quad only (ndc y ~= 0.21, inside its ±2/7
    // span, outside the near quad's ~±0.1 span). The half-gray palette entry
    // quantizes to 128, so the column-2 texel (150, 40, 90) folds to
    // (floor(150*128/255 + .5), floor(40*128/255 + .5), floor(90*128/255 + .5))
    // = (75, 20, 45). This pins the far path's tint multiply, not just the near.
    try testing.expectEqualSlices(u8, &.{ 75, 20, 45, 255 }, &target.colorAt(width / 2, 9));

    // The rendered RGBA8 buffer still round-trips through QOI unchanged.
    const img = A.image.Image{ .width = width, .height = height, .pixels = color };
    const encoded = try A.image.encodeQoi(gpa, img);
    defer gpa.free(encoded);
    var decoded = try A.image.decodeQoi(gpa, encoded);
    defer decoded.deinit(gpa);

    try testing.expectEqual(width, decoded.width);
    try testing.expectEqual(height, decoded.height);
    try testing.expectEqualSlices(u8, color, decoded.pixels);
}

/// Lit variant: its `directionalLight` method makes the directional light
/// resolve through the same duck-typed contract the rasterizer detects at
/// comptime. Kept separate so the unlit and textured paths stay first-class
/// supported configurations.
const LitResources = struct {
    meshes: []const R.RasterMesh,
    palette: []const [4]f32,
    light: R.RasterLight,

    pub fn mesh(self: LitResources, handle: u32) ?R.RasterMesh {
        if (handle >= self.meshes.len) return null;
        return self.meshes[handle];
    }

    pub fn color(self: LitResources, handle: u32) ?[4]f32 {
        if (handle >= self.palette.len) return null;
        return self.palette[handle];
    }

    pub fn directionalLight(self: LitResources) ?R.RasterLight {
        return self.light;
    }
};

fn quadScene(gpa: std.mem.Allocator, name: []const u8, rotation: [4]f32) !TestScene {
    _ = name;
    var sc = try TestScene.init(gpa, "main");
    errdefer sc.deinit();
    const e = try sc.createEntity("quad", null);
    try sc.addComponent(e, corex.scene.Transform{ .position = .{ 0, 0, -1 }, .rotation = rotation });
    try sc.addComponent(e, R.Renderable{
        .mesh = 0,
        .material = 0,
        .bounds = R.Aabb.fromMinMax(.{ -2, -2, -0.1 }, .{ 2, 2, 0.1 }),
    });
    return sc;
}

const lit_positions = [_][3]f32{ .{ -2, -2, 0 }, .{ 2, -2, 0 }, .{ 2, 2, 0 }, .{ -2, 2, 0 } };
const lit_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
const lit_mesh = R.RasterMesh{ .positions = &lit_positions, .indices = &lit_indices };

test "lit integration: the provider's directional light shades the extracted frame" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    var sc = try quadScene(gpa, "lit", .{ 0, 0, 0, 1 });
    defer sc.deinit();

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, aspect, 0.5, 100);

    const meshes = [_]R.RasterMesh{lit_mesh};
    const palette = [_][4]f32{.{ 0.5, 0.25, 1.0, 1.0 }};
    // Quantized palette once (clamp -> *255 -> round): 0.5 -> 128, 0.25 -> 64, 1.0 -> 255.
    const albedo = [3]u8{ 128, 64, 255 };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);

    // All expected values use exact binary arithmetic on the quantized albedo
    // (x * 0.25 == exact; x * 0.8 is pinned against the f64 dot below).
    const cases = [_]struct {
        name: []const u8,
        light: R.RasterLight,
        expected: [4]u8,
    }{
        // Dead-on light, ambient 0: dot == 1 exactly -> tint unchanged.
        .{ .name = "full", .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0, 0, 0 } }, .expected = .{ albedo[0], albedo[1], albedo[2], 255 } },
        // Perpendicular light, ambient 1/4: dot == 0 -> ambient-only.
        .{ .name = "ambient_only", .light = .{ .direction = .{ 1, 0, 0 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.25, 0.25 } }, .expected = .{ 32, 16, 64, 255 } },
        // Oblique light with an exact-ish unit vector: dot ~ 0.8 in f64.
        // 128*0.8+0.5 -> 102, 64*0.8+0.5 -> 51, 255*dot+0.5 -> 204.
        .{ .name = "oblique", .light = .{ .direction = .{ 0.6, 0, 0.8 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0, 0, 0 } }, .expected = .{ 102, 51, 204, 255 } },
    };

    for (cases) |case| {
        var frame = try R.extractDrawList(&sc, cam, .front_to_back, gpa);
        defer frame.deinit();
        try testing.expectEqual(@as(usize, 1), frame.count());

        var target = try R.Target.init(width, height, color, depth);
        target.clear(.{ 0, 0, 0, 255 }, 1.0);

        const res = LitResources{ .meshes = &meshes, .palette = &palette, .light = case.light };
        const stats = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{});
        try testing.expectEqual(@as(usize, 2), stats.submitted);
        try testing.expect(stats.pixels > 0);
        // The provider's light shaded the quad: the center is full albedo * lm.
        std.testing.expectEqualSlices(u8, &case.expected, &target.colorAt(width / 2, height / 2)) catch |err| {
            std.debug.print("case {s}: center mismatch\n", .{case.name});
            return err;
        };
    }
}

test "lit integration: a world rotation reaches the light; culling composes with it" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    // 180 degrees about Y: (0, 1, 0, 0); the quaternion path builds diag(-1, 1, -1)
    // with exact integer products, so the face normal is exactly (0, 0, -1).
    var sc = try quadScene(gpa, "turned", .{ 0, 1, 0, 0 });
    defer sc.deinit();

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, aspect, 0.5, 100);

    const meshes = [_]R.RasterMesh{lit_mesh};
    const palette = [_][4]f32{.{ 0.5, 0.25, 1.0, 1.0 }};
    const res = LitResources{ .meshes = &meshes, .palette = &palette, .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.25, 0.25 } } };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);

    var frame = try R.extractDrawList(&sc, cam, .front_to_back, gpa);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 1), frame.count());

    // Default cull is back-face: the rotated quad is rejected, buffer untouched.
    var target = try R.Target.init(width, height, color, depth);
    target.clear(.{ 9, 9, 9, 255 }, 1.0);
    _ = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{});
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255 }, &target.colorAt(width / 2, height / 2));

    // With culling off the world-side normal does the lighting: facing the
    // ambient only, per channel: floor(c * 0.25 + 0.5).
    target.clear(.{ 9, 9, 9, 255 }, 1.0);
    _ = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{ .cull = .none });
    try testing.expectEqualSlices(u8, &.{ 32, 16, 64, 255 }, &target.colorAt(width / 2, height / 2));
}

test "lit integration: an explicit options.light wins over the provider's" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    var sc = try quadScene(gpa, "override", .{ 0, 0, 0, 1 });
    defer sc.deinit();

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, aspect, 0.5, 100);

    const meshes = [_]R.RasterMesh{lit_mesh};
    const palette = [_][4]f32{.{ 0.5, 0.25, 1.0, 1.0 }};
    // The provider would answer with (1, 0, 0) + ambient 1/4 ({32, 16, 64}) ...
    const res = LitResources{ .meshes = &meshes, .palette = &palette, .light = .{ .direction = .{ 1, 0, 0 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.25, 0.25 } } };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);

    var frame = try R.extractDrawList(&sc, cam, .front_to_back, gpa);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 1), frame.count());

    // ... but the caller's explicit light (dead-on, ambient 0) must win.
    var target = try R.Target.init(width, height, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);
    _ = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{ .light = .{ .direction = .{ 0, 0, 1 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0, 0, 0 } } });
    try testing.expectEqualSlices(u8, &.{ 128, 64, 255, 255 }, &target.colorAt(width / 2, height / 2));
}

test "blended integration: back_to_front extraction + alpha blending round-trips" {
    const gpa = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 24;
    const count = @as(usize, width) * height;

    var sc = try TestScene.init(gpa, "main");
    defer sc.deinit();

    // Two quads on the same axis: a large opaque one behind, a smaller
    // half-transparent one in front, both facing the camera.
    const back = try sc.createEntity("back", null);
    try sc.addComponent(back, corex.scene.Transform{ .position = .{ 0, 0, -2 } });
    try sc.addComponent(back, R.Renderable{
        .mesh = 0,
        .material = 0,
        .bounds = R.Aabb.fromMinMax(.{ -2, -2, -0.1 }, .{ 2, 2, 0.1 }),
    });
    const front = try sc.createEntity("front", null);
    try sc.addComponent(front, corex.scene.Transform{ .position = .{ 0, 0, 1 } });
    try sc.addComponent(front, R.Renderable{
        .mesh = 0,
        .material = 1,
        .bounds = R.Aabb.fromMinMax(.{ -2, -2, -0.1 }, .{ 2, 2, 0.1 }),
    });

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam = R.Camera.perspectiveLookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, std.math.pi / 2.0, aspect, 0.5, 100);

    // back_to_front is the sort the transparent pass needs: the near quad must
    // be composited last, after the far one.
    var frame = try R.extractDrawList(&sc, cam, .back_to_front, gpa);
    defer frame.deinit();
    try testing.expectEqual(@as(usize, 2), frame.count());
    try testing.expectEqual(front, frame.commands[1].entity);

    const big = [_][3]f32{ .{ -2, -2, 0 }, .{ 2, -2, 0 }, .{ 2, 2, 0 }, .{ -2, 2, 0 } };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const meshes = [_]R.RasterMesh{.{ .positions = &big, .indices = &indices }};
    // Opaque blue behind, half-alpha red in front.
    const res = Resources{ .meshes = &meshes, .palette = &.{ .{ 0, 0, 1, 1 }, .{ 1, 0, 0, 0.5 } } };

    const color = try gpa.alloc(u8, count * 4);
    defer gpa.free(color);
    const depth = try gpa.alloc(f32, count);
    defer gpa.free(depth);
    var target = try R.Target.init(width, height, color, depth);
    target.clear(.{ 0, 0, 0, 255 }, 1.0);

    // depth_write off on the transparent pass so the front quad composites on
    // top instead of being occluded by its own depth.
    _ = try R.rasterize(&target, frame.commands, cam.view_projection, res, .{ .blend = .alpha, .depth_write = false });

    // sa = 128/255, keep = 127/255 over opaque blue: red -> 128, blue -> 127.
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, &target.colorAt(width / 2, height / 2));

    // The composited frame is still plain RGBA8 and round-trips through QOI.
    const img = A.image.Image{ .width = width, .height = height, .pixels = target.color };
    const encoded = try A.image.encodeQoi(gpa, img);
    defer gpa.free(encoded);
    var decoded = try A.image.decodeQoi(gpa, encoded);
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, target.color, decoded.pixels);
}
