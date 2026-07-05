# Phase 3 backbone spec — GRDB persistence, Keychain, OpenRouter clients

Read `ARCHITECTURE.md` (§5 data model, §6 OpenRouter facts), `CLAUDE.md`, and
the shared types in `Sources/SkylarkCore/Cleanup/` + `Sources/SkylarkCore/Models/`
(Cleaner, CleanupContext, CleanupPrompt, ModelRegistryEntry with its seed,
DictionaryEntry/DictionaryProviding). You are building the data + network
backbone in an isolated worktree. **Do not modify: `Sources/SkylarkCore/Pipeline/`,
`Hotkey/`, `Audio/`, `Injection/`, `Transcription/FluidAudioParakeet.swift`,
or anything under `Sources/Skylark/` (app target)** — a parallel agent owns
those. You own: `Package.swift` (add GRDB only), `Persistence/`, `Credentials/`,
`Cleanup/OpenRouterCleaner.swift`, `Transcription/OpenRouterCloud.swift`,
`Network/`, and your test files.

## Work items

### 1. Persistence (SkylarkCore/Persistence/, GRDB)
- Add `.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")`,
  product `GRDB`. (MIT.) If 7.x somehow fails against this toolchain, latest
  6.x is acceptable — report it.
- `SkylarkDatabase`: `DatabaseQueue` at
  `~/Library/Application Support/Skylark/skylark.sqlite` (dir creation, WAL);
  in-memory init for tests. `DatabaseMigrator` migration "v1" creating
  (ARCHITECTURE §5): `history(id PK autoinc, timestamp, raw_text, clean_text NULL,
  mode_id NULL, engine, duration_ms, latency_ms, audio_path NULL)`;
  `dictionary(id PK autoinc, phrase UNIQUE COLLATE NOCASE, replacement NULL,
  source, created_at)`; `modes(id TEXT PK, name, bundle_id_pattern NULL, engine NULL,
  cleanup_tier, cloud_cleanup_slug NULL, register_hint NULL, is_default)`;
  `model_registry(slug TEXT PK, label, provider_pin NULL, kind, sort)`.
- Stores (each an actor or GRDB-safe struct over the queue):
  - `HistoryStore`: `append(HistoryRecord)`, `search(text: String, limit:)`
    (LIKE for now), `recent(limit:)`, `updateEditedText(id:new:)`, `delete(id:)`,
    `purgeAll()`. Define `HistoryRecord` here mirroring the table.
  - `DictionaryStore: DictionaryProviding`: CRUD + `entries()`;
    upsert by phrase.
  - `RegistryStore`: `all(kind:)`, `upsert(entry:)` (free-text slug path),
    `seedIfEmpty()` with `ModelRegistryEntry.seed`.
  - `ModeStore`: CRUD; `seedIfEmpty()` with the same two defaults the
    parallel agent uses in its `InMemoryModeProvider` ("Default" local tier +
    isDefault, "Raw" raw tier). Store rows serialize `CleanupTier` as TEXT
    ("raw"/"local"/"cloud:<slug>").
- Settings do NOT go in SQLite (UserDefaults; not your scope).

### 2. Keychain (SkylarkCore/Credentials/KeychainStore.swift)
- Generic-password item: service `com.jjromano.skylark`, account
  `openrouter-api-key`. `get() -> String?`, `set(String) throws` (upsert),
  `delete() throws`. No caching of the key anywhere else; never log it.
  kSecAttrAccessible = `kSecAttrAccessibleWhenUnlocked`.
- Headless test caveat: Keychain works in a CLI context on this box, but if
  the default keychain is locked in your environment, mark those tests to
  skip gracefully (detect errSecInteractionNotAllowed) rather than fail.

