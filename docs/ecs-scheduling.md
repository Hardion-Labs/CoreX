# ECS System Scheduling

CoreXEngine schedules ECS systems through `corex.ecs.schedule`. A schedule is a
comptime value: a tuple of ordered stages, each stage a tuple of systems.
Systems in the same stage are validated for non-conflicting component access and
then dispatched concurrently through `std.Io` (for example the engine
`JobSystem`). Stages run in declaration order; a stage completes before the next
begins.

> Status: implemented and tested. Manual comptime stages, automatic
> dependency-graph scheduling (`AutoSchedule`), cooperative frame budgets and
> allocation-free system profiling (`FrameSchedule`) are implemented. Change
> detection and relation/graph components remain planned extensions.

## Declaring systems

```zig
const ecs = corex.ecs;

const Movement = ecs.schedule.system(World, Context, "movement", move, .{
    .reads = .{Velocity},
    .writes = .{Transform},
});

fn move(world: *World, ctx: *Context) anyerror!void {
    var it = world.view(.{ Transform, Velocity });
    while (it.next()) |entry| {
        entry[1].x += entry[2].dx * ctx.dt;
        entry[1].y += entry[2].dy * ctx.dt;
    }
}
```

A system run function must be `fn (*World, *Context) anyerror!void`. The spec
literal accepts:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `reads` | tuple of component types | `.{}` | Component types the system reads. |
| `writes` | tuple of component types | `.{}` | Component types the system mutates, adds or removes. |
| `exclusive` | bool | `false` | Requires exclusive world access; must occupy a stage alone. |

Unknown spec fields are rejected at comptime.

## Building and running a schedule

```zig
const Schedule = ecs.schedule.Schedule(World, Context, .{
    .{ Movement, Animation }, // parallel: validated disjoint access
    .{ Spawn, Cleanup },      // compile error if these conflict; use separate stages
});

var js: corex.core.jobs.JobSystem = undefined;
js.init(gpa, null);
defer js.deinit();

try Schedule.run(js.io(), &world, &context);
```

`Schedule.run` returns the first system error in declaration order, or
`error.Canceled` if the Io group is canceled. All systems dispatched in a stage
finish before `run` returns, even when one of them fails. Later stages do not run
after an error.

`Schedule.runSequential(&world, &context)` runs the same systems in declaration
order without Io dispatch. Use it for single-threaded contexts, debugging, or
worlds whose allocator is not thread-safe.

## Automatic dependency graphs

`AutoSchedule` infers safe parallel layers from the same read/write/exclusive
access declarations, so you do not have to hand-group stages:

```zig
const Auto = ecs.AutoSchedule(World, Context, .{ Movement, Animation, Spawn });
try Auto.run(js.io(), &world, &context);
```

- Two systems conflict if they write the same component, one writes a component
  the other reads, or either is exclusive. Conflicting systems get a dependency
  edge in **declaration order** (the earlier declaration runs first).
- Non-conflicting systems share a layer and may run concurrently. Exclusive
  systems naturally become barrier layers.
- The graph is a DAG by construction (edges only point forward in declaration
  order). Layer assignment is a comptime longest-path pass; at runtime the
  scheduler only dispatches precomputed layers. There is no runtime graph
  allocation or topological sort.
- `Auto.depths`, `Auto.stage_count`, `Auto.system_count`, `Auto.names` and
  `Auto.stageOf(index)` expose the inferred graph. `runSequential` runs systems in
  declaration order, which is a topological order of the graph.

Use `Schedule` when you want explicit stages; use `AutoSchedule` when you want
the engine to infer them. Both share the same error semantics: the first system
error in declaration order is returned, all systems dispatched in a layer finish
before the error is returned, and later layers do not run.

## Observers

`runObserved` / `runSequentialObserved` (on both `Schedule` and `AutoSchedule`)
accept an observer with two hooks:

```zig
const Observer = struct {
    pub fn before(self: *@This(), io: std.Io, index: usize) void { ... }
    pub fn after(self: *@This(), io: std.Io, index: usize, result: anyerror!void) void { ... }
};
var obs = Observer{};
try Auto.runSequentialObserved(js.io(), &world, &context, &obs);
```

`index` is the global system index in declaration order. Pass a pointer for
mutable observers. In parallel layers each system invokes the hooks with its own
index, so an observer that writes per-index slots (like the frame profiler) is
safe; an observer with shared mutable state must synchronize itself. Supplying an
observer requires a non-null `io`; `runSequentialObserved(null, ...)` with an
observer returns `error.MissingIo`. `NoopObserver{}` compiles the hooks away and
is what the plain `run`/`runSequential` paths use.

