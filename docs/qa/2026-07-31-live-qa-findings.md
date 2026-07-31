# Skylark 0.12.1 — live QA findings

**Date:** 2026-07-31
**Build under test:** `main` @ `c1691f7`, v0.12.1 (build 29). The installed copy was 0.8.1 at session start, so it was rebuilt and installed from a clean tree via `Scripts/install.sh`.
**Machine:** MacBook Air M3 (Mac15,12), macOS 26.2 (25C56). Apple Intelligence available.
**Tester:** Claude Code, live-driving the running app (the companion static source audit was done separately by GPT-5.6 Sol).

---

## 1. Method and its limits — read this before judging any finding

**Audio: Tier 0.** All speech was `say`-generated text converted to 16 kHz mono WAV (`afconvert -f WAVE -d LEI16@16000 -c 1`) and played through the speakers into the built-in mic with `afplay`. Using fixed WAV files rather than live `say` makes runs repeatable, but the path is still acoustic, so each playback differs slightly. Synthesized speech is cleaner than a human — accuracy numbers here are optimistic and were never the point; the questions asked were "where did the text land, what state resulted".

**Trigger: REBOUND to F13.** Skylark's hotkey tap does not see events synthesized by AppleScript/System Events (session-level tap). It does see events posted at HID level. A small helper was built:

```swift
// keyhold.swift — posts a key down, holds, posts key up, at HID level
CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)?.post(tap: .cghidEventTap)
```

Consequence: **everything Fn-specific is untested** — Globe-action swallowing, Fn+arrow / Fn+F-key passthrough, fn-flag traps, stray short-tap suppression. Those need a human.

**Observation:** `log stream --predicate 'subsystem == "com.jjromano.skylark"'`, the `history` table in `~/Library/Application Support/Skylark/skylark.sqlite`, `pbpaste` / `osascript -e 'clipboard info'`, `nettop` for per-process byte counts, and `screencapture` for UI state.

Note `lsof -nP -i -a -p <pid>` returns nothing for Skylark (and for Chrome) on macOS 26 without elevation — it cannot be used for the network checks. `nettop -P -x -l 1 -p <pid>` works and reports cumulative bytes in/out.

**Incident during the session:** running `tccutil reset Accessibility com.jjromano.skylark` against the running app left its global HID event tap in a 60-second disable/re-enable loop while it also held the microphone open. Shortly afterward system input became unresponsive and the Mac required a hard restart. This is part of finding F7 and is why F7 is graded CRITICAL rather than HIGH.

---

## 2. Findings, by severity

### F8 — CRITICAL — Skylark crashes on launch when Accessibility is not granted

**Confirmed both directions:** it crashed 2/2 with Accessibility denied, and launched cleanly the moment the grant was restored.

**Repro**
1. `tccutil reset Accessibility com.jjromano.skylark` (or any state where the grant is absent).
2. Launch Skylark from Finder / `open -a Skylark`.

**Saw:** no menu-bar icon, no window, no error. Clicking the app icon appears to do nothing. The process starts and dies. Two crash reports in `~/Library/Logs/DiagnosticReports/Skylark-2026-07-31-*.ips`.

**Evidence** — launch log, ~4 s before the crash:

```
TCC: kTCCServiceMicrophone     -> auth_value = 2   result = true    (granted)
TCC: kTCCServiceAccessibility  -> auth_value = 0   result = false   (DENIED)
```

Then, on the main thread:

```
EXC_BREAKPOINT (SIGTRAP), via +[NSApplication _crashOnException:]

0  __exceptionPreprocess
1  objc_exception_throw
3  -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
4  -[NSView _informContainerThatSubviewsNeedUpdateConstraints]
6  SwiftUI.NSHostingView.setNeedsUpdate()
11 SwiftUI.NSHostingView.updateSize()
18 SwiftUI.NSHostingView.updateWindowContentSizeExtremaIfNecessary()
19 SwiftUI.NSHostingView.updateConstraints()
...
50 -[NSApplication run]
55 Skylark_main
```

An uncaught ObjC exception during Auto Layout while a SwiftUI-hosted window sizes itself at launch.

