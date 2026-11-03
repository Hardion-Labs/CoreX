# Contributing to CoreX

Thank you for your interest in CoreX. The project is an early-stage game-engine scaffold written in Zig. Contributions should help establish a small, technically rigorous foundation without implying that planned engine subsystems are already implemented.

## Before contributing

Read these documents before proposing implementation changes:

- [Architecture and principles](docs/architecture.md)
- [Development coding standards](docs/development/coding-standards.md)
- [AI-assisted development policy](docs/policies/AI_POLICY.md)

For substantial changes, open a feature-request issue first to discuss the problem, scope, and architectural impact. Please do not assume that a planned roadmap item has an agreed design.

## Development prerequisites

- Zig **0.17.0**, the compiler version currently targeted for development. This is not a declaration of a formally supported minimum version.
- Git.

The project currently has no external runtime dependencies. Recheck this guidance if the build configuration changes.

## Repository organization

- `src/corex.zig`: initial public module and project metadata.
- `src/main.zig`: executable entry point for the scaffold.
- `build.zig`: executable, run, and test build steps.
- `docs/`: architecture, development standards, and policies.
- `.github/`: issue forms and pull request template.

The engine remains at the scaffold stage. Do not create placeholder modules or directories for planned features unless an approved change gives them meaningful content.

## Build and test

The build configuration defines the following commands:

```sh
zig build
zig build run
zig build test
```

These steps are declared in `build.zig`. At the time of writing, validation with the development compiler Zig 0.17.0 is blocked because the build script accesses `Build.args`, which is not available in that version. Until the build configuration is updated and verified, do not treat these commands as passing.

Once the build is working, run `zig build` for changes that affect the project build, and `zig build test` for changes covered by the test step. Run both for behavioral or structural changes when applicable. `zig build run` executes the current scaffold; it is not a substitute for tests.

Report the commands actually run and their outcomes in your pull request. If a command cannot be run, explain why. Never claim that a build, test, benchmark, or validation succeeded unless it was executed and passed.

## Coding standards

Follow [docs/development/coding-standards.md](docs/development/coding-standards.md). In particular, keep ownership and resource lifetimes explicit, preserve the small public surface, and avoid unnecessary dependencies, allocations, abstractions, or runtime work.

## Pull requests

Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). A pull request should:

- Explain the problem and the motivation for the change.
- Keep changes focused and avoid unrelated source changes.
- Include or update tests for changed behavior where practical.
- Include relevant build and test results, and describe any unverified areas.
- Update documentation when behavior, architecture, commands, or contributor expectations change.
- Identify breaking changes and unresolved design decisions.
- Disclose substantial AI assistance as required by the [AI policy](docs/policies/AI_POLICY.md).

Maintainers may request revisions, additional tests, or an explanation of the implementation. Changes may be declined when they are out of scope, conflict with documented principles, lack adequate validation, or leave correctness, licensing, or security concerns unresolved.

## Commit messages

See the [commit guidelines](docs/development/commit-guidelines.md) for the recommended message format, examples, and guidance on commit bodies. These are recommendations, not an automated repository requirement.

## Documentation

Keep statements aligned with the implementation. Clearly label planned work as planned; do not document roadmap items as existing capabilities. Verify relative links and commands when changing documentation.

## AI-assisted contributions

AI tools are permitted, subject to the mandatory requirements in [docs/policies/AI_POLICY.md](docs/policies/AI_POLICY.md). The contributor remains responsible for every submitted change.

## License

By submitting a contribution, you confirm that you have the legal right to submit it under the project's [MIT License](LICENSE), and that it does not introduce unresolved third-party licensing or copyright concerns.