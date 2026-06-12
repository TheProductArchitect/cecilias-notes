<!--
  Cecilia's Notes — Pull Request

  Please fill every section. PRs without a test plan or with vague
  "what" descriptions tend to bounce back. Tight PRs get merged fast.
-->

## What's changing

<!--
  One short paragraph of plain English. Describe the change as you'd
  explain it on a hallway run. Avoid bullet-by-bullet rephrases of
  the diff — focus on the user-facing behaviour or the structural
  shift.
-->

## Why

<!--
  The motivation. Link the discussing issue (`Closes #123`). If
  there's no issue, this is your last chance to convince the
  maintainer that there should be one. Speculative refactors get
  closed.
-->

## Test plan

<!--
  What you ran, what you observed, what you didn't cover. Examples:

  - Ran the full test suite on iPad Pro 13-inch (M5) sim, iPadOS
    26.4, all green.
  - Verified on device: opened a notebook, dictated for ~30s
    including a 5s pause, transcript stayed put.
  - Did NOT test the iCloud sync path; no relevant code paths
    touched.

  Honesty here is worth more than a checked checklist.
-->

## Risks + follow-ups

<!--
  Anything you punted on. Anything that might bite us. Anything a
  future reader of git blame should know that the code itself can't
  say. If there's nothing, write "None."
-->

## Mirror / schema impact

<!--
  Tick whichever applies:

  - [ ] No impact on the .inkbook v1 schema or the MCP mirror
        contract.
  - [ ] Touches the schema; the change is back-compatible (new
        optional field, additive enum case, etc.).
  - [ ] Breaks the schema; we'll need to bump to v2 and update the
        spec at venugopinath.me/cecilias-notes/schemas/inkbook/.
-->

## Checklist

- [ ] Tests cover the new behaviour or the bug's reproduction case.
- [ ] No new tracking / analytics / telemetry.
- [ ] No destructive UX without a confirmation prompt.
- [ ] Comments explain *why*, not *what*.
- [ ] I've read [CONTRIBUTING.md](../CONTRIBUTING.md).
