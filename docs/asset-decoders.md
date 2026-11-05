# Texture Decoders and the CXTX Artifact — CoreXEngine

This document describes CoreXEngine's image decoders and the engine-ready texture
artifact (`CXTX`). The code lives in `src/assets/image.zig` (pure decoding) and
`src/assets/texture.zig` (artifact + importers), exposed as `corex.assets.image`
and `corex.assets.texture` (types `corex.assets.Image` and `corex.assets.Texture`).

> Status: **implemented and tested** for **BMP, TGA and QOI**. PNG, JPEG, audio
> and fonts still have no decoder and continue to be imported as `raw` (verbatim
> copy). Other model formats also fall back to `raw`; the OBJ mesh importer does
> exist (see [mesh-import.md](mesh-import.md)). This is documented as a
> limitation, not as an existing capability.

## Overview

The import pipeline selects an importer by extension. For textures, the importer
**decodes** the source into **RGBA8** (8 bits per channel, row-major, top-down)
and **serializes** it into a self-describing `CXTX` container, which is the
derived artifact stored in the content-addressed cache. The renderer will be able
to upload the pixels directly without re-parsing the source format.

```
source (.bmp/.tga/.qoi) → decode → RGBA8 Image → serialize → CXTX → cache
```

## Supported formats

| Format | Extension | Modes | Depth | Notes |
|---|---|---|---|---|
| BMP | `.bmp` | `BI_RGB` (uncompressed) | 24, 32 bpp | Bottom-up and top-down; row padding at 24 bpp; BGR→RGB; alpha from the 4th byte at 32 bpp. |
| TGA | `.tga` | Uncompressed true-color (type 2) and RLE (type 10) | 24, 32 bpp | Descriptor bit 5 selects top-down; BGR(A)→RGBA(A). |
| QOI | `.qoi` | Decode **and** encode | 3/4 channels | Quite OK Image; encode enables lossless roundtrips and a future export path. |

Honest rejections (`InvalidImage`/`InvalidAsset` errors, no out-of-bounds access):
compressed BMP or bpp other than 24/32; color-mapped or grayscale TGA, or RLE that
exceeds the pixel count; QOI with invalid magic/channels, truncated or missing the
end marker; zero dimensions or dimensions above `max_dimension`; a pixel buffer
above `max_pixel_bytes`.

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
`Image`. The importer identity (`bmp`/`tga`/`qoi`, version 1) participates in the
cache key; changing the layout and bumping the version invalidates the affected
entries automatically.

## API

```zig
const A = corex.assets;

// Pure decoding (the caller frees Image.pixels with deinit):
var img = try A.image.decodeBmp(gpa, source); // or decodeTga / decodeQoi
defer img.deinit(gpa);

// Lossless QOI encode (roundtrip / future export):
const qoi_bytes = try A.image.encodeQoi(gpa, img);
defer gpa.free(qoi_bytes);

// CXTX artifact:
const artifact = try A.texture.serialize(gpa, img);
defer gpa.free(artifact);
const tex = try A.texture.parse(artifact); // zero-copy view
// tex.width / tex.height / tex.pixel_format / tex.pixels

// Importers (source -> CXTX), already registered in engineRegistry:
const bytes = try A.texture.importQoi(gpa, source); // importBmp / importTga
defer gpa.free(bytes);
```

Public limits: `image.max_dimension = 16384`, `image.max_pixel_bytes = 256 MiB`
(aligned with the cache artifact ceiling). Every read is bounds-checked and every
allocation is bounded and checked against overflow.

## Pipeline integration

`assets.engineRegistry()` registers `.bmp`/`.tga`/`.qoi` → texture importers,
before the scene/JSON/text importers, with a `raw` fallback. `.qoi` was added to
the index's texture classification (`AssetKind.fromExtension`). The pipeline,
cache and startup contracts remain unchanged: the `CXTX` artifact is just another
derived payload, stored and verified like any other.

```zig
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "qoi", .kind == .texture, .key -> CXTX artifact
```

## Guarantees and tests

- **QOI roundtrip**: `encodeQoi` → `decodeQoi` preserves pixels exactly (a
  gradient with alpha and a case exercising RUN/INDEX/DIFF/LUMA/RGBA chunks).
- **Known fixtures**: 24 bpp bottom-up BMP with padding, 32 bpp top-down BMP with
  alpha, uncompressed and RLE TGA (run + literal), a known 1-pixel QOI.
- **Corruption rejection**: invalid magic/compression/bpp/channels, truncation,
  an offset beyond the file, RLE exceeding the pixel count, a missing end marker.
- **Memory safety**: `checkAllAllocationFailures` probes on the decoders and on
  serialize; no leaks on allocation failure.
- **End to end**: a test imports a `.qoi` through the pipeline, reads the artifact
  back from the cache via `key`, parses it and compares the pixels; a second run
  is a cache hit (no re-import).

## Performance

- Single-pass decoding, no recursion, writing directly into the pixel buffer
  (cache-friendly). QOI is a format designed for speed.
- `encodeQoi` pre-reserves the maximum capacity (`14 + w*h*5 + 8`) and uses
  `appendAssumeCapacity`, avoiding reallocations during encoding.
- The `CXTX` artifact is self-describing: the renderer does not re-parse the
  source.

## Limitations and next steps

- No PNG (requires inflate), JPEG, compressed BMP, indexed TGA, 16-bit channels
  or HDR; those cases are rejected or fall back to `raw`, never "guessed".
- No mipmaps, texture compression (BC/ASTC) or color-space conversion; the
  artifact is always linear RGBA8.
- The pipeline is not wired into startup/editor yet; that integration and
  hot-reload are next steps, as are audio decoders and other model formats (the
  OBJ mesh importer already exists — see [mesh-import.md](mesh-import.md)).

## Related

- Import and cache: [asset-import.md](asset-import.md)
- Mesh import (OBJ) / CXMH: [mesh-import.md](mesh-import.md)
- Architecture: [architecture.md](architecture.md)
- Versioning: [versioning.md](versioning.md)