### 3. OpenRouter client (SkylarkCore/Network/OpenRouterClient.swift)
Facts are in ARCHITECTURE §6 (verified 2026-07; trust them):
- `struct OpenRouterClient`: init with `keyProvider: @Sendable () -> String?`
  and `URLSession` (injectable; tests use `URLProtocol` stub).
  Headers: `Authorization: Bearer <key>`, `HTTP-Referer:
  https://github.com/jjromano/skylark`, `X-OpenRouter-Title: Skylark`.
- `transcribe(audio: Data, format: String, model: String, language: String?)
  async throws -> TranscriptionResponse` — POST `/api/v1/audio/transcriptions`,
  JSON body `{model, input_audio: {data: <base64>, format}, language}`;
  response `{text, usage{cost,...}}`. Request timeout 60 s.
- `complete(messages: [ChatMessage], model: String, providerPin: String?,
  stream: Bool, temperature: Double?, maxTokens: Int?) async throws ->
  AsyncThrowingStream<String, Error>` — POST `/api/v1/chat/completions`;
  when providerPin set: `"provider": {"order": [pin], "allow_fallbacks": true}`.
  SSE parsing: `data:` lines, `choices[0].delta.content`, terminate on
  `[DONE]`, ignore comment keep-alive lines starting with `:`. Non-stream
  variant returns the full text as a single yield.
- `validateKey() async throws -> KeyInfo` — GET `/api/v1/key`; map
  `data.label/limit/limit_remaining/usage` into a small struct. 401 →
  `OpenRouterError.invalidKey`.
- Error taxonomy `OpenRouterError`: `noKey, invalidKey, rateLimited,
  timeout, network(underlying), server(status:message:), decoding`.
  Map mid-stream SSE error events too.
- Never log request/response bodies (they contain transcripts).

### 4. Cloud engines (thin, over the client)
- `OpenRouterCleaner: Cleaner` (`Cleanup/OpenRouterCleaner.swift`):
  `tier: .cloud(slug:)`; init with client + `ModelRegistryEntry`. Uses
  `CleanupPrompt.instructions(context:)` as the system message and
  `CleanupPrompt.userMessage(transcript:)` as user; temperature 0.1;
  maxTokens ~ 2× transcript estimate. Non-streaming for v1 (the replace
  needs full text anyway). Same output hygiene as the spec'd LocalCleaner:
  trim, strip wrapping quotes, empty or >3× input → `CleanerError.unusableOutput`.
  No key → `CleanerError.unavailable(reason: "No OpenRouter API key")`.
- `OpenRouterCloud: Transcriber` (`Transcription/OpenRouterCloud.swift`):
  conforms to the existing `Transcriber` protocol (read it first);
  `id: .cloud(slug)` — extend `TranscriberID` if it lacks that case (small,
  allowed; it's in `Transcription/Transcriber.swift`, coordinate-free).
  Encodes `AudioClip` (16 kHz mono Float32) → WAV PCM16 (pure function
  `WavEncoder.encode(samples:sampleRate:) -> Data` + unit test with a known
  golden header) → base64 via the client with `language: "en"` hint.
  `warmUp()` = no-op. Clip guard: reuse `FluidAudioParakeet.shouldSkip`.

### 5. Tests (Tests/SkylarkTestKit/, run with `make test` — NOT `swift test`)
- Migrations + every store round-trip (in-memory DB); registry/mode seeding
  idempotence; history search.
- KeychainStore round-trip (with the locked-keychain skip).
- OpenRouterClient with URLProtocol stubs: transcription request shape
  (assert base64 + format + language in body), provider pin JSON, SSE stream
  parse (chunks, keep-alive comments, [DONE], mid-stream error event),
  key validation 200 + 401.
- WavEncoder golden test; OpenRouterCleaner hygiene paths.

## Acceptance
1. `swift build` clean, `make test` green (existing tests must stay green).
2. `make app` still bundles (GRDB is a static dependency; if bundle.sh needs
   a change for it, make it and report).
3. Report: files touched, deviations, anything the integration pass must wire.

Git: commit all your work as a single commit on YOUR worktree branch (no
push, no merge — the orchestrator integrates).
