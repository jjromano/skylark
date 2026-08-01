# Skylark privacy audit — Sources sweep

*Revised 2026-07-31 against v0.13.0 (this revision corrects the network
inventory below, which undercounted; see the corresponding CHANGELOG entries
for the shipped behavior these citations describe). Same-day follow-up pass,
also 2026-07-31: §2's log-content sweep and §3's `UserDefaults` inventory
were both re-enumerated from scratch and closed out — both had gone stale
("28 log sites" and "~69 UserDefaults sites, not individually re-verified")
relative to the current tree.*

Read-only audit of `Sources/` against the invariants in `ARCHITECTURE.md` §7
and `CLAUDE.md`'s hard rules. This document does not modify `Sources/` or
`Tests/`; anything questionable is listed under Findings for the code owner
to fix, not fixed here.

Scope: every network call, every `logger`/`Logger` call site, Keychain vs.
other secret storage, and the clipboard snapshot/restore path.

## 1. Network touchpoints

Nine categories of outbound network access exist in `Sources/` (a prior
revision of this document said "exactly three" — that undercounted; the
model-download surface alone is four separate paths, plus Command Mode and
one OS-managed path this document had never enumerated). No other
`URLSession`, socket, or shell-out to `curl`/`Process` for networking was
found anywhere in the tree — re-confirmed by grepping every `URLSession`/
`URLRequest`/`.download(` call site in `Sources/`.

