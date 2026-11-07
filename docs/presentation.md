# Presentation — the owned frame surface and the loop

Status: `src/runtime/presentation.zig` (loop) and `src/runtime/pacing.zig` (pacing),
re-exported as `corex.runtime.presentation` and `corex.runtime.pacing`.
Implemented: the frame-sized target a loop owns, a bounded headless frame loop, a
target-rate pacer and frame timing statistics.
Planned: a window, a swapchain, real vsync and input — all of which need a platform
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
| `FrameLoop` | the target, the `EngineRenderer`, one scratch arena, the `Pacer`, the run report | only during the warm-up |

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
var loop = try corex.runtime.presentation.FrameLoop.init(gpa, tier, width, height, 60);
defer loop.deinit();

const report = try loop.run(scene, resources, 120, io);
// report.frames, report.empty_frames, report.allocating_frames, report.last,
// report.slept_ns, report.elapsed_ns, report.late_frames
```

The fifth argument of `init` is the pacing rate: a `u32` to pace the loop, or `null` to
render as fast as the machine allows. `frame` and `run` take an `?Io`; when it is `null`
the loop renders without ever reading the clock or sleeping, which is how the unit tests
measure work instead of wall-clock time.

`run` renders `count` frames of the same scene and reports:

- `frames` — frames actually rendered;
- `empty_frames` — frames the loop declined to draw because the scene authors no camera
  (it stops there rather than repeating an answer that cannot change);
- `allocating_frames` — frames that had to ask the general-purpose allocator for
  memory. After the warm-up this is **0**;
- `last` — the final frame's `EngineFrameReport`;
- `slept_ns` / `elapsed_ns` / `late_frames` — pacing measurements, all zero when the loop
  is unpaced.

Three properties make the loop usable rather than merely present:

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

3. **A paced loop actually keeps its rate.** Measured with the reference build
   (`ReleaseFast`, 1280x720, one quad):

   ```console
   $ corex-engine --project examples/hello-project/HelloProject.corex --frames 60 --fps 60
   Pacing: 60 fps — 0 late of 60 frames, 0 resyncs, 794.372 ms slept, 993.652 ms elapsed, 16.561 ms/frame
   $ corex-engine --project examples/hello-project/HelloProject.corex --frames 60 --fps 120
   Pacing: 120 fps — 0 late of 60 frames, 0 resyncs, 297.168 ms slept, 493.491 ms elapsed, 8.225 ms/frame
   ```

   Eight bytes per pixel of raster work is fast enough that both rates are held for the
   whole run: the elapsed time is the frame count times the budget, and the difference
   between target and measured rate is the timer's granularity.

The camera is located through `EngineRenderer.findCamera`, which resolves a world matrix
and therefore needs a transform snapshot. That snapshot is dead before the frame is
drawn, so the loop owns a `camera_scratch` arena for it and resets it once per frame —
without that, locating the camera would allocate on every single frame.

## Pacing: `Pacer`, `FramePacing`

```zig
var pacer = try corex.runtime.Pacer.init(60); // 16_666_666 ns per frame
const started = pacer.begin(io);              // null when unpaced
const pacing = try pacer.end(io, started);    // .work_ns, .slept_ns, .late
```

Pacing is **pure arithmetic plus one sleep**, so it is testable without a window:

- The budget is the integer reciprocal `1e9 / fps`, so 60 fps means exactly
  `16_666_666 ns` — the documented rate, not an approximation of it.
- **No drift.** The deadline is anchored to `previous_deadline + budget`, so a frame that
  overshoots its sleep (timer granularity, scheduler) is repaid by the next one instead
  of accumulating into a loop that slowly runs slower than asked.
- **No death spiral.** A frame slower than its budget never sleeps and never tries to
  catch up a burst; it is counted in `late_frames` and the schedule re-anchors on the
  instant the frame actually ended. Storing `end + budget` instead would hand the next
  frame two budgets of slack and make a struggling loop report half the late frames it
  really has — a test pins that exact case.
- **Lost deadlines are not slept away.** A wait longer than `max_wait_ns` (1 s) means
  the deadline is in the wrong epoch (a clock jump, a corrupted budget); the pacer
  re-anchors and counts a `resync`, rather than blocking the process.
- `reschedule()` drops the schedule entirely. The loop calls it at the start of every
  `run`, so a stall between runs (a scene load, a resize) cannot produce a catch-up burst.
- `Pacer.disabled` never reads the clock: the headless default. Rendering flat out is the
  useful default when nothing is displayed and a scripted run should not take minutes.

**This is not vsync.** There is no authoritative "the display is ready" signal without a
presentable surface, so the pacer sleeps and cannot do better than the timer resolution.
What it computes *is* the deadline a swapchain with `FIFO` would impose, so the
accounting and statistics stay valid when a swapchain lands; only the waiting mechanism
changes. Saying that plainly matters: a pacer that claimed to vsync would be lying.

## Wiring: `--frames`, `--fps`

The launch contract gained options (`docs/launch-contract.md`):

| Option | Value | Meaning |
|---|---|---|
| `--frames` | integer > 0 | Frames to render before exiting. Default: `1` (the previous behaviour). |
| `--fps` | integer > 0 | Pace the loop to this rate. Default: unpaced. |

A bounded count is the honest form of "run for a while" while nothing can stop the
loop — there is no window to close and no input to read. `validate` still prepares no
session and renders nothing; `--frames 0` and `--fps 0` are usage errors (exit code 2).
`--fps 0` is refused rather than treated as "unpaced": the two are different requests,
and confusing them hides a configuration mistake.

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
- **No swapchain or vsync.** Pacing is a sleep against the monotonic clock, not a
  present; see the `Pacer` section for why the statistics stay valid when a swapchain
  arrives. `settings.json`'s `target_fps` is still not consulted by the loop: with no
  window, the loop defaults to unpaced and `--fps` is the explicit per-run override. A
  windowed loop is where the config value becomes the sensible default.
- **No input or event loop.** The bounded `--frames` count exists precisely because
  nothing can currently terminate a run.
- **Single-threaded.** The loop renders on the calling thread; the job system is used by
  startup and assets, not by the frame.
- **Bounded history.** `report` aggregates only the last `run`; there is no ring of frame
  timings, and `FrameLoop` keeps no per-frame history by design.
