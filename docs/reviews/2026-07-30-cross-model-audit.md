# Cross-model audit, 2026-07-30

An adversarial read of Skylark by **GPT-5.6 Sol** (via `codex exec`, read-only),
run because this codebase was written, tested, reviewed, and privacy-audited
almost entirely by Claude models. The point is decorrelation, not a second
opinion: a model cannot audit its own blind spots, and a fourth Claude review
mostly re-confirms the first three.

**Audited commit:** `c1691f7` (v0.12.1, 2026-07-27), read from a frozen clone,
not from an active worktree.

**Verification:** every finding below that is marked CONFIRMED was independently
checked by reading the cited code. Severities are **mine**, not Sol's, and where
I disagree with Sol's grade I say so. Findings Sol reported that I did not
personally verify are listed separately and marked as such.

---

## The headline

**Skylark can paste text, and press Return, into an app the user switched to
after they finished speaking.** The focus guard that is supposed to prevent
exactly this runs once, before a cleanup step that can take seconds, and its
stale result is what gates the keystroke. On a chat window or a terminal, that
means a message sent or a command run in the wrong place.

Three of the four audit lanes reached this independently from different starting
questions. I verified it in the code.

---

## Decisions you owe

1. **v0.12.1 should not be recommended to Stephanie until C1 is fixed.** The
   press-Enter feature plus a slow cleanup tier is a live path to sending text
   to the wrong recipient. Fastest mitigation if you do not want to touch the
   guard today: re-check the guard immediately before the Return, which is a
   one-line change at `DictationOrchestrator.swift:818`.
2. **The validation checklist cannot serve as a release gate in its current
   form.** It was last updated 2026-07-05 and covers none of the destructive
   paths added since. Treat the live QA pass, not the checklist, as the gate for
   this release, and rewrite the checklist after.
3. **Your custom dictionary is uploaded to OpenRouter on every cloud cleanup,
   in full, regardless of what you said** (P2). The dictionary auto-learns from
   your corrections, so it fills with real names over time without you curating
   it. Nothing in the UI says this. Decide whether that is acceptable or whether
   the terms should be filtered to the ones relevant to the current transcript.
4. **Privacy verdict overall:** the core invariants hold. Audio retention,
   Keychain-only secrets, the diagnostics export, and the update checker all
   came back clean under adversarial reading, and Sol withdrew four near-findings
   after tracing them. The two real problems are P1 (a race that can upload audio
   while the menu still says Local) and P2 above. The privacy documentation is
   separately stale and now understates what leaves the machine.

---

## Confirmed findings

### C1. The focus guard is stale by the time it matters, and only knows about apps
**Severity: CRITICAL. Live.** Reached independently by lanes 1, 3, and 4.

`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:731` evaluates the
guard once:

```swift
let focusLost = await capturedTargetLost()
```

Both paste-target branches then await cleanup before writing anything. The
press-Enter branch at `:758` does so deliberately:

```swift
} else if pressEnter {
    // Return must land after the FINAL text: the detached AX replace
    // would race the keystroke (a chat message would send, then get
    // edited), so wait for clean here even on AX targets.
    let outcome = await cleanForPaste(cleaner, tier: effectiveTier, text: rawText, context: cleanupContext)
    ...
    if let token = await insertRaw(final) {
```

and the Return fires at `:818` on the stale value:

```swift
if pressEnter, !focusLost {
    await injector.pressReturn()
}
```

Everything between `:731` and `:818` is unguarded. That window is not small: a
cold Qwen3 4B reloads about 2.3 GB from disk after five idle minutes, and the
cleanup timeout is user-configurable up to 30 seconds with an **"Off"** option
that removes the cap entirely.

Separately, `CapturedTargetGuard.decide` compares bundle identifiers only
(`CapturedTargetGuard.swift:62-64`), so moving to a different window, document,
or text field of the *same* app is never detected, even before the await.

