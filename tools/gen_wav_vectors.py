#!/usr/bin/env python3
"""Generate WAV / CXAW test vectors for the CoreXEngine audio decoder.

The vectors are produced with Python's `struct` (a reference implementation that
is completely independent of the Zig decoder), and each valid vector carries the
expected interleaved float32 output computed here, so the tests compare the
decoder against a trusted encoder instead of against itself.

Usage (from the repository root):

    python3 tools/gen_wav_vectors.py > src/assets/audio_vectors.zig
"""

import struct
import sys

HEX_CHUNK = 96


def hexlit(data: bytes) -> str:
    h = data.hex()
    parts = [h[i : i + HEX_CHUNK] for i in range(0, len(h), HEX_CHUNK)]
    if not parts:
        return '""'
    return ' ++\n        '.join('"%s"' % p for p in parts)


def chunk(tag: bytes, payload: bytes, pad: bool = True) -> bytes:
    out = tag + struct.pack("<I", len(payload)) + payload
    if pad and len(payload) % 2 == 1:
        out += b"\x00"
    return out


# KSDATAFORMAT_SUBTYPE_{PCM,IEEE_FLOAT}: Data1 u32 LE, Data2 u16 LE, Data3 u16 LE,
# Data4 8 bytes — 16 bytes total.
_GUID_TAIL = bytes.fromhex("800000aa00389b71")
PCM_GUID = struct.pack("<IHH", 1, 0, 0x0010) + _GUID_TAIL
FLOAT_GUID = struct.pack("<IHH", 3, 0, 0x0010) + _GUID_TAIL
assert len(PCM_GUID) == 16 and len(FLOAT_GUID) == 16


