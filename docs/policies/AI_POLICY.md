# AI-Assisted Development Policy

AI-assisted development is permitted in CoreX. The use of an AI tool does not reduce a contributor's responsibility for the submitted work. This policy applies to code, tests, documentation, build configuration, and other contribution materials substantially created or modified with AI assistance.

## Human responsibility and understanding

- The contributor is fully responsible for every submitted change, including AI-generated or AI-modified material.
- Contributors must understand and be able to explain the behavior, design, dependencies, and risks of every change they submit.
- Submitting code or other technical material that the contributor cannot understand is prohibited.
- AI tools do not assume responsibility for correctness, security, licensing, maintainability, or policy compliance.

## Mandatory human review

- Every substantial AI-generated or AI-modified implementation must be reviewed by the contributor before submission.
- Review the complete resulting change in its repository context, not only the AI prompt or generated snippet.
- An AI-generated review does not replace review by the contributor or the project's normal human review process.

## Testing and validation

- AI-assisted changes must meet the same build, test, and validation expectations as other contributions.
- Run relevant checks and inspect their output. State exactly what was run and what passed or failed.
- Fabricating test results, benchmarks, compiler output, review evidence, or validation claims is prohibited.
- If a check cannot be run, disclose that limitation rather than implying success.

## CoreX engineering principles

AI-assisted changes must respect the project's architecture and coding standards, including:

- Explicit memory ownership and clear resource lifetimes.
- Predictable allocation behavior and no unjustified allocations.
- No unnecessary abstractions or avoidable runtime overhead.
- No unjustified dependencies.
- Clear error handling, API behavior, and testable design.

Do not treat planned engine subsystems or policies as implemented unless verified in the codebase.

## Security

Pay particular attention to pointer operations, unsafe or unchecked operations, integer arithmetic, buffer boundaries, input validation, resource lifetimes, error handling, and external dependencies. Review generated changes for unsafe assumptions and security weaknesses; do not rely on an AI tool's assurance that code is safe.

## Licensing and provenance

- Contributors must have the legal right to submit all contributed material under the project's MIT License.
- Do not submit generated or copied material with unresolved copyright, provenance, or licensing concerns.
- Verify the origin and license compatibility of substantial third-party code, examples, data, or dependencies.

## Confidentiality

Do not send credentials, API keys, access tokens, private user data, or confidential project information to an AI service unless that service and use are explicitly authorized for the information involved. Remove secrets and private information from prompts, logs, and examples.

## Transparency

Disclose substantial AI assistance in the pull request. Identify:

- The AI tool used.
- Its purpose.
- The areas substantially assisted.
- The validation you personally performed.

Disclosure is not required for trivial spelling, grammar, or formatting assistance.

## Prohibited practices

The following are prohibited:

- Blindly submitting AI-generated code or other technical material.
- Submitting work the contributor cannot explain.
- Concealing known defects or material limitations.
- Fabricating tests, benchmarks, or validation.
- Introducing unjustified dependencies or complexity.
- Using AI review to bypass human review.
- Violating licensing or copyright requirements.
- Exposing credentials, private data, or confidential information to unauthorized services.

## Enforcement

Maintainers may request an explanation, revisions, additional tests, or clarification of provenance and validation. Contributions that violate this policy or leave material concerns unresolved may be rejected.