**Failure path:** dictate a reply in Slack ending with "press enter", switch to
another app while the HUD shows Processing, and the transcript plus a Return
lands in whatever is frontmost when cleanup finishes.

**Fix:** revalidate immediately before every write and again before the Return,
and capture window and AX element identity rather than just the bundle ID.

**My grade vs Sol's:** Sol graded this CRITICAL in two lanes and HIGH in a
third. CRITICAL is right, on the strength of the Return.

### C2. Command Mode pastes over whatever is selected *now* when its anchor goes stale
**Severity: HIGH. Live.**

`Sources/SkylarkCore/Injection/TextInjector.swift:317`:

```swift
public func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool {
    if let element = selection.element, let range = selection.range,
       Self.axReplaceSelection(element: element, range: range, original: selection.text, replacement: text) {
        return true
    }
    // Paste fallback: Cmd-V replaces the current selection in place.
    let token = await performClipboardPaste(text, pasteboard: .general, executor: executor)
    return !token.pasteUncertain
}
```

The anchored AX write correctly refuses when focus has moved. The fallback then
Cmd-Vs over the live selection anyway. The doc comment above it names "focus
moved" as one of the failure cases it is falling back *from*, so the unsafe case
is the documented one.

**Failure path:** select a paragraph in Notes, start a command, switch apps and
select something else while the model runs, and the model's output overwrites
the new selection. The original is not recoverable.

**Fix:** abort instead of pasting when the AX anchor is stale. Only allow the
paste fallback when bundle, element, range, and selected text still match.

### C3. Cancel is a silent no-op once you have released the key
**Severity: HIGH. Live.**

`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:1284`:

```swift
private func cancelRecording() {
    guard phase == .recording else { return }
```

Cancel arriving during `transcribing`, `injecting`, or `cleaning` is dropped on
the floor. Transcription, cleanup, and injection continue and eventually type.
Nothing tells the user the cancellation was refused. This compounds C1: the
user's instinct on realising they are about to paste into the wrong place is to
cancel, and cancel does nothing.

**Fix:** per-session cancellation token, honored at every await and before every
write, with a note when the write is already irreversible.

### C4. A failed capture start leaks the audio tap and poisons the retry
**Severity: HIGH. Live.**

`Sources/SkylarkCore/Audio/AudioCaptureService.swift:341`:

```swift
inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
    self?.handleTap(buffer)
}
tapInstalled = true
try engine.start()
```

`tapInstalled` is set before the throwing call, and `start()` wraps this in
`lifecycle.withLock` with no `do/catch`. The orchestrator's handler at `:406`
catches, publishes idle, and returns **without calling `capture.stop()`**:

```swift
do {
    try capture.start()
} catch {
    logger.error("capture.start failed: \(error.localizedDescription, privacy: .public)")
    publish(.idle)
    return
}
```

So the tap stays installed on bus 0, and the next dictation installs a second
one. AVAudioEngine does not tolerate that. The user also gets no message: the
HUD just returns to idle.

**Fix:** clean up on the throw path (`stopEngineLocked()`), rethrow, and surface
"Microphone capture failed".

### C5. Posting Cmd-V is treated as proof the paste landed
**Severity: HIGH. Live.**

`Sources/SkylarkCore/Injection/TextInjector.swift:641`:

```swift
let pasted = await executor.synthesizePaste()

if pasted {
    restore.arm()
    pendingRestore = restore
    return InsertionToken(method: .paste, text: text, pasteUncertain: false)
}
```

`synthesizePaste()` returns true when the CGEvents were successfully *posted*,
not when the target consumed them. If the target ignores the paste or loses
focus, the token still says `pasteUncertain: false`, history records a
successful paste, and the 500 ms ceiling then restores the old clipboard,
removing the last copy of the transcript outside History. The user is told
nothing.

Note also that the doc comment at `TextInjector.swift:206-209` claims:

> on the paste path `insert` awaits the post-paste settle grace before returning

