# Skylark

A native macOS menu-bar dictation app. Hold a key, talk, get clean text at
your cursor — running entirely on-device by default, with optional cloud
speech-to-text and cleanup for when you want higher accuracy. Latency is the
design priority: local dictation targets under 300 ms from the end of your
speech to raw text landing at the cursor.

![Skylark listening: the notch HUD pill with a live waveform, and the menu-bar mic active](docs/assets/hud-listening.png)

Skylark is a personal, open-source project (MIT). It is not on the App
Store; you build it from source and sign it with a certificate generated on
your own Mac.

## Requirements

- Apple Silicon Mac (M1 or later).
- macOS 26 or later.
- Command Line Tools only — **no Xcode required.** If you don't already
  have them: `xcode-select --install`.
- About 1.2 GB of free disk for local speech models: Parakeet TDT v3
  (~483 MB, downloaded automatically on first launch) plus Whisper
  large-v3-turbo (~626 MB, optional — only downloaded if you switch to it).

## Install (from source)

```sh
git clone https://github.com/jjromano/skylark.git
cd skylark
./Scripts/install.sh
```

`install.sh`:

1. Checks you're on Apple Silicon, macOS 26+, and that the Command Line
   Tools are installed (and tells you exactly what to run if not).
2. Creates a local self-signed "Skylark Dev Signing" certificate, if one
   doesn't already exist. **This is the one sudo prompt** — the script asks
   for your password to add the certificate to the System keychain as
   trusted for code signing. It's needed because macOS ties Accessibility,
   Microphone, and Input Monitoring grants to the app's signing identity;
   without a stable identity, every `swift build` would look like a new app
   and you'd have to re-grant permissions after every rebuild.
3. Builds the release binary and assembles `dist/Skylark.app`.
4. Copies it to `/Applications` (asks first if something is already there).
5. Opens the app and prints the first-run permissions cheat-sheet below.

The script is idempotent — safe to re-run any time you pull updates and want
to rebuild.

## First run

Skylark asks for three permissions, all standard for a system-wide dictation
tool:

| Permission | Why |
|---|---|
| **Microphone** | To record what you say. |
| **Accessibility** | To insert text directly at your cursor via the Accessibility API (no clipboard involved when this path works). |
| **Input Monitoring** | To detect the global Fn (Globe) key hotkey system-wide, even when Skylark isn't the frontmost app. |

macOS will prompt for each in turn; Skylark also opens the relevant System
Settings pane if a grant is missing. Nothing records or types until all
three are granted.

**About the Globe/Fn key:** Skylark installs a system-wide event tap on the
bare Fn key and swallows the key-down/up pair itself, which suppresses
macOS's own Globe action (emoji picker / input-source switch / dictation,
depending on your System Settings binding) while Skylark is running — you
don't need to change your Fn key binding in System Settings first. If you'd
rather make the intent explicit (or if you ever run without Skylark active),
set **System Settings → Keyboard → Press 🌐 key to: Do Nothing**.

**First-launch model download:** the first time you dictate, Skylark
downloads the Parakeet speech model (~483 MB) from Hugging Face in the
background. Dictation works as soon as it finishes; the menu bar shows
download progress in the meantime.

## Usage

- **Hold the dictation key, speak, release** — push-to-talk. The key is Fn
  (Globe) by default and configurable in Settings → General (right ⌘/⌥/⌃ or
  F13–F19), plus an optional mouse trigger (middle / button 4 / button 5).
  Text is inserted at your cursor right after release; a lightly-cleaned
  version replaces it a moment later (see Cleanup, below). Releasing before
  ~0.3 s of hold is treated as a stray tap and discards the clip rather
  than pasting.
- **Double-tap the key** — hands-free mode: keeps recording until it detects
  silence (Voice Activity Detection auto-stops it), or until you press the
  key again to stop it manually. How long a pause counts as silence is
  configurable in Settings → General (1–3 s; push-to-talk is unaffected).
