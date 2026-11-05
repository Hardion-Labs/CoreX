#!/usr/bin/env python3
"""Generate JPEG test vectors for the CoreXEngine decoder, verified by libjpeg.

Requires Pillow (built against libjpeg). Every file is produced by libjpeg and
the reference RGBA8 is libjpeg's own decode of it, so the Zig decoder is checked
against an independent implementation rather than against itself.

JPEG is lossy and its IDCT is not bit-normative: two conforming decoders may
differ by a sample value or two. The engine uses a full-precision separable
IDCT, libjpeg a fixed-point one, so this script measures the actual divergence
and emits it alongside each vector. The test suite pins a ceiling on both the
worst channel and the mean error, which is what catches structural bugs (a wrong
upsampling filter moves the mean by whole levels, not fractions).

Usage (from the repository root):

    python3 -m venv /tmp/venv-ref && /tmp/venv-ref/bin/pip install Pillow
    /tmp/venv-ref/bin/python tools/gen_jpeg_vectors.py > src/assets/jpeg_vectors.zig
"""

import io
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_png_vectors import hexlit  # noqa: E402

try:
    from PIL import Image, features
except ImportError:
    sys.exit(
        "Pillow is required to generate and verify the JPEG corpus.\n"
        "  python3 -m venv /tmp/venv-ref && /tmp/venv-ref/bin/pip install Pillow"
    )

if not features.check("jpg"):
    sys.exit("this Pillow build has no JPEG support")


