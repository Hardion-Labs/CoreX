# FLAC Decoding and the CXAW Artifact — CoreXEngine

This document describes CoreXEngine's **FLAC** (Free Lossless Audio Codec)
decoder. The code lives in `src/assets/flac.zig` and is exposed as
`corex.assets.flac`. It produces the *same* `Audio` type and the *same* **`CXAW`**
artifact as the WAV importer, so nothing downstream — cache, change detection,
snapshot keys, mixer — needs to know which container a clip came from.

> Status: **implemented and tested**, bit-exactly against libFLAC. The supported
> subset is the whole baseline format: every subframe type, every legal
> block-size and sample-rate code, all four channel layouts, both residual
> coding methods and sample sizes from 4 to 32 bits. **Lossy compressed audio
> (MP3, Ogg/Vorbis, Opus, AAC) and other containers (AIFF, CAF, RF64) still have
> no decoder** and fall back to `raw`; they are not described here as an existing
> capability. There is **no audio playback device yet** — the device-independent
> mixer that consumes these artifacts is implemented
> (see [audio-mixer.md](audio-mixer.md)).

## Overview

```
.flac source ──► decode ──► Audio (interleaved f32 + rate + channels + frames)
                        ──► serialize ──► CXAW artifact ──► content-addressed cache
                                                       ──► parse (zero-copy view) ──► mixer
```

The importer is a pure `bytes -> bytes` transformation with its own identity
(`id = "flac"`, `version = 1`), bound to the `.flac` extension. The version
participates in the cache key, so a future layout change invalidates the affected
entries automatically.

Because FLAC is **lossless**, the contract is stronger than the JPEG one: the
decoded samples must equal the reference **bit for bit**, with no tolerance to
tune. A FLAC and a WAV carrying the same PCM produce byte-identical artifacts.

## Module boundaries

`flac.zig` imports `audio.zig` in **one direction only**, for the shared `Audio`
type, `DecodeError`, the engine limits and the `CXAW` serializer. `audio.zig`
does **not** import `flac.zig`; the engine registry in `src/assets.zig` composes
`audio.bindings ++ flac.bindings`. This is the same arrangement as
`png.zig` → `image.zig`, and it avoids an import cycle between the container
decoders and the shared artifact contract.

The only change to `audio.zig` in this stage was making `mapDecodeError` public so
both decoders map `InvalidAudio`/`OutOfMemory` to the registry's
`InvalidAsset`/`OutOfMemory` through one function instead of two copies.

## Supported subset

| Feature | Supported |
|---|---|
| Metadata | `STREAMINFO` (required, first, exactly once); `PADDING`, `APPLICATION`, `SEEKTABLE`, `VORBIS_COMMENT`, `CUESHEET`, `PICTURE` skipped |
| Blocking strategy | Fixed and variable block size |
| Block size | Every legal code, including the 8-bit and 16-bit explicit forms |
| Sample rate | Every table code, code 0 (inherit `STREAMINFO`), and the explicit kHz / Hz / 10 Hz forms |
| Channels | 1..8 independent; left/side, right/side and mid/side stereo |
| Subframes | `CONSTANT`, `VERBATIM`, `FIXED` orders 0..4, `LPC` orders 1..32 |
| Wasted bits | Unary-coded `k-1` flag on any subframe |
| Residual | Rice method 0 (4-bit parameters) and method 1 (5-bit), any partition order, escaped raw partitions |
| Sample size | 4..32 bits |
| Integrity | Header CRC-8 (poly `0x07`) and frame CRC-16 (poly `0x8005`), both non-reflected with zero init |
| Coded numbers | UTF-8 frame/sample numbers up to the format's 36 bits, canonical shortest form only |

### Normalization

Identical to the WAV path (see [asset-audio.md](asset-audio.md)): a sample is
divided by `2^(bits-1)`, so full scale maps to `[-1, 1)`. There is **no
resampling, downmixing or channel reordering**. After decorrelation, channel 0 is
left and channel 1 is right, matching the source order.

### What is rejected

