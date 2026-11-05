//! CoreXEngine ECS (Entity-Component-System).
//!
//! Data-oriented storage: generational entity handles (`entity`), sparse-set
//! component pools (`pool`), and a type-safe world with multi-component views
//! (`world`). See `docs/architecture.md` for the subsystem status.
//!
//! Example:
//! ```zig
//! const W = corex.ecs.World(.{ Transform, Velocity });
//! var world = W.init(gpa);
//! defer world.deinit();
//! const e = try world.create();
//! try world.add(e, Transform{ .x = 0, .y = 0 });
//! try world.add(e, Velocity{ .dx = 1, .dy = 0 });
//! var it = world.view(.{ Transform, Velocity });
//! while (it.next()) |entry| {
//!     entry[1].x += entry[2].dx; // entry = { Entity, *Transform, *Velocity }
//! }
//! ```

const std = @import("std");

pub const entity = @import("ecs/entity.zig");
pub const pool = @import("ecs/pool.zig");
pub const world = @import("ecs/world.zig");
pub const schedule = @import("ecs/schedule.zig");
/// Automatic dependency-graph scheduling inferred from component access.
pub const graph = @import("ecs/graph.zig");
/// Frame-level scheduling: system profiling and cooperative frame budgets.
pub const frame = @import("ecs/frame.zig");

pub const Entity = entity.Entity;
pub const Entities = entity.Entities;
pub const Pool = pool.Pool;
pub const World = world.World;
pub const AddError = world.AddError;
pub const Schedule = schedule.Schedule;
pub const system = schedule.system;
pub const AutoSchedule = graph.AutoSchedule;
pub const FrameSchedule = frame.FrameSchedule;
pub const FrameBudget = frame.FrameBudget;
pub const FrameCursor = frame.FrameCursor;
pub const FrameResult = frame.FrameResult;
pub const StopReason = frame.StopReason;
pub const SystemStats = frame.SystemStats;

test {
    std.testing.refAllDecls(@This());
    _ = entity;
    _ = pool;
    _ = world;
    _ = schedule;
    _ = graph;
    _ = frame;
}