| # | Call site | Trigger | Data sent |
|---|---|---|---|
| Cloud STT | `OpenRouterClient.transcribe` (`Sources/SkylarkCore/Network/OpenRouterClient.swift:75`), invoked from `OpenRouterCloud` (`Sources/SkylarkCore/Transcription/OpenRouterCloud.swift:27`) | User has selected a cloud entry under menu bar → Speech Engine and dictates | The recorded audio clip, WAV-encoded and base64-inlined in the JSON body, to `POST /api/v1/audio/transcriptions` |
| Cloud re-transcribe | `OpenRouterClient.transcribe` via `Retranscription.run` (`Sources/SkylarkCore/Transcription/Retranscription.swift:20`) → `OpenRouterCloud`, built by `AppController.makeRetranscriber` | In History, the user opens a *retained* entry and explicitly picks a **cloud** engine in the Re-transcribe control, then clicks Go | A previously-retained clip, decoded from its local WAV (`WavDecoder`) and re-encoded/base64-inlined, to `POST /api/v1/audio/transcriptions`. This is the *only* path on which a **retained** file leaves the Mac, and it is a deliberate per-entry user action. Local re-transcribe engines never touch the network. |
| Cloud cleanup | `OpenRouterClient.complete` (`OpenRouterClient.swift:105`), invoked from `OpenRouterCleaner` (`Sources/SkylarkCore/Cleanup/OpenRouterCleaner.swift:24`) | Menu bar → Cleanup is set to Cloud | The raw transcript text only (no audio) as a chat message, to `POST /api/v1/chat/completions`, plus a **transcript-relevant subset of the custom dictionary** — see the P1-6 note below |
| Command Mode (cloud) | `OpenRouterClient.complete` via `CommandRunner.run` (`Sources/SkylarkCore/Command/CommandRunner.swift:66,116-138`), invoked from `DictationOrchestrator` (`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:1390`) | The voice-command shortcut is bound to a **cloud** cleanup-tier model and the user speaks an instruction | The selected text (or, with no selection, just the spoken instruction) plus the instruction itself, as chat messages, to `POST /api/v1/chat/completions`. Whatever the user highlighted before speaking the command leaves the machine here — the same tier the Cleanup menu is set to; a **local** tier keeps it on-device (`CommandRunner.run`'s `.local` branch calls `LocalCleanupBackend.generate`, no network) |
| Key validation | `OpenRouterClient.validateKey` (`OpenRouterClient.swift:191`), invoked from `APIKeyCard.save()` (`Sources/Skylark/APIKeyEntry.swift:83`) | User saves a key in onboarding or Settings | Only the Bearer key in the request header, to `GET /api/v1/key` |
| Model download (Parakeet) | `AsrModels.downloadAndLoad` (`Sources/SkylarkCore/Transcription/FluidAudioParakeet.swift:83`) | First local-engine warm-up if the Parakeet model isn't already on disk (`AppController.swift:1156,1960`) | Model weight files from Hugging Face only — no audio, no transcript |
| Model download (Whisper) | `WhisperKit.download` (`Sources/SkylarkCore/Transcription/WhisperKitWhisper.swift:88`) | First WhisperKit warm-up if the large-v3-turbo checkpoint isn't already on disk (`AppController.swift:1966`) | Model checkpoint files only. `downloadBase` is overridden to `ModelPaths.whisperKitBase` (`ModelPaths.swift:69-71`) instead of WhisperKit's default `Documents/huggingface`, per the ARCHITECTURE §6 note |
| Model download (deep-vocabulary CTC) | `ModelHub.download` via `FluidAudioDeepVocabularyRescorer.prepareModel` (`Sources/SkylarkCore/Transcription/FluidAudioDeepVocabularyRescorer.swift:73-95`) | User opts into Deep Vocabulary matching (Settings → Dictionary/Models) and the ~98 MB Parakeet CTC-110M helper model isn't already on disk (`AppController.swift:260-267`) | Model weight files (`ctc110m.repo`) from Hugging Face only — no audio, no transcript. Off by default (`AppController.deepVocabKey`) |
| Model download (Qwen cleanup GGUF) | `URLSession` download task in `CleanupModelDownloader.start` (`Sources/SkylarkCore/Cleanup/Llama/CleanupModelDownloader.swift:46-67`) | User downloads a local Qwen cleanup model from Settings → Models | GGUF weight file only, from a **pinned immutable Hugging Face revision** (not `resolve/main` — `LocalCleanupModel.swift:123,139`), staged and **SHA-256-verified** before an atomic swap-in (`CleanupModelInstaller.swift:79,112-116`); a corrupt or tampered download never replaces a working model |
| Apple Speech assets (system) | `AssetInventory.assetInstallationRequest`/`.reserve` (`Sources/SkylarkCore/Transcription/SpeechAnalyzerTranscriber.swift:99,110`) | User selects Apple Speech as the STT engine and the on-device language assets aren't yet installed | Handled entirely by the OS's own asset-management daemon, not by any `URLSession` in `Sources/` — Skylark only asks `AssetInventory` to reserve/install; it never sees or controls the transfer. Listed for completeness, not because Skylark code originates the request |

Every OpenRouter request also carries a static `HTTP-Referer:
https://github.com/jjromano/skylark` and `X-OpenRouter-Title: Skylark` header
(`OpenRouterClient.swift:222-223`) — an identifying header on every cloud
call (transcription, cleanup, command mode, key validation), not a secret
leak, but listed under Findings for visibility.

**P1-6 — dictionary terms sent to cloud cleanup.** Before v0.13.0, cloud
cleanup uploaded the user's *entire* custom dictionary with every request (a
measured 10.5 KB dictionary added 4.9 KB per request, with none of its terms
anywhere in the transcript) — colleagues' names, project code names, client
names, and jargon the user never spoke in that utterance. `DictionaryRelevance`
(`Sources/SkylarkCore/Cleanup/DictionaryRelevance.swift`) now filters that list
per-request: only terms the transcript plausibly contains (exact token, listed
misspelling, shared prefix, or small edit distance) are included, capped at 40
terms (`DictionaryRelevance.maxTerms`, `:29`); nothing matched means no
dictionary line in the prompt at all. This is wired in
`DictationOrchestrator.cleanupContexts` (`DictationOrchestrator.swift:1791-1804`):
the filter runs **only** when the resolved tier is `.cloud` — local and raw
tiers get the unfiltered context (nothing leaves the machine there regardless).
The Dictionary pane (`Sources/Skylark/Settings/DictionaryView.swift:28-32`)
discloses this: "With cloud cleanup, terms that match what you said are sent
along; the rest of your dictionary stays on this Mac. Local cleanup never
sends any of it." Command Mode's selected text (row above) is a separate
upload with no equivalent per-term filtering — the whole selection travels
when the bound tier is cloud, which is the nature of that feature (there is
no "dictionary" to filter, only the highlighted text itself).

## 2. Disk/log writes of audio or transcript content

**Re-swept 2026-07-31** (this document's prior "28 call sites" figure was
stale — it undercounted by 4x). Method: `grep -rn 'logger\.\|Logger('
Sources/` finds every `Logger(...)` instantiation and every `logger.<level>`
call; each of the **111 matches, across 20 files**, was read in place with
its surrounding function to trace every interpolated value back to its
source. Breakdown: 20 are `private/static let logger = Logger(subsystem:...,
category: ...)` declarations (no content — they carry only a static
subsystem/category string), leaving **91 actual log call sites**.

