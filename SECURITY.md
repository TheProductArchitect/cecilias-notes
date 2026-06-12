# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for a security report.** Public
issues are indexed and crawled within minutes of being filed; an
exploit window opens before a fix can ship.

Instead, email **nvg1996@gmail.com** with the subject line:

> Cecilia's Notes security

Include in the body:

- A description of the issue.
- Steps to reproduce, or a proof-of-concept.
- The iPadOS version + app version where you observed it.
- Your suggested impact rating (low / medium / high / critical) and
  reasoning.

You'll get an acknowledgement within 72 hours. From there we'll
coordinate a fix timeline and (with your permission) credit you in
the release notes when the fix ships.

## Scope

In scope for this policy:

- The Cecilia's Notes iPad app source code in this repository.
- The `.inkbook` v1 file format and the MCP mirror contract
  (importer / exporter / parser code paths).

Out of scope:

- The user's own iCloud account / Apple ID — that's between the
  user and Apple. Report Apple-platform vulnerabilities through
  [Apple's security program](https://security.apple.com/).
- Vulnerabilities in third-party dependencies that we don't bundle
  source for (Swift Package Manager dependencies). Please report
  those to the upstream maintainers; we'll bump our pin when a
  fixed version lands.
- The `cecilias-notes-mcp` npm package — that lives in a separate
  repository with its own security contact.

## What we ask of researchers

- Don't access, modify, or delete data belonging to other users.
- Don't degrade service quality (DoS-style testing).
- Give us a reasonable window to fix before public disclosure.
  Industry norm is 90 days; we'll discuss adjustments on a
  case-by-case basis if the severity demands faster disclosure.

Thanks for helping keep the project safe.
