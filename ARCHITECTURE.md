# Skylark Architecture

Companion to `Skylark_Dictation_PRD.md`. This is the orchestrator's design of
record; implementation specs derive from it. Sections marked **[pending
research]** get finalized once dependency research lands and are updated in
place.

## 0. Platform decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language/UI | Swift 6.2, SwiftUI + AppKit where needed | PRD §11; low-latency audio, AX APIs |
| Build system | **Pure SwiftPM — no Xcode project** | Build box has CLT only; reproducible for non-technical users; FluidAudio/WhisperKit are SPM packages |
| App packaging | `swift build -c release` → `Scripts/bundle.sh` assembles `Skylark.app` (Info.plist, icon, resources) → `codesign` with a **self-signed "Skylark Dev" certificate** | Stable signing identity so TCC grants (Mic, Accessibility, Input Monitoring) survive rebuilds |
| Min deployment | macOS 15; Tier‑1 local cleanup gated `#available(macOS 26)` for FoundationModels **[pending research — may raise floor to FluidAudio's min]** | Both current machines run macOS 26 |
| Bundle ID | `com.jjromano.skylark` | Stable TCC identity |
| Persistence | SQLite via **GRDB** (MIT, SPM) | Code-first, testable, no Core Data model files (which want Xcode tooling) |
| App style | `LSUIElement` menu-bar app + floating `NSPanel` HUD | PRD §9, §11 |

## 1. Package layout

```
Package.swift
Sources/
  SkylarkCore/          # library target — all logic, fully testable
    Audio/              # AVAudioEngine capture, ring buffer, level meter, VAD
    Transcription/      # Transcriber protocol + FluidAudioParakeet, WhisperKitWhisper, OpenRouterCloud, StubTranscriber
    Cleanup/            # Cleaner protocol + RawPassthrough, LocalCleaner (FoundationModels), OpenRouterCleaner
    Injection/          # TextInjector: AX insertion + clipboard-preserving paste fallback
    Hotkey/             # Fn event tap, push-to-talk vs double-tap toggle detection
    Pipeline/           # DictationOrchestrator actor — the state machine
    Models/             # ModelRegistry, ModeStore (app-aware modes), Dictionary (bias + correction map)
    Persistence/        # GRDB database, history, settings
    Credentials/        # Keychain wrapper for OpenRouter key
    Permissions/        # TCC status checks + deep links to System Settings panes
  Skylark/              # executable target — thin AppKit/SwiftUI shell
    App.swift           # @main, menu-bar item, lifecycle
    HUD/                # NSPanel + SwiftUI pill (state machine per PRD §9)
    Settings/           # settings window views
    Onboarding/         # permissions walkthrough + API key entry
Tests/SkylarkCoreTests/
Scripts/bundle.sh       # .app assembly + codesign
Scripts/make-cert.sh    # one-time self-signed codesigning cert
Makefile                # make app / make run / make test
```

## 2. Core abstractions (API surface — orchestrator-owned)

```swift
// One recorded utterance, 16 kHz mono Float32 (engines' native rate — verify) [pending research]
struct AudioClip { let samples: [Float]; let sampleRate: Double; let duration: TimeInterval }

protocol Transcriber: Sendable {
    var id: TranscriberID { get }             // .parakeet, .whisperKit, .cloud(slug)
    func warmUp() async throws                // load + keep resident (PRD §6.1 model residency)
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String
    // Streaming interim results where supported (Parakeet transducer):
    func stream(_ frames: AsyncStream<[Float]>, hint: TranscriptionHint) -> AsyncThrowingStream<TranscriptUpdate, Error>
}

protocol Cleaner: Sendable {
    var tier: CleanupTier { get }             // .raw, .local, .cloud(ModelRegistryEntry)
    func clean(_ transcript: String, context: CleanupContext) async throws -> String
    // context: target-app register, custom-dictionary terms, mode prompt
}

protocol TextInjecting: Sendable {
    /// Inserts at cursor. Returns a token describing HOW it inserted (AX direct vs paste),
    /// which InsertionToken later enables in-place replacement by the cleaner stage.
    func insert(_ text: String) async throws -> InsertionToken
    func replace(_ token: InsertionToken, with text: String) async throws
}
```

The app targets protocols, never concrete engines (PRD §11). Every pipeline
stage is skippable; a failed optional stage never blocks the paste (PRD §12).

## 3. The pipeline (push-to-talk happy path)

```
Fn down ─→ AudioCapture.start (engine pre-warmed, tap → ring buffer)
        ─→ HUD → .listening (waveform driven by RMS AsyncStream)
        ─→ [streaming engines] Transcriber.stream feeds interim text to HUD
Fn up   ─→ clip finalized ─→ Transcriber finishes final text
        ─→ TextInjector.insert(raw)              ⟵ LATENCY BAR: <300 ms after Fn up
        ─→ HUD → .idle (does not wait for cleanup)
        ─→ Cleaner.clean(raw) async ─→ TextInjector.replace(token, cleaned)
```

Hands-free toggle: same, but VAD endpointing generates the "Fn up" event.

**In-place replacement strategy** (Tier 1/2 cleanup): when insertion went via
AX we can rewrite the inserted range precisely. When insertion used the paste
fallback, replacement uses select-back + repaste, which is riskier; per-mode
setting `replaceStrategy: .inPlace | .waitForClean | .rawOnly` with `.inPlace`
default, auto-degrading to `.waitForClean` in apps where select-back is known
unsafe. **[design to validate in Phase 2]**

## 4. Concurrency model

- `DictationOrchestrator` — actor; owns the session state machine
  (`idle → recording → transcribing → injecting → cleaning`), the only writer
  of pipeline state.
- `AudioCaptureService` — wraps AVAudioEngine; render-thread tap writes into a
  preallocated ring buffer, publishes frames/levels via `AsyncStream`
  (no allocation, no locks on the audio thread).
- `HotkeyMonitor` — CGEventTap on its own thread; posts key events into the
  orchestrator. **[pending research: exact Fn capture mechanism]**
- UI — `@MainActor`, observes an `@Observable HUDModel` snapshot the
  orchestrator updates.
- Engines — each `Transcriber` manages its own executor; `warmUp()` at app
  launch and on engine switch keeps the active model resident.

## 5. Data model (GRDB)

- `history(id, timestamp, raw_text, clean_text, mode_id, engine, duration_ms, latency_ms, audio_path NULLABLE)` — audio path only when opt-in.
- `dictionary(id, phrase, replacement NULLABLE, source ENUM(manual, auto_correction), created_at)`
- `modes(id, name, bundle_id_pattern, engine, cleanup_tier, cleanup_model_slug, register_hint, is_default)`
- `model_registry(slug, label, provider_pin, kind ENUM(stt, cleanup), sort)`
- Settings in `UserDefaults` (non-secret); OpenRouter key in Keychain only.

## 6. External services

- **OpenRouter STT**: `POST /api/v1/audio/transcriptions`, per-clip; slugs +
  request shape **[pending research]**. 60 s timeout budget, transparent local
  fallback with non-blocking notice (PRD §6.2).
- **OpenRouter cleanup**: chat completions, provider pinned to Groq, streaming
  SSE. Pinning syntax **[pending research]**.
- **Model downloads**: FluidAudio/WhisperKit fetch their CoreML models on
  first use; download manager UI wraps their APIs. Locations/sizes
  **[pending research]**.

## 7. Privacy invariants (enforced in review, every phase)

1. Local mode: zero network. Cloud calls only from `OpenRouterCloud` /
   `OpenRouterCleaner`, only when selected.
2. No audio persisted unless history-audio opt-in; never leaves machine except
   explicit cloud STT.
3. Clipboard byte-for-byte preserved across paste fallback (tested, PRD §10).
4. No telemetry. No transcript content in logs.
5. Secrets only in Keychain.

## 8. Latency budget (local short utterance, PRD §12)

| Stage | Budget |
|---|---|
| Fn-up debounce + capture close | ≤ 20 ms |
| Parakeet final decode (warm, ANE) | ≤ 150 ms |
| Dictionary correction map | ≤ 5 ms |
| AX insertion | ≤ 50 ms |
| **Total end-of-speech → raw text visible** | **≤ 300 ms** |
| Streaming interim token (where implemented) | ≤ 150 ms |

Benchmark harness in Phase 1 measures each stage with signposts; regressions
block merge.
