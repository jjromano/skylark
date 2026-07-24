# Skylark — project context for Claude Code

Native Swift/SwiftUI macOS menu-bar dictation app. Read
`Skylark_Dictation_PRD.md` (product spec) and `ARCHITECTURE.md` (design of
record) before working. Latency is the product: never add blocking work to the
audio or paste path.

## Machines

- **Verify the machine before assuming what you can do** — `sysctl -n hw.model`,
  and check `SystemLanguageModel.default.availability` when it matters. Sessions
  run on the **Air** (Apple Intelligence ON, Skylark installed), where
  interactive and on-device-model testing works — don't assume you're on the
  headless Mini. On the **Mini**, Apple Intelligence is OFF: Foundation Models
  reports `.appleIntelligenceNotEnabled` — a supported runtime state, not an
  error — and there's no mic/keyboard/screen to test with.
- Latency/memory acceptance (PRD §12) is judged on the M3 Air; Mini benchmarks
  are advisory.
- Distribution = build from source on each machine (`Scripts/install.sh`); never
  trust a binary built on one machine on another.

## Build (SwiftPM only — no xcodebuild/.xcodeproj)

```sh
swift build                 # debug build
make test                   # run the unit suite (NOT `swift test` — see below)
make app                    # release build → dist/Skylark.app (bundled + signed)
make run                    # build app bundle and launch it
```

- **`swift test` does NOT run the tests here.** The CLT-only box has no XCTest
  host, so `swift test` builds the bundle and exits 0 having executed nothing —
  a silent no-op that looks green. Use `make test`, which runs the standalone
  swift-testing runner (`swift run SkylarkTestRunner --testing-library
  swift-testing`); pass `--filter <name>` to it to run a subset.
- Toolchain: Swift 6.2.x via Command Line Tools, macOS 26. Do NOT introduce
  anything requiring xcodebuild or an .xcodeproj.
- Signing uses the local self-signed "Skylark Dev" cert (`Scripts/make-cert.sh`
  creates it once). Never switch to ad-hoc signing — it breaks TCC permission
  persistence across rebuilds.

## Versioning (bump on every behavior/UI change)

Any change that lands on `main` after v0.1.0 and alters app behavior or UI
MUST, in the same commit or PR:

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` (MINOR for
   features, PATCH for fixes/polish) and increment `CFBundleVersion`.
2. Add a matching entry to `CHANGELOG.md`.

Users update via Settings → Account → Check for Updates (compares the
build's stamped git commit against GitHub `main`); the version string is the
human-readable label for what they're getting, so never ship behavior
changes under an unchanged version.

## Hard rules

- MIT repo: never copy GPL code (VoiceInk is reference-only). Hex/Handy/
  OpenWhispr are MIT — adaptation OK with a source comment.
- Secrets only in the macOS Keychain. No keys, tokens, or user paths in the
  repo or in UserDefaults.
- Never log audio or transcript content.
- Clipboard must be snapshot/restored around any synthesized paste.
- Local mode must work fully offline; an optional stage failing never blocks
  the core paste.
- Swift 6 strict concurrency: keep the build free of concurrency warnings.
- Any `AppController` setting bound to SwiftUI must be a STORED
  `private(set) var` (init from UserDefaults, setter assigns + persists).
  A computed property reading UserDefaults is invisible to `@Observable`,
  so the control writes the value but never re-renders — toggles/pickers
  appear dead or stuck. This bug shipped twice (v0.2.2 cleanupOverride,
  v0.7.3 dictionary/history toggles); grep for `UserDefaults` inside
  computed vars before adding a settings control.

## State that lives outside the repo

Downloaded models (`~/Library/Application Support/Skylark/…`), Keychain entries,
and TCC grants live outside the repo and are shared across all worktrees —
nothing to copy between them.