**Expected:** with Accessibility missing, show onboarding and guide the user to grant it.

**Why this is the top-priority item:** this is plausibly the **first-run path for a new user**. A fresh install has no Accessibility grant, presenting the same "not trusted" state. If the onboarding window is what crashes, then the window whose entire job is to walk a non-technical user through granting permissions is the window that cannot survive not having them. The only escape is System Settings → Privacy & Security → Accessibility → **+** → `/Applications/Skylark.app`, which is exactly the step a non-technical user will not find.

**Action before shipping:** on a machine that has *never* granted Skylark Accessibility, confirm whether onboarding appears or crashes. This was not testable here without a clean TCC state. If it crashes, every new install is bricked on first launch.

---

### F7 — CRITICAL — Revoking Accessibility while running wedges Skylark into a permanent fake "recording" state (and took the machine down)

**Repro (1/1, deterministic)**
1. Skylark running, dictation confirmed working (baseline 198 ms, text pasted).
2. `tccutil reset Accessibility com.jjromano.skylark` (scoped to Skylark only).
3. Press the trigger and speak.

**Saw**
- No text injected, on that attempt or any subsequent one.
- HUD pill stuck showing a **red recording dot with a flat, dead waveform**, indefinitely.
- macOS menu-bar **microphone indicator stayed lit** — the system believed the mic was in continuous use.
- Log looped every 60 seconds, forever:

```
hotkey:   event tap disabled (timeout); re-enabling + reconciling trigger state
hotkey:   interruption mid-session (tap timeout); finalizing the utterance at this boundary
hotkey:   reconcile: synthetic triggerUp for keyboard f13 (was held, now reads released)
pipeline: capture interrupted (triggerTapStalled) — recording continues
```

- **Nothing** names TCC or Accessibility — no alert, no menu-bar change, no log line.
- Shortly after, system input became unresponsive; the Mac needed a hard restart.

**Expected:** detect the lost grant, drop the recording state, tell the user which permission to restore, and offer a button to the right Settings pane.

**Root shape:** the real, diagnosable cause (permission revoked) is reported internally as a generic *tap stall*, so recovery logic retries forever against a condition retrying cannot fix. A global HID event tap stuck in that loop is a **system-level** hazard, not merely an app-level one.

---

### F1 — CRITICAL — Deep vocabulary matching overwrites unrelated words with dictionary terms on every cleaned dictation

This is the shipped configuration on the Air (`dictionary.deepVocabMatching = 1` + cloud cleanup), so it has been corrupting real dictations.

**Repro**
1. Dictionary holds two entries: `CLAUDE.md` (misspellings `CLOD.md`, `Cloud.md`) and `Claude` (misspelling `clod`).
2. `defaults write com.jjromano.skylark dictionary.deepVocabMatching -bool true`
3. `defaults write com.jjromano.skylark cleanupTierOverride -string "cloud"` — also reproduces with `"local"` + `localCleanupBackend=qwen3-4b`.
4. Relaunch. Dictate: *"The meeting starts at three and we should bring the budget spreadsheet."*

**Saw (5/5, cloud `openai/gpt-oss-20b`)**

```
"The Claude at Claude and we should bring the Claude."
"The meeting Claude and we should bring the Claude."
"Claude starts at Claude and we should bring the budget Claude."
"The meeting Claude and we Claude Claude."
"Claude and we should bring the budget spreadsheet."      <- whole opening clause deleted
```

None of *meeting, starts, three, budget, spreadsheet* resembles "Claude".

**Rate:** 10/10 corrupted with deep vocab ON (5 cloud + 5 local Qwen3-4B). 0/10 with it OFF (3 Qwen + 5 cloud + raw controls). Not engine-specific — local and cloud both. Requires a non-raw cleanup tier; `raw` is unaffected.

**Evidence** — `history` row 1353:

```
raw_text   = "The meeting starts at three and we should bring the budget spreadsheet."
clean_text = "The Claude at Claude and we should bring the Claude."
```

**User harm:** the correct raw text is injected first, then silently replaced by the corrupted cleaned text. The user watches good text turn into garbage.

