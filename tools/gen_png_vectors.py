#!/usr/bin/env python3
"""Generate PNG / DEFLATE test vectors for the CoreXEngine decoders.

The vectors are produced with Python's `zlib` (a reference implementation that is
completely independent of the Zig decoder) so the tests compare our decoder
against a trusted encoder instead of against itself.

Usage (from the repository root):

    python3 tools/gen_png_vectors.py > src/assets/png_vectors.zig

The emitted Zig file contains only data: hex strings plus the expected RGBA8
output for each valid PNG. Byte strings are emitted as `"..." ++ "..."` chunks so
no newlines end up inside the hex payload.
"""

import struct
import sys
import zlib

HEX_CHUNK = 96


def hexlit(data: bytes) -> str:
    h = data.hex()
    parts = [h[i : i + HEX_CHUNK] for i in range(0, len(h), HEX_CHUNK)]
    if not parts:
        return '""'
    return ' ++\n        '.join('"%s"' % p for p in parts)


def chunk(typ: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + typ
        + data
        + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
    )


SIGNATURE = b"\x89PNG\r\n\x1a\n"


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def apply_filter(ft: int, row: bytes, prev: bytes, bpp: int) -> bytes:
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i] if prev else 0
        c = prev[i - bpp] if (prev and i >= bpp) else 0
        if ft == 0:
            v = x
        elif ft == 1:
            v = x - a
        elif ft == 2:
            v = x - b
        elif ft == 3:
            v = x - ((a + b) // 2)
        elif ft == 4:
            v = x - paeth(a, b, c)
        else:
            raise ValueError(ft)
        out.append(v & 0xFF)
    return bytes(out)


def pack_rows(rows, depth: int) -> bytes:
    out = []
    for r in rows:
        if depth == 8:
            out.append(bytes(r))
        elif depth == 16:
            out.append(b"".join(struct.pack(">H", s) for s in r))
        else:
            per = 8 // depth
            mask = (1 << depth) - 1
            bs = bytearray()
            for i in range(0, len(r), per):
                v = 0
                for j in range(per):
                    s = r[i + j] if i + j < len(r) else 0
                    v = (v << depth) | (s & mask)
                bs.append(v)
            out.append(bytes(bs))
    return b"".join(out)


def raw_scanlines(rows, depth: int, channels: int, width: int, filters) -> bytes:
    packed = pack_rows(rows, depth)
    row_bytes = (width * channels * depth + 7) // 8
    bpp = max(1, (channels * depth + 7) // 8)
    out = bytearray()
    prev = b""
    for y in range(len(rows)):
        row = packed[y * row_bytes : (y + 1) * row_bytes]
        ft = filters[y % len(filters)]
        out.append(ft)
        out += apply_filter(ft, row, prev, bpp)
        prev = row
    return bytes(out)


def to_rgba(rows, width, depth, ct, palette=None, trns=None) -> bytes:
    maxv = (1 << depth) - 1

    def scale(s: int) -> int:
        if depth == 16:
            return s >> 8
        if depth == 8:
            return s
        return s * 255 // maxv

    out = bytearray()
    for r in rows:
        for x in range(width):
            if ct == 3:
                idx = r[x]
                p = palette[idx]
                a = trns[idx] if (trns is not None and idx < len(trns)) else 255
                out += bytes((p[0], p[1], p[2], a))
            elif ct == 0:
                s = r[x]
                v = scale(s)
                a = 0 if (trns is not None and s == trns) else 255
                out += bytes((v, v, v, a))
            elif ct == 2:
                ss = r[x * 3 : x * 3 + 3]
                a = 0 if (trns is not None and tuple(ss) == tuple(trns)) else 255
                out += bytes((scale(ss[0]), scale(ss[1]), scale(ss[2]), a))
            elif ct == 4:
                s, al = r[x * 2], r[x * 2 + 1]
                v = scale(s)
                out += bytes((v, v, v, scale(al)))
            elif ct == 6:
                ss = r[x * 4 : x * 4 + 4]
                out += bytes((scale(ss[0]), scale(ss[1]), scale(ss[2]), scale(ss[3])))
            else:
                raise ValueError(ct)
    return bytes(out)


def ihdr(width, height, depth, ct, interlace=0) -> bytes:
    return chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, ct, 0, 0, interlace))


