# GUI Foundation — CoreXEngine

This document describes the engine's own GUI library: the built-in layer the
graphical editor will be built on. It is exposed as `corex.gui` and lives in
`src/gui/`.

> Status: **foundation implemented and tested** (font, canvas, text, layout,
> widgets, theme, input + a headless frame renderer). The editor itself, a window
> backend and text shaping are still planned; nothing here needs a window to run,
> which is what makes the layer verifiable in CI and in a terminal-only sandbox.

## Why a built-in GUI

The engine ships its own font, canvas and widgets for three reasons:

1. **No platform dependency.** A system font, a text stack (HarfBuzz/FreeType) or
   a widget toolkit would each be a new external contract that the launch contract
   and the export pipeline would have to carry. A bitmap font and an RGBA8 canvas
   are data, not dependencies.
2. **The pixel format is already the engine's.** The canvas is row-major,
   top-down, 4 bytes per pixel — exactly `assets.image.Image.pixels` and
   `raster.Target.color`. A GUI frame composites onto a rendered scene with no
   copy and no conversion, and encodes straight to QOI/PNG with the existing
   `assets.image` encoders.
3. **Testability.** Everything below the widget layer is pure integer arithmetic
   over a caller-owned buffer, so a frame can be produced, diffed and inspected
   without a swapchain. `zig build gui-frame` renders one such frame.

## Layer map

```text
theme ──┐
font ──► text ──► canvas
        │          ▲
layout ─┴──► widgets ──► (editor shell, planned)
             input ──┘
```

| Module | Responsibility |
| --- | --- |
| `gui.font` | Built-in 8x8 bitmap font: printable ASCII 0x20–0x7E, measurement |
| `gui.text` | Drawing text on a canvas: newlines, integer scale, clipping |
| `gui.canvas` | `Color`, `Rect`, `Point`, RGBA8 `Canvas` with clipped primitives |
| `gui.layout` | `Size`, `Padding`, stacking `Layout`, text measurement |
| `gui.input` | One frame of input: pointer, buttons, wheel, text, keys |
| `gui.theme` | Colours and metrics for the built-in widgets (dark + light) |
| `gui.widgets` | Immediate-mode `Context`, `Id`, `Entry`, `panel`, `label`, `button`, `checkbox`, `slider`, `textField` |

## Font (`gui.font`)

A data table plus pure lookup: no allocation, no I/O, no platform call.

- Glyphs are 8 bytes (one per row, MSB = leftmost pixel), authored on a 6x7 grid
  inside the 8x8 cell.
- `cell_width = 6`, `line_height = 8`, `glyph_height = 7`; the descender row is
  always empty, so a line never bleeds into the one below.
- `measure(text)` is the **advance**, not a fixed cell grid:
  `(len - 1) * cell_width + inkWidth(last)`. A trailing space has no ink but still
  advances by `cell_width`, so a padded label measures wider than the bare one.
- `inkWidth(cp)` is the inked column count of one glyph (`0..6`); space is 0.
- Anything outside the table (including control bytes and all non-ASCII) renders
  as `fallback = '?'`. That is the honest behaviour until real shaping exists.

Scope is deliberately ASCII only: no kerning, no ligatures, no bidi, no grapheme
clusters. Nothing here claims otherwise.

## Canvas (`gui.canvas`)

- `Color = [4]u8`, straight-alpha RGBA8 — the same encoding as `raster`.
- `Rect { x, y, w, h }` is position plus **extent**, with non-inverting slices
  (`sliceTop`, `sliceBottom`, `sliceLeft`, `sliceRight`, `below`, `after`) and
  `intersect`/`inset`/`offset`/`contains`/`containsRect`/`intersects`.
- `Canvas.init(width, height, pixels)` borrows a caller-owned buffer and rejects a
  short one. Every primitive is **allocation-free and clipped**: a rect that runs
  off the edge writes only the part inside, a zero-size canvas writes nothing.
- `fillRect`, `fillOutside` (the dimming pass a modal uses), `strokeRect` (drawn
  **inside** the rect, so adjacent boxes share an edge without overlapping),
  `hline`, `vline`, `plot`, `blit`.
- Compositing is straight-alpha source-over quantized once per channel. A fully
  opaque colour is an exact store, so an opaque GUI over a scene writes exactly
  the colour asked for; alpha 0 is an exact no-op.
- `shade(base, percent)` rounds half up (`shade(white, 50) == 128`), because a
  hover tint that drifts a level darker than half is a visible seam.

## Text (`gui.text`)

`draw(canvas, x, y, text, .{ .color, .scale, .clip })` paints a block of text and
returns the height it consumed. `\n` starts a new line; `scale` is an integer
block expansion (2 = every glyph pixel is a 2x2 block); `clip` keeps a label
inside its widget even when it is wider than the space. `width`/`height` measure
the same way `draw` paints. No wrapping: a line that does not fit is clipped.

