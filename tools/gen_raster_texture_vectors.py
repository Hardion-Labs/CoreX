#!/usr/bin/env python3
"""Generate reference vectors for texture-mapped rasterization.

Companion to gen_raster_vectors.py: identical integer edge-function coverage
(brute force, no bounding box) plus perspective-correct UV interpolation and
texture sampling, recomputed from first principles for every pixel. The float
expressions are pinned to the exact operation order used by the Zig shading
path (f64 throughout, floor(x + 0.5) for the final round), so both sides agree
bit for bit.

The expected frames are emitted as full 8x8 RGBA buffers, which also covers
alpha verbatim writes (no blending exists yet).

Output: src/render/raster_texture_vectors.zig (committed; CI never runs this).

Usage: python3 tools/gen_raster_texture_vectors.py
"""

import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_raster_vectors import SUBPIXEL_SCALE, HALF, edge, is_top_left, mask_bytes  # noqa: E402

WIDTH = 8
HEIGHT = 8
TEX = 4

# One non-symmetric 4x4 texture shared by every case: R depends on x, G on y,
# B on x+y, A constant 255 with a transparent corner to pin alpha writes.
def texel(x, y):
    if x == 0 and y == 0:
        return (10, 20, 30, 0)
    return ((x * 57 + 29) % 256, (y * 73 + 41) % 256, ((x + y) * 31 + 17) % 256, 255)


TEX_PIXELS = [c for y in range(TEX) for x in range(TEX) for c in texel(x, y)]


def f64_bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def repeat_frac(t):
    import math
    return t - math.floor(t)


def wrap_index(t, n):
    import math
    return int(math.floor(t)) % n


def fetch(tx, ty, c):
    return float(TEX_PIXELS[(ty * TEX + tx) * 4 + c])


def sample_nearest(u, v):
    uf, vf = repeat_frac(u), repeat_frac(v)
    x = min(TEX - 1, int(uf * TEX))
    y = min(TEX - 1, int(vf * TEX))
    off = (y * TEX + x) * 4
    return [TEX_PIXELS[off + c] for c in range(4)]


def sample_bilinear(u, v):
    import math
    uf, vf = repeat_frac(u), repeat_frac(v)
    tx = uf * TEX - 0.5
    ty = vf * TEX - 0.5
    fx = tx - math.floor(tx)
    fy = ty - math.floor(ty)
    x0, x1 = wrap_index(tx, TEX), (wrap_index(tx, TEX) + 1) % TEX
    y0, y1 = wrap_index(ty, TEX), (wrap_index(ty, TEX) + 1) % TEX
    out = []
    for c in range(4):
        c00, c10 = fetch(x0, y0, c), fetch(x1, y0, c)
        c01, c11 = fetch(x0, y1, c), fetch(x1, y1, c)
        top = (c00 * (1.0 - fx) + c10 * fx) * (1.0 - fy)
        bottom = (c01 * (1.0 - fx) + c11 * fx) * fy
        out.append(int(math.floor(top + bottom + 0.5)))
    return out


def tint_multiply(texel_rgba, tint):
    return [int(math_floor(t * n / 255.0 + 0.5)) for t, n in zip(texel_rgba, tint)]


def math_floor(t):
    import math
    return math.floor(t)


def shade(vertex, w0, w1, w2, area_inv, tint, filt):
    # vertex tuples: (x, y, z, uw, vw, w_inv) with uw/vw pre-divided by w.
    den = ((w0 * vertex[0][5] + w1 * vertex[1][5]) + w2 * vertex[2][5]) * area_inv
    if not (den > 0.0) or den != den or den == float("inf"):
        u = v = 0.0
    else:
        u = (((w0 * vertex[0][3] + w1 * vertex[1][3]) + w2 * vertex[2][3]) * area_inv) / den
        v = (((w0 * vertex[0][4] + w1 * vertex[1][4]) + w2 * vertex[2][4]) * area_inv) / den
    texel = sample_nearest(u, v) if filt == "nearest" else sample_bilinear(u, v)
    return tint_multiply(texel, tint)