def build_png(
    rows,
    width,
    height,
    depth,
    ct,
    filters=(0, 1, 2, 3, 4),
    palette=None,
    trns=None,
    level=9,
    strategy=zlib.Z_DEFAULT_STRATEGY,
    interlace=0,
    extra_before=(),
    idat_parts=1,
):
    raw = raw_scanlines(rows, depth, CHANNELS[ct], width, filters)
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strategy)
    z = co.compress(raw) + co.flush()
    body = ihdr(width, height, depth, ct, interlace)
    if palette is not None:
        body += chunk(b"PLTE", b"".join(bytes(p) for p in palette))
    if trns is not None:
        if ct == 3:
            body += chunk(b"tRNS", bytes(trns))
        elif ct == 0:
            body += chunk(b"tRNS", struct.pack(">H", trns))
        elif ct == 2:
            body += chunk(b"tRNS", struct.pack(">HHH", *trns))
    for typ, data in extra_before:
        body += chunk(typ, data)
    step = max(1, len(z) // idat_parts)
    for i in range(0, len(z), step):
        body += chunk(b"IDAT", z[i : i + step])
    body += chunk(b"IEND", b"")
    return SIGNATURE + body


CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}

VALID = []


def add_valid(name, rows, width, height, depth, ct, **kw):
    png = build_png(rows, width, height, depth, ct, **kw)
    rgba = to_rgba(
        rows, width, depth, ct, palette=kw.get("palette"), trns=kw.get("trns")
    )
    VALID.append((name, width, height, png, rgba))


def ramp_rows(width, height, channels, depth, seed=1):
    maxv = (1 << depth) - 1
    rows = []
    for y in range(height):
        r = []
        for x in range(width):
            for c in range(channels):
                r.append((x * 37 + y * 91 + c * 53 + seed * 17) % (maxv + 1))
        rows.append(r)
    return rows


