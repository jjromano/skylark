# Skylark — project context for Claude Code

Native Swift/SwiftUI macOS menu-bar dictation app. Read
`Skylark_Dictation_PRD.md` (product spec) and `ARCHITECTURE.md` (design of
record) before working. Latency is the product: never add blocking work to the
audio or paste path.

## Machines

- **Build/dev box:** JJ's always-on headless Mac Mini (M4, 24GB, macOS 26).
  Apple Intelligence is OFF here by choice — Foundation Models reports
  `.appleIntelligenceNotEnabled`; treat that as a supported runtime state, not
  an error. No interactive testing here (no mic/keyboard/screen use).
- **Target machines:** the primary MacBook Air (M3, 16GB) and a second
  user's MacBook Pro. Latency/memory acceptance (PRD §12) is judged on the M3 Air, not the
  Mini — Mini benchmarks are advisory.
- Distribution = build from source on each target machine (planned
  `Scripts/install.sh`); never assume a binary built on one machine is
  trusted on another.

## Build (SwiftPM only — no Xcode on this machine)

```sh
swift build                 # debug build
swift test                  # unit tests
make app                    # release build → dist/Skylark.app (bundled + signed)
make run                    # build app bundle and launch it
```

- Toolchain: Swift 6.2.x via Command Line Tools, macOS 26. Do NOT introduce
  anything requiring xcodebuild or an .xcodeproj.
- Signing uses the local self-signed "Skylark Dev" cert (`Scripts/make-cert.sh`
  creates it once). Never switch to ad-hoc signing — it breaks TCC permission
  persistence across rebuilds.

## Orchestration

This project is built by a Fable orchestrator delegating to subagents defined
in `.claude/agents/` (`opus-implementer` for latency/system-API work,
`sonnet-implementer` for views/stores/tests/docs). Specs come from the
orchestrator; implementers report deviations rather than silently redesigning.

## Versioning (v0.1.0 is complete — bump on every change)

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

## State that does not travel between worktrees

Runtime state lives outside the repo: downloaded CoreML models
(~/Library/Application Support/Skylark/… once implemented), Keychain entries,
TCC grants. Nothing to copy between worktrees; all worktrees share them.
