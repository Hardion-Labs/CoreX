# Asset Change Detection and Incremental Import — CoreXEngine

This document describes CoreXEngine's change detection: how the engine finds out
which assets were added, modified or removed, and how to re-import only those. It
is the foundation of hot-reload. The code lives in `src/assets/changes.zig` and is
exposed as `corex.assets.changes` (types `corex.assets.Snapshot`,
`corex.assets.ChangeSet`).

> Status: **implemented and tested** (polling-based detection + incremental
> import + correct garbage collection). What is *not* implemented: an operating
> system event watcher (inotify/FSEvents/`ReadDirectoryChangesW`) and wiring into
> the editor/runtime, which do not exist yet. Detection is a complete, usable
> feature on its own — call it once per editor frame or on a timer.

## Why not just re-run the pipeline?

The cache is content-addressed, so re-running the pipeline over the whole index
already avoids re-importing unchanged bytes. Two things are still missing for a
live session:

1. **Knowing what changed.** A renderer or editor needs the list of affected
   assets to reload GPU resources, not just a report saying "0 imported".
2. **Not reading every file on every poll.** Hashing a whole project each frame
   is wasteful; most polls find nothing.

Change detection answers both, and adds a third piece that is easy to get wrong:
the **complete live key set** for garbage collection after a partial import.

## Two-tier detection

| Tier | Cost | What it does |
|---|---|---|
| Cheap | one `stat` per file | Compares `size` + `mtime` against the baseline. Unchanged fingerprint ⇒ the stored hash is reused and **the file is not read**. |
| Confirmation | one read + BLAKE3 per candidate | New files, and files whose fingerprint moved, are hashed and compared to the baseline hash. |

The confirmation tier is what makes hot-reload well behaved: an asset that was
merely **touched**, or re-saved with identical bytes, moves `mtime` but keeps its
hash, so it is **not** reported as modified and nothing is reloaded.

### The documented blind spot

An edit that preserves **both** the size and the modification time is invisible to
the cheap tier. This is inherent to timestamp-based detection, not a bug, and it
is covered by a test. Use `Options.verify_all = true` when timestamps cannot be
trusted (restored backups, coarse filesystem clocks, tools that preserve `mtime`);
it hashes every file and detects any content change.

## API

```zig
const corex = @import("corex");
const A = corex.assets;

// 1. Baseline: stat + hash every indexed asset (one full scan).
var index = try A.indexDirectories(gpa, io, project_root, &.{"assets"});
defer index.deinit();
var root = try std.Io.Dir.openDirAbsolute(io, project_root, .{});
defer root.close(io);
var baseline = try A.changes.capture(gpa, io, root, index, .{});
defer baseline.deinit();

// 2. Later: re-index, then compare. `baseline` is not modified.
var detected = try A.changes.detect(gpa, io, root, &baseline, index, .{});
defer detected.deinit();
// detected.changes.added / .modified / .removed  (sorted, owned by the change set)
// detected.snapshot                              (the new baseline)

// 3. Re-import exactly what changed.
const only = try detected.changes.changedPaths(gpa); // added + modified
defer gpa.free(only);
var report = try A.pipeline.run(gpa, io, root, index, &cache, .{
    .registry = A.engineRegistry(),
    .only = only,
});
defer report.deinit();

// 4. Garbage-collect with the COMPLETE live set, not the filtered report.
const live = try detected.snapshot.cacheKeys(gpa, A.engineRegistry(), "");
defer gpa.free(live);
const stats = try cache.gc(gpa, live);
```

### `Snapshot`

An owned, path-sorted baseline. Call `deinit` exactly once; it is move-only.

- `entries: []Entry` where `Entry = { path, size, mtime, hash }` (BLAKE3-256, the
  same hash function the cache uses).
- `count()`, `totalBytes()`.
- `find(path) ?Entry` — binary search.
- `cacheKeys(gpa, registry, options_salt) ![]Hash` — derives every asset's cache
  key exactly as the pipeline would, **without reading or importing anything**.

### `ChangeSet`

- `added`, `modified`, `removed`: `[][]const u8`, each sorted by path, so results
  are deterministic.
- Paths are **owned by the change set**, so it stays valid after either snapshot
  is released.
- `total()`, `isEmpty()`, `changedPaths(gpa)` (added + modified, for `only`).

