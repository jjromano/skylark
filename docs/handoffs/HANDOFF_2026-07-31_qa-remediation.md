# Skylark QA remediation sprint

**Author:** Opus (planning). **Executor:** Fable, running locally on the M3 Air
with the app installed and JJ present.
**Date:** 2026-07-31. **Base:** `main` @ `c1691f7` (v0.12.1).

This sprint closes every finding from two independent QA tracks plus four
outstanding items recovered from earlier sessions. Phases 1 and 2 of
`fable-sprint` are already done: the ledger is below, and JJ has answered the
checkpoint. **Do not re-run the checkpoint. Start at phase 3.**

## Inputs

1. `docs/reviews/2026-07-30-cross-model-audit.md`, the GPT-5.6 Sol static audit:
   four lanes, findings C1-C10, P1-P4, U1-U12. Lane prompts in
   `docs/reviews/lane-prompts/`.
2. The live QA report from Claude Code driving the running app, findings F1-F8
   plus a measured privacy observation and a checklist verdict. JJ has the file;
   its content is reproduced in the ledger below where it matters.
3. Recovered backlog from prior sessions, R1-R5 below.

`[both]` on a ledger item means the static and live tracks reached it
independently. That is the strongest evidence available and those items do not
need re-deriving, only fixing.

---

## Decisions, already made. Do not reopen.

| # | Decision |
|---|---|
| 1 | Deep vocabulary matching: ship it defaulted **OFF** immediately as a safety release, fix the matcher, then **turn it back ON by default** once the fix is confirmed with evidence. |
| 2 | Focus guard: **keep the re-activate behavior** for cross-app. Add window-level identity so same-app is caught. Revalidate immediately before every write and again before Return. |
| 3 | Cancel after release: **extend cancel** through processing until the write is irreversible; notice when it arrives too late. |
| 4 | 120 s capture cap: **keep 120 s**. Warn on the pill as it approaches. Finalize honestly instead of reporting a microphone fault. |
| 5 | Dictionary and cloud: **send only terms that approximate the current transcript**, and disclose the behavior in the Dictionary pane. |
| 6 | Releases: **0.12.2 = P0 only, shipped fast. 0.13.0 = P1. 0.13.x = P2.** |
| 7 | Sol's twelve unverified leads: **triage all and fix all.** No deferral. |
| 8 | First-run verification: no spare machine exists. Verify with **quit first, then reset the grant** (the safe order). True never-granted first run stays unverified and must be called out. |
| 9 | Validation checklist rewrite: **in scope**, done last, informed by everything the sprint learns. |

**No-deferral rule (global CLAUDE.md).** Only an EXTERNAL blocker justifies not
doing something: a device only JJ has, a credential only he can issue, data that
does not exist, a vendor decision. "This is large" is a reason to plan, not to
postpone. Anything not done goes under an explicit **NOT done** heading in the
final report, naming the blocker and what would unblock it.

---

## The ledger

### P0: corrupts real work or bricks the app. Ships as 0.12.2.

**P0-1 `[live]` Deep vocabulary matching overwrites unrelated words on every
cleaned dictation.**
10/10 corrupted with the feature on (5 cloud `openai/gpt-oss-20b`, 5 local
Qwen3-4B), 0/10 with it off. Raw tier unaffected. History row 1353:
`raw_text = "The meeting starts at three and we should bring the budget
spreadsheet."` became `clean_text = "The Claude at Claude and we should bring
the Claude."` None of *meeting, starts, three, budget, spreadsheet* resembles
"Claude". One run deleted the whole opening clause. Dictionary held `CLAUDE.md`
(misspellings `CLOD.md`, `Cloud.md`) and `Claude` (misspelling `clod`).

This was the shipped configuration on the Air, so it has been corrupting real
dictations. The user watches correct raw text get replaced by garbage.

