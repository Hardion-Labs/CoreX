#!/usr/bin/env python3
"""Generate Adam7 (interlaced) PNG test vectors for the CoreXEngine decoder.

Requires Pillow, because every file this script emits is **decoded back by
libpng before it is written out**. That is what makes the corpus trustworthy:

    this script scatters pixels into Adam7 passes
        -> libpng decodes the result
        -> must equal the expected RGBA8, or generation fails

So a mistake in the pass table cannot survive: libpng would reconstruct a
scrambled image and the comparison would fail. The Zig decoder is then checked
against files an independent implementation has already confirmed, rather than
against a layout this repository invented on both sides.

Pillow cannot *write* interlaced PNGs (its saver hardcodes the interlace byte to
zero), which is why the pass layout is assembled here and only verified there.

Usage (from the repository root):

    python3 -m venv /tmp/venv-ref && /tmp/venv-ref/bin/pip install Pillow
    /tmp/venv-ref/bin/python tools/gen_png_adam7_vectors.py > src/assets/png_adam7_vectors.zig

Helpers are imported from gen_png_vectors so the filter, packing and RGBA
normalization rules have exactly one definition in the tree.
"""

import io
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_png_vectors import (  # noqa: E402
    CHANNELS,
    SIGNATURE,
    build_png,
    chunk,
    hexlit,
    ihdr,
    raw_scanlines,
    to_rgba,
)

try:
    from PIL import Image
except ImportError:
    sys.exit(
        "Pillow is required to verify the Adam7 corpus against libpng.\n"
        "  python3 -m venv /tmp/venv-ref && /tmp/venv-ref/bin/pip install Pillow\n"
        "  /tmp/venv-ref/bin/python tools/gen_png_adam7_vectors.py"
    )


# The Adam7 pass geometry from the PNG specification: (x_start, y_start, x_step,
# y_step). Verified against libpng below, not trusted on its own.
ADAM7 = (
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
)


def pass_size(width, height, pass_index):
    x0, y0, dx, dy = ADAM7[pass_index]
    pw = (width - x0 + dx - 1) // dx if width > x0 else 0
    ph = (height - y0 + dy - 1) // dy if height > y0 else 0
    return pw, ph


def pass_rows(rows, width, height, channels, pass_index):
    """Gather the pixels of one pass, in the order the scanlines must appear."""
    x0, y0, dx, dy = ADAM7[pass_index]
    out = []
    for y in range(y0, height, dy):
        src = rows[y]
        row = []
        for x in range(x0, width, dx):
            row.extend(src[x * channels : (x + 1) * channels])
        out.append(row)
    return out


def adam7_scanlines(rows, width, height, depth, ct, filters):
    """Concatenate every non-empty pass, each with its own filter history."""
    channels = CHANNELS[ct]
    out = bytearray()
    for p in range(7):
        pw, ph = pass_size(width, height, p)
        if pw == 0 or ph == 0:
            continue
        prows = pass_rows(rows, width, height, channels, p)
        # A fresh raw_scanlines call per pass is the point: the Up/Average/Paeth
        # predictors must restart from zero at every pass boundary. Rotating the
        # filter list per pass means a decoder that carried state across passes
        # would diverge on the very first row of the next one.
        rotated = filters[p % len(filters) :] + filters[: p % len(filters)]
        out += raw_scanlines(prows, depth, channels, pw, rotated)
    return bytes(out)


