# Phase 1 spec — local Parakeet MVP (FluidAudio, instant raw paste, waveform, latency benchmark)

Read `ARCHITECTURE.md`, `CLAUDE.md`, and skim the Phase 0 sources before
starting (`Sources/SkylarkCore/**`, `Sources/Skylark/**`) — extend them, don't
restructure. Acceptance = `swift build` clean, `make test` green (note:
`swift test` does not execute tests on this CLT-only box; use `make test`),
`make app` works, plus the bench harness below runs headless.

## API ground truth (verified from FluidAudio source at v0.15.4 — trust this over its README)

- Dependency: `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4")`, product `FluidAudio`. Apache-2.0. macOS 14+.
- Load: `let models = try await AsrModels.downloadAndLoad(to: dir, version: .v3, encoderPrecision: .int8, progressHandler: ...)` — downloads ~483 MB from HuggingFace on first run into `dir` (pass OUR directory: `~/Library/Application Support/Skylark/Models/`). `AsrModels.modelsExist(at:)` to detect first-run.
- Transcribe: `let manager = AsrManager(config: .default); try await manager.loadModels(models)`. **Every transcribe takes `inout TdtDecoderState`** (README's stateless example is stale): `var state = try TdtDecoderState(); let result = try await manager.transcribe(samples, decoderState: &state)` → `ASRResult { text, confidence, duration, processingTime, tokenTimings }`. `AsrManager` is an actor.
- Residency: models stay loaded in the actor until `cleanup()`; call `reset()` (clears decoder state only) between utterances — never `cleanup()` during a session. Default compute `.cpuAndNeuralEngine` — keep it.
- Input: 16 kHz mono `[Float]` (exactly what `AudioCaptureService` produces).
- VAD: `let vad = try await VadManager(config: .default)` (downloads a small Silero CoreML model — same custom directory mechanism via its config/progress init if available; check `VadManager` init signatures in the package source under `Sources/FluidAudio/VAD/`). Streaming: `var s = vad.makeStreamState()` then `vad.processStreamingChunk(_:state:config:...)` → result with `.speechStart`/`.speechEnd` events; `VadSegmentationConfig` has `minSilenceDuration` etc. Chunk size 4096 samples (256 ms).

## Work items

### 1. `FluidAudioParakeet: Transcriber` (SkylarkCore/Transcription/)
- Conforms to the existing `Transcriber` protocol. Holds `AsrModels` +
  `AsrManager` + a `TdtDecoderState`; `warmUp()` = ensure downloaded + loaded
  (idempotent, safe to call at launch); `transcribe(_:hint:)` = guard clip
  (skip when duration < 0.2 s or samples all near-zero → return empty string,
  never throw for that), call manager, `reset()` after each utterance, return
  trimmed text.
- Download progress: `warmUp` reports via an injected
  `@Sendable (ModelPreparationState) -> Void` callback
  (`.checking`, `.downloading(progress: Double)`, `.loading`, `.ready`,
  `.failed(Error)`).
- Errors surface as thrown errors; the orchestrator (below) decides fallback.

### 2. Orchestrator + app wiring
- Replace `StubTranscriber` with `FluidAudioParakeet` in the app composition
  root (keep the stub for tests). The orchestrator must handle: transcriber
  not ready (HUD shows preparing state; a dictation attempted before ready
  gets discarded with a menu-bar status note — never a crash or hang);
  transcribe throwing (log category-level error, drop to idle, no paste of
  garbage); empty transcript (no injection at all).
- Model preparation state shown in: menu bar status line ("Downloading speech
  model… 42%") and HUD processing dot pulsing while preparing. Start `warmUp()`
  at launch right after permissions are granted (or immediately if already
  granted).
- Fix the Phase 0 edge: in `HotkeyMonitor.handle` for
  `.tapDisabledByTimeout/.tapDisabledByUserInput`, after reconciling
  `isFnPressed` from `CGEventSource.flagsState`, if the reconcile flips
  fn from pressed→released, feed the processor a synthetic `.fnUp` so a
  recording can't get stuck.

### 3. Hands-free VAD endpointing (SkylarkCore/Audio/ + Pipeline)
- Only in hands-free (double-tap-lock) sessions: feed captured 16 kHz frames
  in 4096-sample chunks to `VadManager` streaming; on `.speechEnd` (with
  `minSilenceDuration` ≈ 1.0 s, tune constant in one place), synthesize the
  stop event (same path as Fn-up). Push-to-talk sessions do NOT run VAD.
- VAD model prepares alongside Parakeet in `warmUp`; if VAD is unavailable,
  hands-free still works via double-tap stop (graceful degradation, log once).

### 4. Waveform (Skylark/HUD/)
- Wire `AudioCaptureService.levels` into the listening pill: ~24 vertical
  bars, newest level pushes in from the trailing edge, 60 fps NOT required —
  drive from the levels stream cadence (~15–20 Hz) with `.animation` easing.
  Idle/ready state keeps the stable placeholder bars (no layout pop —
  Phase 0's fixed heights stay).

### 5. Latency instrumentation + bench harness
- Signpost intervals already exist; add a per-dictation summary log (Logger,
  info level, no transcript content): capture-close ms, transcribe ms, inject
  ms, total fn-up→inserted ms. Keep a rolling in-memory list of the last 20
  summaries; menu bar gets a "Last: 214 ms" line under status.
- New executable target `SkylarkBench` (SkylarkCore dep): args = audio file
  paths (anything `AVAudioFile` reads; resample to 16 kHz mono internally),
  flags `--repeat N` (default 3) and `--models-dir` (default the app's dir).
  Output per file: duration, decode ms (median of repeats), RTFx; plus a
  total summary. Exit nonzero on any failure.
- `Scripts/bench.sh`: if no args, synthesize 3 clips with `say` (short ~2 s,
  medium ~6 s, long ~15 s; use `say -o` + `afconvert` to 16 kHz wav into
  `.build/bench/`), then run `swift run -c release SkylarkBench` on them.
  This must run fully headless (say(1) needs no mic/GUI).

### 6. Tests (extend SkylarkTestKit; runnable via `make test`)
- FluidAudioParakeet clip guards (short/silent clip → empty string, no model
  load attempted — inject a fake engine layer or gate before engine call).
- Orchestrator: not-ready discard path; transcriber-throws path drops to idle
  with no injection (spy injector asserts).
- VAD chunking math: frames → 4096-sample chunks with tail handling (pure
  function, test it as one).
- HotkeyMonitor reconcile fix: pure-logic test if feasible (the synthetic
  fnUp decision), else document why not.

## Acceptance (run yourself, headless)
1. `swift build` clean; `make test` green (all old + new tests).
2. `Scripts/bench.sh` end-to-end: downloads Parakeet on first run (~483 MB —
   fine, machine has bandwidth; put it in the app's real models dir), decodes
   3 synthesized clips, prints timing table. Include the table in your report.
3. `make app` still produces a signed bundle.
4. Report: files touched, deviations, the bench numbers, and updated list of
   what needs the MacBook (waveform feel, real-mic accuracy, true fn-up→paste
   latency).

Git: single commit on main when done (no push).