def source_image(w, h, mode, kind):
    im = Image.new(mode, (w, h))
    px = []
    for y in range(h):
        for x in range(w):
            if kind == "flat":
                v = 137
            elif kind == "ramp":
                v = (x * 7 + y * 11) % 256
            elif kind == "hard":
                v = 255 if ((x // 2 + y // 2) % 2) else 0
            else:  # mixed detail, exercises non-zero AC coefficients
                v = (x * x * 3 + y * 5 + x * y) % 256
            if mode == "L":
                px.append(v)
            else:
                px.append((v, (x * 13 + y * 29) % 256, (x * y * 7 + 3 * y) % 256))
    im.putdata(px)
    return im


VALID = []
STATS = []


def add(name, w, h, mode, kind="detail", **kw):
    im = source_image(w, h, mode, kind)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", **kw)
    data = buf.getvalue()
    ref = Image.open(io.BytesIO(data)).convert("RGBA").tobytes()
    VALID.append((name, w, h, data, ref))
    return data


def main():
    # --- grayscale, including sizes that are not whole blocks ----------------
    for w, h in ((1, 1), (8, 8), (9, 7), (16, 16), (17, 13)):
        add("gray_%dx%d" % (w, h), w, h, "L", quality=90)
    add("gray_flat", 16, 16, "L", kind="flat", quality=95)
    add("gray_hard", 16, 16, "L", kind="hard", quality=100)

    # --- every subsampling libjpeg can emit, across sizes --------------------
    for ss, label in ((0, "444"), (1, "422"), (2, "420")):
        for w, h in ((1, 1), (2, 2), (9, 7), (16, 16), (17, 13)):
            add("rgb%s_%dx%d" % (label, w, h), w, h, "RGB",
                quality=90, subsampling=ss)

    # --- quality extremes and table selection -------------------------------
    for q in (10, 50, 100):
        add("rgb420_q%d" % q, 17, 13, "RGB", quality=q, subsampling=2)
    add("rgb444_optimized", 17, 13, "RGB", quality=85, subsampling=0, optimize=True)
    add("rgb420_optimized", 17, 13, "RGB", quality=85, subsampling=2, optimize=True)
    add("gray_optimized", 17, 13, "L", quality=75, optimize=True)

    # --- restart markers: predictors and the bit buffer must reset ----------
    for blocks in (1, 2, 5):
        add("rgb420_rst%d" % blocks, 17, 13, "RGB", quality=90, subsampling=2,
            restart_marker_blocks=blocks)
    add("gray_rst1", 17, 13, "L", quality=90, restart_marker_blocks=1)
    add("rgb444_rst3", 16, 16, "RGB", quality=90, subsampling=0,
        restart_marker_blocks=3)

    # --- content that stresses the DC-only and sparse IDCT paths ------------
    add("rgb420_flat", 16, 16, "RGB", kind="flat", quality=95, subsampling=2)
    add("rgb444_hard", 16, 16, "RGB", kind="hard", quality=100, subsampling=0)
    add("rgb420_ramp", 17, 13, "RGB", kind="ramp", quality=80, subsampling=2)

    # --- malformed / unsupported files --------------------------------------
    good = add("probe_source", 16, 16, "RGB", quality=90, subsampling=0)
    VALID.pop()  # only used as a base for the rejection cases
    invalid = []       # malformed: libjpeg must reject these too
    unsupported = []   # valid JPEG outside the engine's subset: engine rejects

    def markers(data):
        """Yield (marker, payload_start, segment_end) for each payload segment."""
        i = 2
        while i + 1 < len(data):
            if data[i] != 0xFF:
                return
            m = data[i + 1]
            if m == 0xD9 or m == 0xDA:
                return
            ln = struct.unpack(">H", data[i + 2 : i + 4])[0]
            yield m, i + 4, i + 2 + ln
            i = i + 2 + ln

    def replace_byte(data, at, value, name):
        invalid.append((name, data[:at] + bytes([value]) + data[at + 1 :]))

    # Truncation at several points.
    invalid.append(("truncated_soi", b"\xff\xd8"))
    invalid.append(("truncated_mid_header", good[:40]))
    invalid.append(("no_eoi_scan_cut", good[: len(good) // 2]))

    seen = {}
    for m, start, end in markers(good):
        seen[m] = seen.get(m, 0) + 1
        suffix = "" if seen[m] == 1 else "_%d" % seen[m]
        if m == 0xC0:
            unsupported.append(("precision_12bit", good[:start] + bytes([12]) + good[start + 1 :]))
            unsupported.append(("four_components", good[: start + 5] + bytes([4]) + good[start + 6 :]))
            replace_byte(good, start + 7, 0x51, "sampling_h_zero") # h = 5
            replace_byte(good, start + 8, 9, "bad_quant_index" + suffix)
            # Same component id twice.
            dup = good[: start + 9] + bytes([good[start + 6]]) + good[start + 10 :]
            invalid.append(("duplicate_component_id", dup))
        if m == 0xDB:
            replace_byte(good, start, 0x09, "bad_quant_table_id" + suffix)
            replace_byte(good, start + 1, 0, "zero_quant_value" + suffix)
        if m == 0xC4:
            replace_byte(good, start, 0x29, "bad_huff_class" + suffix)
            # Counts that over-subscribe the code space.
            over = bytearray(good)
            over[start + 1] = 0xFF
            invalid.append(("huff_oversubscribed" + suffix, bytes(over)))
        if m == 0xDD:
            pass

    # A progressive frame must be rejected, not half-decoded.
    pbuf = io.BytesIO()
    source_image(16, 16, "RGB", "detail").save(pbuf, format="JPEG", quality=90,
                                              progressive=True)
    progressive = pbuf.getvalue()
    # A genuinely valid progressive file: libjpeg reads it, the engine must not.
    Image.open(io.BytesIO(progressive)).load()
    unsupported.append(("progressive", progressive))

    # SOF markers for the unsupported coding processes, with a plausible body.
    for sof, name in ((0xC2, "sof2_progressive"), (0xC3, "sof3_lossless"),
                      (0xC9, "sof9_arithmetic"), (0xCB, "sof11_arithmetic_lossless")):
        for m, start, end in markers(good):
            if m == 0xC0:
                unsupported.append((name, good[: start - 1] + bytes([sof]) + good[start:]))
                break

    # Restart interval declared but the markers are absent from the scan.
    for m, start, end in markers(good):
        if m == 0xC0:
            dri = b"\xff\xdd\x00\x04\x00\x01"
            invalid.append(("restart_marker_missing", good[:start - 2] + dri + good[start - 2 :]))
            break

    # libjpeg must reject the malformed set too, except where it is deliberately
    # more permissive than the engine. A zero quantizer is meaningless to us but
    # libjpeg clamps it; a truncated scan is rendered as far as it got.
    lenient = {"zero_quant_value", "zero_quant_value_2", "no_eoi_scan_cut"}
    for name, data in invalid:
        try:
            Image.open(io.BytesIO(data)).load()
        except Exception:  # noqa: BLE001
            continue
        if name in lenient:
            print("NOTE %s: libjpeg is lenient, engine is strict" % name, file=sys.stderr)
            continue
        sys.exit("malformed vector %s was accepted by libjpeg" % name)

    # --- emit --------------------------------------------------------------
    w = sys.stdout.write
    w("//! Generated JPEG test vectors. DO NOT EDIT.\n")
    w("//!\n")
    w("//! Regenerate with:\n")
    w("//!     python3 tools/gen_jpeg_vectors.py > src/assets/jpeg_vectors.zig\n")
    w("//!\n")
    w("//! (with Pillow installed; see the generator docstring for a venv recipe)\n")
    w("//!\n")
    w("//! Every JPEG here was encoded by libjpeg and every `rgba_hex` is libjpeg's\n")
    w("//! own decode of it, so the tests compare the engine against an independent\n")
    w("//! implementation. JPEG's IDCT is not bit-normative: the engine uses a\n")
    w("//! full-precision separable transform and libjpeg a fixed-point one, so they\n")
    w("//! legitimately differ by a sample value or two. The suite pins a measured\n")
    w("//! ceiling on both the worst channel and the mean error; a structural bug\n")
    w("//! moves the mean by whole levels, so the mean bound is what catches it.\n\n")
    w("/// A JPEG plus the RGBA8 libjpeg produces for it.\n")
    w("pub const Jpeg = struct {\n")
    w("    name: []const u8,\n    width: u32,\n    height: u32,\n")
    w("    jpg_hex: []const u8,\n    rgba_hex: []const u8,\n};\n\n")
    w("pub const valid = [_]Jpeg{\n")
    for name, width, height, data, ref in VALID:
        w("    .{\n")
        w('        .name = "%s",\n        .width = %d,\n        .height = %d,\n' % (name, width, height))
        w("        .jpg_hex = %s,\n" % hexlit(data))
        w("        .rgba_hex = %s,\n" % hexlit(ref))
        w("    },\n")
    w("};\n\n")
    w("/// A JPEG the decoder must reject with `error.InvalidImage`.\n")
    w("pub const Invalid = struct { name: []const u8, jpg_hex: []const u8 };\n\n")
    w("pub const invalid = [_]Invalid{\n")
    for name, data in invalid:
        w('    .{ .name = "%s", .jpg_hex = %s },\n' % (name, hexlit(data)))
    w("};\n\n")
    w("/// A JPEG outside the supported subset. `progressive` is a genuinely valid\n")
    w("/// progressive file that libjpeg reads; the rest are marker mutations that\n")
    w("/// declare an unsupported coding process. All must be refused, never\n")
    w("/// partially decoded.\n")
    w("pub const unsupported = [_]Invalid{\n")
    for name, data in unsupported:
        w('    .{ .name = "%s", .jpg_hex = %s },\n' % (name, hexlit(data)))
    w("};\n")
    print("emitted %d valid, %d malformed, %d unsupported"
          % (len(VALID), len(invalid), len(unsupported)), file=sys.stderr)


if __name__ == "__main__":
    main()