def fmt_chunk(tag, channels, rate, bits, extensible=False, guid=None, mask=0, cb=22):
    block_align = channels * (bits // 8)
    body = struct.pack(
        "<HHIIHH", tag, channels, rate, rate * block_align, block_align, bits
    )
    if extensible:
        body += struct.pack("<HHI", cb, bits, mask) + (guid or PCM_GUID)
    return chunk(b"fmt ", body)


def wav(body: bytes, riff_size=None) -> bytes:
    # The RIFF size covers everything after the size field: the 4-byte "WAVE"
    # form type plus every chunk (including pad bytes).
    size = len(body) + 4 if riff_size is None else riff_size
    return b"RIFF" + struct.pack("<I", size) + b"WAVE" + body


def encode_samples(samples, bits, is_float):
    """samples: flat list of ints (or floats when is_float)."""
    if is_float:
        return b"".join(struct.pack("<f", s) for s in samples)
    if bits == 8:
        return bytes((s + 128) & 0xFF for s in samples)
    if bits == 16:
        return b"".join(struct.pack("<h", s) for s in samples)
    if bits == 24:
        out = bytearray()
        for s in samples:
            out += (s & 0xFFFFFF).to_bytes(3, "little")
        return bytes(out)
    if bits == 32:
        return b"".join(struct.pack("<i", s) for s in samples)
    raise ValueError(bits)


def to_f32(samples, bits, is_float):
    if is_float:
        values = list(samples)
    elif bits == 8:
        values = [s / 128.0 for s in samples]
    else:
        scale = float(1 << (bits - 1))
        values = [s / scale for s in samples]
    return b"".join(struct.pack("<f", v) for v in values)


VALID = []
INVALID = []


def add_valid(name, samples, channels, rate, bits, is_float=False, **kw):
    data = encode_samples(samples, bits, is_float)
    tag = 3 if is_float else 1
    extensible = kw.get("extensible", False)
    fmt_tag = 0xFFFE if extensible else tag
    guid = (FLOAT_GUID if is_float else PCM_GUID) if extensible else None
    body = fmt_chunk(
        fmt_tag,
        channels,
        rate,
        bits,
        extensible=extensible,
        guid=guid,
        mask=kw.get("mask", 0),
    )
    for tag_name, payload in kw.get("before", ()):
        body += chunk(tag_name, payload)
    body += chunk(b"data", data, pad=kw.get("pad", True))
    for tag_name, payload in kw.get("after", ()):
        body += chunk(tag_name, payload)
    frames = len(samples) // channels
    VALID.append(
        (name, channels, rate, frames, wav(body), to_f32(samples, bits, is_float))
    )


def add_invalid(name, data):
    INVALID.append((name, data))


def main() -> None:
    # --- valid WAVs -------------------------------------------------------
    add_valid("pcm8_mono", [-128, -64, 0, 1, 63, 127, -1, 100], 1, 8000, 8)
    add_valid("pcm16_mono", [0, 1, -1, 32767, -32768, 12345, -12345, 16384], 1, 44100, 16)
    add_valid(
        "pcm16_stereo",
        [0, 32767, -32768, -1, 1000, -1000, 20000, -20000, 5, -5, 32766, -32767],
        2,
        48000,
        16,
    )
    add_valid("pcm24_mono", [0, 1, -1, 8388607, -8388608, 1234567, -1234567], 1, 44100, 24)
    add_valid(
        "pcm24_stereo",
        [8388607, -8388608, -1, 1, 500000, -500000, 0, 123],
        2,
        96000,
        24,
    )
    add_valid(
        "pcm32_mono",
        [0, 1, -1, 2147483647, -2147483648, 123456789, -123456789],
        1,
        48000,
        32,
    )
    add_valid(
        "float32_mono",
        [0.0, 1.0, -1.0, 0.5, -0.25, 1.5, -2.0, 0.001],
        1,
        44100,
        32,
        is_float=True,
    )
    add_valid(
        "float32_stereo",
        [0.25, -0.25, 0.75, -0.75, 1.0, -1.0, 0.0, 0.125],
        2,
        48000,
        32,
        is_float=True,
    )
    add_valid(
        "extensible_pcm16_stereo",
        [1, -1, 32767, -32768, 100, -100],
        2,
        44100,
        16,
        extensible=True,
        mask=0x3,
    )
    add_valid(
        "extensible_float32_6ch",
        [0.1 * (i + 1) for i in range(12)],
        6,
        48000,
        32,
        is_float=True,
        extensible=True,
        mask=0x3F,
    )
    add_valid("pcm8_odd_data", [-128, 0, 127], 1, 8000, 8)
    add_valid("pcm8_odd_data_no_pad", [-128, 0, 127], 1, 8000, 8, pad=False)
    add_valid(
        "pcm16_extra_chunks",
        [10, -10, 20, -20],
        2,
        22050,
        16,
        before=((b"LIST", b"INFOICMT\x04\x00\x00\x00Core"),),
        after=((b"fact", struct.pack("<I", 2)), (b"cue ", b"\x00" * 4)),
    )
    add_valid("pcm16_one_frame", [-32768], 1, 8000, 16)
    add_valid("pcm16_192k", [0, 32767, -32768, 1], 1, 192000, 16)

    # --- invalid WAVs -----------------------------------------------------
    good_body = fmt_chunk(1, 1, 8000, 16) + chunk(b"data", encode_samples([1, -1], 16, False))
    good = wav(good_body)

    add_invalid("bad_riff_magic", b"RIFX" + good[4:])
    add_invalid("not_wave", b"RIFF" + good[4:8] + b"AVI " + good[12:])
    add_invalid("truncated_header", good[:9])
    add_invalid("empty", b"")
    add_invalid(
        "missing_fmt", wav(chunk(b"data", encode_samples([1, -1], 16, False)))
    )
    add_invalid("missing_data", wav(fmt_chunk(1, 1, 8000, 16)))
    add_invalid(
        "duplicate_fmt",
        wav(fmt_chunk(1, 1, 8000, 16) + fmt_chunk(1, 1, 8000, 16) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "unsupported_adpcm",
        wav(fmt_chunk(0x11, 1, 8000, 4) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "unsupported_mulaw",
        wav(fmt_chunk(7, 1, 8000, 8) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "bad_bits",
        wav(fmt_chunk(1, 1, 8000, 12) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "zero_channels",
        wav(fmt_chunk(1, 0, 8000, 16) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "too_many_channels",
        wav(fmt_chunk(1, 9, 8000, 16) + chunk(b"data", b"\x00" * 36)),
    )
    add_invalid(
        "zero_sample_rate",
        wav(fmt_chunk(1, 1, 0, 16) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "oversized_sample_rate",
        wav(fmt_chunk(1, 1, 384001, 16) + chunk(b"data", b"\x00\x00")),
    )
    add_invalid(
        "empty_data",
        wav(fmt_chunk(1, 1, 8000, 16) + chunk(b"data", b"")),
    )
    add_invalid(
        "data_not_block_aligned",
        wav(fmt_chunk(1, 2, 8000, 16) + chunk(b"data", b"\x00" * 5)),
    )
    add_invalid(
        "truncated_data",
        wav(fmt_chunk(1, 1, 8000, 16) + b"data" + struct.pack("<I", 64) + b"\x00\x00"),
    )
    add_invalid("bad_riff_size", wav(good_body, riff_size=len(good_body) + 100))
    add_invalid(
        "extensible_bad_guid",
        wav(
            fmt_chunk(0xFFFE, 1, 8000, 16, extensible=True, guid=b"\x01" + b"\xFF" * 15)
            + chunk(b"data", b"\x00\x00"),
        ),
    )
    add_invalid(
        "extensible_short_cbsize",
        wav(
            fmt_chunk(0xFFFE, 1, 8000, 16, extensible=True, cb=0)
            + chunk(b"data", b"\x00\x00"),
        ),
    )
    add_invalid(
        "float_nan",
        wav(
            fmt_chunk(3, 1, 8000, 32)
            + chunk(b"data", struct.pack("<f", float("nan"))),
        ),
    )
    add_invalid(
        "float_infinity",
        wav(
            fmt_chunk(3, 1, 8000, 32)
            + chunk(b"data", struct.pack("<f", float("inf"))),
        ),
    )
    add_invalid(
        "unknown_critical_chunk_order",
        wav(chunk(b"data", b"\x00\x00") + fmt_chunk(1, 1, 8000, 16)),
    )

    # --- emit -------------------------------------------------------------
    w = sys.stdout.write
    w("//! Generated test vectors for the WAV audio decoder. DO NOT EDIT.\n")
    w("//!\n")
    w("//! Regenerate with:\n")
    w("//!     python3 tools/gen_wav_vectors.py > src/assets/audio_vectors.zig\n")
    w("//!\n")
    w("//! Every WAV here was produced by Python's struct module (independent of the\n")
    w("//! Zig decoder), and every `f32_hex` is the expected interleaved float32\n")
    w("//! output computed by the generator, so the tests check the decoder against\n")
    w("//! a trusted reference rather than against itself.\n\n")

    w("/// A valid WAV plus the interleaved f32 samples the decoder must produce.\n")
    w("pub const Wav = struct {\n")
    w("    name: []const u8,\n    channels: u16,\n    sample_rate: u32,\n")
    w("    frames: u32,\n    wav_hex: []const u8,\n    f32_hex: []const u8,\n};\n\n")
    w("pub const valid = [_]Wav{\n")
    for name, channels, rate, frames, data, expected in VALID:
        w("    .{\n")
        w('        .name = "%s",\n' % name)
        w("        .channels = %d,\n        .sample_rate = %d,\n        .frames = %d,\n" % (channels, rate, frames))
        w("        .wav_hex = %s,\n" % hexlit(data))
        w("        .f32_hex = %s,\n" % hexlit(expected))
        w("    },\n")
    w("};\n\n")

    w("/// A malformed WAV the decoder must reject with `error.InvalidAudio`.\n")
    w("pub const Invalid = struct { name: []const u8, wav_hex: []const u8 };\n\n")
    w("pub const invalid = [_]Invalid{\n")
    for name, data in INVALID:
        w('    .{ .name = "%s", .wav_hex = %s },\n' % (name, hexlit(data)))
    w("};\n")


if __name__ == "__main__":
    main()