**Verdict: none of the 91 call sites interpolate transcript text (raw or
clean), dictionary phrases/misspellings, snippet content, command/selection
text, clipboard content, an API key, raw audio samples, or a file path that
embeds user content.** Every content-bearing value logged is metadata:
durations, sample *counts* (never the samples array), `OSStatus`/error
codes, enum-derived labels (`Self.tierString`, `Self.stageString`,
`CaptureInterruption.reason.rawValue`), app-bundle identifiers
(`NSWorkspace...bundleIdentifier`, `capturedTarget.bundleID`), AX role
strings (`kAXRoleAttribute`, e.g. `"AXTextField"` — a UI element type, not
its contents), model slugs/ids, hotkey-binding raw values (stable
persistence strings like `"chord:cmd+opt"`, never a keystroke's typed
content), a compile-time `StaticString` restore-trigger label
(`PasteRestore.swift`'s `trigger:` parameter), or `error.localizedDescription`
on error enums whose associated values are themselves content-free
(`ParakeetError`, `WhisperKitError`, `OpenRouterError`,
`CleanerError.unavailable(reason:)` — always a static string like `"No
OpenRouter API key"`, never the transcript — `KeychainError`,
`InjectionError`). `DictationOrchestrator.swift`'s per-dictation summary
(`:1068`) and latency line (`:2051`) both carry explicit "Content-free"
code comments next to the log call.

**One dev-only site flagged for judgment, not a violation of the rule as
shipped** — see Finding 6 below: `LlamaRunner.swift:463-465` forwards
llama.cpp's own native log callback into the unified log, but only when the
developer-only `SKYLARK_LLAMA_LOG` environment variable is set (unset for
every normal user run, where the callback discards everything); even then
only `GGML_LOG_LEVEL_WARN`-and-above lines are forwarded. The interpolated
value (`String(cString: text)`) originates inside llama.cpp's C code, not
Skylark's own strings, so its content isn't fully auditable from the Swift
call site the way every other line in this sweep is — the in-code comment
argues warn/error-level llama.cpp lines are config/state chatter, not
prompt-derived, but that argument isn't independently verified against
llama.cpp's source in this pass.

Representative content-free sites (of the 91):
`DictationOrchestrator.swift:503,525,806,1068-1073,1239-1244,1301-1305,
1569-1572,1815-1819,1897,2028-2031,2051-2055`;
`FluidAudioParakeet.swift:115`; `WhisperKitWhisper.swift:112`;
`AudioCaptureService.swift:295-299,321,323` (sample/duration counts, never
the buffer); `AudioDeviceManager.swift:99`; `SpeechEndpointer.swift:73,76,
106,146`; `TextInjector.swift:653,663` (bundle id + AX role only, never any
text near the caret); `HotkeyMonitor.swift:138,152,163,708,712`;
`LlamaRunner.swift:219,320-326`; `QwenCleanupBackend.swift:63-69` (token
counts/timings, never the prompt or output — explicit comment);
`CleanupProviderPins.swift:56,59` (model slugs); `PasteRestore.swift:392-403,
406-410` (trigger is a `StaticString`, never clipboard content).

**History persistence.** `HistoryStore` (`Sources/SkylarkCore/Persistence/HistoryStore.swift`) is a GRDB actor over the local `history` table, opened by `SkylarkDatabase` (`Sources/SkylarkCore/Persistence/SkylarkDatabase.swift:80`) at `~/Library/Application Support/Skylark/skylark.sqlite` — local file, WAL mode, no sync/cloud path anywhere in the codebase. Schema matches ARCHITECTURE §5, including a nullable `audio_path` column.

**Audio retention default.** Audio retention is opt-in and OFF by default,
per PRD §8. *(This section was audited before the retention feature merged;
re-verified after the merge:)* the toggle lives in Settings → History; when
OFF (default) the clip handed to `HistoryHub` is dropped and never written.
When ON, `HistoryHub` writes 16 kHz WAV files to
`~/Library/Application Support/Skylark/Audio/` strictly off the paste path,
and per-row delete / Clear History / "Delete all stored audio" remove the
files. An orphan sweep at launch removes files with no DB row (logs a count
only). Retained files are pruned by an audio-only retention window (default 7
days; `HistoryStore.pruneAudio` deletes the file and nulls `audio_path`,
keeping the text row) at launch and on setting change, and turning the toggle
off deletes every retained file immediately (`AppController.setAudioRetentionEnabled`
→ `HistoryHub.deleteAllAudio`).

**Reads of retained audio.** Live cloud STT never reads retained files — it
encodes the in-memory clip of the current dictation only. The one place a
retained file is *read* is History → Re-transcribe (`WavDecoder.decode` →
`Retranscription.run`): the clip is decoded locally and fed to a
freshly-instantiated engine. With a **local** engine chosen, the audio never
leaves the Mac; with a **cloud** engine explicitly chosen, it is uploaded once
(the "Cloud re-transcribe" row in §1). Re-transcribe replaces the row's raw
text and clears its clean text — no re-cleanup, no re-injection, and no audio
or transcript content is logged on this path (only content-free engine/network
errors surface to the History detail pane).

## 3. Keychain-only secrets

`KeychainStore` (`Sources/SkylarkCore/Credentials/KeychainStore.swift`) is a
generic-password Keychain item — service `com.jjromano.skylark`, account
`openrouter-api-key`, `kSecAttrAccessibleWhenUnlocked` (`:15,88`).
`get()`/`getStrict()` never fall back to any other store; `set()`/`delete()`
touch only the Keychain.

`APIKeyCard` (`Sources/Skylark/APIKeyEntry.swift`) is the sole UI reader/writer:
`save()` (`:83-105`) writes via `KeychainStore().set(entered)` then
immediately clears the view's `@State private var key` (`:102`, commented
"never keep the key in view state"). Its error-mapping helper
(`friendly(error:)`, `:131`) returns static strings only — the key or raw
error text is never surfaced.

