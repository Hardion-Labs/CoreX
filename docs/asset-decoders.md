# Image Decoders and the CXTX Artifact — CoreXEngine

This document describes CoreXEngine's image decoders and the engine-ready texture
artifact (`CXTX`). The code lives in `src/assets/image.zig` (BMP/TGA/QOI),
`src/assets/png.zig` (PNG) and `src/assets/inflate.zig` (DEFLATE/zlib), plus
`src/assets/texture.zig` (artifact + importers). They are exposed as
`corex.assets.image`, `corex.assets.png`, `corex.assets.inflate` and
`corex.assets.texture` (types `corex.assets.Image` and `corex.assets.Texture`).

> Status: **implemented and tested** for **PNG, JPEG, BMP, TGA and QOI**.
> Fonts still have no decoder and continue to be imported as `raw` (verbatim
> copy). Other model formats also fall back to `raw`; the OBJ mesh importer does
> exist (see [mesh-import.md](mesh-import.md)), as do the WAV and FLAC audio
> importers (see [asset-audio.md](asset-audio.md) and
> [asset-flac.md](asset-flac.md)). This is documented as a limitation, not as an
> existing capability.

## Overview

The import pipeline selects an importer by extension. For textures, the importer
**decodes** the source into **RGBA8** (8 bits per channel, row-major, top-down)
and **serializes** it into a self-describing `CXTX` container, which is the
derived artifact stored in the content-addressed cache. The renderer will be able
to upload the pixels directly without re-parsing the source format.

```
source (.png/.bmp/.tga/.qoi) → decode → RGBA8 Image → serialize → CXTX → cache
```

## Supported formats

| Format | Extension | Modes | Depth | Notes |
|---|---|---|---|---|
| PNG | `.png` | Grayscale, truecolor, indexed, grayscale+alpha, truecolor+alpha; non-interlaced and Adam7 | 1, 2, 4, 8, 16 bit | All five row filters; `tRNS` (palette alpha and color keys); multiple IDAT chunks; Adam7 interlacing; chunk CRC-32 and zlib Adler-32 verified. |
| JPEG | `.jpg`, `.jpeg` | Sequential Huffman (`SOF0`/`SOF1`), 8-bit; grayscale and YCbCr | 8 bit | 4:4:4, 4:4:0, 4:2:2, 4:2:0, 4:1:1 and any legal 1..4 sampling factors; restart markers; 8/16-bit quant tables; arbitrary Huffman tables; libjpeg-exact colour conversion and chroma upsampling. |
| BMP | `.bmp` | `BI_RGB` (uncompressed) | 24, 32 bpp | Bottom-up and top-down; row padding at 24 bpp; BGR→RGB; alpha from the 4th byte at 32 bpp. |
| TGA | `.tga` | Uncompressed true-color (type 2) and RLE (type 10) | 24, 32 bpp | Descriptor bit 5 selects top-down; BGR(A)→RGBA(A). |
| QOI | `.qoi` | Decode **and** encode | 3/4 channels | Quite OK Image; encode enables lossless roundtrips and a future export path. |

Honest rejections (`InvalidImage`/`InvalidAsset` errors, no out-of-bounds access):
compressed BMP or bpp other than 24/32; color-mapped or grayscale TGA, or RLE that
exceeds the pixel count; QOI with invalid magic/channels, truncated or missing the
end marker; zero dimensions or dimensions above `max_dimension`; a pixel buffer
above `max_pixel_bytes`. PNG-specific rejections are listed below.

## PNG

### What is supported

- **Color types**: grayscale (0), truecolor (2), indexed (3), grayscale+alpha (4),
  truecolor+alpha (6).
- **Bit depths**: 1/2/4/8 for grayscale and indexed, 8/16 for the other types —
  exactly the combinations the specification allows. Invalid combinations are
  rejected.
- **Filters**: None, Sub, Up, Average and Paeth, chosen per row, reconstructed in
  place.
- **Transparency (`tRNS`)**: per-entry palette alpha, grayscale color key and RGB
  color key. Color keys are compared at the **source** bit depth, so a 16-bit key
  matches exactly.