Not engine-specific and not cloud-specific, so suspect the shared path: how
dictionary terms and their misspellings reach the cleanup prompt, and how the
deep-vocabulary rescorer's output is merged. Note the interaction with P1-6: the
full dictionary is injected into the cleanup instructions, and a term list
presented as "prefer these exact spellings" is a plausible mechanism for a model
to substitute them aggressively. Prove the mechanism before fixing.

Ship the default-off flip first, in its own commit, before diagnosing.

**P0-2 `[live]` Crash on launch when Accessibility is not granted.**
2/2 with the grant absent, launches cleanly the moment it is restored. No
menu-bar icon, no window, no error; the process starts and dies. Crash reports
in `~/Library/Logs/DiagnosticReports/Skylark-2026-07-31-*.ips`.

`EXC_BREAKPOINT` via `+[NSApplication _crashOnException:]`, an uncaught ObjC
exception during Auto Layout while a SwiftUI-hosted window sizes itself:
`NSHostingView.updateConstraints` → `updateWindowContentSizeExtremaIfNecessary`
→ `_postWindowNeedsUpdateConstraints`.

Highest priority because it is plausibly the first-run path. A fresh install has
no grant and presents the same untrusted state, so the window whose job is to
walk a non-technical user through granting permissions may be the window that
cannot survive not having them. Escape today requires System Settings, Privacy
and Security, Accessibility, **+**, `/Applications/Skylark.app`, which Stephanie
will not find.

**P0-3 `[live]` Revoking Accessibility while running wedges a permanent fake
recording state, and took the machine down.**
1/1 deterministic. After `tccutil reset Accessibility com.jjromano.skylark`
against the running app: no text injected ever again; HUD pill stuck on a red
recording dot with a flat dead waveform indefinitely; the macOS microphone
indicator stayed lit because the mic was held open; and this looped every 60
seconds forever:

```
hotkey:   event tap disabled (timeout); re-enabling + reconciling trigger state
hotkey:   interruption mid-session (tap timeout); finalizing the utterance at this boundary
hotkey:   reconcile: synthetic triggerUp for keyboard f13 (was held, now reads released)
pipeline: capture interrupted (triggerTapStalled) — recording continues
```

Nothing anywhere names TCC or Accessibility. Shortly after, system input became
unresponsive and the Mac needed a hard restart. A global HID event tap stuck in
that loop is a system-level hazard, not just an app-level one.

**P0-4 `[both]` Text and a synthesized Return land in the wrong window of the
same app.**
3/3 live. Two TextEdit documents; text and a real Return landed in the
non-target window. Log shows `inject target: frontmost=com.apple.TextEdit` with
no focus-guard line firing, because `CapturedTargetGuard.decide` compares bundle
identifiers only (`CapturedTargetGuard.swift:62-64`). Risk is two Mail compose
windows, two Slack windows, two editor windows.

The cross-app case works and re-activates the original app correctly.

**Static half, still unverified live:** the guard is evaluated once at
`DictationOrchestrator.swift:731`, before a cleanup await that can run for
seconds, and the Return at `:818` fires on that stale result. The live test used
raw cleanup so it never exercised the await. Both halves need fixing and the
stale-await half needs a live repro (cold Qwen or cloud cleanup, switch apps
during Processing).

### P1: broken or blocked flows. Ships as 0.13.0.

**P1-1 `[both]` Clipboard restore destroys a copy made during the restore
window.** 4/4. Paste-fallback path only. Restore fires 115-140 ms after the
target reads and blindly writes the pre-dictation snapshot back.
`clipboard restored: trigger=read after-ms=116.2 reads=1`. There is no
`changeCount` comparison anywhere in `PasteRestore.swift`. Real-world: dictate
into Terminal or VS Code, immediately Cmd-C something, your copy vanishes. Fix
is the one JJ specified: only restore if the pasteboard change count still
matches what Skylark wrote.

