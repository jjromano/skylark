# Lane 1 — Can Skylark type, paste, or press Return into the wrong place, or leave the user's clipboard destroyed?

You are GPT-5.6 Sol, auditing a codebase written, tested, and reviewed almost
entirely by Claude models. You are here because you are a *different model
family*. The failure mode being bought protection against is a **correlated
blind spot**: something every Claude reviewer looked straight at and rationalized
away because the code reads well, has an explanatory comment, and has a passing
unit test.

Calibrating exemplar from a prior run of this technique on another codebase: a
guard called `assertDemoWritable` was well written, unit tested, documented in an
ADR — and wired into **zero of 46** mutating paths. Every reviewer read the
guard, agreed it was correct, and never asked whether anything called it. That is
the shape: correct mechanism, absent or partial wiring, tested in isolation from
the paths that matter.

Skylark is a native macOS menu-bar dictation app (Swift 6.2, SwiftUI/AppKit,
SwiftPM, no Xcode project). You hold the Fn key, speak, release, and text is
inserted at the cursor in whatever app was frontmost. Read-only access. Findings
only.

**Audit the checked-out working tree at HEAD.** Do not use `git show origin/main:`
or any other ref — the remote-tracking refs in this clone may be stale, and a
previous run of this audit wasted itself reading a nine-day-old tree. Read files
from the working tree directly. Confirm and state the HEAD SHA in your report.

## The invariants, in the project's own words

`Skylark_Dictation_PRD.md` §10:

> The app must insert text without disturbing the user's clipboard. This is an
> explicit requirement, since many dictation apps clobber the clipboard by
> pasting through it.
> - **Primary path:** insert text directly at the cursor via the Accessibility
>   API, which does not touch the clipboard at all.
> - **Fallback path:** … snapshot the full `NSPasteboard` contents (all types and
>   items, not just plain string), perform the paste, then restore the original
>   contents after the paste completes. Handle timing so the restore does not
>   race the paste.
> - **Verification:** include a test that copies known content to the clipboard,
>   runs a dictation into a paste-fallback target, and asserts the clipboard is
>   byte-for-byte unchanged afterward.

`CLAUDE.md` hard rule: "Clipboard must be snapshot/restored around any
synthesized paste."

`CHANGELOG.md` 0.12.0, describing the two mechanisms that are the heart of this
lane and are only two days old:

> **Read-signaled clipboard restore:** after a synthesized paste, your original
> clipboard is restored the moment the target app actually reads the transcript
> (plus a 100 ms grace for apps that read twice), instead of on a blind 500 ms
> timer. … The 500 ms timer survives only as a ceiling for targets that never
> read.
>
> **Focus guard:** the transcript belongs to the app that was frontmost when you
> started dictating. If focus moved by paste time (Cmd-Tab, a notification, a
> focus steal), Skylark re-activates that app and verifies it's frontmost before
> pasting — and if it can't, it aborts the paste (including any press-enter
> Return) with a note instead of typing into the wrong window.

## Your one question

**Is there any reachable sequence of real user actions in which text lands
somewhere the user did not intend, a Return is synthesized into the wrong app, or
the clipboard ends up different from what it was before dictation?**

Weight the *destructive* outcomes highest. This app can synthesize a Return
keystroke (`Sources/SkylarkCore/Injection/PressEnterCommand.swift`). A Return in
the wrong window sends a message, submits a form, or runs a shell command. That
is the single worst thing this codebase can do, and it is newer than most of the
tests.

## Start here

- `Sources/SkylarkCore/Injection/` — all of it: `TextInjector.swift`,
  `PasteRestore.swift`, `PasteboardSnapshot.swift`, `CapturedTargetGuard.swift`,
  `PressEnterCommand.swift`, `CorrectionWatcher.swift`, `AXTextReader.swift`,
  `AXFieldContextReader.swift`, `AXCorrectionFieldReader.swift`,
  `KeyboardLayout.swift`
- `Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift` — the callers,
  the cleanup-replace stage, cancellation
- `Sources/SkylarkCore/Command/CommandRunner.swift` — voice commands that
  **rewrite the user's selected text in place**
- `Tests/SkylarkTestKit/PasteboardSnapshotTests.swift`,
  `PasteRestoreDeciderTests.swift`, `CapturedTargetGuardTests.swift`,
  `TextInjectorReplaceTests.swift`