Rejected with `error.InvalidAudio` (surfacing as `InvalidAsset` through the
importer), never approximated:

- A bad magic, a missing/duplicate/misplaced `STREAMINFO`, a metadata length past
  the end, or the invalid metadata type 127.
- A bad frame sync, a set reserved bit, reserved block-size code 0, sample-rate
  code 15, sample-size code 3, or channel assignment 11..15.
- A frame whose channel count, sample rate or sample size **contradicts
  `STREAMINFO`**. libFLAC tolerates a rate mismatch by keeping the `STREAMINFO`
  value and decoding anyway; the engine refuses it, because a format change
  mid-stream would silently reinterpret the interleaved output buffer.
- A reserved subframe type, LPC precision code 15, a negative LPC shift, an
  order larger than the block, or a wasted-bit count that consumes the whole
  sample width.
- A partition order that does not divide the block size, a residual method other
  than 0/1, or a Rice quotient larger than any legal residual magnitude.
- An over-long or malformed UTF-8 coded number, a frame index that does not
  advance exactly, or a blocking strategy that changes mid-stream.
- A truncated frame, a CRC-8 or CRC-16 mismatch, or a decoded frame count that
  disagrees with the declared total.

`STREAMINFO`'s total sample count is authoritative: decoding stops at the last
declared frame, so trailing bytes are ignored rather than parsed as audio.

## Implementation notes

**Memory safety.** Every field is read through a bounds-checked bit reader over
the frame's own slice, so a malformed frame cannot read past it. Running out of
bits is `InvalidAudio`, never an out-of-bounds access. The test suite decodes
*every proper prefix* of a valid stream to prove no truncation can trap.

**Overflow safety by construction.** Sample storage is `i64`. That makes every
fixed predictor, every LPC accumulation and every decorrelation step
overflow-free without a per-bit-depth argument — including the `mid * 2` step at
32 bits, which would overflow a 40-bit accumulator.

**Frame boundaries are proved, not guessed.** FLAC frames are not
length-prefixed. The decoder decodes the subframes, and the bit reader's final
position locates the zero padding and the CRC-16; the CRC then proves the
boundary was right. It never scans for the next sync code, which would mis-frame
any payload that happens to contain one.

**Allocation.** One block buffer sized from `STREAMINFO` is allocated once and
reused for every frame. The residual is decoded directly into the sample slots it
will occupy, so there is no intermediate residual array and no per-frame
allocation. The output list is pre-sized from the declared total. Fixed
predictors are specialized at comptime per order, so the inner loop has no
per-sample branch on the order.

**Limits.** The engine's shared audio ceilings apply unchanged: 8 channels,
384 kHz, 256 MiB of decoded samples. The declared total is checked against the
byte ceiling *before* anything is allocated.

## Guarantees and tests

- **Bit-exact corpus**: `src/assets/flac_vectors.zig`, generated by
  `tools/gen_flac_vectors.py` (CI tests the committed vectors and never runs the
  generator). **72 valid streams**, each with libFLAC's own float32 decode as the
  reference. The test compares raw `f32` bytes, so even a sign-of-zero difference
  fails.
- **Malformed corpus**: **16 streams** that must be refused — bad magic,
  truncations, duplicate/misplaced `STREAMINFO`, broken sync, both broken CRCs,
  every reserved header code, and a frame that contradicts `STREAMINFO`. Where
  libFLAC resynchronises or ignores damage instead of failing, the generator
  records that explicitly rather than pretending the reference agrees.
- **Measured coverage, not assumed.** The generator parses every frame it emits
  and prints which features the corpus actually reaches. That report is what
  exposed the gaps below.
- **Crafted vectors for paths libFLAC's encoder never chooses.** 25 of the 72
  streams are built by hand and then **decoded back by libFLAC before being
  emitted**, so a construction mistake cannot survive. They cover mid/side
  decorrelation, Rice method 1, partition orders up to 5, escaped raw partitions,
  LPC orders 4/8/12/16/24/32, the maximum 15-bit coefficient precision with a
  non-zero shift, the variable-blocksize strategy, and rate codes 0/12/13/14.