**P1-2 `[both]` Hands-free loses everything past 120 s, never endpoints, and
then blames the microphone.** Three defects in one flow.
(a) VAD never ended a session: 143.5 s of speech then 45 s of silence, still
recording at 4 minutes, ended only by an explicit `skylark://record/stop` at
253 s.
(b) Capture hard-caps at 120 s and drops the overflow silently. Markers at 0 s
and 52 s survived; markers at 122 s and 140 s were lost. History row 1393:
`duration_ms=119098`, `wall-ms: 253243`.
(c) The cap then misdiagnoses itself: `capture sample duration 119.93s ≪ wall
253.24s — input tap likely stalled (possible mic interruption)`. The tap did not
stall. The user is told their mic was interrupted when they hit a designed
limit.
Also: RSS went 93 MB to 195 MB and was not reclaimed within 25 s.
Not confirmed: which notice string the user actually sees. Verify it.

**P1-3 `[both]` Cancel after key release is silently ignored.** 3/3.
`cancelRecording` guards on `phase == .recording`
(`DictationOrchestrator.swift:1284`), so Esc or `skylark://record/cancel` during
Processing is dropped with no log line and no UI report. Window is about 180 ms
on local Parakeet and 350-680 ms on cloud STT. Esc *during* recording works
correctly, so keep that path intact.

**P1-4 `[live]` Deep-link dictation pastes into Skylark itself.** 1/1.
`open skylark://record/start` activates Skylark, so the captured target becomes
Skylark: `frontmost=com.jjromano.skylark focusedRole=AXOutline axEditable=false`
→ clipboard paste into Skylark's own window, `app_name = "Skylark"` in history,
dictation lost. Affects anyone driving from Shortcuts, Stream Deck, or scripts.
Does not affect the hotkey path. Capture the target before the activation, or
resolve it from the previously-frontmost app.

**P1-5 `[static]` Command Mode pastes over the live selection when its anchor
goes stale.** `TextInjector.swift:317`: the anchored AX write correctly refuses
when focus moved, then the fallback Cmd-Vs over whatever is selected now,
destroying unrelated content with no recovery. The doc comment names "focus
moved" as a case it falls back *from*, so the unsafe case is the documented one.
Abort instead of pasting when the anchor is stale.

**P1-6 `[both]` The full custom dictionary is uploaded on every cloud cleanup.**
Measured from the outside with `nettop`, same clip, warm process, three runs
each: 2 entries (45 bytes) gave mean 4009 bytes out; 102 entries (10 521 bytes)
gave mean 8901 bytes out. Delta about +4.9 KB for +10.5 KB of dictionary text.
The dictated sentence contained none of the added terms and deep vocab was off.
Source side: `DictationOrchestrator.swift:1331` passes `entries.map(\.phrase)`
and `CleanupPrompt.swift:23` joins all of them into the cloud system message.
Nothing in the UI discloses it. Dictionaries hold names, clients, and private
jargon, and the dictionary auto-learns from corrections.
Fix per decision 5, and check whether it also mitigates P0-1.

**P1-7 `[static]` A stale cloud-STT rebuild can upload audio while the menu
reads Local.** `AppController.swift:1530` does a detached Keychain read then
calls `finishCloudRebuild`, which never rechecks that the cloud slug is still
selected. The comment above it notes `SecItemCopyMatching` can block on an
authorization prompt, which widens the window to however long a dialog sits
unanswered. Violates the first privacy invariant.

**P1-8 `[static]` A failed capture start leaks the audio tap.**
`AudioCaptureService.swift:341` sets `tapInstalled = true` before
`try engine.start()`, with no cleanup on throw, and the orchestrator's catch at
`:406` returns without calling `capture.stop()`. The next dictation installs a
second tap on the same bus. The user also gets no message.

**P1-9 `[static]` Posting Cmd-V is treated as a landed paste.**
`TextInjector.swift:641` returns `pasteUncertain: false` when the CGEvents were
merely *posted*. If the target ignores the paste, history records success and
the ceiling then restores the clipboard, removing the last copy of the
transcript. Note the doc comment at `:206-209` claims `insert` awaits a
post-paste settle grace before returning; **it does not**. That stale comment is
what makes the unconditional Return look safe on review. Fix the code and the
comment.