def rasterize(vertex, tint, filt, cull="none", front_face="ccw",
              depth_test=True, depth_write=True):
    """vertex: three (x, y, z, uw, vw, w_inv) tuples. Returns (drew, mask, frame)."""
    v = list(vertex)
    area = edge(v[0][0], v[0][1], v[1][0], v[1][1], v[2][0], v[2][1])
    if area == 0:
        return False, [0] * (WIDTH * HEIGHT), [0] * (WIDTH * HEIGHT * 4)

    front = area < 0 if front_face == "ccw" else area > 0
    if cull == "back" and not front:
        return False, [0] * (WIDTH * HEIGHT), [0] * (WIDTH * HEIGHT * 4)
    if cull == "front" and front:
        return False, [0] * (WIDTH * HEIGHT), [0] * (WIDTH * HEIGHT * 4)

    if area < 0:
        v[1], v[2] = v[2], v[1]
        area = -area

    inv_area = 1.0 / float(area)
    mask = [0] * (WIDTH * HEIGHT)
    frame = [0] * (WIDTH * HEIGHT * 4)
    depth = [1.0] * (WIDTH * HEIGHT)

    for y in range(HEIGHT):
        for x in range(WIDTH):
            px = x * SUBPIXEL_SCALE + HALF
            py = y * SUBPIXEL_SCALE + HALF
            i = y * WIDTH + x
            weights = []
            inside = True
            for k in range(3):
                a = v[(k + 1) % 3]
                b = v[(k + 2) % 3]
                e = edge(a[0], a[1], b[0], b[1], px, py)
                bias = 0 if is_top_left(a[0], a[1], b[0], b[1]) else 1
                if e - bias < 0:
                    inside = False
                    break
                weights.append(float(e))
            if not inside:
                continue
            z = ((weights[0] * v[0][2] + weights[1] * v[1][2]) + weights[2] * v[2][2]) * inv_area
            z = struct.unpack("<f", struct.pack("<f", z))[0]
            if not depth_test or z < depth[i]:
                mask[i] = 1
                frame[i * 4: i * 4 + 4] = shade(v, weights[0], weights[1], weights[2], inv_area, tint, filt)
                if depth_write:
                    depth[i] = z
    return True, mask, frame


def px(x, y, z=0.0, u=0.0, v=0.0):
    """x/y in pixels (fixed point applied); u/v raw (pre-divide). w = 1."""
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)),
            struct.unpack("<f", struct.pack("<f", z))[0], float(u), float(v), 1.0)


def pxw(x, y, z, u, v, w):
    """Non-unit w clip vertex: uw/vw are pre-divided by w at construction."""
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)),
            struct.unpack("<f", struct.pack("<f", z))[0], float(u) / w, float(v) / w, 1.0 / w)


def cases():
    out = []

    def add(name, tri, filt="bilinear", tint=(255, 255, 255, 255), **kw):
        drew, mask, frame = rasterize(tri, tint, filt, **kw)
        out.append({"name": name, "tri": tri, "filt": filt, "tint": tint,
                    "cull": kw.get("cull", "none"),
                    "front_face": kw.get("front_face", "ccw"),
                    "depth_test": kw.get("depth_test", True),
                    "depth_write": kw.get("depth_write", True),
                    "drew": drew, "mask": mask_bytes(mask), "frame": frame})

    # Axis-aligned UV gradients, nearest and bilinear.
    add("uv_gradient_nearest", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], filt="nearest")
    add("uv_gradient_bilinear", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], filt="bilinear")
    add("uv_offset", [px(0, 0, 0, 0.25, 0.1), px(8, 0, 0, 1.25, 0.1), px(0, 8, 0, 0.25, 1.1)])
    # Repeat wrap: UVs well outside [0, 1], including negatives.
    add("uv_repeat_positive", [px(0, 0, 0, 2.0, 3.0), px(8, 0, 0, 4.5, 3.25), px(0, 8, 0, 2.5, 6.0)])
    add("uv_repeat_negative", [px(0, 0, 0, -2.0, -3.0), px(8, 0, 0, 0.5, -2.75), px(0, 8, 0, -1.5, 1.0)])
    add("uv_repeat_negative_nearest", [px(0, 0, 0, -2.0, -3.0), px(8, 0, 0, 0.5, -2.75), px(0, 8, 0, -1.5, 1.0)], filt="nearest")
    # Perspective-correct interpolation: near vertex (big w_inv) pulls UVs.
    add("perspective_nearest", [pxw(0, 0, 0, 0.0, 0.0, 1.8), pxw(8, 0, 0, 1.0, 0.0, 1.0), pxw(0, 8, 0, 0.0, 1.0, 1.0)], filt="nearest")
    add("perspective_bilinear", [pxw(0, 0, 0, 0.0, 0.0, 1.8), pxw(8, 0, 0, 1.0, 0.0, 1.0), pxw(0, 8, 0, 0.0, 1.0, 1.0)], filt="bilinear")
    add("perspective_far", [pxw(0, 0, 0, 1.0, 1.0, 0.6), pxw(8, 0, 0, 2.0, 1.0, 1.0), pxw(0, 8, 0, 1.0, 2.0, 1.0)])
    add("perspective_mixed", [pxw(0, 0, 0, 0.1, 0.2, 1.7), pxw(8, 0, 0, 1.9, 0.2, 0.8), pxw(0, 8, 0, 0.1, 2.1, 1.1)], filt="nearest")
    # Tints: identity, half, saturated red-magenta, and a half-alpha tint.
    add("tint_gray", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], tint=(128, 128, 128, 255))
    add("tint_magenta", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], tint=(255, 0, 128, 255))
    add("tint_half_alpha", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], tint=(255, 255, 255, 128))
    add("tint_black", [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)], tint=(0, 0, 0, 255))
    # Cull modes still gate coverage before any sampling happens.
    add("uv_culled_back", [px(1, 1, 0, 0, 0), px(7, 2, 0, 1, 0), px(3, 7, 0, 0, 1)], cull="back", front_face="ccw")
    add("uv_culled_front", [px(1, 1, 0, 0, 0), px(3, 7, 0, 0, 1), px(7, 2, 0, 1, 0)], cull="front", front_face="ccw")
    # Deterministic random cases: subpixel positions, random UVs and w, both filters.
    rng = random.Random(20261107)
    for n in range(28):
        tri = []
        for _ in range(3):
            x = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            y = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            z = struct.unpack("<f", struct.pack("<f", rng.uniform(-1, 1)))[0]
            u = rng.uniform(-1.5, 2.5)
            v = rng.uniform(-1.5, 2.5)
            w = rng.uniform(0.5, 2.0)
            tri.append((x, y, z, u / w, v / w, 1.0 / w))
        add(f"random_{n:02d}", tri,
            filt=rng.choice(["nearest", "bilinear"]),
            tint=rng.choice([(255, 255, 255, 255), (200, 220, 255, 255), (255, 200, 128, 255)]),
            cull=rng.choice(["none", "none", "back"]),
            front_face=rng.choice(["ccw", "cw"]))

    return out


