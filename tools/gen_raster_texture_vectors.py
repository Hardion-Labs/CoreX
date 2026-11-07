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

Mipmapped cases (`mips == true`) additionally pin mip level selection: the
generated chain below level 0 is recomputed here with the same integer box
filter, the per-pixel LOD comes from the exact analytic derivative of the
perspective UV mapping, and the trilinear mix is applied with the same single
final round. Everything below level 0 is validated against this reference.

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

# A 16x16 level 0 whose detail is deliberately finer than the 8x8 target: this is
# what a minified texture looks like, and what mip level selection must fix. The
# pattern mixes a 1-texel checker with a red ramp along x and a green ramp along
# y, so aliasing shows up as both colour noise and a shifted ramp.
MIP_TEX = 16


def mip_texel(x, y):
    checker = 0 if (x + y) % 2 == 0 else 255
    r = (x * 16 + 8) % 256
    g = (y * 16 + 4) % 256
    b = checker
    return (r, g, b, 255)


def mip_tex_pixels():
    return [c for y in range(MIP_TEX) for x in range(MIP_TEX) for c in mip_texel(x, y)]


def mip_level_count(w, h):
    n, d = 1, 0
    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        n += 1
    return n


def mip_dims(w, h, level):
    for _ in range(level):
        w, h = max(1, w // 2), max(1, h // 2)
    return w, h


def downsample(src, sw, sh, dw, dh):
    """Box filter with one integer round-half-up per channel (see mipmap.zig)."""
    out = [0] * (dw * dh * 4)
    for dy in range(dh):
        y0 = dy * sh // dh
        y1 = max(y0 + 1, (dy + 1) * sh // dh)
        for dx in range(dw):
            x0 = dx * sw // dw
            x1 = max(x0 + 1, (dx + 1) * sw // dw)
            count = (x1 - x0) * (y1 - y0)
            acc = [0, 0, 0, 0]
            for sy in range(y0, y1):
                for sx in range(x0, x1):
                    off = (sy * sw + sx) * 4
                    for c in range(4):
                        acc[c] += src[off + c]
            off = (dy * dw + dx) * 4
            for c in range(4):
                out[off + c] = (acc[c] + count // 2) // count
    return out


def build_chain(pixels, w, h):
    """Levels below level 0, largest first: [(w, h, pixels), ...]."""
    levels = []
    prev, pw, ph = pixels, w, h
    for level in range(1, mip_level_count(w, h)):
        dw, dh = mip_dims(w, h, level)
        prev = downsample(prev, pw, ph, dw, dh)
        levels.append((dw, dh, prev))
        pw, ph = dw, dh
    return levels


def nearest_at(level, u, v):
    lw, lh, pixels = level
    x = min(lw - 1, int(repeat_frac(u) * lw))
    y = min(lh - 1, int(repeat_frac(v) * lh))
    off = (y * lw + x) * 4
    return [pixels[off + c] for c in range(4)]


def bilinear_at(level, u, v):
    import math
    lw, lh, pixels = level
    uf, vf = repeat_frac(u), repeat_frac(v)
    tx = uf * lw - 0.5
    ty = vf * lh - 0.5
    fx = tx - math.floor(tx)
    fy = ty - math.floor(ty)
    x0, x1 = wrap_index(tx, lw), (wrap_index(tx, lw) + 1) % lw
    y0, y1 = wrap_index(ty, lh), (wrap_index(ty, lh) + 1) % lh
    out = []
    for c in range(4):
        def at(x, y):
            return float(pixels[(y * lw + x) * 4 + c])

        top = (at(x0, y0) * (1.0 - fx) + at(x1, y0) * fx) * (1.0 - fy)
        bottom = (at(x0, y1) * (1.0 - fx) + at(x1, y1) * fx) * fy
        out.append(int(math.floor(top + bottom + 0.5)))
    return out


def sample_level(level, u, v, filt):
    return nearest_at(level, u, v) if filt == "nearest" else bilinear_at(level, u, v)


def texture_lod(du, dv, levels):
    """log2 of the larger texel-space gradient, clamped to [0, levels - 1]."""
    import math
    rho = max(abs(du), abs(dv))
    if not (rho > 1.0):
        return 0.0
    lod = math.log2(rho)
    return min(lod, float(levels - 1)) if lod > 0.0 else 0.0


def sample_trilinear(levels, u, v, lod, filt):
    import math
    base = int(lod) if lod >= 0 else 0
    last = len(levels) - 1
    if base >= last:
        return sample_level(levels[last], u, v, filt)
    t = lod - float(base)
    if not (t > 0.0):
        return sample_level(levels[base], u, v, filt)
    fine = sample_level(levels[base], u, v, filt)
    coarse = sample_level(levels[base + 1], u, v, filt)
    return [int(math.floor(a * (1.0 - t) + b * t + 0.5)) for a, b in zip(fine, coarse)]


def texel_gradient(p, q, den, dp, dq, dden, size):
    """du/dv in texel units: the derivative of u = p / den, per screen axis."""
    import math
    den_sq = den * den
    if not (den_sq > 0.0):
        return 0.0, 0.0
    inv_den_sq = 1.0 / den_sq  # one reciprocal, mirrored from texelGradient
    du = max(abs((dp[0] * den - p * dden[0]) * inv_den_sq),
             abs((dp[1] * den - p * dden[1]) * inv_den_sq)) * size[0]
    dv = max(abs((dq[0] * den - q * dden[0]) * inv_den_sq),
             abs((dq[1] * den - q * dden[1]) * inv_den_sq)) * size[1]
    return du, dv


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


def shade(vertex, w0, w1, w2, area_inv, tint, filt, levels=None, grad=None, mipmap="trilinear"):
    """Shade one pixel. `levels` is the full chain (level 0 first) when the case
    is mipmapped; `grad` holds the per-pixel differences of the perspective
    numerator and denominator, as (dp, dq, dden)."""
    num_u = (((w0 * vertex[0][3] + w1 * vertex[1][3]) + w2 * vertex[2][3]) * area_inv)
    num_v = (((w0 * vertex[0][4] + w1 * vertex[1][4]) + w2 * vertex[2][4]) * area_inv)
    den = ((w0 * vertex[0][5] + w1 * vertex[1][5]) + w2 * vertex[2][5]) * area_inv
    if not (den > 0.0) or den != den or den == float("inf"):
        u = v = 0.0
    else:
        u = num_u / den
        v = num_v / den
    use_mips = levels is not None and len(levels) > 1 and mipmap == "trilinear"
    if not use_mips:
        if levels is not None:
            # `.level0` on a mipmapped texture samples the chain's own level 0.
            texel = sample_level(levels[0], u, v, filt)
        else:
            texel = sample_nearest(u, v) if filt == "nearest" else sample_bilinear(u, v)
        return tint_multiply(texel, tint)
    lw, lh = levels[0][0], levels[0][1]
    dp, dq, dden = grad
    du, dv = texel_gradient(num_u, num_v, den, dp, dq, dden, (float(lw), float(lh)))
    lod = texture_lod(du, dv, len(levels))
    texel = sample_trilinear(levels, u, v, lod, filt)
    return tint_multiply(texel, tint)


def rasterize(vertex, tint, filt, cull="none", front_face="ccw",
              depth_test=True, depth_write=True, levels=None, mipmap="trilinear"):
    """vertex: three (x, y, z, uw, vw, w_inv) tuples. Returns (drew, mask, frame).

    `levels` is the full mip chain (level 0 first) for a mipmapped case; the
    gradient constants are then derived per triangle from the same per-pixel
    edge steps the rasterizer uses, exactly like `GradSteps.init`."""
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
    # Per-pixel barycentric steps, from the same edge-function deltas the Zig
    # coverage loop steps by (one pixel right/down), divided by area: this is
    # `GradSteps.init`. d(att) = da * (att0 - att2) + db * (att1 - att2).
    da = ((float(v[1][1] - v[2][1]) * SUBPIXEL_SCALE) * inv_area,
          (float(v[2][0] - v[1][0]) * SUBPIXEL_SCALE) * inv_area)
    db = ((float(v[2][1] - v[0][1]) * SUBPIXEL_SCALE) * inv_area,
          (float(v[0][0] - v[2][0]) * SUBPIXEL_SCALE) * inv_area)
    grad = None
    if levels is not None and len(levels) > 1 and mipmap == "trilinear":
        duv = (v[0][3] - v[2][3], v[0][4] - v[2][4], v[0][5] - v[2][5])
        duv1 = (v[1][3] - v[2][3], v[1][4] - v[2][4], v[1][5] - v[2][5])
        axis = lambda k, c: da[k] * duv[c] + db[k] * duv1[c]
        grad = (tuple(axis(k, 0) for k in (0, 1)),
                tuple(axis(k, 1) for k in (0, 1)),
                tuple(axis(k, 2) for k in (0, 1)))
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
                frame[i * 4: i * 4 + 4] = shade(v, weights[0], weights[1], weights[2], inv_area, tint, filt,
                                                 levels=levels, grad=grad, mipmap=mipmap)
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

    chain_cache = {}

    def chain_for(name):
        """Full chain (level 0 first) of the named level-0 texture."""
        if name not in chain_cache:
            base = (TEX, TEX, TEX_PIXELS) if name == "base" else (MIP_TEX, MIP_TEX, mip_tex_pixels())
            levels = [base] + build_chain(base[2], base[0], base[1])
            chain_cache[name] = levels
        return chain_cache[name]

    def add(name, tri, filt="bilinear", tint=(255, 255, 255, 255), mips=None, **kw):
        levels = chain_for(mips) if mips is not None else None
        if levels is not None:
            # Every emitted chain must satisfy the sampler's validation, i.e. be
            # exactly repeated halving of the level 0 it belongs to.
            w, h = levels[0][0], levels[0][1]
            for (lw, lh, _) in levels[1:]:
                w, h = max(1, w // 2), max(1, h // 2)
                assert (lw, lh) == (w, h), (name, lw, lh, w, h)
        mipmap = kw.pop("mipmap", "trilinear")
        drew, mask, frame = rasterize(tri, tint, filt, levels=levels, mipmap=mipmap, **kw)
        entry = {"name": name, "tri": tri, "filt": filt, "tint": tint,
                 "cull": kw.get("cull", "none"),
                 "front_face": kw.get("front_face", "ccw"),
                 "depth_test": kw.get("depth_test", True),
                 "depth_write": kw.get("depth_write", True),
                 "drew": drew, "mask": mask_bytes(mask), "frame": frame,
                 "mips": mips is not None, "mipmap": mipmap, "big_base": mips == "mip"}
        if mips is not None:
            entry["levels"] = [(w, h, px) for (w, h, px) in chain_for(mips)[1:]]
        out.append(entry)

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
    # --- mipmapped cases -----------------------------------------------------
    # The 16x16 level 0 covers the whole target 3 times over, so the UV gradient
    # is ~6 texels/pixel: without mips that is heavy aliasing, with trilinear it
    # lands between levels 2 and 3.
    big_quad = [px(0, 0, 0, 0, 0), px(8, 0, 0, 3, 0), px(0, 8, 0, 0, 3)]
    add("mip_minified_nearest", big_quad, filt="nearest", mips="mip")
    add("mip_minified_bilinear", big_quad, filt="bilinear", mips="mip")
    add("mip_minified_nearest_level0", big_quad, filt="nearest", mips="mip", mipmap="level0")
    # One-to-one mapping: ~1 texel per pixel in x, 2 in y -> fractional LOD.
    add("mip_anisotropic", [px(0, 0, 0, 0, 0), px(8, 0, 0, 2, 0), px(0, 8, 0, 0, 4)],
        filt="bilinear", mips="mip")
    # Magnification: the UV gradient is below one texel per pixel, so the chain
    # must not be touched at all (LOD clamps to 0).
    add("mip_magnified", [px(0, 0, 0, 0.2, 0.2), px(8, 0, 0, 0.6, 0.2), px(0, 8, 0, 0.2, 0.6)],
        filt="bilinear", mips="mip")
    # Perspective: the gradient varies per pixel, so the level varies too.
    add("mip_perspective", [pxw(0, 0, 0, 0.0, 0.0, 2.4), pxw(8, 0, 0, 3.0, 0.0, 1.0), pxw(0, 8, 0, 0.0, 3.0, 1.0)],
        filt="bilinear", mips="mip")
    add("mip_perspective_nearest", [pxw(0, 0, 0, 1.5, 0.5, 3.0), pxw(8, 0, 0, 4.0, 0.5, 1.0), pxw(0, 8, 0, 1.5, 4.0, 1.0)],
        filt="nearest", mips="mip")
    # Repeat wrap and a tint on top of the mip chain.
    add("mip_repeat_tint", [px(0, 0, 0, -1.5, 2.5), px(8, 0, 0, 2.5, 2.5), px(0, 8, 0, -1.5, 6.5)],
        filt="bilinear", tint=(200, 220, 255, 255), mips="mip")
    # The 4x4 base texture with a chain of its own (levels 4 -> 2 -> 1): pins the
    # behaviour at the last level, where both taps collapse onto 1x1.
    add("mip_base_minified", [px(0, 0, 0, 0, 0), px(8, 0, 0, 4, 0), px(0, 8, 0, 0, 4)],
        filt="nearest", mips="base")
    add("mip_base_bilinear", [px(0, 0, 0, 0, 0), px(8, 0, 0, 4, 0), px(0, 8, 0, 0, 4)],
        filt="bilinear", mips="base")

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
    # Random mipmapped cases: random screen triangles over the 16x16 level 0, so
    # the LOD spans magnification through heavy minification including fractional
    # levels, both filters and both mipmap modes.
    for n in range(24):
        tri = []
        for _ in range(3):
            x = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            y = rng.randint(-2 * SUBPIXEL_SCALE, 10 * SUBPIXEL_SCALE)
            z = struct.unpack("<f", struct.pack("<f", rng.uniform(-1, 1)))[0]
            u = rng.uniform(-2.0, 3.0)
            v = rng.uniform(-2.0, 3.0)
            w = rng.uniform(0.5, 2.5)
            tri.append((x, y, z, u / w, v / w, 1.0 / w))
        add(f"mip_random_{n:02d}", tri,
            filt=rng.choice(["nearest", "bilinear"]),
            tint=rng.choice([(255, 255, 255, 255), (180, 200, 240, 255), (255, 220, 160, 255)]),
            cull=rng.choice(["none", "none", "back"]),
            front_face=rng.choice(["ccw", "cw"]),
            mips="mip",
            mipmap=rng.choice(["trilinear", "trilinear", "level0"]))

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
    lines.append("/// The shared 4x4 RGBA8 texture the level-0 cases sample (row-major, top-down).")
    tex = ", ".join(str(b) for b in TEX_PIXELS)
    lines.append(f"pub const texture = [_]u8{{ {tex} }};")
    lines.append("")
    lines.append("/// The 16x16 level-0 texture the mipmapped cases sample.")
    big = ", ".join(str(b) for b in mip_tex_pixels())
    lines.append(f"pub const mip_texture = [_]u8{{ {big} }};")
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
    lines.append("    /// Mip levels below level 0, largest first; empty for a level-0-only")
    lines.append("    /// case (the whole pre-mipmap corpus).")
    lines.append("    levels: []const Level,")
    lines.append("    mipmap: enum { level0, trilinear },")
    lines.append("    /// True when level 0 is `mip_texture` (16x16), false for `texture` (4x4).")
    lines.append("    big_base: bool,")
    lines.append("};")
    lines.append("")
    lines.append("pub const Level = struct { width: u32, height: u32, pixels: []const u8 };")
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
        if c["mips"]:
            level_entries = []
            for (lw, lh, lpix) in c["levels"]:
                bytes_ = ", ".join("0x{0:02x}".format(b) for b in lpix)
                level_entries.append(
                    ".{{ .width = {0}, .height = {1}, .pixels = &.{{ {2} }} }}".format(lw, lh, bytes_))
            lines.append("        .levels = &.{{ {0} }},".format(", ".join(level_entries)))
            lines.append("        .mipmap = .{0},".format(c["mipmap"]))
            lines.append("        .big_base = {0},".format(str(c["big_base"]).lower()))
        else:
            lines.append("        .levels = &.{},")
            lines.append("        .mipmap = .trilinear,")
            lines.append("        .big_base = false,")
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
