# World-Space Transforms — CoreXEngine

This document describes how CoreXEngine propagates local scene transforms into
world space. The math lives in `src/scene/transform.zig` and is exposed as
`corex.scene.transform` (with the types `corex.scene.Mat4`, `Vec3` and `Quat`).
The scene methods live in `src/scene/scene.zig` (`Scene.computeWorldTransforms`
and `Scene.worldMatrix`).

> Status: **implemented and tested**. The `.scene` file still stores only the
> authored **local** transform (TRS, `format_version = 1`); world-space matrices
> are **computed at runtime** and never serialized. This preserves the scene
> format contract (see [scene-format.md](scene-format.md)).

## Why matrices (and not component-wise TRS)

Composing two transforms by combining position/rotation/scale component-wise
loses shear when there is **non-uniform scale under rotation**. That is why
propagation uses full 4×4 matrices:

```
child_world = parent_world * child_local
```

where `child_local = T * R * S` (scale applied first, then rotation, then
translation). Matrix multiplication preserves shear correctly at any hierarchy
depth.

## Math conventions

- `Mat4 = [16]f32`, **column-major**: the element at row `r`, column `c` is
  `m[c*4 + r]`. Compatible with the layout expected by column-major graphics APIs.
- `Vec3 = [3]f32`; `Quat = [4]f32` in `[x, y, z, w]` form.
- `transform.identity()` returns the identity matrix.
- `transform.fromTransform(t)` builds `M = T * R * S` from a local `Transform`.
  The quaternion is **normalized** internally; a zero-length quaternion is
  treated as identity.
- `transform.multiply(a, b)` returns `a * b`.
- `transform.transformPoint(m, v)` applies `m` to a point (translation included);
  `transform.transformDirection(m, v)` applies only the linear part (no
  translation), useful for directions/normals.
- Quaternion helpers: `quatNormalize`, `quatMultiply`, `quatRotateVec3`,
  `quatFromAxisAngle`.
- `transform.approxEqual(a, b, epsilon)` compares matrices with an absolute
  tolerance (useful in tests; do not use as exact equality in gameplay logic).

## Scene API

### `Scene.computeWorldTransforms(gpa) Error!WorldTransforms`

Computes the world-space matrices of **all** live entities in a single **iterative**
O(n) pass (parents before children). It uses no recursion, so arbitrarily deep
hierarchies are safe (no stack-overflow risk). Entities without the `Transform`
component use the identity local transform. Requires the scene schema to contain
`Transform` (otherwise a compile error). The caller owns the snapshot and must
call `deinit`.

This is the recommended per-frame path: compute once after transforms change and
query many entities through `WorldTransforms.get`.

### `WorldTransforms` (snapshot)

- `matrices: []Mat4` and `entities: []Entity` — parallel dense arrays, ordered by
  **ascending stable ID** (determinism).
- `count() usize` — number of entities in the snapshot.
- `get(entity) ?Mat4` — world-space matrix for a handle present in the snapshot,
  or `null` for an absent handle.
- `deinit()` — frees the arrays and the index.

The snapshot is **frozen**: it is valid until the hierarchy or the local
transforms change; recompute to refresh. It is **generation-safe**: a recycled
slot with a new generation cannot read the previous entity's matrix (the new
handle is not in the snapshot). A handle that was alive at computation time keeps
returning its own frozen matrix even if the entity is destroyed afterwards —
that is the entity's own data, not another entity's.

### `Scene.worldMatrix(gpa, entity) Error!Mat4`

Convenience for a single entity: walks the parent chain up to the root and
composes top-down. It allocates a temporary chain buffer; for per-frame use over
many entities prefer `computeWorldTransforms`. Returns `error.EntityNotAlive` for
a dead handle. Requires `Transform` in the schema.

## Example

```zig
const corex = @import("corex");
const gpa = allocator;

var scene = try corex.scene.EngineScene.init(gpa, "main");
defer scene.deinit();

const root = try scene.createEntity("Root", null);
try scene.addComponent(root, corex.scene.Transform{
    .position = .{ 10, 0, 0 },
    .scale = .{ 2, 2, 2 },
});
const child = try scene.createEntity("Child", scene.idOf(root));
try scene.addComponent(child, corex.scene.Transform{ .position = .{ 1, 0, 0 } });

// Batch (recommended per frame):
var wt = try scene.computeWorldTransforms(gpa);
defer wt.deinit();
if (wt.get(child)) |world| {
    const origin = corex.scene.transform.transformPoint(world, .{ 0, 0, 0 });
    // origin == { 12, 0, 0 }  (root * child * origin)
}

// Single entity:
const m = try scene.worldMatrix(gpa, child);
```

## Guarantees and tests

- **Determinism**: the dense order is by ascending stable ID; identical snapshots
  for the same scene.
- **No recursion**: iterative topological evaluation with an explicit heap stack;
  a stress test with a 2000-level chain validates correct propagation without
  stack overflow.
- **Generation-safe**: recycled handles never read data from previous entities.
- **Identity for entities without Transform**: the entity inherits the parent's
  world transform.
- **Forward parent references**: parents defined after their children in the JSON
  are resolved correctly (two-pass resolution).
- **Memory safety**: allocation-failure paths are tested with
  `checkAllAllocationFailures` (no leaks). Snapshot initialization registers
  cleanup before any fallible allocation.
- **Parity**: `worldMatrix` (single) and `computeWorldTransforms` (batch) produce
  the same matrix for the same entity.

## Performance and usage

- `computeWorldTransforms` is O(n) in time and uses O(n) temporary memory (freed
  before returning), in addition to the snapshot arrays. Run it once per frame
  (or when transforms change) and query through `get`.
- `worldMatrix` is O(depth) and allocates a chain buffer; suitable for one-off
  queries, not for sweeping the whole scene every frame.
- The snapshot does not track changes automatically: if the scene changes,
  recompute. Change tracking is a future extension.

## Limitations and next steps

- There is no incremental/dirty-tracking cache between frames; each computation
  is complete.
- There is no support for multiple scenes or transform streaming in this
  increment.
- The renderer/editor will consume these matrices once implemented; this
  increment delivers only the math and the propagation in the scene system.

## Related

- Scene format: [scene-format.md](scene-format.md)
- Architecture: [architecture.md](architecture.md)
- Versioning: [versioning.md](versioning.md)