def main() -> None:
    # --- valid PNGs -------------------------------------------------------
    add_valid("rgb8_all_filters", ramp_rows(5, 5, 3, 8), 5, 5, 8, 2)
    add_valid("rgba8_mixed_filters", ramp_rows(4, 3, 4, 8, 2), 4, 3, 8, 6, filters=(4, 1, 3))
    add_valid("gray8", ramp_rows(4, 2, 1, 8, 3), 4, 2, 8, 0, filters=(0, 1))
    add_valid("gray16", ramp_rows(3, 2, 1, 16, 4), 3, 2, 16, 0)
    add_valid("rgb16", ramp_rows(2, 2, 3, 16, 5), 2, 2, 16, 2)
    add_valid("rgba16", ramp_rows(2, 2, 4, 16, 6), 2, 2, 16, 6)
    add_valid("gray_alpha8", ramp_rows(3, 2, 2, 8, 7), 3, 2, 8, 4)
    add_valid("gray_alpha16", ramp_rows(2, 2, 2, 16, 8), 2, 2, 16, 4)

    pal = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (12, 34, 56), (250, 251, 252)]
    pal_rows = [[(x + y) % 5 for x in range(4)] for y in range(3)]
    add_valid(
        "palette8_trns",
        pal_rows,
        4,
        3,
        8,
        3,
        palette=pal,
        trns=[0, 128, 255],
    )
    add_valid(
        "palette4",
        [[(x * 3 + y) % 4 for x in range(5)] for y in range(2)],
        5,
        2,
        4,
        3,
        palette=pal[:4],
    )
    add_valid(
        "palette2",
        [[(x + y) % 3 for x in range(5)] for y in range(2)],
        5,
        2,
        2,
        3,
        palette=pal[:3],
    )
    add_valid(
        "palette1",
        [[(x + y) % 2 for x in range(9)] for y in range(2)],
        9,
        2,
        1,
        3,
        palette=pal[:2],
    )
    add_valid("gray4", [[(x * 5 + y * 3) % 16 for x in range(5)] for y in range(2)], 5, 2, 4, 0)
    add_valid("gray2", [[(x + y) % 4 for x in range(5)] for y in range(2)], 5, 2, 2, 0)
    add_valid("gray1", [[(x + y) % 2 for x in range(9)] for y in range(2)], 9, 2, 1, 0)

    key_rows = [[0, 60, 120, 255], [60, 0, 255, 120]]
    add_valid("gray8_color_key", key_rows, 4, 2, 8, 0, trns=60)
    rgb_key_rows = [
        [10, 20, 30, 40, 50, 60, 70, 80, 90],
        [40, 50, 60, 10, 20, 30, 90, 80, 70],
    ]
    add_valid("rgb8_color_key", rgb_key_rows, 3, 2, 8, 2, trns=(40, 50, 60))
    add_valid(
        "rgb16_color_key",
        [[1000, 2000, 3000, 40000, 50000, 60000]],
        2,
        1,
        16,
        2,
        trns=(1000, 2000, 3000),
    )
    add_valid("one_pixel_rgba8", [[7, 8, 9, 10]], 1, 1, 8, 6)

    grad = []
    for y in range(32):
        r = []
        for x in range(32):
            r += [x * 8 % 256, y * 8 % 256, (x + y) * 4 % 256, 255]
        grad.append(r)
    add_valid("rgba8_gradient32", grad, 32, 32, 8, 6, level=9)
    add_valid("rgb8_stored_blocks", ramp_rows(8, 8, 3, 8, 9), 8, 8, 8, 2, level=0)
    add_valid(
        "rgb8_fixed_huffman",
        ramp_rows(8, 8, 3, 8, 10),
        8,
        8,
        8,
        2,
        strategy=zlib.Z_FIXED,
    )
    add_valid(
        "rgb8_ancillary_chunks",
        ramp_rows(4, 4, 3, 8, 11),
        4,
        4,
        8,
        2,
        extra_before=((b"gAMA", struct.pack(">I", 45455)), (b"tEXt", b"Comment\x00CoreX")),
    )
    add_valid("rgb8_multi_idat", ramp_rows(6, 6, 3, 8, 12), 6, 6, 8, 2, idat_parts=4)

    # --- invalid PNGs -----------------------------------------------------
    invalid = []

    def add_invalid(name, data):
        invalid.append((name, data))

    good = build_png(ramp_rows(4, 4, 3, 8), 4, 4, 8, 2)

    add_invalid("bad_signature", b"\x88PNG\r\n\x1a\n" + good[8:])
    add_invalid("truncated_header", good[:12])
    add_invalid("no_idat", SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"IEND", b""))
    add_invalid("missing_iend", good[: -len(chunk(b"IEND", b""))])
    add_invalid("trailing_bytes", good + b"junk")
    add_invalid("unknown_critical_chunk", SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"ABCD", b"x") + good[len(SIGNATURE) + 25 :])
    add_invalid("zero_width", SIGNATURE + ihdr(0, 4, 8, 2) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b""))
    add_invalid(
        "oversize_width",
        SIGNATURE + ihdr(16385, 1, 8, 2) + chunk(b"IDAT", zlib.compress(b"\x00")) + chunk(b"IEND", b""),
    )
    add_invalid(
        "bad_bit_depth_for_color",
        SIGNATURE + ihdr(4, 4, 4, 2) + chunk(b"IDAT", zlib.compress(b"\x00" * 28)) + chunk(b"IEND", b""),
    )
    add_invalid(
        "bad_color_type",
        SIGNATURE + ihdr(4, 4, 8, 5) + chunk(b"IDAT", zlib.compress(b"\x00" * 68)) + chunk(b"IEND", b""),
    )
    add_invalid(
        "palette_missing",
        SIGNATURE + ihdr(4, 4, 8, 3) + chunk(b"IDAT", zlib.compress(b"\x00" * 20)) + chunk(b"IEND", b""),
    )
    add_invalid(
        "palette_index_out_of_range",
        build_png([[(x + y) % 4 for x in range(4)] for y in range(4)], 4, 4, 8, 3, palette=pal[:2]),
    )

    # Non-consecutive IDAT chunks (forbidden by the PNG specification).
    raw = raw_scanlines(ramp_rows(4, 4, 3, 8), 8, 3, 4, (0,))
    z = zlib.compress(raw, 9)
    add_invalid(
        "nonconsecutive_idat",
        SIGNATURE
        + ihdr(4, 4, 8, 2)
        + chunk(b"IDAT", z[:5])
        + chunk(b"tEXt", b"a\x00b")
        + chunk(b"IDAT", z[5:])
        + chunk(b"IEND", b""),
    )

    # Wrong inflated size (one scanline missing).
    add_invalid(
        "inflated_size_mismatch",
        SIGNATURE
        + ihdr(4, 4, 8, 2)
        + chunk(b"IDAT", zlib.compress(raw[: 3 * 13], 9))
        + chunk(b"IEND", b""),
    )

    # Invalid row filter byte.
    bad_filter = bytearray(raw)
    bad_filter[0] = 5
    add_invalid(
        "bad_row_filter",
        SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"IDAT", zlib.compress(bytes(bad_filter), 9)) + chunk(b"IEND", b""),
    )

    # Corrupt the zlib Adler-32 trailer, keeping the chunk CRC valid.
    broken_adler = bytearray(z)
    broken_adler[-1] ^= 0xFF
    add_invalid(
        "bad_adler32",
        SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"IDAT", bytes(broken_adler)) + chunk(b"IEND", b""),
    )

    # Invalid zlib header.
    add_invalid(
        "bad_zlib_header",
        SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"IDAT", b"\x00\x00" + z[2:]) + chunk(b"IEND", b""),
    )

    # Truncated deflate payload.
    add_invalid(
        "truncated_idat",
        SIGNATURE + ihdr(4, 4, 8, 2) + chunk(b"IDAT", z[: len(z) // 2]) + chunk(b"IEND", b""),
    )

    # Corrupt CRC on the first IDAT chunk.
    crc_bytes = bytearray(good)
    idx = crc_bytes.index(b"IDAT")
    end = idx + 4 + struct.unpack(">I", crc_bytes[idx - 4 : idx])[0]
    crc_bytes[end] ^= 0xFF
    add_invalid("bad_chunk_crc", bytes(crc_bytes))

    # --- DEFLATE / zlib vectors ------------------------------------------
    pattern = bytes(range(256)) * 800
    zlib_pattern = zlib.compress(pattern, 1)

    fixed_payload = bytes(((i * i + i) % 251) for i in range(4096))
    co = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_FIXED)
    zlib_fixed = co.compress(fixed_payload) + co.flush()

    stored_text = b"CoreXEngine inflate stored block vector\n" * 8
    zlib_stored = zlib.compress(stored_text, 0)

    raw_text = b"hello hello hello world, hello CoreXEngine world"
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw_deflate = co.compress(raw_text) + co.flush()

    # --- emit -------------------------------------------------------------
    w = sys.stdout.write
    w("//! Generated test vectors for the PNG and DEFLATE decoders. DO NOT EDIT.\n")
    w("//!\n")
    w("//! Regenerate with:\n")
    w("//!     python3 tools/gen_png_vectors.py > src/assets/png_vectors.zig\n")
    w("//!\n")
    w("//! Every PNG here was produced by Python's zlib (an implementation independent\n")
    w("//! of the Zig decoder), and every `rgba_hex` is the expected RGBA8 output\n")
    w("//! computed by the generator, so the tests check the decoder against a\n")
    w("//! trusted reference rather than against itself.\n\n")

    w("/// A valid PNG plus the RGBA8 pixels the decoder must produce.\n")
    w("pub const Png = struct {\n")
    w("    name: []const u8,\n    width: u32,\n    height: u32,\n")
    w("    png_hex: []const u8,\n    rgba_hex: []const u8,\n};\n\n")
    w("pub const valid = [_]Png{\n")
    for name, width, height, png, rgba in VALID:
        w("    .{\n")
        w('        .name = "%s",\n        .width = %d,\n        .height = %d,\n' % (name, width, height))
        w("        .png_hex = %s,\n" % hexlit(png))
        w("        .rgba_hex = %s,\n" % hexlit(rgba))
        w("    },\n")
    w("};\n\n")

    w("/// A malformed PNG the decoder must reject with `error.InvalidImage`.\n")
    w("pub const Invalid = struct { name: []const u8, png_hex: []const u8 };\n\n")
    w("pub const invalid = [_]Invalid{\n")
    for name, data in invalid:
        w('    .{ .name = "%s", .png_hex = %s },\n' % (name, hexlit(data)))
    w("};\n\n")

    w("/// zlib stream (level 1, multiple dynamic-Huffman blocks) whose plaintext is\n")
    w("/// `bytes(range(256))` repeated 800 times.\n")
    w("pub const zlib_pattern256_hex = %s;\n" % hexlit(zlib_pattern))
    w("pub const zlib_pattern256_len: usize = %d;\n\n" % len(pattern))

    w("/// zlib stream forced to fixed-Huffman blocks; plaintext byte `i` is\n")
    w("/// `(i * i + i) % 251`.\n")
    w("pub const zlib_fixed_hex = %s;\n" % hexlit(zlib_fixed))
    w("pub const zlib_fixed_len: usize = %d;\n\n" % len(fixed_payload))

    w("/// zlib stream made only of stored (uncompressed) blocks.\n")
    w("pub const zlib_stored_hex = %s;\n" % hexlit(zlib_stored))
    w('pub const zlib_stored_text = "%s";\n\n' % stored_text.decode().replace("\n", "\\n"))

    w("/// Raw DEFLATE stream (no zlib wrapper).\n")
    w("pub const raw_deflate_hex = %s;\n" % hexlit(raw_deflate))
    w('pub const raw_deflate_text = "%s";\n' % raw_text.decode())


if __name__ == "__main__":
    main()
