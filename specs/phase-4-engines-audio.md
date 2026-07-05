# Phase 4 spec — WhisperKit fallback engine, model manager, input device picker + BT warning, Whisper Mode

Read `ARCHITECTURE.md` (§6 WhisperKit facts), `CLAUDE.md`, and the code you'll
extend: `Transcription/` (Transcriber, FluidAudioParakeet, FallbackTranscriber),
`Models/{ModelPaths,ModelSelection}.swift`, `Audio/AudioCaptureService.swift`,
`Pipeline/DictationOrchestrator.swift`, `AppController`, Settings views.
`make test` runs the suite (not `swift test`).

## Ground truth (verified from source 2026-07)
- WhisperKit's repo/package renamed: `.package(url:
  "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")`,
  product `WhisperKit`. MIT.
- Init: `try await WhisperKit(model: <variant>, downloadBase: <URL>, prewarm:,
  load:, download:)`; `transcribe(audioArray: [Float]) async throws ->
  [TranscriptionResult]` (16 kHz Float, `WhisperKit.sampleRate == 16000`);
  `prewarmModels()`, `unloadModels()`; static
  `download(variant:downloadBase:...progressCallback:)`.
- large-v3-turbo checkpoint = `openai_whisper-large-v3-v20240930`; use the
  compressed `openai_whisper-large-v3-v20240930_626MB` variant (their default
  for capable Macs; ~626 MB). **Must pass `downloadBase`** (default is
  `Documents/huggingface` — wrong for us): use a `whisperkit/` subdir under
  the existing `ModelPaths.models`.
- Its `Package@swift-6.2.swift` builds on this toolchain (verified). If the
  dependency's test-target resources upset `swift build`, they won't — only
  library targets matter — but report anything weird.

## Work items

### 1. `WhisperKitWhisper: Transcriber` (Transcription/WhisperKitWhisper.swift)
- `id: .whisperKit`. Same shape as FluidAudioParakeet: `warmUp()` idempotent
  (download with progress mapped onto the existing `ModelPreparationState`
  callback, then load + prewarm), clip guard reuse (`shouldSkip`), transcribe
  joins segment texts, trims. `shutdown()` unloads.
- English hint: DecodingOptions language "en" if the API takes it (check
  source; `DecodingOptions(language: "en")` exists).

### 2. Engine lifecycle + selection
- `STTChoice` gains `.localWhisper`. Menu "Speech Engine" gains
  "Local (Whisper large-v3-turbo)".
- Memory policy (16 GB target machines): only the ACTIVE local engine stays
  warm. Switching local engines warms the new one, then `shutdown()`s the
  old after the switch completes. Cloud STT's fallback engine is whichever
  local engine is selected (default Parakeet); it stays warm per PRD §6.2.
- Engine identity strings recorded to history must distinguish parakeet /
  whisperkit / cloud slugs (check what Phase 3 wired; extend if needed).

### 3. Model manager (Settings window, "Models" section)
- Rows for Parakeet (~483 MB), Whisper large-v3-turbo (~626 MB), Silero VAD
  (few MB): state = Not downloaded / Downloading N% / Ready (+ size on disk),
  actions = Download / Delete (delete disabled for the engine currently in
  use; confirm dialog). Engines already expose progress via
  `ModelPreparationState`; add small `installedSize()`/`removeFromDisk()`
  helpers next to each engine's ModelPaths dir. Keep the UI plain (Form/List);
  the Phase 5 pass polishes.

### 4. Input device picker + Bluetooth warning (Audio/ + Settings "Audio" section)
- `AudioDeviceManager` (CoreAudio): enumerate input-capable devices
  (`kAudioHardwarePropertyDevices` → devices with input streams), expose
  `{uid, name, transportType}`, watch device-list changes
  (`AudioObjectAddPropertyListenerBlock` on the system object).
- Selection: persist device UID in UserDefaults; `AudioCaptureService` sets
  the engine's input device via `kAudioOutputUnitProperty_CurrentDevice` on
  `inputNode`'s audio unit before start; missing/unplugged UID → system
  default + one status note. Device switch must be safe across sessions (no
  crash if it changes between dictations; re-apply at each `start()`).
- Bluetooth warning: `transportType == kAudioDeviceTransportTypeBluetooth`
  (also check `...TypeBluetoothLE`) → inline warning in the picker row and a
  one-time status note when selected: "Bluetooth mics reduce recognition
  quality (HFP). Consider the built-in mic." Do not block selection.
- Built-in default stays default.

### 5. Whisper Mode (quiet-speech)
- Global toggle: menu-bar item "Whisper Mode" + persisted bool + optional
  per-mode override later (leave a `whisperMode: Bool?` on DictationMode
  defaulting nil = inherit global; migration v2 adds the column — coordinate
  with `ModeRecord`/`ModeStore` and the adapter).
- Effects while ON, all in one tunables struct (`WhisperModeTuning`):
  capture gain ×4.0 applied post-conversion in the tap (vDSP multiply, clamp
  to [-1, 1]); VAD `minSilenceDuration` unchanged but threshold config moved
  toward sensitive (whatever `VadSegmentationConfig` exposes — check source;
  if only durations are exposed, lengthen `speechPadding` and lower
  `minSpeechDuration`); silence-floor guard in `shouldSkip` drops to 1e-5.
- HUD: listening dot gets a subtle hollow style in whisper mode (tiny visual
  cue; keep it minimal).
- Unit tests: gain clamp math, tuning selection plumbing (whisper on/off
  changes the config handed to capture/VAD/guard).

### 6. Bench extension
- `SkylarkBench` gains `--engine parakeet|whisper` (default parakeet).
  `Scripts/bench.sh` runs both engines over the same synthesized clips and
  prints a comparison table. First whisper run downloads ~626 MB — expected.

## Acceptance
1. `swift build` clean; `make test` green (existing 121 + new).
2. `Scripts/bench.sh` produces the two-engine table — include it in your report.
3. `make app` bundles.
4. Report deviations + MacBook-validation additions (device switching with
   real hardware, AirPods HFP warning, whisper-volume accuracy).

Git: single commit on main (no push). Stage only your files.
