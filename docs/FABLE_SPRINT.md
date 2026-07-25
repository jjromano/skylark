# Skylark — Fable Sprint Handoff

> Detailed reference for a Claude **Fable** orchestration session. Read this and
> `CLAUDE.md` before starting. Kickoff note is at the bottom.

## Orchestration model (token-optimized)
**Fable orchestrates and owns the design/decisions; it does NOT write high-volume
code itself.** Each well-scoped execution task is delegated to a subagent:
- **opus subagent** → latency-critical audio, AX/pasteboard system APIs, the
  llama.cpp C binding, concurrency-sensitive lifecycle.
- **sonnet subagent** → routine views, stores, serialization, download managers,
  tests, docs.

Fable reviews each subagent's output, integrates it, keeps the cross-cutting
design coherent, and runs the release steps. Prefer delegating boilerplate.

## Non-negotiable constraints (from CLAUDE.md)
- **Latency is the product** — never add blocking work to the audio or paste path.
- **Never log audio or transcript content** (metadata only).
- **SwiftPM + Command Line Tools only** — no Xcode, no `metal` compiler. (This is
  why MLX is out and llama.cpp is in — see WS4.)
- Swift 6 strict concurrency, warning-free.
- Version-bump `Resources/Info.plist` (`CFBundleShortVersionString` +
  `CFBundleVersion`) and add a `CHANGELOG.md` entry on every behavior/UI change.
- **Run tests with `make test`** — `swift test` is a silent no-op on this box
  (no XCTest host); it runs `SkylarkTestRunner`. Filter subset with
  `swift run SkylarkTestRunner --testing-library swift-testing --filter <name>`.
- MIT repo — no GPL runtime deps (VoiceInk / nerd-dictation = ideas only).

## Already done — do NOT redo
- Shipped v0.7.5→v0.7.10: hotkey clip fix, number-hygiene fix, cleanup-prompt
  overhaul + `SpokenNumbers` + output-hygiene filter, history-UI fix,
  flapping/visible-degrades + configurable cleanup timeout, and the **cloud
  reasoning-model truncation** fix (`max_tokens` was sized for the answer only;
  reasoning ate the budget → first-few-words truncation).
- Diagnostics export feature + richer pipeline logging (v0.8.0).
- Quick wins (v0.8.1): `replace()` reports failure (history-lies bug), hotkey
  tap-liveness watchdog, detached clipboard-restore, explicit-modifier-flags on
  Cmd+V, transient-marker on pasted transcript, wall-clock-vs-samples stalled-tap
  log.
- **One small quick win deferred** (do early in the sprint or standalone): a
  Settings banner when `defaults read com.apple.HIToolbox AppleFnUsageType` is
  non-zero, warning that macOS's Fn behavior can fight the default Fn trigger
  (sonnet task; input0 `feature-single-key-hotkey.md`).
- **All research is complete** (cited inline) — subagents must not re-investigate.

## Cleanup eval harness (use to measure any cleanup change)
`SKYLARK_LIVE_CLEANUP_EVAL=1 make test` drives the real on-device model over
`CleanupCorpus` and prints MATCH/DIFF. Post-v0.7.7 Apple baseline: 13/17.

---

## WS1 — Interruption handling / silent-tail robustness  *(HIGH leverage)*
**Problem:** when the mic/focus is stolen mid-hold (Superwhisper, an OS Fn action,
a route change), Skylark records a full-length clip that is speech-then-silence →
the dictation drops everything after the first few seconds. v0.7.5's "keep
recording" bias converted early-stops into silent tails. No peer handles this
well — it's a differentiator.

Design as ONE coherent interruption model:
- **Split tap-disable reasons** in `HotkeyMonitor.swift:250-256`:
  `tapDisabledByTimeout` (our run-loop stalled — correlates with the steal) vs
  `tapDisabledByUserInput` (benign). On a mid-hold **timeout**, emit an
  interruption event → orchestrator **finalizes the utterance at the disruption
  boundary** instead of appending silence.
- **Config-change observer:** in `AudioCaptureService`, observe
  `AVAudioEngineConfigurationChange` scoped to the engine (Hex's
  `restartPreservingRecording()` pattern) — often the earliest steal signal; set
  an `interrupted` flag / restart-preserving-recording.
- **Dead-tail detector:** RMS is *already computed per callback*
  (`AudioCaptureService.swift:256-262`); in `finishRecording`
  (`DictationOrchestrator.swift` ~562-567, beside the `SilenceDetector` branch),
  detect "energy early, long sub-floor tail" → trim before STT + surface a note
  ("Mic interrupted — text may be incomplete"). Apply to BOTH push-to-talk and
  hands-free.
- **Duration integrity:** expose wall-clock (already measured but only logged,
  `AudioCaptureService.swift:140-144`) vs sample-count divergence on `AudioClip`
  — catches the *stalled-tap* variant the zeros-tail check misses.
- *(Optional)* device-alive / default-input listeners during a live session
  (VoiceInk pattern) — lower priority; partly covered by the config-change observer.

**Delegate:** opus → engine lifecycle + orchestrator finalize path; sonnet → the
pure `TrailingSilenceAnalyzer` + tests.
**Accept:** speech-then-silence and stalled-tap clips are detected → trimmed/
finalized + a visible note; analyzer + finalize-decision unit-tested; zero added
latency on the clean path.
**Peer refs:** Hex `SuperFastCaptureController.swift` (config-change restart);
VoiceInk `ShortcutMonitor` `onShortcutInterrupted`; Handy #840 / Ghostty #11883
(cautionary — tap died with no recovery).

