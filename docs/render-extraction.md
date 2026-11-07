# Backend-Independent Render Extraction — CoreXEngine

This document describes CoreXEngine's render extraction layer: the
**backend-independent** (CPU) foundation every renderer tier (Low/Medium/Advanced)
will consume. The code lives in `src/render/` and is exposed as `corex.render`.

> Status: **extraction layer implemented and tested**. The Low/Medium GPU backends
> and the Advanced contract are still planned; no GPU backend has been chosen.
> This layer has no GPU dependency, so it runs and is fully tested headlessly. It
> consumes world-space transforms ([scene-transforms.md](scene-transforms.md))
> and, in the future, `CXTX` texture artifacts
> ([asset-decoders.md](asset-decoders.md)).

## Overview

Extraction turns a scene + camera into a **draw list** ready for the GPU backend:

```
scene (Transform + Renderable) ──► world transforms (O(n) snapshot)
                               ──► world AABB per renderable
                               ──► frustum culling
                               ──► sorted DrawCommands ──► GPU backend
```

It is pure CPU work, reusing the scene's world-transform snapshot and the ECS view
iteration — low coupling and cache-friendly.

## Math conventions

- **Column-major** `Mat4` matrices (`m[c*4+r]`, the same as
  [scene-transforms.md](scene-transforms.md)).
- **Right-handed** system; the camera looks down **-Z**.
- OpenGL-style clip space: NDC with `z ∈ [-1, 1]` (near → -1, far → +1).
- `clip = projection * view * world` (column vector).

## Camera (`corex.render.camera`)

- `perspective(fov_y, aspect, near, far)` — perspective projection (vertical fov in
  radians; `near < far`, both positive).
- `orthographic(left, right, bottom, top, near, far)` — orthographic projection.
- `lookAt(eye, target, up)` — view matrix; `eye == target` (the degenerate case)
  returns identity.
- `Camera` — combines `view`, `projection`, `view_projection` (= `projection *
  view`) and `position` (the eye, used for depth sorting).
  `Camera.perspectiveLookAt(...)` is a convenience constructor.

## Culling (`corex.render.culling`)

- `Aabb { center, extents }` — an aligned box by center + half-extents;
  `fromMinMax`, `min`, `max`.
- `Sphere { center, radius }`.
- `Plane { normal, d }` — inside when `dot(normal, p) + d >= 0`; normalized so
  `distanceToPoint` is a signed Euclidean distance.
- `Frustum.fromMat4(view_projection)` — extracts the 6 normalized planes
  (Gribb–Hartmann): left/right/bottom/top/near/far.
- `Classification { outside, intersecting, inside }`.
- `Frustum.classifyAabb` / `classifySphere` — a conservative test: `outside` only
  when fully outside some plane (safe to discard).
- `transformAabb(m, b)` — conservatively transforms a local AABB into world space
  (Arvo's method): transforms the center and scales the extents by the absolute
  values of the linear part; it bounds the box under rotation and non-uniform
  scale.

## Draw list (`corex.render.draw`)

- `Renderable { mesh, material, bounds }` — a **plain-data** scene component
  (opaque handles + a local AABB). Add it to a schema with
  `Component(Renderable, "renderable")`; it serializes like any component.
  `isValid` rejects non-finite bounds or negative extents.
- `DrawCommand { entity, mesh, material, world, bounds, depth }` — one visible draw
  call, self-contained (it carries the world matrix and world bounds), so the draw
  list outlives the transient transform snapshot.
- `SortMode`:
  - `front_to_back` — nearest first (good for opaque geometry / early-z).
  - `back_to_front` — farthest first (required for alpha blending).
  - `by_material` — groups by material, then mesh (minimizes state changes).
  Ties are broken by `entity.key()` for **determinism**.
- `RenderFrame { commands, culled }` — a sorted draw list plus culling diagnostics;
  the caller owns it and calls `deinit`.
- `extractDrawList(scene, cam, mode, gpa)` — generic over any `*Scene(schema)` with
  `Transform` + `Renderable`. Computes the world-transform snapshot once, culls each
  renderable's world AABB and sorts the survivors. Fails only on allocation (the
  scene is already valid).

## Example

```zig
const corex = @import("corex");
const R = corex.render;

const MyScene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(R.Renderable, "renderable"),
});

var scene = try MyScene.init(gpa, "main");
defer scene.deinit();
const e = try scene.createEntity("cube", null);
try scene.addComponent(e, corex.scene.Transform{ .position = .{ 0, 0, 0 } });
try scene.addComponent(e, R.Renderable{ .mesh = 1, .material = 2 });

const cam = R.Camera.perspectiveLookAt(
    .{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 },
    std.math.pi / 3.0, 16.0 / 9.0, 0.1, 500,
);
var frame = try R.extractDrawList(&scene, cam, .front_to_back, gpa);
defer frame.deinit();
// frame.commands[i].world / .mesh / .material are ready for the GPU backend.
```

## Guarantees and tests

- **Camera math**: near/far map to NDC -1/+1; `lookAt` puts the eye at the origin
  and objects in front have negative view-z; the degenerate case returns identity.
- **Frustum**: the identity matrix yields the NDC cube `[-1,1]^3`; a real
  perspective camera discards what is behind, to the side and beyond the far plane.
- **Classification**: inside/intersecting/outside for AABBs and spheres;
  `transformAabb` bounds all 8 corners under rotation (explicitly verified).
