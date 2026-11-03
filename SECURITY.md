# Security Policy

CoreX is under active development and does not currently publish supported release versions. Security-relevant changes are considered in the context of the current development branch; no release support window is promised.

## Reporting a vulnerability

**Do not report suspected vulnerabilities in public issues, discussions, or pull requests.**

GitHub Private Vulnerability Reporting must be enabled in the repository settings before it can be used or advertised as an available reporting channel. This document does not claim that the feature is currently enabled.

If GitHub's private reporting option is available for this repository, use it to submit the report. Otherwise, this repository does not currently publish a dedicated security email address or confidential reporting channel. Do not disclose exploit details publicly while seeking a private route; use GitHub's platform reporting tools or contact a maintainer through a channel the maintainers have explicitly made available.

## Include in a report

When safe to do so, provide:

- A concise description of the suspected issue and its potential impact.
- The affected commit, branch, file, and relevant configuration.
- Reproduction steps or a minimal proof of concept that does not affect third parties.
- The Zig version, operating system, and architecture involved.
- Any relevant logs, expected behavior, and observed behavior.
- Whether the issue is known to affect other versions or configurations.

Avoid including real credentials, personal data, or other sensitive information in a report.

## Coordinated disclosure

Please allow maintainers an opportunity to investigate and prepare a fix before public disclosure. Coordinate publication timing with maintainers; this project does not promise a response or resolution deadline. Do not access, modify, or expose data or systems that are not yours while investigating.

## Security engineering expectations

Contributions should carefully handle pointer operations, integer arithmetic, buffer bounds, input validation, resource lifetimes, error paths, and third-party dependencies. Security reports and fixes receive review appropriate to their impact.