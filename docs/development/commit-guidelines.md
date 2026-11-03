# Commit Guidelines

These guidelines help keep CoreX's Git history clear and useful. They are recommendations, not a mandatory template or an automated repository requirement. Use judgment; do not split related work or add formatting merely to satisfy a convention.

## Principles

- **Logical cohesion:** each commit should represent a coherent change.
- **Atomicity:** make commits independently understandable whenever practical. Do not fragment work artificially to achieve this.
- **Clarity:** describe what the commit actually changes.
- **Context:** explain relevant technical reasoning when the subject alone is not enough.
- **Honesty:** do not claim functionality that is not implemented, checks that were not run, or results that were not observed.
- **Naturalness:** keep messages readable and avoid unnecessary formatting, references, or commit fragmentation.

## Suggested format

A useful format for many commits is:

```text
<type>: <description>
```

The type and description are recommendations, not required fields. A clear descriptive subject without a type prefix is also appropriate when it reads more naturally. A body and issue references are optional; include them when useful.

Recommended types:

- `feat`: add or change a capability.
- `fix`: correct a defect or unintended behavior.
- `refactor`: restructure implementation without intending to change behavior.
- `perf`: improve performance.
- `docs`: add or update documentation.
- `test`: add, update, or reorganize tests.
- `build`: change build configuration or build-related tooling.
- `ci`: change continuous integration configuration.
- `chore`: perform repository maintenance that does not fit a more specific type.
- `style`: make formatting or stylistic changes without changing behavior.

Examples:

```text
feat: add entity query filters
fix: reject empty resource paths
refactor: isolate allocator selection
perf: avoid copying asset metadata
docs: clarify allocator ownership
test: cover empty query results
build: expose the test build step
ci: run Zig formatting checks
chore: update repository metadata
style: format Zig declarations
Document the current build compatibility limitation
```

Choose a type only when it accurately describes the change. Do not use a prefix to imply that a planned feature exists or that a change has been validated.

## Optional body and references

Add a body when additional context will help reviewers or future maintainers understand the change. It is particularly useful for:

- Architectural decisions and their trade-offs.
- Non-obvious implementation choices.
- Important behavioral changes.
- Compatibility considerations.
- Known limitations or unverified areas.
- Relevant issue references.

Keep the subject sufficient for straightforward changes; bodies are not required for trivial commits. References such as `Refs #123` or `Fixes #123` may be included when relevant and accurate. Do not add a reference just to decorate a message.

## AI assistance and authorship

AI usage does not need to be declared in every commit message. Follow the [AI-assisted development policy](../policies/AI_POLICY.md) for disclosure of substantial AI assistance in a pull request.

Contributors are responsible for every committed change and must review and correct AI-generated commit descriptions to ensure they accurately represent the work. Do not invent authorship, co-authorship, test results, or technical justifications. Do not add artificial AI attribution or unnecessary `Co-authored-by` trailers; use authorship attribution only when it is accurate and appropriate.
