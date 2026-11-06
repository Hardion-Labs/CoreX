#!/usr/bin/env python3
"""Generate reference vectors for framebuffer blending in the rasterizer.

Companion to gen_raster_vectors.py / gen_raster_texture_vectors.py /
gen_raster_light_vectors.py: identical integer edge-function coverage (brute
force, every pixel of the target, no bounding box), the same perspective-correct
texture sampling and Lambert shading, and on top of that a **non-empty initial
target** plus one of the four blend modes. The frame that survives is what the
Zig path must reproduce bit for bit.

Blend math (pinned, one evaluation order):

    sa = src.a / 255,  da = dst.a / 255,  keep = 1 - sa
    out.a = sa + da * keep                      (every blending mode)

    none           out.rgb = src.rgb
    alpha          out.rgb = (src.rgb*sa + (dst.rgb*da)*keep) / out.a
                   (straight-alpha source-over; out.a == 0 -> transparent black)
    premultiplied  out.rgb = src.rgb*sa + dst.rgb*keep
                   (composites into a premultiplied target: the straight-alpha
                    fragment is premultiplied here, the target is read as-is)
    additive       out.rgb = dst.rgb + src.rgb*sa

Each channel is clamped to [0, 1] and quantized once as
`floor(clamp(v, 0, 1) * 255 + 0.5)`; alpha uses the same rule on `out.a`. The
source fragment is the *quantized* shading result (exactly what the Zig
`shadePixel` returns), so the only lossy step is the 8-bit target itself.

Output: src/render/raster_blend_vectors.zig (committed; CI never runs this).

Usage: python3 tools/gen_raster_blend_vectors.py
"""

import math
import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_raster_vectors import SUBPIXEL_SCALE, HALF, edge, is_top_left, mask_bytes  # noqa: E402
from gen_raster_light_vectors import (  # noqa: E402
    TEX_PIXELS,
    f32,
    sample_bilinear,
    sample_nearest,
    light_multiplier,
)

WIDTH = 8
HEIGHT = 8


def math_floor(t):
    return math.floor(t)


def clamp_byte_255(s):
    """Linear channel already in byte units: floor(clamp(s, 0, 255) + 0.5)."""
    return int(math_floor(min(max(s, 0.0), 255.0) + 0.5))


def unit_byte(v):
    """A [0, 1] channel: floor(clamp(v, 0, 1) * 255 + 0.5)."""
    return int(math_floor(min(max(v, 0.0), 1.0) * 255.0 + 0.5))


def alpha_byte(t, tint):
    return int(math_floor(float(t) * float(tint) / 255.0 + 0.5))


def shade(vertex, w0, w1, w2, area_inv, tint, use_texture, filt, light, raw_normal):
    """The quantized shading result: identical to raster.zig's shadePixel."""
    tex = None
    if use_texture:
        den = ((w0 * vertex[0][5] + w1 * vertex[1][5]) + w2 * vertex[2][5]) * area_inv
        if den > 0.0 and not math.isinf(den) and not math.isnan(den):
            u = (((w0 * vertex[0][3] + w1 * vertex[1][3]) + w2 * vertex[2][3]) * area_inv) / den
            v = (((w0 * vertex[0][4] + w1 * vertex[1][4]) + w2 * vertex[2][4]) * area_inv) / den
        else:
            u = 0.0
            v = 0.0
        tex = sample_nearest(u, v) if filt == "nearest" else sample_bilinear(u, v)

    out = [0, 0, 0, 0]
    if light is None:
        if tex is None:
            return list(tint)
        for c in range(4):
            out[c] = int(math_floor(tex[c] * tint[c] / 255.0 + 0.5))
        return out

    lm = light_multiplier(light, raw_normal)
    for c in range(3):
        if tex is None:
            out[c] = clamp_byte_255(float(tint[c]) * lm[c])
        else:
            out[c] = clamp_byte_255(((float(tex[c]) * float(tint[c])) * lm[c]) / 255.0)
    out[3] = tint[3] if tex is None else alpha_byte(tex[3], tint[3])
    return out


