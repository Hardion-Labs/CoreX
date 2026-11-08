# Scene Format — the `.scene` file

CoreXEngine scenes are versioned UTF-8 JSON documents. They describe entities,
hierarchy and components stored in the ECS. The engine **reads and validates**
scenes; project creation remains out of the engine's scope (see
[scope.md](scope.md)).

> Status: `format_version = 1` implemented for the engine's default schema
> (`corex.scene.EngineScene`, `transform` only) and, since the scene renderer
> landed, for `corex.scene.EngineRenderScene`, which adds `renderable` and
> `camera`. Startup loads the scene with the render schema, so a `.scene` may
> author a mesh, a material and a camera today. Tools may define additional
> schemas with `Scene(.{ Component(T, "name") })`.

## Structure

```json
{
  "format_version": 1,
  "name": "main",
  "entities": [
    {
      "id": 1,
      "name": "Root",
      "components": {
        "transform": {
          "position": [0, 0, 0],
          "rotation": [0, 0, 0, 1],
          "scale": [1, 1, 1]
        }
      }
    },
    {
      "id": 2,
      "name": "Child",
      "parent": 1,
      "components": {
        "transform": { "position": [0, 1, 0] }
      }
    }
  ]
}
```

## Root fields

| Field | Type | Required | Description |
|---|---|---|---|
| `format_version` | integer | yes | Scene format version. Supported: `1`. Unknown versions are rejected. |
| `name` | string | yes | Scene display name. Non-empty, up to 128 bytes, with no control characters or path separators. |
| `entities` | array | no | Entity list. Default: `[]` (empty scene). |

## Entity fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | integer > 0 | yes | Stable scene identifier, unique within the document. Never reused by the engine when creating new entities at runtime. |
| `name` | string | no | Display name. Same rules as the scene name. |
| `parent` | integer > 0 | no | `id` of the parent entity. Must exist, cannot be the entity itself and cannot form a cycle. |
| `order` | integer ≥ 0 | no | Sibling sort key among children of the same parent. Default: the entity's own `id`. |
| `components` | object | no | Typed components. Default: `{}`. |

Unknown fields and duplicate fields are rejected (strict JSON).

### Sibling order

`order` is what makes the order a user arranged in the editor **scene data** rather than a
view detail. Children of one parent are painted — and returned by `childIdsInto` — sorted by
ascending `(order, id)`, so:

- It is a **key, not an index**: no entity has to be unique or contiguous, and a gap or a
  duplicate is fine. Ties fall back to ascending `id`, which is why entities that never
  carried the field keep their creation order.
- It orders siblings only. The `entities` array itself stays sorted by ascending `id`, so
  adding an order never reshuffles the document.
- It is omitted when it equals the entity's own `id` — that value *is* the natural order —
  so a scene nobody reordered serializes byte for byte as it did before the field existed.
  `Scene.setOrder(id, id)` removes the entry for the same reason.
- It is compared inside one parent only: two entities under different parents may hold the
  same key, and a key may name an id that does not exist.

A subtree cloned into another scene (`cloneSubtree`, which is how prefabs and streamed
sectors are built) carries its authored order across, so an instance paints its children the
way its source does; the cloned root keeps none, because it is being attached to a new parent
rather than moved among its old siblings.

## The `transform` component

The entity's local component relative to its parent (or to the scene root). All
fields are optional and use identity values when absent:

| Field | Type | Default | Description |
|---|---|---|---|
| `position` | `[f32, f32, f32]` | `[0, 0, 0]` | Local position. |
| `rotation` | `[f32, f32, f32, f32]` | `[0, 0, 0, 1]` | Quaternion `[x, y, z, w]`. |
| `scale` | `[f32, f32, f32]` | `[1, 1, 1]` | Local scale. |

Non-finite values (NaN/Infinity) are rejected. The format stores only the
authored **local** transform (TRS). Propagation to **world space** is computed at
runtime by `Scene.computeWorldTransforms` / `Scene.worldMatrix` and is **never**
serialized into the `.scene` file — keeping the format local avoids redundancy
and preserves the `format_version = 1` contract. See
[scene-transforms.md](scene-transforms.md) for the math, the API and the
guarantees.

## The `renderable` component

Marks an entity as drawn. `mesh` and `material` are opaque handles into the
renderer's resource table (see [render-backend.md](render-backend.md)); the
engine resolves them when it loads the project's assets.

| Field | Type | Default | Description |
|---|---|---|---|
| `mesh` | `u32` | `0` | Mesh handle (slot index + generation). |
| `material` | `u32` | `0` | Material handle: a base colour, or a texture. |
| `bounds` | `{ center, extents }` | unit cube | **Local** axis-aligned bounding box used for frustum culling. |

`bounds` is `{ "center": [x, y, z], "extents": [x, y, z] }`; extents are
half-sizes and must be finite and non-negative, otherwise the component is
rejected. Keep the bounds tight: an over-large box is never culled, an
under-large one pops out while still on screen.