**Notable:** the diagnostics export already computes `likely cleanup truncation (clean words < 50% of raw): 2` and correctly counted these. The app can detect the condition but never surfaces it at dictation time.

**Immediate mitigation (no code needed):** Settings → Dictionary → **Deep vocabulary matching OFF**. This has been left OFF on the Air.

---

### F2 — HIGH — Text and a synthesized Return land in the wrong window of the *same* app

The focus guard compares bundle IDs, so a second window of the same app is invisible to it.

**Repro (3/3)**
1. TextEdit with two documents: `scratch1.txt` (intended target, focused) and `scratch2.txt` containing `ORIG2`.
2. `pressEnterCommandEnabled = true`, local Parakeet, raw cleanup.
3. Hold trigger, play clip *"Meet me on Friday press enter"*, release.
4. At release + 0.0 s: `osascript -e 'tell application "TextEdit" to set index of window "scratch2.txt" to 1'`

**Saw:** `scratch1.txt` **empty**. `scratch2.txt` = `"ORIG2 Meet me on Friday"` **plus a real synthesized Return**.
**Expected:** text in scratch1, or a refusal with a notice.
**Log:** `inject target: frontmost=com.apple.TextEdit focusedRole=AXTextArea axEditable=true` — no focus-guard line fires.

**Cross-app case works correctly.** Switching to a different app (Script Editor) at release logs `focus guard: captured target re-activated before injection`, and Skylark force-reactivates the original app and injects correctly. Worth documenting that the actual guard behavior is **re-activate the original app**, not "refuse + notice" — it means Skylark yanks focus back from a deliberate app switch.

**Risk:** two Mail compose windows, two Slack windows, two editor windows — same app, wrong window, plus a Return.

---

### F4 — HIGH — Clipboard restore destroys a copy the user makes during the restore window

Paste-fallback path only (`inject: paste`). Restore fires ~115–140 ms after the target reads the pasteboard and blindly writes the pre-dictation snapshot back, with no check for whether the clipboard changed in the meantime.

**Repro (4/4)**
1. A Terminal window running `cat > /tmp/scratch.txt` frontmost (a genuine paste-fallback target).
2. `printf 'PRECLIP-SENTINEL' | pbcopy`
3. Dictate a short clip. Poll `pbpaste` every 20 ms; the instant the transcript appears, `printf 'NEWCOPY' | pbcopy`.
4. Wait 2 s, read `pbpaste`.

**Saw:** `PRECLIP-SENTINEL` — the user's `NEWCOPY` was silently overwritten.
**Expected:** `NEWCOPY` survives. A copy made after the paste is the user's intent and must win.
**Log:** `clipboard restored: trigger=read after-ms=116.2 reads=1`

**Real-world:** dictate into Terminal / VS Code / any Electron app, then immediately ⌘C something — your copy vanishes and you paste the wrong thing.

---

### F6 — HIGH — Hands-free silently discards everything past 120 seconds, and VAD never ends the session

Two interacting defects.

**(a) VAD never endpointed the session.** Started hands-free, played a 143.5 s monologue, then left the room silent for a further 45 s. The HUD still showed a live red dot and waveform at ~4 minutes. It only ended on an explicit `open skylark://record/stop` at 253 s wall time.

**(b) Capture is hard-capped at 120 s and the overflow is dropped silently:**

```
audio:    capture hit 120s cap; clip truncated
pipeline: capture finalize — interrupted: true [stalledTap,vad],
          trimmed-ms: 830, kept-ms: 119098, wall-ms: 253243
```

Markers spoken at ~0 s, ~52 s, ~122 s, ~140 s:

| marker  | approx. time | present in transcript |
|---------|--------------|-----------------------|
| alpha   | 0 s          | yes                   |
| bravo   | 52 s         | yes                   |
| charlie | 122 s        | **LOST**              |
| delta   | 140 s        | **LOST**              |

`history` row 1393: `duration_ms=119098`, `rawlen=2027`, `latency_ms=1760`.

**(c) The cap then misdiagnoses itself as a hardware fault:**