- **Extraction**: an empty scene → an empty frame; an off-screen object is
  discarded (`culled`); an entity without `Renderable` is not drawn; the world matrix
  reflects the hierarchy; front/back and by-material sorting are correct;
  **determinism** for identical scenes; scaled bounds still cull correctly.
- **Memory safety**: a `checkAllAllocationFailures` probe on extraction with no
  leaks; explicit allocators; ownership documented.

## Performance

- Reuses the O(n) world-transform snapshot (one pass per frame).
- AABB culling is O(1) per renderable (6 planes); only visible ones become
  `DrawCommand`s.
- Sorting uses `std.mem.sort` with a total order (ties broken by `entity.key()`), so
  the result is deterministic regardless of sort stability.
- `DrawCommand` is plain data and self-contained, cache-friendly for the backend.

## The reusable frame buffer

`RenderFrame` is the frame-loop shape of the same extraction: two command buffers
(`active`/`spare`) plus the current `commands` view.

```zig
var frame = try R.draw.RenderFrame.init(gpa);
defer frame.deinit();

const result = try frame.refill(&scene, cam, .front_to_back); // { culled, changed }
// frame.commands is the sorted list for this frame; a steady-state frame
// allocates nothing.
```

`refill` extracts into the spare buffer, compares it with the active one and swaps,
so `changed` answers "is this frame different from the last one?" without the caller
comparing lists. The comparison is **field by field** (`commandsEqual`), not a byte
compare: `DrawCommand` has padding the compiler may leave undefined, so a byte
compare reports a change between two frames identical in every field that is read.

### Where a frame's memory comes from

Extraction needs a world-transform snapshot per frame: two arrays, two lookup maps
and three work arrays, all thrown away before it returns. Those come from a
**scratch arena** owned by `RenderFrame` and reset once per `refill`
(`extractIntoScratch(list_gpa, scratch)`), while the draw-list buffers stay in the
general-purpose allocator because they persist across frames. `refill` then reports
`allocated_last_frame`: false means the frame asked the general allocator for
nothing. A counting-allocator test asserts exactly that (0 calls, 0 bytes), and the
positive case — a scene that grows — simply grows the arena.

Two consequences worth knowing:

- A frame reaches its steady state after **two** passes, because `refill` extracts
  into the spare buffer: both buffers must have grown once. That is the price of
  comparing this frame with the last, paid twice per session.
- `changed` (content) and `allocated` (memory) are independent facts. A frame can be
  identical in content and still allocate once while a buffer grows to the size the
  scene now needs.

## Authoring and driving a frame

`corex.scene.render_scene` (see [scene-format.md](scene-format.md) for the file
format) is the piece that connects a project to this layer:

- `EngineRenderScene` — the scene schema with `transform` + `renderable` + `camera`.
- `planSlots(gpa, asset_index, capacity)` — the deterministic path → table-slot
  layout; `handleOf(path)` is the handle a `.scene` stores, computable without
  loading any bytes.
- `loadAssets(gpa, io, project_root, index, options)` — loads what the plan placed:
  `.mesh` artifacts and `.obj` sources become meshes, `.png`/`.bmp`/`.tga`/`.qoi`
  become textures; each mesh slot also gets a white base colour, so a mesh's own
  handle is a valid material. Source bytes are released as soon as a slot is filled —
  a mesh is copied into the table's scratch, a texture keeps its level-0 pixels plus a
  generated mip chain — so a session does not hold the files it decoded. `AssetReport`
  counts `meshes`, `textures`, `mipmapped`, `skipped` and `evicted`.
- `LoadedAssets.evict(path)` — release one asset's slot and pixel blocks. The slot
  keeps its place in the path map (the layout is a property of the project, so a
  reload lands in the same slot), but it stops resolving: `release` bumps the
  generations, so every handle into it is dead. Eviction is explicit, not an automatic
  budget; `uploadedBytes()` reports the footprint before and after.
- `EngineRenderer.render(surface, scene, camera, view, resources, params)` — one
  frame through `RenderFrame.refill` + `pipeline.renderFrame`; the projection comes
  from the surface's aspect, so resizing reframes.
- `EngineRenderer.findCamera(scene, gpa)` / `renderSceneFrame(scene, dimensions,
  resources, params)` — the headless frame path the binary drives: find the scene's
  camera, size and clear a surface, render, report. Returns null when the scene has
  no camera.

## Limitations and next steps

- There is no GPU backend yet (Low/Medium/Advanced are planned). Extraction itself
  only produces the draw list; the CPU software rasterizer in
  [render-raster.md](render-raster.md) consumes it and writes pixels.
- No LOD, occlusion culling, instancing or automatic batching; `by_material` only
  sorts to reduce state changes.
- `Renderable` uses opaque mesh/material handles. The software rasterizer resolves
  them through a caller-supplied duck-typed provider, and `render_scene` fills that
  table from the project's assets, with mip chains generated at upload. We have no GPU
  yet, so "upload" means copying into CPU scratch; there is no VRAM residency, no
  texture budget and no automatic (LRU/budgeted) eviction — `evict` is a call the
  caller makes.
- One `Renderable` per entity, one mesh per draw: no instancing, no multi-material
  meshes, and a texture is addressed as the material of the slot it was loaded into.
- No per-object transparency beyond `back_to_front` sorting; transparent/opaque
  materials are not yet split into sublists.

## Related

- Software rasterizer: [render-raster.md](render-raster.md)
- World-space transforms: [scene-transforms.md](scene-transforms.md)
- Texture decoders / CXTX: [asset-decoders.md](asset-decoders.md)
- Architecture: [architecture.md](architecture.md)
- Versioning: [versioning.md](versioning.md)
