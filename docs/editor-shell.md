# Editor Shell — CoreXEngine

The graphical editor's composition layer: one editor frame painted with the engine's
own GUI (`corex.gui`), over a session the startup pipeline already prepared. Code in
`src/editor/`, exposed as `corex.editor`.

> Status: **shell implemented and tested** (docks, hierarchy, viewport, inspector,
> status bar, headless frame renderer). The platform parts of an editor — a window, a
> swapchain, real input, and *editing* with undo — are **not** implemented. This
> document says exactly where the line is.

## What the shell is

```
prepared session (scene + camera + assets)   ─┐
rendered surface (RGBA8, the renderer's own) ─┤─► editor.shell.draw ─► one editor frame
input frame + editor state                   ─┘
```

`editor.shell.draw(ctx, state, scene, frame) -> bool` paints a complete editor frame
into the GUI context's canvas and returns whether the selection changed. It owns no
scene, no renderer and no surface: everything is borrowed for the duration of the
frame. That is what lets the same call serve a headless tool (`zig build
editor-frame`), a test, and — once the window layer exists — a windowed shell, with no
reimplementation in between.

![Editor frame rendered headlessly by the shell](../editor-frame-preview.png)

## Docks

`Dock.compute(canvas_rect)` splits the canvas once per frame into the hierarchy (left),
the viewport (centre), the inspector (right) and the status bar (bottom). The rules are
deliberate:

- Both side panels are **fixed width** (`side_width = 150`). A panel that scales with
  the window makes every label jump, and this surface is text-heavy.
- A panel is admitted only if a viewport of at least `min_viewport_width = 60` still
  fits beside it: both panels, then the hierarchy alone (it is what the user navigates
  with), then neither. **The viewport never disappears** — an editor without one is not
  an editor.
- The docks tile the canvas with no gap and no overlap, which the tests assert.

## Hierarchy

One row per entity, depth-first from the roots, indented by depth, clickable to select
(selection is a stable entity ID, so it survives handle recycling). Rows come from
`Scene.childIdsInto(parent, out)`, which:

- is **allocation-free** — a single scan of the scene's own records;
- writes **ascending stable IDs**, so the tree does not depend on hash-map visit order;
- never overflows `out`, and when a node has more children than fit it keeps the
  **smallest** IDs, so the visible prefix is deterministic.

`Scene.rootIds` is now defined in terms of the same function, so the two cannot drift.

The row budget (`State.rows_per_frame`, default 24) bounds how much of a large scene one
frame paints; a "more..." hint is shown when it is reached. Scrolling is a later step
(see *Limitations*).

## Viewport

The scene is rendered by the engine's own renderer into an RGBA8 surface — the exact
buffer `raster.Target.color` and `backend.Surface.color` describe — and the shell
samples it into the viewport rect with `Canvas.blitScaled`: nearest-neighbour, clipped
to the destination *and* the canvas, so a viewport smaller than the render is a
downsample of the whole frame rather than a crop, and nothing spills over the panels.

`editor.shell.projectToViewport(view_projection, world, rect)` maps a world position to
a viewport pixel using the **same** matrix the renderer used, so a marker lands on the
pixels the entity was drawn at. A point at or behind the eye (`w <= 0`) or outside the
clip volume returns `null` instead of being divided through onto the wrong side of the
screen.

## Inspector

Name, stable ID, local transform position/scale, the renderable's mesh/material
handles, the camera's field of view, and the parent — read from the scene, never
copied. Values are clipped to their own rect so a long name cannot run into the next
column. With nothing selected the panel says so; an entity with no components still
shows its name, ID and parent.

**The inspector is read-only in this cycle.** Editing needs an undo/redo model, dirty
tracking and write-back to the `.scene` format; bolting a half version of that onto a
read-only panel would be exactly the kind of speculative work this project avoids, so
it is the next coherent step instead.

## Status bar

Project, scene, command/draw count, thousands of pixels and the viewport size — every
number comes from the renderer's own `EngineFrameReport`, so the bar cannot claim
something the renderer did not do. The text is **ASCII only**: the built-in font draws
anything else as `?`, which the first render of this bar made embarrassingly obvious.

## Headless frame renderer

```bash
zig build editor-frame -- examples/hello-project/HelloProject.corex out.qoi [selected-id]
```

`tools/editor_frame.zig` runs the documented startup pipeline (`startup.run`) to
prepare the session, loads the project's render assets, renders one frame of the scene
through `EngineRenderer`, paints the editor around it, and writes the result as QOI
(readable by `assets.image.decodeQoi`, and by any viewer). It draws two passes because
the GUI resolves hit-testing against the previous frame; that is the GUI's documented
behaviour, not a workaround.

## Limitations

- **No window, no swapchain, no real input.** Blocked in this environment (no X11
  headers, no `DISPLAY`). The shell paints into a caller-owned buffer; wiring it to a
  window is `present()` of that same buffer.
- **Read-only inspector.** No editing, no undo, no dirty tracking, no save.
- **No scrolling in the tree.** Beyond `rows_per_frame` the hierarchy shows a hint;
  the row budget is a bound, not a scroll model.
- **No drag/drop, no viewport camera controls, no gizmos.** The camera is whatever the
  scene authors.
- **No keyboard focus traversal.** Clicking a row selects; Tab order is not
  implemented (the GUI layer reports Tab, nothing consumes it yet).
- **Fixed dock widths, no resizable splitters, no docking/re-docking.**
- **One viewport, one scene.** Multi-scene editing and tabs are out of scope for now.