## Failure shapes to check explicitly

Report on each, even where the answer is "correct":

1. **The read-signaled restore.** It depends on a lazy `NSPasteboardItem` data
   provider firing when the target reads. What happens when the provider is
   called by something that is *not* the paste — Universal Clipboard, a clipboard
   manager, Spotlight, an accessibility tool, a screenshot service? Does an
   unrelated reader trigger an early restore *before* the target app reads,
   pasting the user's old clipboard content into their document instead of the
   transcript? Trace the exact signal.
2. **The 500 ms ceiling for targets that never read.** What is on the clipboard
   between the paste and the ceiling firing? If the app never reads and the user
   hits Cmd-V manually in that window, what do they get? And if the process is
   killed or quits in that window, does the transcript stay on the clipboard
   forever with the snapshot lost?
3. **Concurrency on the snapshot and the provider.** Two dictations in quick
   succession; a cleanup replace landing while a new dictation starts. Can
   dictation B's snapshot capture dictation A's transcript and "restore" that as
   if it were the user's clipboard? Is the pending-restore state per-operation or
   shared? `TextInjector` is `@MainActor` — but actors and MainActor are
   *reentrant across awaits*. Check every `await` in a mutating path.
4. **The focus guard's re-activation.** It re-activates the captured app and
   verifies frontmost. Between the verify and the synthesized Cmd-V there is a
   window. Can focus move again in it? Does the guard cover the *cleanup replace*
   and the *Return* as well as the initial paste, or only the paste? What happens
   if the captured app has quit, or is showing a modal sheet, or is on another
   Space? Does re-activating an app the user deliberately left steal their focus?
5. **Press-Enter.** Enumerate every path that can synthesize Return. For each:
   what guarantees the intended app and the intended text field are focused, and
   what happens if the paste partially failed but the Return still fires? Is
   there any path where Return fires and the text did not land, or landed
   truncated? Is Return ever synthesized when the transcript was empty?
6. **Command Mode.** `CommandRunner` rewrites the user's *existing selected
   text*. That is destructive to content the user did not dictate. What bounds
   it? What happens if the selection changed, the model returns something
   unrelated, empty, or enormous, or the command times out mid-replace? Is the
   original recoverable?
7. **Snapshot fidelity.** Does the snapshot capture every item and every UTI,
   including promised/lazy types (file promises, Finder file URLs, multi-
   representation RTF+plain) that return `nil` `Data` on eager read? A silently
   dropped type is data loss no plain-string test would see. Say exactly which
   representations the tests actually exercise.
8. **Every exit path.** Trace *every* return, throw, early exit, and cancellation
   between "clipboard written" and "clipboard restored." Is restore in a `defer`
   or equivalent? Which exits strand the transcript?
9. **The AX path claim.** Verify that the direct-AX insertion path genuinely
   never touches `NSPasteboard`, including its own internal fallbacks.
10. **Does the PRD §10 verification test exist and would it bite?** If you
    deleted the restore call in production, would any test go red? Name the test
    or state plainly that none covers it.

## Known and already queued — deeper or adjacent instances still wanted

Known and deliberate: when a synthesized paste fails outright, the snapshot is
**not** restored and the transcript is left on the clipboard as the user's manual
fallback. Don't re-file that tradeoff itself. **Do** report any other path with
the same effect, any path that enters that branch more often than a user would
expect, and any case where the user is never told it happened.

## Output contract — follow exactly

For each finding:
- **Claim** — one line.
- **Severity** — CRITICAL / HIGH / MEDIUM / LOW, graded by user harm.
- **Location** — `path/file.swift:line`.
- **Real code** — quote the actual lines from the working tree. No paraphrase.
- **Failure path** — the concrete sequence of user actions and code steps that
  produces the harm. If you cannot write it concretely, lower confidence or drop
  the finding.
- **Fix** — what you would change.
- **Confidence** — high / medium / low, honestly.

Then three whole-report sections:

- **SOUND** — what you verified as genuinely correct, naming the mechanism. As
  valuable as the findings.
- **COVERAGE** — what you read, and what you could not reach or evaluate.
- **CORRECTIONS** — anything you revised or withdrew during the run, including
  findings you nearly filed and rejected.

No hypotheticals. Every finding cites real code you read. **A short report is a
good outcome — do NOT pad.** Three real findings beat twelve graded medium.
