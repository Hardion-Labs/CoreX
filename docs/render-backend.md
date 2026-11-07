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
| `FrameOptions` | What the caller asks of a frame: `blend`, `antialias`, `mipmap`, `light`, `depth_test`, `depth_write`, `cull`, `front_face`. `rasterOptions()` converts to the rasterizer's `Options` so a field can never be forgotten on one side. |
| `Surface` | The framebuffer: `width`, `height`, borrowed RGBA8 `color` (`w*h*4`), borrowed `f32` `depth` (`w*h`). `validate()`, `clear(rgba, depth)`, `pixelCount()`. `Surface.of(&target)` adapts the rasterizer's `Target` — a cast, not a copy. |
| `DrawResources` | The asset resolver as a **runtime** value: a pointer plus `meshFn`/`colorFn` and optional `textureFn`/`lightFn`. `fromComptime(provider)` adapts any provider the rasterizer already accepts. |
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
- **Light precedence.** Provider light → used; explicit `FrameOptions.light` →
  wins; tier without lighting → provider ignored (vertex colour survives).
- **Adapter fidelity.** `fromComptime` yields null function pointers for absent
  optional declarations and keeps a **private** `texture` decl invisible, exactly
  like `@hasDecl` in the comptime path.

## Limitations and next steps

- **No GPU backend.** Low/Medium/Advanced are tiers of this contract; only the CPU
  driver implements it. Choosing an API (Vulkan/Metal/D3D12 abstraction) is a
  separate, documented decision.
- **One surface format.** RGBA8 colour and `f32` depth only. HDR, MSAA targets and
  sRGB views are not modelled; a GPU backend would keep its own handles behind the
  vtable and use `Surface` only for readback.
- **Per-frame options only.** No per-material or per-pass state, no render passes,
  no compute, no command buffers: `draw` is immediate-mode.
- **No parallelism.** A backend draws on the calling thread; the frame loop,
  double buffering and presentation belong to the (planned) runtime/window layer.
- **`FrameStats.culled` counts triangles**, because that is what the rasterizer
  reports per draw; a GPU backend may report draw-level culling instead, so the
  number is documented as backend-reported diagnostics, not a contract value.
- Not wired into startup yet: the startup pipeline still opens a headless session,
  and nothing selects or instantiates a backend from `settings.json`. That wiring
  belongs with the runtime/window layer, not with the contract.

## Related

- Draw-list extraction: [render-extraction.md](render-extraction.md)
- Software rasterizer: [render-raster.md](render-raster.md)
- Scope and tiers: [scope.md](scope.md)
- Architecture: [architecture.md](architecture.md)
