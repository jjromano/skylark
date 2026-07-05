# Skylark privacy audit — Sources sweep

Read-only audit of `Sources/` against the invariants in `ARCHITECTURE.md` §7
and `CLAUDE.md`'s hard rules. This document does not modify `Sources/` or
`Tests/`; anything questionable is listed under Findings for the code owner
to fix, not fixed here.

Scope: every network call, every `logger`/`Logger` call site, Keychain vs.
other secret storage, and the clipboard snapshot/restore path.

## 1. Network touchpoints

Exactly three categories of outbound network access exist in `Sources/`,
matching the design intent. No other `URLSession`, socket, or shell-out to
`curl`/`Process` for networking was found anywhere in the tree.

| # | Call site | Trigger | Data sent |
|---|---|---|---|
| Cloud STT | `OpenRouterClient.transcribe` (`Sources/SkylarkCore/Network/OpenRouterClient.swift:71`), invoked from `OpenRouterCloud` (`Sources/SkylarkCore/Transcription/OpenRouterCloud.swift:31`) | User has selected a cloud entry under menu bar → Speech Engine and dictates | The recorded audio clip, WAV-encoded and base64-inlined in the JSON body (`OpenRouterClient.swift:80`), to `POST /api/v1/audio/transcriptions` |
| Cloud cleanup | `OpenRouterClient.complete` (`OpenRouterClient.swift:101`), invoked from `OpenRouterCleaner` (`Sources/SkylarkCore/Cleanup/OpenRouterCleaner.swift:31`) | Menu bar → Cleanup is set to Cloud | The raw transcript text only (no audio) as a chat message, to `POST /api/v1/chat/completions` |
| Key validation | `OpenRouterClient.validateKey` (`OpenRouterClient.swift:181`), invoked from `APIKeyCard.save()` (`Sources/Skylark/APIKeyEntry.swift:52`) | User saves a key in onboarding or Settings | Only the Bearer key in the request header, to `GET /api/v1/key` |
| Model download (Parakeet) | `AsrModels.downloadAndLoad` (`Sources/SkylarkCore/Transcription/FluidAudioParakeet.swift:83`) | First local-engine warm-up if the Parakeet model isn't already on disk (`AppController.swift:239,559`) | Model weight files from Hugging Face only — no audio, no transcript |
| Model download (Whisper) | `WhisperKit.download` (`Sources/SkylarkCore/Transcription/WhisperKitWhisper.swift:88`) | First WhisperKit warm-up if the large-v3-turbo checkpoint isn't already on disk (`AppController.swift:565`) | Model checkpoint files only. `downloadBase` is overridden to `ModelPaths.whisperKitBase` (`WhisperKitWhisper.swift:44`) instead of WhisperKit's default `Documents/huggingface`, per the ARCHITECTURE §6 note |

Every request also carries a static `HTTP-Referer: https://github.com/jjromano/skylark` and `X-OpenRouter-Title: Skylark` header (`OpenRouterClient.swift:212-213`) — an identifying header on every cloud call, not a secret leak, but listed under Findings for visibility.

## 2. Disk/log writes of audio or transcript content

All 28 `logger.`/`Logger(` call sites in `Sources/` were inspected. **None
interpolate transcript text or raw audio samples.** Every content-bearing
value logged is metadata — durations, sample *counts* (not the samples
array), `OSStatus` codes, or `error.localizedDescription` on error enums
whose associated values are themselves content-free (e.g. `ParakeetError`,
`WhisperKitError`, `OpenRouterError`, `CleanerError.reason` — always a
static string like `"No OpenRouter API key"`, never the transcript,
`KeychainError`, `InjectionError`). `DictationOrchestrator.swift:319`
carries an explicit `// Never logs transcript content.` comment next to the
history-emission code.

Representative sites: `DictationOrchestrator.swift:164,172,236,358,437,498`;
`FluidAudioParakeet.swift:108`; `WhisperKitWhisper.swift:112`;
`AudioCaptureService.swift:126,130,179,193` (line 126 logs a sample *count*,
an `Int`, never the sample buffer); `AudioDeviceManager.swift:90`;
`SpeechEndpointer.swift:57,60,90`; `TextInjector.swift:262` (a static
notice string, the pasted `text` is never interpolated);
`HotkeyMonitor.swift:71,106,120`.

**History persistence.** `HistoryStore` (`Sources/SkylarkCore/Persistence/HistoryStore.swift`) is a GRDB actor over the local `history` table, opened by `SkylarkDatabase` (`Sources/SkylarkCore/Persistence/SkylarkDatabase.swift:80`) at `~/Library/Application Support/Skylark/skylark.sqlite` — local file, WAL mode, no sync/cloud path anywhere in the codebase. Schema matches ARCHITECTURE §5, including a nullable `audio_path` column.

