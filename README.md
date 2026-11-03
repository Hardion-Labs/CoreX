# CoreX

<p align="center">
  <img
    src="assets/branding/LogoBanner_CoreX_1.png"
    alt="CoreX Engine"
    width="100%"
  />
</p>

**A modular game engine written entirely in Zig.**

CoreX is being built to provide a clear, extensible foundation for games: core, ECS, memory, rendering, resources, and fundamental systems—with a focus on performance, explicit control, and maintainable code.

> **Status:** early development. The current structure is a scaffold; the subsystems listed on the roadmap have yet to be implemented. The target version is Zig **0.17.0**.

## Overview

- **Language:** Zig 0.17.0
- **License:** MIT — see [`LICENSE`](LICENSE)
- **Approach:** modular, data-oriented, with no external runtime dependencies
- **Platforms and backends:** to be determined as development progresses

## Goals

- Keep the core small, explicit, and predictable.
- Provide control over allocation and resource lifetimes.
- Build decoupled and testable systems.
- Avoid external runtime dependencies wherever possible.
- Document architectural and compatibility decisions.

## Project Structure

```text
CoreX/
├── assets/
│   └── branding/
│       └── LogoBanner_CoreX_1.png
├── docs/
│   ├── architecture.md
│   ├── development/
│   │   └── coding-standards.md
│   └── policies/
│       └── AI_POLICY.md
├── src/
│   ├── main.zig       # Scaffold entry point
│   └── corex.zig      # Initial public module
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml
│   │   └── feature_request.yml
│   └── PULL_REQUEST_TEMPLATE.md
├── .editorconfig
├── .gitattributes
├── .gitignore
├── build.zig          # Build configuration
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
├── SECURITY.md
└── SUPPORT.md
```

## Requirements

- Zig **0.17.0** (the project's target version)
- Git

## Getting Started

Clone the repository and enter the directory:

```sh
git clone https://github.com/Hardion-Labs/CoreX.git
cd CoreX
```

Build and run the scaffold:

```sh
zig build
zig build run
```

The commands above are defined in `build.zig`, but validation with Zig 0.17.0 is currently blocked by an incompatibility in this build configuration (`Build.args` does not exist in this version). Therefore, neither a successful build nor execution has been confirmed.

> The scaffold validates the initial project structure; it is not a production-ready engine and does not include implemented game systems.

## Roadmap

- [x] Create the initial project structure and define its scope.
- [ ] Continuously validate builds and tests with Zig 0.17.0.
- [ ] Core: lifecycle, configuration, and logging.
- [ ] Memory: allocators and documented ownership policies.
- [ ] ECS: entities, components, and systems.
- [ ] Resources: loading, caching, and explicit release.
- [ ] Rendering: define the API and supported backends.
- [ ] Windowing, input, audio, and timing.
- [ ] Examples, API documentation, and CI pipeline.

The roadmap is indicative and may change as technical decisions are validated.

## Development

Before contributing, read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`docs/architecture.md`](docs/architecture.md), [`docs/development/coding-standards.md`](docs/development/coding-standards.md), and [`docs/policies/AI_POLICY.md`](docs/policies/AI_POLICY.md). Keep code in Zig, minimize dependencies, and include tests for new or changed behavior.

Suggested local checks:

```sh
zig build
zig build test
```

## Contributions

Issues and pull requests are welcome. For substantial changes, open an issue first to discuss the goal, scope, and architectural impact. Also see the [support](SUPPORT.md) and [security](SECURITY.md) guidelines.

## License

CoreX is distributed under the MIT License. See [`LICENSE`](LICENSE).
