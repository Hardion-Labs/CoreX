# Mesh Import (OBJ) and the CXMH Artifact — CoreXEngine

This document describes CoreXEngine's mesh importer: the decoder for the geometry
subset of **Wavefront OBJ** and the engine-ready **`CXMH`** artifact it produces.
The code lives in `src/assets/mesh.zig` and is exposed as `corex.assets.mesh`
(with `corex.assets.Mesh` / `corex.assets.MeshView`).

> Status: **implemented and tested**. This is the "model" part of the asset
> decoders roadmap item. It consumes the same pipeline/cache as the other
> importers ([asset-import.md](asset-import.md)) and feeds the render extraction
> layer ([render-extraction.md](render-extraction.md)): the mesh `bounds` can
> initialize `Renderable.bounds`, and mesh handles reference the artifact. Other
> model formats (glTF/FBX/DAE) still have no decoder.

## Overview

```
.obj source ──► decodeObj ──► Mesh (interleaved vertices + u32 indices + bounds)
                          ──► serialize ──► CXMH artifact ──► content-addressed cache
                                                          ──► parse (zero-copy view) ──► renderer
```

The importer is a pure `bytes -> bytes` transformation with its own identity
(`id = "obj"`, `version = 1`). The version participates in the cache key, so
changing the layout and bumping the version invalidates the affected entries
automatically.

## Supported OBJ subset

Honest and documented — what is not supported is **skipped**, never "guessed":

- `v x y z [w]` — positions (`w` ignored).
- `vn x y z` — normals (normalized on import; zero length is rejected).
- `vt u v [w]` — UVs (`w` ignored; passed through unchanged, bottom-left origin).
- `f a b c ...` — polygonal faces, **fan-triangulated** as `(0,i,i+1)`. Each corner
  may be `v`, `v/vt`, `v//vn` or `v/vt/vn`; indices are 1-based, and negative values
  resolve relative to the current end. Index `0`, out-of-range indices and forward
  references are rejected.
- Missing normals get a **flat per-face normal** (normalized edge cross product; a
  degenerate face → normal `(0,0,0)`). Missing UVs → `(0,0)`.
- Vertices are **deduplicated** by `(position, uv, normal)` reference. With shared
  explicit normals, coincident corners across faces are merged; with flat normals,
  each face keeps its own vertices (correct for flat shading).
- `#` comments, blank lines, CRLF and group/material directives (`o`, `g`, `s`,
  `usemtl`, `mtllib`, ...) are skipped — materials are future work.

## The `CXMH` artifact

Little-endian layout, 44-byte header:

| Offset | Field | Type |
| --- | --- | --- |
| 0..4 | magic `"CXMH"` | 4 bytes |
| 4..8 | `format_version` (= 1) | u32 |
| 8..12 | `vertex_format` (= 0, p3n3t2) | u32 |
| 12..16 | `vertex_count` | u32 |
| 16..20 | `index_count` (multiple of 3) | u32 |
| 20..32 | `bounds_min` | [3]f32 |
| 32..44 | `bounds_max` | [3]f32 |
| 44.. | interleaved vertices (`vertex_count * 32`) + indices (`index_count * 4`) | bytes |

Each vertex is 32 bytes: `position[3] f32`, `normal[3] f32`, `uv[2] f32`
(the `p3n3t2` format). The indices form a triangle list (`u32`).

## API

- `decodeObj(gpa, source) DecodeError!Mesh` — decodes OBJ into an indexed mesh.
- `Mesh { vertices: []Vertex, indices: []u32, bounds_min, bounds_max }` — an owned
  mesh; `deinit(gpa)` frees it; `triangleCount()`.
- `Vertex` — a 32-byte `extern struct` (position + normal + uv).
- `serialize(gpa, mesh) ImportError![]u8` — validates and writes the `CXMH`
  artifact.
- `parse(bytes) error{InvalidAsset}!MeshView` — a **zero-copy**, alignment-safe
  view: linear validation of structure, index range and float finiteness; the
  `vertexAt(i)` / `indexAt(i)` accessors read little-endian fields explicitly (no
  pointer casts).
- `importObj(gpa, source) ImportError![]u8` — `decodeObj` + `serialize`.
- `obj_importer` (`id="obj"`, `version=1`) and `bindings` (`.obj`).

Limits: `max_vertices = 4,000,000` (128 MB of vertices), `max_indices = 12,000,000`
(48 MB of indices); total < the cache's 256 MiB ceiling.

## Pipeline integration

`assets.engineRegistry()` now includes the mesh bindings (`.obj`), so the pipeline
imports `.obj` into `CXMH` automatically, with cache and GC like any other asset.
`.obj` is already classified as `AssetKind.model` by the index.

```zig
const corex = @import("corex");
const A = corex.assets;
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "obj", kind == .model
const artifact = (try cache.get(gpa, key)).?;
defer gpa.free(artifact);
const view = try A.mesh.parse(artifact);
// view.vertexAt(i).position / .normal / .uv, view.indexAt(i), view.bounds_*
```

## Guarantees and tests

- **Decoding**: a triangle with position/normal/UV; fan triangulation of a quad;
  negative indices; dedup with explicit normals vs. flat per-face normals; the
  `v/vt` and `v//vn` corner forms; skipped comments/CRLF/directives; normal
  normalization and rejection of a zero-length normal.
- **Rejection**: no faces, a face with < 3 corners, index 0/out of range/forward
  reference, a corner with too many parts, non-finite floats, a position with < 3
  components.
- **Artifact**: serialize/parse roundtrip preserving vertices/indices/bounds;
  rejection of invalid magic/version/format/counts/length, truncation, an
  out-of-range index and a non-finite vertex (crafted bytes); serialize rejects an
  invalid mesh.
- **Pipeline**: an end-to-end OBJ → CXMH → cache → parse test, with a cache hit on
  the second run.
- **Memory safety**: `checkAllAllocationFailures` on decode/serialize/import with no
  leaks; the two-phase ownership transfer in `decodeObj` frees the first slice if
  the second one fails.

## Performance

- One pass over the source lines; position/normal/UV lists and a dedup
  `AutoHashMap` with a 96-bit `(v, vt, vn)` key.
- O(n) fan triangulation per face; only used vertices enter the buffer.
- `parse` makes one linear validation pass (finitude + index range), guaranteeing
  the consumer never sees an out-of-range index or a NaN.
- A self-contained, cache-friendly artifact for direct upload by the GPU backend.

## Limitations and next steps

- Only the OBJ geometry subset; no materials/`.mtl`, no groups as submeshes, no
  smoothing groups, no per-vertex colors.
- No glTF/FBX/DAE; those formats still fall back to `raw`.
- No LOD, skinning, morph targets or mesh compression.
- Binding `Renderable.mesh` handles to the `CXMH` artifact and the GPU upload are
  work for the future render backend.

## Related

- Import and cache: [asset-import.md](asset-import.md)
- Texture decoders / CXTX: [asset-decoders.md](asset-decoders.md)
- Render extraction: [render-extraction.md](render-extraction.md)
- Architecture: [architecture.md](architecture.md)