- **Chunks**: any number of consecutive IDAT chunks (a single chunk is inflated
  without copying), `PLTE`, `tRNS`, `IEND`; unknown **ancillary** chunks are
  skipped, unknown **critical** chunks are rejected. Every chunk's CRC-32 is
  verified, as is the zlib Adler-32 of the inflated data.

### Adam7 interlacing

An interlaced PNG stores the image as seven progressively finer passes rather
than one run of top-to-bottom rows. Each pass is a **separate sub-image**: it has
its own width, its own row padding, and its own filter history.

| Pass | x start | y start | x step | y step |
| --- | --- | --- | --- | --- |
| 1 | 0 | 0 | 8 | 8 |
| 2 | 4 | 0 | 8 | 8 |
| 3 | 0 | 4 | 4 | 8 |
| 4 | 2 | 0 | 4 | 4 |
| 5 | 0 | 2 | 2 | 4 |
| 6 | 1 | 0 | 2 | 2 |
| 7 | 0 | 1 | 1 | 2 |

The decoder handles the details that make this easy to get wrong:

- **Empty passes carry no bytes.** A pass whose starting offset is already past
  the image contributes nothing at all — not even a filter byte. A 1×1 image is
  one pass of one row; an 8×8 image uses all seven. The inflated size predicted
  from `IHDR` is the sum over the non-empty passes, and it must match exactly.
- **Filter state resets per pass.** Up, Average and Paeth all read the previous
  row, and "previous" means the previous row *of that pass*, starting from zeros.
  Carrying state across a pass boundary corrupts everything after it.
- **Row padding is per pass.** Sub-byte depths pad each pass row to a byte
  boundary independently, so the passes do not share a stride.

Implementation notes: the existing unfilter and comptime-specialized pixel
converter are reused unchanged — a pass is handed to them as a `Header` with its
own dimensions, and each pass row as a one-row header. Only **one scratch row**
(`width * 4` bytes) is allocated and reused across every pass; the final pass has
an x-step of 1, so it converts straight into the output row and skips the copy
altogether. That pass carries half the image. The non-interlaced path is
untouched.

### Normalization to RGBA8 (documented, not silent)

- **16-bit samples** are reduced to 8 bits by taking the **high byte**, because
  `CXTX` is RGBA8. No dithering or gamma conversion is applied.
- **Sub-byte grayscale** samples (1/2/4 bit) are scaled to the full 0..255 range by
  bit replication, so a 1-bit white pixel becomes 255, not 1.
- **Indexed** pixels are expanded through the palette; missing `tRNS` entries are
  opaque (255).
- **Grayscale** is replicated into R, G and B.

### What is rejected

- Zero or oversized dimensions, invalid bit-depth/color-type combinations, a
  missing/duplicate/late `PLTE`, a palette index outside the palette, `tRNS` on a
  format that already has alpha, non-consecutive IDAT chunks, a missing IDAT or
  IEND, trailing bytes after IEND, a bad chunk CRC, a bad zlib header, a preset
  dictionary, a corrupt/truncated deflate stream, an unknown row filter, and an
  inflated size that differs from the size implied by `IHDR`.

### DEFLATE / zlib (`corex.assets.inflate`)

PNG needed a dependency-free inflater, so `inflate.zig` implements the complete
DEFLATE format (RFC 1951) and the zlib wrapper (RFC 1950):

- Stored, fixed-Huffman and dynamic-Huffman blocks; multi-block streams;
  length/distance back-references with overlapping copies.
- Canonical Huffman tables decoded through a **flat lookup table** (O(1) per
  symbol), rebuilt in place per block and reused across blocks.
- Over-subscribed and incomplete code spaces are rejected (except the single-code
  distance tree zlib emits); illegal symbols, reserved block type 3 and
  back-references before the start of output are rejected.
- `adler32` is exposed and verified against the RFC reference values.

```zig
const I = corex.assets.inflate;

// Raw DEFLATE (no wrapper):
const raw = try I.inflate(gpa, deflate_bytes, 1 << 20);
defer gpa.free(raw);

// zlib stream: header + Adler-32 verified.
const data = try I.zlibInflate(gpa, zlib_bytes, 1 << 20);
defer gpa.free(data);
```

The third argument is a hard bound: the decoder never produces more than
`max_output_bytes` (length **and** capacity), returning `error.OutputTooLarge`
instead of growing without limit. PNG passes the exact scanline size implied by
`IHDR`, so a decompression bomb cannot exceed the image's own declared size.

