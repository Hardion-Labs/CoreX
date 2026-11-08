# Scene Streaming — CoreXEngine

This document describes CoreXEngine's **scene streaming**: named sectors loaded
into and unloaded from a live scene, either explicitly or from a listener
position. The code lives in `src/scene/stream.zig` and is exposed as
`corex.scene.stream` (with `corex.scene.EngineStream` for the default schema).

> Status: **implemented and tested**. A stream manifest is a versioned, strict
> JSON document; sector payloads are ordinary `.scene` files. Change tracking,
> multi-scene management and asynchronous/background sector loading remain
> planned — they are not described here as existing capabilities.

## Overview

```
world.corexstream ──► Manifest (validated, canonical, sorted by name)
                          │
                          ▼
        Stream ── load ──► Scene.load + Scene.cloneSubtree ──► target Scene
               └─ unload ─► Scene.destroySet (exact owned set)
```

A `Stream` **owns its manifest** and **borrows the target scene**, which must
outlive it. `deinit` unloads everything the stream created and leaves entities the
caller made untouched.

The module depends on `scene.zig` in one direction only. `scene.zig` does not
import it; `src/scene.zig` re-exports both. Sector documents are parsed by the
existing `Scene.load` and instantiated by the existing `Scene.cloneSubtree`, so
there is no second scene format, no second serializer and no second ECS.

## The manifest format (`.corexstream`, v1)

```json
{
  "format_version": 1,
  "name": "world",
  "sectors": [
    {
      "name": "town",
      "scene": "scenes/town.scene",
      "center": [0, 0, 0],
      "radius": 10,
      "unload_radius": 14,
      "pinned": false
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `format_version` | yes | Must be `1`. |
| `name` | yes | Display name, same validation as a scene name. |
| `sectors` | no (default `[]`) | At most 4096 entries. |
| `sectors[].name` | yes | Unique display name; the sector's identity. |
| `sectors[].scene` | yes | Project-relative path to a `.scene` document. |
| `sectors[].center` | no (default `[0,0,0]`) | Volume centre, three finite numbers. |
| `sectors[].radius` | yes | Load distance; finite and strictly positive. |
| `sectors[].unload_radius` | no (default = `radius`) | Unload distance; must be `>= radius`. |
| `sectors[].pinned` | no (default `false`) | Always resident; never unloaded by `update`. |

Parsing is strict: unknown fields and duplicate JSON keys are rejected, sector
names must be unique, paths go through the same `validateRelative` guard as every
other project-relative path, and non-finite or inverted volumes are refused.
Sectors are **canonicalized in name order**, so `serialize` is deterministic and
re-importing an artifact is byte-stable. An `unload_radius` equal to `radius` is
omitted on output because it adds no hysteresis.

The `stream` importer (v1, bound to `.corexstream`) validates and canonicalizes a
manifest through the normal asset pipeline, exactly like `scene` and `prefab`.
Manifests are indexed as `AssetKind.scene`. Sector payloads stay separate assets
and are imported on their own.

## Residency

### Explicit control

```zig
var stream = corex.scene.EngineStream.init(gpa, &scene, manifest);
defer stream.deinit();                       // unloads what it loaded