**P1-10 `[static]` Cleanup timeout "Off" blocks the first paste indefinitely.**
`DictationOrchestrator.swift:1434`. On paste-only targets cleanup runs before
the first insertion, so "Off" means unbounded time with nothing on screen,
violating PRD §12. Cap the pre-paste stage regardless of the setting; let "Off"
apply only where raw text is already visible.

**P1-11 `[static]` Qwen download deletes the working model before validating the
new one.** `CleanupModelDownloader.swift:127` removes the existing file, moves
the new one in, and only then checks `size >= downloadBytes`, against a mutable
`resolve/main` URL with no digest. A failed upgrade leaves the user with no
local cleanup model at all. Fix the ordering at minimum; pin to an immutable
revision with a SHA-256 if cheap.

### P2: evidence, docs, hygiene. Ships as 0.13.x.

**P2-1 `[both]` The validation checklist is stale and in places cannot detect
the bug it targets.** Rewrite last, per decision 9.
- §2's clipboard step **passes precisely because P1-1 occurs**. Needs a second
  clause: copy something new immediately after the paste and confirm *that*
  survives.
- §1's "double-tap Fn, stops by itself about 1 s after you stop speaking" is
  **FAILED** by P1-2a.
- No coverage of the 120 s cap anywhere.
- §4 names retired models ("Groq Fast Whisper", "Llama 3.1 8B") versus the
  current registry (`openai/whisper-large-v3-turbo`, `openai/gpt-oss-20b`).
- §2 instructs dictating into Messages, Mail, and Slack, which is exactly where
  a wrong-window paste plus a Return sends something. Specify draft-only targets.
- §0 onboarding was unverifiable with permissions already granted, and P0-2
  makes that the most important section to actually exercise.
- Add sections for every feature in the audit's CHECKLIST-GAPS list.

**P2-2 `[static]` Keychain tests pass on a locked keychain.**
`KeychainStoreTests.swift:17` catches `interactionNotAllowed` and returns before
the first expectation, so three tests report success with zero evidence. Report
skipped, not passed.

**P2-3 `[static]` `specs/phase-0-skeleton.md:6` and `:200` still say
`swift test`,** which `CLAUDE.md` documents as a silent no-op that exits 0
having run nothing. Every other spec was corrected. An agent following it
reports acceptance having tested nothing.

**P2-4 `[static]` Launch warms Parakeet before the persisted engine choice is
applied** (`AppController.swift:1092`), so a user on Whisper or Apple Speech who
deleted Parakeet gets an unrequested Hugging Face connection and a 483 MB
download.

**P2-5 Documentation that asserts what the code does not do.**
- `docs/privacy-audit.md` claims "exactly three categories of outbound network
  access exist in `Sources/`", which is false (update checker, Qwen downloader,
  deep-vocabulary download, Apple Speech assets). Rewrite it against current call
  sites, and document the Command Mode selection upload and P1-6.
- `ARCHITECTURE.md` §7 says "Cloud calls only from `OpenRouterCloud` /
  `OpenRouterCleaner`". No longer true.
- The PRD still lists Command Mode and snippets under "Phase 2 backlog, out of
  scope for v1" and translation and stats under "explicitly skipped, not
  planned". All four shipped. Mark historical or remove.
- `ARCHITECTURE.md:218-224` says `ModelPaths.parakeetModelDir` does not match the
  real path so the Settings model manager mis-reports Parakeet. **The constant
  now reads `parakeet-tdt-0.6b-v3` and matches what is on disk, so this looks
  already fixed.** Verify the Settings model manager reports Parakeet's
  size/presence correctly and that Delete works, then correct or remove the
  caveat.

**P2-6 `[static]` U1 through U12, the twelve unverified leads.** Triage all and
fix all per decision 7. Listed in the audit report's table with file and line.
The highest-value two are U1 (non-finalizing interruptions reset the hotkey
processor, so the real key-up is ignored and the session stays recording, which
may be the same root as P0-3) and U4 (synchronous Keychain read on the cloud STT
path can stall the pipeline past its own timeout, which the changelog shows has
hung this app before).