## JPEG

### What is supported

- **Coding process**: sequential DCT with Huffman coding — `SOF0` (baseline) and
  `SOF1` (extended sequential). They share one entropy-coded structure, so both
  decode through the same path.
- **Precision**: 8 bits per sample.
- **Components**: grayscale (1) and YCbCr (3). Single-component scans are
  non-interleaved, one block per MCU, as the specification requires.
- **Sampling**: any legal factors in 1..4 whose h·v sums to at most 10, which
  covers 4:4:4, 4:4:0, 4:2:2, 4:2:0 and 4:1:1. Factors must divide the frame
  maximum, or the file is rejected.
- **Tables**: 8-bit and 16-bit quantization tables, arbitrary Huffman tables
  (standard or optimized), up to four of each class.
- **Restart markers**: `DRI` plus `RSTn` at the declared interval. DC predictors
  and the bit buffer reset at every interval, and a missing or out-of-sequence
  marker is an error rather than a silently smeared image.
- **Segments**: any number of `APPn`/`COM` and other payload-bearing ancillary
  markers, including the Adobe and EXIF wrappers real cameras emit.

### Fidelity, and why it is not bit-exact

JPEG does not normatively specify the inverse DCT, so two conforming decoders may
legitimately differ by a sample value. Everything *around* the IDCT here is
reproduced exactly from libjpeg:

- **Colour conversion** uses libjpeg's fixed-point constants (91881, 22554,
  46802, 116130 with a 16-bit scale), so YCbCr→RGB is bit-identical.
- **Chroma upsampling** reproduces libjpeg's "fancy" triangle filters, including
  the details that are easy to get wrong: the upper output row of a 2× vertical
  pair blends with the row *above* and the lower with the row *below*; the fused
  2×2 filter rounds left taps with +8 and right taps with +7; and the fancy
  horizontal path is only taken when the component row is wider than two samples,
  below which libjpeg replicates.
- **The IDCT** is a full-precision separable transform, where libjpeg uses a
  13-bit fixed-point one. This is the only source of divergence.

Measured over the 36-vector corpus, the worst channel differs by **3** levels
(at quality 10, where coarse quantization amplifies the difference) and the worst
per-image mean error is **0.199**. The suite pins a ceiling of 4 on the worst
channel (one level of headroom for floating-point contraction differing between
optimization modes) and 0.25 on the mean. The mean bound is the one that matters:
a structurally wrong filter shifts it by whole levels, not fractions.

### What is rejected

Progressive (`SOF2`), lossless (`SOF3`), hierarchical, arithmetic-coded
(`SOF9`/`SOF10`/`SOF11`) and 12-bit frames, and 4-component CMYK/YCCK files. Also
rejected: over-subscribed Huffman code spaces, a zero quantizer, out-of-range
table indices, duplicate component ids, non-baseline spectral selection, a
truncated scan, and dimensions beyond the shared image limits. None of these are
approximated or partially decoded.

### Implementation notes

- **Bit reader**: pulls bytes only as far as the current symbol needs, never far
  ahead, so a restart marker can be found by discarding the padding bits of the
  current byte. `0xFF00` un-stuffs to `0xFF`, repeated `0xFF` are fill bytes, and
  any other marker stops the stream *without consuming it*. Running out of bytes
  with no marker is a truncated scan, not a grey fill.
- **Huffman**: codes up to 10 bits resolve with one lookup in a 1024-entry table;
  longer codes walk the canonical code space. The fast path matters less than it
  looks — the standard AC luminance table has 125 codes of length 16.
- **IDCT**: coefficient rows that are entirely zero are skipped in both passes,
  and a DC-only block becomes a constant fill with the 2D gain of 1/8. The two
  transform passes are 8-wide vector products against a comptime basis.
- **Conversion**: one output-resolution row per component is expanded into a
  single `3 * width` scratch allocation, then a branch-free loop converts to
  RGBA8. No per-pixel dispatch on the sampling ratio.

## The `CXTX` artifact

Little-endian layout, total size `20 + width*height*4`:

| Bytes | Field | Type |
|---|---|---|
| 0..4 | magic `"CXTX"` | 4 bytes |
| 4..8 | `format_version` (= 1) | u32 |
| 8..12 | `width` | u32 |
| 12..16 | `height` | u32 |
| 16..20 | `pixel_format` (0 = RGBA8) | u32 |
| 20.. | RGBA8 pixels (row-major, top-down) | `width*height*4` bytes |

`texture.parse` validates magic, version, pixel format, dimensions and the exact
size, returning a **zero-copy view** (`Texture`) over the artifact bytes (the
caller owns the bytes). `texture.serialize` produces the artifact from an
`Image`. The importer identity (`png`/`bmp`/`tga`/`qoi`, version 1) participates in
the cache key; changing the layout and bumping the version invalidates the
affected entries automatically.

## API

```zig
const A = corex.assets;

// Pure decoding (the caller frees Image.pixels with deinit):
var img = try A.image.decodeBmp(gpa, source); // or decodeTga / decodeQoi
defer img.deinit(gpa);

// PNG and JPEG live in their own modules and return the same Image type:
var png_img = try A.png.decode(gpa, png_source);
defer png_img.deinit(gpa);
var jpg_img = try A.jpeg.decode(gpa, jpg_source);
defer jpg_img.deinit(gpa);

// Lossless QOI encode (roundtrip / future export):
const qoi_bytes = try A.image.encodeQoi(gpa, img);
defer gpa.free(qoi_bytes);

// CXTX artifact:
const artifact = try A.texture.serialize(gpa, img);
defer gpa.free(artifact);
const tex = try A.texture.parse(artifact); // zero-copy view
// tex.width / tex.height / tex.pixel_format / tex.pixels

// Importers (source -> CXTX), already registered in engineRegistry:
const bytes = try A.texture.importPng(gpa, png_source); // importBmp / importTga / importQoi
defer gpa.free(bytes);
```

Public limits: `image.max_dimension = 16384`, `image.max_pixel_bytes = 256 MiB`
(aligned with the cache artifact ceiling), `png.max_raw_bytes = 2 * 256 MiB +
16384` (16-bit RGBA scanlines plus one filter byte per row). Every read is
bounds-checked and every allocation is bounded and checked against overflow.
Images whose RGBA8 output would exceed `max_pixel_bytes` are rejected **before**
inflating.

## Pipeline integration

`assets.engineRegistry()` registers `.png`/`.bmp`/`.tga`/`.qoi` → texture
importers, before the scene/JSON/text importers, with a `raw` fallback. All four
extensions were already classified as textures by the index
(`AssetKind.fromExtension`). The pipeline, cache and startup contracts remain
unchanged: the `CXTX` artifact is just another derived payload, stored and
verified like any other.

```zig
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "png", .kind == .texture, .key -> CXTX artifact
```

## Guarantees and tests

- **Reference vectors**: `src/assets/png_vectors.zig` is generated by
  `tools/gen_png_vectors.py` using Python's `zlib` — an encoder independent of the
  Zig decoder — and carries the expected RGBA8 output for every image. The suite
  covers all color types and bit depths, all five filters, palette/color-key
  transparency, 16-bit truncation, sub-byte scaling, multi-IDAT files, ancillary
  chunks, and stored/fixed/dynamic deflate blocks.
- **Rejection vectors**: 19 malformed PNGs (bad signature, CRC, Adler-32, zlib
  header, row filter, palette index, bit depth, color type, chunk order,
  truncation, trailing bytes, inflated-size mismatch) must all fail.
- **Adam7 vectors**: `src/assets/png_adam7_vectors.zig`, generated by
  `tools/gen_png_adam7_vectors.py` (the only generator that needs a third-party
  package — Pillow, for the libpng cross-check; CI does not run generators, it
  compiles the committed vectors). The generator scatters pixels into the seven
  passes itself, then **decodes every file back with libpng** (through Pillow)
  and refuses to emit it unless the result matches the expected RGBA8. A mistake
  in the pass table therefore cannot survive generation, and the Zig decoder is
  checked against files an independent implementation already confirmed. The 34
  vectors cover every color type and bit depth, palette and color-key
  transparency, sizes from 1×1 to 17×13 (so several passes are empty), odd
  dimensions that end mid-stride, per-pass filter rotation, single-filter files,
  multi-IDAT and stored-block files. One 16-bit grayscale vector is verified at
  native depth instead, because libpng reduces it to 8 bits differently than the
  documented high-byte rule.
