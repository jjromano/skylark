# Phase 3 integration spec — wire persistence + cloud into the pipeline; quick-switch; key onboarding; fallback

Read `ARCHITECTURE.md`, `CLAUDE.md`, then the Phase 2/3 code you're joining:
`Sources/SkylarkCore/{Persistence,Credentials,Network}/`, `Cleanup/` (CleanerRegistry,
OpenRouterCleaner, LocalCleaner), `Models/` (DictationMode, ModeProviding,
ModelRegistryEntry), `Pipeline/DictationOrchestrator.swift`,
`Sources/Skylark/AppController.swift`. Extend; don't restructure. `make test`
(not `swift test`) runs the suite.

## Work items

### 1. Composition root (Sources/Skylark/AppController.swift + App wiring)
- One `SkylarkDatabase.onDisk()` at launch; `seedIfEmpty()` on RegistryStore +
  ModeStore. DB/database failures must not kill the app: fall back to the
  in-memory providers with a menu-bar status note ("history disabled").
- Swap `InMemoryModeProvider`/`InMemoryDictionaryProvider` for GRDB-backed
  ones. Write a `ModeStore` → `ModeProviding` adapter mapping `ModeRecord` ↔
  `DictationMode` (tier TEXT "raw"/"local"/"cloud:<slug>"); put it in
  `Persistence/`. Round-trip unit test.
- Shared `OpenRouterClient(keyProvider: { KeychainStore().get() })`.

### 2. Model selection state (SkylarkCore/Models/ModelSelection.swift)
- `@MainActor @Observable final class ModelSelection`: `cleanupSlug: String`
  (default "meta-llama/llama-3.1-8b-instruct"), `sttChoice: STTChoice`
  (`.localParakeet` default | `.cloud(slug: String)`), UserDefaults-backed
  (plain keys; it's non-secret). Registry lookups resolve slug → entry
  (provider pin); a free-text slug not in the registry becomes an ad-hoc
  entry `{slug, label: slug, providerPin: "groq" for cleanup / nil for stt}`
  and is upserted via `RegistryStore` so it shows in menus thereafter.

### 3. Cloud cleanup wiring
- `CleanerRegistry` gets the cloud slot: `.cloud(slug)` → `OpenRouterCleaner`
  built per-dictation from the resolved slug (mode's `cloudCleanupSlug` wins
  over the global `ModelSelection.cleanupSlug`) + registry entry pin +
  shared client. Keep the existing degradation (no key/unavailable →
  local → raw) intact and silent.

### 4. Cloud STT + transparent fallback (SkylarkCore/Transcription/FallbackTranscriber.swift)
- `FallbackTranscriber: Transcriber` wrapping `primary` + `fallback`:
  try primary with a 10 s cap (race, not URLSession's 60 s); on throw/timeout
  run fallback and emit a non-blocking notice via an injected
  `@Sendable (String) -> Void` (menu-bar status line, auto-clearing after
  ~10 s — reuse the existing status-note mechanism from Phase 1). `warmUp()`
  warms BOTH (local stays resident even when cloud is selected — PRD §6.2).
- Composition: `sttChoice == .localParakeet` → plain Parakeet;
  `.cloud(slug)` → `FallbackTranscriber(primary: OpenRouterCloud(slug),
  fallback: parakeet)`. Orchestrator's transcriber becomes swappable at
  runtime (`setTranscriber` or an indirection box — your call; keep the
  ready-gate semantics working for both).
- No key + cloud selected → notice once ("No API key — using local engine"),
  use local directly.

### 5. Menu-bar quick-switch (AppController)
- "Cleanup Model" submenu: registry `.cleanup` entries (checkmark = active
  global slug) + "Custom Slug…" (opens a small window/alert with a text
  field; on submit set + upsert). Selecting takes effect next dictation.
- "Speech Engine" submenu: "Local (Parakeet)" + registry `.stt` entries.
- Keep the existing Cleanup tier submenu (Auto/Raw/Local) — add "Cloud" item
  now that it exists.
- (PRD's optional cycle-hotkey: skip; note as backlog.)

### 6. API key onboarding + settings
- Onboarding window: add an optional 4th step/card "OpenRouter API key
  (optional — enables cloud STT and cloud cleanup)": SecureField, Save →
  `KeychainStore.set` then `client.validateKey()`; show result inline
  ("Key OK — $X.XX remaining" from limit_remaining when present, or label) or
  the error. Skippable — local mode needs no key.
- Settings stub window: same component + "Remove key" button. (Full settings
  UI is a later pass; keep this minimal but real.)
- The key never appears in logs, UserDefaults, or error text.

### 7. History recording (orchestrator + HistoryStore)
- After each completed dictation, append a `HistoryRecord` (timestamp, raw
  text, clean text if a replace succeeded, mode id, engine id string,
  duration ms, fn-up→inserted latency ms, audio_path nil) via an injected
  `@Sendable (HistoryRecord) -> Void` sink — detached, off the paste path.
  When cleanup replaces later, update the record (`updateEditedText` or a
  dedicated `setCleanText` — add the small store method if cleaner).
  Failures silent. Spy-sink unit test.

## Acceptance
1. `swift build` clean; `make test` green (existing 106 + new: adapter
   round-trip, FallbackTranscriber primary-ok/throw/timeout paths + both-warm,
   ModelSelection persistence + ad-hoc slug upsert, history sink hook).
2. `make app` bundles.
3. Report deviations + what needs the MacBook / a real API key (I'll validate
   cloud calls with a real key later — structure so a key dropped into
   Keychain lights everything up with no code change).

Git: single commit on main (no push). Stage only your files.
