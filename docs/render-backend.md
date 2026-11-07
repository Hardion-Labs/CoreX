# Renderer tiers and the backend contract — CoreXEngine

This document defines the boundary between the **backend-independent draw list**
([render-extraction.md](render-extraction.md)) and whatever executes it. It is the
contract every renderer tier implements, plus the CPU driver that implements it
today. Code: `src/render/backend.zig`, exposed as `corex.render.backend` (with the
main types re-exported directly on `corex.render`).

> Status: **contract implemented and exercised**, with one backend — the CPU
> reference (`SoftwareBackend`) built on the software rasterizer
> ([render-raster.md](render-raster.md)). **No GPU backend exists yet**: Low,
> Medium and Advanced are tiers of this contract, not three implementations.

## Why a contract at all

The engine has to be able to swap renderers without touching the scene, the
extraction layer or the editor. Two decisions make that possible here:

1. **The draw list stays the only input.** A backend receives `DrawCommand`s
   (`entity`, `mesh`, `material`, `world`, `bounds`, `depth`) and a
   `view_projection * world` matrix per draw. It never sees a scene, an ECS
   world or an asset cache.
2. **The contract is explicit, not comptime-generic.** `Backend` is
   `*anyopaque` + a vtable with four functions, the same shape as
   `core.splash.SplashScreen`. A backend is chosen at **runtime** from the project
   configuration (`settings.json` → `renderer`), so a `comptime` type parameter —
   which the rasterizer's own `resources` uses — would force a switch over every
   backend at every call site.

## Tiers and capabilities

`Tier` is `low`, `medium`, `advanced`; the project selects it in `settings.json`
(`config.RendererTier`). Capabilities live in **one table**, `capabilities(tier)`,
so the tiers differ by documented, asserted feature sets instead of prose:

| Capability | Low | Medium | Advanced |
| --- | --- | --- | --- |
| `depth` (depth buffer written and tested) | yes | yes | yes |
| `textures` | no | yes | yes |
| `lighting` (directional Lambert) | no | yes | yes |
| `blending` (`.alpha` / `.premultiplied` / `.additive`) | no | yes | yes |
| `mipmaps` (`.trilinear` level selection) | no | yes | yes |
| `antialias` (`.edge`) | no | yes | yes |
| `anisotropic` (`Mipmap.anisotropic`) | no | yes | yes |
| `sampling_controls` (`Sampling`: level bias, tap cap) | no | yes | yes |

Low is the documented floor: opaque, untextured, unlit geometry with a depth
buffer — "broad hardware reach, minimal feature set". Medium is everything the CPU
rasterizer implements today; Advanced declares the same set **until a backend
exists** and is deliberately not implied by Medium.

### Asking for more than a tier has

`unsupported(tier, options)` is a pure function returning the first capability a
frame request exceeds, or `null`. `beginFrame` calls it and fails the frame with
`error.UnsupportedFeature` **before touching the surface**. A project that asks
for antialiasing on Low is a configuration error, and the engine says so rather
than silently rendering something else.

Two derived rules keep the gate honest:

- A tier without textures cannot sample any mip level, so `mipmap` is not treated
  as a request there — but a **material that binds a texture** on such a tier is
  an `error.UnsupportedFeature`, not a flat-shaded draw. Silent degradation would
  make the misconfiguration look like it works.
- A tier without `lighting` ignores a provider `directionalLight` (nothing was
  requested); an explicit `FrameOptions.light` is a request and is rejected.

## The pieces