def blend_pixels(src, dst, mode):
    if mode == "none":
        return list(src)
    sa = float(src[3]) / 255.0
    da = float(dst[3]) / 255.0
    keep = 1.0 - sa
    out_a = sa + da * keep
    out = [0, 0, 0, 0]
    if mode == "alpha":
        # Straight-alpha source-over: composite premultiplied, then divide out.
        if not (out_a > 0.0):
            return out
        for c in range(3):
            s = float(src[c]) / 255.0
            d = float(dst[c]) / 255.0
            out[c] = unit_byte(((s * sa) + ((d * da) * keep)) / out_a)
    elif mode == "premultiplied":
        for c in range(3):
            s = float(src[c]) / 255.0
            d = float(dst[c]) / 255.0
            out[c] = unit_byte((s * sa) + (d * keep))
    elif mode == "additive":
        for c in range(3):
            s = float(src[c]) / 255.0
            d = float(dst[c]) / 255.0
            out[c] = unit_byte(d + (s * sa))
    else:
        raise AssertionError(mode)
    out[3] = unit_byte(out_a)
    return out


def rasterize(vertex, tint, use_texture, filt, light, raw_normal, clear, blend,
              cull="none", front_face="ccw"):
    v = list(vertex)
    area = edge(v[0][0], v[0][1], v[1][0], v[1][1], v[2][0], v[2][1])
    if area == 0:
        return False, [0] * (WIDTH * HEIGHT), list(clear) * (WIDTH * HEIGHT)

    front = area < 0 if front_face == "ccw" else area > 0
    if cull == "back" and not front:
        return False, [0] * (WIDTH * HEIGHT), list(clear) * (WIDTH * HEIGHT)
    if cull == "front" and front:
        return False, [0] * (WIDTH * HEIGHT), list(clear) * (WIDTH * HEIGHT)

    if area < 0:
        v[1], v[2] = v[2], v[1]
        area = -area

    inv_area = 1.0 / float(area)
    mask = [0] * (WIDTH * HEIGHT)
    frame = list(clear) * (WIDTH * HEIGHT)

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
            src = shade(v, weights[0], weights[1], weights[2], inv_area,
                        tint, use_texture, filt, light, raw_normal)
            mask[i] = 1
            frame[i * 4: i * 4 + 4] = blend_pixels(src, frame[i * 4: i * 4 + 4], blend)
    return True, mask, frame


def px(x, y, z=0.0, u=0.0, v=0.0):
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)), f32(z),
            float(u), float(v), 1.0)


def pxw(x, y, z, u, v, w):
    return (int(round(x * SUBPIXEL_SCALE)), int(round(y * SUBPIXEL_SCALE)), f32(z),
            float(u) / w, float(v) / w, 1.0 / w)