- **Depths libsndfile cannot read.** It only exposes 8/16/24-bit FLAC, so the
  12/20/32-bit vectors are anchored to the same samples encoded at 16 or 24 bits
  and scaled by a power of two. FLAC normalizes by `2^(bits-1)`, so the float
  results are bit-identical and the reference still comes from libFLAC rather
  than from the generator.
- **Unit tests** for the CRC check values (`0xF4` / `0xFEE8` over `"123456789"`),
  UTF-8 round-trips across all seven widths plus over-long/truncated rejections,
  bit-reader bounds, signed sign-extension, bounded unary runs, all five fixed
  predictors, all three decorrelation modes, mono no-op decorrelation, 32-bit
  mid/side extremes, the wasted-bit `k-1` encoding, and the three header tables.
- **Allocation-failure probes** over `decode`, and an end-to-end
  pipeline → registry → `CXAW` → cache → snapshot-key → cache-hit test.

21 tests were added (20 in `flac.zig`, 1 in `assets.zig`), bringing the suite to
**556 tests**, green in Debug, ReleaseSafe and ReleaseFast.

## Performance

ReleaseFast, best of 10, 10 seconds of 44.1 kHz stereo 16-bit (441 000 frames,
882 000 samples; 106 694-byte FLAC vs 1 764 044-byte WAV of the same PCM):

| Path | Time | Throughput | Output bandwidth |
|---|---|---|---|
| FLAC decode | **7.14 ms** | 123.5 Msamples/s | 471 MiB/s |
| WAV decode (same PCM) | 1.17 ms | 754 Msamples/s | 2878 MiB/s |

FLAC costs about **6.1×** a WAV decode of the same PCM, which is the expected
shape: WAV is a bounds check plus a width conversion, while FLAC adds entropy
decoding and prediction. Import happens off the frame path, so this is a
cache-miss cost, not a per-frame cost.

A phase measurement (decoding digital silence of the same length, which libFLAC
encodes as `CONSTANT` subframes) puts the floor for float conversion and
interleaving at 1.67 ms — so **77% of the time is residual decoding and
prediction**, and 23% is the shared conversion step.

One optimization was tried and **rejected on measurement**: fusing the unary
quotient and the Rice remainder into a single 32-bit window. With a byte-assembly
loop it was *slower* (8.47 ms); with a single `readInt` load it reached parity
(7.12 ms). Parity does not justify an extra fallback path, so the simpler
two-call reader was kept.

## Limitations and next steps

- **No Ogg container.** This is bare FLAC (the `fLaC` stream signature). FLAC
  inside Ogg (`.oga`/`.ogg`) is not demuxed, and `.ogg` still imports as `raw`.
- **No MD5 verification.** `STREAMINFO`'s unencoded-audio MD5 is read past, not
  checked; the per-frame CRC-16 is what guards integrity today.
- **No seeking or partial decode.** The whole clip is decoded into memory,
  bounded by `max_sample_bytes`; `SEEKTABLE` is skipped. Streaming decode for very
  long files is future work.
- **No metadata surfaced.** Vorbis comments, cue sheets and embedded pictures are
  skipped, not exposed to the caller.
- **No resampling or downmixing**, exactly as for WAV.
- **Lossy codecs remain unimplemented**: MP3, Ogg/Vorbis, Opus and AAC have no
  decoder and are not claimed here.

## Related

- WAV importer and the `CXAW` contract: [asset-audio.md](asset-audio.md)
- Audio runtime / mixer: [audio-mixer.md](audio-mixer.md)
- Import and cache: [asset-import.md](asset-import.md)
- Change detection / incremental import: [asset-change-detection.md](asset-change-detection.md)
- Texture decoders / CXTX: [asset-decoders.md](asset-decoders.md)
- Mesh import / CXMH: [mesh-import.md](mesh-import.md)
- Versioning policy: [versioning.md](versioning.md)
- Architecture: [architecture.md](architecture.md)
