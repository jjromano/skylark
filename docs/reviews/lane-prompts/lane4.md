# Lane 4 — Can a user press the hotkey, speak, and get nothing, with no error, no text, and no way to know why?

You are GPT-5.6 Sol, auditing a codebase written, tested, and reviewed almost
entirely by Claude models. You are here because you are a *different model
family*. Look for what a reviewer from the authoring family would plausibly have
rationalized away. In this lane the classic rationalization is *"the guard is
correct, it protects the pipeline"*, without ever asking what the **user
experiences** when the guard fires.

Calibrating exemplar from a prior run of this technique: a guard was well
written, unit tested, and documented — and wired into **zero of 46** paths that
needed it. Reviewers read the guard, agreed it was correct, and never asked
whether anything called it. The same reflex in a different direction is what you
hunt here: a guard that *is* wired in, *is* correct, and drops the user's speech
on the floor in silence.

Skylark records while the user holds the Fn key, transcribes on-device (Parakeet
via FluidAudio on the Neural Engine), pastes raw text at the cursor, then
asynchronously replaces it with a cleaned version. Read-only access. Findings
only.

**Audit the checked-out working tree at HEAD.** Do not use `git show origin/main:`
or any other ref — remote-tracking refs in this clone may be stale, and a
previous run of this audit wasted itself reading a nine-day-old tree. Read files
from the working tree. Confirm and state the HEAD SHA in your report.

## The invariants, in the project's own words

`Skylark_Dictation_PRD.md` §12:

> **Reliability:** if any optional stage fails, the user still gets usable text.
> An optional feature never blocks the core paste.

`ARCHITECTURE.md` §2: "Every pipeline stage is skippable; a failed optional stage
never blocks the paste (PRD §12)."

`ARCHITECTURE.md` §4:

> - `DictationOrchestrator` — actor; owns the session state machine
>   (`idle → recording → transcribing → injecting → cleaning`), the only writer
>   of pipeline state.
> - `AudioCaptureService` — render-thread tap writes into a preallocated ring
>   buffer, publishes frames/levels via `AsyncStream` (no allocation, no locks on
>   the audio thread).
> - `HotkeyMonitor` — active CGEventTap on its own run loop … reconcile modifier
>   state from `CGEventSource.flagsState` after `.tapDisabledByTimeout` and
>   re-enable the tap.

`CLAUDE.md`: "Latency is the product: never add blocking work to the audio or
paste path." and "Swift 6 strict concurrency: keep the build free of concurrency
warnings."

## This area was churning as of two days ago — read the history first

`CHANGELOG.md` 0.12.1 (2026-07-27):

> Fixed the new interruption handling clipping a still-holding user. A mid-hold
> event-tap timeout also fires on a benign main-run-loop stall (not only a real
> mic steal), and it was finalizing + pasting the utterance immediately — cutting
> off a user who was still speaking. A bare tap stall now just records the marker
> and keeps recording; the genuine-steal case (a silent/short tail) is still
> trimmed and flagged when the key is released.

That is a one-day-old fix to a one-day-old feature, in the exact subsystem this
lane covers, and it is a **user-cut-off** bug rather than a crash. Read
`docs/FABLE_SPRINT.md` WS1 and WS2 for the intended design, then check whether
the shipped interruption model has other cases of the same shape: a heuristic
that decides on the user's behalf that their utterance ended, or that part of
their audio was not speech.

## Your one question

**Across the whole dictation pipeline, where can the user's spoken utterance be
lost, truncated, duplicated, or stalled — and in each case, does the user find
out?**

Losing the utterance is bad. Losing it *silently* is the bug class this lane
exists for: the user cannot distinguish "it didn't hear me" from "it's broken"
from "I pressed the key wrong," so they retry, lose more work, and stop trusting
it.

## Start here

- `Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift` — the state machine
- `Sources/SkylarkCore/Audio/` — `AudioCaptureService.swift`,
  `CaptureInterruption.swift`, `TrailingSilenceAnalyzer.swift`,
  `SilenceDetector.swift`, `VadClipTrimmer.swift`, `SpeechEndpointer.swift`,
  `VadChunker.swift`, `AudioDeviceManager.swift`
- `Sources/SkylarkCore/Hotkey/` — `HotkeyMonitor.swift`, `HotkeyProcessor.swift`,
  `HotkeyBinding.swift`, `HotkeyCapture.swift`
- `Sources/SkylarkCore/Transcription/` — engines, `FallbackTranscriber.swift`,
  `ModelPreparationState.swift`, `SpeechAnalyzerTranscriber.swift`
- `Sources/SkylarkCore/Cleanup/Llama/` — model load/unload-when-idle under a
  16 GB budget
- `Sources/Skylark/AppController.swift`, `Sources/Skylark/HUD/`

## Failure shapes to check explicitly

Report on each, even where the answer is "correct":

1. **Every silent drop.** Enumerate every `guard … else { return }`, `try?`,
   empty `catch`, and early exit in the pipeline whose outcome is "user gets no
   text." For each: is there a HUD state, banner, sound, or *anything* that tells
   the user? Produce this as an explicit list. It is the primary deliverable of
   this lane.
2. **Every silent truncation.** The trimming and interruption heuristics
   (`VadClipTrimmer`, `TrailingSilenceAnalyzer`, `SilenceDetector`,
   `CaptureInterruption`) each decide that some of the user's audio was not
   speech. For each: what are the thresholds, what real speech patterns fall
   below them (a soft-spoken user, a long pause mid-sentence, a whispered
   utterance in Whisper Mode, a quiet trailing clause), and is the user told that
   anything was trimmed? Silent truncation is worse than a silent drop, because
   the user gets *plausible* text and may not notice words are missing.