**`UserDefaults` inventory, fully re-enumerated 2026-07-31** (this document's
prior "~69 sites, not individually re-verified" note was stale and is now
closed out). Method: `grep -rn 'UserDefaults'` across `Sources/` plus
`\.set(` on every type that takes an injected `defaults: UserDefaults`
parameter, to catch the non-`.standard`-literal writers
(`ModelSelection`, `CleanupIntensity`, `LocalCleanupEngine`,
`VadClipTrimmer`, `HistoryStore` all default that parameter to `.standard`
but are written to only through `AppController`/`ModelSelection` — every
key below was traced to its literal string). Total: **38 write call sites**
(36 `UserDefaults.standard.set(...)` + 2 `defaults.set(...)` in
`ModelSelection.swift`, plus 4 `removeObject(forKey:)` calls) across **33
unique keys**, all written from `Sources/Skylark/AppController.swift` and
`Sources/SkylarkCore/Models/ModelSelection.swift:64,68`.
`Sources/Skylark/History/HistoryView.swift:463` only *reads* one of
AppController's keys (`dictionaryAutoLearnKey`); every other file's
`UserDefaults` mentions found by the grep are doc comments, not code.

Every key was read at its write site to confirm the stored value's type and
provenance. **None store an API key/token, transcript content (raw or
clean), dictionary/snippet content, or a user file path** — grouped by
area:

| Area | Keys | What's stored |
|---|---|---|
| Hotkey | `hotkey.keyboard`, `hotkey.mouse`, `hotkey.command`, `hotkey.cycleCleanup` | `HotkeyBinding.rawValue` — a stable persistence string for a key/chord (e.g. `"chord:cmd+opt"`, a function-key label), never a live keystroke or its typed content |
| Models / engines | `modelSelection.cleanupSlug`, `modelSelection.sttChoice`, `localCleanupEngine` | Model slug / STT-engine / local-cleanup-engine identifiers (e.g. an OpenRouter slug, `"apple"`) |
| Cleanup behavior | `cleanupTierOverride`, `cleanup.intensity`, `cleanup.timeoutSeconds`, `cleanup.useOnScreenContext`, `vadClipTrimEnabled` | Tier-override string (`"auto"`/`"raw"`/…), an intensity enum's raw value, a timeout in seconds, and two booleans |
| Dictionary toggles | `dictionary.autoLearn`, `dictionary.learnFromCorrections`, `dictionary.deepVocabMatching`, `dictionary.deepVocabMatching.v0122KillSwitch`, `dictionary.deepVocabMatching.v0123ReEnable` | Booleans only — none of these ever hold a dictionary term; the actual dictionary lives in GRDB (`SkylarkDatabase`), not `UserDefaults`. The two `v0122`/`v0123`-named keys are one-shot migration flags for the deep-vocabulary kill-switch history, not user data |
| HUD | `hud.style`, `hud.showIdlePill` | A style enum's raw value and a boolean |
| History / retention | `history.audioRetentionEnabled`, `history.retentionDays`, `history.audioRetentionDays` | A boolean and two day-count integers — never a retained clip's path or content (those live in GRDB/`Audio/`, per §2) |
| Recording / pipeline | `pressEnterCommandEnabled`, `recording.livePreview`, `pauseMediaWhileDictating`, `whisperMode` | Booleans only |
| Translation | `translation.enabled`, `translation.targetLanguage` | A boolean and a language code (e.g. `"es"`) — never translated text |
| Sound effects | `soundEffectsEnabled`, `soundStartID`, `soundStopID`, `soundVolume` | A boolean, two built-in sound-asset identifiers, and a volume float |
| Audio device | `audio.inputDeviceUID` | A `AVCaptureDevice`/CoreAudio hardware UID string — a device identifier, not a file path |