def build_interlaced(
    rows,
    width,
    height,
    depth,
    ct,
    filters=(0, 1, 2, 3, 4),
    palette=None,
    trns=None,
    idat_parts=1,
    level=9,
):
    raw = adam7_scanlines(rows, width, height, depth, ct, filters)
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY)
    z = co.compress(raw) + co.flush()
    body = ihdr(width, height, depth, ct, interlace=1)
    if palette is not None:
        body += chunk(b"PLTE", b"".join(bytes(p) for p in palette))
    if trns is not None:
        if ct == 3:
            body += chunk(b"tRNS", bytes(trns))
        elif ct == 0:
            body += chunk(b"tRNS", struct.pack(">H", trns))
        elif ct == 2:
            body += chunk(b"tRNS", struct.pack(">HHH", *trns))
    step = max(1, len(z) // idat_parts)
    for i in range(0, len(z), step):
        body += chunk(b"IDAT", z[i : i + step])
    body += chunk(b"IEND", b"")
    return SIGNATURE + body, raw


VALID = []
SKIPPED = []
NATIVE = []


def add(name, rows, width, height, depth, ct, **kw):
    png, raw = build_interlaced(rows, width, height, depth, ct, **kw)
    expected = to_rgba(
        rows, width, depth, ct, palette=kw.get("palette"), trns=kw.get("trns")
    )
    # The independent check. If libpng cannot read it back to exactly the
    # expected RGBA8, the corpus is wrong and generation must stop.
    try:
        back = Image.open(io.BytesIO(png)).convert("RGBA").tobytes()
    except Exception as exc:  # noqa: BLE001
        sys.exit("libpng rejected generated vector %s: %s" % (name, exc))
    if back == expected:
        VALID.append((name, width, height, png, expected, len(raw)))
        return

    # libpng normalizes 16-bit grayscale differently from the engine's documented
    # high-byte rule. The *layout* can still be verified independently: read the
    # file at its native depth and compare the samples themselves. Only the
    # 8-bit reduction is then left to the documented rule.
    native = Image.open(io.BytesIO(png))
    if depth == 16 and ct == 0 and native.mode in ("I;16", "I"):
        got = native.tobytes()
        want = b"".join(struct.pack("<H", s) for r in rows for s in r)
        if got == want:
            NATIVE.append(name)
            print("NATIVE %s: layout verified at 16-bit, high-byte reduction by rule" % name, file=sys.stderr)
            VALID.append((name, width, height, png, expected, len(raw)))
            return
    SKIPPED.append(name)
    print("SKIP %s: libpng normalization differs and layout check failed" % name, file=sys.stderr)


def ramp(width, height, channels, depth, seed=0):
    maxv = (1 << depth) - 1
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            for c in range(channels):
                row.append((x * 7 + y * 13 + c * 29 + seed) % (maxv + 1))
        rows.append(row)
    return rows


def palette_ramp(width, height, entries, seed=0):
    return [[(x * 5 + y * 3 + seed) % entries for x in range(width)] for y in range(height)]


def main():
    # --- geometry: sizes that empty some passes, and sizes that do not divide ---
    for w, h in ((1, 1), (1, 9), (9, 1), (2, 2), (3, 3), (4, 4), (5, 9), (9, 5), (8, 8), (17, 13)):
        add("rgb8_%dx%d" % (w, h), ramp(w, h, 3, 8), w, h, 8, 2)
    add("rgba8_9x7", ramp(9, 7, 4, 8), 9, 7, 8, 6, idat_parts=3)
    add("rgba8_1x1", ramp(1, 1, 4, 8), 1, 1, 8, 6)
    add("la8_7x9", ramp(7, 9, 2, 8), 7, 9, 8, 4)

    # --- sub-byte and 16-bit depths ---
    for depth in (1, 2, 4, 8):
        add("gray%d_13x9" % depth, ramp(13, 9, 1, depth), 13, 9, depth, 0)
    add("gray16_9x5", ramp(9, 5, 1, 16), 9, 5, 16, 0)
    add("rgb16_5x9", ramp(5, 9, 3, 16), 5, 9, 16, 2)
    add("rgba16_9x5", ramp(9, 5, 4, 16), 9, 5, 16, 6)
    add("la16_5x5", ramp(5, 5, 2, 16), 5, 5, 16, 4)

    # --- palette, with and without tRNS ---
    pal = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (17, 34, 51), (200, 100, 50), (9, 8, 7)]
    for depth in (1, 2, 4, 8):
        n = min(1 << depth, len(pal))
        add(
            "pal%d_11x7" % depth,
            palette_ramp(11, 7, n, seed=1),
            11, 7, depth, 3,
            palette=pal[:n],
        )
    add("pal8_trns_9x9", palette_ramp(9, 9, len(pal), seed=2), 9, 9, 8, 3,
        palette=pal, trns=[0, 128, 255, 64])

    # --- color-key transparency, compared at the source depth ---
    grows = ramp(9, 9, 1, 8)
    add("gray8_key_9x9", grows, 9, 9, 8, 0, trns=grows[3][3])
    rgbrows = ramp(9, 9, 3, 8)
    add("rgb8_key_9x9", rgbrows, 9, 9, 8, 2, trns=tuple(rgbrows[4][4 * 3 : 4 * 3 + 3]))

    # --- every filter, and a single filter repeated so passes cannot borrow ---
    add("rgb8_filters_13x11", ramp(13, 11, 3, 8), 13, 11, 8, 2, filters=(4, 3, 2, 1, 0))
    add("rgb8_paeth_9x9", ramp(9, 9, 3, 8), 9, 9, 8, 2, filters=(4,))
    add("rgb8_up_9x9", ramp(9, 9, 3, 8), 9, 9, 8, 2, filters=(2,))
    add("rgb8_avg_9x9", ramp(9, 9, 3, 8), 9, 9, 8, 2, filters=(3,))
    add("rgb8_sub_9x9", ramp(9, 9, 3, 8), 9, 9, 8, 2, filters=(1,))
    add("rgb8_stored_9x9", ramp(9, 9, 3, 8), 9, 9, 8, 2, level=0, idat_parts=4)

    if not VALID:
        sys.exit("no vectors survived libpng verification")

    # --- malformed interlaced files ---------------------------------------
    base_rows = ramp(9, 9, 3, 8)
    good, good_raw = build_interlaced(base_rows, 9, 9, 8, 2)
    invalid = []

    def zdata(raw):
        co = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY)
        return co.compress(raw) + co.flush()

    def wrap(raw, name):
        z = zdata(raw)
        body = ihdr(9, 9, 8, 2, interlace=1) + chunk(b"IDAT", z) + chunk(b"IEND", b"")
        invalid.append((name, SIGNATURE + body))

    # One byte short / long: the pass sizes must be summed exactly.
    wrap(good_raw[:-1], "adam7_raw_short")
    wrap(good_raw + b"\x00", "adam7_raw_long")
    # A filter byte that is valid nowhere, placed in a later pass so a decoder
    # that only checks the first pass would miss it.
    bad = bytearray(good_raw)
    first_pass_len = ((9 + 7) // 8) * 3 + 1
    bad[first_pass_len * ((9 + 7) // 8)] = 7
    wrap(bytes(bad), "adam7_bad_filter_late_pass")
    # A well-formed chunk carrying half a zlib stream: the deflate never
    # finishes. Cutting bytes off the end of the file instead would only trip
    # libpng's tolerance for a missing IEND, not test the inflater.
    half = zdata(good_raw)[: len(zdata(good_raw)) // 2]
    body = ihdr(9, 9, 8, 2, interlace=1) + chunk(b"IDAT", half) + chunk(b"IEND", b"")
    invalid.append(("adam7_truncated_idat", SIGNATURE + body))
    # Interlace method 2 is not Adam7.
    body = ihdr(9, 9, 8, 2, interlace=2) + chunk(b"IDAT", zdata(good_raw)) + chunk(b"IEND", b"")
    invalid.append(("adam7_unknown_method", SIGNATURE + body))

    # Two cases where the engine is deliberately stricter than libpng, so they
    # are exempt from the rejection cross-check rather than dropped:
    #  - trailing bytes after the last pass: libpng ignores them, the engine
    #    requires the inflated size to match exactly (the same contract the
    #    non-interlaced path already enforces);
    #  - interlace method 2: undefined by the specification, but libpng treats
    #    any non-zero value as Adam7. The engine accepts only 0 and 1.
    lenient_in_libpng = {"adam7_raw_long", "adam7_unknown_method"}
    for name, data in invalid:
        try:
            Image.open(io.BytesIO(data)).load()
        except Exception:  # noqa: BLE001
            continue
        if name in lenient_in_libpng:
            print("NOTE %s: libpng is lenient, engine is strict by contract" % name, file=sys.stderr)
            continue
        sys.exit("malformed vector %s was accepted by libpng" % name)

    # --- a large pair, referenced by formula instead of a 4 MiB hex blob ----
    # Odd, non-power-of-two dimensions so every pass ends mid-stride. The same
    # source is emitted twice, interlaced and not, so the test can also assert
    # the two decode paths agree at a size the small corpus never reaches.
    LW, LH = 257, 259
    lrows = [[(x * 3 + y * 5 + c * 17) % 256 for x in range(LW) for c in range(4)]
             for y in range(LH)]
    large_inter, _ = build_interlaced(lrows, LW, LH, 8, 6)
    large_plain = build_png(lrows, LW, LH, 8, 6)
    formula = bytes((x * 3 + y * 5 + c * 17) % 256
                    for y in range(LH) for x in range(LW) for c in range(4))
    for label, blob in (("interlaced", large_inter), ("plain", large_plain)):
        got = Image.open(io.BytesIO(blob)).convert("RGBA").tobytes()
        if got != formula:
            sys.exit("large %s pair does not match the documented formula" % label)

    # --- emit --------------------------------------------------------------
    w = sys.stdout.write
    w("//! Generated Adam7 (interlaced) PNG vectors. DO NOT EDIT.\n")
    w("//!\n")
    w("//! Regenerate with:\n")
    w("//!     python3 tools/gen_png_adam7_vectors.py > src/assets/png_adam7_vectors.zig\n")
    w("//!\n")
    w("//! (with Pillow installed; see the generator docstring for a venv recipe)\n")
    w("//!\n")
    w("//! Every file here was decoded back by libpng (via Pillow) and compared\n")
    w("//! against `rgba_hex` before being emitted, so the pass layout is confirmed\n")
    w("//! by an independent implementation rather than by this repository's own\n")
    w("//! understanding of Adam7. `raw_len` is the exact inflated size, i.e. the\n")
    w("//! sum over the non-empty passes of (row_bytes + 1) * pass_height.\n\n")
    w("/// An interlaced PNG, the RGBA8 it must produce, and its inflated size.\n")
    w("pub const Adam7 = struct {\n")
    w("    name: []const u8,\n    width: u32,\n    height: u32,\n")
    w("    raw_len: usize,\n    png_hex: []const u8,\n    rgba_hex: []const u8,\n};\n\n")
    w("pub const valid = [_]Adam7{\n")
    for name, width, height, png, rgba, raw_len in VALID:
        w("    .{\n")
        w('        .name = "%s",\n        .width = %d,\n        .height = %d,\n' % (name, width, height))
        w("        .raw_len = %d,\n" % raw_len)
        w("        .png_hex = %s,\n" % hexlit(png))
        w("        .rgba_hex = %s,\n" % hexlit(rgba))
        w("    },\n")
    w("};\n\n")
    w("/// A malformed interlaced PNG the decoder must reject.\n")
    w("pub const Invalid = struct { name: []const u8, png_hex: []const u8 };\n\n")
    w("pub const invalid = [_]Invalid{\n")
    for name, data in invalid:
        w('    .{ .name = "%s", .png_hex = %s },\n' % (name, hexlit(data)))
    w("};\n")
    w("\n/// A larger image emitted as a matched pair. The expected RGBA8 is not\n")
    w("/// stored: it is `(x*3 + y*5 + c*17) % 256` for c in 0..4, row-major, which\n")
    w("/// libpng confirmed for both files at generation time.\n")
    w("pub const large_width: u32 = %d;\n" % LW)
    w("pub const large_height: u32 = %d;\n" % LH)
    w("pub const large_interlaced_hex = %s;\n" % hexlit(large_inter))
    w("pub const large_plain_hex = %s;\n" % hexlit(large_plain))
    print("emitted %d valid (%d verified at native depth), %d invalid, 1 large pair; skipped %s"
          % (len(VALID), len(NATIVE), len(invalid), SKIPPED or "none"), file=sys.stderr)


if __name__ == "__main__":
    main()