3. **The state machine's illegal transitions.** Can the orchestrator get stuck in
   `recording`, `transcribing`, or `cleaning` so the next Fn press does nothing
   until relaunch? What resets it? Is there a timeout on any stage or a watchdog,
   or does the app quietly become inert if an engine hangs?
4. **Re-entrancy and rapid input.** Fn pressed again during `transcribing` or
   `cleaning`; double-tap toggle started while a push-to-talk session finishes;
   Command Mode invoked mid-dictation. Can session B's audio be pasted as session
   A's, can A's cleanup replace land inside B's freshly pasted text, or can one
   session's cancel cancel the other's work? The orchestrator is an actor, but
   **actors are reentrant across awaits** — check every `await` in a mutating
   method for state that could have changed underneath it.
5. **Audio capture lifecycle.** Does the engine/tap restart cleanly for the
   second, tenth, hundredth dictation? Route changes (AirPods connecting
   mid-session, device unplugged, display sleep, `AVAudioEngineConfigurationChange`,
   an OS interruption)? Is there a path where capture reports started but no
   frames arrive, so the user holds Fn, speaks, releases, and gets an empty clip?
   The stalled-tap detector exists — what happens *after* it fires?
6. **The ring buffer.** Is it genuinely preallocated and lock-free on the render
   thread as `ARCHITECTURE.md` §4 claims — no allocation, no locks, no logging,
   no Swift runtime calls that can allocate inside the tap callback? On overrun
   for a long utterance: does it drop the oldest audio (silently truncating the
   start of the sentence), block, or grow unbounded?
7. **VAD endpointing in hands-free mode.** Can it end the utterance mid-sentence,
   or never end it (recording forever, memory growing)? Is there a maximum
   session length?
8. **Cancellation semantics.** ESC, chord-intent cancel, the HUD Cancel item.
   Does cancel actually stop capture, release the engine, and reset state, or
   just hide the HUD while work continues and eventually pastes into whatever the
   user is now doing? **A cancelled dictation that pastes later is a serious
   defect: it types into an app the user has since switched to.**
9. **The async cleanup-replace racing the user.** Raw text is pasted, then
   cleanup replaces it up to seconds later — and local Qwen cleanup may first
   have to *reload a 1 to 2.5 GB model that unloaded after 5 idle minutes*. What
   if by then the user has typed more, moved the cursor, switched apps, closed
   the document, or started another dictation? What bounds the replace, and how
   long can that window actually get on a cold model?
10. **"Optional stage failure never blocks the paste" — verify by tracing, not by
    trusting.** Cleanup unavailable (Apple Intelligence off is a *supported*
    state), Qwen model missing or mid-download, cloud key missing, network down,
    OpenRouter timing out, history DB locked or corrupt, dictionary or snippet
    store failing, deep-vocabulary rescoring failing. In each: does the raw paste
    still happen, and *first*? Is any awaited call on the paste path that can
    take seconds?
11. **Latency-path violations.** Anything on the Fn-up to text-visible path that
    can block: a synchronous disk write, a DB transaction, a Keychain read (which
    can prompt, and has hung this app before per `CHANGELOG.md` v0.7.3), a
    `URLSession` call, a `MainActor` hop under contention, a lazy model load, VAD
    trimming. The budget is 300 ms total (`ARCHITECTURE.md` §8).
12. **Event-tap survival.** `.tapDisabledByTimeout` / `.tapDisabledByUserInput`
    handling and the liveness watchdog. What happens when Accessibility
    permission is revoked while running, or after sleep/wake? Does the hotkey
    silently stop working with no indication? To the user that presents as "the
    app is dead."
13. **Memory under the 16 GB budget.** Qwen weights plus a resident STT model
    plus WhisperKit. Can two large models be resident at once? What happens under
    memory pressure mid-dictation — is there a handler, and does it drop the
    in-flight clip?
14. **Swift 6 strict concurrency.** Any `@unchecked Sendable`,
    `nonisolated(unsafe)`, unguarded global mutable state, or `Task { }`
    capturing mutable state that is a real data race rather than a silenced
    warning.

## Known and already queued — deeper or adjacent instances still wanted

Known and fixed: the v0.12.1 mid-hold tap-stall cutoff described above, and the
older first-dictation-before-model-download silent drop. Don't re-file those two.
**Do** report other instances of the same class, and any case where the v0.12.1
fix is incomplete.

## Output contract — follow exactly

For each finding:
- **Claim** — one line.
- **Severity** — CRITICAL / HIGH / MEDIUM / LOW, graded by user harm. Weight
  "user loses work and cannot tell why" heavily.
- **Location** — `path/file.swift:line`.
- **Real code** — quote the actual lines from the working tree. No paraphrase.
- **Failure path** — the concrete sequence of user actions and code steps. If you
  cannot write it concretely, lower confidence or drop the finding.
- **Fix** — what you would change.
- **Confidence** — high / medium / low, honestly.

Then three whole-report sections:

- **SOUND** — what you verified as genuinely correct and robust, naming the
  mechanism. As valuable as the findings.
- **COVERAGE** — what you read, and what you could not evaluate statically
  (real-time timing, ANE behavior, TCC, third-party internals).
- **CORRECTIONS** — anything you revised or withdrew, including findings you
  nearly filed and rejected.

Finally, end with **LIVE-QA TARGETS**: up to eight things you could not settle
from source that an agent driving a real Mac with a microphone should try, each
phrased as a concrete action plus the observation that would decide the question.
These feed a live QA pass on the target hardware that is being planned right now.

No hypotheticals. Every finding cites real code you read. **A short report is a
good outcome — do NOT pad.**