The code does not do that. It arms the restore coordinator and returns
immediately. The comment is what makes the unconditional Return at `:818` look
safe on review, which is a good example of the correlated-blind-spot shape: the
comment is the thing every reviewer trusted.

**Fix:** distinguish posted / read / failed, and never press Return or record a
successful paste on anything but a confirmed read.

### C6. Clipboard restore never checks whether it still owns the clipboard
**Severity: MEDIUM. Live.**

There is no `changeCount` comparison anywhere in
`Sources/SkylarkCore/Injection/PasteRestore.swift`. `restore()` calls
`snapshot?.restore(to: pasteboard)` unconditionally, and
`PasteboardSnapshot.restore` starts with `pasteboard.clearContents()`. If the
user copies something during the read grace or the 500 ms ceiling, that copy is
destroyed and the pre-dictation clipboard is put back.

**Fix:** record the change count at write time and skip the restore if another
writer has taken the pasteboard.

### C7. "Off" on the cleanup timeout removes the cap before the first paste
**Severity: MEDIUM. Live.**

`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:1434`:

```swift
guard let cap else {
    // Timeout disabled (Settings): wait for the cleaner however long it
    // takes. A failed cleaner still returns nil, so raw stands.
    return try? await cleaner.cleanTracked(text, context: context)
}
```

On paste-only targets (Chrome, Terminal) cleanup runs *before* the first
insertion, so this is unbounded time with no text on screen. PRD §12 says an
optional stage never blocks the core paste. This one does, by design, on that
branch.

**Fix:** cap the pre-paste stage regardless of the setting; let "Off" apply only
where raw text is already on screen.

### C8. Keychain tests report success on a locked keychain
**Severity: MEDIUM. Evidence gap, latent.**

`Tests/SkylarkTestKit/KeychainStoreTests.swift:17`:

```swift
private func skippingIfLocked(_ body: () throws -> Void) rethrows {
    do {
        try body()
    } catch KeychainError.interactionNotAllowed {
        return
    }
}
```

On a headless or locked-keychain box all three tests return before their first
expectation and are reported as **passing**. A release can carry three green
Keychain tests with zero Keychain evidence behind them.

**Fix:** report as skipped, not passed, and require an unlocked-keychain lane.

### C9. One spec still tells an agent to run the no-op test command
**Severity: LOW. Latent, but it is a landmine for a future agent.**

`specs/phase-0-skeleton.md:6` and `:200` still say `swift test`, which
`CLAUDE.md` documents as a silent no-op on the CLT-only box that exits 0 having
run nothing. Every other spec was corrected to `make test`; this one was missed.
An agent following it reports acceptance complete having tested nothing.

### C10. The validation checklist covers a fraction of the app it is gating
**Severity: HIGH as a release-gate defect. Live.**

`docs/validation-checklist.md` was last changed 2026-07-05; `Sources/` has
gained over 14,000 lines since. It has 33 boxes, none of which touch Command
Mode, the focus guard, press-Enter, capture-interruption recovery, VAD clip
trimming, Qwen local cleanup, translation, snippets, deep vocabulary,
diagnostics export, update checking, or the correction watcher. Its §2 clipboard
step can also be checked off without the paste path ever executing, because if
the chosen target accepts AX insertion the clipboard is never touched.

The PRD still lists Command Mode and snippets under "Phase 2 backlog (out of
scope for v1)" and translation under "explicitly skipped (not planned)", all of
which have shipped.

**Consequence:** a QA agent can complete every item and report a clean release
while C1 and C2 remain broken. Sol's full gap list is in
`docs/qa/live-qa-handoff.md` §5 and drove that document's scope.

---

## Confirmed privacy findings

The privacy lane was told to treat `docs/privacy-audit.md` as a claim to falsify
rather than a baseline, because that document was written by the same model
family that wrote the code. It swept all 112 Swift files, and statically
inspected the vendored llama.cpp binary with `otool`, `nm`, and `strings`.

