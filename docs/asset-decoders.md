# Image Decoders and the CXTX Artifact — CoreXEngine

This document describes CoreXEngine's image decoders and the engine-ready texture
artifact (`CXTX`). The code lives in `src/assets/image.zig` (BMP/TGA/QOI),
`src/assets/png.zig` (PNG) and `src/assets/inflate.zig` (DEFLATE/zlib), plus
`src/assets/texture.zig` (artifact + importers). They are exposed as
`corex.assets.image`, `corex.assets.png`, `corex.assets.inflate` and
`corex.assets.texture` (types `corex.assets.Image` and `corex.assets.Texture`).

> Status: **implemented and tested** for **PNG, BMP, TGA and QOI**. JPEG and
> fonts still have no decoder and continue to be imported as `raw` (verbatim
> copy). Other model formats also fall back to `raw`; the OBJ mesh importer does
> exist (see [mesh-import.md](mesh-import.md)), as does the WAV audio importer
> (see [asset-audio.md](asset-audio.md)). This is documented as a limitation, not
> as an existing capability.

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
| PNG | `.png` | Non-interlaced; grayscale, truecolor, indexed, grayscale+alpha, truecolor+alpha | 1, 2, 4, 8, 16 bit | All five row filters; `tRNS` (palette alpha and color keys); multiple IDAT chunks; chunk CRC-32 and zlib Adler-32 verified. |
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

### Normalization to RGBA8 (documented, not silent)

- **16-bit samples** are reduced to 8 bits by taking the **high byte**, because
  `CXTX` is RGBA8. No dithering or gamma conversion is applied.
- **Sub-byte grayscale** samples (1/2/4 bit) are scaled to the full 0..255 range by
  bit replication, so a 1-bit white pixel becomes 255, not 1.
- **Indexed** pixels are expanded through the palette; missing `tRNS` entries are
  opaque (255).
- **Grayscale** is replicated into R, G and B.

### What is rejected

- **Adam7 interlacing** (`interlace = 1`). This is a documented limitation, not an
  approximated decode.
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

// PNG lives in its own module and returns the same Image type:
var png_img = try A.png.decode(gpa, png_source);
defer png_img.deinit(gpa);

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
- **Rejection vectors**: 20 malformed PNGs (bad signature, CRC, Adler-32, zlib
  header, row filter, palette index, bit depth, color type, interlacing, chunk
  order, truncation, trailing bytes, inflated-size mismatch) must all fail.
- **Inflate**: a 200 KiB multi-block dynamic-Huffman stream, fixed-Huffman and
  stored streams, crafted over-subscribed/illegal-code streams, truncation at
  several offsets, and the output bound for literals, matches and stored blocks.
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
- `encodeQoi` pre-reserves the maximum capacity (`14 + w*h*5 + 8`) and uses
  `appendAssumeCapacity`, avoiding reallocations during encoding.
- The `CXTX` artifact is self-describing: the renderer does not re-parse the
  source.

## Limitations and next steps

- No Adam7-interlaced PNG, no APNG animation, and no 16-bit output artifact
  (`CXTX` is RGBA8, so 16-bit sources lose their low byte).
- No JPEG, compressed BMP, indexed TGA or HDR; those cases are rejected or fall
  back to `raw`, never "guessed".
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