## WS2 — VAD-based trimming  *(MEDIUM — latency + hallucination)*
Reuse the **already-loaded** Silero VAD (`SpeechEndpointer.swift`) to *trim*
non-speech from the finalized clip (both modes), not just to end hands-free. Handy
ref: onset gating + ~450 ms prefill/hangover (`vad/smoothed.rs`). Parakeet is
silence-robust (win is latency/interruption); Whisper benefits from hallucination
reduction. Respect `WhisperModeTuning.vadSpeechPadding`. **Must be provably off
the fn-up→paste path, or gated.** Delegate: opus. Folds into WS1 (both trim silence).

## WS3 — Injection / clipboard correctness  *(MEDIUM)*
- **Read-signaled clipboard restore:** replace the blind 500 ms timer
  (`TextInjector.swift:593,608`) with a lazy `NSPasteboardItem` data-provider so
  restore fires *after* the target reads (Handy PR #1770). The timer both races
  slow apps (stale-clipboard paste) and inflates latency.
- **Captured-target focus guard:** capture the target app at record-start; before
  paste, if frontmost ≠ captured, re-activate or abort-with-note (OpenWhispr
  pattern); leave an already-frontmost Electron app alone. Skylark already computes
  `frontmostBundleID()` for setup.
**Delegate:** opus (AX/pasteboard). *(The quick fixes — replace-failure, restore-
detach, modifier-flush, concealed-markers — are already done; do NOT repeat them.)*

## WS4 — Local cleanup via llama.cpp + Qwen  *(HIGHEST leverage, BIG)*
**Validated this session:** llama.cpp builds AND runs on the CLT-only box via a
SwiftPM `binaryTarget` on the official `llama.xcframework` — its Metal shaders are
embedded and compiled at RUNTIME (`GGML_METAL_EMBED_LIBRARY`), so no `metal`
compiler is needed. Thinned arm64 framework ~5.7 MB, MIT. Spike ran real Qwen
inference: ~0.5–0.7 s warm, ~1–2 GB RAM. **Consumption approach approved: prebuilt
xcframework `binaryTarget`** (LLM.swift precedent — `eastriverlee/LLM.swift`
`Package.swift`).

Reuse `CleanupPrompt.compactInstructions` (per-model-prompt research: ONE shared
prompt across local models; per-model work lives in the ADAPTER). The Qwen adapter
must: ChatML messages, `enable_thinking:false`, and strip `<think>` (which
`CleanupHygiene.stripReasoningBlocks` already does). Wire behind the existing
`LocalCleanupBackend` protocol in `LocalCleaner.swift` (the Apple conformer is
`FoundationModelBackend`). **Apple Foundation Models stays the DEFAULT**; Qwen is
opt-in. The deterministic `SpokenNumbers` pass (v0.7.7) already yields "$1.99", so
the small model's number-format miss is moot.

**Decomposition:**
- **opus** → the `binaryTarget` integration + a thin **actor-wrapped** Swift
  binding over the llama.cpp C API (`llama_backend_init` → `llama_model_load_from_file`
  → `llama_init_from_model` → tokenize → greedy sampler chain → `llama_decode`
  loop) + ChatML / thinking / `<think>`-strip handling. Isolate all llama calls
  behind one actor (single-threaded engine).
- **sonnet** → GGUF download manager (Qwen3-1.7B + Qwen3-4B-Instruct →
  `~/Library/Application Support/Skylark/…` with progress, like the STT models),
  the model-picker Settings UI (Apple default + Qwen 1.7B/4B), unload-when-idle
  for the 16 GB budget, and a gated corpus eval harness over `CleanupCorpus`
  (mirror the `SKYLARK_LIVE_CLEANUP_EVAL` pattern).
**Accept:** Apple FM default; Qwen 1.7B + 4B selectable; runtime download; unloads
when idle; fully offline; **validated on the M3 Air** against `CleanupCorpus`
(report match rate + per-cleanup latency); never blocks paste; MIT-clean.
**Refs:** spike code at `scratchpad/llamaspike/`; `eastriverlee/LLM.swift`
(binaryTarget precedent); `OpenWhispr` (bundling a llama binary); the failed MLX
attempt is at `scratchpad/mlx-work/` (do NOT revive — needs the Xcode metal compiler).

---

## Suggested order
**WS4 and WS1 in parallel** (highest leverage + worst active pain). **WS2** folds
into WS1. **WS3** last. Each workstream ships as its own release (version bump +
CHANGELOG + `make test` green + push).

## Key files
- Audio: `Sources/SkylarkCore/Audio/{AudioCaptureService,SpeechEndpointer,VadChunker,WhisperModeTuning,SilenceDetector}.swift`
- Hotkey: `Sources/SkylarkCore/Hotkey/{HotkeyMonitor,HotkeyProcessor,HotkeyBinding}.swift`
- Injection: `Sources/SkylarkCore/Injection/{TextInjector,PasteboardSnapshot}.swift`
- Cleanup: `Sources/SkylarkCore/Cleanup/{LocalCleaner,CleanupPrompt,CleanupHygiene,SpokenNumbers,CleanerRegistry}.swift`
- Pipeline: `Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift`
- Tests + corpus: `Tests/SkylarkTestKit/` (`CleanupCorpus`, `CleanupCorpusTests`, `DictationOrchestratorTests`)