**Audio retention default.** The PRD/ARCHITECTURE describe audio retention
as opt-in and off by default. In this build it is stronger than that: the
opt-in toggle **does not exist yet**. The only call site that constructs a
`HistoryRecord`, `DictationOrchestrator.emitHistory` (`Sources/SkylarkCore/Pipeline/DictationOrchestrator.swift:328-337`), hardcodes `audioPath: nil`.
There is no settings flag, `UserDefaults` key, or Settings UI toggle for
history-audio anywhere in `Sources/` (grep for
`audioPath|audio_path|historyAudio|saveAudio|retainAudio` outside the
schema/model declarations returns nothing). Net effect: audio is never
written to disk in this build, full stop — stricter than the spec's
"off by default," but worth flagging since the opt-in feature described in
the PRD isn't implemented, so a user who wants audio retention has no way
to turn it on yet.

## 3. Keychain-only secrets

`KeychainStore` (`Sources/SkylarkCore/Credentials/KeychainStore.swift`) is a
generic-password Keychain item — service `com.jjromano.skylark`, account
`openrouter-api-key`, `kSecAttrAccessibleWhenUnlocked` (`:18-19,82`).
`get()`/`getStrict()` never fall back to any other store; `set()`/`delete()`
touch only the Keychain.

`APIKeyCard` (`Sources/Skylark/APIKeyEntry.swift`) is the sole UI reader/writer:
`save()` (`:45-62`) writes via `KeychainStore().set(entered)` then
immediately clears the view's `@State private var key` (`:60`, commented
"never keep the key in view state"). Its error-mapping helper
(`friendly(error:)`, `:82-90`) returns static strings only — the key or raw
error text is never surfaced.

`UserDefaults` usage elsewhere (`AppController.swift:123,124,389,394,512,622,624`, `ModelSelection.swift`) is confined to non-secret preferences — Whisper Mode toggle, input-device UID, cleanup-tier override, model
selection. No overlap was found between those keys and the API key.
No plain-file writes of the key exist; the only other `FileManager` disk
writes in `Sources/` are `SkylarkBench` reading benchmark `.wav` fixtures,
unrelated to credentials.

## 4. Clipboard behavior

`PasteboardSnapshot` (`Sources/SkylarkCore/Injection/PasteboardSnapshot.swift:18-30`) snapshots **every** pasteboard item and **every** UTI type on each item as raw `Data` (not just the string type), and `restore(to:)` (`:32-45`) clears and rewrites every item/type from that snapshot — matching PRD §10's "full multi-item snapshot, all types."

The paste path in `TextInjector.performClipboardPaste` (`Sources/SkylarkCore/Injection/TextInjector.swift:236-262`): snapshot → clear + write the transcript string → poll `changeCount` (5 ms interval, 150 ms cap) → synthesize Cmd-V → on success, sleep a 500 ms grace period, then restore the snapshot.

On the **failure** branch (synthesized paste didn't go through, `:260-262`), the snapshot is deliberately **not** restored — the transcript is left on the clipboard as the user's manual-paste fallback instead, per the in-code comment "Leave the text on the clipboard as the user's fallback (do NOT restore)." This is intentional and matches ARCHITECTURE §3's injection strategy ("If the paste itself fails, leave the text on the clipboard as the user's fallback"), but it means the "byte-for-byte clipboard restore" guarantee holds only on the success path — see Findings.

## 5. Findings

Reported for visibility; none require a source change beyond what the code
already documents as intentional.

1. **`Sources/SkylarkCore/Injection/TextInjector.swift:260-262`** — when a synthesized paste fails, the pre-dictation clipboard snapshot is discarded rather than restored; the user's prior clipboard contents are lost in that branch (the transcript replaces them until the user's next copy). This is a deliberate, commented tradeoff (better to leave usable text than silently drop it), but it's the one path where "clipboard preserved" doesn't hold.
2. **`Sources/SkylarkCore/Network/OpenRouterClient.swift:212-213`** — every OpenRouter request sends a static `HTTP-Referer`/`X-OpenRouter-Title` identifying header. No secret or user data in it, but it is an outbound identifier present on every cloud call, worth knowing about.
3. **Audio-retention opt-in is unimplemented** (see §2) — not a privacy violation (the stricter state — no audio ever persists — currently holds), but the PRD's "off by default, opt-in available" feature has no toggle in this build; a future implementer should not assume the setting exists.

No transcript or audio content was found in any log line, error path, or
persisted location outside the local GRDB `history` table's own
`raw_text`/`clean_text` columns, which are the intended local store per
ARCHITECTURE §5.
