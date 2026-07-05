# Phase 5b spec — README, install script, app icon, privacy audit report

You are in an isolated worktree. **You own: README.md, Scripts/, Makefile,
Resources/ (Info.plist icon key + icon assets), and a new `docs/` dir if
useful. Do NOT modify anything under `Sources/` or `Tests/` — report needed
source changes instead.** Read `ARCHITECTURE.md`, `CLAUDE.md`,
`Skylark_Dictation_PRD.md` §4 (repository/licensing) and §8, plus the current
`Scripts/` and `Makefile`, before writing.

## Work items

### 1. README.md (the repo face — for a competent Mac user who is NOT the author)
Sections:
- What Skylark is (dictation app, local-first, latency-focused; one
  screenshot placeholder comment for later).
- Requirements: Apple Silicon Mac, macOS 26+, ~1.2 GB disk for models
  (Parakeet ~483 MB required, Whisper ~626 MB optional), Command Line Tools
  (`xcode-select --install`) — no Xcode needed.
- Install (from source): `git clone … && cd skylark && ./Scripts/install.sh`
  — and what the script will do, including the one sudo prompt (signing cert)
  and why (TCC permission persistence).
- First run: the three permissions walkthrough (Microphone, Accessibility,
  Input Monitoring — what each is for, in plain language), the Globe-key
  note ("Press 🌐 key to: Do Nothing" recommendation OR rely on Skylark's
  suppression — describe actual behavior from AppController/HotkeyMonitor),
  model download on first launch.
- Usage: hold Fn to talk, release to paste; double-tap Fn for hands-free
  (auto-stops on silence); ESC cancels. Menu bar: modes, cleanup tiers,
  models, Whisper Mode, History.
- Cloud (optional): create an OpenRouter key, add it in Settings → Account;
  what leaves the machine and when (be precise: audio clips only for cloud
  STT, transcripts only for cloud cleanup; nothing in local mode).
- Privacy summary (from §4 below).
- Troubleshooting: permissions reset (`tccutil reset … com.jjromano.skylark`),
  rebuild loses permissions only if the cert is missing, Bluetooth mic
  quality, Apple Intelligence required for local cleanup (Settings path),
  logs via Console/`log stream --predicate 'subsystem == "com.jjromano.skylark"'`.
- Building/dev: `make build/test/app/run/cert`, `Scripts/bench.sh`, test
  runner caveat (CLT-only boxes use `make test`), toolchain pin (Swift 6.2.x,
  macOS 26 SDK), dependency list with licenses (FluidAudio Apache-2.0,
  WhisperKit MIT, GRDB MIT) and the Hex/handy-keys adaptation attribution.
- License: MIT.
Keep it tight and skimmable; no marketing fluff.

### 2. Scripts/install.sh (Stephanie path)
- Checks: Apple Silicon, macOS ≥ 26, CLT present (offer `xcode-select
  --install` and exit with clear instructions if missing).
- Runs `make cert` (explaining the sudo prompt before it appears; skip if
  identity already present), `make app`, copies `dist/Skylark.app` to
  `/Applications` (ask before overwrite), opens it, prints the
  first-run permissions cheat-sheet.
- Idempotent; `set -euo pipefail`; every failure exits with a
  human-actionable message.

### 3. App icon
- Generate an icon with a small self-contained Swift script
  (`Scripts/make-icon.swift`, run via `swift Scripts/make-icon.swift`):
  CoreGraphics drawing — rounded-rect gradient (deep indigo → sky blue), a
  clean white bird/feather silhouette drawn with bezier paths (simple and
  geometric is better than clever; it must read at 16 px), render all 10
  iconset sizes, `iconutil -c icns` → `Resources/AppIcon.icns` (commit the
  .icns, not the iconset). Wire `CFBundleIconFile` into Info.plist and make
  `bundle.sh` copy it. Verify the .icns lands in the bundle via `make app`.

### 4. Privacy audit (report + fixes limited to your files)
Sweep `Sources/` read-only and produce `docs/privacy-audit.md`:
- Every network touchpoint (should be exactly: OpenRouter client, FluidAudio
  HF model download, WhisperKit HF model download) with when it fires.
- Every place audio or transcript content could be written to disk or logs —
  verify: no transcript/audio in Logger calls (grep for interpolations in
  `logger.` lines), history is local SQLite, audio retention default OFF.
- Keychain-only secrets confirmed (no key in UserDefaults/files/logs).
- Clipboard behavior summary.
- Anything questionable → list under "Findings" with file:line; do NOT fix
  source yourself.

## Acceptance
1. `bash -n` both scripts; run `swift Scripts/make-icon.swift` and `make app`
   to prove the icon pipeline (build must stay clean).
2. README renders sanely (no broken relative links).
3. Report: files touched, audit findings count + highlights, deviations.

Git: single commit on your worktree branch (no push, no merge).