```
audio: capture sample duration 119.93s ≪ wall 253.24s
       — input tap likely stalled (possible mic interruption)
```

The tap did not stall; the deliberate 120 s cap truncated the buffer, and the sample-vs-wall comparison concludes the microphone was interrupted. The user is told their mic was interrupted when they actually hit a designed limit — wrong cause leads to wrong user action. Same shape as F7.

**Memory:** RSS 93 MB before the long capture → 195 MB after, not reclaimed within 25 s.

**Not confirmed:** which notice string the user actually sees. `interrupted: true` suggests the "Mic interrupted, text may be incomplete" path fires; this was not visually verified.

---

### F3 — MEDIUM — Cancel after key release is silently ignored

**Repro (3/3, cloud STT so the window is ~350–680 ms)**
1. Hold trigger, play clip, release.
2. Send Esc (HID keycode 53) at release + 0.15 s and + 0.35 s; separately `open "skylark://record/cancel"` at + 0.15 s.

**Saw:** text pasted normally every time. No log line mentions the cancel; nothing in the UI reports it was refused.
**Expected:** either the paste is cancelled, or the user is told the cancel arrived too late.
**Control:** Esc *during* recording cancels correctly (empty document, 1/1).

The window is ~180 ms on local Parakeet, ~350–680 ms on cloud STT.

---

### F5 — MEDIUM — Deep links activate Skylark, so deep-link dictation pastes into Skylark itself

**Repro (1/1):** TextEdit focused, `open skylark://record/start`, speak, `open skylark://record/stop`.

**Saw:** `inject target: frontmost=com.jjromano.skylark focusedRole=AXOutline axEditable=false` → clipboard paste fallback into Skylark's own window. `history` row records `app_name = "Skylark"`. The dictation is lost.
**Expected:** text goes to the app focused when recording began.
**Scope:** affects anyone driving Skylark from Shortcuts / Stream Deck / scripts. Does **not** affect the Fn/F13 hotkey path.

---

## 3. Confirmed working

- **Latency — comfortably inside the PRD bar.** Local Parakeet **median 184 ms**, n=37, range 166–220 ms. The menu-bar readout agrees with `latency_ms` in the database and with when text visibly appeared, so the readout is measuring the right thing.
- **Offline fallback.** Cloud STT + cloud cleanup selected, Wi-Fi off: transparently fell back to local Parakeet, pasted the full correct text in **220 ms**, no hang, no error.
- **Diagnostics export is clean.** All 100 lines read. No API key or key-shaped string, no transcript or cleaned text, no dictionary or snippet content, no `/Users/<name>` paths. Settings snapshot accurate.
- **Local mode makes zero network connections**, sampled throughout a full dictation.
- **Clipboard preservation on the normal path.** A genuinely rich 5-type clipboard (HTML 72 KB + utf8 + ut16 + string + Unicode) survived a paste-fallback dictation intact, verified with `clipboard info` before and after.
- **The late cleanup swap does not clobber typing.** Typed ` AND_I_TYPED_THIS` at release + 0.45 s, between the raw paste and the cleaned swap. Result: `"The meeting starts at three, and we should bring the budget spreadsheet. AND_I_TYPED_THIS"` — the comma was correctly inserted by the swap and the typed text survived.
- **Cross-app focus guard works** (the same-app gap is F2).
- **Esc during recording cancels cleanly.**
- **Settings toggles are real stored properties.** Every `defaults write` made was reflected correctly in the UI — no stuck controls (the CLAUDE.md `@Observable` trap does not appear to have regressed).

---

## 4. Privacy observation — the dictionary is uploaded on every cloud cleanup

Measured with `nettop` byte counts, same clip, warm process, three runs each:

| dictionary size | bytes out per dictation |
|---|---|
| 2 entries (45 bytes of text) | ~3713 / 4458 / 3857 → **mean ≈ 4009** |
| 102 entries (10 521 bytes of text) | ~8949 / 8949 / 8805 → **mean ≈ 8901** |

