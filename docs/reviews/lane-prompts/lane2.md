# Lane 2 — Can audio, transcript text, or the API key leave the machine, or land in a file the user never opted into?

You are GPT-5.6 Sol, auditing a codebase written, tested, reviewed, and
**already privacy-audited** almost entirely by Claude models. You are here
because you are a *different model family*.

The existing audit, `docs/privacy-audit.md`, concluded essentially clean. Treat
it as a **claim to falsify, not a baseline to trust** — it was written by the
same family that wrote the code, so anything it missed, it missed for the same
reason the code has it. It is also **stale**: it claims "exactly three categories
of outbound network access exist in `Sources/`," and since it was written the app
has gained an update checker, a diagnostics exporter, a local LLM download
manager, translation, statistics, and re-transcription. Check whether its central
claim is still true.

Calibrating exemplar from a prior run of this technique: a guard was well
written, unit tested, and documented — and wired into **zero of 46** paths that
needed it. Correct mechanism, absent wiring, tests that only exercised the
mechanism.

Skylark is a native macOS menu-bar dictation app (Swift 6.2, SwiftUI/AppKit,
SwiftPM). Read-only access. Findings only.

**Audit the checked-out working tree at HEAD.** Do not use `git show origin/main:`
or any other ref — remote-tracking refs in this clone may be stale, and a
previous run of this audit wasted itself reading a nine-day-old tree. Read files
from the working tree. Confirm and state the HEAD SHA in your report.

## The invariants, in the project's own words

`ARCHITECTURE.md` §7:

> 1. Local mode: zero network. Cloud calls only from `OpenRouterCloud` /
>    `OpenRouterCleaner`, only when selected.
> 2. No audio persisted unless history-audio opt-in; never leaves machine except
>    explicit cloud STT.
> 3. Clipboard byte-for-byte preserved across paste fallback.
> 4. No telemetry. No transcript content in logs.
> 5. Secrets only in Keychain.

`CLAUDE.md` hard rules:

> - Secrets only in the macOS Keychain. No keys, tokens, or user paths in the
>   repo or in UserDefaults.
> - Never log audio or transcript content.
> - Local mode must work fully offline; an optional stage failing never blocks
>   the core paste.

`Skylark_Dictation_PRD.md` §12: "no audio saved, no network, no telemetry in
local mode. Cloud calls only when a cloud engine or cloud cleanup is selected."
§8: "Audio retention OFF by default; if the user opts in, store audio locally
only."

## Your one question

**Given the user's actual selected configuration, is there any reachable path
where audio bytes, transcript text, or the OpenRouter key reach the network, a
log, an exported file, a crash report, or a location the user did not opt into?**

## Failure shapes to check explicitly

Report on each, even where the answer is "correct":

1. **`Sources/Skylark/DiagnosticsExporter.swift` and
   `Sources/SkylarkCore/Diagnostics/DiagnosticsReport.swift` — audit these
   hardest.** A diagnostics bundle is the classic transcript-leak vector: it is
   built to be *shared*, so anything it scoops up leaves the machine the moment
   the user emails it. Does it include history rows, raw or clean transcript
   text, dictionary phrases, snippets, file paths containing the user's name,
   the API key, retained audio, or unified-log lines that quote any of those?
   Where does it write, and what exactly is in it? Quote the assembly code.
2. **`Sources/SkylarkCore/Update/UpdateChecker.swift`.** This is outbound network
   traffic the existing privacy audit does not list at all. When does it fire —
   including in "local mode" and offline? What does it send (URL, headers,
   query, any identifier)? Is it a silent periodic beacon? Does it run without
   the user having asked? A version check that fires on a timer is telemetry
   under PRD §12's "no telemetry" whether or not it is labeled as such.
3. **"Local mode = zero network," tested by *reachability*, not by grep.** For
   every network-capable path, trace *what selects it*. Can a mode, a per-app
   mode rule, a preset, a fallback, a retry, a registry default, a quick-switch,
   a translation setting, or a stale persisted preference put the user on a
   cloud engine or cloud cleaner while the UI still reads local? Is the engine
   that *runs* always the engine the menu bar says is running?
