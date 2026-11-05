# ECS System Scheduling

CoreXEngine schedules ECS systems through `corex.ecs.schedule`. A schedule is a
comptime value: a tuple of ordered stages, each stage a tuple of systems.
Systems in the same stage are validated for non-conflicting component access and
then dispatched concurrently through `std.Io` (for example the engine
`JobSystem`). Stages run in declaration order; a stage completes before the next
begins.

> Status: implemented and tested. Automatic dependency-graph scheduling, frame
> budgeting, change detection and system profiling are planned extensions.

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

## Performance notes

- The schedule is comptime; there is no runtime graph construction or allocation
  in the scheduler itself.
- Single-system stages run directly, without async dispatch.
- Multi-system stages use one `Io.Group` and stack-allocated per-system error
  slots. Worker count and execution policy come from the caller's `Io`
  implementation (`JobSystem` uses `--jobs`).
- Component storage remains sparse-set; systems should iterate dense views and
  avoid per-entity lookups in hot paths.

## Related

- Architecture: [architecture.md](architecture.md)
- ECS storage and views: `src/ecs/world.zig`, `src/ecs/pool.zig`
- Job system: `src/core/jobs.zig`
- Scope: [scope.md](scope.md)
