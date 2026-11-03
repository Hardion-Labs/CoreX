# Architecture and Principles

This document records CoreX's initial principles. The architecture is still under development; the decisions below are guidelines, not promises of already implemented features.

## Principles

1. **Zig end to end:** runtime code and project tools are written in Zig; external native dependencies will be adopted only with documented justification.
2. **Explicit ownership:** APIs should make clear who allocates, owns, and releases each resource.
3. **Composition:** subsystems should be independently usable and testable wherever possible.
4. **Data before abstractions:** prioritize data structures and access patterns suited to the engine's actual workload, avoiding abstractions without a demonstrated need.
5. **Visible compatibility:** document the supported Zig version and validate changes with builds and tests.

## Planned Subsystems

- **Core:** initialization, configuration, logging, and shared utilities.
- **Memory:** allocation policies with explicit allocators and documented lifetimes.
- **ECS:** entities, components, and systems with a data-oriented API.
- **Resources:** loading, caching, dependencies, and predictable release.
- **Rendering:** a backend-independent API; backends will be selected after prototyping and platform evaluation.
- **Platform systems:** windowing, input, audio, and clock, as scope is defined.

## API Guidelines

- Prefer passing allocators explicitly to operations that may allocate.
- Avoid mutable global state; when unavoidable, document its lifecycle and synchronization.
- Define error behavior and data ownership in public APIs.
- Add tests for rules, invariants, and error cases.
- Keep the public surface concentrated in `src/corex.zig` as subsystems are implemented.

## Current Status

The repository contains only the initial build scaffold, entry point, and metadata. ECS, specialized allocators, rendering, resource management, and platform systems have not yet been implemented.
