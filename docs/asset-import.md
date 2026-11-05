# Asset Import and Cache — CoreXEngine

This document describes CoreXEngine's asset import pipeline and content-addressed
cache. The code lives in `src/assets/` and is exposed publicly as `corex.assets`.
The asset index (a startup stage) remains in `src/core/assets.zig` and its
contract is unchanged.

> Status: **implemented and tested**. **Texture** decoders for **PNG, BMP, TGA
> and QOI** exist and produce a `CXTX` artifact (RGBA8) — see
> [asset-decoders.md](asset-decoders.md) — and an **OBJ mesh** decoder produces a
> `CXMH` artifact — see [mesh-import.md](mesh-import.md). Other binary formats
> (JPEG, audio, other models such as glTF/FBX/DAE, fonts) still have no
> decoder and use the `raw` importer (verbatim copy) until decoders are
> registered. This is documented below and is not described as an existing
> capability.

## Overview

The pipeline turns source assets into engine-ready derived artifacts and stores
them in an incremental, reproducible cache:

1. The asset index (`AssetIndex`) lists the source files (path, size, kind).
2. For each asset, the pipeline reads the source, selects an **importer** by
   extension and computes a **cache key** from the content hash + importer
   identity/version + options.
3. If the key already exists in the cache and is intact, the artifact is reused
   (**cache hit**, no re-import). Otherwise the importer runs and the result is
   written atomically (**import**).
4. A **report** (`Report`) records the per-asset result and the totals.

Because the key depends on the source content and the importer version, the cache
is invalidated automatically when the source changes or the importer is updated —
with no need for a separate index or timestamps.

## Importers

An `Importer` is a stable identity (`id` + `version`) plus a pure function
`source bytes -> derived bytes`. The version participates in the cache key;
changing an importer's behavior and bumping its version invalidates the affected
entries.

Built-in importers (`corex.assets.importer`):

| ID     | Version | Behavior                                                              |
|--------|---------|-----------------------------------------------------------------------|
| `raw`  | 1       | Verbatim copy for binary/opaque assets (no decoding).                  |
| `text` | 1       | Validates UTF-8, strips the BOM and normalizes CRLF/CR to LF.           |
| `json` | 1       | Validates strict JSON (rejects duplicate fields) and re-minifies losslessly. |

The scene importer (`corex.assets.scene_importer`, ID `scene`) reuses the scene
system: it validates the `.scene` document (hierarchy, components, transforms)
and re-serializes it canonically and deterministically. Invalid scenes are
rejected at import time.

Texture importers (`corex.assets.texture`, IDs `png`/`bmp`/`tga`/`qoi`, version 1)
decode the image to RGBA8 and serialize it into the `CXTX` artifact. The PNG
importer is backed by the dependency-free DEFLATE/zlib inflater in
`corex.assets.inflate`. See [asset-decoders.md](asset-decoders.md) for supported
formats, the artifact layout and limitations.

Importer contract:

```zig
pub const ImportError = error{ InvalidAsset, OutOfMemory };
// fn (gpa: Allocator, source: []const u8) ImportError![]u8
```

- The returned bytes are allocated with the passed allocator; the caller frees
  them.
- The importer must not retain `source`.
- `InvalidAsset` means the source is invalid for that importer; the pipeline marks
  the asset as `failed` and continues the batch.

### Importer registry

`Registry` maps extensions (including the dot, case-insensitive) to importers,
with a fallback for unmatched extensions:

- `importer.defaultRegistry()`: JSON + text, `raw` fallback.
- `assets.engineRegistry()`: textures (PNG/BMP/TGA/QOI) + meshes (OBJ) + scenes +
  prefabs (`.prefab`/`.corexprefab`) + JSON + text, `raw` fallback (the engine's
  default registry).

Higher layers can extend the registry (for example, audio decoders or other model
formats) without changing the pipeline:

```zig
const reg = corex.assets.Registry{
    .bindings = &.{.{ .extensions = &.{".png"}, .importer = my_png_importer }},
    .fallback = corex.assets.importer.raw_importer,
};
```

## Content-addressed cache

`corex.assets.Cache` stores one self-describing file per key, named by the
lowercase hexadecimal digest (BLAKE3-256). Layout of each file:

```text
magic "CXAC" (4 bytes) | format_version u32 LE | meta_len u32 LE | meta JSON | payload
```

The metadata JSON object records: key, source path, source hash, importer and
version, artifact hash and size, and the asset kind.

Guarantees:

- **Atomic write**: writes to a temporary file and `rename`s it. A crash never
  leaves a partially visible entry.
- **Integrity verification**: on read, the payload hash and size are recomputed
  and compared against the metadata. A corrupt/truncated entry is treated as a
  *miss* and re-imported (self-healing).
- **Version invalidation**: the cache `format_version` and the importer version
  participate in the key; bumping them invalidates the affected entries.
- **Concurrency-safe**: an atomic temporary-file counter + atomic `rename` allow
  parallel writes, including of identical keys.

Main API:

```zig
var cache = try corex.assets.Cache.open(io, cache_dir);
defer cache.deinit();

const key = corex.assets.cache.deriveKey(source_hash, "text", 1, options_hash);
try cache.put(gpa, key, info, payload, tmp_suffix);
const bytes = try cache.get(gpa, key); // ?[]u8; null on miss/corruption
```