### Recovered backlog: outstanding from prior sessions

Found by sweeping the repo, specs, source comments, and prior session memory.
JJ asked for these to be rolled in.

**R1. Cleanup-model cycle hotkey.** PRD §7 lists "a menu-bar dropdown **and an
optional cycle hotkey** to change the active cleanup model on the fly".
`specs/phase-3-integration.md:60` says "(PRD's optional cycle-hotkey: skip; note
as backlog.)" No implementation exists. This is a v1 PRD requirement that was
never delivered, and the A/B-models workflow is the reason the model registry
exists.

**R2. Registry-aware provider pin in the ad-hoc cleaner factory.**
`AppController.swift:889` hardcodes `providerPin: "groq"` for any user-entered
custom slug rather than consulting the registry entry. PRD §7 wants pinning so
"switching models never silently routes to a slow backend"; pinning an arbitrary
user slug to a provider that may not serve it does the opposite.

**R3. Per-mode Whisper Mode override.** Deferred originally because it needed a
schema v2. The schema is now at v4 and the `modes` table still has no Whisper
Mode column. Not a PRD v1 requirement, so lowest priority of the four, but it is
outstanding and unblocked.

**R4. README screenshot.** `README.md:9` is still the placeholder
`<!-- screenshot: menu-bar pill + notch HUD in the listening state -->`. **The
repo is now PUBLIC** (`gh repo view` confirms), so this is the front page of a
public project with a missing screenshot. Capture the pill and notch HUD in the
listening state and commit it.

**R5.** The "repo public flip" backlog item is **done** (visibility PUBLIC), and
PRD Appendix A's "text shortcuts" is **done** via snippets. "User-defined custom
mode prompts UI" is satisfied by the per-mode free-text Register hint field in
`ModesView.swift:272`. Recorded so nobody re-opens them.

---

## Verification duties

**Every P0 needs a live repro on the Air before and after.** Show it failing,
then show it passing. The repros are in the QA report and reproduced above with
their rates. P0-1 and P0-3 are deterministic; do not accept a mechanism argument
in place of a run.

**The harness JJ's QA used, reuse it:**

```bash
say -r 170 -o clip.aiff "The meeting starts at three and we should bring the budget spreadsheet."
afconvert -f WAVE -d LEI16@16000 -c 1 clip.aiff clip.wav
# Skylark's tap does NOT see AppleScript-synthesized keys. Post at HID level:
#   CGEvent(keyboardEventSource:virtualKey:keyDown:)?.post(tap: .cghidEventTap)
# F13 = 105, Esc = 53. Rebind: defaults write com.jjromano.skylark hotkey.keyboard -string "f13"
./keyhold 105 5.1 & sleep 0.6; afplay clip.wav

log stream --predicate 'subsystem == "com.jjromano.skylark"' --level debug --style compact
sqlite3 ~/Library/Application\ Support/Skylark/skylark.sqlite \
  "select id, engine, cleanup_engine, latency_ms, app_name, raw_text, clean_text from history order by id desc limit 5;"
nettop -P -x -l 1 -p "$(pgrep -x Skylark)"   # lsof does NOT work for this on macOS 26
osascript -e 'clipboard info'
```

**Restore `hotkey.keyboard` to `fn` when done.**

**Safety, learned the hard way:** never run `tccutil reset` against Skylark
while it is running. That is what wedged the HID tap and forced a hard restart.
Quit first, then reset, then launch.

**Cleanup quality gate.** `SKYLARK_LIVE_CLEANUP_EVAL=1 make test` drives the real
on-device model over `CleanupCorpus`. Current baselines: Apple Intelligence
13/17, Qwen3 4B 15/17, Qwen3 1.7B 7/17. Run it before and after any change to
`CleanupPrompt`, the dictionary-to-prompt path, or the rescorer, because P0-1
and P1-6 both touch that surface. Note the audit found this eval **prints
without asserting**, so it can report 0/17 and pass; make it fail below its
baseline while you are in there.

