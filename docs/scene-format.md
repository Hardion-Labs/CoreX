# Scene Format — the `.scene` file

CoreXEngine scenes are versioned UTF-8 JSON documents. They describe entities,
hierarchy and components stored in the ECS. The engine **reads and validates**
scenes; project creation remains out of the engine's scope (see
[scope.md](scope.md)).

> Status: `format_version = 1` implemented for the engine's default schema
> (`corex.scene.EngineScene`), which currently contains the `transform`
> component. Tools may define additional schemas with
> `Scene(.{ Component(T, "name") })`.

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
| `components` | object | no | Typed components. Default: `{}`. |

Unknown fields and duplicate fields are rejected (strict JSON).

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

## Validation rules

- `format_version` must be `1`.
- Names follow the shared display-name rule (manifest and scenes).
- Entity IDs must be unique and greater than zero.
- Parents must reference existing entities; self-parenting and cycles are
  rejected.
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
