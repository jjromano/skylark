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
| Min deployment | **macOS 26** | All target machines run 26; FoundationModels needs 26; kills `#available` gating. (Deps allow lower: FluidAudio ≥14, WhisperKit ≥13) |
| Bundle ID | `com.jjromano.skylark` | Stable TCC identity |
| Persistence | SQLite via **GRDB** (MIT, SPM) | Code-first, testable, no Core Data model files (which want Xcode tooling) |
| App style | `LSUIElement` menu-bar app + floating `NSPanel` HUD | PRD §9, §11 |
| Resources | Never `Bundle.module` in app code — SPM's generated accessor breaks inside a signed .app (looks at bundle root; codesign rejects root files). Bundler puts `<Pkg>_<Target>.bundle` in `Contents/Resources`; load via `Bundle.main.resourceURL` helper. FluidAudio/WhisperKit library targets ship no resource bundles. GRDB ships `GRDB_GRDB.bundle` (privacy manifest); `bundle.sh` copies it into `Contents/Resources`. If GRDB ever loads it via the generated accessor at runtime it would look at the bundle root instead — no such failure observed, but if a `could not load resource bundle` crash ever appears, this is why | Empirically verified on this machine (build-time; runtime lookup unexercised) |
| FoundationModels macros | `@Generable`/`@Guide` don't compile with CLT-only (macro plugin ships in Xcode). Tier‑1 cleanup uses plain `String` responses | Verified locally |

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
// One recorded utterance, 16 kHz mono Float32 (confirmed native rate for
// FluidAudio ASR + VAD and WhisperKit; capture converts once at the tap)
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

Hands-free toggle: same, but VAD endpointing generates the "Fn up" event
(FluidAudio `VadManager` streaming `.speechEnd` events).

**Transcription strategy for push-to-talk (Phase 1 MVP):** batch — feed the
whole clip to `AsrManager.transcribe` on release. At Parakeet's ~140× real-time
on ANE, a 10 s utterance decodes in well under 100 ms, comfortably inside the
300 ms bar, with none of the sliding-window complexity. Live interim text in
the HUD via `SlidingWindowAsrManager` is an additive enhancement after the
latency bar is proven.

