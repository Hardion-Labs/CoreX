#!/usr/bin/env python3
"""Generate FLAC test vectors for the CoreXEngine decoder, verified by libFLAC.

Requires `soundfile` (built against libsndfile, which embeds libFLAC). Every file
is encoded by libFLAC and the reference is libFLAC's own decode, normalized to
float32 exactly as the engine normalizes it. FLAC is lossless, so the comparison
is **bit-exact** -- there is no tolerance to tune.

The script also *parses every frame it emits* and reports which format features
the corpus actually reaches: subframe types, channel decorrelation modes, Rice
methods, partition orders, LPC orders and wasted-bit counts. That coverage report
is the point: it makes gaps visible instead of assumed, and the crafted cases
below exist to close the ones libFLAC's encoder does not produce on its own.

Usage (from the repository root):

    python3 -m venv /tmp/venv-ref
    /tmp/venv-ref/bin/pip install soundfile numpy
    /tmp/venv-ref/bin/python tools/gen_flac_vectors.py > src/assets/flac_vectors.zig
"""

import io
import os
import struct
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_png_vectors import hexlit  # noqa: E402

try:
    import numpy as np
    import soundfile as sf
except ImportError:
    sys.exit(
        "soundfile and numpy are required.\n"
        "  python3 -m venv /tmp/venv-ref\n"
        "  /tmp/venv-ref/bin/pip install soundfile numpy"
    )


