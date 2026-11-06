#!/usr/bin/env python3
"""Generate reference vectors for the CoreX software rasterizer.

The reference deliberately does NOT mirror the Zig implementation's structure.
Zig steps the edge functions incrementally across each scanline; this reference
recomputes all three edge functions from scratch for every pixel using Python
arbitrary-precision integers. Agreement therefore validates the incremental
stepping, the bounding-box clamp and the fill-rule bias independently, rather
than merely restating them.

Coverage is exact integer arithmetic, so it must match bit for bit. Depth is
interpolated in IEEE float64 with a pinned operation order and then rounded to
float32, which is likewise reproducible.

Output: src/render/raster_vectors.zig (committed; CI never runs this script).

Usage: python3 tools/gen_raster_vectors.py
"""

import random
import struct
from pathlib import Path

SUBPIXEL_BITS = 4
SUBPIXEL_SCALE = 1 << SUBPIXEL_BITS
HALF = SUBPIXEL_SCALE // 2

WIDTH = 8
HEIGHT = 8


def edge(ax, ay, bx, by, px, py):
    """Twice the signed area of (a, b, p), exact integer arithmetic."""
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)


def is_top_left(ax, ay, bx, by):
    """Top edge: horizontal, interior below (runs left-to-right).
    Left edge: interior to the right (runs upwards in a Y-down buffer)."""
    dy = by - ay
    dx = bx - ax
    return (dy == 0 and dx > 0) or dy < 0