### `Options`

| Field | Default | Effect |
|---|---|---|
| `verify_all` | `false` | Hash every file instead of trusting size + mtime. |
| `max_source_bytes` | 64 MiB | Read bound for hashing; the same default the pipeline uses. |

### Errors

`error.OutOfMemory` and `error.ProjectIo` (a source could not be stat'ed or read).
A file that **vanishes** between indexing and detection is not an error: it is
left out of the new baseline and reported as removed.

## Incremental import (`pipeline.Options.only`)

`Options.only` is an optional list of project-relative paths. When set, the run
imports only those assets and the report contains one entry per selected asset,
in index order. `null` (the default) imports the whole index — the historical
behavior, unchanged.

Selection sorts the filter once and binary-searches each indexed asset, so it
costs O(n log m) rather than O(n·m). Duplicate and unknown paths are harmless.
Both `run` (parallel) and `runSequential` honor the filter.

## Garbage collection after a partial import

This is the trap worth stating explicitly:

> `Report.liveKeys` only contains the assets **that run** imported. After a
> filtered run it is a *partial* set. Passing it to `Cache.gc` would delete every
> other asset's artifact.

Use `Snapshot.cacheKeys` instead: it derives the key of every asset in the
project from the stored hashes, with the same importer identity/version and
options salt the pipeline uses. A test asserts byte-for-byte parity between
`Snapshot.cacheKeys` and the keys a real pipeline run produced, including the
`raw` fallback and a non-empty salt.

After an edit, the orphans are the edited asset's **previous** artifact plus any
artifacts of deleted assets — which is exactly what the GC reclaims.

## Guarantees and tests

- **Classification**: added, modified, removed, rename (removed + added), and a
  file deleted after indexing (reported as removed, not an error).
- **No false positives**: a touch or an identical re-save with a moved `mtime` is
  not a modification.
- **Documented blind spot**: a size- and `mtime`-preserving edit is missed by the
  cheap tier and caught by `verify_all`.
- **Determinism**: snapshots and change lists are sorted by path; two captures of
  the same project produce identical entries.
- **Ownership**: change-set paths outlive both snapshots (asserted by a test that
  releases the old baseline and keeps reading `removed`).
- **Key parity**: `cacheKeys` matches the pipeline's derived keys; a salt change
  moves every key; editing one asset moves exactly one key.
- **Memory safety**: explicit allocators, documented ownership,
  `checkAllAllocationFailures` probes over capture, detect, `cacheKeys` and
  `changedPaths`; `OutOfMemory` propagates instead of being reported as an I/O
  error.
- **End to end**: a full hot-reload cycle — import 3 assets, edit one, add one,
  delete one, detect, re-import only the 2 changed, GC with the complete live set
  (3 kept, 2 reclaimed), then a quiet pass that reports no changes and re-imports
  nothing.

## Performance

Measured in `ReleaseFast` on the development container, 2000 assets totaling
4 MiB:

| Operation | Time |
|---|---|
| `capture` (stat + hash everything) | ~13.9 ms |
| `detect`, nothing changed (cheap tier, no file reads) | **~1.5 ms** |
| `detect`, nothing changed, `verify_all` | ~8.8 ms |

Detection is O(n log n) (a binary search per asset against the sorted baseline,
then a linear merge join). Only candidates are read, so an idle project costs one
`stat` per file per poll.

## Limitations and next steps

- **Polling only.** There is no OS event watcher yet; call `detect` on a timer or
  once per editor frame. An inotify/FSEvents backend is a planned extension.
- **No editor/runtime wiring.** The graphical editor and GPU backends do not
  exist yet, so nothing consumes these change sets automatically.
- **No dependency graph.** A change to a material does not yet invalidate the
  meshes or scenes that reference it; only the changed file is reported.
- **Whole-file hashing.** Candidates are read in full (bounded by
  `max_source_bytes`); there is no chunked/incremental hashing for very large
  files.
- **Temp-file cleanup** after interrupted cache writes is still pending (see
  [asset-import.md](asset-import.md)).

## Related

- Import and cache: [asset-import.md](asset-import.md)
- Image decoders / CXTX: [asset-decoders.md](asset-decoders.md)
- Architecture: [architecture.md](architecture.md)
- Versioning: [versioning.md](versioning.md)
