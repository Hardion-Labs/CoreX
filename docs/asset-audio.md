# Audio Import (WAV) and the CXAW Artifact — CoreXEngine

This document describes CoreXEngine's WAV importer: the decoder for the
uncompressed subset of **RIFF/WAVE** and the engine-ready **`CXAW`** artifact it
produces. The **FLAC** decoder lives in `src/assets/flac.zig` and produces the
same `Audio`/`CXAW` artifact — see [asset-flac.md](asset-flac.md). The code lives in `src/assets/audio.zig` and is exposed as
`corex.assets.audio` (with `corex.assets.Audio` / `corex.assets.AudioView`).

> Status: **implemented and tested**. This is the "audio" part of the asset
> decoders roadmap item. It consumes the same pipeline/cache as the other
> importers ([asset-import.md](asset-import.md)) and the same change-detection
> path ([asset-change-detection.md](asset-change-detection.md)). **Lossy and
> other compressed audio (ADPCM, A-law/µ-law, GSM, Ogg/Vorbis, MP3, Opus) and
> other containers (AIFF, CAF, RF64) have no decoder** and are rejected or fall
> back to `raw`; they are not described here as an existing capability. Lossless
> **FLAC is supported** as of this stage ([asset-flac.md](asset-flac.md)). There is **no
> audio playback device yet**. The device-independent **mixer** that consumes
> these artifacts is implemented — see [audio-mixer.md](audio-mixer.md) — while
> the OS device backends remain planned.

## Overview

```
.wav source ──► decodeWav ──► Audio (interleaved f32 + rate + channels + frames)
                          ──► serialize ──► CXAW artifact ──► content-addressed cache
                                                          ──► parse (zero-copy view) ──► mixer
```

The importer is a pure `bytes -> bytes` transformation with its own identity
(`id = "wav"`, `version = 1`). The version participates in the cache key, so
changing the layout and bumping the version invalidates the affected entries
automatically.

Float32 was chosen as the artifact sample format because it is what a mixer wants
(summing and gain without requantization), it makes every source width comparable
downstream, and it keeps one single layout instead of one artifact per bit depth.

## Supported WAV subset

Honest and documented — what is not supported is **rejected**, never approximated:

| `wFormatTag` | Meaning | Accepted widths |
| --- | --- | --- |
| `0x0001` | `WAVE_FORMAT_PCM` | 8 (unsigned), 16, 24, 32 (signed LE) |
| `0x0003` | `WAVE_FORMAT_IEEE_FLOAT` | 32 |
| `0xFFFE` | `WAVE_FORMAT_EXTENSIBLE` | PCM or IEEE-float subformat GUID |

Container rules:

- `RIFF` + size + `WAVE`; the RIFF size **must equal `file_length - 8`** (it covers
  the `WAVE` form type plus every chunk, including pad bytes).
- Exactly **one** `fmt ` chunk and **one** `data` chunk, and `fmt ` must appear
  **before** `data`. A `data` chunk without a preceding header is rejected.
- Every other chunk (`LIST`/`INFO`, `fact`, `cue `, `id3 `, `bext`, `JUNK`, ...) is
  **skipped**, not parsed. Unknown chunks never abort the import.
- Chunks are word-aligned: an odd-sized chunk is followed by one pad byte. A
  missing pad byte at **end of file** is tolerated (some writers omit it).
- `data` must be non-empty and a **whole number of frames**
  (`data.len % block_align == 0`); `block_align` must equal `channels * bits/8`.
- `WAVE_FORMAT_EXTENSIBLE` requires a 40-byte `fmt ` body, `cbSize >= 22`,
  `wValidBitsPerSample` of `0` (unspecified) or exactly `bits`, and a subformat
  GUID whose tail matches `KSDATAFORMAT_SUBTYPE_*`. The channel mask is read past:
  channel **order is preserved as stored**, not reordered to a canonical layout.
- Limits: **1..8 channels**, sample rate **1..384000 Hz**, decoded sample buffer
  up to **256 MiB** (`max_sample_bytes`), i.e. up to 67,108,864 mono frames.
  The derived byte rate in `fmt ` is ignored (it is redundant and often wrong).

## Normalization rules

The conversion is explicit and documented, not a silent guess:

