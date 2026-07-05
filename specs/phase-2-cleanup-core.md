# Phase 2 core spec — cleanup pipeline, in-place replace, dictionary engine, app-aware modes

Read `ARCHITECTURE.md`, `CLAUDE.md`, and the shared types just landed in
`Sources/SkylarkCore/Cleanup/` and `Sources/SkylarkCore/Models/` (Cleaner,
CleanupContext, CleanupPrompt, DictionaryEntry/DictionaryProviding). Extend
Phase 0/1 code; don't restructure. A parallel agent is building persistence +
OpenRouter clients in a separate worktree — **do not create or modify:
`Package.swift`, anything under `Sources/SkylarkCore/Persistence/`,
`Sources/SkylarkCore/Credentials/`, or any file named `OpenRouter*`.** Where
you need modes/dictionary data, depend on the protocols below with in-memory
defaults; the orchestrator (Fable) wires GRDB stores in an integration pass.

Latency contract (PRD §6.3): the raw paste NEVER waits on cleanup, except the
documented paste-fallback case below.

## Work items

### 1. Cleaners (SkylarkCore/Cleanup/)
- `RawPassthrough: Cleaner` — `tier: .raw`, returns input unchanged.
- `LocalCleaner: Cleaner` — `tier: .local`, Apple FoundationModels:
  - `import FoundationModels` (system framework, no package change).
  - Availability via `SystemLanguageModel.default.availability`; on
    `.unavailable(reason)` throw `CleanerError.unavailable` with a
    human-readable reason string (the app surfaces "Enable Apple Intelligence"
    guidance later). This machine WILL report appleIntelligenceNotEnabled —
    that state must be handled, not crash; you cannot test real generation
    here, so unit-test the prompt assembly + unavailable path and structure
    the generation call behind a thin protocol you can fake.
  - **No `@Generable`/`@Guide` macros** — they don't compile with CLT-only.
    Plain string respond.
  - Per-request: fresh `LanguageModelSession(instructions:
    CleanupPrompt.instructions(context:))`, `respond(to:
    CleanupPrompt.userMessage(transcript:), options: GenerationOptions(
    temperature: 0.1, maximumResponseTokens: <~2× transcript tokens, capped>))`.
    Keep ONE prewarmed session alive for latency (`session.prewarm()`) but
    never reuse a session that has already responded (4096-token context, no
    accumulation) — prewarm the next one off the paste path after each use.
  - Output hygiene: trim whitespace; strip surrounding quotes if the model
    added them; if output is empty or > 3× input length, throw
    `.unusableOutput` (caller keeps raw).
- Truncation guard: if transcript would exceed the context budget (~3000
  tokens worth; estimate 4 chars/token), skip cleanup entirely
  (`CleanerError.unavailable(reason: "transcript too long for local cleanup")`).

