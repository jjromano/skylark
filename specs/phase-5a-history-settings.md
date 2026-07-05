# Phase 5a spec — history window, dictionary/modes management, settings polish, audio opt-in

Read `ARCHITECTURE.md`, `CLAUDE.md`, then the code you're extending:
`Sources/Skylark/` (AppController, Settings views, Onboarding),
`SkylarkCore/Persistence/` (HistoryStore, DictionaryStore, ModeStore, HistoryHub),
`Models/` (DictionaryEntry, DictationMode, CorrectionDiff, DictionaryCorrector),
`Pipeline/DictationOrchestrator.swift`, `Audio/AudioCaptureService.swift`.
`make test` runs the suite (never `swift test`). A parallel agent is writing
docs/scripts in a separate worktree — **do not touch: README*, Scripts/,
Makefile, Resources/Info.plist, LICENSE, or any *.md.**

## Work items

### 1. History window (menu bar → "History…")
- Searchable list (search field → `HistoryStore.search`, else `recent(200)`),
  rows: timestamp, engine badge, first ~80 chars of final text (clean if
  present else raw).
- Detail pane: raw text, clean text (when present), mode, engine, duration,
  latency ms. Copy button (writes final text to clipboard — this is an
  explicit user action, no snapshot needed). Delete row; "Clear History…"
  with confirm → `purgeAll()`.
- **Edit → auto-learn loop (closes the PRD auto-add requirement):** the final
  text is editable; on save, run `CorrectionDiff.diff(raw:edited:)` and show
  resulting candidate pairs as toggleable "Add to dictionary" chips
  (default ON); accepted pairs upsert `DictionaryEntry(source:
  .autoCorrection)` and the edited text persists via `updateEditedText`.
  The corrector must pick up new entries on next dictation (verify the
  orchestrator's per-session dictionary fetch already guarantees this).
- If audio retention was ON for an entry (`audio_path` non-nil): a play
  button (AVAudioPlayer) + the file is deleted when the row is deleted /
  history is purged.

### 2. Audio retention opt-in (default OFF — PRD §8)
- Settings → History section: toggle "Keep audio recordings (local only)" +
  explanatory text; "Delete all stored audio" button.
- When ON: after a completed dictation the orchestrator hands the clip to the
  history sink; `HistoryHub` writes 16 kHz mono WAV (reuse `WavEncoder`) to
  `~/Library/Application Support/Skylark/Audio/<uuid>.wav` and stores the
  path. Strictly off the paste path (inside the existing detached hub work).
  When OFF (default): clip is never retained anywhere (verify current
  behavior drops it — it must remain so).
- Purge/delete removes files; on launch, orphaned files in `Audio/` with no
  DB row are cleaned up (detached, logged count only).

### 3. Dictionary management (Settings → "Dictionary")
- Table of entries (phrase, replacement, source badge manual/auto, date);
  add (phrase + optional replacement), edit inline, delete. Upsert-by-phrase
  semantics already exist in the store.
- Explainer line: entries without replacement bias cleanup; with replacement
  they rewrite the transcript directly.

### 4. Modes management (Settings → "Modes")
- List modes; create/edit/delete (name, bundle-ID pattern with a "pick from
  running apps" convenience menu (NSWorkspace.runningApplications, regular
  activation policy only), cleanup tier picker (Auto is not a tier — raw/
  local/cloud), per-mode cloud model picker from registry when tier=cloud,
  register hint text field, isDefault toggle — enforce exactly one default
  (the store may need a small `setDefault(id:)` transaction; add it).
- Deleting the default mode is blocked; deleting a mode leaves history rows
  intact (mode_id is informational).

### 5. Settings polish (structure only, keep it native and plain)
- Reorganize the Settings window into a `TabView` (or sidebar) with:
  General (cleanup tier default + whisper mode + launch-at-login via
  `SMAppService.mainApp` with error surfacing), Models (exists), Audio
  (exists — device picker + BT warning), Dictionary (new), Modes (new),
  History (new — retention + purge), Account (existing API key card).
- Launch-at-login is NEW: implement with `SMAppService.mainApp.register()`/
  `unregister()`, reflect `.status`, and surface failures as inline text
  (headless box: don't crash if unavailable; it operates on the built .app,
  so mark it "needs `make app` + first launch" in a footnote if status is
  `.notFound` when running unbundled).
- Menu bar: add "History…" item; keep existing structure otherwise.

### 6. Tests
- CorrectionDiff→dictionary flow: edited text produces expected upserts
  (in-memory DB).
- HistoryHub audio write/delete/orphan-sweep (temp dir).
- setDefault(id:) uniqueness.
- Settings/UI views themselves need no unit tests; keep view logic in small
  testable helpers where natural.

## Acceptance
1. `swift build` clean; `make test` green (existing 128 + new).
2. `make app` bundles.
3. Report deviations + MacBook-validation additions. Remember: no README/
   Scripts/Info.plist changes — if you need one, report it instead.

Git: single commit on main (no push). Stage only your files.