def cases():
    out = []
    quad = [px(0, 0, 0, 0, 0), px(8, 0, 0, 1, 0), px(0, 8, 0, 0, 1)]
    half_quad = [px(1, 1, 0.2, 0, 0), px(7, 1, 0.2, 1, 0), px(1, 7, 0.2, 0, 1)]
    opaque_blue = (0, 0, 255, 255)
    clear_black = (0, 0, 0, 0)
    white = (255, 255, 255, 255)

    def add(name, tri, clear, blend, tint=white, use_texture=False, filt="bilinear",
            light=None, raw_normal=(0.0, 0.0, 0.0),
            cull="none", front_face="ccw"):
        drew, mask, frame = rasterize(tri, tint, use_texture, filt, light, raw_normal,
                                      clear, blend, cull=cull, front_face=front_face)
        out.append({
            "name": name, "tri": tri, "clear": clear, "blend": blend, "tint": tint,
            "use_texture": use_texture, "filt": filt, "light": light,
            "raw_normal": raw_normal, "cull": cull, "front_face": front_face,
            "drew": drew, "mask": mask_bytes(mask), "frame": frame,
        })

    # No blending is the pre-existing path: the clear color disappears entirely.
    add("no_blend_over_clear", quad, (200, 100, 50, 255), "none", tint=(0, 255, 0, 255))
    add("no_blend_ignores_transparent_clear", quad, clear_black, "none", tint=(10, 20, 30, 40))

    # Fully opaque source: every mode degenerates to the source color.
    for mode in ("alpha", "premultiplied", "additive"):
        add(f"opaque_source_{mode}", quad, (200, 100, 50, 128), mode, tint=(70, 60, 50, 255))

    # Fully transparent source: nothing changes (and .alpha must not divide by 0).
    for mode in ("alpha", "premultiplied", "additive"):
        add(f"transparent_source_{mode}", quad, (200, 100, 50, 128), mode, tint=(70, 60, 50, 0))

    # Half-alpha source over an opaque destination, and over a transparent one.
    add("alpha_half_over_opaque", quad, opaque_blue, "alpha", tint=(255, 0, 0, 128))
    add("alpha_half_over_transparent", quad, clear_black, "alpha", tint=(255, 0, 0, 128))
    add("alpha_quarter_over_half", quad, (0, 128, 255, 128), "alpha", tint=(255, 64, 0, 64))

    # A destination that is already partly transparent: the divide by out.a is
    # exercised at a non-round value.
    add("alpha_over_half_transparent", quad, (0, 200, 100, 90), "alpha", tint=(120, 30, 240, 160))

    # Premultiplied and additive, including saturation at the ceiling.
    add("premultiplied_half", quad, (40, 80, 120, 255), "premultiplied", tint=(200, 100, 50, 128))
    add("premultiplied_over_transparent", quad, clear_black, "premultiplied", tint=(64, 128, 192, 200))
    add("additive_half", quad, (30, 60, 90, 255), "additive", tint=(200, 200, 200, 128))
    add("additive_saturates", quad, (200, 190, 180, 255), "additive", tint=(255, 255, 255, 255))
    add("additive_transparent_dst", quad, clear_black, "additive", tint=(255, 128, 0, 51))

    # Textured source composited over a color.
    add("alpha_textured", quad, (10, 200, 240, 255), "alpha", use_texture=True, filt="bilinear", tint=(255, 255, 255, 128))
    add("alpha_textured_nearest_tint_alpha", quad, (255, 0, 255, 255), "alpha", use_texture=True, filt="nearest", tint=(200, 220, 255, 96))
    add("additive_textured", quad, (12, 34, 56, 255), "additive", use_texture=True, filt="bilinear", tint=(255, 180, 90, 200))

    # Lit source composited over a color (lighting is albedo-only).
    lit = {"direction": (0.0, 0.0, 1.0), "color": (0.5, 0.5, 0.5), "ambient": (0.15, 0.15, 0.15)}
    add("alpha_lit_flat", quad, (40, 120, 200, 255), "alpha", light=lit, raw_normal=(0.0, 0.0, 3.0), tint=(240, 180, 120, 140))
    add("alpha_lit_textured", quad, (200, 40, 90, 255), "alpha", use_texture=True, filt="bilinear",
        light=lit, raw_normal=(0.0, 0.0, 3.0), tint=(255, 255, 255, 180))

    # Partial coverage: blended pixels next to untouched clear pixels.
    add("alpha_partial_coverage", half_quad, (255, 255, 0, 255), "alpha", tint=(0, 0, 255, 100))

    # Backface culling wins over blending: the target keeps its clear color.
    add("culled_keeps_clear", [px(1, 1), px(7, 2), px(3, 7)], (12, 24, 36, 255), "alpha",
        tint=(255, 0, 0, 128), cull="back", front_face="ccw")

    # Perspective-correct UVs, straight-alpha composite.
    add("alpha_perspective", [pxw(0, 0, 0, 0.1, 0.2, 1.7), pxw(8, 0, 0, 1.9, 0.2, 0.8), pxw(0, 8, 0, 0.1, 2.1, 1.1)],
        (30, 60, 90, 200), "alpha", use_texture=True, filt="bilinear", tint=(255, 255, 255, 170))

    rng = random.Random(20261108)
    modes = ("none", "alpha", "alpha", "alpha", "premultiplied", "additive")
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
        light = None
        raw_normal = (0.0, 0.0, 0.0)
        if rng.random() < 0.5:
            light = {
                "direction": (rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)),
                "color": tuple(rng.uniform(0.0, 1.5) for _ in range(3)),
                "ambient": tuple(rng.uniform(0.0, 1.2) for _ in range(3)),
            }
            if light["direction"] == (0.0, 0.0, 0.0):
                light["direction"] = (0.0, 0.0, 1.0)
            raw_normal = (rng.uniform(-3, 3), rng.uniform(-3, 3), rng.choice([-1.0, 1.0]) * rng.uniform(0.01, 1000.0))
        add(f"random_{n:02d}", tri,
            (rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
            rng.choice(modes),
            tint=(rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
            use_texture=rng.choice([True, True, False]),
            filt=rng.choice(["nearest", "bilinear"]),
            light=light,
            raw_normal=raw_normal,
            cull=rng.choice(["none", "none", "back"]),
            front_face=rng.choice(["ccw", "cw"]))

    return out


def emit(all_cases):
    lines = []
    lines.append("//! Reference vectors for framebuffer blending.")
    lines.append("//!")
    lines.append("//! GENERATED by tools/gen_raster_blend_vectors.py -- do not edit by hand.")
    lines.append("//! Each case starts from a non-empty target (`clear`), shades one triangle")
    lines.append("//! with the same flat/textured/Lambert rules as the other corpora, and")
    lines.append("//! composites it with one blend mode. Expected frames must match bit for")
    lines.append("//! bit. Every case keeps depth_test and depth_write enabled.")
    lines.append("")
    lines.append("pub const width: u32 = 8;")
    lines.append("pub const height: u32 = 8;")
    lines.append("")
    tex = ", ".join(str(b) for b in TEX_PIXELS)
    lines.append("/// The shared 4x4 RGBA8 texture (row-major, top-down).")
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
    lines.append("    /// Raw (NOT normalized) world-space face normal; ignored without a light.")
    lines.append("    world_normal: [3]f64,")
    lines.append("    light: ?Light,")
    lines.append("    use_texture: bool,")
    lines.append("    filter: enum { nearest, bilinear },")
    lines.append("    tint: [4]u8,")
    lines.append("    cull: enum { none, back, front },")
    lines.append("    front_face: enum { ccw, cw },")
    lines.append("    /// Target contents before the draw (both color and depth are reset to it).")
    lines.append("    clear: [4]u8,")
    lines.append("    blend: enum { none, alpha, premultiplied, additive },")
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
        clear = ", ".join(str(b) for b in c["clear"])
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
        lines.append("        .clear = .{{ {0} }},".format(clear))
        lines.append("        .blend = .{0},".format(c["blend"]))
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
    out = root / "src" / "render" / "raster_blend_vectors.zig"
    out.write_text(emit(all_cases))
    drew = sum(1 for c in all_cases if c["drew"])
    pixels = sum((b >> i) & 1 for c in all_cases for b in c["mask"] for i in range(8))
    modes = {}
    for c in all_cases:
        modes[c["blend"]] = modes.get(c["blend"], 0) + 1
    print(f"wrote {out.relative_to(root)}")
    print(f"  cases: {len(all_cases)}  drew: {drew}  culled/degenerate: {len(all_cases) - drew}")
    print(f"  covered pixels across all cases: {pixels}")
    print("  modes: " + ", ".join(f"{k}={v}" for k, v in sorted(modes.items())))


if __name__ == "__main__":
    main()
