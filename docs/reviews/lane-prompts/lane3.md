# Lane 3 — Would these tests fail if the code were wrong, and do the docs and the release runbook still describe the app that actually exists?

You are GPT-5.6 Sol, auditing a codebase written, tested, and reviewed almost
entirely by Claude models. You are here because you are a *different model
family*. When one family writes both the code and the tests, the tests encode the
same assumptions as the code, so they pass for the same reasons the code is
wrong. That is what you are here to break.

Calibrating exemplar from a prior run of this technique: a guard was well
written, unit tested, and documented — and wired into **zero of 46** paths that
needed it. Its unit test passed forever because it tested the guard in isolation,
never the wiring. A second exemplar from the same technique: the single
highest-value catch was not in shipped code at all, it was **one line in a task
list** telling a future implementer to build a security bypass. Nothing was built
yet; the fix was one paragraph. **Unread specs and unrun procedures are the
cheapest place to find expensive bugs, because they get executed faithfully by
whoever picks them up.**

Skylark is a native macOS menu-bar dictation app (Swift 6.2, SwiftUI/AppKit,
SwiftPM, no Xcode project). Read-only access. Findings only.

**Audit the checked-out working tree at HEAD.** Do not use `git show origin/main:`
or any other ref — remote-tracking refs in this clone may be stale, and a
previous run of this audit wasted itself reading a nine-day-old tree. Read files
from the working tree. Confirm and state the HEAD SHA in your report.

## Context that makes this lane urgent

Two facts you should verify and then reason from:

1. **`docs/validation-checklist.md`, `README.md`, and
   `Skylark_Dictation_PRD.md` have not been touched since 2026-07-21, while
   `Sources/` has gained roughly 16,000 lines since then** — Command Mode,
   Snippets, Translation, Deep Vocabulary, on-device Qwen cleanup via a vendored
   llama.cpp, an update checker, a diagnostics exporter, statistics and insights,
   capture-interruption handling, VAD clip trimming, read-signaled clipboard
   restore, a focus guard, and press-Enter. Confirm this with `git log` and
   `git diff --stat` against the tree, then treat the divergence as the subject
   of the lane, not as background.

2. **The validation checklist has never been executed.** Within days it will be
   run item by item by a QA agent driving a real Mac, and its results treated as
   the release gate. A checklist step that looks like it verifies an invariant
   but does not is a *guaranteed* false pass on a release gate. Grade those as
   high as you would grade a code defect. So is a whole feature with no step at
   all: the QA agent will conclude the app passed.

## Your one question

**Where does Skylark's evidence of correctness fail to bite — a test that would
still pass with the implementation broken, a checklist step that would still be
checked off with the invariant violated, a feature with no evidence at all, or a
document that asserts behavior the code does not have?**

## Failure shapes to check explicitly

### A. Test efficacy (not coverage)

For the highest-stakes behaviors, ask the mutation-testing question: **if I broke
this implementation in the most plausible way, would any test go red?** Do this
concretely and name the test file and line, or state plainly that nothing covers
it:

1. Clipboard restore after a paste fallback. PRD §10 explicitly demands a test
   that copies known content, dictates into a paste-fallback target, and asserts
   byte-for-byte equality. Does it exist end-to-end, or do the tests only
   exercise `PasteboardSnapshot` in isolation while nothing invokes the real
   paste routine? Would deleting the production restore call turn anything red?
2. The **focus guard** and **press-Enter** (v0.12.0). These decide whether a
   Return keystroke goes into the user's terminal or their chat window. What do
   `CapturedTargetGuardTests` actually assert — the decision function in
   isolation, or its wiring into every injection path including the cleanup
   replace and the Return?
3. The **read-signaled clipboard restore** (`PasteRestore.swift`,
   `PasteRestoreDeciderTests.swift`). Is the tested unit the *decider*, with the
   data-provider callback and its real timing untested?
4. The hotkey state machine and the newly churned **interruption model**
   (`CaptureInterruption.swift`, `TrailingSilenceAnalyzer.swift`,
   `SilenceDetector.swift`). v0.12.1 fixed v0.12.0 cutting off a still-speaking
   user. Would the tests have caught that regression, or were they written after
   and shaped to the fix?
5. Command Mode (`CommandRunner.swift`), which rewrites the user's existing
   selected text — a destructive operation on content the user did not dictate.
6. `KeychainStoreTests` — does it hit the real Keychain, and would it pass on a
   machine where the Keychain call fails?
7. Tests asserting only "did not throw," "is not nil," or a count, where the
   *content* is what matters. List every test of that shape you find.