| Source | Conversion | Full scale |
| --- | --- | --- |
| PCM 8-bit unsigned | `(byte - 128) / 128` | `[-1, 1)` |
| PCM 16-bit signed | `i16 / 32768` | `[-1, 1)` |
| PCM 24-bit signed | sign-extended from 3 bytes, `/ 8388608` | `[-1, 1)` |
| PCM 32-bit signed | `i32 / 2147483648` | `[-1, 1)` |
| IEEE float 32 | **pass-through, unchanged** | unclamped |

- Dividing by `2^(bits-1)` (not `2^(bits-1)-1`) maps the most negative sample to
  exactly `-1.0` and keeps the scale symmetric; the most positive sample lands at
  `1 - 2^-(bits-1)`. This is the standard full-scale convention.
- **Float headroom is preserved**: `1.5` and `-2.0` stay `1.5` and `-2.0`. Clamping
  a float source would destroy information the mixer may want.
- **Non-finite samples (NaN/±Infinity) are rejected** at decode time, so an
  artifact can never carry a NaN into the mix.
- **No resampling, no downmixing, no channel reordering, no dithering.** The
  artifact keeps the source sample rate, channel count and channel order.

## The `CXAW` artifact

Little-endian layout, 20-byte header:

| Offset | Field | Type |
| --- | --- | --- |
| 0..4 | magic `"CXAW"` | 4 bytes |
| 4..8 | `format_version` (= 1) | u32 |
| 8..12 | `sample_rate` (Hz) | u32 |
| 12..14 | `channels` | u16 |
| 14..16 | `sample_format` (= 0, `f32_interleaved`) | u16 |
| 16..20 | `frame_count` | u32 |
| 20.. | `frame_count * channels` interleaved f32 samples | bytes |

A frame is one sample per channel; sample `i` belongs to frame `i / channels` and
channel `i % channels`. Total size is exactly `20 + frame_count * channels * 4`.
`sample_format` is an enum tag so planar or compressed layouts can be added later
**without** reinterpreting old artifacts: a reader that does not know the tag
rejects the file instead of misreading it.

## API

- `decodeWav(gpa, source) DecodeError!Audio` — decodes a WAV into interleaved f32.
- `Audio { sample_rate, channels, frames, samples: []f32 }` — an owned clip;
  `deinit(gpa)` frees it; `sampleCount()`, `durationSeconds()`.
- `serialize(gpa, clip) ImportError![]u8` — validates and writes the `CXAW`
  artifact.
- `parse(bytes) error{InvalidAsset}!AudioView` — a **zero-copy**, alignment-safe
  view: linear validation of magic/version/format/dimensions/exact length plus
  float finiteness; the `sampleAt(i)` / `frameAt(frame, channel)` accessors read
  little-endian fields explicitly (no pointer casts, so unaligned buffers work).
- `AudioView { sample_rate, channels, frames, sample_format, sample_bytes }` —
  borrows the artifact bytes; `sampleCount()`, `durationSeconds()`.
- `importWav(gpa, source) ImportError![]u8` — `decodeWav` + `serialize`.
- `wav_importer` (`id="wav"`, `version=1`) and `bindings` (`.wav`).
- `DecodeError = error{ InvalidAudio, OutOfMemory }`; the importer maps
  `InvalidAudio` to the pipeline's `InvalidAsset`.

Limits: `max_channels = 8`, `max_sample_rate = 384000`,
`max_sample_bytes = 256 MiB`, `max_frames = 67,108,864`.

## Pipeline integration

`assets.engineRegistry()` now includes the audio bindings (`.wav`), so the pipeline
imports `.wav` into `CXAW` automatically, with cache, incremental re-import and GC
like any other asset. `.wav` is already classified as `AssetKind.audio` by the
index — no change to the startup contract or to `AssetEntry` was needed.

```zig
const corex = @import("corex");
const A = corex.assets;
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "wav", kind == .audio
const artifact = (try cache.get(gpa, key)).?;
defer gpa.free(artifact);
const view = try A.audio.parse(artifact);
// view.sample_rate, view.channels, view.frames, view.durationSeconds()
// view.frameAt(frame, channel) -> f32 in [-1, 1] (or beyond, for float sources)
```

Because the artifact is content-addressed like every other asset, a `.wav` edit is
picked up by `changes.detect` and re-imported through `Options.only`; the snapshot's
`cacheKeys` includes the WAV key, so GC keeps it (covered by a test).

## Guarantees and tests