def emit(all_cases):
    lines = []
    lines.append("//! Reference vectors for texture-mapped rasterization.")
    lines.append("//!")
    lines.append("//! GENERATED by tools/gen_raster_texture_vectors.py -- do not edit by hand.")
    lines.append("//! Coverage reuses the exact integer edge functions of the base vectors;")
    lines.append("//! UV interpolation and sampling recompute the pinned f64 expressions over")
    lines.append("//! every pixel. Expected frames must match bit for bit.")
    lines.append("")
    lines.append("pub const width: u32 = 8;")
    lines.append("pub const height: u32 = 8;")
    lines.append("")
    lines.append("/// The shared 4x4 RGBA8 texture every case samples (row-major, top-down).")
    tex = ", ".join(str(b) for b in TEX_PIXELS)
    lines.append(f"pub const texture = [_]u8{{ {tex} }};")
    lines.append("")
    lines.append("pub const Vertex = struct { x: i32, y: i32, z: f32, uw: f64, vw: f64, w_inv: f64 };")
    lines.append("")
    lines.append("pub const Case = struct {")
    lines.append("    name: []const u8,")
    lines.append("    /// Three screen-space vertices: x/y in 28.4 fixed point, z NDC,")
    lines.append("    /// uw/vw = u|v / w, w_inv = 1/w (both f64).")
    lines.append("    tri: [3]Vertex,")
    lines.append("    filter: enum { nearest, bilinear },")
    lines.append("    tint: [4]u8,")
    lines.append("    cull: enum { none, back, front },")
    lines.append("    front_face: enum { ccw, cw },")
    lines.append("    depth_test: bool,")
    lines.append("    depth_write: bool,")
    lines.append("    drew: bool,")
    lines.append("    /// Little-endian bit per pixel, row-major: 1 where the color was written.")
    lines.append("    mask: [8]u8,")
    lines.append("    /// Expected 8x8 RGBA8 frame, row-major (clear pixels stay zero).")
    lines.append("    frame: []const u8,")
    lines.append("};")
    lines.append("")
    lines.append("pub const cases = [_]Case{")
    for c in all_cases:
        tri = ", ".join(
            ".{{ .x = {0}, .y = {1}, .z = {2}, .uw = {3!r}, .vw = {4!r}, .w_inv = {5!r} }}".format(
                v[0], v[1], repr(v[2]), v[3], v[4], v[5])
            for v in c["tri"]
        )
        mask = ", ".join(str(b) for b in c["mask"])
        tint = ", ".join(str(b) for b in c["tint"])
        frame = ", ".join("0x{0:02x}".format(b) for b in c["frame"])
        lines.append("    .{")
        lines.append('        .name = "{0}",'.format(c["name"]))
        lines.append("        .tri = .{{ {0} }},".format(tri))
        lines.append("        .filter = .{0},".format(c["filt"]))
        lines.append("        .tint = .{{ {0} }},".format(tint))
        lines.append("        .cull = .{0},".format(c["cull"]))
        lines.append("        .front_face = .{0},".format(c["front_face"]))
        lines.append("        .depth_test = {0},".format(str(c["depth_test"]).lower()))
        lines.append("        .depth_write = {0},".format(str(c["depth_write"]).lower()))
        lines.append("        .drew = {0},".format(str(c["drew"]).lower()))
        lines.append("        .mask = .{{ {0} }},".format(mask))
        lines.append("        .frame = &.{{ {0} }},".format(frame))
        lines.append("    },")
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def main():
    all_cases = cases()
    root = Path(__file__).resolve().parent.parent
    out = root / "src" / "render" / "raster_texture_vectors.zig"
    out.write_text(emit(all_cases))
    drew = sum(1 for c in all_cases if c["drew"])
    pixels = sum((b >> i) & 1 for c in all_cases for b in c["mask"] for i in range(8))
    print(f"wrote {out.relative_to(root)}")
    print(f"  cases: {len(all_cases)}  drew: {drew}  culled/degenerate: {len(all_cases) - drew}")
    print(f"  covered pixels across all cases: {pixels}")


if __name__ == "__main__":
    main()
