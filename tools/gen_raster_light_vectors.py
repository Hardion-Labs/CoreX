#!/usr/bin/env python3
"""Generate reference vectors for the Lambert-lit rasterization path.

Same brute-force coverage as gen_raster_vectors.py (every pixel, integer edge
functions, no bounding box) plus the light path: the raw world-space face
normal is an input (the rasterizer normalizes it per triangle), the light's
direction is normalized, and the per-channel multiplier
`ambient + max(0, n . l) * color` is applied to the albedo tint (flat) or to
texel x tint (textured), with a single clamp at the final quantization.

Float expressions are pinned to the exact operation order used by the Zig
implementation (f64 throughout, floor(min(max(s, 0), 255) + 0.5) for bytes),
so both sides agree bit for bit. Light components are f32 on the Zig side;
the Python reference rounds them to f32 before computing.

Output: src/render/raster_light_vectors.zig (committed; CI never runs this).

Usage: python3 tools/gen_raster_light_vectors.py
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


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def texel(x, y):
    if x == 0 and y == 0:
        return (10, 20, 30, 0)
    return ((x * 57 + 29) % 256, (y * 73 + 41) % 256, ((x + y) * 31 + 17) % 256, 255)


TEX_PIXELS = [c for y in range(TEX) for x in range(TEX) for c in texel(x, y)]


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


def normalize3(x, y, z):
    # Pinned: sqrt((x*x + y*y) + z*z)
    import math
    length = math.sqrt((x * x + y * y) + z * z)
    if not (length > 0.0) or not math.isfinite(length):
        return (0.0, 0.0, 0.0)
    return (x / length, y / length, z / length)


def light_multiplier(light, raw_normal):
    # Light components are f32 on the Zig side; round before use.
    lx, ly, lz = (f32(light["direction"][0]), f32(light["direction"][1]), f32(light["direction"][2]))
    l = normalize3(lx, ly, lz)
    nrm = normalize3(raw_normal[0], raw_normal[1], raw_normal[2])
    dot = max(0.0, (nrm[0] * l[0] + nrm[1] * l[1]) + nrm[2] * l[2])
    return [f32(light["ambient"][c]) + dot * f32(light["color"][c]) for c in range(3)]


def clamp_byte(s):
    import math
    return int(math.floor(min(max(s, 0.0), 255.0) + 0.5))


def alpha_byte(t, tint):
    import math
    return int(math.floor(float(t) * float(tint) / 255.0 + 0.5))


def shade(vertex, w0, w1, w2, area_inv, tint, use_texture, filt, light, raw_normal):
    tex = None
    if use_texture:
        den = ((w0 * vertex[0][5] + w1 * vertex[1][5]) + w2 * vertex[2][5]) * area_inv
        if den > 0.0 and den == den and den != float("inf"):
            u = (((w0 * vertex[0][3] + w1 * vertex[1][3]) + w2 * vertex[2][3]) * area_inv) / den
            v = (((w0 * vertex[0][4] + w1 * vertex[1][4]) + w2 * vertex[2][4]) * area_inv) / den
        else:
            u = v = 0.0
        tex = sample_nearest(u, v) if filt == "nearest" else sample_bilinear(u, v)

    out = [0, 0, 0, 0]
    if light is None:
        if tex is None:
            for c in range(4):
                out[c] = tint[c]
            return out
        for c in range(4):
            out[c] = alpha_byte(tex[c], tint[c]) if c == 3 else int(math_floor(tex[c] * tint[c] / 255.0 + 0.5))
        return out

    lm = light_multiplier(light, raw_normal)
    for c in range(3):
        if tex is None:
            out[c] = clamp_byte(float(tint[c]) * lm[c])
        else:
            s = ((float(tex[c]) * float(tint[c])) * lm[c]) / 255.0
            out[c] = clamp_byte(s)
    # Alpha is never lit.
    if tex is None:
        out[3] = tint[3]
    else:
        out[3] = alpha_byte(tex[3], tint[3])
    return out


def math_floor(t):
    import math
    return math.floor(t)


def rasterize(vertex, tint, use_texture, filt, light, raw_normal,
              cull="none", front_face="ccw", depth_test=True, depth_write=True):
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
            z = f32(z)
            if not depth_test or z < depth[i]:
                mask[i] = 1
                frame[i * 4: i * 4 + 4] = shade(v, weights[0], weights[1], weights[2], inv_area,
                                                tint, use_texture, filt, light, raw_normal)
                if depth_write:
                    depth[i] = z
    return True, mask, frame


def px(x, y, z=0.0, u=0.0, v=0.0):
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)), f32(z),
            float(u), float(v), 1.0)


def pxw(x, y, z, u, v, w):
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)), f32(z),
            float(u) / w, float(v) / w, 1.0 / w)


def cases():
    out = []
    white = (255, 255, 255, 255)
    quad = [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)]

    def add(name, tri, raw_normal, light, tint=white, use_texture=False, filt="bilinear",
            cull="none", front_face="ccw", depth_test=True, depth_write=True):
        drew, mask, frame = rasterize(tri, tint, use_texture, filt, light, raw_normal,
                                      cull=cull, front_face=front_face,
                                      depth_test=depth_test, depth_write=depth_write)
        out.append({"name": name, "tri": tri, "raw_normal": raw_normal, "light": light,
                    "tint": tint, "use_texture": use_texture, "filt": filt,
                    "cull": cull, "front_face": front_face,
                    "depth_test": depth_test, "depth_write": depth_write,
                    "drew": drew, "mask": mask_bytes(mask), "frame": frame})

    L_full = {"direction": (0.0, 0.0, 5.0), "color": (1.0, 1.0, 1.0), "ambient": (0.0, 0.0, 0.0)}
    L_half = {"direction": (0.0, 0.0, 1.0), "color": (0.5, 0.5, 0.5), "ambient": (0.0, 0.0, 0.0)}
    L_amb = {"direction": (0.0, 0.0, 1.0), "color": (0.0, 0.0, 0.0), "ambient": (0.25, 0.5, 0.75)}

    # Full diffuse: dot = 1, light*1 leaves the tint unchanged.
    add("light_full_diffuse", quad, (0.0, 0.0, 1.0), L_full, tint=(100, 150, 200, 255))
    # Half-gray spot: floor(t * 0.5 + 0.5).
    add("light_half", quad, (0.0, 0.0, 400.0), L_half, tint=(100, 150, 200, 255))
    # Facing away: ambient only, per-channel floor.
    add("light_facing_away", quad, (0.0, 0.0, -1.0), L_amb, tint=(100, 150, 200, 255))
    # Degenerate normal: ambient only, no NaN.
    add("light_zero_normal", quad, (0.0, 0.0, 0.0), L_amb, tint=(100, 150, 200, 255))
    # Oblique incidence at a non-round angle.
    add("light_oblique", quad, (0.0, 0.0, 1.0), {"direction": (0.6, 0.0, 0.8), "color": (1.0, 1.0, 1.0), "ambient": (0.0, 0.0, 0.0)}, tint=(200, 100, 50, 255))
    # HDR ambient: channels clamp at 255, never exceed.
    add("light_hdr_ambient_clamp", quad, (0.0, 0.0, 1.0), {"direction": (0.0, 1.0, 0.0), "color": (1.0, 1.0, 1.0), "ambient": (2.5, 2.5, 2.5)}, tint=(100, 150, 200, 255))
    # Ambient fills but the spot contributes nothing perpendicular.
    add("light_perpendicular_ambient", quad, (0.0, 0.0, 1.0), {"direction": (1.0, 0.0, 0.0), "color": (1.0, 1.0, 1.0), "ambient": (0.5, 0.5, 0.5)}, tint=(200, 100, 50, 255))
    # Textured: texel * tint * lm with a non-trivial ambient.
    add("light_textured_bilinear", quad, (0.0, 0.0, 1.0), {"direction": (0.0, 0.0, 1.0), "color": (0.5, 0.5, 0.5), "ambient": (0.1, 0.1, 0.1)}, use_texture=True, filt="bilinear")
    add("light_textured_nearest", quad, (0.0, 0.0, 1.0), {"direction": (0.0, 0.0, 1.0), "color": (0.5, 0.5, 0.5), "ambient": (0.1, 0.1, 0.1)}, use_texture=True, filt="nearest")
    # Facing away: RGB goes black, alpha stays from the texel/tint multiply.
    add("light_textured_facing_away", quad, (0.0, 0.0, -1.0), {"direction": (0.0, 0.0, 1.0), "color": (1.0, 1.0, 1.0), "ambient": (0.0, 0.0, 0.0)}, use_texture=True, filt="nearest", tint=(255, 200, 128, 255))
    # Tint multiplies the lit albedo: t * tint * lm, one rounding per channel.
    add("light_textured_tint", quad, (0.0, 0.0, 1.0), {"direction": (0.0, 0.0, 1.0), "color": (0.75, 0.5, 0.25), "ambient": (0.05, 0.05, 0.05)}, use_texture=True, filt="bilinear", tint=(255, 200, 128, 255))
    # Huge raw normal (world-space cross products can be large); normalize pinned.
    add("light_huge_normal", quad, (0.0, 0.0, 4096.0), L_half, tint=(100, 150, 200, 255))
    # Tiny raw normal; normalize pinned in f64.
    add("light_tiny_normal", quad, (0.0, 0.0, 1e-6), L_half, tint=(100, 150, 200, 255))
    # Perspective-correct UVs under lighting with a colored light.
    add("light_perspective", [pxw(0, 0, 0, 0.1, 0.2, 1.7), pxw(8, 0, 0, 1.9, 0.2, 0.8), pxw(0, 8, 0, 0.1, 2.1, 1.1)], (0.0, 0.0, 1.0), {"direction": (0.2, 0.3, 0.93), "color": (0.8, 0.9, 1.0), "ambient": (0.1, 0.1, 0.1)}, use_texture=True, filt="bilinear")
    # Backface rejected before shading even with a light set.
    add("light_culled_back", [px(1, 1, 0, 0, 0), px(7, 2, 0, 1, 0), px(3, 7, 0, 0, 1)], (0.0, 0.0, 1.0), L_full, cull="back", front_face="ccw")
    # Winding flipped, no culling: the triangle is lit by the (now) back
    # side — its world normal points away from the light, so ambient only.
    add("light_flipped_none", [px(0, 0, 0, 0, 0), px(0, 8, 0, 0, 1), px(8, 0, 0, 1, 0)], (0.0, 0.0, -1.0), L_full, cull="none", tint=(100, 150, 200, 255))

    rng = random.Random(20261107)
    for n in range(24):
        tri = []
        for _ in range(3):
            x = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            y = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            z = f32(rng.uniform(-1, 1))
            u = rng.uniform(-1.5, 2.5)
            v = rng.uniform(-1.5, 2.5)
            w = rng.uniform(0.5, 2.0)
            tri.append((x, y, z, u / w, v / w, 1.0 / w))
        raw_normal = (rng.uniform(-3, 3), rng.uniform(-3, 3), rng.choice([-1.0, 1.0]) * rng.uniform(0.01, 1000.0))
        light = {
            "direction": (rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)),
            "color": tuple(rng.uniform(0.0, 1.5) for _ in range(3)),
            "ambient": tuple(rng.uniform(0.0, 1.2) for _ in range(3)),
        }
        if light["direction"] == (0.0, 0.0, 0.0):
            light["direction"] = (0.0, 0.0, 1.0)
        add(f"random_{n:02d}", tri, raw_normal, light,
            tint=rng.choice([(255, 255, 255, 255), (200, 220, 255, 255), (255, 200, 128, 255), (128, 64, 240, 255)]),
            use_texture=rng.choice([True, True, False]),
            filt=rng.choice(["nearest", "bilinear"]),
            cull=rng.choice(["none", "none", "back"]),
            front_face=rng.choice(["ccw", "cw"]))

    return out


def emit(all_cases):
    lines = []
    lines.append("//! Reference vectors for the Lambert-lit rasterization path.")
    lines.append("//!")
    lines.append("//! GENERATED by tools/gen_raster_light_vectors.py -- do not edit by hand.")
    lines.append("//! The raw world-space face normal is an input per case (the path")
    lines.append("//! normalizes it); the light multiplier is ambient + max(0, n . l) * color;")
    lines.append("//! expected frames must match bit for bit.")
    lines.append("")
    lines.append("pub const width: u32 = 8;")
    lines.append("pub const height: u32 = 8;")
    lines.append("")
    tex = ", ".join(str(b) for b in TEX_PIXELS)
    lines.append(f"/// The shared 4x4 RGBA8 texture (row-major, top-down).")
    lines.append(f"pub const texture = [_]u8{{ {tex} }};")
    lines.append("")
    lines.append("pub const Vertex = struct { x: i32, y: i32, z: f32, uw: f64, vw: f64, w_inv: f64 };")
    lines.append("")
    lines.append("pub const Light = struct {")
    lines.append("    direction: [3]f32,")
    lines.append("    color: [3]f32,")
    lines.append("    ambient: [3]f32,")
    lines.append("};")
    lines.append("")
    lines.append("pub const Case = struct {")
    lines.append("    name: []const u8,")
    lines.append("    tri: [3]Vertex,")
    lines.append("    /// Raw (NOT normalized) world-space face normal, as produced by")
    lines.append("    /// cross(b - a, c - a) from the world-space positions.")
    lines.append("    world_normal: [3]f64,")
    lines.append("    light: ?Light,")
    lines.append("    use_texture: bool,")
    lines.append("    filter: enum { nearest, bilinear },")
    lines.append("    tint: [4]u8,")
    lines.append("    cull: enum { none, back, front },")
    lines.append("    front_face: enum { ccw, cw },")
    lines.append("    depth_test: bool,")
    lines.append("    depth_write: bool,")
    lines.append("    drew: bool,")
    lines.append("    mask: [8]u8,")
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
        normal = ", ".join(repr(n) for n in c["raw_normal"])
        light = "null"
        if c["light"] is not None:
            d = ", ".join(repr(f32(v)) for v in c["light"]["direction"])
            col = ", ".join(repr(f32(v)) for v in c["light"]["color"])
            amb = ", ".join(repr(f32(v)) for v in c["light"]["ambient"])
            light = ".{{ .direction = .{{ {0} }}, .color = .{{ {1} }}, .ambient = .{{ {2} }} }}".format(d, col, amb)
        frame = ", ".join("0x{0:02x}".format(b) for b in c["frame"])
        lines.append("    .{")
        lines.append('        .name = "{0}",'.format(c["name"]))
        lines.append("        .tri = .{{ {0} }},".format(tri))
        lines.append("        .world_normal = .{{ {0} }},".format(normal))
        lines.append("        .light = {0},".format(light))
        lines.append("        .use_texture = {0},".format(str(c["use_texture"]).lower()))
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
    out = root / "src" / "render" / "raster_light_vectors.zig"
    out.write_text(emit(all_cases))
    drew = sum(1 for c in all_cases if c["drew"])
    pixels = sum((b >> i) & 1 for c in all_cases for b in c["mask"] for i in range(8))
    print(f"wrote {out.relative_to(root)}")
    print(f"  cases: {len(all_cases)}  drew: {drew}  culled/degenerate: {len(all_cases) - drew}")
    print(f"  covered pixels across all cases: {pixels}")


if __name__ == "__main__":
    main()