Delta ≈ **+4.9 KB** for +10.5 KB of added dictionary text — consistent with the full dictionary being serialized into every request body.

Notable: the dictated sentence contained **none** of the added terms, and `deepVocabMatching` was **OFF** for these measurements. Nothing in the UI discloses this. The Dictionary pane describes deep vocabulary matching as *"Runs a second, on-device acoustic pass"* — accurate about that feature, but there is no statement anywhere that dictionary contents leave the machine during cloud cleanup. Dictionaries hold names, clients, and private jargon.

This corroborates the static audit's claim from the outside; confirming the literal request body would need TLS interception, which was not set up.

---

## 5. Recommendations

1. **Fix F8 first.** Verify the never-granted first-run path on a clean machine. If onboarding crashes without Accessibility, every new install is dead on arrival and Stephanie cannot self-recover.
2. **Ship the F1 fix, or default `deepVocabMatching` to off.** It corrupts real work daily and the mitigation is a single toggle.
3. **Treat "permission revoked" as a first-class state.** F7, F6(c) and F8 are one bug shape: a specific, diagnosable cause is collapsed into a generic stall/fault, then retried forever or crashed on. Check the actual TCC grant before concluding "tap stalled", and never present a recording UI with the mic held when injection is impossible.
4. **Bound the event-tap retry loop.** A stuck global HID tap is a system-level hazard. Retry a few times, then give up loudly rather than looping every 60 s indefinitely.
5. **Disclose cloud dictionary transmission** in the Dictionary pane and/or the cloud-cleanup setting.
6. **Surface the 120 s cap while recording**, not after — a countdown or colour change on the pill, so speech is never discarded silently.
7. **Make cancel honest** — either extend it through the processing window or tell the user it arrived too late.
8. **Make the clipboard restore conditional** — only restore if the pasteboard `changeCount` still matches what Skylark wrote (fixes F4).

---

## 6. Latency data

Local Parakeet, TextEdit target, short/medium utterances, n = 37:

| statistic | value |
|---|---|
| median | **184 ms** |
| mean | 184 ms |
| min | 166 ms |
| max | 220 ms |

Cloud `openai/whisper-large-v3-turbo`, n = 12: median **350 ms**, mean 412 ms, range 278–678 ms.

PRD §12 target is **under 300 ms** end-of-speech to pasted raw text for a short local utterance — **met**, with margin. Database `latency_ms` matched the readout on every sampled row.

Outlier for context: the 119 s hands-free clip from F6 took 1760 ms total (transcribe 646 ms, inject 1100 ms).

---

## 7. Verdict on `docs/validation-checklist.md`

**§2's clipboard step cannot detect F4 — it passes precisely *because* the bug occurs.** It reads: *"paste again manually (Cmd-V) somewhere → your ORIGINAL clipboard content must come back intact."* That is exactly the behavior that destroys a copy made during the restore window. Needs a second clause: copy something new immediately after the paste and confirm **that** survives.

**§1 "double-tap Fn → hands-free; stops by itself ~1 s after you stop speaking (VAD)" — FAILED** (F6a). VAD never ended the session; 45 s of silence and it was still recording.

Other issues:
- **No coverage of the 120 s capture cap** anywhere in the runbook.
- **§4 names stale models** — "Groq Fast Whisper", "Llama 3.1 8B" versus the current registry (`openai/whisper-large-v3-turbo`, `openai/gpt-oss-20b`).
- **§2 instructs dictating into Messages, Mail, Slack/Discord** — precisely the surface where a wrong-window paste plus a synthesized Return sends something. Given F2 and the press-enter feature, that step should specify draft-only targets.
- **§0 onboarding steps were unverifiable** here because permissions were already granted — and F8 suggests that is the single most important part of the runbook to actually exercise.

Passed as written: §0 install end-to-end; §1 hold-and-speak, sub-300 ms, Esc cancels; §2 swap-does-not-clobber; §4 Wi-Fi-off fallback; §7 median latency.

---

## 8. Not tested, and what would unblock it