4. **Model and asset downloads.** Parakeet, WhisperKit, and now Qwen GGUF files
   via `Sources/SkylarkCore/Cleanup/Llama/CleanupModelDownloader.swift`. Can a
   download fire when the user believes they are offline/local-only? Are the
   URLs pinned and integrity-checked, or could a registry value or a redirect
   point the downloader somewhere else? A GGUF is *executed* as model weights —
   what verifies it beyond size?
5. **Transitive network and vendored code.** `Vendor/llama.xcframework` is a
   prebuilt binary in the repo. Check `Package.swift`, `Package.resolved`, and
   the vendored framework's licensing (`Vendor/LICENSE-llama.cpp.txt`) against
   the MIT-repo hard rule. Do FluidAudio, WhisperKit, GRDB, or llama.cpp phone
   home, fetch remote config, or emit analytics on their own initiative?
6. **Logging.** Every `Logger`/`os_log`/`print`/`NSLog`/`debugPrint`/`assert`/
   `fatalError` site. Does any interpolate a transcript, a partial transcript, a
   live preview (`TranscriptPreview.swift`), a cleanup prompt containing the
   transcript, a dictionary phrase, a snippet, a command instruction, or audio?
   Check **error paths hardest**: a thrown error whose `localizedDescription`
   embeds the payload, a decoding error quoting the response body, any
   `String(describing:)` of a request or response.
7. **The API key.** Where does it live and for how long? Does it ever appear in a
   logged `URLRequest`, an error message, `String(describing:)`, SwiftUI
   `@State`/`@AppStorage`, `UserDefaults`, a crash log, `NSError.userInfo`, a URL
   query rather than a header, or **the diagnostics export**? Does a failed
   request echo the request back anywhere?
8. **Audio at rest.** Trace the clip's full lifetime. With retention OFF (the
   default): any temp file, cache, `WavEncoder` output, autosave, or
   library-internal scratch file? WhisperKit and llama.cpp may write their own
   temp files — check. With retention ON: are files inside the app's own support
   directory, deleted when the row is deleted, and honored by the retention
   window? `Sources/SkylarkCore/Transcription/Retranscription.swift` re-reads
   retained audio — can it re-send previously retained audio to the *cloud* on a
   later re-transcribe, after the user has switched engines? That would send
   audio the user recorded while in local mode.
9. **Stats and insights.** `Sources/SkylarkCore/Persistence/StatsStore.swift` and
   `Sources/Skylark/Settings/InsightsView.swift`. Is any of it aggregated,
   uploaded, or included in diagnostics? Local-only analytics is fine; verify it
   is local-only.
10. **Cloud request bodies.** When cloud STT, cloud cleanup, or translation *is*
    legitimately selected, is exactly the intended payload sent — no history
    rows, no dictionary contents, no prior transcripts as "context," no app names
    or bundle IDs, no user paths? Read the actual request construction. Note that
    field-context cleanup (`AXFieldContextReader.swift`) reads **surrounding text
    from the user's focused field** — does any of that text reach a cloud
    request? That would send content the user never dictated.

## Known and already queued — deeper or adjacent instances still wanted

Known: every OpenRouter request carries a static `HTTP-Referer` /
`X-OpenRouter-Title` identifying header. Don't re-file that. Any *other* outbound
identifier, or any user-specific value in any header, is wanted.

## Output contract — follow exactly

For each finding:
- **Claim** — one line.
- **Severity** — CRITICAL / HIGH / MEDIUM / LOW, graded by user harm.
- **Location** — `path/file.swift:line`.
- **Real code** — quote the actual lines from the working tree. No paraphrase.
- **Failure path** — the concrete sequence (configuration + user action + code
  steps) that produces the leak. If you cannot write it concretely, lower
  confidence or drop the finding.
- **Fix** — what you would change.
- **Confidence** — high / medium / low, honestly.

Then three whole-report sections:

- **SOUND** — which invariants you verified actually hold, and by what mechanism.
- **COVERAGE** — what you read, and what you could not reach (third-party
  internals, runtime behavior).
- **CORRECTIONS** — anything you revised or withdrew, including findings you
  nearly filed and rejected.

No hypotheticals. Every finding cites real code. **A short report is a good
outcome — do NOT pad.** If the invariants hold, say so and spend your words on
SOUND.
