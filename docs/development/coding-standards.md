# Zig Coding Standards

These are contribution standards for a project in early development. They distinguish conventions visible in the current repository from recommendations for new code; the latter should not be mistaken for patterns already implemented throughout the engine.

## Established in the current repository

- Project source and build configuration are written in Zig (target: Zig 0.17.0).
- `src/corex.zig` is the public module and re-exports implemented subsystems; `src/main.zig` is the `corex-engine` executable entry point.
- Implemented subsystems live under `src/core/` (startup spine: CLI, manifest, paths, validation, jobs, config, assets, splash, diagnostics, startup, version), `src/ecs/` (entities, pools, world, scheduling), `src/scene/` (components, versioned scene documents) and `src/assets/` (import cache, importers, parallel pipeline).
- `build.zig` defines `zig build`, `zig build run`, and `zig build test`; `zig build run -- <args>` forwards arguments via `Run.addPassthruArgs`.
- The Zig files use lowercase snake_case for file names, declarations, and local identifiers, and PascalCase for types.
- Allocators are passed explicitly; owned resources expose a `deinit`. Error sets are explicit and, at the process boundary, map to the stable exit codes in `docs/launch-contract.md`.
- All source comments, doc comments, and project documentation are written in English. Identifiers and user-facing engine output (CLI help, log messages) are English as well.

## Recommended conventions for new code

### Naming and formatting

- Use `snake_case` for files, functions, variables, and constants, following the current source.
- Use `PascalCase` for Zig types, as appropriate to the language.
- Use descriptive names; avoid unexplained abbreviations.
- Format Zig files with `zig fmt`. Review the formatter's complete diff rather than suppressing or working around it.
- Keep formatting-only changes separate from behavioral changes when doing so makes review clearer.

### Function responsibilities and architecture

- Give each function a focused responsibility and keep control flow easy to follow.
- Prefer straightforward Zig constructs and data layouts over speculative abstractions.
- Keep the public API intentional and concentrated in `src/corex.zig` as features are implemented.
- Keep subsystems independently testable where that fits the design.
- Document architectural changes and their trade-offs before introducing broad new boundaries.

### Errors and resource lifetimes

- Make failure modes explicit in function signatures and propagate or handle errors intentionally.
- Do not hide errors behind success-shaped defaults or silently discard failures.
- When allocating, make the allocator and ownership contract clear. Document who releases returned or retained memory and when.
- Keep resource lifetimes bounded and predictable. Release owned resources on all relevant success and error paths.
- Avoid global mutable state; where it is necessary, document initialization, lifetime, and synchronization expectations.
- Do not introduce allocations in hot paths without a clear need and justification.

The implemented subsystems establish explicit-allocator APIs, owned `deinit` cleanup, generational ECS handles, plain-data scene components, and versioned importers feeding a content-addressed cache with atomic, hash-verified writes. New code should follow these patterns where they fit and should not imply that planned subsystems already establish additional policies.

### Safety and performance

- Use safe operations by default. Keep pointer arithmetic and other unsafe or unchecked operations limited, justified, and documented.
- Check integer operations and buffer boundaries according to the required behavior.
- Validate external or caller-provided input at appropriate API boundaries.
- Prefer measurable workloads and representative tests before optimizing.
- Avoid avoidable runtime overhead, unnecessary copies, and dependencies that are not justified by a concrete need.

### Documentation and testing

- Document public behavior, ownership, error conditions, and non-obvious invariants.
- Write comments and documentation in English, including doc comments (`///`, `//!`) and Markdown under `docs/`. Keep technical terms, API names, and format identifiers exactly as they appear in the code.
- Keep documentation accurate to the implementation and distinguish planned work from existing behavior.
- Add tests for new behavior, important invariants, and error cases where applicable.
- Run `zig build` and `zig build test` when relevant, and report exact commands and outcomes. Do not invent test coverage or results.

### Dependencies

- Prefer the Zig standard library and existing project facilities.
- Propose external dependencies with their purpose, maintenance status, license, security implications, and build/runtime impact.
- Do not add a dependency solely to avoid a small, clear implementation.

## Updating these standards

These conventions may evolve as the implementation grows. Changes to established project rules should be supported by actual code or explicit maintainer decisions.