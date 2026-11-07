# Presentation — the owned frame surface and the loop

Status: `src/runtime/presentation.zig`, re-exported as `corex.runtime.presentation`.
Implemented: the frame-sized target a loop owns, and a bounded headless frame loop.
Planned: a window, a swapchain, vsync and input — all of which need a platform
library and none of which are faked here.

## Why this layer exists

Rendering one frame is not a loop. The engine binary used to allocate colour and depth
for a single frame, draw it, report the accounting and exit — enough to prove the
pipeline, but it freed the two largest buffers in the engine immediately afterwards and
threw away the renderer's reusable draw list with them. A loop cannot work that way:
resizing, clearing and (eventually) presenting are per-frame operations on the *same*
buffers, and reallocating them per frame would undo the per-frame allocator hand-off
that already exists inside the renderer.

So this layer owns exactly two things and nothing else:

| Type | Owns | Reallocates |
|---|---|---|
| `SurfaceTarget` | colour (RGBA8) + depth (`f32`) | only when the size actually changes |
| `FrameLoop` | the target, the `EngineRenderer`, one scratch arena, the run report | only during the warm-up |

Deliberately **not** here: windows, swapchains, event queues, vsync, input. Inventing an
abstraction for them before a platform library exists would be speculative code, and
the scope document is explicit that subsystems are added when they have real content.

## `SurfaceTarget`

```zig
var target = try corex.runtime.SurfaceTarget.init(gpa, 1280, 720);
defer target.deinit();

_ = try target.resize(1920, 1080); // true: the buffers were reallocated
_ = try target.resize(1920, 1080); // false: same size, nothing happened

target.clear(.{ 0, 0, 0, 255 }, 1.0); // caller's one clear per frame
const surface = target.surface();     // borrowed BackendSurface
```

- Colour is `width * height * 4` bytes and depth is `width * height` `f32` — exactly the
  layout `render.backend.Surface` validates, so the target is what a backend writes and
  never a conversion of it.
- `resize` allocates both buffers **before** replacing either, so a failure (allocation
  or a rejected size) leaves the previous frame intact and still renderable. A resize
  that cannot be honoured must not destroy the frame the caller already has.
- Zero-sized and oversized (> `raster.max_dimension`) requests are refused rather than
  accepted: a zero-pixel surface is what a minimised window reports, and rendering into
  it would make every pixel count meaninglessly zero.
- `clear` is explicit and is the only clear per frame. The render contract says the
  rasterizer never clears on its own, and folding it into `render` would cost a full
  surface pass on frames whose depth is already at the far plane.

## `FrameLoop`

```zig
var loop = try corex.runtime.presentation.FrameLoop.init(gpa, tier, width, height);
defer loop.deinit();

const report = try loop.run(scene, resources, 120);
// report.frames, report.empty_frames, report.allocating_frames, report.last
```

`run` renders `count` frames of the same scene and reports:

- `frames` — frames actually rendered;
- `empty_frames` — frames the loop declined to draw because the scene authors no camera
  (it stops there rather than repeating an answer that cannot change);
- `allocating_frames` — frames that had to ask the general-purpose allocator for
  memory. After the warm-up this is **0**;
- `last` — the final frame's `EngineFrameReport`.

Two properties make the loop usable rather than merely present:

1. **Steady-state frames allocate nothing.** The surface is allocated once, the draw
   list grows once in each of its two buffers, and the two per-frame arenas
   (`RenderFrame`'s extraction scratch and the loop's camera scratch) are reset, not
   reallocated. Measured on the shipped example:

   ```console
   $ corex-engine --project examples/hello-project/HelloProject.corex --headless --frames 120
   Frames: 120 of 120 (2 allocating) at 1280x720 medium — last frame: 1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled
   ```

   Two allocating frames, not 120: one per draw-list buffer. A steady-state frame takes
   no allocation at all, which a counting-allocator test asserts as 0 calls / 0 bytes.

2. **The same scene produces the same pixels.** A reused buffer must not leak state from
   one frame into the next, so a test renders five identical frames and compares the
   colour buffer byte for byte, then moves the quad and asserts the image changed.

The camera is located through `EngineRenderer.findCamera`, which resolves a world matrix
and therefore needs a transform snapshot. That snapshot is dead before the frame is
drawn, so the loop owns a `camera_scratch` arena for it and resets it once per frame —
without that, locating the camera would allocate on every single frame.

## Wiring: `--frames`

The launch contract gained one option (`docs/launch-contract.md`):

| Option | Value | Meaning |
|---|---|---|
| `--frames` | integer > 0 | Frames to render before exiting. Default: `1` (the previous behaviour). |

A bounded count is the honest form of "run for a while" while nothing can stop the
loop — there is no window to close and no input to read. `validate` still prepares no
session and renders nothing; `--frames 0` is a usage error (exit code 2).

## Limitations and next steps

- **No window.** Nothing is displayed; the target is a headless buffer. A window/surface
  backend is the next platform decision.
- **No swapchain or presentation timing.** No vsync, no `target_fps` pacing, no frame
  timing statistics yet — `settings.json` already carries `target_fps`, but honouring it
  requires a real present.
- **No input or event loop.** The bounded `--frames` count exists precisely because
  nothing can currently terminate a run.
- **Single-threaded.** The loop renders on the calling thread; the job system is used by
  startup and assets, not by the frame.
- **Bounded history.** `report` aggregates only the last `run`; there is no ring of frame
  timings, and `FrameLoop` keeps no per-frame history by design.