| Item | Meaning |
| --- | --- |
| `Tier` | `low` / `medium` / `advanced`; `name()` for logs and diagnostics. |
| `Capabilities` | One boolean per feature, returned by `capabilities(tier)`. |
| `FrameOptions` | What the caller asks of a frame: `blend`, `antialias`, `mipmap`, `sampling`, `light`, `depth_test`, `depth_write`, `cull`, `front_face`. `rasterOptions()` converts to the rasterizer's `Options` so a field can never be forgotten on one side. |
| `Surface` | The framebuffer: `width`, `height`, borrowed RGBA8 `color` (`w*h*4`), borrowed `f32` `depth` (`w*h`). `validate()`, `clear(rgba, depth)`, `pixelCount()`. `Surface.of(&target)` adapts the rasterizer's `Target` — a cast, not a copy. |
| `DrawResources` | The asset resolver as a **runtime** value: a pointer plus `meshFn`/`colorFn` and optional `textureFn`/`lightFn`/`samplingFn`. `fromComptime(&provider)` adapts any provider the rasterizer already accepts — by pointer, so the borrow and its lifetime are explicit. |
| `DrawStats` | Per draw: `submitted`, `skipped`, `pixels`, `antialiased`, `culled`. |
| `FrameStats` | Accumulated: `draws`, `submitted`, `skipped`, `pixels`, `antialiased_pixels`, `culled`; `add(DrawStats)` is the only way to fold one in. |
| `Backend` | The vtable: `tier`, `beginFrame(surface, options)`, `draw(command, mvp, resources)`, `endFrame()`, `deinit(gpa)`. |
| `Error` | `FrameNotBegun`, `FrameAlreadyBegun`, `InvalidSurface`, `UnsupportedFeature`, `UnresolvedHandle`, `InvalidTexture`, `OutOfMemory`. |

### `mvp` is the caller's job

`draw` takes `mvp = view_projection * world`, folded once by the caller. Backends
therefore never recompute a matrix per draw, and the CPU driver passes
`transform.identity()` as the rasterizer's `world` so the product is still applied
exactly once. `FrameOptions.cull` / `front_face` / `depth_*` apply to the whole
frame, not per draw, matching how the rasterizer's `Options` already work.

### Ownership

Everything is borrowed: the surface, the draw list, the resource provider and the
strings in `DrawStats`. The backend owns only its own state — the CPU driver's
`antialias` scratch is allocated per draw from the allocator passed at
construction and freed before `draw` returns, so a failed allocation fails that
draw (`error.OutOfMemory`) without leaving a half-rendered command.

## Frame lifecycle

```
beginFrame(surface, options)      // validates surface + tier gate, resets stats
  draw(command, mvp, resources)   // N times, in draw-list order
endFrame()                        // returns FrameStats, closes the frame
```

Misuse is an error, never undefined behaviour: `draw`/`endFrame` without
`beginFrame` → `FrameNotBegun`; a second `beginFrame` → `FrameAlreadyBegun`; a
malformed surface → `InvalidSurface`, and a rejected `beginFrame` does **not**
start a frame (a following `endFrame` is still `FrameNotBegun`).

Per-command soft failures mirror the rasterizer's: an unresolved mesh or material
handle, or a mesh whose `uvs` cannot serve a bound texture, counts as
`skipped` and leaves the surface untouched. A malformed texture is
`error.InvalidTexture` — bad asset data must not render silently wrong.

## The CPU driver: `SoftwareBackend`

`SoftwareBackend.init(gpa, tier)` + `interface()` returns a `Backend` that drives
the existing rasterizer (`drawMeshAlloc`, i.e. every feature Medium declares:
coverage, depth, blending, textures, Lambert, `.edge` antialiasing, mip
selection). It exists for two reasons:

- it is the **reference implementation** of the contract — the behaviour a GPU
  backend must reproduce;
- it makes the contract exercised end to end by the test suite instead of declared
  and unused.

Its draw path converts the material's linear `[4]f32` tint to RGBA8 the same way
`rasterize` does, honours the `mvp`-is-pre-folded rule, and maps the rasterizer's
`Stats` onto `DrawStats`/`FrameStats`. It is **not** a tier by itself: the same
driver serves `.low` (through the capability gate) and `.medium`.

## Guarantees and tests

- **Bit-identity with the rasterizer.** The same command, surface and options
  driven through the backend produce byte-identical colour *and* depth buffers to
  calling `raster.drawMeshAlloc` directly. This is the property that makes the CPU
  path a valid reference for a GPU backend.
- **Capability table.** Asserted per tier: Low has depth only; Medium has all six;
  Medium and Advanced stay distinct values.
