# 🔧 Skylark debug handoff — DELETE THIS FILE WHEN DONE

> **This is a temporary, self-destructing note** for a Claude Code agent running
> **on the MacBook Air** (where Skylark actually runs), handed off from a session
> on the Mac Mini that was blind to the Air's runtime.
>
> **When you (the Air agent) have read this and pulled what you need, remove it:**
> ```sh
> git rm DEBUG_HANDOFF.md
> git commit -m "chore: remove debug handoff note"
> git push origin HEAD:main
> ```

---

## Where things stand

Skylark is **installed and launching** on the Air (M3, macOS 26.2). The install
saga is fully documented in the last several `git log` commits — read them for
context. In short, these were fixed to get here:

- PKCS#12 cert import on macOS 26 (empty-password + OpenSSL 3.x incompatibility)
- Self-signed trust settings (`trustRoot`, not `trustAsRoot`) + self-clean of
  stale identities
- `install.sh` now fails fast if Swift < 6.2 (the Air needed a CLT update)
- **Signing dropped `--options runtime`** — hardened runtime without a mic
  entitlement was making the microphone `.restricted` ("denied", not listed)

**Working now:** menu-bar app launches, **Microphone granted**, **Accessibility
granted**, Fn hotkey tap fires (the HUD widget expands on Fn-down). Skylark is a
menu-bar-only app (`LSUIElement`) — no Dock icon, no window; the mic glyph in the
menu bar is the whole GUI.

## The open bug

Dictation via Fn:
1. **First attempt:** audio captured (waveform animated in the HUD), **but no
   text pasted.**
2. **Second attempt:** HUD widget expands (listening), but **no waveform** and no
   paste.

### Leading hypothesis (check this FIRST)

The Parakeet speech model (~483 MB) downloads on first use. The first dictation
almost certainly fired **before the model was ready**, so the clip was dropped:

- `Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:165`
  — `guard transcriberReady else { … }`
- `…/DictationOrchestrator.swift:245` — "Empty transcript → no injection at all."

**Cheapest check:** click the menu-bar mic icon and read the status/model line.
If it says preparing / downloading / not-ready, wait until it shows ready, then
retry. If that fixes it, the only real bug is UX (dictation should tell the user
"model still downloading" instead of silently dropping the clip).

## How to debug efficiently (you're on the right machine now)

Skylark logs its whole pipeline through **unified logging**, subsystem
`com.jjromano.skylark`, categories: `audio`, `vad`, `asr`, `injection`,
`pipeline`, `audio-devices`, `history`. It deliberately **never logs transcript
or audio content** (privacy rule), so streaming logs is safe.

**Live-stream while the user reproduces** (ask JJ to press Fn + speak):
```sh
log stream --predicate 'subsystem == "com.jjromano.skylark"' --level debug --style compact
```

**Or capture after a repro:**
```sh
log show --last 3m --predicate 'subsystem == "com.jjromano.skylark"' --info --debug --style compact
```

Confirm it's running / relaunch:
```sh
pgrep -xl Skylark || open -a Skylark
```

### Two questions the logs should answer
1. **Was the transcriber ready on attempt #1?** Watch the `asr` / `pipeline`
   categories — look for model prep/warm-up completion vs. the `transcriberReady`
   guard dropping the clip.
2. **Why no waveform on attempt #2?** Watch the `audio` category
   (`AudioCaptureService`, category `audio`) — did the capture session restart,
   or did it fail/stay stopped after the first run? A capture session not
   restarting cleanly between dictations would be a real bug.

### Code map (correlate with the log categories)
- Pipeline / readiness gate: `Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift`
  (see `:165` ready-gate, `:245` empty-transcript, `:265`–`:290` AX-vs-paste inject paths)
- Text injection: `Sources/SkylarkCore/Injection/TextInjector.swift` (category `injection`)
- Audio capture: `Sources/SkylarkCore/Audio/AudioCaptureService.swift` (category `audio`)
- VAD / endpointing: `Sources/SkylarkCore/Audio/SpeechEndpointer.swift` (category `vad`)
- Parakeet ASR: `Sources/SkylarkCore/Transcription/FluidAudioParakeet.swift`
  (`warmUp()`, `isReady`, category `asr`)
- Fn hotkey tap (Accessibility-gated, active `.cghidEventTap`):
  `Sources/SkylarkCore/Hotkey/HotkeyMonitor.swift`

### Model download location
Local models land under `~/Library/Application Support/Skylark/…` (per
`CLAUDE.md`); FluidAudio pulls Parakeet from Hugging Face. If the menu status
never reaches ready, check disk space and that the download actually completed.

## Build / rebuild on the Air (SwiftPM only, no Xcode)
```sh
make app     # release build → dist/Skylark.app (bundled + signed)
./Scripts/install.sh   # rebuild + reinstall to /Applications (idempotent)
```

## Notes / guardrails
- Don't re-add `--options runtime` to `Scripts/bundle.sh` — it re-breaks the mic.
- Latency is the product: never add blocking work to the audio/paste path.
- Read `CLAUDE.md` and `ARCHITECTURE.md` before changing pipeline code.

**Again: delete this file and push once you've used it (see top).**