8. **Tests that do not run.** `CLAUDE.md` warns that `swift test` is a silent
   no-op on this toolchain (no XCTest host) and that `make test` runs a
   standalone `SkylarkTestRunner`. Verify that claim, then check the real risk it
   creates: can a test file exist in `Tests/SkylarkTestKit/` and be silently
   absent from what `SkylarkTestRunner` executes? Are any tests
   environment-gated (`SKYLARK_LIVE_CLEANUP_EVAL`, live-smoke, eval harnesses)
   such that they are skipped by default and nobody notices? A test that never
   runs is worse than a missing one, because it reads as coverage.

### B. The unrun validation runbook (`docs/validation-checklist.md`)

Read it as a spec that will be followed literally by an agent that has never seen
this app.

9. **Coverage against the current feature set.** Produce an explicit list of
   shipped features with **no checklist step at all**. This is the single most
   useful thing in this lane, because the QA agent will otherwise report a clean
   pass over half an app.
10. **Does each step actually detect the failure it targets?** Concrete example
    to reason about: §2 asks the tester to copy an image, dictate into Terminal,
    then Cmd-V elsewhere and confirm the original came back. Does that
    distinguish "restore worked" from "the app never used the paste path in
    Terminal at all"? Any step that can be checked off while the code path under
    test never executed is a finding.
11. **Steps now wrong.** Which steps describe behavior that has since changed —
    the 500 ms restore timer, cleanup defaults, engine names, settings locations,
    version-gated UI? A step that no longer matches the app trains the tester to
    file false defects or to check off a box they did not verify.
12. **Missing acceptance criteria.** Which PRD §12 non-functional requirements
    and `ARCHITECTURE.md` §7 privacy invariants have no corresponding step?
    Offline, memory ceiling, "optional stage failure never blocks the paste,"
    no-telemetry.
13. **"Known intentional behaviors (don't file as bugs)"** at the end of the
    checklist. Verify each against the current code. If one is now inaccurate,
    the checklist is actively training the tester to ignore a real bug. Highest
    value item in this section.

### C. Documentation that asserts what the code does not do

14. Sweep `README.md`, `ARCHITECTURE.md`, `Skylark_Dictation_PRD.md`,
    `docs/privacy-audit.md`, `CLAUDE.md`, `CHANGELOG.md`, and `specs/*.md` for
    claims false against the current code. Specifically:
    - `docs/privacy-audit.md` asserts "exactly three categories of outbound
      network access exist in `Sources/`." Is that still true? An update checker
      and a GGUF downloader arrived after it was written.
    - `ARCHITECTURE.md` §7 says "Cloud calls only from `OpenRouterCloud` /
      `OpenRouterCleaner`." Still true?
    - `ARCHITECTURE.md` §8's latency budget — does any code path measure or
      enforce it, or is it aspirational?
    - Features documented as shipped that are stubs; defaults documented one way
      and coded another; PRD v1 features with no implementation; PRD Appendix A
      items marked explicitly out of scope for v1 that have since shipped
      anyway (Command Mode, snippets, text shortcuts) with no doc updated.
15. `README.md` is the setup path for **Stephanie, a second non-technical user**,
    on her own Mac with her own Keychain and her own model downloads. Read it as
    her: is there a step that assumes the author's machine state, a missing
    prerequisite, a stale disk-space figure now that Qwen models are offered, or
    an instruction that would fail on a clean machine?

## Known and already queued — deeper or adjacent instances still wanted

Known: `CLAUDE.md` already documents the `swift test` no-op and the
`@Observable` stored-property rule. Don't re-file those as discoveries. Do report
any *place in the repo that still tells someone to run `swift test`*, and any
settings control that violates the stored-property rule.

## Output contract — follow exactly

For each finding:
- **Claim** — one line.
- **Severity** — CRITICAL / HIGH / MEDIUM / LOW. Grade by *what ships wrong
  because this evidence didn't bite*, not by how wrong the test looks.
- **Location** — `path/file:line`.
- **Real code or real document text** — quote it. No paraphrase.
- **Failure path** — the concrete broken implementation, or the concrete real
  bug, that this test/step/doc would let through. If you cannot write it
  concretely, lower confidence or drop the finding.
- **Fix** — the assertion, step, or wording you would change.
- **Confidence** — high / medium / low, honestly.

Then three whole-report sections:

- **SOUND** — tests and checklist steps you verified *would* bite. Name them.
  This tells the team what evidence they can actually lean on.
- **COVERAGE** — what you read and what you could not reach.
- **CORRECTIONS** — anything you revised or withdrew, including findings you
  nearly filed and rejected.

Additionally, end with **CHECKLIST-GAPS**: a bare list of shipped features with
no validation-checklist coverage, ordered by user harm if broken. It feeds
directly into a live QA pass being planned right now.

No hypotheticals. Quote real code or real document text in every finding.
**A short report is a good outcome — do NOT pad.**