try stream.loadSector(io, dir, "town");      // idempotent, ignores volumes
const removed = try stream.unloadSector("town");  // idempotent, overrides pin
```

### Position-driven control

```zig
const report = try stream.update(io, dir, listener_position, .{
    .max_loads = 4,
    .max_unloads = 4,
    .max_resident_entities = 50_000,
});
if (report.pending) { /* a budget ran out; call again next frame */ }
if (report.oversized > 0) { /* a sector can never fit; retrying will not help */ }
```

`update` runs unloads **before** loads, so freed room is available in the same
call. A sector loads when the listener is within `radius` and unloads only when it
is beyond `unload_radius`. That band is the hysteresis: a listener sitting on the
boundary cannot cause a load/unload every frame. Pinned sectors are loaded
regardless of distance and are never unloaded by `update`.

Sectors are visited in canonical name order. Within a sector the roots are cloned in
the source's **paint order** — `(order, id)`, the order the hierarchy shows them in —
and the IDs one clone allocates ascend with the source's, so the same manifest and the
same positions always produce the same result. Both halves matter: the ascending IDs are
what make a load reproducible, and the paint order is what makes an order the user
authored *among roots* survive being streamed in.

### Budgets

`Options.max_loads` and `max_unloads` cap operations per call.
`max_resident_entities` is a ceiling on entities **owned by the stream**, not on
the target scene's total size. A sector that would exceed its share is skipped after
parsing but **before any mutation**; `Report.oversized` counts the sectors that can
never fit the ceiling (retrying will not help), while `Report.pending` is set only
when a budget or transient capacity stopped a sector that may load later.

### Ownership

The stream tracks exactly the entities it created, including descendants.
Queries:

- `isResident(name)`, `residentSectorCount()`, `residentEntityCount()`
- `sectorEntities(name)` — sorted stable IDs owned by a resident sector
- `sectorRoots(name)` — the cloned top-level entities
- `sectorOfEntity(id)` — O(1) reverse lookup, `null` for caller-created entities

Entities the **caller** parents under a streamed entity are not owned by the
sector. When the sector unloads they survive and are reparented to the nearest
surviving ancestor (or become roots), matching `Scene.destroyEntity` semantics.

Stable IDs are allocated fresh on every load and never reused, so an entity's ID
**changes across an unload/reload cycle**. Track sectors by name and entities by
the returned roots or by name; do not persist a streamed entity's stable ID
expecting it to survive a reload.

## Two new scene primitives

Streaming needed two bulk operations that `Scene` did not have. Both are
**additive**; no existing method changed behaviour.

### `Scene.destroySet(ids) usize`

Destroys a set of entities in one pass. Surviving children are reparented to the
nearest surviving ancestor, which is exactly the result of calling
`destroyEntity` once per ID — a differential test proves the two produce
byte-identical documents across a dozen subset shapes.

`ids` must be sorted non-decreasing (duplicates allowed). The operation
**does not allocate and cannot fail**:

- membership is a binary search over the caller's sorted slice, so no hash set;
- ancestor resolution is memoized by path-compressing the `parent` field of the
  doomed records themselves, which are about to be deleted anyway, so a deep
  doomed chain is walked once in total rather than once per surviving child.

That is what makes it usable on teardown and rollback paths, where an allocator
failure must not be able to strand entities in the scene.

### `Scene.nextStableId() u64`

The ID the next `createEntity` will hand out. Because IDs are monotonic and never
reused, a bulk operation can capture the exact set it created as the half-open
range `[before, after)` — without allocating. Streaming uses this both to record
ownership and to roll back, which is why a failed load is exact even under OOM.

## Failure handling

- **All-or-nothing load.** A sector that fails partway is fully rolled back. The
  rollback walks the created ID range and calls the infallible `destroyEntity`, so
  it works even when the allocator is the thing that failed. Allocation-failure
  probes assert that a failed load leaves the entity count, the residency map, the
  ownership index and the accounting exactly as they were.
- **Ceiling rejection is side-effect free.** A sector rejected by
  `max_resident_entities` never touches the target scene.
- **Accounting invariant.** `residentEntityCount()` always equals the sum of
  `sectorEntities(name).len` over resident sectors, and the reverse index covers
  exactly the same set — including after the caller destroys a streamed entity
  behind the stream's back.
- **Missing or malformed sector file.** Surfaces the scene loader's error
  (`ProjectIo`, `InvalidJson`, …) and leaves the sector non-resident.

## Performance

ReleaseFast, best of 5. Removing half of a fanout-8 hierarchy, comparing
`destroySet` against the semantics-preserving reference of one `destroyEntity`
call per entity:

| Entities | Removed | `destroySet` | `destroyEntity` loop | Speedup |
|---|---|---|---|---|
| 5 000 | 2 500 | **0.56 ms** | 47.9 ms | 85× |
| 20 000 | 10 000 | **3.16 ms** | 1 346.9 ms | 427× |
| 80 000 | 40 000 | **17.8 ms** | 24 144.3 ms | 1358× |

The speedup grows with scene size because the batch is `O(records · log ids)`
while the loop is `O(records · ids)`. This is the reason streaming unloads are
practical at all: the naive implementation would have taken 24 seconds to unload
40 000 entities from an 80 000-entity scene.

Streaming a 10 000-entity sector: **load 15.4 ms**, **unload 1.24 ms**. Load is
dominated by JSON parsing and `cloneSubtree`, not by residency bookkeeping, which
is a single allocation-free range scan.

## Guarantees and tests

Covered by the suite (all green in Debug, ReleaseSafe and ReleaseFast):

- Manifest parse/canonicalization/defaults, deterministic serialize, file
  roundtrip, binary-search lookup, empty sector list, size limit.
- Twelve malformed-manifest cases: bad JSON, wrong version, unknown field,
  duplicate JSON key, bad manifest/sector names, duplicate sector, relative and
  absolute path escapes, zero/negative radius, unload radius below load radius.
- Exact ownership capture including descendants and multiple roots; idempotent
  load and unload; caller entities surviving an unload with correct reparenting;
  unload after the caller destroyed part of a sector.
- Hysteresis in both directions, budgets with `pending`, the entity ceiling
  leaving the scene byte-identical, pinned semantics, `deinit` restoring the
  scene to its pre-stream document.
- Determinism across six load/unload cycles, compared by a structural signature
  (names, components and parent *rank*) because stable IDs legitimately advance.
- Allocation-failure probes over manifest parse/serialize, sector load (asserting
  exact rollback), `update` (asserting the accounting invariants), unload, and the
  `stream` importer.
- `destroySet`: differential equivalence with `destroyEntity`, nearest-surviving-
  ancestor reparenting, a 20 000-deep chain, stale/unknown IDs, and a direct
  assertion that it performs **zero allocations**.

## Limitations and next steps

- **Synchronous loading.** `loadSector` and `update` parse and clone on the calling
  thread. There is no background job, no async prefetch and no partial residency;
  budgets bound the work per call but do not move it off the frame.
- **No document cache.** An unloaded sector is re-read and re-parsed if it comes
  back. Hysteresis is what prevents thrashing today.
- **Spherical volumes only.** No boxes, frustums, portals or occlusion-driven
  visibility, and no level-of-detail.
- **IDs are not stable across reloads**, as described above.
- **No cross-sector references.** A sector document cannot name an entity in
  another sector; parent links only work inside one document.
- **No change tracking.** Editing a sector file does not invalidate a resident
  copy; unload and reload it explicitly.
- **Sector paths bypass the asset cache.** They are read from the project
  directory as source `.scene` files, not from the canonicalized copies the
  `scene` importer stores in the cache.

## Related

- Scene format and ECS bridge: [scene-format.md](scene-format.md)
- Prefabs: [scene-prefabs.md](scene-prefabs.md)
- World-space transforms: [scene-transforms.md](scene-transforms.md)
- Import and cache: [asset-import.md](asset-import.md)
- Architecture: [architecture.md](architecture.md)
- Versioning policy: [versioning.md](versioning.md)
