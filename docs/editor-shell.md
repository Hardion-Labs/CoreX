# Editor Shell — CoreXEngine

The graphical editor's composition layer: one editor frame painted with the engine's
own GUI (`corex.gui`), over a session the startup pipeline already prepared. Code in
`src/editor/`, exposed as `corex.editor`.

> Status: **shell and editing model implemented and tested** (docks, hierarchy with
> keyboard navigation and sibling ordering, viewport with framing / orbit / zoom /
> click-to-select and a move-rotate-scale gizmo, inspector with editable name, transform
> and camera fields, status bar, command stack with undo/redo, dirty tracking, atomic
> save, headless frame renderer). The platform parts of an editor — a window, a swapchain,
> real input — are **not** implemented. This document says exactly where the line is.

## What the shell is

```
prepared session (scene + camera + assets)   ─┐
rendered surface (RGBA8, the renderer's own) ─┤─► editor.shell.draw ─► one editor frame
input frame + editor state                   ─┘
```

`editor.shell.draw(ctx, state, scene, history, frame, gpa) -> bool` paints a complete editor frame
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
(selection is a stable entity ID, so it survives handle recycling).

Rows come from the hierarchy's own model, `editor/tree.zig`, not from the paint loop:

- **Flat and caller-owned.** `tree.build(scene, list)` writes one `Row{id, depth}` per
  visible line into an array the caller provides; the panel paints that array. Nothing
  allocates, and painting cannot descend into a branch the window has cut off.
- **Bounded work.** The walk stops as soon as the window is full (plus one row, to know
  whether a "more..." hint is needed), so a scene with a hundred thousand entities costs
  the same per frame as one with ten.
- **Depth-limited.** `max_depth = 32` is checked while descending, so a corrupt parent
  chain cannot overflow the stack. The walk is recursive, but its depth is a constant.
- **Scrollable.** `State.tree_offset` is the first painted row; the wheel moves it by
  three rows and it clamps at both ends. Selecting an entity that is off screen
  (`tree.indexOf`, a bounded search) unfolds the chain above it and centres the window on
  it, so a selection restored by an undo or moved by a shortcut is never invisible.
- **Foldable.** A row with children draws a disclosure control (`>` / `v`) with its own
  hit area, registered before the row so clicking it folds instead of selecting.
  `tree.Collapsed` is a fixed inline set of up to 64 folded IDs: a full set **refuses a new
  fold** instead of evicting one, because silently unfolding a branch the user folded is
  worse than not folding. Folding is a view preference and never enters the history —
  undoing an edit must not also unfold the tree.

### Tree actions

The tree is an editing surface, not just a selector. Every action is one `tree.apply`
call, so a click, a key and a test take the same path and each one becomes **exactly one**
history command (one `Ctrl+Z` undoes exactly what one click did):

| Action | Where | Command |
| --- | --- | --- |
| add a child (or a root) | the panel's `+` control, `N` | `create`, named `entity`, selected afterwards |
| delete | `Delete` | `delete` |
| reparent | drag a row onto another row (or onto the blank area, for a root) | `reparent` |
| reparent to a root | `P` | `reparent` with a null parent |
| reorder among siblings | `move_up` / `move_down` | two `set_order` commands, so two `Ctrl+Z` |
| fold / unfold | the disclosure, `Enter` on a row with children | none (view only) |