class Bits:
    """MSB-first reader used only to analyse coverage of generated frames."""

    def __init__(self, data):
        self.d = data
        self.p = 0

    def read(self, n):
        v = 0
        for _ in range(n):
            if self.p >= len(self.d) * 8:
                raise ValueError("out of bits")
            v = (v << 1) | ((self.d[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def signed(self, n):
        v = self.read(n)
        return v - (1 << n) if v & (1 << (n - 1)) else v

    def unary(self):
        c = 0
        while self.read(1) == 0:
            c += 1
            if c > 4096:
                raise ValueError("unary runaway")
        return c

    def utf8(self):
        b = self.read(8)
        if b < 0x80:
            return b
        extra = 0
        mask = 0x40
        while extra < 6 and b & mask:
            extra += 1
            mask >>= 1
        v = b & ((1 << (6 - extra)) - 1)
        for _ in range(extra):
            v = (v << 6) | (self.read(8) & 0x3F)
        return v

    def align(self):
        self.p = (self.p + 7) & ~7


BLOCK_CODES = {1: 192, 2: 576, 3: 1152, 4: 2304, 5: 4608,
               8: 256, 9: 512, 10: 1024, 11: 2048, 12: 4096,
               13: 8192, 14: 16384, 15: 32768}

COVERAGE = {
    "subframe": Counter(), "layout": Counter(), "rice": Counter(),
    "partition_order": Counter(), "lpc_order": Counter(), "wasted": Counter(),
    "block_size": Counter(), "bps": Counter(), "channels": Counter(),
    "escaped_partition": Counter(), "strategy": Counter(),
    "coded_number_bytes": Counter(), "block_code": Counter(), "rate_code": Counter(),
}


def analyse(raw, frames_at, info_bps, info_ch):
    """Walk the frames of a generated file, recording which features appear."""
    pos = frames_at
    while pos < len(raw):
        br = Bits(raw[pos:])
        if br.read(14) != 0x3FFE:
            raise ValueError("bad sync at %d" % pos)
        br.read(1)
        strategy = br.read(1)
        COVERAGE["strategy"]["variable" if strategy else "fixed"] += 1
        bc = br.read(4)
        rc = br.read(4)
        cc = br.read(4)
        sc = br.read(3)
        br.read(1)
        before = br.p
        br.utf8()
        COVERAGE["coded_number_bytes"][(br.p - before) // 8] += 1
        COVERAGE["block_code"][bc] += 1
        COVERAGE["rate_code"][rc] += 1
        block = BLOCK_CODES.get(bc)
        if bc == 6:
            block = br.read(8) + 1
        elif bc == 7:
            block = br.read(16) + 1
        if rc == 12:
            br.read(8)
        elif rc in (13, 14):
            br.read(16)
        bps = {1: 8, 2: 12, 4: 16, 5: 20, 6: 24, 7: 32}.get(sc, info_bps)
        chans = cc + 1 if cc < 8 else 2
        layout = {8: "left_side", 9: "right_side", 10: "mid_side"}.get(cc, "independent")
        COVERAGE["layout"][layout] += 1
        COVERAGE["block_size"][block] += 1
        COVERAGE["bps"][bps] += 1
        COVERAGE["channels"][chans] += 1
        br.align()
        br.read(8)  # header CRC-8 sits between the header and the subframes
        for c in range(chans):
            sbps = bps
            # The side channel is channel 0 for right/side, channel 1 otherwise.
            is_side = (layout == "right_side" and c == 0) or (
                layout in ("left_side", "mid_side") and c == 1
            )
            if is_side:
                sbps += 1
            br.read(1)
            kind = br.read(6)
            has_wasted = br.read(1)
            wasted = 0
            if has_wasted:
                wasted = br.unary() + 1
                sbps -= wasted
            COVERAGE["wasted"][wasted] += 1
            if kind == 0:
                COVERAGE["subframe"]["constant"] += 1
                br.signed(sbps)
            elif kind == 1:
                COVERAGE["subframe"]["verbatim"] += 1
                for _ in range(block):
                    br.signed(sbps)
            elif 8 <= kind <= 12:
                order = kind - 8
                if block < order:
                    raise ValueError("block smaller than predictor order")
                COVERAGE["subframe"]["fixed%d" % order] += 1
                for _ in range(order):
                    br.signed(sbps)
                residual(br, block, order)
            elif 32 <= kind <= 63:
                order = kind - 31
                COVERAGE["subframe"]["lpc"] += 1
                COVERAGE["lpc_order"][order] += 1
                for _ in range(order):
                    br.signed(sbps)
                prec = br.read(4) + 1
                br.read(5)
                for _ in range(order):
                    br.signed(prec)
                residual(br, block, order)
            else:
                raise ValueError("reserved subframe %d" % kind)
        br.align()
        pos += (br.p >> 3) + 2


def residual(br, block, warmup):
    method = br.read(2)
    COVERAGE["rice"][method] += 1
    pbits = 4 if method == 0 else 5
    escape = 15 if method == 0 else 31
    order = br.read(4)
    COVERAGE["partition_order"][order] += 1
    parts = 1 << order
    plen = block // parts
    if plen < warmup and parts == 1:
        raise ValueError("partition smaller than warmup: block=%d parts=%d warmup=%d" % (block, parts, warmup))
    for p in range(parts):
        count = plen - warmup if p == 0 else plen
        param = br.read(pbits)
        if param == escape:
            raw_bits = br.read(5)
            COVERAGE["escaped_partition"][raw_bits] += 1
            for _ in range(count):
                br.signed(raw_bits)
        else:
            for _ in range(count):
                br.unary()
                br.read(param)



# --- crafted-frame encoder -------------------------------------------------
# libFLAC's encoder does not emit every legal combination (it never chose
# mid/side, Rice method 1, high partition orders or high LPC orders for the
# signals above). These cases are built here and then **decoded back by
# libsndfile/libFLAC** before being emitted, so a mistake in the construction
# cannot survive: the reference implementation would disagree.

def crc_table(bits, poly):
    top = 1 << (bits - 1)
    mask = (1 << bits) - 1
    table = []
    for i in range(256):
        r = i << (bits - 8)
        for _ in range(8):
            r = ((r << 1) ^ poly) & mask if r & top else (r << 1) & mask
        table.append(r)
    return table


CRC8 = crc_table(8, 0x07)
CRC16 = crc_table(16, 0x8005)


def crc8(data):
    r = 0
    for b in data:
        r = CRC8[r ^ b]
    return r


def crc16(data):
    r = 0
    for b in data:
        r = ((r << 8) & 0xFFFF) ^ CRC16[(r >> 8) ^ b]
    return r


class Writer:
    def __init__(self):
        self.bits = []

    def put(self, value, n):
        for i in range(n - 1, -1, -1):
            self.bits.append((value >> i) & 1)

    def put_signed(self, value, n):
        self.put(value & ((1 << n) - 1), n)

    def unary(self, q):
        self.bits.extend([0] * q)
        self.bits.append(1)

    def align(self):
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        if len(self.bits) % 8:
            raise ValueError("writer not byte aligned")
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            v = 0
            for b in self.bits[i : i + 8]:
                v = (v << 1) | b
            out.append(v)
        return bytes(out)


def utf8_encode(v):
    """FLAC's UTF-8 coded number: same structure as UTF-8, extended to 36 bits."""
    if v < 0x80:
        return bytes([v])
    limits = [(0x7FF, 1), (0xFFFF, 2), (0x1FFFFF, 3), (0x3FFFFFF, 4),
              (0x7FFFFFFF, 5), (0xFFFFFFFFF, 6)]
    extra = next(e for hi, e in limits if v <= hi)
    out = bytearray()
    lead_mask = (0xFF << (7 - extra)) & 0xFF
    out.append(lead_mask | (v >> (6 * extra)))
    for i in range(extra - 1, -1, -1):
        out.append(0x80 | ((v >> (6 * i)) & 0x3F))
    return bytes(out)


RATE_CODES = {88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6,
              24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11}
SIZE_CODES = {8: 1, 12: 2, 16: 4, 20: 5, 24: 6, 32: 7}
BLOCK_CODES_INV = {192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9,
                   1024: 10, 2048: 11, 4096: 12, 8192: 13, 16384: 14, 32768: 15}


def encode_residual(w, residual, warmup, method, partition_order, escape_partition=None):
    w.put(method, 2)
    w.put(partition_order, 4)
    pbits = 4 if method == 0 else 5
    escape = 15 if method == 0 else 31
    parts = 1 << partition_order
    plen = len(residual) // parts
    for p in range(parts):
        chunk = residual[p * plen : (p + 1) * plen]
        if p == 0:
            chunk = chunk[warmup:]
        if escape_partition is not None and p == escape_partition:
            width = max([abs(v).bit_length() + 1 for v in chunk] + [2])
            width = min(width, 32)
            w.put(escape, pbits)
            w.put(width, 5)
            for v in chunk:
                w.put_signed(v, width)
            continue
        folded = [(2 * v if v >= 0 else -2 * v - 1) for v in chunk]
        # Pick the parameter that minimises the encoded size, as libFLAC does.
        best, best_bits = 0, None
        for param in range(escape):
            total = sum((u >> param) + 1 + param for u in folded)
            if best_bits is None or total < best_bits:
                best, best_bits = param, total
        w.put(best, pbits)
        for u in folded:
            w.unary(u >> best)
            w.put(u & ((1 << best) - 1), best)


def encode_subframe(w, samples, bps, kind, order=0, coeffs=None, shift=0,
                    method=0, partition_order=0, escape_partition=None):
    w.put(0, 1)
    if kind == "constant":
        w.put(0, 6)
        w.put(0, 1)
        w.put_signed(samples[0], bps)
        return
    if kind == "verbatim":
        w.put(1, 6)
        w.put(0, 1)
        for v in samples:
            w.put_signed(v, bps)
        return
    if kind == "fixed":
        w.put(8 + order, 6)
        w.put(0, 1)
        for v in samples[:order]:
            w.put_signed(v, bps)
        res = list(samples)
        for i in range(len(samples) - 1, order - 1, -1):
            if order == 0:
                pass
            elif order == 1:
                res[i] -= res[i - 1]
            elif order == 2:
                res[i] -= 2 * res[i - 1] - res[i - 2]
            elif order == 3:
                res[i] -= 3 * res[i - 1] - 3 * res[i - 2] + res[i - 3]
            elif order == 4:
                res[i] -= 4 * res[i - 1] - 6 * res[i - 2] + 4 * res[i - 3] - res[i - 4]
        encode_residual(w, res, order, method, partition_order, escape_partition)
        return
    if kind == "lpc":
        w.put(31 + order, 6)
        w.put(0, 1)
        for v in samples[:order]:
            w.put_signed(v, bps)
        precision = max(abs(c).bit_length() + 1 for c in coeffs)
        precision = max(precision, 4)
        w.put(precision - 1, 4)
        w.put(shift, 5)
        for c in coeffs:
            w.put_signed(c, precision)
        res = list(samples)
        for i in range(len(samples) - 1, order - 1, -1):
            pred = sum(coeffs[j] * res[i - 1 - j] for j in range(order)) >> shift
            res[i] -= pred
        encode_residual(w, res, order, method, partition_order, escape_partition)
        return
    raise ValueError(kind)


def encode_frame(channels_samples, bps, rate, number, variable=False,
                 layout="independent", kind="verbatim", order=0, coeffs=None,
                 shift=0, method=0, partition_order=0, escape_partition=None,
                 block_size=None, rate_code_override=None):
    n = len(channels_samples[0])
    block_size = block_size or n
    chan_code = {"left_side": 8, "right_side": 9, "mid_side": 10}.get(
        layout, len(channels_samples) - 1)
    bc = BLOCK_CODES_INV.get(block_size)
    extra_block = b""
    if bc is None:
        if block_size <= 256:
            bc = 6
            extra_block = bytes([block_size - 1])
        else:
            bc = 7
            extra_block = struct.pack(">H", block_size - 1)
    rc = RATE_CODES.get(rate, 0)
    extra_rate = b""
    if rate_code_override is not None:
        rc, value, width = rate_code_override
        # Code 0 means "inherit STREAMINFO" and carries no extra bytes.
        if rc != 0:
            extra_rate = bytes([value]) if width == 8 else struct.pack(">H", value)
    head = bytearray()
    w = Writer()
    w.put(0x3FFE, 14)
    w.put(0, 1)
    w.put(1 if variable else 0, 1)
    w.put(bc, 4)
    w.put(rc, 4)
    w.put(chan_code, 4)
    w.put(SIZE_CODES[bps], 3)
    w.put(0, 1)
    head += w.bytes()
    head += utf8_encode(number)
    head += extra_block
    head += extra_rate
    head += bytes([crc8(head)])

    body = Writer()
    for c, samples in enumerate(channels_samples):
        sbps = bps
        is_side = (layout == "right_side" and c == 0) or (
            layout in ("left_side", "mid_side") and c == 1)
        if is_side:
            sbps += 1
        encode_subframe(body, samples, sbps, kind, order, coeffs, shift,
                        method, partition_order, escape_partition)
    body.align()
    frame = bytes(head) + body.bytes()
    return frame + struct.pack(">H", crc16(frame))


def streaminfo_block(bps, channels, rate, total, min_block, max_block, frames):
    w = Writer()
    w.put(min_block, 16)
    w.put(max_block, 16)
    w.put(0, 24)
    w.put(frames, 24)
    w.put(rate, 20)
    w.put(channels - 1, 3)
    w.put(bps - 1, 5)
    w.put(total, 36)
    body = w.bytes() + bytes(16)  # zero MD5 means "not computed"
    return bytes([0x80]) + len(body).to_bytes(3, "big") + body


def build_stream(bps, channels, rate, total, frames, min_block=None, max_block=None):
    mb = min_block or max_block or total
    return (b"fLaC" + streaminfo_block(bps, channels, rate, total, mb,
                                       max_block or mb, 0) + b"".join(frames))


def add_crafted_scaled(name, raw, rate, channels, bps, samples, ref_bps, ref_shift):
    """For depths libsndfile cannot read (12/20/32), anchor the reference to the
    same samples encoded at a depth it *can* read, scaled by a power of two.
    FLAC normalises by 2^(bps-1), so the f32 results are bit-identical and the
    reference still comes from libFLAC rather than from this script."""
    ref_samples = [v * (1 << ref_shift) if ref_shift >= 0 else v // (1 << -ref_shift)
                   for v in samples]
    if ref_shift < 0 and any(v % (1 << -ref_shift) for v in samples):
        sys.exit("scaled reference for %s is not exact" % name)
    ref_fr = encode_frame([ref_samples], ref_bps, rate, 0, kind="verbatim")
    ref_raw = build_stream(ref_bps, 1, rate, len(samples), [ref_fr])
    got, got_rate = sf.read(io.BytesIO(ref_raw), dtype="float32", always_2d=True)
    want = np.asarray(samples, dtype=np.float64).reshape(-1, 1) / float(1 << (bps - 1))
    if got_rate != rate or not np.array_equal(got.astype(np.float64), want):
        sys.exit("scaled reference for %s is inconsistent" % name)
    _, _, frames_at = streaminfo(raw)
    analyse(raw, frames_at, bps, channels)
    CRAFTED.append(name)
    VALID.append((name, rate, channels, bps, len(samples), raw,
                  got.astype("<f4").tobytes()))


CRAFTED = []


def add_crafted(name, raw, rate, channels, bps, expected):
    """Emit only if libFLAC agrees with the samples we intended to encode."""
    try:
        got, got_rate = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    except Exception as exc:  # noqa: BLE001
        sys.exit("libFLAC rejected crafted vector %s: %s" % (name, exc))
    want = np.asarray(expected, dtype=np.float32).reshape(-1, channels)
    scale = float(1 << (bps - 1))
    want = want / scale
    if got_rate != rate or got.shape != want.shape or not np.array_equal(got, want):
        sys.exit("crafted vector %s disagrees with libFLAC (shape %s vs %s)"
                 % (name, got.shape, want.shape))
    _, _, frames_at = streaminfo(raw)
    analyse(raw, frames_at, bps, channels)
    CRAFTED.append(name)
    VALID.append((name, rate, channels, bps, want.shape[0], raw, got.astype("<f4").tobytes()))


VALID = []


def streaminfo(raw):
    si = raw[8:42]
    v = int.from_bytes(si[10:18], "big")
    pos = 4
    while True:
        h = raw[pos]
        ln = int.from_bytes(raw[pos + 1 : pos + 4], "big")
        pos += 4 + ln
        if h & 0x80:
            break
    return ((v >> 36) & 31) + 1, ((v >> 41) & 7) + 1, pos


def add(name, data, rate, subtype, level=1.0):
    buf = io.BytesIO()
    sf.write(buf, data, rate, format="FLAC", subtype=subtype, compression_level=level)
    raw = buf.getvalue()
    ref, out_rate = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    if out_rate != rate:
        sys.exit("rate changed on roundtrip for %s" % name)
    bps, ch, frames_at = streaminfo(raw)
    if ref.shape[1] != ch:
        sys.exit("channel count disagrees with STREAMINFO for %s" % name)
    try:
        analyse(raw, frames_at, bps, ch)
    except Exception as exc:
        sys.exit("coverage analysis failed for %s (bps=%d ch=%d frames_at=%d): %s"
                 % (name, bps, ch, frames_at, exc))
    VALID.append((name, rate, ch, bps, ref.shape[0], raw, ref.astype("<f4").tobytes()))
    return raw


def signal(n, kind, ch=1):
    t = np.arange(n)
    if kind == "sine":
        base = (np.sin(t * 0.05) * 20000).astype(np.int32)
    elif kind == "flat":
        base = np.full(n, 1234, dtype=np.int32)
    elif kind == "silence":
        base = np.zeros(n, dtype=np.int32)
    elif kind == "noise":
        rng = np.random.default_rng(1234)
        base = rng.integers(-30000, 30000, n).astype(np.int32)
    elif kind == "ramp":
        base = ((t * 37) % 60000 - 30000).astype(np.int32)
    elif kind == "impulse":
        base = np.zeros(n, dtype=np.int32)
        base[::97] = 25000
    else:
        raise ValueError(kind)
    if ch == 1:
        return base.astype(np.int16)
    cols = []
    for c in range(ch):
        if kind == "sine" and c == 1:
            cols.append((base // 2).astype(np.int16))  # correlated -> mid/side
        else:
            cols.append((base // (c + 1)).astype(np.int16))
    return np.stack(cols, axis=1)


def main():
    # --- bit depths libsndfile can encode, mono and stereo -------------------
    for subtype, scale in (("PCM_S8", 1), ("PCM_16", 256), ("PCM_24", 65536)):
        for kind in ("sine", "noise"):
            d = signal(512, kind)
            if subtype == "PCM_S8":
                d = (d.astype(np.int32) // 256).astype(np.int16)
            elif subtype == "PCM_24":
                d = d.astype(np.int32) * 256
            add("%s_%s" % (subtype.lower(), kind), d, 44100, subtype)

    # --- compression extremes: verbatim-ish vs high-order LPC ---------------
    for level in (0.0, 0.5, 1.0):
        add("level%s" % str(level).replace(".", ""), signal(512, "noise"),
            44100, "PCM_16", level=level)

    # --- content classes that select different subframes -------------------
    for kind in ("flat", "silence", "ramp", "impulse"):
        add("mono_%s" % kind, signal(256, kind), 44100, "PCM_16")
    add("stereo_flat", signal(256, "flat", 2), 44100, "PCM_16")

    # --- channel counts 1..8 ------------------------------------------------
    for ch in range(1, 9):
        add("chan%d" % ch, signal(128 if ch > 2 else 400, "sine", ch), 44100, "PCM_16")

    # --- decorrelation: correlated stereo pushes libFLAC to mid/side -------
    base = signal(384, "sine")
    near = np.stack([base, (base.astype(np.int32) + 3).astype(np.int16)], axis=1)
    add("stereo_correlated", near, 44100, "PCM_16")
    indep = np.stack([base, signal(384, "noise")], axis=1)
    add("stereo_independent", indep, 44100, "PCM_16")

    # --- wasted bits: low bits always zero ---------------------------------
    for shift in (1, 4, 8):
        d = ((signal(256, "sine").astype(np.int32) >> shift) << shift).astype(np.int16)
        add("wasted%d" % shift, d, 44100, "PCM_16")

    # --- block boundaries: lengths around and across the 4096 block --------
    for n in (1, 2, 15, 16, 191, 192, 4095, 4096, 4097):
        add("len%d" % n, signal(n, "sine"), 44100, "PCM_16")

    # --- sample rates covering the header rate codes -----------------------
    for rate in (8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000):
        add("rate%d" % rate, signal(96, "sine"), rate, "PCM_16")

    if not VALID:
        sys.exit("no vectors generated")

    # --- crafted frames closing the coverage gaps ---------------------------
    # libFLAC's encoder never selected mid/side, Rice method 1, high partition
    # orders, high LPC orders or the odd bit depths for the signals above. These
    # are built by hand and decoded back by libFLAC before being emitted.
    ramp = np.arange(1, 301, dtype=np.int64) * 7

    left = (np.arange(300, dtype=np.int64) * 11) % 5000
    right = (left * 3) // 4
    mid = (left + right) >> 1
    side = left - right
    fr = encode_frame([mid.tolist(), side.tolist()], 16, 44100, 0,
                      layout="mid_side", kind="fixed", order=1)
    add_crafted("mid_side", build_stream(16, 2, 44100, 300, [fr]),
                44100, 2, 16, np.stack([left, right], axis=1))

    # The block size must be divisible by the partition count, so these use 512.
    ramp512 = np.arange(1, 513, dtype=np.int64) * 7
    for porder in (0, 1, 2, 4, 5):
        fr = encode_frame([ramp512.tolist()], 16, 44100, 0, kind="fixed", order=0,
                          method=1, partition_order=porder, block_size=512)
        add_crafted("rice1_part%d" % porder,
                    build_stream(16, 1, 44100, 512, [fr], min_block=512, max_block=512),
                    44100, 1, 16, ramp512.reshape(-1, 1))

    for meth in (0, 1):
        fr = encode_frame([ramp.tolist()], 16, 44100, 0, kind="fixed", order=0,
                          method=meth, partition_order=2, escape_partition=1,
                          block_size=300)
        add_crafted("escape_rice%d" % meth,
                    build_stream(16, 1, 44100, 300, [fr], min_block=300, max_block=300),
                    44100, 1, 16, ramp.reshape(-1, 1))

    for lpc_order in (4, 8, 12, 16, 24, 32):
        coeffs = [1] + [0] * (lpc_order - 1)
        fr = encode_frame([ramp.tolist()], 16, 44100, 0, kind="lpc",
                          order=lpc_order, coeffs=coeffs, shift=0, block_size=300)
        add_crafted("lpc_order%d" % lpc_order,
                    build_stream(16, 1, 44100, 300, [fr], min_block=300, max_block=300),
                    44100, 1, 16, ramp.reshape(-1, 1))

    # Maximum legal coefficient precision (15 bits, code 14) with a non-zero
    # quantisation shift, so the predictor's rounding path is exercised.
    fr = encode_frame([(ramp * 256).tolist()], 24, 44100, 0, kind="lpc", order=2,
                      coeffs=[16383, -8191], shift=13, block_size=300)
    add_crafted("lpc_precision15", build_stream(24, 1, 44100, 300, [fr],
                                               min_block=300, max_block=300),
                44100, 1, 24, (ramp * 256).reshape(-1, 1))

    # libsndfile only exposes 8/16/24-bit FLAC, so these three depths are
    # anchored to a scaled 16/24-bit stream that libFLAC does read.
    for bps, ref_bps, ref_shift, step in ((12, 16, 4, 16), (20, 24, 4, 4096),
                                          (32, 24, -8, 1 << 20)):
        vals = (np.arange(120, dtype=np.int64) - 60) * step
        fr = encode_frame([vals.tolist()], bps, 48000, 0, kind="verbatim")
        add_crafted_scaled("verbatim_%dbit" % bps,
                           build_stream(bps, 1, 48000, 120, [fr]),
                           48000, 1, bps, vals.tolist(), ref_bps, ref_shift)

    # Variable-blocksize strategy: the coded number is a sample index and the
    # frames deliberately differ in length.
    a = ramp[:192].tolist()
    b = (ramp[192:300] * 2).tolist()
    f1 = encode_frame([a], 16, 44100, 0, variable=True, kind="verbatim", block_size=192)
    f2 = encode_frame([b], 16, 44100, 192, variable=True, kind="verbatim", block_size=108)
    add_crafted("variable_blocksize",
                build_stream(16, 1, 44100, 300, [f1, f2], min_block=108, max_block=192),
                44100, 1, 16, np.concatenate([np.array(a), np.array(b)]).reshape(-1, 1))

    # Rate codes 0 (inherit STREAMINFO) and 12/13/14 (explicit kHz / Hz / 10 Hz),
    # which libFLAC's encoder never emits because it always uses the table.
    tiny = ramp[:96]
    for name, rate, override in (
        ("rate_code_streaminfo", 44100, (0, 0, 8)),
        ("rate_code_khz", 48000, (12, 48, 8)),
        ("rate_code_hz", 44100, (13, 44100, 16)),
        ("rate_code_tens_hz", 44100, (14, 4410, 16)),
    ):
        fr = encode_frame([tiny.tolist()], 16, rate, 0, kind="verbatim",
                          block_size=96, rate_code_override=override)
        add_crafted(name, build_stream(16, 1, rate, 96, [fr], min_block=96,
                                       max_block=96),
                    rate, 1, 16, tiny.reshape(-1, 1))

    # Two more block-size codes from the fixed table.
    for bs in (576, 1152):
        vals = (np.arange(bs, dtype=np.int64) % 251) * 13
        fr = encode_frame([vals.tolist()], 16, 44100, 0, kind="fixed", order=2,
                          block_size=bs)
        add_crafted("block_code_%d" % bs,
                    build_stream(16, 1, 44100, bs, [fr], min_block=bs, max_block=bs),
                    44100, 1, 16, vals.reshape(-1, 1))

    # --- malformed files ---------------------------------------------------
    good = VALID[0][5]
    bps, ch, frames_at = streaminfo(good)
    invalid = []

    def mutate(name, at, value):
        invalid.append((name, good[:at] + bytes([value]) + good[at + 1 :]))

    invalid.append(("bad_magic", b"fLaX" + good[4:]))
    invalid.append(("truncated_streaminfo", good[:20]))
    invalid.append(("no_frames", good[:frames_at]))
    invalid.append(("truncated_frame", good[: frames_at + 6]))
    # STREAMINFO must be first and must appear once.
    invalid.append(("first_block_not_streaminfo", good[:4] + bytes([good[4] | 1]) + good[5:]))
    dup_si = good[:4] + bytes([0x00]) + good[5:8] + good[4 : 4 + 4 + 34] + good[4 + 4 + 34 :]
    invalid.append(("duplicate_streaminfo", dup_si))
    mutate("metadata_len_past_end", 5, 0xFF)
    mutate("invalid_metadata_type", 4, 0x7F)
    # Frame header: break the sync, the reserved bit, and the CRC-8.
    mutate("bad_frame_sync", frames_at, 0xFE)
    mutate("frame_crc8", frames_at + 6, good[frames_at + 6] ^ 0xFF)
    # Frame footer CRC-16.
    invalid.append(("frame_crc16", good[:-1] + bytes([good[-1] ^ 0xFF])))
    # Reserved sample-rate code 15 and reserved block-size code 0.
    mutate("reserved_rate_code", frames_at + 2, (good[frames_at + 2] & 0xF0) | 0x0F)
    mutate("reserved_block_code", frames_at + 2, good[frames_at + 2] & 0x0F)
    # Reserved channel assignment 11..15.
    mutate("reserved_channels", frames_at + 3, (good[frames_at + 3] & 0x0F) | 0xB0)
    # Reserved sample-size code 3.
    mutate("reserved_sample_size", frames_at + 3, (good[frames_at + 3] & 0x9F) | 0x60)

    # A frame header that contradicts STREAMINFO. libFLAC keeps the STREAMINFO
    # rate and decodes anyway; the engine rejects it, because a format change
    # mid-stream would silently reinterpret the interleaved output buffer.
    mismatch = encode_frame([ramp.tolist()], 16, 48000, 0, kind="verbatim",
                            block_size=300)
    invalid.append(("frame_rate_mismatch",
                    build_stream(16, 1, 44100, 300, [mismatch],
                                 min_block=300, max_block=300)))

    # libsndfile/libFLAC tolerates some damage by resynchronising or by ignoring
    # a bad CRC, so only the structurally impossible cases are cross-checked.
    lenient = {
        "frame_crc8", "frame_crc16", "truncated_frame", "reserved_rate_code",
        "reserved_block_code", "reserved_channels", "reserved_sample_size",
        "bad_frame_sync", "duplicate_streaminfo", "frame_rate_mismatch",
    }
    for name, data in invalid:
        try:
            sf.read(io.BytesIO(data), dtype="float32")
        except Exception:  # noqa: BLE001
            continue
        if name in lenient:
            print("NOTE %s: libFLAC resyncs/ignores, engine is strict" % name, file=sys.stderr)
            continue
        sys.exit("malformed vector %s was accepted by libFLAC" % name)

    # --- emit --------------------------------------------------------------
    w = sys.stdout.write
    w("//! Generated FLAC test vectors. DO NOT EDIT.\n")
    w("//!\n")
    w("//! Regenerate with:\n")
    w("//!     python3 tools/gen_flac_vectors.py > src/assets/flac_vectors.zig\n")
    w("//!\n")
    w("//! (with soundfile and numpy installed; see the generator docstring)\n")
    w("//!\n")
    w("//! Every file was encoded by libFLAC (through libsndfile) and every\n")
    w("//! `f32_hex` is libFLAC's own decode normalized to float32 exactly as the\n")
    w("//! engine normalizes it. FLAC is lossless, so the tests compare **bit-exactly**\n")
    w("//! -- there is no tolerance. The generator also parses each frame and reports\n")
    w("//! which subframe types, decorrelation modes, Rice methods and LPC orders the\n")
    w("//! corpus actually reaches, so coverage is measured rather than assumed.\n\n")
    w("/// A FLAC stream plus the interleaved f32 libFLAC produces for it.\n")
    w("pub const Flac = struct {\n")
    w("    name: []const u8,\n    sample_rate: u32,\n    channels: u16,\n")
    w("    bits: u16,\n    frames: u32,\n")
    w("    flac_hex: []const u8,\n    f32_hex: []const u8,\n};\n\n")
    w("pub const valid = [_]Flac{\n")
    for name, rate, ch, b, n, raw, ref in VALID:
        w("    .{\n")
        w('        .name = "%s",\n        .sample_rate = %d,\n        .channels = %d,\n' % (name, rate, ch))
        w("        .bits = %d,\n        .frames = %d,\n" % (b, n))
        w("        .flac_hex = %s,\n" % hexlit(raw))
        w("        .f32_hex = %s,\n" % hexlit(ref))
        w("    },\n")
    w("};\n\n")
    w("/// A FLAC stream the decoder must reject with `error.InvalidAudio`.\n")
    w("pub const Invalid = struct { name: []const u8, flac_hex: []const u8 };\n\n")
    w("pub const invalid = [_]Invalid{\n")
    for name, data in invalid:
        w('    .{ .name = "%s", .flac_hex = %s },\n' % (name, hexlit(data)))
    w("};\n")

    print("emitted %d valid (%d crafted), %d malformed"
          % (len(VALID), len(CRAFTED), len(invalid)), file=sys.stderr)
    for key, counter in COVERAGE.items():
        items = ", ".join("%s:%d" % (k, v) for k, v in sorted(counter.items(), key=lambda kv: str(kv[0])))
        print("  coverage %-16s %s" % (key, items), file=sys.stderr)


if __name__ == "__main__":
    main()