No plain-file writes of the API key exist anywhere in `Sources/`; the only
other `FileManager` disk writes are `SkylarkBench` reading benchmark `.wav`
fixtures (unrelated to credentials) and the audio-retention/history paths
already covered in §2. `APIKeyCache` (`Sources/SkylarkCore/Credentials/
APIKeyCache.swift:16-18`) explicitly keeps the key in an in-process cache
only — "never written to disk or UserDefaults, never logged" — confirmed by
reading the type: no `UserDefaults` or file API appears in it at all.

## 4. Clipboard behavior

`PasteboardSnapshot` (`Sources/SkylarkCore/Injection/PasteboardSnapshot.swift:17-29`) snapshots **every** pasteboard item and **every** UTI type on each item as raw `Data` (not just the string type), and `restore(to:)` (`:31-43`) clears and rewrites every item/type from that snapshot — matching PRD §10's "full multi-item snapshot, all types."

**The restore mechanism was rebuilt in v0.13.0** (P1-1/P1-9 fixes) and this
section previously described the old blind-timer version; it no longer
matches the code. The current paste path,
`TextInjector.performClipboardPaste` (`Sources/SkylarkCore/Injection/TextInjector.swift:891-966`),
delegates the restore decision to `PasteRestoreCoordinator`/`PasteRestoreDecider`
(`Sources/SkylarkCore/Injection/PasteRestore.swift`):
snapshot → write the transcript as a **lazy pasteboard promise** (a real read
callback, not a timer) → poll `changeCount` to confirm the write committed →
synthesize Cmd-V → **arm** the decider (only reads from this point count as
"the target consumed it") → on the first accepted read, wait out a **120 ms
floor** (`PasteRestoreCoordinator.minimumRestoreDelay`, `:251`) plus a 100 ms
read-grace for apps that read twice, then restore; if nothing ever reads, a
500 ms ceiling (`fallbackRestore`) restores anyway. Two guards sit around the
write-back itself:
- **changeCount guard** (`PasteRestoreGuards.restoreIsSafe`, `PasteRestore.swift:145-147`):
  immediately before writing the snapshot back, the coordinator checks the
  pasteboard's `changeCount` still matches what Skylark's own write produced.
  If it doesn't — most commonly the user pressing Cmd-C during the ~120 ms
  restore window — **the restore is skipped entirely** and the snapshot is
  dropped rather than overwriting the user's newer copy (`PasteRestore.swift:389-399`,
  logged as "clipboard restore skipped: another writer took the pasteboard").
  This is a stronger privacy guarantee than the old version had (nothing the
  user copies during that window is ever silently destroyed) but it does mean
  "restore" is now conditional, not unconditional, even on the success path.