- **Gate.** Every rejected feature is named by `unsupported` and surfaces as
  `UnsupportedFeature` from `beginFrame`, with the surface untouched and no frame
  left open; `mipmap = .level0` and default options are accepted on Low; a texture
  binding on Low is rejected instead of being shaded flat.
- **Stats.** A culled quad, a skipped unresolved handle and a rendered quad
  accumulate exactly as declared (`draws` 2, `skipped` 1, `pixels` 0, `culled` 2
  in the test), and a partial-coverage frame reports `antialiased_pixels`.
- **Lifecycle.** Every misuse path above is a test, including the malformed
  surface and the second frame.
- **Sampling precedence.** `FrameOptions.sampling` is the frame default; a
  provider's optional `sampling(handle)` overrides it **per material** on a tier
  that declares `sampling_controls`, and is inert elsewhere (`pipeline.resolve`
  zeroes the field, so the uncorrected level renders instead of a refusal). Absent
  optional declarations are not defaulted: a provider without `sampling` yields a
  null function pointer and the frame default stands.
- **Light precedence.** Provider light → used; explicit `FrameOptions.light` →
  wins; tier without lighting → provider ignored (vertex colour survives).
- **Adapter fidelity.** `fromComptime` yields null function pointers for absent
  optional declarations and keeps a **private** `texture` decl invisible, exactly
  like `@hasDecl` in the comptime path.
- **Adapter lifetime.** The argument is a pointer to the provider, checked at
  comptime. An earlier by-value signature stored the address of its own parameter
  and silently read a dead stack slot at `-O ReleaseSafe`; a regression test now
  drives a provider whose handles and tint are read through the adapter and asserts
  the resulting pixels.

## The frame pipeline (`src/render/pipeline.zig`)

The contract above stops at one `draw` call; `pipeline` is the layer that turns a
**scene** into a **finished frame** with one call, so callers never redo the same
four steps:

```
renderScene(gpa, tier, surface, scene, camera, sort_mode, resources, params)
  ├─ extractDrawList        culling + sorting (docs/render-extraction.md)
  ├─ resolve(tier, params)  coerce what the tier cannot do
  └─ renderFrame            beginFrame → N × draw(mvp = vp * world) → endFrame
```

- **Tier selection.** `tierFromConfig(config.RendererTier)` maps the project
  setting onto `Tier` and is **checked at compile time**: a config tier with no
  render tier fails the build. The dependency still runs one way — `render` does
  not import `core/config.zig`; the mapping is duck-typed on the tag name and both
  enums are asserted to have the same tags.
- `backendFor(tier, gpa)` is the **single** place a backend is registered. Today
  Low and Medium map to `SoftwareBackend`; **Advanced has no backend**, so `run`
  refuses it (`error.PreparationFailed`, exit code 6) instead of silently rendering
  a tier lower.
- `resolve(tier, params, blend_hint)` turns a `FrameParams` into `FrameOptions`
  the tier can actually honour: antialiasing, mip selection, sampling controls,
  lighting and blending are switched off on a tier that lacks them. The pipeline never trips the gate it
  documents, and a caller still gets the whole feature set for free on Medium.
  The default blend comes from the extraction sort — `back_to_front` means
  transparency (`.alpha`), the other modes are opaque.
- `mvp = view_projection * world` is folded here, once per draw, per the
  contract's rule.
- `FrameReport` returns the tier, command count, extraction culling, backend
  `FrameStats` and the **options that were accepted**, so "requested X, got Y" is
  observable without guessing.

### Asset handles

`DrawCommand.mesh`/`.material` are opaque `u32`s, so the pipeline needs a resolver:
`ResourceTable` is a **fixed-capacity** handle table (allocated once, no growth, no
allocation per frame) for meshes, material colours and optional textures.
`Handle` packs a slot index and a **per-kind generation**, so a released handle
cannot alias a slot that was reused, and setting a material on a slot does not
invalidate that slot's mesh handle.

`AssetTable` builds on it for real project assets: it copies a zero-copy `CXMH`
view (`assets.mesh`) into tightly-packed scratch and borrows nothing else, and
`textureFromAsset` adapts a decoded `CXTX` texture to the rasterizer's borrowed
`Texture` with no copy. The engine therefore renders real assets while `render`
keeps **no dependency** on the asset layer beyond these two thin adapters. Limits
are explicit: a mesh larger than the slot sizing is `error.MeshTooLarge`, never a
truncated mesh.