## Frame budgets and profiling

`FrameSchedule` wraps an `AutoSchedule` graph and adds allocation-free profiling
and cooperative frame budgets:

```zig
const Frame = ecs.FrameSchedule(World, Context, .{ Movement, Animation, Spawn });
var profiler = Frame.Profiler.init();
var cursor = ecs.FrameCursor{};

// Cooperative budget: stop between systems, resume next call.
const r = try Frame.runBudgeted(js.io(), &world, &context, &profiler, &cursor, .{
    .max_nanoseconds = 2_000_000, // 2 ms; 0 disables
    .max_systems = 4,             // 0 disables
});
if (!r.completed) {
    // r.reason is .time_budget or .system_budget; cursor.next_system marks the
    // next system to run. Call runBudgeted again next frame to resume.
}

// Full parallel run with per-system stats.
try Frame.runProfiled(js.io(), &world, &context, &profiler);

var buf: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try Frame.writeReport(&profiler, &writer);
```

- `FrameProfiler(N)` keeps fixed per-system slots (`runs`, `errors`, `total_ns`,
  `last_ns`, `max_ns`, `min_ns`) plus `frame_elapsed_ns`. It accumulates across
  calls until `reset()`. Parallel profiling is safe because each system writes
  only its own slot; `reset`/`totalNanoseconds`/`writeReport` must not race with a
  running frame.
- `runBudgeted` executes sequentially in topological (declaration) order and
  checks the budget **between** systems. A running system is never preempted, so
  a single system can overrun the time budget; this is cooperative, not a hard
  real-time guarantee. Budget exhaustion is a normal `FrameResult`
  (`completed = false`), not an error.
- `FrameCursor.next_system` advances only after a system succeeds. On a system
  error it stays at the failed system so the caller can decide whether to retry;
  an out-of-range cursor returns `error.InvalidCursor`. A completed cursor is a
  no-op until `reset()`.
- `FrameBudget.unlimited` disables both limits. Time uses the monotonic `awake`
  clock via the diagnostics `Timer`.

## Safety model

- Two systems may share a stage only if their writes are disjoint and neither
  writes a component type the other reads. Violations are comptime errors.
- A system that creates/destroys entities, or otherwise needs exclusive world
  access, must set `exclusive = true` and be the only system in its stage.
- Access declarations are a trusted contract. The scheduler cannot inspect
  arbitrary Zig code; declaring a write as a read, omitting a written component,
  or hiding entity lifecycle mutation can introduce data races.
- Parallel systems that allocate through the world (for example adding a new
  component to a pool) require a thread-safe world allocator. If the allocator is
  not thread-safe, use `runSequential` or confine allocation to exclusive stages.
- Systems must still respect ECS view rules: do not add/remove components of the
  viewed types while iterating a view. Mutating component values in place is fine.
- `AutoSchedule` only reasons about declared component access. Shared mutable
  state in `Context` is not tracked; partition it per system or synchronize it
  yourself, just as with manual stages.
- Frame budgets are cooperative and sequential; they do not make a system
  real-time safe and do not parallelize budgeted execution.

## Performance notes

- The schedule is comptime; there is no runtime graph construction or allocation
  in the scheduler itself.
- Single-system stages run directly, without async dispatch.
- Multi-system stages use one `Io.Group` and stack-allocated per-system error
  slots. Worker count and execution policy come from the caller's `Io`
  implementation (`JobSystem` uses `--jobs`).
- Component storage remains sparse-set; systems should iterate dense views and
  avoid per-entity lookups in hot paths.
- `AutoSchedule` graph inference and layer assignment happen at comptime; runtime
  dispatch reuses the same `runLayer` helper as manual stages (one `Io.Group` per
  multi-system layer, stack error slots).
- `FrameProfiler` is a fixed-size value with no heap allocation; budgeted runs
  keep a single cursor owner and avoid cross-thread budget checks.

## Related

- Architecture: [architecture.md](architecture.md)
- ECS storage and views: `src/ecs/world.zig`, `src/ecs/pool.zig`
- Automatic graphs: `src/ecs/graph.zig`; frame budgets/profiling: `src/ecs/frame.zig`
- Job-system integration tests: `src/ecs/frame_jobs_test.zig`
- Job system: `src/core/jobs.zig`
- Scope: [scope.md](scope.md)
