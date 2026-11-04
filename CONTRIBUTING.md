# Contributing to CoreXEngine

Thank you for your interest in CoreXEngine. The project is an early-stage game
engine written in Zig. Contributions should help establish a small, technically
rigorous foundation without implying that planned engine subsystems are already
implemented.

## Before contributing

Read these documents before proposing implementation changes:

- [Definitive scope](docs/scope.md) — the Engine/Hub boundary.
- [Architecture and principles](docs/architecture.md)
- [Launch contract](docs/launch-contract.md)
- [Development coding standards](docs/development/coding-standards.md)
- [AI-assisted development policy](docs/policies/AI_POLICY.md)

For substantial changes, open a feature-request issue first to discuss the
problem, scope, and architectural impact. Please do not assume that a planned
roadmap item has an agreed design.

**Scope guard:** this repository is the CoreXEngine only. Do not add project
creation/registration, recent-projects catalogs, engine installation/version
selection, or any other CoreXHub responsibility here. Integration with the Hub
is only through the documented launch contract, file formats, and stable
contracts.

## Development prerequisites

- Zig **0.17.0**, the compiler version currently targeted for development. This
  is not a declaration of a formally supported minimum version.
- Git.

The project currently has no external runtime dependencies. Recheck this
guidance if the build configuration changes.

## Repository organization

- `src/corex.zig`: public module; re-exports implemented subsystems.
- `src/main.zig`: executable entry point (`corex-engine`).
- `src/core/`: implemented startup-spine subsystems (CLI, manifest, paths, jobs,
  config, assets, splash, diagnostics, startup, version).
- `include/corex/`: Native Module ABI header (contract).
- `examples/`: example projects.
- `build.zig`: executable, run, and test build steps.
- `docs/`: scope, architecture, contracts, development standards, and policies.
- `.github/`: issue forms and pull request template.

Do not create placeholder modules or directories for planned features unless an
approved change gives them meaningful content.

## Build and test

The build configuration defines the following commands, validated with Zig
0.17.0:

```sh
zig build           # builds zig-out/bin/corex-engine
zig build test      # runs the engine test suite
zig build run -- --help
```

Run `zig build` for changes that affect the project build, and `zig build test`
for changes covered by the test step. Run both for behavioral or structural
changes when applicable. `zig build run` executes the engine; it is not a
substitute for tests.

Report the commands actually run and their outcomes in your pull request. If a
command cannot be run, explain why. Never claim that a build, test, benchmark, or
validation succeeded unless it was executed and passed.

## Coding standards

Follow [docs/development/coding-standards.md](docs/development/coding-standards.md).
In particular, keep ownership and resource lifetimes explicit, preserve the small
public surface, and avoid unnecessary dependencies, allocations, abstractions, or
runtime work.

## Pull requests

Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). A pull request
should:

- Explain the problem and the motivation for the change.
- Keep changes focused and avoid unrelated source changes.
- Include or update tests for changed behavior where practical.
- Include relevant build and test results, and describe any unverified areas.
- Update documentation when behavior, architecture, commands, or contributor
  expectations change.
- Identify breaking changes and unresolved design decisions.
- Disclose substantial AI assistance as required by the
  [AI policy](docs/policies/AI_POLICY.md).

Maintainers may request revisions, additional tests, or an explanation of the
implementation. Changes may be declined when they are out of scope, conflict with
documented principles, lack adequate validation, or leave correctness, licensing,
or security concerns unresolved.

## Commit messages

See the [commit guidelines](docs/development/commit-guidelines.md) for the
recommended message format, examples, and guidance on commit bodies. These are
recommendations, not an automated repository requirement.

## Documentation

Keep statements aligned with the implementation. Clearly label planned work as
planned; do not document roadmap items as existing capabilities. Verify relative
links and commands when changing documentation.

## AI-assisted contributions

AI tools are permitted, subject to the mandatory requirements in
[docs/policies/AI_POLICY.md](docs/policies/AI_POLICY.md). The contributor remains
responsible for every submitted change.

## License

By submitting a contribution, you confirm that you have the legal right to submit
it under the project's [MIT License](LICENSE), and that it does not introduce
unresolved third-party licensing or copyright concerns.
