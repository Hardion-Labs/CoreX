# Scene Prefabs — CoreXEngine

Prefabs are reusable, versioned entity subtrees. They let you capture a piece of a
scene (for example, an enemy with children and components) and instantiate it
several times in other scenes, with stable IDs remapped and hierarchy/components
copied by value.

> Status: **implemented and tested**. Prefabs reuse the scene format
> (`format_version = 1`) and the ECS; they do not duplicate serialization or
> storage. Change tracking and multi-scene management remain
> planned.

## The `.prefab` format

A `.prefab` (or `.corexprefab`) file is a strict JSON document with the same shape
as a `.scene` (see [scene-format.md](scene-format.md)), but with **exactly one root
entity** (an entity without `parent`). Documents with zero or multiple roots are
rejected with `error.InvalidPrefab`.

```json
{
  "format_version": 1,
  "name": "enemy",
  "entities": [
    {
      "id": 1,
      "name": "Root",
      "components": { "transform": { "position": [0, 1, 0] } }
    },
    { "id": 2, "name": "Child", "parent": 1 }
  ]
}
```

The same scene validation rules apply: unknown/duplicate fields rejected, unique
IDs > 0, existing parents, no cycles, plain-data components and valid names. The
engine's default schema is `corex.scene.EnginePrefab` (only `transform`); tools may
use `Prefab(.{ Component(T, "name"), ... })`.

## API

`corex.scene.Prefab(schemas)` (and `corex.scene.prefab`):

- `parse(gpa, bytes) !Prefab` — reads a strict prefab document.
- `load(gpa, io, dir, path) !Prefab` — loads relative to the project (safe path).
- `fromScene(gpa, source, root_entity, opt_name) !Prefab` — captures the subtree
  rooted at `root_entity` from a live scene. The source scene is unchanged; the
  captured root's original parent is dropped.
- `instantiate(target, parent_id) !ecs.Entity` — instantiates into `target` (same
  schema), attaching the cloned root to `parent_id` (or as a root when `null`).
  Returns the new root handle. Children of every entity inside the subtree keep the
  `order` the asset authored (see [scene-format.md](scene-format.md)); the cloned
  root is given none, since it is attached rather than moved.
- `serialize(gpa) ![]u8` / `save(io, dir, path)` — deterministic serialization (same
  layout as a scene, entities in ascending ID order).
- `deinit`, `count`, `root`, `name`, `root_id`.

The foundation is `Scene.cloneSubtree(source, root_id, parent_id)`, which is also
available directly on any `Scene(schemas)` for scene composition.

## Guarantees

- **ID remapping**: instantiation allocates new stable IDs in the target in
  ascending source-ID order, so it is deterministic and never collides with
  existing IDs. `parent` links inside the subtree are remapped; the cloned root is
  attached to the requested `parent_id`.
- **Copy by value**: components are plain data and copied by value; multiple
  instances are independent (mutating one does not affect another or the prefab).
- **Paint order**: an authored sibling order survives both clone hops — into the
  prefab's own scene on capture and out of it on instantiate — and a group nobody
  reordered stays unwritten, so capturing a prefab never grows the document.
- **Atomicity on error**: if any step fails (for example, an invalid component or an
  allocation failure), the entities created by the call are destroyed and the target
  remains unchanged, except for monotonic ID advancement (IDs are never reused).
- **Deep hierarchies**: subtree collection is iterative (no recursion), safe for
  arbitrarily deep hierarchies.
- **Memory safety**: explicit allocators, documented ownership,
  `checkAllAllocationFailures` probes and a rollback test on component failure.

## Asset integration

`AssetKind.prefab` classifies `.prefab`/`.corexprefab`. `engineRegistry()` includes
the `prefab` importer (id `prefab`, version 1), which validates the document
(single-root) and re-serializes it canonically before storing it in the
content-addressed cache. Prefabs participate in the pipeline/cache/GC like any
other asset.

```zig
const corex = @import("corex");
const A = corex.assets;
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "prefab", kind == .prefab
```

## Example

```zig
const corex = @import("corex");
const S = corex.scene;

var prefab = try S.EnginePrefab.parse(gpa, prefab_bytes);
defer prefab.deinit();

var level = try S.EngineScene.init(gpa, "level");
defer level.deinit();
const anchor = try level.createEntity("Anchor", null);

const a = try prefab.instantiate(&level, level.idOf(anchor));
const b = try prefab.instantiate(&level, level.idOf(anchor));
// a and b are independent roots, each with its own cloned subtree.

// Capture a prefab from a live scene:
var captured = try S.EnginePrefab.fromScene(gpa, &level, a, "captured");
defer captured.deinit();
const bytes = try captured.serialize(gpa);
defer gpa.free(bytes);
```

## Limitations and next steps

- Prefabs have no per-instance overrides and no nested variants (a prefab inside a
  prefab with editing); instantiation is a full copy by value.
- There are no cross-entity references through components (components are plain
  data; entity IDs stored in components are not remapped automatically).
- Change tracking and multi-scene management remain planned. Sector streaming is
  implemented separately — see [scene-streaming.md](scene-streaming.md).

## Related

- Scene format: [scene-format.md](scene-format.md)
- World-space transforms: [scene-transforms.md](scene-transforms.md)
- Import and cache: [asset-import.md](asset-import.md)
- Architecture: [architecture.md](architecture.md)