- **Voice Command Mode** — select text, hold the command-mode key (Settings →
  General; unbound by default), and speak an instruction ("make this
  formal", "translate to Spanish") to rewrite the selection in place.
- **Esc** — cancels the current recording (push-to-talk or hands-free)
  without inserting anything.
- **Say "… press enter"** (opt-in, Settings → General) — strips the command
  and presses Return after the text lands, for firing off chat messages.
- **Say a snippet trigger** (Settings → Snippets) — saying a saved trigger
  phrase by itself ("my email address") types its replacement instead.

The menu-bar icon (a bird) opens a dropdown with:

- **Status line** — Idle / Listening / Processing, the last dictation's
  end-to-end latency in ms, and today's dictated word count.
- **Cleanup** — Auto / Raw / Local / Cloud, overriding the cleanup tier for
  every dictation until changed back.
- **Cleanup Model** — pick which cloud cleanup model quick-switches to when
  Cloud is active, or enter a custom OpenRouter model slug.
- **Speech Engine** — Local (Parakeet), Local (Whisper large-v3-turbo), or
  any cloud STT model from the registry, plus a custom-slug option.
- **Whisper Mode** — toggles quiet-speech tuning (boosted input gain, more
  sensitive VAD) for dictating at low volume in shared spaces.
- **History…** — searchable browser for past dictations: view raw vs.
  cleaned text, copy, delete, or edit an entry. Edits are diffed against the
  raw transcript and offered as custom-dictionary auto-adds (or learned
  automatically — Settings → History), so correcting a name once teaches
  Skylark to get it right next time.
- **Settings…** — General (dictation shortcut, recording-indicator style,
  behavior toggles, cleanup default, sounds + volume, launch at login),
  Insights (words dictated, WPM, time saved, streaks, activity heatmap),
  Models (download/delete local models, cloud catalog with cost estimates),
  Audio (input device picker, Whisper Mode), Dictionary, Snippets, Modes
  (per-app profiles), History (retention, audio retention, auto-learn), and
  Account (API key, version + Check for Updates).
- **Onboarding…** — re-opens the permissions walkthrough and hotkey tutorial.
- **Quit Skylark**.

## Updating

Settings → Account → **Check for Updates** compares your build against the
GitHub repo and, on **Update Now**, opens Terminal to `git pull` and re-run
`install.sh`. Or do the same by hand:

```sh
cd skylark && git pull && ./Scripts/install.sh
```

## Cloud (optional)

Local mode needs no account and works fully offline. To enable cloud speech
recognition or cloud cleanup:

1. Create a key at [openrouter.ai](https://openrouter.ai/keys).
2. Open Skylark's menu bar → **Settings…** and paste the key into the
   OpenRouter API key field. It's validated immediately and stored in the
   macOS Keychain — never in a file, UserDefaults, or a log.
3. Pick a cloud entry from **Speech Engine** and/or set **Cleanup** to
   Cloud / pick a **Cleanup Model**.

What leaves the machine, precisely:

- **Local mode (default):** nothing. No audio, no transcript, no network
  call of any kind.
- **Cloud speech-to-text:** the recorded audio clip is sent to OpenRouter
  for that one utterance. Nothing else.
- **Cloud cleanup:** the raw transcript text (not audio) is sent to
  OpenRouter for that one utterance. Nothing else.
- If a cloud call fails or times out, Skylark transparently falls back to
  the local engine with a small non-blocking notice — it does not silently
  retry against the network in a loop.

## Privacy summary

- No telemetry, ever.
- No audio or transcript content in logs, in either mode.
- Local mode is fully offline: zero network calls.
- Cloud calls happen only for the specific stage you've enabled (STT and/or
  cleanup), only for the current utterance, never as a background upload.
- Dictation history (text, not audio) is stored locally in SQLite. Audio
  retention is **off by default**; if you opt in, audio is saved locally
  only and never uploaded.
- The OpenRouter API key lives only in the macOS Keychain.
- Clipboard-preserving paste: when direct Accessibility insertion isn't
  possible and Skylark falls back to a synthesized paste, it snapshots your
  full clipboard (every type, every item) first and restores it afterward —
  your clipboard is byte-for-byte unchanged once dictation finishes. If the
  synthesized paste itself fails to go through, Skylark leaves the
  transcript on the clipboard as a manual-paste fallback instead of
  restoring your prior contents — the one case where the clipboard changes.

See `docs/privacy-audit.md` for the full source-level audit (network
touchpoints, logging, Keychain-only secrets, clipboard behavior) with
file:line citations.

## Troubleshooting

- **Reset permissions** (e.g. to re-run the onboarding flow from scratch):
  ```sh
  tccutil reset Microphone com.jjromano.skylark
  tccutil reset Accessibility com.jjromano.skylark
  tccutil reset ListenEvent com.jjromano.skylark
  ```
- **Rebuilding loses my permissions.** This only happens if the "Skylark Dev
  Signing" certificate is missing (ad-hoc signing doesn't preserve TCC
  grants across rebuilds). Run `make cert` once, then `make app` — a
  stable signing identity is exactly what keeps grants intact after that.
