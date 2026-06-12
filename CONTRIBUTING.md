# Contributing to Cecilia's Notes

Thanks for taking the time to look at the project. The contribution
process is intentionally a little involved: this is an end-user app
on an iPad, and a sloppy change can break someone's notes. The
guardrails below are how we keep that from happening.

## TL;DR for first-time contributors

1. **Open an issue first** for anything bigger than a typo. We'll
   discuss scope before you write code — saves both of us time.
2. **Fork → branch → PR.** No direct pushes to `main`; branch
   protection enforces this.
3. **Keep PRs focused.** One coherent change per PR. If you find
   yourself writing "Also fixed X" in the description, split it.
4. **Tests required for behaviour changes.** A bug fix without a
   regression test is half a fix.
5. **One approver decides merge.** [@TheProductArchitect](https://github.com/TheProductArchitect)
   is the sole code owner (see [CODEOWNERS](.github/CODEOWNERS)) and
   the only person who can merge to `main`.

## Workflow

### 1. Discuss before you build

For anything beyond a doc fix or a one-line correction:

- **Bug?** Open a *Bug* issue using the template. Include the iPad
  model + iPadOS version + reproduction steps. A console log
  excerpt (the `[…]` log lines in DEBUG builds) speeds triage
  enormously.
- **Feature?** Open a *Feature* issue. Describe the user-facing
  problem first; the implementation comes second. Wait for a
  thumbs-up before sending code — a PR for a feature we won't ship
  is a waste of everyone's evening.

### 2. Fork, branch, build

```bash
git clone https://github.com/<your-user>/cecilias-notes.git
cd cecilias-notes
git checkout -b your-branch-name
open CeciliasNotes/CeciliasNotes.xcodeproj
```

Branch names are free-form but `kebab-case-with-context` reads
nicely in the PR list (e.g. `fix-dictation-empty-partial`,
`feat-blocknote-export`).

Build target: latest stable Xcode. The project deploys to iPadOS
26.4+; you can build for the simulator without an Apple Developer
account, but on-device runs need provisioning.

### 3. Write the change

A few principles that come up repeatedly in review:

- **Match the codebase's voice.** Comments are full sentences,
  explain *why* not *what*, and don't repeat what the code already
  says. Look at neighboring files for tone.
- **Don't add abstractions speculatively.** A helper / protocol /
  enum should pay for itself today, not "someday."
- **Don't break the mirror contract.** Anything that touches
  `CeciliasNotesImporter`, `CeciliasNotesExporter`,
  `CeciliasNotesFile`, or `inkbookBlocksJSON` is on the MCP
  contract surface — the spec lives at
  [`venugopinath.me/cecilias-notes/schemas/inkbook/v1.json`](https://venugopinath.me/cecilias-notes/schemas/inkbook/v1.json)
  and any incompatible change requires a v2 bump, not a v1 edit.
- **Don't introduce destructive UX without a confirmation.** No
  silent deletes, no silent overwrites. The user owns their
  notebooks.

### 4. Tests

Every behaviour change needs a test. The repo has three test
classes worth knowing:

- `InkbookImporterStrategyTests` — pins the import decision matrix
  (create / append / replace / unknown / no-action).
- `InkbookRoundTripTests` — pins MCP mirror round-trip fidelity
  (block structure, agent attribution, `has_ink`).
- `RegressionGuardTests` — pins one-off bugs whose root cause is
  understood but easy to re-break.

Each previously-fixed bug has a test that fails when the symptom
returns. If you fix a bug here, add the same kind of guard test —
that's the price of admission for "ensure this never resurfaces."

Run the suite locally before pushing:

```bash
xcodebuild -project CeciliasNotes/CeciliasNotes.xcodeproj \
  -scheme CeciliasNotes \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest' \
  test
```

### 5. Open the PR

Push to your fork's branch and open a PR against `main`. Use the
template — sections are short on purpose:

- **What's changing** — one paragraph of plain English. Pretend
  you're describing it to a teammate on a hallway run.
- **Why** — the user-facing problem or the technical motivation.
  Link the discussing issue.
- **Test plan** — what you ran, what you observed, what you
  *didn't* test. Honesty here is more valuable than a checked
  checklist.
- **Risks / follow-ups** — anything you punted on, anything that
  might bite us in three weeks.

### 6. Review

[@TheProductArchitect](https://github.com/TheProductArchitect) is
the sole code owner. Branch protection requires CODEOWNER approval
before merge, so review timing is whatever the maintainer's
schedule allows. Expect comments — most PRs go through 1–3 rounds.

Things that get a PR closed without merge:

- Force-pushes to your branch that destroy review history
  mid-review (rebase + push *before* opening, not during).
- AI-generated code submitted without disclosure or without the
  contributor having actually read it.
- Unsigned commits from unverified emails (GitHub will flag).
- Anything that breaks an existing test without a documented
  justification.

### 7. Merge

Only the code owner can merge to `main`. Merge strategy: **squash
and merge**, with the PR title becoming the commit subject. Keep PR
titles short and present-tense (`Fix dictation empty-partial
erasure`, not `Fixed an issue where…`).

## What we don't accept

- Drive-by formatting / style PRs that touch many files but don't
  change behaviour. Open an issue first.
- Dependency bumps that lack a release-note link explaining what
  changed in the dependency.
- New top-level features without a prior design discussion.
- Tracking, analytics, or telemetry additions. The app is local-
  first by design.

## Code of Conduct

Be kind, be specific, assume good faith. We follow the
[Contributor Covenant 2.1](CODE_OF_CONDUCT.md).

## Security issues

Don't open a public issue for a security report — email
nvg1996@gmail.com directly with the subject "Cecilia's Notes
security" and we'll work it out privately.