### Where it is wired in

`startup.run` step 7 selects the tier from `settings.json` after the configuration
is loaded, logs it and fails the session when the tier has no backend; the launch
summary prints the **selected** tier (`validate` mode prepares no session and
reports the configured one).

The engine binary then renders **one real frame** of the project's own scene
(`src/scene/render_scene.zig`, section *Authoring and driving a frame*): assets are
loaded from the project's asset index, the scene's camera is found, a headless
surface is sized from `settings.json`'s window size, and the frame is drawn through
the tier. The accounting goes to stdout — always the same line shape:

```text
Frame: 1280x720 medium (1 commands, 1 draws, 0 skipped, 43264 pixels, 0 culled)
```

A scene with no camera prints `no camera in the scene; nothing to render` instead of
drawing an empty image: nothing to frame is a fact about the scene, not a frame.
Presentation — a window, a swapchain, a frame loop — is still the next layer.

## Limitations and next steps

- **No GPU backend.** Low/Medium/Advanced are tiers of this contract; only the CPU
  driver implements it. Choosing an API (Vulkan/Metal/D3D12 abstraction) is a
  separate, documented decision.
- **One surface format.** RGBA8 colour and `f32` depth only. HDR, MSAA targets and
  sRGB views are not modelled; a GPU backend would keep its own handles behind the
  vtable and use `Surface` only for readback.
- **Almost per-frame options only.** `FrameOptions` is the frame default and
  `sampling` is the single per-material override (resolved through the provider per
  draw). There is no material object, no other per-material or per-pass state, no
  render passes, no compute and no command buffers: `draw` is immediate-mode.
- **No parallelism.** A backend draws on the calling thread; the frame loop,
  double buffering and presentation belong to the (planned) runtime/window layer.
- **`FrameStats.culled` counts triangles**, because that is what the rasterizer
  reports per draw; a GPU backend may report draw-level culling instead, so the
  number is documented as backend-reported diagnostics, not a contract value.
- **No window or swapchain.** A headless frame loop now exists
  ([presentation.md](presentation.md)): it owns colour/depth for the whole run and
  renders `--frames` frames (default 1), reusing the draw list and per-frame arenas,
  so nothing is on screen and nothing allocates after the warm-up. A window,
  swapchain, vsync and input still need a platform library.
- **One frame in, one frame out.** No sub-frame pipelining and no per-pass API;
  `renderScene` extracts and draws in one call. A frame loop should drive
  `EngineRenderer.render` (reusable draw list + per-frame scratch arena, so a
  steady-state frame allocates nothing) rather than `renderScene`, which allocates
  its draw list per call.
- **The surface is the caller's.** Colour and depth are owned by whoever renders;
  `runtime.presentation.SurfaceTarget` owns one pair for a whole run and reallocates
  only when the size changes.
- **Resource table: upload is automatic, eviction is explicit.** `scene.render_scene`
  fills the table from the project's asset index, generates a mip chain for every
  uploaded texture (`render.mipmap`, integer box filter) and frees the source bytes as
  soon as the slot is filled, so what the renderer holds is exactly what it samples.
  An upload reports its own footprint (`AssetTable.uploadedBytes`, the scratch it
  copied plus every level it borrows) and the loader counts what it skipped and what it
  mipmapped. **Eviction is not automatic**: there is no budget or LRU — `LoadedAssets.evict(path)`
  is called by whoever knows the asset is no longer needed, and it releases the slot
  (bumping the generations, so stored handles stop resolving) and frees the pixel
  blocks. `CXTX` artifacts still carry no levels; the chain is generated at upload time,
  which is why the artifact format did not change.

## Related

- Draw-list extraction: [render-extraction.md](render-extraction.md)
- Software rasterizer: [render-raster.md](render-raster.md)
- Scope and tiers: [scope.md](scope.md)
- Architecture: [architecture.md](architecture.md)