Handles are `(generation << 16) | slot`. A `.scene` authored against a project's
assets gets them from `corex.scene.render_scene.planSlots(...).handleOf(path)`:
the mapping is a pure function of the project's asset paths and the renderer
table capacity, so it is reproducible without loading anything. `assets/quad.obj`
in a 64-slot table, for example, is `65589` (`0x10035`) as both `mesh` and
`material` — the loader pairs every mesh with a white base colour, so a mesh's own
handle is a valid material.

## The `camera` component

Turns an entity into a camera. Its **world transform** supplies the position and
orientation (forward is `-Z`, as everywhere in this engine); the component is only
the lens, so a camera can be parented and moved like any other entity.

| Field | Type | Default | Description |
|---|---|---|---|
| `fov` | `f32` | `1.0471976` (60°) | Vertical field of view, radians, in `(0, π)`. |
| `near` | `f32` | `0.1` | Near plane, `> 0`. |
| `far` | `f32` | `500` | Far plane, `> near`. |

The projection is **reversed-Z with an infinite far plane**, so `near` alone
drives depth precision and `far` is the culling boundary. Only the first camera
entity in the scene (ascending stable ID) frames the view; a scene without a
camera renders nothing and says so.

### A complete example

`examples/hello-project/scenes/main.scene` draws a quad from a plain-text OBJ,
seen by a camera entity:

```json
{
  "id": 3,
  "name": "Quad",
  "parent": 1,
  "components": {
    "transform": { "position": [0, 1, 0] },
    "renderable": {
      "mesh": 65589,
      "material": 65589,
      "bounds": { "center": [0, 0, 0], "extents": [1, 1, 0] }
    }
  }
},
{
  "id": 4,
  "name": "Camera",
  "components": {
    "transform": { "position": [0, 0, 6] },
    "camera": { "fov": 1.0471976, "near": 0.1, "far": 100 }
  }
}
```

## Asset formats the loader accepts

| Extension | Treated as | Notes |
|---|---|---|
| `.mesh` | mesh artifact (`CXMH`) | The importer's derived artifact; parsed zero-copy. |
| `.obj` | mesh source | Converted with the importer's own OBJ decoder, so a checkout needs no binary asset and no external tool. |
| `.png`, `.bmp`, `.tga`, `.qoi` | texture | Decoded to RGBA8 and stored in the slot's texture. |
| anything else | not renderable | Indexed at startup, never loaded by the renderer. |

A file that fails to decode is counted as *skipped* and the frame still draws the
rest; running out of table slots is `error.TableFull`, because a mesh that
silently failed to load draws nothing at all.

## Validation rules

- `format_version` must be `1`.
- Names follow the shared display-name rule (manifest and scenes).
- Entity IDs must be unique and greater than zero.
- Parents must reference existing entities; self-parenting and cycles are
  rejected.
- `order`, when present, must be a non-negative integer. It is a sort key, so it is
  not checked for uniqueness and it does not have to name an existing entity.
- Components unknown to the loaded schema are rejected.
- The document is limited to 16 MiB and 1,000,000 entities.
- Scene paths coming from the manifest/CLI remain relative to the project root,
  without traversal (`..`), as per [project-format.md](project-format.md).

## Startup

- `editor` and `runtime`: the initial scene (manifest or `--scene`) is resolved,
  validated and loaded into the ECS. If no scene is specified, an empty scene is
  prepared. Scene failures produce exit code **6**.
- `validate`: does not load a scene; validates the manifest, compatibility,
  configuration and asset index. The launch contract remains the same
  ([launch-contract.md](launch-contract.md)).

## API and ownership

`corex.scene.EngineScene` (or `Scene(schema)`) owns its arena, its ECS world and
its ID maps. Call `deinit` exactly once. `parse`/`load` return an owned scene;
`serialize` returns owned bytes. `save` writes to a project-relative path and
creates parent directories; it is not crash-atomic (callers needing atomic
replacement should write a temporary file and rename it).

Runtime entity handles are generational ECS handles; the file's stable IDs live
in a separate mapping. Use the scene's `createEntity`/`destroyEntity` (not the raw
ECS world) to keep IDs and hierarchy consistent. Destroying an entity reparents
its direct children to its parent (or to the root).

## Prefabs

`.prefab` files use the same shape as this document, but require **exactly one
root entity** (without `parent`). Prefabs are reusable subtrees that can be
captured from a scene and instantiated with ID remapping. See
[scene-prefabs.md](scene-prefabs.md).

## Related

- Architecture: [architecture.md](architecture.md)
- Project format: [project-format.md](project-format.md)
- Versioning: [versioning.md](versioning.md)
- Launch contract: [launch-contract.md](launch-contract.md)
- World-space transforms: [scene-transforms.md](scene-transforms.md)
- Prefabs: [scene-prefabs.md](scene-prefabs.md)