### P1. A stale cloud rebuild can upload audio while the menu still says Local
**Severity: HIGH. Live.** This is a direct violation of ARCHITECTURE §7's first
invariant.

`Sources/Skylark/AppController.swift:1530`:

```swift
Task.detached { [weak self] in
    let hasKey = KeychainStore().get() != nil
    await MainActor.run { self?.finishCloudRebuild(slug: slug, hasKey: hasKey) }
}
```

`finishCloudRebuild` at `:1537` **never rechecks that the cloud slug is still
selected**. It builds an `OpenRouterCloud` primary and installs it on the
orchestrator.

**Failure path:** select a cloud STT engine, then change your mind and select a
local engine before the detached Keychain read returns. The local rebuild
completes and the menu shows Local. The older detached completion then lands and
installs a cloud-primary `FallbackTranscriber`. Your next dictation WAV-encodes
and uploads.

**Why the window is not as small as it looks:** the comment immediately above
that code says `SecItemCopyMatching` "can raise a keychain authorization prompt
and block until it's answered". On a self-signed build, which is Skylark's only
distribution model, that window lasts until the user dismisses a dialog.

**Fix:** give STT rebuilds a generation counter and recheck
`modelSelection.sttChoice` before constructing and again before installing.

### P2. The entire custom dictionary goes to the cloud on every cloud cleanup
**Severity: MEDIUM, and I would argue MEDIUM-HIGH. Live.**

`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:1331` passes every
entry:

```swift
dictionaryTerms: entries.map(\.phrase),
```

and `Sources/SkylarkCore/Cleanup/CleanupPrompt.swift:23` joins all of them into
the cloud system message:

```swift
if !context.dictionaryTerms.isEmpty {
    text += "\nPrefer these exact spellings when the transcript approximates them: "
        + context.dictionaryTerms.joined(separator: ", ") + "."
}
```

Every cloud cleanup request carries your full dictionary, whether or not any of
it relates to what you just said. The dictionary is exactly where names,
acronyms, and private jargon live, and it **auto-adds from your corrections**,
so it accumulates real vocabulary without deliberate curation. The Dictionary UI
describes recognition biasing and says nothing about cloud transfer.

**My grade vs Sol's:** Sol said MEDIUM. The auto-learn behavior is what pushes
it up for me: the user never consciously decides to put a name in there.

**Fix:** send only terms that approximate the current transcript, or none at all
(the local `DictionaryCorrector` already runs first), and disclose it either way.

### P3. Launch warms and can download Parakeet even when another engine is selected
**Severity: MEDIUM. Live.**

`Sources/Skylark/AppController.swift:1092` warms Parakeet unconditionally at
launch, before `bootstrapSelection()` applies the persisted engine choice:

```swift
Task { [parakeet] in try? await parakeet.warmUp() }
...
Task { [weak self] in await self?.bootstrapSelection() }
```

`FluidAudioParakeet.warmUp()` calls `AsrModels.downloadAndLoad`, which downloads
if the model is absent. A user on local Whisper or Apple Speech who deleted
Parakeet gets an unrequested connection to Hugging Face and a 483 MB download on
next launch. No audio or transcript is sent, but "local mode: zero network" is
not what happens.

**Fix:** load the persisted choice before warming, and warm only the active
engine.

### P4. Qwen model downloads delete the working model before validating the new one
**Severity: MEDIUM. Live.**

`Sources/SkylarkCore/Cleanup/Llama/CleanupModelDownloader.swift:127`:

```swift
if FileManager.default.fileExists(atPath: model.fileURL.path) {
    try FileManager.default.removeItem(at: model.fileURL)
}
try FileManager.default.moveItem(at: location, to: model.fileURL)
```

and only then, at `:140`, a size check with no digest:

```swift
guard size >= model.downloadBytes else {
```