**These were NOT tested by the live pass and are now unblocked because JJ is
present at the machine.** They are sprint scope, not deferrals:
Fn-specific behavior (Globe swallow, Fn+arrow and Fn+F-key passthrough, fn-flag
traps, stray short-tap suppression); Apple Intelligence cleanup tier and the
AI-off fallback; Whisper Mode and quiet speech; the VAD-trim A/B; AirPods and
Bluetooth, device yanked mid-utterance, capture-start failure (needs any second
audio device); engine switch mid-transcription; WhisperKit and model
download/mid-download/interrupted download; History UI, auto-learn, snippets,
modes, translation, Command Mode, update check; target coverage beyond TextEdit,
Terminal, and Script Editor.

**Genuine external blockers, the only legitimate NOT-done candidates:**
a truly never-granted TCC state for first-run (no spare machine or VM exists);
literal cloud request bodies (needs mitmproxy plus CA trust); HUD motion
quality, felt latency, and the Wispr Flow comparison (needs JJ's judgment, not
Fable's).

---

## Fable operating contract

You are at **phase 3 of `fable-sprint`**. Read that skill. The checkpoint is
answered; do not re-run it.

**Delegate by default.** JJ's Fable capacity is hard-capped; Opus and Sonnet are
effectively unlimited. The test for every unit of work: would Fable do this
meaningfully better than a subagent? If not, delegate it, no matter how small.

**Fan-out is mandatory here.** This ledger is roughly 30 independent items of
similar shape. Spawn one agent per item or per small cluster and run them in
parallel. Grinding this list serially in your own thread is the single most
expensive mistake available. Route latency-critical, audio, AX, pasteboard, and
concurrency work to `opus-implementer`; views, stores, tests, docs, and
mechanical edits to `sonnet-implementer`.

**Keep in your own hands:** the diagnosis of P0-1 (it resisted the obvious
explanation and spans cleanup and rescoring), the coherent design of the
permission-and-fault-identity model below, the pass/fail judgment on every P0
repro, and the final report.

**One theme, fix it as one model rather than three patches.** P0-2, P0-3, and
P1-2c are the same bug shape: a specific, diagnosable cause (permission revoked,
designed cap reached) gets collapsed into a generic stall or fault, then retried
forever or crashed on. Concretely: check the actual TCC grant before concluding
"tap stalled"; never present a recording UI with the mic held when injection is
impossible; bound the event-tap retry loop so it gives up loudly instead of
looping every 60 s indefinitely; and distinguish "hit the designed cap" from
"hardware interrupted us".

**Gate the tiers.** No P1 work ships until every P0 is proven fixed against a
live repro. No P2 until P1 is done.

**Per-release discipline (project CLAUDE.md):** every behavior or UI change bumps
`CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and
adds a `CHANGELOG.md` entry, in the same commit. Run `make test`, never
`swift test`. Keep the build free of Swift 6 concurrency warnings.

**Skills to invoke:** `empirical-debugging` for P0-1 and P0-3 and for anything
whose first fix does not hold; `visual-qa` for the HUD warning in P1-2 and the
R4 screenshot; `ship-and-verify` before any done claim; `concurrent-sessions` at
start, since JJ runs several sessions.

**Report (phase 4).** The final message is the deliverable and must stand alone.
Echo each ledger item with a one-line outcome so JJ can tick them off. Separate
**verified** (with the method: which repro, which device, which run) from **not
verified** (what you changed but could not prove, and what would prove it). Give
anything not done its own explicit **NOT done** heading naming the external
blocker. No "see docs/X.md" in place of an answer. No em dashes.

**Housekeeping in the first commit:** `git rm docs/FABLE_SPRINT.md`. Its four
workstreams all shipped as v0.9.0 through v0.12.0, so it is a spent plan a later
session could mistake for live work. Everything still useful from it is already
carried into this doc (the cleanup eval invocation and its baselines, the Handy
VAD smoothing reference relevant to P1-2's trim thresholds). Delete this handoff
too once the sprint report is delivered.