- **Posted-vs-read landing**: `InsertionToken.landing` distinguishes `.posted`
  (Cmd-V was sent to the HID tap; whether the target actually consumed it is
  unknown) from `.readConfirmed` (a pasteboard read was observed after
  arming) from `.notPosted` (synthesis itself failed). Callers that need the
  truth (History, Command Mode's replace) await `PasteLandingSignal`
  (`PasteRestore.swift:218-235`); callers that must be immediate
  (press-Return) don't block on it — see ARCHITECTURE §3.

On the **failure** branch (synthesized paste could not even be posted,
`TextInjector.swift:953-965`), the snapshot is deliberately **not**
restored — the transcript is written as real (non-promise) data and left on
the clipboard as the user's manual-paste fallback, per the in-code comment
"Leave the text on the clipboard as the user's fallback (do NOT restore)."
This still matches ARCHITECTURE §3's injection strategy, and the
"byte-for-byte clipboard restore" guarantee still holds conditionally, not
unconditionally — see Findings, which now also covers the changeCount-guard
skip case above.

## 5. Findings

Reported for visibility; none require a source change beyond what the code
already documents as intentional.

1. **`Sources/SkylarkCore/Injection/TextInjector.swift:953-965`** — when a synthesized paste cannot even be posted, the pre-dictation clipboard snapshot is discarded rather than restored; the user's prior clipboard contents are lost in that branch (the transcript replaces them until the user's next copy). This is a deliberate, commented tradeoff (better to leave usable text than silently drop it), unchanged in spirit since the last revision, just relocated by the v0.13.0 paste-restore rewrite.
2. **`Sources/SkylarkCore/Injection/PasteRestore.swift:389-399`** — new in v0.13.0: when another writer takes the pasteboard during the ~120 ms restore window (the confirmed live case is the user pressing Cmd-C right after dictating), the restore is skipped and the pre-dictation snapshot is silently dropped rather than fighting the user's newer copy. This protects the user's later action at the cost of the pre-dictation clipboard contents, which are lost in that specific interleaving — worth knowing about even though the code's judgment call (their newest action wins) is the right one.
3. **`Sources/SkylarkCore/Network/OpenRouterClient.swift:222-223`** — every OpenRouter request (transcription, cleanup, Command Mode, key validation) sends a static `HTTP-Referer`/`X-OpenRouter-Title` identifying header. No secret or user data in it, but it is an outbound identifier present on every cloud call, worth knowing about.
4. **Audio-retention opt-in is implemented** (see §2), OFF by default, with an audio-only retention window, toggle-off purge, orphan sweep, and per-row/purge deletion. The only outbound path for a retained clip is an explicit user-initiated cloud Re-transcribe (§1). No content is logged on any of these paths.
5. ~~Command Mode's selected-text upload (§1) has no dedicated privacy disclosure in Settings.~~ **Resolved and shipped in v0.14.0** (2026-07-31). The voice-command shortcut's footer (`Sources/Skylark/Settings/SettingsView.swift:281`) reads: "Hold and speak an instruction to rewrite selected text or generate text at the cursor. With a cloud cleanup model, the selected text and your instruction are sent to that model; with local cleanup they stay on this Mac." — parity with the Dictionary pane's P1-6 copy. Verified in the 2026-08-01 sweep: the string is present at that call site on `main`, `Resources/Info.plist` is stamped past 0.13.0, and the v0.14.0 CHANGELOG entry records it, so the versioning rule was satisfied. Closed for users.
6. **Per-mode custom cleanup instructions (v0.15.0) are a new user-authored cloud payload.** Settings → Modes → Custom instruction stores free text per mode (schema v6, `modes.custom_prompt`), capped at 500 characters, and `CleanupPrompt` fences it into both the cloud and local instruction blocks. On a cloud-cleanup mode it therefore leaves the machine on every dictation in that mode, exactly like the register hint that preceded it. Disclosed in the field's own caption ("Sent to the cloud model when this mode uses cloud cleanup"). Local-only and raw modes never transmit it. It is user-authored configuration rather than dictated content, but it is listed here because it is a per-dictation outbound string that did not exist before.
7. **`Sources/SkylarkCore/Cleanup/Llama/LlamaRunner.swift:456-467`** — llama.cpp's own native log callback is forwarded into the unified log, but only when the developer-only `SKYLARK_LLAMA_LOG` environment variable is set (every normal user/shipped run leaves it unset, and the default callback discards everything). Even when set, only `GGML_LOG_LEVEL_WARN`-and-above lines pass through, and the in-code comment argues those are config/state chatter rather than the "verbose levels" that "can echo prompt-derived text." That argument is plausible but not independently verified against llama.cpp's own source in this pass — the interpolated `String(cString: text)` originates inside a C library Skylark doesn't control, so it's the one log site in the sweep whose content isn't fully auditable from the Swift call site alone. Not a violation of the rule as shipped (off by default, not reachable by a normal user), but flagged so a future revision of this document — or a `SKYLARK_LLAMA_LOG` user — knows the guarantee here is "the code's belief about llama.cpp's behavior," not a verified content-free line.

No transcript or audio content was found in any log line, error path, or
persisted location outside the local GRDB `history` table's own
`raw_text`/`clean_text` columns, which are the intended local store per
ARCHITECTURE §5.