Two problems. The ordering is destructive: a truncated or wrong download removes
the previously working model first, and the size check then deletes the
replacement too, leaving the user with nothing. And the only integrity test is
"at least as many bytes as expected", against a mutable
`huggingface.co/.../resolve/main` URL that follows redirects. A GGUF is parsed
and executed as model weights by llama.cpp.

**Fix:** pin to an immutable revision, ship a SHA-256, verify while staged, and
replace atomically only on success.

---

## Reported by Sol, not independently verified

Real-looking, cited to real code, but I did not confirm the reachability claim
myself. Treat as leads, not as established defects.

| # | Claim | Sol's severity | Location |
|---|---|---|---|
| U1 | Non-finalizing interruptions reset the hotkey processor, so the real Fn-up is ignored and the session stays recording | HIGH | `HotkeyMonitor.swift:504` |
| U2 | An anonymous pasteboard reader (Universal Clipboard, clipboard manager) is treated as the paste target and triggers an early restore | HIGH | `PasteRestore.swift:144` |
| U3 | Cleanup replace can rewrite an older identical phrase because the range is derived from the live caret | HIGH | `TextInjector.swift:532` |
| U4 | Synchronous Keychain read on the cloud STT path can stall the pipeline past its own timeout | HIGH | `AppController.swift:879` |
| U5 | A second utterance during Processing is captured only after the user stops speaking, then finalized as an empty clip | HIGH | `DictationOrchestrator.swift:361` |
| U6 | Hands-free stops receiving VAD frames after 120 s and may never end | HIGH | `SpeechEndpointer.swift:38` |
| U7 | Partial VAD detection silently deletes quiet leading or trailing speech | HIGH | `VadClipTrimmer.swift:78` |
| U8 | Accessibility revocation mid-hold strands capture in recording; persistent tap-creation failure is log-only | HIGH | `HotkeyMonitor.swift:121` |
| U9 | The render callback allocates and yields through AsyncStream, against the stated no-allocation invariant | MEDIUM | `AudioCaptureService.swift:372` |
| U10 | Engine switching takes effect mid-session and can unload WhisperKit while it is decoding | HIGH | `AppController.swift:1568` |
| U11 | Benchmark never fails on a latency regression despite ARCHITECTURE claiming regressions block merge | MEDIUM | `Scripts/bench.sh:59` |
| U12 | Launch at Login binds to a computed property, violating the stored-`@Observable` rule that has already shipped bugs twice | MEDIUM | `AppController.swift:699` |

Lane 4 also produced a 25-row inventory of every silent-drop exit in the
pipeline. It is the most reusable artifact of the run and is worth reading in
full before the next reliability sprint.

---

## What Sol verified as sound

This section exists because it is the calibration anchor, and because it tells
you what you no longer have to worry about.

- The direct AX insertion path genuinely never touches the pasteboard.
- The **detached** AX cleanup replacement is well guarded: it verifies the same
  focused element, the caret, the exact inserted range, and the exact original
  text before writing, and fails safe with a note. (This is the path C1 does
  *not* cover, because press-Enter and paste targets deliberately bypass it.)
- Cancel *during* recording works correctly and leaves nothing that can paste
  later. The defect is only cancel after Fn-up.
- The sample store is preallocated and bounded; it does not grow or block on
  overrun.
- The interruption model's shipped tests assert the exact v0.12.1 regression
  boundary and would bite if it returned.
- `SilenceDetector` is not a silent drop: it surfaces "No speech detected".
- VAD's all-negative result leaves the clip untouched.
- Raw text reaches direct-AX targets before cleanup, and cleanup failure, Apple
  Intelligence being unavailable, Qwen being absent, and deep-vocabulary failure
  all leave that raw text standing.
- `DiagnosticsReportTests.noTranscriptContent` uses distinctive markers and
  would detect transcript leakage into the export.
- Inactive STT engines are shut down and Qwen unloads after five idle minutes.
- Test discovery is target-wide; a new test file cannot be silently omitted from
  the runner.