## Layout (`gui.layout`)

- `Size` with `max`/`min`/`padded`/`clamped`, and `Padding` with `all`,
  `symmetric`, `add`, `sub` and `apply` (never inverts a rect).
- `Layout.init(rect, .vertical | .horizontal)` is a forward-only cursor:
  `measure(size)` returns the next slot and advances, `remaining()` reports what is
  left, `fillRemaining()` consumes it, `reset()` rewinds. A slot larger than the
  space left is **truncated**, never inverted, so a widget cannot spill over its
  neighbour even when a caller asks for too much.
- `textSize(text, scale)` measures exactly what `text.draw` paints.

## Input (`gui.input`)

One frame's worth of events, already resolved into the questions a widget asks:
`pointer`, `pointer_in_window`, `pointer_down`, `pointer_pressed`,
`pointer_released`, `wheel`, `text`, `key`, `modifiers`. `endFrame()` clears the
one-frame events and keeps held state. Widgets never see a platform event, so the
whole layer is testable headlessly and the (still blocked) window binding stays
outside the widget code.

## Widgets (`gui.widgets`)

Immediate mode: a `Context` holds the canvas, theme, input and the hit-test
tables; a widget takes `(ctx, id, rect, value)`, paints itself, and returns a
`Response { rect, hovered, pressed, clicked, focused, owns_pointer, blocked, changed }`.

Available: `panel` (returns the content rect inside its border and title bar),
`label`, `button`, `checkbox`, `slider`, `textField` (operates on a caller-owned
fixed buffer, never reallocates).

### Identity

`Id.from(seed, name)` hashes a caller seed with a name using Wyhash. The same
button therefore keeps its hot/active/focus state across frames without the caller
allocating anything or keeping a pointer to a widget object. Distinct seeds keep
two identically-named widgets apart.

### Pointer ownership and paint order

The GUI paints back-to-front, so the widget that must **win** the pointer is the
one painted **last** (on top). Which one that is is only known once the frame is
built, so the resolution is done against the **previous** frame:

1. Each widget calls `ctx.interact(id, rect)`, which records its rect in the
   frame's table (`next`).
2. At `beginFrame`, the pointer is looked up in the previous frame's table
   **from the end**, so the topmost reachable widget containing the pointer
   becomes `hot`. Everything else that contains the pointer is `blocked`.
3. `endFrame` publishes the frame's table.

The consequence is one frame of latency on hover: a fresh GUI needs one frame
before the pointer can hit anything, and a widget only reports `hovered` from the
frame after it first painted. A window pipeline draws its first frame before any
input arrives, so this costs nothing in practice; a headless renderer just draws
two passes (`tools/gui_frame.zig` does exactly that).

`blockBelow(rect)` declares a rect an overlay: widgets painted **before** it that
it covers stop being reachable, while widgets painted **after** it (its own
children, or a control lying entirely inside it) stay reachable. That is what lets
a modal dialog block the panel behind it without disabling its own controls.

A click fires on **release inside the widget that was pressed**, so dragging off a
button cancels it. A slider keeps following the pointer outside its own row while
the button is held, and pins at both ends of its range.

## Headless frame rendering

```bash
zig build gui-frame -- frame.qoi      # 220x132, one frame of real widgets
```

`tools/gui_frame.zig` paints a panel with a label, a two-button row, a checkbox, a
slider and a text field through the same calls an editor sidebar will make, then
writes the frame as QOI (`assets.image.encodeQoi`, already supported by the
decoder). It is the GUI's smoke test and its visual reference.

## Limitations

- **No window, no swapchain.** `std`'s windowing is not available in this
  environment (no X11 headers, no `DISPLAY`), so the host side of `Input` and the
  presented surface are the caller's job. The canvas is exactly the buffer a
  window backend would present.
- **No text shaping.** ASCII bitmap glyphs only; a proportional face, kerning or
  non-Latin scripts would need a glyph cache and a shaping step.
- **No wrapping, no multi-line editing.** A text field is single-line and clips.
- **No keyboard focus traversal yet.** `Context.focus` can be set by the host (and
  Tab is reported in `Input.key`), but automatic Tab order is the editor's job and
  is not implemented here.
- **Fixed-capacity hit-test tables.** A frame records at most `entries.len`
  widgets; extras are dropped rather than allocated. `remainingSlots()` reports it.
- **No scrolling.** `Layout` reports the space it did not consume
  (`remaining`/`fillRemaining`) and `Input.wheel` carries the delta, but the scroll
  offset, its clamping and a scrollbar widget are not implemented.
- **No 3D/no nine-slice/no images in widgets.** `canvas.blit` exists; no widget
  uses it yet.