**Injection strategy (AX-first — deliberate inversion of Hex's order):**
1. Probe `kAXFocusedUIElement`; if it answers `kAXValue`/`kAXSelectedText`
   reads, set `kAXSelectedTextAttribute` — clipboard untouched. The write is
   **verified by read-back**: Chrome/Electron/web fields return `.success` on
   the set yet silently drop it, so we read the inserted range back and only
   trust the AX path when the text matches (`axInsertLanded`). Unconfirmed
   inserts fall through to the paste path below.
2. On any AX failure **or unconfirmed insert**: full multi-item `NSPasteboard` snapshot (all types) →
   write text as a **lazy `NSPasteboardItem` promise** (transient marker written
   eagerly) → poll `changeCount` until committed (5 ms poll, 150 ms cap) →
   synthesized Cmd-V (explicit Cmd down, layout-resolved V, Cmd up, posted to
   `.cghidEventTap`) → **restore when the target actually READS** the promise,
   never earlier than a **120 ms floor** after arming (`PasteRestoreCoordinator
   .minimumRestoreDelay`) plus a 100 ms grace for apps that read twice, with the
   old 500 ms timer kept only as a ceiling for targets that never read
   (`PasteRestoreDecider`). Immediately before the restore write, a `changeCount`
   guard confirms the pasteboard still holds exactly what Skylark wrote; if
   another writer took it in the meantime (the confirmed live case: the user
   hits Cmd-C right after dictating), the restore stands down instead of
   clobbering their newer copy (P1-1). Posting Cmd-V proves nothing on its own
   (the events can land in the HID queue and be ignored) — `InsertionToken
   .landing` distinguishes `.posted` (keystroke sent, landing unconfirmed) from
   `.readConfirmed` (a pasteboard read was observed after arming) from
   `.notPosted` (synthesis itself failed); callers needing the truth (History,
   Command Mode's replace) await the async landing signal, callers on the
   latency path (press-Return) don't block on it (P1-9). If the paste itself
   fails, the text is written eagerly (no dangling promise) and left on the
   clipboard as the user's fallback.
3. Before **every** write — each insert/paste and again before a synthesized
   Return — the **captured-target focus guard** compares the live focus against
   the target captured at record start: the frontmost app (one `NSWorkspace`
   read) *and*, when the app exposed one, the focused **window**
   (`kAXFocusedWindowAttribute`, compared by window-server id with `CFEqual`
   element identity as the fallback; a 200 ms AX messaging timeout keeps a
   wedged app off the paste path). Same app+window → inject; different app →
   re-activate and verify (bounded ~300 ms) → inject; different window of the
   same app → abort (raising a window under the user is worse than not
   pasting); unrecoverable → abort with a note, transcript still recorded to
   History (`CapturedTargetGuard`). Re-validating per write is what stops a
   verdict taken before a multi-second cleanup from gating a keystroke; a
   missing window identity degrades to the bundle-only verdict, never to a
   false abort.

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
  (no allocation, no locks on the audio thread). `frames`/`previewFrames` are
  **per-access streams**: every read of the property mints a fresh
  `AsyncStream` and retires whatever continuation was live before it, rather
  than handing out one stored stream. A cancelled consumer permanently
  finishes an `AsyncStream` (verified), and hands-free tears its VAD task down
  on every stop that isn't the VAD's own — a stored stream therefore
  endpointed once per launch and silently never again (P1-2a, "hands-free
  never stops"). Per-access streams contain that damage to the one consumer
  that got cancelled.
- Capture disruptions surface as `CaptureInterruption.Reason`
  (`configurationChange`, `restartFailed`, `triggerTapStalled`,
  `permissionLost`, `capReached`) reported on `AudioCaptureService
  .interruptions` and converged on the orchestrator's single finalize
  decision via `finalizesUtterance`. `permissionLost` (Accessibility revoked
  or the event tap died unrecoverably mid-session) and `capReached` (the
  120 s hard buffer cap) both finalize immediately — the former because the
  key-up that would normally end the session can never arrive, the latter
  because nothing more can be stored past the cap. `triggerTapStalled` is
  recorded as a marker only and does NOT finalize (it also fires on a benign
  main-loop stall while the user is still holding the key).
- `HotkeyMonitor` — active CGEventTap (`.cghidEventTap`, head-insert,
  `.defaultTap`) on its own run loop. Bare Fn = `.flagsChanged` + keycode
  `kVK_Function` (0x3F) + `.maskSecondaryFn`, with the three known traps
  handled (per Hex/Handy, both MIT): sticky fn-pressed bool because arrow/F-keys
  spuriously carry the fn mask; skip unknown-keycode keyDowns carrying the fn
  flag (Fn+media keys); reconcile modifier state from
  `CGEventSource.flagsState` after `.tapDisabledByTimeout` and re-enable the
  tap. Swallow the bare-Fn event (return nil) to suppress the system Globe
  action; also detect `AppleFnUsageType` (com.apple.HIToolbox) and surface a
  hint in onboarding. Push-to-talk/double-tap-lock is a pure, unit-testable
  state machine adapted from Hex's `HotKeyProcessor` (idle / pressAndHold /
  doubleTapLock; 0.3 s double-tap window; ≥0.3 s minimum hold for
  modifier-only chords; ESC cancels).
- UI — `@MainActor`, observes an `@Observable HUDModel` snapshot the
  orchestrator updates.
- Engines — each `Transcriber` manages its own executor; `warmUp()` at app
  launch and on engine switch keeps the active model resident.

## 5. Data model (GRDB)

- `history(id, timestamp, raw_text, clean_text, mode_id, engine, duration_ms, latency_ms, audio_path NULLABLE, word_count, app_bundle_id NULLABLE, app_name NULLABLE)`
  — audio path only when opt-in; word_count/app_* (v3) feed `StatsStore`
  aggregates (Insights pane). Time-based retention pruning
  (`HistoryStore.prune`) runs at launch and on setting change.
- `snippets(id, trigger UNIQUE NOCASE, replacement, created_at)` — spoken
  whole-utterance triggers; matched by `SnippetMatcher` in the orchestrator
  before cleanup.
- `dictionary(id, phrase, replacement NULLABLE, source ENUM(manual, auto_correction), created_at)`
- `modes(id, name, bundle_id_pattern, engine, cleanup_tier, cleanup_model_slug, register_hint, is_default)`
- `model_registry(slug, label, provider_pin, kind ENUM(stt, cleanup), sort, seeded)`
  — `seeded` (added ad hoc by `RegistryStore`, not the shared migrator; see §6)
  distinguishes rows `syncSeed()` owns from user/ad-hoc entries.
- Settings in `UserDefaults` (non-secret); OpenRouter key in Keychain only.

### Hotkey bindings

The dictation trigger is a `HotkeyBinding` (keyboard: Fn default, right
⌘/⌥/⌃, F13–F19; mouse: buttons 2–4 as an optional second trigger). Both
feed the same `HotkeyProcessor` state machine (`triggerDown`/`triggerUp`);
`HotkeyMonitor` swallows only the bound keys/buttons. Persisted under
`hotkey.keyboard` / `hotkey.mouse`; applied live via `setBindings`.

### Voice commands & media

- "press enter"/"press return" spoken terminally (opt-in) is stripped by
  `PressEnterCommand.strip` pre-injection; the orchestrator then synthesizes
  Return via `TextInjecting.pressReturn()` — on this path cleanup is awaited
  (never the detached replace) so Return always lands after final text.
- `MediaPauseController` (opt-in) pauses running Music/Spotify at listening
  start and resumes exactly what it paused; AppleScript on the main actor,
  fire-and-forget, never on the audio/paste path.

### Updates

`bundle.sh` stamps the bundle with commit/date/repo path/remote;
`UpdateChecker` compares the commit against GitHub `main` (unauthenticated)
and `UpdateCommandWriter` emits a Terminal `.command` running
`git pull --ff-only && Scripts/install.sh` (Settings → Account).

## 6. Engine integration facts (verified from source, 2026-07)

### FluidAudio (Apache-2.0, SPM `from: "0.15.5"`, zero transitive deps)
- Batch path (our primary): `AsrModels.downloadAndLoad(to:)` once →
  `AsrManager` (actor) `.transcribe(_ samples: [Float], decoderState: inout
  TdtDecoderState)`. **Every transcribe takes `inout TdtDecoderState`** — the
  README's stateless example is stale. `reset()` clears decoder state but
  keeps models warm; `cleanup()` releases them (only on quit/engine switch).
  These signatures are unchanged 0.15.4→0.15.5.
- 0.15.x introduced an internal `ModelHub` download layer, but the public
  `AsrModels.downloadAndLoad`/`.download`/`.modelsExist` wrappers are stable
  and `DownloadUtils` still exists — **no adaptation needed** in our code.
  `encoderPrecision` is typed `ParakeetEncoderPrecision` (`.int8`/`.int4`); we
  pass `.int8`.
- Parakeet TDT v3 int8 ≈ **483 MB** on disk, auto-downloaded from HuggingFace.
  We pass `~/Library/Application Support/Skylark/Models/` as the models dir,
  but FluidAudio actually lays the repo down at the **parent** of that dir under
  the version's folder name (`-coreml` stripped): the real on-disk location is
  `~/Library/Application Support/Skylark/parakeet-tdt-0.6b-v3/` (NOT under
  `Models/`, NOT `…-coreml`). Verified: an install downloaded on 0.15.4 loads
  under 0.15.5 with "no download needed" — the layout is stable, no forced
  redownload. **Fixed:** `ModelPaths.parakeetModelDir`
  (`Sources/SkylarkCore/Models/ModelPaths.swift:45-47`) now reads
  `appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3")` — i.e. exactly
  this real on-disk path, no `Models/` prefix, no `-coreml` suffix. The
  Settings model-manager (`AppController.ManagedModel.parakeet.directory`,
  `Sources/Skylark/AppController.swift:332`) and its size/presence/delete
  logic (`ModelPaths.installedSize`/`.isPresent`/`.removeFromDisk`, all
  operating on that same `.directory`) derive from this one constant, so the
  earlier "Settings mis-reports Parakeet" caveat no longer applies.
- Compute: default `.cpuAndNeuralEngine` — keep it (low memory, ANE). Encoder
  can opt into `.cpuAndGPU` (~+8% RTFx, WER-neutral) via `encoderComputeUnits:`
  — not worth the power cost for us. Word-level timestamps are available on
  `ASRResult.tokenTimings` (+ `WordTimingMerger`) if ever needed; we currently
  use only `.text`.
- **Custom vocabulary (0.15.x) is NOT a warm-up decoder bias.** For Parakeet
  0.6B v3 (no built-in CTC head) it is a *post-decode* NeMo CTC word-spotter
  rescorer ("Approach 2"): it needs a **separate ~97.5 MB Parakeet CTC-110M
  model** and runs a **second full acoustic pass over the audio per utterance**
  (~26x RTFx) plus a `VocabularyRescorer` over the TDT `tokenTimings`. The docs'
  `asrManager.transcribe(_:customVocabulary:)` convenience does **not** exist in
  the shipped 0.15.5 code — the real entry points are `CtcModels.downloadAndLoad`
  → `CtcKeywordSpotter.spotKeywordsWithLogProbs` → `VocabularyRescorer.create` /
  `.ctcTokenRescore`. Because the pass is per-utterance and heavyweight, it
  **cannot** go on the Fn-up→paste path; any integration must run off-path
  (insert raw, then rescore→replace via the existing detached cleanup path) and
  is gated on the orchestrator accepting the +model download and +~64–130 MB
  resident memory. **Not wired in the MVP** — our dictionary bias remains the
  post-transcription `DictionaryCorrector` text rewrite.
- Interim results for TDT v3 = `SlidingWindowAsrManager`
  (volatile/confirmed updates via `AsyncStream`), NOT transducer cache
  streaming. True low-latency streaming needs different model variants
  (Parakeet EOU 120M with end-of-utterance callbacks, Unified 0.6B) — a
  Phase 1+ option, not the MVP path.
- **VAD included**: `VadManager` (Silero CoreML, 16 kHz, 256 ms chunks) with a
  streaming hysteresis state machine (`.speechStart`/`.speechEnd` events) and
  endpointing knobs (`minSilenceDuration` etc.). No extra dependency needed.
  `VadManager(config:modelDirectory:)`, `processStreamingChunk`,
  `VadSegmentationConfig` unchanged in 0.15.5.
- Builds clean on Swift 6.2.x / macOS 26 (re-verified at 0.15.5, zero warnings;
  real transcription on the M3 Air at ~67x RTFx). No open ASR issues on 26.

### WhisperKit (MIT) — Phase 4
- Repo renamed: package is now `argmax-oss-swift`, `from: "1.0.0"`, product
  `WhisperKit`. large-v3-turbo checkpoint = `openai_whisper-large-v3-v20240930`
  (1.62 GB full; `_626MB` compressed variant is their default for capable
  Macs). **Must override `downloadBase`** — default drops models into
  `Documents/huggingface`. `prewarmModels()` exists.

### OpenRouter (verified against live API + docs)
- STT: `POST /api/v1/audio/transcriptions`, JSON with base64
  `input_audio.data` + `format` (not multipart); optional `language: "en"`.
  Response: `{text, usage.cost}`. 60 s upstream timeout. Slugs: Groq fast
  Whisper = **`openai/whisper-large-v3-turbo`** (Groq is sole provider,
  $0.04/hr); accuracy = `openai/gpt-4o-transcribe` (token-priced; registry
  also seeds `openai/gpt-4o-mini-transcribe` — cheaper, steadier uptime).
- Cleanup: `POST /api/v1/chat/completions`, `"stream": true` (SSE, ignore
  `: OPENROUTER PROCESSING` keep-alives). Provider pinning:
  `"provider": {"order": ["groq"], "allow_fallbacks": true}` (soft pin —
  Groq 30-min uptime floats 95–99%, so hard `only` pin would hurt
  reliability). `:nitro` suffix ≡ `provider.sort:"throughput"`.
- Cleanup slugs (all live on Groq): `meta-llama/llama-3.1-8b-instruct`
  ($0.05/$0.08 per 1M), `openai/gpt-oss-20b`, `meta-llama/llama-3.3-70b-instruct`.
- Auth: `Authorization: Bearer <key>`; validate stored key via
  `GET /api/v1/key` at onboarding.

### Updating the model catalog

Skylark is distributed by building from source (`git clone` + `Scripts/install.sh`,
re-run after `git pull` = "the update"), so the cloud model catalog can't be
pushed to installed copies — it travels with the source and reaches existing
installs the same way any other code change does:

1. `ModelRegistryEntry.seed` (`Sources/SkylarkCore/Models/ModelRegistryEntry.swift`)
   is the source of truth — a hardcoded array of STT + cleanup OpenRouter
   entries, edited in a PR like any other code.
2. `RegistryStore.syncSeed()` (`Sources/SkylarkCore/Persistence/RegistryStore.swift`)
   reconciles the on-disk `model_registry` table against `.seed` every time
   it's called (app launch): it inserts any seed slug missing from the DB,
   and refreshes `label`/`providerPin`/`sort` for rows *it* previously
   seeded — never touching a row the user hand-added/edited, and never
   deleting anything. `seedIfEmpty()` still exists and just delegates to
   `syncSeed()`, so old call sites keep working.
3. Consequently: a maintainer edits `.seed`, commits, and every existing
   install picks up the change on its next launch after `git pull` +
   `Scripts/install.sh` — no server round trip, no versioned migration
   needed for catalog changes specifically.
4. Use `/update-models` (`.claude/commands/update-models.md`) to curate the
   seed: it fetches the live OpenRouter catalog, diffs it against `.seed`,
   web-researches promising new entrants, proposes edits, and reminds the
   maintainer that `Sources/Skylark/Settings/ModelInfo.swift` (blurbs/scores/
   cost estimates, not synced automatically) needs matching updates.

## 7. Privacy invariants (enforced in review, every phase)

1. Local mode: zero network. Cloud calls only when a cloud engine or cloud
   cleanup tier is explicitly selected. `OpenRouterCloud`/`OpenRouterCleaner`
   are no longer the only call sites (both grew alongside the feature set):
   `CommandRunner` also calls `OpenRouterClient.complete` when Command Mode's
   bound tier is cloud (uploads the highlighted selection, not just the
   transcript), and outbound model-download traffic now spans Parakeet,
   WhisperKit, the deep-vocabulary CTC helper, and Qwen cleanup GGUFs (the
   last pinned to an immutable revision and SHA-256-verified before install).
   Full current inventory: `docs/privacy-audit.md` §1. Switching the STT
   engine is itself race-guarded — `STTRebuildGate`
   (`Sources/SkylarkCore/Models/STTRebuildGate.swift`) stamps every rebuild
   with a generation and only installs a completion whose generation AND
   whose `choice` still match the live menu selection, so a slow cloud
   rebuild started before the user switched back to local can no longer land
   after the fact and upload audio the menu says is local (v0.13.0).
2. No audio persisted unless history-audio opt-in; never leaves machine except
   explicit cloud STT.
3. Clipboard byte-for-byte preserved across paste fallback, conditionally: the
   v0.13.0 `PasteRestoreCoordinator` rewrite (§3) also added a `changeCount`
   guard that stands down the restore (rather than clobbering it) if another
   writer took the pasteboard first — see `docs/privacy-audit.md` §4/§5 for
   the current precise semantics (tested, PRD §10).
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