| Area | Why not | Unblocked by |
|---|---|---|
| All Fn-specific behavior (Globe swallow, Fn+arrow, fn-flag traps, stray-tap) | Trigger was rebound to F13 | A human at the keyboard |
| Onboarding / never-granted first-run | Needs a clean TCC state | A fresh machine or VM — **highest priority given F8** |
| Sleep/wake event-tap watchdog | Dropped after the hard restart | A human present; low risk once F7 is fixed |
| No-API-key and invalid-key states | Sandbox blocked reading the key; stopped rather than risk it | Running it with the key backed up first |
| Apple Intelligence cleanup tier, and AI-off fallback | Not exercised | Straightforward, just time |
| Whisper Mode, quiet speech, VAD-trim A/B | Tier 0 cannot attenuate reliably | BlackHole virtual audio device |
| AirPods/Bluetooth, device yanked mid-utterance, capture-start failure | No second audio device | Any USB or BT mic |
| Engine switch mid-transcription, WhisperKit, model download / mid-download / interrupted download | No model was ever deleted | Time + bandwidth |
| History UI, auto-learn, snippets, modes, translation, Command Mode, update check | Not reached | Time |
| Target coverage beyond TextEdit / Terminal / Script Editor | Chrome had Gmail open and VS Code had an SSH shell; both deliberately avoided | A clean desktop |
| HUD motion quality, felt latency, Wispr Flow comparison | Not judgeable from screenshots | JJ |
| Literal cloud request bodies | No TLS interception | mitmproxy + CA trust |

---

## 9. Machine state at handoff

Restored to the pre-session configuration:

- `hotkey.keyboard` → `fn`
- `cleanupTierOverride` → `cloud`; `modelSelection.sttChoice` → `cloud:openai/whisper-large-v3-turbo`
- `pressEnterCommandEnabled`, `localCleanupBackend`, `vadClipTrimEnabled` — removed (absent before this session)
- Dictionary back to the original 2 entries; the 100 injected test entries deleted
- OpenRouter key present and untouched; the temporary QA backup Keychain entry deleted
- Wi-Fi on; no models deleted; diagnostics export removed from `~/Documents`
- Accessibility re-granted manually; Skylark verified launching and running

**Deliberate exception:** `dictionary.deepVocabMatching` is left **OFF** (it was `1`). This is the F1 mitigation — restoring the original value restores the corruption.

**Leftovers to clear if desired:** Automation grants for Terminal → Script Editor and Terminal → TextEdit (System Settings → Privacy & Security → Automation), and a couple of scratch TextEdit windows.

**Security note:** during the session the OpenRouter API key was printed to a terminal in order to back it up, so it exists in that session transcript. Recommend rotating it at openrouter.ai and pasting the new key via Settings → Account → Replace. The key does not appear in this document, in the diagnostics export, or in any file written during the session.

---

## 10. Reproduction harness

Built under the session scratchpad; recreate as needed.

```bash
# 1. Generate a deterministic clip
say -r 170 -o clip.aiff "The meeting starts at three and we should bring the budget spreadsheet."
afconvert -f WAVE -d LEI16@16000 -c 1 clip.aiff clip.wav

# 2. Hold the trigger at HID level (session-level synthesis is NOT seen by Skylark)
#    keyhold.swift: CGEvent(keyboardEventSource:virtualKey:keyDown:)?.post(tap: .cghidEventTap)
#    F13 = keycode 105, Esc = 53
./keyhold 105 5.1 &        # hold for pre + clip duration + post
sleep 0.6; afplay clip.wav

# 3. Observe
log stream --predicate 'subsystem == "com.jjromano.skylark"' --level debug --style compact
sqlite3 ~/Library/Application\ Support/Skylark/skylark.sqlite \
  "select id, engine, cleanup_engine, latency_ms, app_name, raw_text, clean_text
     from history order by id desc limit 5;"
nettop -P -x -l 1 -p "$(pgrep -x Skylark)"      # bytes in/out; lsof does NOT work here
osascript -e 'clipboard info'                    # all pasteboard types + sizes
```

Rebind the trigger with `defaults write com.jjromano.skylark hotkey.keyboard -string "f13"` and restore with `-string "fn"`.
