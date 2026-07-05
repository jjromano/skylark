# Skylark — project context for Claude Code

Native Swift/SwiftUI macOS menu-bar dictation app. Read
`Skylark_Dictation_PRD.md` (product spec) and `ARCHITECTURE.md` (design of
record) before working. Latency is the product: never add blocking work to the
audio or paste path.

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