From the privacy lane specifically, all of it reached by adversarial reading
rather than by trusting the existing audit:

- **The diagnostics export is clean.** It emits word counts, timings, engine
  ids, and app names, never `rawText`, `cleanText`, or `audioPath`, and it writes
  only after an explicit save-panel confirmation. Sol nearly filed it as a leak
  because it copies unified-log `composedMessage` verbatim, then withdrew after
  auditing every logger and error mapping in the app and finding no transcript,
  preview, dictionary, snippet, command, request, response-body, key, or
  audio-sample interpolation.
- **The update checker is not telemetry.** Its only caller is the "Check for
  Updates" button. No timer, no launch hook, no identifier, no query parameters.
- **The API key never persists outside the Keychain**, and never appears in
  UserDefaults, query strings, logs, diagnostics, or `NSError.userInfo`.
- **Audio retention is correctly gated**, defaults off when the key is missing,
  and every deletion path (per-row, purge, toggle-off, orphan sweep, both
  retention windows) removes the files. Cloud WAV encoding is in-memory only,
  with no Skylark-owned temp or cache audio write.
- **Field context and retained-audio re-transcription are disclosed opt-ins**,
  each with UI text stating the cloud transfer at the point it is enabled.
- **Stats and Insights are local-only** GRDB aggregation with no network or
  exporter path.
- **Per-app modes cannot silently route you to the cloud:** `ModeProviderAdapter`
  does not map the persisted engine field into `DictationMode`, presets use local
  or raw cleanup, and the timeout chain only ever degrades cloud to local to raw.
  P1 is the one exception, and it is a race, not routing.
- **The vendored llama.cpp is MIT and shows no phone-home mechanism.** It does
  not link CFNetwork, and symbol and string scans found no networking or
  telemetry APIs. No GPL dependency anywhere in the tree.

---

## Disposition

| Do | Finding |
|---|---|
| **Fix before recommending this build to a second user** | C1, C2, P1 |
| **Fix next** | C3, C4, C5, P2 |
| **Fix when convenient** | C6, C7, C8, C9, P3, P4 |
| **Rewrite before it is used as a gate again** | C10, the stale PRD scope sections, and `docs/privacy-audit.md` (its "exactly three categories of outbound network access" claim is now false) |
| **Triage the leads** | U1 through U12, starting with U1 and U4 |
| **Answer with live QA, not code reading** | the sixteen targeted experiments in `docs/qa/live-qa-handoff.md` §7 |

P4 has a second-order consequence worth stating separately: because the old
model is deleted before the new one is validated, a failed Qwen upgrade leaves
the user with no local cleanup model at all. Fixing the ordering is cheap and is
worth doing even if you never pin the digest.

---

## Method, so this is repeatable

Four lanes, each one sharp question, run concurrently as independent
`codex exec -m gpt-5.6-sol --sandbox read-only` agents against a frozen clone.
Read-only enforces findings-only mechanically. Each prompt carried the
correlated-blind-spot framing, the invariant in the project's own words, a
concrete exemplar of the bug class, an enumerated list of failure shapes, a
rigid output contract (per-finding real code plus a concrete failure path, and
whole-report `SOUND` / `COVERAGE` / `CORRECTIONS` sections), and an explicit
anti-padding instruction.

Lane prompts are kept verbatim in `docs/reviews/lane-prompts/`.

**The one process mistake, recorded so it is not repeated:** the first run
audited `origin/main` as it stood in a stale remote-tracking ref, which was
`b5989e9` from 2026-07-21, 42 commits behind. Its findings were largely already
fixed. Two lessons, now baked into the lane prompts: fetch before you freeze,
and instruct the auditor to read the working tree at HEAD rather than any ref.

Sol's own `CORRECTIONS` sections are worth reading. Across the four lanes it
withdrew nine claims during the runs, including an unbounded-ring-buffer claim
and a "cancelled recording pastes later" claim that it narrowed to the specific
post-Fn-up case that turned out to be real.