Sibling order is **scene data**, not a view preference: `Scene` keeps an explicit `order`
key per entity (defaulting to the entity's own stable ID) and writes it into the document
only when it differs, so a reorder survives a save, a prefab capture and a streamed sector,
and a scene nobody reordered serializes exactly as it did before the field existed. That is
also why a swap is two commands rather than one custom inverse: undo restores both keys
exactly instead of guessing what the previous order was. The cost shows up one press early:
a single `Ctrl+Z` leaves the swapped pair holding the **same** key, which tie-breaks by ID
rather than restoring the previous order — so the first press can look like nothing happened,
while one explicit key stays in the document until the second press clears it.

### Drag and drop

Reparenting is also a pointer gesture: press a row, drag it, release it on another row —
or on the panel's blank area to make it a root.

- The gesture is a **value**, `tree.Drag` (`begin` / `end` / `cancel`), not a flag buried in
  a paint function, so "does this drop change anything?" is testable without a pointer —
  exactly like `step` and `apply`.
- A drop is resolved against the rects the rows were **actually painted at**, so the target
  is always the row the user saw under the pointer.
- A drop that cannot work records **no command**: releasing on the dragged row itself, on
  its own subtree (`tree.isAncestor`, checked *before* a command exists, so the history never
  holds an edit that would fail), on its current parent, or outside the panel at all (a
  release over the viewport abandons the gesture — it does not mean "root"). A direct
  `tree.apply(.{ .reparent = ... })` reports `ParentCycle` instead of silently doing nothing.
- What it *does* work as is an ordinary edit: one `reparent` command, one undo step, the
  dropped entity selected, and its new parent unfolded so the result is visible. A press
  that never moves is still a click, so selecting and dragging are the same gesture.
- The drag is visible: the dragged row's label is muted, the row under the pointer is
  outlined, and a row the drop would refuse is not outlined. `Escape` abandons the gesture.
- The disclosure arrow is **not** a drag handle: it is 8 px wide, and a drag from there would
  be a drag nobody meant. Pressing it presses the row too, so the gesture resolves anyway.

### Keyboard navigation

The arrow keys walk the tree by **visible line**, not by entity
(`tree.step(scene, rows, current, what, collapsed, limit)`): with folders, "the row under
this one" is not "the next entity in the scene".

| Key | Effect |
| --- | --- |
| `Down` / `Up` | next / previous visible row, skipping the hidden children of a folded branch |
| `Right` | unfold a folded branch; on an open branch, step into its first child |
| `Left` | fold an open branch; on a folded row or a leaf, step out to its parent |
| `Home` / `End` | first / last visible row of the **whole** tree, not of the painted window |
| `PageUp` / `PageDown` | one panel-full of rows (`list.visible`), clamped at both ends |
| `Enter` | fold / unfold the selected row |

Two details make it behave rather than nearly behave:

- **Fold state comes from the set, not from the painted row**, so a step works even when
  the current row is scrolled out of the caller's window; and `Down`/`Up` past the window
  fall back to a bounded walk of the whole tree (`indexOf` / `lineAt`) instead of stopping
  at the edge of the screen.
- **A step never enters the history.** Navigation and folding are view state; only create,
  delete and reparent record commands. The selection a step produces is scrolled into view
  by the same `revealSelection` a click uses.
- **Arrows in a text field are text keys.** The inspector holds the keyboard, so `Left` /
  `Right` move the caret and the tree selection does not move.

### Focus

`State.dock_focus` is which dock answers the keyboard; the focused dock is outlined in the
accent colour, because focus that is invisible is focus the user cannot use.

| Key | Effect |
| --- | --- |
| `Tab` | move focus to the next dock: hierarchy → viewport → inspector → hierarchy |
| `Shift+Tab` | the same order backwards |

All three docks are stops, because all three now answer keys: the hierarchy navigates and
edits, the viewport frames and orbits the camera, and the inspector's fields take text. A
dock that answered nothing would be a stop the user has to press `Tab` twice to get past,
which is why the viewport only became one once it had its own vocabulary. Clicking a field
in the inspector moves the dock focus with it, so the outline, the Tab order and what
actually receives keys never disagree.

`Tab` is handled **before** the "a text field holds the keyboard" gate: otherwise a focused
name field would be a place the user cannot leave. In the hierarchy, `N`/`P`/`Enter` and the
arrows act; in the viewport the arrows orbit and `F` frames; in the inspector they do not
(they are text keys there). The same key therefore means different things per dock — and
that is the point of having a dock focus at all. `Delete`, `Ctrl+Z` and `Ctrl+Y` are
dock-independent: they act on the selection and the history, which are the tree's and the
project's rather than a dock's.

A refused action is never silent: `tree.apply` returns the failure, and the status bar
shows it as `! ParentCycle` (or whichever error) for the frame instead of leaving the user
with a click that appeared to do nothing. A new entity is selected immediately and the
inspector reloads, so it can be named straight away; a new child under a folded parent
unfolds it, because the point of creating something is to see it.

Underneath it, each node's children come from `Scene.childIdsInto(parent, out)`, which:

- is **allocation-free** — a single scan of the scene's own records;
- writes **ascending stable IDs**, so the tree does not depend on hash-map visit order;
- keeps the **smallest** IDs when a node has more children than the buffer holds, and
  `Scene.parentIdOf(id)` answers a row's parent without resolving the parent entity;
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

### Keyboard framing and orbit

The viewport answers the keyboard, so the editor is usable without a pointer at all
(`src/editor/frame_camera.zig`, `corex.editor.frame_camera`):

| Key (viewport focused) | Effect |
| --- | --- |
| `F` | frame the whole scene |
| `Shift+F` | frame the selection |
| `Left` / `Right` | orbit left / right (yaw about world +Y) |
| `Up` / `Down` | orbit up / down (pitch about the camera's right axis) |

- **What gets framed.** `frame_camera.bounds` walks the scene's world transforms and
  returns the box containing every entity that has **both** a `Transform` and a
  `Renderable`, using the eight corners of the local unit box so a scaled mesh is framed by
  its real extent. Cameras and empties do not contribute: focusing the view frames what can
  be *seen*. `boundsOf(scene, id)` is the same for one entity, and an entity with no
  geometry still frames — as the point it occupies — because a user who selects a group and
  presses `Shift+F` wants to look at the group, not at nothing.
- **Where the camera goes.** `fit` keeps the authored **direction** and only moves the
  target to the box centre and the eye to `radius / sin(fov/2) * 1.15`, floored at
  `min_distance`. Keeping the direction is what makes repeated `F` presses stable instead of
  drifting; the margin keeps geometry off the frame edges.
- **Orbit** turns the view direction about the target: pitch about the camera's right axis
  first, then yaw about world +Y. Elevation is clamped to `±(π/2 − 0.02)` by clamping the
  **sine** and rescaling the horizontal part — a rotation-based clamp only approximates the
  limit and overshoots when pitch is applied in steps, which is exactly what key repeat does.
- **It is an ordinary edit.** The resulting transform goes onto the scene's first usable
  camera entity as **one** `set_component` through the history, so `Ctrl+Z` restores the
  camera the user had and the project is marked dirty like any other change. Nothing is
  stored outside the scene: reopening a project shows the camera it authored.
- **Honest failures.** A scene with no camera reports `NoCamera`; a scene with nothing to
  frame reports `NothingToFrame`; both appear in the status bar for the frame rather than
  moving the camera somewhere arbitrary. An invalid transform is refused before it reaches
  the history.
- **It starts from the screen, not from a default.** Each command re-reads the camera's
  placement from the scene (`viewOf`) and keeps the distance the editor last worked with,
  so an orbit after an inspector edit or an undo turns from what is actually on screen.

### Pointer gestures

The viewport answers the pointer as well as the keyboard, and — like `tree.Drag` — each
gesture is a **value** (`ViewportDrag`, `Gizmo`) the shell owns and the paint loop reads, so
"did this press mean a drag or a click?" is testable without a pointer.

| Gesture, with the pointer inside the viewport | Effect |
| --- | --- |
| press on nothing, drag | orbit the camera by the pointer's movement |
| press and release without moving past 2 px | select the entity under the pointer |
| wheel | dolly the camera in / out around the point it already looks at |
| press on a gizmo handle or ring, drag | move / rotate / scale the selected entity |

- **Click and drag are one press.** `ViewportDrag.end` is what says whether the pointer
  travelled far enough to have been an orbit, so the release resolves to "the orbit already
  happened" or "this was a click — pick something" instead of two handlers guessing.
- **Picking uses the camera the renderer used.** `pickEntity` un-projects the pointer through
  the inverse view-projection into a screen ray (`frame_camera.pickRay`) and tests it against
  each candidate's world box — the eight corners of the local unit box, the same box framing
  measures — taking the nearest hit. Only entities carrying **both** a `Transform` and a
  `Renderable` are candidates, so an empty or a camera cannot be clicked. No camera, a
  non-invertible matrix or a miss selects nothing rather than selecting whatever the view
  happened to hold first.
- **Zoom is an edit; a tool switch is not.** The wheel goes through the same `cameraCommand`
  as `F`, so it records one `set_component` and marks the project dirty, and
  `min_distance` keeps the eye out of its own target — a wheel at that floor changes nothing
  and records nothing.

### Gizmo

The selected entity gets a gizmo painted at its projected world position. Which tool is
active decides both what is painted and what a drag on it does:

| Key (viewport focused) | `GizmoMode` | Handles | A drag means |
| --- | --- | --- | --- |
| `W` | `.translate` | one arrow per axis, half a world unit long | displacement along that axis, on a plane facing the camera |
| `E` | `.rotate` | one ring per axis, 24 segments at radius 0.5 | the signed angle around that axis, measured from the press point |
| `R` | `.scale` | the same arrows, with larger tips | displacement along that axis, as a factor |

- **The keys are load-bearing.** They are the only way to reach `.rotate` and `.scale`, so
  the tools the shell can pick, paint and apply are also the tools the user can actually
  choose. The tool is viewport state (`State.setGizmoMode`): it survives a selection change,
  never enters the history and cannot dirty the project. Switching tools mid-drag abandons
  the drag, because a gesture that started as a move must not finish as a rotation.
- **Handles are picked in the pixels they were drawn in.** `pickGizmo` projects the axis tips
  and the ring segments through `projectToViewport` and takes the closest within 8 px by
  point-to-segment distance, so clicking *near* a handle is enough. A point behind the eye is
  dropped, not divided through onto the wrong side of the screen.
- **The drag writes live, the history records once.** Every frame `applyGizmoDrag` writes the
  new transform straight to the scene so the entity follows the pointer; the undoable
  `set_component` is recorded on release, and a press that never moved the axis records
  nothing. Each mode measures against the world transform captured at `Gizmo.begin`, so a
  drag cannot compound itself.
- **Rotate keeps its angle in range.** The angle is `atan2` of the cross and dot products of
  the start and current hit vectors around the axis, wrapped to `[-π, π]`, so a long drag
  cannot accumulate turns the user never made.

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

The **name**, **position** and **scale** are editable; rotation, the renderable handles,
the camera fov and the parent stay read-only.

Every editable field follows the same rule: **typing edits a buffer, Enter commits
through the history, Escape discards.** The buffer is what keeps a half-typed value out
of the scene; the history is what makes the commit one undoable step and marks the
project dirty.

- The **name** commits a `rename` command.
- **`pos`** and **`scale`** are rows of three numeric fields (`src/editor/inspector.zig`).
  A commit builds the *whole* `Transform` — the edited row plus the untouched one — and
  sends it as a **single** `set_component`, so `Ctrl+Z` steps back over the whole value
  the user changed and an axis they did not touch is never rewritten.
- A field that is not a number (`abc`, an empty box, `nan`, an overflow) commits
  **nothing**: the row reverts to what the scene holds, so the panel never claims a value
  the scene does not have. Leaving a field after editing it commits, the way a form does,
  so a typed value is not silently lost.
- The rows reload from the scene when the entity or the underlying values change (undo, a
  command, a selection change) but **never while the user is typing**.

Any focused inspector field holds the keyboard: the frame's shortcuts do not fire, so
`Delete` is a text key there and never "destroy the entity".

## Status bar

Project, scene, save state (`*` = unsaved), undo/redo depth (`u3 r1`), command/draw
count and the viewport size. The render numbers come from the renderer's own
`EngineFrameReport` and the depths from the history, so the bar cannot claim something
that did not happen. The text is **ASCII only**: the built-in font draws anything else
as `?`, which the first render of this bar made embarrassingly obvious.

## Editing model

`src/editor/edit.zig` (`corex.editor.edit`) is the layer that turns a read-only view
into an editor. It imports no GUI and no renderer: the shell drives it, and so do the
tests.

```
Command (a value)  ──apply──►  Scene          + an Entry {command, before} on the stack
                   ◄─undo───   restore(before)
```

**A command is a description, not a closure.** Six arms, all plain data:
`set_component`, `remove_component`, `rename`, `reparent`, `create`, `delete`. Each
names an entity by **stable ID** — not by the generational ECS handle, which gets
recycled — so a command recorded a frame ago still names the right entity.

**Undo is exact, by snapshot.** Before every edit the history captures the entity's full
prior state (name, parent, every schema component). Undo puts that state back. One rule
for all six commands instead of six inverse formulas, and it is what makes the hard case
right: undoing a **delete** restores the entity with its **original stable ID**, its
parent and all its components, so a selection (or an older command) still resolves
afterwards. A schema is the single source of truth — `History(Scene).ComponentValue` is
a comptime union with one *typed* arm per schema component, so a value travels with its
real type instead of as a byte blob.

What the model guarantees, each point covered by a test:

- **Failure changes nothing.** An invalid command records no entry and leaves the scene
  alone; a scene-level failure mid-apply is rolled back from the snapshot taken just
  before, so the scene is never half-edited.
- **`undo` and `redo` allocate nothing** (measured with a counting allocator), which is
  what makes it safe to bind them to a key press inside a frame.
- **A new edit discards the redo tail** — the undone future is unreachable and its
  memory is released.
- **Saving never clears the stacks.** `markSaved` clears the dirty flag only.
- **Redo keeps the original snapshot**, so undo after redo restores the same state.

### Saving

`edit.saveScene(history, scene, io, dir, path, gpa)` stages the serialized document in a
dot-prefixed sibling and renames it over the target. `Scene.save` writes in place, which
is right for a library call and wrong for an editor: a crash mid-write would destroy the
user's only copy. With the staged rename the file on disk is the old project or the new
one, never a truncated mix. A failed save leaves the project **dirty** — "retry the
save" has a meaning only if the flag is honest.

### Shortcuts

Handled once per frame, after the panels are painted, and skipped while a text field
holds focus:

| Key | Action |
| --- | --- |
| `Ctrl+Z` | undo |
| `Ctrl+Y`, `Ctrl+Shift+Z` | redo |
| `Delete` | delete the selected entity (undoable) |
| `Escape` | clear the selection |

`Delete` and `Escape` act on the **selection**, so they are not scoped to a dock: they work
from any dock that is not a text field (where `Delete` is a text key and `Escape` reverts
the field).

They are a convenience over `shell.undo`/`redo`/`deleteSelected`, which are the same
functions a menu or a test calls — the shortcuts add no behaviour of their own. A
selection whose entity no longer resolves (undoing a create, redoing a delete) is
dropped rather than left pointing at nothing.

## Headless frame renderer

```bash
zig build editor-frame -- examples/hello-project/HelloProject.corex out.qoi [selected-id] [dirty]
```

The tool passes a real `edit.History`, so the preview's status bar shows the same save
marker and undo depth a session would; the optional `dirty` argument sets the marker.

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
- **Rotation is edited as Euler degrees.** The row shows `quatToEuler` (roll / pitch / yaw,
  pitch clamped to ±90 for the gimbal-lock singularity) and writes back through
  `quatFromEuler`, which normalizes: an edit round-trips the *orientation*, not the exact
  authored quaternion. A quaternion widget (four fields, or a draggable arc) is the open
  question, not the history — `set_component` already carries any component.
- **No scrub/drag on numeric fields.** Values are typed; a drag-to-scrub affordance needs
  pointer-drag state the GUI can already report, but it is a separate interaction.
- **The history is in-memory and per-session.** It is not persisted, and there is no
  "reopen and undo" — deliberate for now.
- **No multi-select, no copy/paste, no grouping.**
- **No drop *between* rows and no drop onto the panel title.** A drag reparents ("be a
  child of this node") or roots ("be a root"). Ordering siblings is `move_up` / `move_down`
  instead, because a drop between rows would need a boundary to land on and an 8 px row has
  none to hit.
- **The gizmo and the pick are screen-space approximations.** A handle is found by distance
  to a projected segment, the drag plane faces the camera, and a click selects an entity by
  its **unit box** rather than its mesh triangles — so a wide flat mesh is picked by a box
  taller than it looks, and geometry outside that box cannot be clicked. There is no snapping,
  no drag-across-the-edge auto-scroll, and the handles shrink with the view instead of keeping
  a fixed size on screen.
- **No focus ring on individual fields.** The outline marks the dock; the field inside it
  draws its own border when focused.
- **No multi-select in the tree.** One selected entity, so a gizmo drag and every edit act on
  one entity at a time. Reordering reaches only the first 64 siblings of a parent (the window
  `childIdsInto` fills): a row outside it has no neighbour inside to swap with, and the action
  reports "nothing changed" rather than moving rows the user cannot see.
- **No inline rename in the tree.** Renaming goes through the inspector's name field.
- **Fold state is not persisted.** It lives in `shell.State`, so reopening a project
  starts unfolded.
- **One camera.** Framing moves the scene's first usable camera (the one the renderer
  would use). Multi-camera switching is out of scope for now.
- **Fixed dock widths, no resizable splitters, no docking/re-docking.**
- **One viewport, one scene.** Multi-scene editing and tabs are out of scope for now.