- **Adam7 rejection vectors**: 5 malformed interlaced files (inflated size one
  byte short and one byte long, an illegal filter byte in a *later* pass, a
  half-finished zlib stream, and interlace method 2). Two of these are
  deliberately stricter than libpng, which ignores trailing inflated bytes and
  treats any non-zero interlace value as Adam7.
- **Adam7 geometry**: the seven pass areas must sum to exactly `width * height`
  for every size from 1×1 to 39×39, the 8×8 pass sizes are pinned against the
  specification table, and a 1×1 image must give six zero-byte passes.
- **Adam7 at scale**: a 257×259 image is stored as a matched pair, interlaced and
  plain. Both must decode to the documented formula and to each other, byte for
  byte, at a size where every pass ends mid-stride.
- **Adam7 allocation failures**: every allocation site in the interlaced path is
  exercised with `checkAllAllocationFailures`.
- **Inflate**: a 200 KiB multi-block dynamic-Huffman stream, fixed-Huffman and
  stored streams, crafted over-subscribed/illegal-code streams, truncation at
  several offsets, and the output bound for literals, matches and stored blocks.
- **JPEG vectors**: `src/assets/jpeg_vectors.zig`, generated by
  `tools/gen_jpeg_vectors.py` (needs Pillow, for libjpeg; CI compiles the
  committed vectors and does not run generators). Every JPEG is encoded by
  libjpeg and every reference is libjpeg's own decode, so the engine is compared
  against an independent implementation. The 36 vectors cover grayscale and all
  three subsamplings libjpeg can emit, sizes from 1×1 to 17×13 including
  non-block-aligned ones, quality 10/50/85/90/100, standard and optimized Huffman
  tables, restart intervals of 1/2/3/5 blocks, and flat/hard-edged/ramped content
  that exercises the DC-only and sparse IDCT paths. Each is checked against the
  tolerance documented above.
- **JPEG rejection vectors**: 19 malformed files (truncation at three points, bad
  quant/Huffman table ids and classes, a zero quantizer, over-subscribed Huffman
  counts, a sampling factor out of range, a duplicate component id, and a declared
  restart interval whose markers are absent) plus 7 unsupported ones (progressive,
  the `SOF3`/`SOF9`/`SOF11` coding processes, 12-bit precision and four
  components). The `progressive` vector is a
  genuinely valid progressive JPEG that libjpeg reads and the engine must refuse;
  the generator asserts that, so "unsupported" is proven to be a real format case
  rather than a corrupt file. Two rejection vectors are deliberately stricter
  than libjpeg, which clamps a zero quantizer and renders a truncated scan as far
  as it got.
- **JPEG paths the corpus cannot reach**: 4:4:0 is not something Pillow can emit,
  so `h1v2` upsampling is pinned directly against hand-computed libjpeg output,
  as are the 2×2 rounding biases, the two-sample replication fallback, odd-width
  expansion, the 1/8 DC gain, byte un-stuffing and fill bytes, marker stops,
  magnitude sign extension, Huffman over-subscription, and the colour-conversion
  clamp extremes.
- **JPEG allocation failures**: `checkAllAllocationFailures` over the decoder and
  the importer, including a colour image so a failure after one or two component
  planes have been allocated must unwind exactly those planes.
- **QOI roundtrip**: `encodeQoi` → `decodeQoi` preserves pixels exactly (a
  gradient with alpha and a case exercising RUN/INDEX/DIFF/LUMA/RGBA chunks).
- **Known fixtures**: 24 bpp bottom-up BMP with padding, 32 bpp top-down BMP with
  alpha, uncompressed and RLE TGA (run + literal), a known 1-pixel QOI.
- **Memory safety**: `checkAllAllocationFailures` probes on the decoders, the
  inflater, the PNG importer and serialize; no leaks on allocation failure.
- **End to end**: tests import a `.qoi` and a `.png` through the pipeline, read the
  artifact back from the cache via `key`, parse it and compare the pixels; a second
  run is a cache hit (no re-import).

## Performance

- Single-pass decoding, no recursion, writing directly into the pixel buffer
  (cache-friendly). QOI is a format designed for speed.