`get` returns bytes owned by the caller (free them with the same allocator).
`has` checks without retaining the payload; `remove` deletes an entry.

## Pipeline

`corex.assets.pipeline` orchestrates the import of an `AssetIndex`:

```zig
var report = try corex.assets.pipeline.run(gpa, io, project_root, index, &cache, .{
    .registry = corex.assets.engineRegistry(),
});
defer report.deinit();
```

- `run(...)` imports assets concurrently through an `Io.Group` (for example
  `JobSystem.io()`). It requires a thread-safe allocator.
- `runSequential(...)` imports one at a time, without parallelism, for
  single-threaded contexts or non-thread-safe allocators.
- Each task writes only its own report slot; totals are computed after the group
  completes.
- A per-asset failure is recorded (`status = .failed`, `error_name`) and does not
  abort the rest of the batch.

Options (`Options`):

| Field              | Default             | Effect                                        |
|--------------------|---------------------|-----------------------------------------------|
| `force`            | `false`             | Ignores cache hits and re-imports everything.  |
| `registry`         | `defaultRegistry()` | Extension-to-importer registry.                |
| `max_source_bytes` | 64 MiB              | Read limit per source file.                    |
| `options_salt`     | `""`                | Extra bytes folded into the cache key.         |

The report (`Report`) contains one entry per asset in index order, with `status`
(`imported`, `cached`, `failed`), `importer_id`, `key`, `output_size` and
`error_name`, plus the totals (`imported`, `cached`, `failed`,
`total_output_bytes`). `Report.liveKeys(gpa)` collects the keys of every
successfully imported/cached asset — the `live` set for garbage collection.

## Garbage collection (GC)

`Cache.gc(gpa, live)` performs a **mark-and-sweep** pass: it deletes every entry
whose key is **not** in `live` and keeps the rest. It is the complement of the
import → cache cycle: when a source changes, is removed, or an importer is
versioned, the old entry becomes an orphan and GC reclaims it.

```zig
var report = try corex.assets.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = corex.assets.engineRegistry(),
});
defer report.deinit();

const live = try report.liveKeys(gpa); // valid keys of the current index
defer gpa.free(live);

const stats = try cache.gc(gpa, live);
// stats.scanned / .kept / .removed / .bytes_freed
```

Guarantees and behavior:

- `live` must be the **complete** set of keys to retain — typically from a pipeline
  run over the whole index. Entries outside that set are removed; GC does not
  "guess" what is still referenced.
- Entries are identified strictly by filename (64 lowercase hexadecimal digits).
  Temporary files (`.tmp.N`) and foreign files are **not** touched.
- Complexity O(entries + live), with a hash set for membership; directory
  iteration uses a fixed buffer. `bytes_freed` sums the on-disk size of the removed
  entries.
- It is a **maintenance** operation: run it when no concurrent `put` is in progress
  (it is not part of the per-frame import path). It is idempotent: a second sweep
  with the same `live` removes nothing.
- Assets that failed to import contribute no key; their old artifact (if any) is
  treated as an orphan and removed, which is correct because the current source is
  invalid.

## Limitations

- Texture decoders exist for **PNG, BMP, TGA and QOI** (see
  [asset-decoders.md](asset-decoders.md)) and a mesh decoder for **OBJ** (see
  [mesh-import.md](mesh-import.md)). JPEG, audio, other model formats
  (glTF/FBX/DAE) and fonts still have no decoder and use the `raw` importer
  (verbatim copy); they will be registered as dedicated importers once they exist.
  Adam7-interlaced PNG is rejected rather than approximated.
- The `json` importer preserves the source key order (it minifies, it does not sort
  keys); determinism is by source content, which is sufficient for a
  content-addressed cache.
- The pipeline is not wired into startup/editor yet; it is an independent public
  API. Startup integration and hot-reload are next steps.
- Garbage collection (GC) of orphan cache entries is **implemented** (`Cache.gc`,
  see above). There is no dependency tracking between assets yet, nor cleanup of
  temporary files left behind by interrupted writes (crash); both are planned
  extensions.
- Parallel `run` requires a thread-safe allocator; otherwise use `runSequential`.

## Memory safety

- Explicit allocators in every allocating API; ownership documented.
- Bounded reads (`max_source_bytes`, `max_cache_file_bytes`) to avoid unbounded
  memory consumption.
- Atomic writes + hash verification avoid trusting partial or corrupt artifacts.
- Source paths come from the index (project-relative); the pipeline reads them
  relative to the project root directory.
- Tests include allocation-failure probes (`checkAllAllocationFailures`) on the
  importers and corruption/truncation tests on the cache.

## Related links

- [architecture.md](architecture.md) — subsystem map and status.
- [asset-decoders.md](asset-decoders.md) — image decoders (PNG/BMP/TGA/QOI), the
  DEFLATE/zlib inflater and the CXTX artifact.
- [mesh-import.md](mesh-import.md) — OBJ mesh importer and the CXMH artifact.
- [scene-format.md](scene-format.md) — scene format validated by the importer.
- [versioning.md](versioning.md) — format versioning policy.
- [launch-contract.md](launch-contract.md) — startup contract (unchanged).