### 2. In-place replacement (SkylarkCore/Injection/TextInjector.swift)
Implement `replace(_ token: InsertionToken, with text: String)`:
- Only for `method == .ax(element)`:
  1. Confirm the focused element is still `CFEqual` to the token's element
     (user hasn't clicked elsewhere) — else abort silently (raw text stands).
  2. Read `kAXSelectedTextRange` (caret expected at end of insertion). Compute
     candidate range `{caret.location - token.text.utf16 count, length}` (mind
     UTF-16 vs CFRange units — AX ranges are UTF-16 code units).
  3. Verify with `kAXStringForRangeParameterizedAttribute` that the candidate
     range's text equals `token.text`; mismatch → abort silently.
  4. Set `kAXSelectedTextRange` to the candidate range, then
     `kAXSelectedTextAttribute` to the replacement; restore caret to end.
- `method == .paste` → throw `InjectionError.replaceUnsupported` (new case);
  the orchestrator handles strategy (below). Add the case; remove
  `replaceNotImplemented`.
- Unit tests: the range math (UTF-16, incl. emoji/multibyte) as pure
  functions; AX calls behind the existing structure so tests fake them.

### 3. Pipeline stage (SkylarkCore/Pipeline/DictationOrchestrator.swift)
- After successful injection with cleanup tier ≠ raw: run the active cleaner;
  on success and output ≠ raw text → `injector.replace(token, cleaned)`.
  Every failure (`CleanerError`, replace abort/unsupported, timeout) is
  silent-to-the-user: raw text stands, one log line, state returns to idle
  regardless. Cleanup runs detached from the HUD state (HUD goes idle at
  paste, per ARCHITECTURE §3).
- Paste-fallback targets (token.method == .paste): **wait-for-clean** —
  run the cleaner BEFORE injecting, capped at 2 s (race the cleaner against
  the clock; on timeout or failure inject raw). AX targets keep
  paste-raw-then-replace. This is a deliberate PRD deviation for apps where
  select-back is unsafe — but you don't know the method before inserting, so:
  probe AX support first (extract the Phase-0 probe into
  `TextInjector.canInsertDirectly() -> Bool`) and branch the pipeline on it.
- Cleanup timeout: 5 s cap on the replace path too (then skip replace).
- Active cleaner selection: `CleanupTier` comes from the resolved mode (below);
  map `.raw → RawPassthrough`, `.local → LocalCleaner`, `.cloud → nil for now`
  (fall back to `.local` if cloud selected but no cloud cleaner is registered;
  integration pass swaps in OpenRouterCleaner via the existing composition
  root — design a `CleanerRegistry` the app target populates).

### 4. Dictionary correction engine (SkylarkCore/Models/)
- `DictionaryCorrector`: built from `[DictionaryEntry]`; applies entries with
  `replacement != nil` to a transcript — case-insensitive, word-boundary,
  preserves leading capitalization of the matched token when the replacement
  is lowercase. Precompiled `NSRegularExpression`s built once per dictionary
  change (rebuild via `update(entries:)`), application budget ≤ 5 ms for 200
  entries on a 100-word transcript (measure in a test with `ContinuousClock`,
  assert < 50 ms to keep CI slack).
- Runs BEFORE the raw paste in the orchestrator (it's part of raw text, PRD:
  correction map applies always, even Tier 0).
- Entries with `replacement == nil` feed `CleanupContext.dictionaryTerms`.
- `CorrectionDiff`: pure word-level differ `diff(raw: String, edited: String)
  -> [(from: String, to: String)]` producing candidate auto-add pairs when a
  user edits a history entry (UI lands in Phase 5; engine + tests now).
  Filter: only single-token→single/double-token substitutions, length ≥ 3,
  not pure case/punctuation changes.

### 5. App-aware mode selection (SkylarkCore/Models/ + Pipeline)
- `struct DictationMode: Sendable, Codable, Equatable { id, name,
  bundleIDPattern: String? /* glob, e.g. "com.apple.mail" or "com.microsoft.*" */,
  cleanupTier: CleanupTier, registerHint: String?, isDefault: Bool }`
  (engine/model fields come with Phase 3/4 integration — add
  `cloudCleanupSlug: String?` now so the type is stable).
- `protocol ModeProviding: Sendable { func modes() async throws -> [DictationMode] }`
  + `InMemoryModeProvider` default seeded with: "Default" (local tier,
  isDefault), "Raw" (raw tier, no pattern).
- `FrontmostAppMonitor` (app target or core — your call): tracks frontmost
  bundle ID via `NSWorkspace.shared.notificationCenter`
  `didActivateApplicationNotification` + initial `frontmostApplication`.
  Captured AT DICTATION START (fn-down), not at paste time.
- `ModeResolver`: pure — `(bundleID: String?, modes: [DictationMode]) ->
  DictationMode`; most-specific glob match wins (exact > longest-prefix glob >
  default). Unit-test.
- Orchestrator: resolve mode at session start; use its tier + registerHint +
  dictionary terms to build `CleanupContext`.

### 6. Menu bar (Sources/Skylark/AppController.swift)
- Add a "Cleanup" submenu: Raw / Local (check current tier of the default
  mode override). This is a temporary global override (UserDefaults-backed,
  `@AppStorage`) until the real Settings UI; wire it through the composition
  root into mode resolution (override replaces resolved tier when set to raw;
  "Auto" clears).

## Acceptance
1. `swift build` clean (zero warnings from our sources); `make test` green —
   new tests: LocalCleaner prompt/unavailable/hygiene (faked model),
   replacement range math, orchestrator cleanup stage (spy injector: replace
   called with cleaned text; failure leaves raw; paste-fallback waits then
   times out to raw), DictionaryCorrector (case, boundaries, budget),
   CorrectionDiff, ModeResolver globs.
2. `make app` still bundles.
3. Report deviations + interactive-validation additions.

Git: single commit on main when done (no push). Stage only files you touched.