- PNG: Huffman symbols are decoded with one table lookup each; the bit reader
  refills whole bytes into a 64-bit accumulator; unfiltering is in place; the pixel
  conversion is specialized at comptime per (bit depth, channel count), so the
  inner loop has no per-pixel format branching. A single IDAT chunk is inflated
  with no copy. A 1024×1024 RGBA8 PNG (245 KB source, 4 MiB of scanlines) decodes in
  roughly 23 ms in `ReleaseFast` on the development container.
- Adam7 runs at **parity with the non-interlaced path**. On a 1024×1024 RGBA8
  pair built from the same source (23 KB plain, 30 KB interlaced, 4 MiB of
  scanlines each), best-of-12 in `ReleaseFast` measured 14.0 ms plain and 14.5 ms
  interlaced; a second run measured 15.8 ms and 15.6 ms. The scatter is a 4-byte
  copy per pixel against a full format conversion, and half the image skips it
  entirely, so it disappears into the inflate/unfilter cost. Both files decoded
  to byte-identical 4 MiB buffers. Absolute milliseconds are container-specific;
  only the ratio within a run is meaningful.
- JPEG: measured on a 1024×1024 image in `ReleaseFast`, best of 10 — **30.6 ms**
  at 4:4:4 and **20.5 ms** at 4:2:0, against **17.1 ms** for a lossless PNG of the
  same pixels. Splitting the 4:2:0 case into phases: entropy decode plus IDCT
  11.0 ms, upsampling plus colour conversion 4.8 ms, and the remainder is
  allocating and first-touching the buffers. Within the scan, Huffman decoding
  accounts for 7.6 ms and the IDCT only 3.4 ms, so the entropy reader is the
  bottleneck, not the transform. Marking the bit-reader helpers `inline` was
  measured and **rejected**: it made the scan slower (8.1 ms vs 7.6 ms for the
  entropy phase) through register pressure. A wider bit accumulator is the
  obvious next win but needs source-position tracking to keep restart markers
  locatable through `0xFF00` stuffing, so it is left as future work rather than
  risked here.
- JPEG memory: one plane per component at MCU-padded size, plus the RGBA8 output.
  For 1024×1024 4:2:0 that is 1536 KiB of planes against 4096 KiB of output. The
  planes are bounded by `max_plane_bytes` (= `image.max_pixel_bytes`) and checked
  with overflow-guarded arithmetic *before* any allocation, so a hostile header
  cannot make the decoder allocate one huge plane before rejecting the next. For
  the densest accepted layout (4:4:4) the planes need 3 bytes per pixel against
  the output's 4, so the bound never rejects an image whose output would fit.
- `encodeQoi` pre-reserves the maximum capacity (`14 + w*h*5 + 8`) and uses
  `appendAssumeCapacity`, avoiding reallocations during encoding.
- The `CXTX` artifact is self-describing: the renderer does not re-parse the
  source.

## Limitations and next steps

- No APNG animation and no 16-bit output artifact
  (`CXTX` is RGBA8, so 16-bit sources lose their low byte).
- No progressive, arithmetic-coded, lossless or 12-bit JPEG, and no CMYK/YCCK;
  those are rejected, never "guessed". No EXIF orientation is applied and no ICC
  profile is honoured — the pixels are decoded as stored.
- No compressed BMP, indexed TGA or HDR; those cases are rejected or fall back to
  `raw`.
- No mipmaps, texture compression (BC/ASTC) or color-space conversion; the
  artifact is always linear RGBA8. `gAMA`/`sRGB`/`iCCP` chunks are skipped, not
  applied.
- The pipeline is not wired into startup/editor yet; that integration and
  hot-reload are next steps, as are compressed-audio decoders and other model
  formats (the OBJ mesh importer already exists — see
  [mesh-import.md](mesh-import.md) — and so does the WAV audio importer, see
  [asset-audio.md](asset-audio.md)).

## Related

- Import and cache: [asset-import.md](asset-import.md)
- Mesh import (OBJ) / CXMH: [mesh-import.md](mesh-import.md)
- Audio import (WAV) / CXAW: [asset-audio.md](asset-audio.md)
- Architecture: [architecture.md](architecture.md)
- Versioning: [versioning.md](versioning.md)