The decoder is checked against **38 independently generated fixtures**
(`src/assets/audio_vectors.zig`, produced by `tools/gen_wav_vectors.py` with
Python's `struct`, not by the Zig decoder): **15 valid** WAVs with their expected
f32 output, and **23 malformed/unsupported** ones.

- **Bit-exact decoding**: every valid vector's samples are compared as **u32 bit
  patterns** against the reference, so rounding differences and `-0.0` cannot
  hide. Coverage: PCM 8/16/24/32, float32 mono/stereo, `WAVE_FORMAT_EXTENSIBLE`
  PCM16 and float32 6-channel, odd-sized `data` with and without the final pad
  byte, extra ancillary chunks, a single frame, and 192 kHz.
- **Rejection**: bad RIFF magic, not-`WAVE`, truncated header, empty file, missing
  `fmt `, missing `data`, duplicate `fmt `, ADPCM, µ-law, unsupported bit depth,
  zero/too-many channels, zero/oversized sample rate, empty `data`, non-block-
  aligned `data`, truncated `data`, wrong RIFF size, bad extensible GUID, short
  `cbSize`, NaN and Infinity samples, `data` before `fmt `.
- **Artifact**: serialize/parse roundtrip preserving rate/channels/frames and
  every sample bit; rejection of bad magic/version/sample format/dimensions/length,
  truncation and a crafted NaN payload; `serialize` rejects inconsistent clips
  (`samples.len != frames * channels`, zero frames/rate, too many channels) and
  non-finite samples.
- **Alignment safety**: the artifact is parsed at an **odd byte offset** and every
  `frameAt` accessor is checked against the decoded clip.
- **Registry**: `.wav`/`.WAV` select `wav` v1; `.ogg`/`.mp3` still select `raw`.
- **Pipeline**: an end-to-end `.wav` → `CXAW` → cache → `parse` test, a cache hit on
  the second run, and key parity with `changes.Snapshot.cacheKeys`.
- **Memory safety**: `checkAllAllocationFailures` on decode/serialize/import with
  no leaks and no swallowed `OutOfMemory`.

## Performance

Measured on this machine, `ReleaseFast`, best of 5 runs, 10 s of 48 kHz stereo
16-bit PCM (1.875 MiB source, 480,000 frames):

| Step | Time |
| --- | --- |
| `decodeWav` (parse + normalize 960,000 samples) | **1.29 ms** |
| `serialize` (validate + write `CXAW`) | **1.32 ms** |

- The container is parsed in **one pass** with no allocation; only the sample
  buffer is allocated, sized exactly once from `data.len`.
- Sample conversion is monomorphized per bit width at comptime (`inline 8, 16, 24,
  32`), so the hot loop has no per-sample branch on the format and vectorizes.
- `parse` makes one linear validation pass (finiteness) so the consumer never has
  to check for NaN, and returns a view — no copy of the sample data.
- Import happens off the frame path (pipeline/job system), so decode cost is a
  cache-miss cost, not a per-frame cost.

## Limitations and next steps

- **Uncompressed WAV only in this module.** ADPCM, A-law/µ-law, GSM and every
  other codec inside a RIFF container are rejected, and 64-bit float is rejected.
  FLAC is handled by the sibling decoder ([asset-flac.md](asset-flac.md));
  Ogg/MP3/Opus/AIFF have no decoder and use the `raw` importer (verbatim copy).
- **No resampling, downmixing or channel reordering** — a consumer that needs
  48 kHz stereo must handle the source rate/layout itself for now.
- **No device playback**: the voice/bus mixer that consumes `CXAW` is implemented
  (`corex.audio`, see [audio-mixer.md](audio-mixer.md)), but there is no OS audio
  device backend, streaming of long clips or 3D attenuation yet.
- **No loop points**: `smpl`/`cue ` chunks are skipped, so loop markers are not
  carried into the artifact yet.
- The whole clip is decoded into memory (bounded by `max_sample_bytes`); streaming
  decode for very long files is future work.
- The artifact is always f32; a 16-bit or compressed artifact variant for
  memory-constrained targets is not implemented.

## Related

- FLAC decoder (same `CXAW` artifact): [asset-flac.md](asset-flac.md)
- Audio runtime / mixer: [audio-mixer.md](audio-mixer.md)
- Import and cache: [asset-import.md](asset-import.md)
- Change detection / incremental import: [asset-change-detection.md](asset-change-detection.md)
- Texture decoders / CXTX: [asset-decoders.md](asset-decoders.md)
- Mesh import / CXMH: [mesh-import.md](mesh-import.md)
- Versioning policy: [versioning.md](versioning.md)
- Architecture: [architecture.md](architecture.md)