def f32(x):
    """Round a Python float to the nearest float32 and back."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_bits(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def rasterize(tri, cull="none", front_face="ccw", depth_test=True, depth_write=True,
              initial_depth=None):
    """Reference rasterization. Returns (drew, mask, depth_buffer).

    `tri` is three (x, y, z) tuples with x/y in 28.4 fixed point and z a float32.
    """
    v = list(tri)
    area = edge(v[0][0], v[0][1], v[1][0], v[1][1], v[2][0], v[2][1])
    if area == 0:
        return False, [0] * (WIDTH * HEIGHT), None

    front = area < 0 if front_face == "ccw" else area > 0
    if cull == "back" and not front:
        return False, [0] * (WIDTH * HEIGHT), None
    if cull == "front" and front:
        return False, [0] * (WIDTH * HEIGHT), None

    if area < 0:
        v[1], v[2] = v[2], v[1]
        area = -area

    inv_area = 1.0 / float(area)
    mask = [0] * (WIDTH * HEIGHT)
    depth = list(initial_depth) if initial_depth is not None else [1.0] * (WIDTH * HEIGHT)

    # Exhaustive scan of the whole target: no bounding box at all, so the Zig
    # bbox clamp is checked against a brute-force ground truth.
    for y in range(HEIGHT):
        for x in range(WIDTH):
            px = x * SUBPIXEL_SCALE + HALF
            py = y * SUBPIXEL_SCALE + HALF
            i = y * WIDTH + x
            inside = True
            weights = []
            for k in range(3):
                a = v[(k + 1) % 3]
                b = v[(k + 2) % 3]
                e = edge(a[0], a[1], b[0], b[1], px, py)
                bias = 0 if is_top_left(a[0], a[1], b[0], b[1]) else 1
                if e - bias < 0:
                    inside = False
                    break
                weights.append(e)
            if not inside:
                continue
            z = ((float(weights[0]) * v[0][2] + float(weights[1]) * v[1][2])
                 + float(weights[2]) * v[2][2]) * inv_area
            z = f32(z)
            if not depth_test or z < depth[i]:
                mask[i] = 1
                if depth_write:
                    depth[i] = z
    return True, mask, depth


def mask_bytes(mask):
    out = [0] * ((len(mask) + 7) // 8)
    for i, bit in enumerate(mask):
        out[i // 8] |= bit << (i % 8)
    return out


def build_cases():
    cases = []

    def add(name, tri, **kw):
        drew, mask, depth = rasterize(tri, **kw)
        covered_depths = []
        if drew:
            for i, bit in enumerate(mask):
                if bit:
                    covered_depths.append(f32_bits(depth[i]))
        cases.append({
            "name": name,
            "tri": tri,
            "cull": kw.get("cull", "none"),
            "front_face": kw.get("front_face", "ccw"),
            "depth_test": kw.get("depth_test", True),
            "depth_write": kw.get("depth_write", True),
            "drew": drew,
            "mask": mask_bytes(mask),
            "depths": covered_depths,
        })

    def px(x, y, z=0.0):
        return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)), f32(z))

    # Axis-aligned and hand-checkable shapes.
    add("right_triangle", [px(0, 0), px(4, 0), px(0, 4)])
    add("full_quad_lower", [px(0, 0), px(8, 0), px(0, 8)])
    add("full_quad_upper", [px(8, 0), px(8, 8), px(0, 8)])
    add("thin_sliver", [px(0, 0), px(8, 0.0625), px(8, 0)])
    add("collinear", [px(0, 0), px(4, 4), px(8, 8)])
    add("coincident", [px(3, 3), px(3, 3), px(3, 3)])
    add("horizontal_line", [px(0, 2), px(4, 2), px(8, 2)])
    add("offscreen_left", [px(-9, 0), px(-1, 0), px(-5, 8)])
    add("offscreen_right", [px(9, 0), px(17, 0), px(13, 8)])
    add("straddling_left", [px(-4, -4), px(4, 0), px(-4, 12)])
    add("huge_covering", [px(-100, -100), px(100, -100), px(0, 100)])
    add("single_pixel", [px(2, 2), px(3, 2), px(2, 3)])
    add("subpixel_small", [px(2.25, 2.25), px(2.75, 2.25), px(2.5, 2.75)])
    add("center_sample_on_vertex", [px(2.5, 2.5), px(6.5, 2.5), px(2.5, 6.5)])

    # Depth gradients, including negative and near-boundary values.
    add("depth_flat", [px(0, 0, 0.25), px(8, 0, 0.25), px(0, 8, 0.25)])
    add("depth_gradient_x", [px(0, 0, -1), px(8, 0, 1), px(0, 8, -1)])
    add("depth_gradient_y", [px(0, 0, -0.5), px(8, 0, -0.5), px(0, 8, 0.75)])
    add("depth_gradient_both", [px(0, 0, -1), px(8, 0, 0), px(0, 8, 1)])
    add("depth_all_far", [px(0, 0, 1), px(8, 0, 1), px(0, 8, 1)])
    add("depth_no_write", [px(0, 0, -0.9), px(8, 0, 0.9), px(0, 8, 0)], depth_write=False)
    add("depth_no_test", [px(0, 0, 0.9), px(8, 0, 0.9), px(0, 8, 0.9)], depth_test=False)

    # Winding and culling combinations.
    for ff in ("ccw", "cw"):
        for cull in ("none", "back", "front"):
            add(f"cull_{ff}_{cull}_a", [px(1, 1), px(7, 2), px(3, 7)], cull=cull, front_face=ff)
            add(f"cull_{ff}_{cull}_b", [px(1, 1), px(3, 7), px(7, 2)], cull=cull, front_face=ff)

    # Deterministic random subpixel triangles.
    rng = random.Random(20261106)
    for n in range(40):
        tri = []
        for _ in range(3):
            x = rng.randint(-3 * SUBPIXEL_SCALE, 11 * SUBPIXEL_SCALE)
            y = rng.randint(-3 * SUBPIXEL_SCALE, 11 * SUBPIXEL_SCALE)
            z = f32(rng.uniform(-1.0, 1.0))
            tri.append((x, y, z))
        cull = rng.choice(["none", "none", "back", "front"])
        add(f"random_{n:02d}", tri, cull=cull,
            front_face=rng.choice(["ccw", "cw"]),
            depth_write=rng.random() < 0.8)

    return cases


def emit(cases):
    lines = []
    lines.append("//! Reference vectors for the software rasterizer's screen-space core.")
    lines.append("//!")
    lines.append("//! GENERATED by tools/gen_raster_vectors.py -- do not edit by hand.")
    lines.append("//! Coverage comes from exact integer edge functions evaluated brute-force")
    lines.append("//! over every pixel; depth from a pinned float64 expression rounded to f32.")
    lines.append("//! Both must match the rasterizer bit for bit.")
    lines.append("")
    lines.append("pub const width: u32 = 8;")
    lines.append("pub const height: u32 = 8;")
    lines.append("")
    lines.append("pub const Vertex = struct { x: i32, y: i32, z: f32 };")
    lines.append("")
    lines.append("pub const Case = struct {")
    lines.append("    name: []const u8,")
    lines.append("    /// Three vertices: x and y in 28.4 fixed point, z as NDC depth.")
    lines.append("    tri: [3]Vertex,")
    lines.append("    cull: enum { none, back, front },")
    lines.append("    front_face: enum { ccw, cw },")
    lines.append("    depth_test: bool,")
    lines.append("    depth_write: bool,")
    lines.append("    drew: bool,")
    lines.append("    /// Little-endian bit per pixel, row-major: 1 where the color was written.")
    lines.append("    mask: [8]u8,")
    lines.append("    /// f32 bit patterns of the written depths, in row-major pixel order.")
    lines.append("    depths: []const u32,")
    lines.append("};")
    lines.append("")
    lines.append("pub const cases = [_]Case{")
    for c in cases:
        tri = ", ".join(
            ".{{ .x = {0}, .y = {1}, .z = {2} }}".format(v[0], v[1], repr(v[2]))
            for v in c["tri"]
        )
        mask = ", ".join(str(b) for b in c["mask"])
        depths = ", ".join("0x{0:08x}".format(d) for d in c["depths"])
        lines.append("    .{")
        lines.append('        .name = "{0}",'.format(c["name"]))
        lines.append("        .tri = .{{ {0} }},".format(tri))
        lines.append("        .cull = .{0},".format(c["cull"]))
        lines.append("        .front_face = .{0},".format(c["front_face"]))
        lines.append("        .depth_test = {0},".format(str(c["depth_test"]).lower()))
        lines.append("        .depth_write = {0},".format(str(c["depth_write"]).lower()))
        lines.append("        .drew = {0},".format(str(c["drew"]).lower()))
        lines.append("        .mask = .{{ {0} }},".format(mask))
        if len(c["depths"]) == 1:
            lines.append("        .depths = &.{{{0}}},".format(depths))
        elif depths:
            lines.append("        .depths = &.{{ {0} }},".format(depths))
        else:
            lines.append("        .depths = &.{},")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def main():
    cases = build_cases()
    root = Path(__file__).resolve().parent.parent
    out = root / "src" / "render" / "raster_vectors.zig"
    out.write_text(emit(cases))
    drew = sum(1 for c in cases if c["drew"])
    pixels = sum((b >> i) & 1 for c in cases for b in c["mask"] for i in range(8))
    print(f"wrote {out.relative_to(root)}")
    print(f"  cases: {len(cases)}  drew: {drew}  culled/degenerate: {len(cases) - drew}")
    print(f"  covered pixels across all cases: {pixels}")


if __name__ == "__main__":
    main()