- **Bluetooth mic sounds bad / recognition is worse.** Any Bluetooth
  hands-free (HFP) input, including AirPods, forces macOS into a low-quality
  audio profile the moment the mic is active. Skylark surfaces a warning
  when you pick one in Settings → Audio; switch to the built-in mic or a
  wired/USB mic for best accuracy.
- **Local cleanup isn't running / says Apple Intelligence not enabled.**
  Tier 1 (local) cleanup uses Apple's on-device Foundation Models, which
  requires Apple Intelligence to be turned on for your Apple Account and
  region: **System Settings → Apple Intelligence & Siri**. Until it's
  enabled, Skylark reports the reason and dictation still works — you just
  don't get the cleanup pass (or switch Cleanup to Raw/Cloud in the menu
  bar in the meantime).
- **Logs.** Skylark logs status/errors (never transcript or audio content)
  under subsystem `com.jjromano.skylark`. View live:
  ```sh
  log stream --predicate 'subsystem == "com.jjromano.skylark"'
  ```
  or filter Console.app by that subsystem.

## Building / development

```sh
swift build                 # debug build
swift test                  # unit tests (needs a full Xcode install for the XCTest host)
make build                  # same as swift build
make test                   # unit tests via the standalone swift-testing runner (works on CLT-only boxes)
make app                    # release build → dist/Skylark.app (bundled + signed)
make run                    # make app, then open it
make cert                   # create/verify the self-signed signing identity (sudo)
make clean                  # remove .build and dist
Scripts/bench.sh            # headless local-decode latency benchmark, both engines
```

This machine builds with Command Line Tools only — there is no Xcode
project and none is planned. `swift test` builds fine everywhere but needs
a full Xcode install to actually run (it hosts XCTest); on a CLT-only box,
use `make test`, which runs the identical suite through the standalone
`swift-testing` runner instead.

**Toolchain:** Swift 6.2.x (Command Line Tools), macOS 26 SDK. Confirm with
`swift --version`.

**Dependencies:**

| Package | License | Role |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | Local Parakeet ASR + Silero VAD, Neural Engine |
| [argmax-oss-swift (WhisperKit)](https://github.com/argmaxinc/argmax-oss-swift) | MIT | Local Whisper large-v3-turbo fallback engine |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | SQLite persistence (history, modes, dictionary) |

The Fn-key event tap and push-to-talk/double-tap state machine are adapted
from [Hex](https://github.com/kitlangton/Hex) (MIT) and
[Handy](https://github.com/cjpais/handy) (MIT); adaptations are
marked with a source comment at the top of the relevant file
(`Sources/SkylarkCore/Hotkey/HotkeyMonitor.swift`,
`Sources/SkylarkCore/Hotkey/HotkeyProcessor.swift`,
`Sources/SkylarkCore/Permissions/PermissionsService.swift`).

## License

MIT — see `LICENSE`.
