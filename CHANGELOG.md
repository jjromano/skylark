# Changelog

All notable user-facing changes to Skylark. Versions follow
[semver](https://semver.org)-ish `MAJOR.MINOR.PATCH`: MINOR for new features,
PATCH for fixes/polish. Every release bumps `CFBundleShortVersionString` in
`Resources/Info.plist` — the version users see in Settings → Account, where
**Check for Updates** tells them a newer build is on GitHub.

## 0.17.0 - 2026-08-30

**Diagnostics can now say WHERE a slow dictation spent its time.**

- **The exported diagnostics report breaks each dictation into stages**: time in
  speech recognition, time waiting on cleanup, and time actually inserting the
  text, next to the total. Until now only the total was recorded, and the
  cleanup wait was quietly counted as part of the paste, so a cleanup that used
  up its whole time limit and then gave you the raw text back looked identical
  to a slow paste. That is the difference between "your speech engine is slow"
  and "your cleanup model never finishes", and the old report could not tell
  them apart.

- **The report now counts the dictations where cleanup made you wait and gave
  you nothing**, with the total time lost. If cleanup keeps hitting its time
  limit, that line says so in one number.

- **Log entries are no longer limited to the current app launch.** The report
  used to read only the running process's logs, so an export taken after a
  restart showed a couple of lines covering one dictation while the table above
  it listed dozens, with nothing to explain the gap. It now reads the wider
  system log where permitted, and when it cannot, it says so in the report
  instead of leaving you to guess.

  Existing history rows keep working; they show a dash in the new columns
  because their stage timings were never recorded.

## 0.16.1 - 2026-08-29

**Fix: saying "yes period" pasted the word "period".**

- Short dictations that end in spoken punctuation now reach the cleanup model
  like any other. In 0.16.0 a dictation of one or two words skipped the model
  entirely to save latency, which was right for "yes" but wrong for "yes
  period", "done exclamation mark" or "new line": the command word was pasted
  literally instead of becoming a mark or a line break. The skip now stands
  aside whenever the last word or two is a punctuation or layout command, so
  the feature added in 0.16.0 works at every length. A plain "yes" or "ok
  thanks" still skips the model and stays fast.

## 0.16.0 - 2026-08-29

**Pausing to think no longer ends your sentence, and you can say your
punctuation out loud.**

- **Thinking pauses stop turning into periods.** The speech recogniser marks
  every longer pause as a full stop, so "I want to... draft the document" came
  out as two sentences, and the local model then kept and multiplied those
  breaks. A deterministic repair now runs before cleanup on every tier except
  Raw: a period that lands after a word no sentence can end on ("to", "the",
  "and", "was"), or in front of a word that cannot open one ("which", "than"),
  is removed and the fragments rejoined. A break before "and", "but",
  "because" and similar is joined too, with a comma only when what follows is
  a complete clause ("I shipped it, but I am tired") and never when it is not
  ("ship the feature and then tell the team"). Real sentence ends, questions
  and exclamations are left alone. Raw mode stays byte-verbatim.
- **The cleanup prompts now re-punctuate instead of adding punctuation.** All
  three intensities on both the local and cloud tiers are told the
  transcript's punctuation is a pause-length guess, not grammar, and to
  rebuild it from meaning. The local prompt's "split run-ons into separate
  sentences" instruction, the direct cause of the local tier being worse, is
  gone, and the on-device examples now include pause-shredded input.
- **Spoken punctuation.** Say "exclamation mark", "question mark", "comma",
  "period" or "full stop", "colon", "semicolon", "dash", "open quote" /
  "close quote", "open paren" / "close paren" and the mark is written: "I
  love that exclamation mark" becomes "I love that!". The model only treats
  the word as a command where punctuation belongs, so "a period of rest" stays
  a phrase. Works at every intensity, including Light.
- **Stressing a word no longer gets you exclamation marks or CAPS.** The
  prompts forbid turning vocal emphasis into typography, and a repair pass
  enforces it: an exclamation mark the transcript did not contain and you did
  not say is downgraded to a period, a word the model upper-cased is put back
  to how it was spoken, and stray bold markers are stripped. Acronyms you
  actually said stay as they are.
- **One- or two-word dictations skip the model.** "yes" is capitalised and
  given a period on the spot instead of taking a full cleanup round trip, the
  slowest and most hallucination-prone case.
- **Hands-free dictation waits longer before stopping.** The pause that ends a
  double-tap hands-free session was a fixed 1 second; it is now 2 seconds by
  default and adjustable (1s / 2s / 3s) in Settings, General. Push-to-talk is
  unaffected.
- **Voice Command Mode is easier to find.** Its hotkey ships unassigned, so
  Settings now says what it does and that a key needs assigning.
- Clipboard snapshots respect a "never allow" pasteboard setting on newer
  macOS instead of forcing a read. FluidAudio updated to 0.15.6.

## 0.15.0 — 2026-08-01

**Per-mode custom instructions, and the build box can compile the app again.**

- **Settings → Modes → Custom instruction:** each mode can now carry your own
  standing instruction for cleanup, for example "keep bullet points on separate
  lines" for your notes app or "sign off with Thanks, JJ" for mail. It is
  *added* to the standard cleanup rules, never a replacement for them: the
  faithfulness guard still runs, so an instruction that rewrites too
  aggressively is rejected and your raw text stands. Capped at 500 characters
  with a live counter, and the caption says plainly that it is sent to the
  cloud model when that mode uses cloud cleanup. Modes without an instruction
  produce a byte-identical prompt to before, so cleanup quality is unchanged
  (eval baselines still 13/17 Apple, 15/17 Qwen 4B).

  This was the last open item in the PRD's Phase 2 backlog appendix.

- **Fixed: the app no longer builds on its own documented toolchain.** `main`
  had two `sending 'self' risks causing data races` errors that Swift 6.3
  accepts and the Swift 6.2.3 Command Line Tools reject, so the headless build
  box could not compile or test the app at all, on any commit. Both sites
  (audio device enumeration and the cloud speech-engine rebuild) now inherit
  main-actor isolation instead of sending `self` out of a detached task; the
  blocking CoreAudio and keychain reads still happen off the main actor, so
  behavior is unchanged.

## 0.14.0 — 2026-07-31

**Pre-1.0 batch: the recovered backlog, registry curation, and evidence
hygiene.**

- **Cleanup cycle hotkey** (PRD §7, the last undelivered v1 item): an optional
  shortcut (Settings → General) steps the active cleanup through Auto → Raw →
  Apple Intelligence → downloaded Qwen models → cloud models, naming each stop
  in the menu bar. Also fixed a bug found on the way: recording a Voice
  Command shortcut silently overwrote the dictation shortcut (since v0.9.0).
- **Per-mode Whisper Mode override:** each per-app mode can now follow the
  global Whisper Mode setting, force it on, or force it off.
- **Provider pinning is registry-aware.** Custom cleanup slugs are no longer
  force-pinned to Groq (a pin for a provider that may not serve the model);
  known slugs use their registry pin, unknown ones let OpenRouter route. The
  same fix applies to Voice Command Mode.
- **Model registry curated for the Groq backend retirement (2026-08-16):**
  Llama 3.1 8B is un-pinned (still served by other providers; slower),
  GPT-OSS 20B — the evaluated best — is now the first suggestion. Cloud STT
  rows verified live and unchanged.
- **Launch warms only your selected engine.** Deleting Parakeet while using
  another engine no longer triggers an unrequested 483 MB re-download at
  launch.
- **Command Mode discloses its cloud behavior** in Settings, matching the
  Dictionary pane: with cloud cleanup, the selection and instruction go to
  that model; with local cleanup they stay on the Mac.
- **Evidence hygiene:** the live cleanup eval now fails below its baselines;
  Keychain tests report locked-keychain runs as known issues instead of
  passing vacuously; the benchmark script fails on latency regressions
  against a recorded baseline; the release validation checklist was rewritten
  from scratch (23 sections, each with explicit pass/fail criteria) after the
  audit showed the old one could not detect the bugs it targeted; the privacy
  audit was re-swept end to end (91 log sites, 38 UserDefaults writers, zero
  content leaks).

## 0.13.0 — 2026-07-31

**P1 reliability and privacy release: every broken or blocked flow from the QA
remediation ledger.**

- **Your clipboard survives dictation.** The post-paste restore now checks
  whether another writer took the pasteboard and skips itself if so — copying
  something right after a dictation no longer loses it. A restore also never
  fires sooner than 120 ms after the paste, and a pasted transcript is only
  treated as landed when the target actually read it: pressing Return (the
  press-enter option) now waits for that confirmation instead of firing after
  a paste the target may have ignored.
- **Esc works after you release the key.** Cancel now extends through
  transcription and cleanup up to the instant text is written; after that a
  note says it was too late. Esc during recording is unchanged.
- **Hands-free mode actually ends when you stop talking — every time.**
  Auto-endpointing silently worked only for the first hands-free session per
  launch; every later one recorded until manually stopped. Fixed. The 120 s
  recording cap now finalizes the session honestly ("Reached the 2-minute
  recording limit — transcribed what fit") instead of silently discarding
  audio and then blaming the microphone, and the pill shows an amber countdown
  during the last 20 seconds.
- **Cloud cleanup no longer uploads your whole dictionary.** Only terms that
  approximate something you actually said are sent (none, when none match);
  local cleanup keeps the full list on-device. The Dictionary pane now says
  exactly this.
- **Dictating via skylark://record/start pastes into the right app** instead
  of into Skylark's own window (affects Shortcuts / Stream Deck workflows).
- **Command Mode can no longer overwrite a selection you made after starting
  it** — if the captured selection changed, nothing is written and a note says
  so.
- **A cleanup timeout of "Off" or "30 seconds" no longer blocks the first
  paste** — before anything is on screen the wait is capped at 10 seconds; the
  full setting still applies where raw text is already visible.
- **Switching STT engines is race-free.** A stale cloud rebuild can no longer
  land after you switched back to local (audio could have been uploaded while
  the menu read Local), and an engine switch no longer tears down a model
  mid-transcription — changes now apply at the next idle moment.
- **Qwen model downloads validate before replacing.** Downloads are pinned to
  an immutable revision, SHA-256-verified while staged, and swapped in
  atomically — a failed update leaves your working model untouched.
- **Two hands-free bugs the endpointing fix uncovered, also fixed:** the
  auto-stop's own finalize was being cancelled with the VAD task, so an
  endpointed session's transcription failed and the audio was dropped; and an
  auto-stopped session left the hotkey layer's double-tap lock behind, eating
  the next press. Both found and verified live.
- **Sturdier internals:** a failed microphone start no longer leaks the audio
  tap (and now says "Microphone capture failed"); the API key is read once and
  cached in memory instead of hitting the Keychain on every cloud request; the
  audio render thread no longer allocates or locks; VAD trimming keeps quiet
  speech near the cut points; the waveform animates at a steady 20 Hz; the
  Launch at Login toggle reflects reality; a dictation started while the
  previous one is still processing now says so instead of vanishing.

## 0.12.3 — 2026-07-31

**P0 reliability release: every corruption/crash finding from the 2026-07-30/31
QA passes, fixed and verified live.**

- **Deep vocabulary matching is fixed and back on by default.** The corruption
  shipped in v0.12.x came from FluidAudio's spotter-rescue pass, which bypasses
  the string-similarity gate and let a flat acoustic bonus replace unrelated
  words with dictionary terms ("The meeting starts" became "CLAUDE.md" at
  similarity 0.06). The rescue pass is now disabled for Skylark's short
  user-dictionary vocabularies (FluidAudio's own guidance for this case);
  misspelling aliases still correct as designed ("cloud.md" → "CLAUDE.md").
  Anyone the v0.12.2 kill switch turned off is re-enabled once, with a notice.
- **No more crash on launch when Accessibility is not granted.** The onboarding
  window died in an AppKit constraint feedback loop before it could walk you
  through granting permissions — likely the first-run path. The window is now
  fixed-size with scrolling content and survives every launch.
- **Revoking Accessibility while Skylark runs no longer wedges recording or
  your Mac.** Permission loss is now a first-class event: the session finalizes
  at the boundary (transcript saved to History), the mic is released, the HUD
  returns to idle, and notes name Accessibility and the Settings pane. The
  event-tap recovery loop checks the actual permission before calling a stall
  a stall, and gives up loudly after bounded retries instead of looping every
  60 s forever. A benign tap stall no longer eats the key release (the session
  now ends when you let go).
- **Text and Return can no longer land in the wrong window of the same app.**
  The focus guard now captures window identity (not just the app) and
  revalidates immediately before every write and again before pressing Return,
  so switching windows or apps during Processing safely aborts: text is kept
  in History and a note says so. Cross-app behavior (re-activating the
  original app) is unchanged.

## 0.12.2 — 2026-07-31

- **Safety release: deep vocabulary matching is forced off.** With the feature
  enabled, every cleaned dictation could have unrelated words replaced by
  dictionary terms (e.g. "The meeting starts at three" became "The meeting
  Claude"). The feature was already opt-in (default off); this release turns it
  off once for anyone who enabled it, with a notice. It will return, on by
  default, once the matcher is fixed and verified.

## 0.12.1 — 2026-07-27

- Fixed the new interruption handling clipping a still-holding user. A mid-hold
  event-tap timeout also fires on a benign main-run-loop stall (not only a real
  mic steal), and it was finalizing + pasting the utterance immediately — cutting
  off a user who was still speaking. A bare tap stall now just records the marker
  and keeps recording; the genuine-steal case (a silent/short tail) is still
  trimmed and flagged when the key is released. A failed engine restart still
  finalizes (nothing more will arrive).
- Added a **"Trim silence from recordings"** toggle (Settings → Audio) for the
  VAD clip trimming that shipped default-on — turn it off if it ever clips the
  start or end of your speech.

## 0.12.0 — 2026-07-25

**Injection correctness: your clipboard back sooner, your text never in the
wrong app.**

- **Read-signaled clipboard restore:** after a synthesized paste, your
  original clipboard is restored the moment the target app actually reads
  the transcript (plus a 100 ms grace for apps that read twice), instead of
  on a blind 500 ms timer. Fast apps get your clipboard back in tens of
  milliseconds; slow apps can no longer race the restore and paste your old
  clipboard by mistake. The 500 ms timer survives only as a ceiling for
  targets that never read. Transcripts stay marked transient/concealed for
  clipboard managers.
- **Focus guard:** the transcript belongs to the app that was frontmost when
  you started dictating. If focus moved by paste time (Cmd-Tab, a
  notification, a focus steal), Skylark re-activates that app and verifies
  it's frontmost before pasting — and if it can't, it aborts the paste
  (including any press-enter Return) with a note instead of typing into the
  wrong window. The text is kept in History. Voice commands get the same
  guard. No change and no added cost when focus never moved.

## 0.11.0 — 2026-07-25

**Local cleanup, upgraded: optional on-device Qwen models via llama.cpp.**
Apple Intelligence remains the default local cleanup engine; you can now
alternatively download and select a Qwen3 model that runs fully offline
through a bundled llama.cpp (MIT, ~6 MB) — no cloud, no Xcode toolchain,
Metal shaders compiled at runtime:

- **Settings → Models → "Cleanup · on device":** pick Apple Intelligence,
  Qwen3 1.7B (~1.0 GB) or Qwen3 4B Instruct (~2.3 GB), with in-app download
  (progress/cancel/resume, size-verified before install), delete, and
  switch-without-restart. Selection only sticks when the model is fully on
  disk; otherwise cleanup silently stays on Apple.
- **Quality:** on the internal cleanup corpus (M3 Air), Qwen3 4B matches
  15/17 vs Apple Intelligence's 13/17, at ~0.7 s per cleanup; Qwen3 1.7B is
  faster (~0.3 s) but weaker (7/17) — offered for lighter machines.
- **Memory-friendly:** model weights (~1–2.5 GB resident) unload after 5
  idle minutes and reload transparently on the next dictation; instructions
  stay cached between dictations (KV-prefix reuse) so a warm cleanup runs in
  a few hundred ms.
- Cleanup still never blocks the paste: timeouts, cancellation, and the
  degrade chain (local → raw) apply to Qwen exactly as before. Nothing from
  your dictations is ever written to logs.

## 0.10.0 — 2026-07-25

- **VAD trimming of finalized clips:** the already-resident Silero VAD now
  trims the quiet head and tail off every finalized recording (push-to-talk
  and hands-free) before transcription — less audio to decode means faster
  results, and Whisper models hallucinate less on leading/trailing silence.
  Measured cost ≈3.5 ms for a 5 s clip on the M3 Air; clips under 2 s are
  never scanned, the trim is skipped entirely if the VAD model isn't already
  loaded, and it can only ever shrink pauses — a clip VAD thinks is all
  silence is left untouched for the normal no-speech handling. Diagnostics
  kill switch: `defaults write com.jjromano.skylark vadClipTrimEnabled -bool
  false`.

## 0.9.0 — 2026-07-25

**Interruption-proof dictation.** When something steals the mic or input path
mid-utterance (another dictation app grabbing Fn, a macOS Fn action, an audio
device/route change, a stalled input tap), Skylark no longer loses everything
after the first few seconds to a silent tail — it detects the disruption,
keeps every word captured up to that boundary, and tells you the text may be
incomplete ("Mic interrupted — text may be incomplete"):

- **Audio route/device changes survive recording:** an engine configuration
  change mid-capture now restarts the engine while preserving everything
  already recorded; if the restart fails, the utterance is finalized at the
  boundary instead of recording silence.
- **Dead-tail trimming:** clips that are speech-then-nothing (a seized mic
  delivers no signal) are trimmed before transcription, so the words you did
  say come through instead of being dropped by the transcriber.
- **Stalled-tap detection:** when far fewer audio samples arrive than the
  hold lasted (mic seized with no silent tail at all), it's now treated as an
  interruption rather than silently producing a too-short clip.
- **Hotkey stalls finalize cleanly:** a mid-hold event-tap timeout (the stall
  that accompanies a focus/mic steal) finalizes the utterance at that boundary,
  and hands-free sessions no longer swallow the next press after an
  interruption.
- Applies to push-to-talk, hands-free, and voice-command mode alike; a clean
  recording passes through byte-identical with zero added latency.

## 0.8.2 — 2026-07-25

- **Settings warns about an Fn-key conflict:** if macOS itself has the Fn key
  assigned to a system action (Change Input Source, Emoji & Symbols, or
  Apple Dictation) while a Skylark hotkey is bound to Fn, the General pane now
  shows a warning with a shortcut to macOS Keyboard settings — the two can
  otherwise fight over the same key press.

## 0.8.1 — 2026-07-25

Robustness/latency quick wins from a comparison against peer dictation apps
(Hex, Handy, VoiceInk, OpenWhispr):

- **Fixed a correctness bug:** when an in-place cleanup replace failed (focus
  moved, or an Electron/Chrome/terminal app dropped the AX write), Skylark kept
  the raw text on screen but recorded the *cleaned* text in history — history
  now correctly reflects that raw was kept, and you're told.
- **Hotkey self-heals:** a 1s watchdog now re-enables the global-hotkey event tap
  if macOS silently disabled it (sleep/wake or a stall) without a callback —
  previously the hotkey could die with no recovery.
- **Lower paste latency:** the clipboard is now restored *after* the paste on a
  background task instead of blocking for 500ms on the injection path (which also
  delayed a spoken "press enter").
- Dictated transcripts are marked transient on the clipboard so clipboard
  managers don't capture them into their history.
- Synthesized Cmd+V now sets explicit modifier flags so a stray held key can't
  corrupt the paste chord.
- Capture logs a content-free warning when far fewer audio samples arrived than
  the hold lasted (input tap stalled — a possible mic interruption), visible in
  the diagnostics export.

## 0.8.0 — 2026-07-24

- New **Export Diagnostics…** button (Settings → Account → Diagnostics). Saves a
  single plain-text file — app version and build, machine/macOS/Apple
  Intelligence status, your current settings, a metadata table of recent
  dictations (per-dictation timestamps, app, engine, clip duration, raw/clean
  **word counts**, cleanup engine, and latency), and the last ~2 hours of
  content-free app logs — so you can hand it to a developer to debug a problem on
  a machine where you can't develop. **No audio and no transcript text are ever
  included** — only counts and timings. The report also flags likely
  cloud-cleanup truncation (clean words < half the raw words) and likely
  mic/silent-tail clips (very few words over a long recording).
- Added richer, content-free diagnostic logging: a per-dictation summary line
  (engine, clip duration, cleanup tier, the cleanup engine that actually ran,
  how the text was injected, and total latency) plus explicit lines when a cloud
  cleanup response is truncated or a cloud→local / timeout→raw degrade happens —
  all of which now surface in the exported diagnostics file.

## 0.7.10 — 2026-07-25

- Fixed cloud cleanup dropping most of a sentence — keeping only the first ~5-7
  words. The cleanup request's token cap was sized for the answer alone
  (`max(64, …)`), but gpt-oss are reasoning models that spend tokens *thinking*
  before answering, so the reasoning consumed the budget and the answer was
  truncated mid-sentence. The cap is now generous enough for reasoning + the full
  answer (it's a ceiling, not a target, so non-reasoning models still stop
  early). Also: a response the model cut off at the token limit
  (`finish_reason: length`) is now rejected and degrades to local cleanup instead
  of pasting half an answer. This primarily hit cloud reasoning models; raw text
  was always intact.

## 0.7.9 — 2026-07-24

- Cleanup no longer silently switches between cloud, local, and no-cleanup. When
  a cloud cleanup is **too slow**, it now falls back to the **local** engine
  instead of pasting raw (previously a slow cloud → no cleanup at all), and the
  formerly-silent timeout keeps now surface a note. Combined with the existing
  cloud→local degrade on errors, every fallback is visible instead of feeling
  random.
- Added a **Cleanup timeout** setting (Settings → General): 1–30 seconds, or
  "Off" to wait for cleanup with no cap. Raise it for a slow-but-preferred cloud
  model, or disable the cap entirely.

## 0.7.8 — 2026-07-24

- Fixed the Full History window's search field overlapping the list. It used
  `.searchable(.sidebar)`, which floats a translucent field over the sidebar so
  rows scroll behind it. Replaced it with a pinned search header (with a clear
  button) above the list, so the field and the rows occupy separate,
  non-overlapping regions.

## 0.7.7 — 2026-07-24

Cleanup-quality overhaul, informed by an eval against the real on-device model
and cleanup techniques from open-source dictation apps (OpenWhispr, Handy — MIT;
VoiceInk, nerd-dictation — GPL, ideas only). On-device exact-match rate on the
new cleanup corpus rose from 8/15 to 13/17.

- **Self-corrections now resolve reliably on the local model.** "I want to
  restructure, I mean refactor the code" now becomes "I want to refactor the
  code" (previously kept both). The local prompt gained a fuller replacement-cue
  list, an "'actually' used for emphasis is not a correction" carve-out, and
  worked examples — small models follow examples, not rule lists.
- **Cleanup no longer turns questions into commands or drops polite framing.**
  "Can you investigate what happened?" stayed a question instead of becoming
  "Investigate what happened." Both prompts now explicitly preserve sentence
  type, pronouns, and "can you"/"could you"/"please" (the cloud prompt had no
  such protection before).
- **Stopped a prompt example leaking into output** ("…because last time it
  broke" appearing on unrelated dictations), and added a deterministic output
  filter that strips reasoning/thinking blocks, a wrapping code fence, and
  leading "Output:"-style labels that small local models emit.
- **Added a deterministic spoken-number→digit/currency/percent pass** as a
  safety net after cleanup, so numbers the model leaves unformatted still come
  out right; idempotent, so correctly-formatted digits are untouched.
- Re-anchored the output contract immediately after the transcript in the user
  message, which improves instruction-following on small models.

## 0.7.6 — 2026-07-24

- Fixed cleanup silently keeping raw, unformatted text when the transcript
  contained spoken numbers — most visibly on the local (on-device) tier, e.g.
  "reserve an A ten G GPU" stayed "A ten G" instead of "A10G", and "one dollar
  and ninety nine cents" stayed spelled out instead of "$1.99". The
  faithfulness guard that protects against a dropped numbers-heavy clause
  (v0.7.1) counted spoken number "runs" and rejected any output with fewer than
  the raw — but legitimate number formatting reduces that count: currency
  collapses two spoken runs into one figure, and a spoken number fused into a
  word ("A ten G" → "A10G") wasn't recognized as a number at all. The model's
  correctly-formatted output was thrown away and raw kept. The guard now fires
  only when every spoken number vanishes (the genuine dropped-amount case),
  and any digit-bearing token counts as a number. Cloud output was unaffected
  only because its speech-to-text already emits digits. Added regression tests
  for both cases.

## 0.7.5 — 2026-07-24

- Fixed press-and-hold dictation clipping a sentence mid-hold ("captured the
  first part, the rest vanished"). When the OS momentarily disabled the event
  tap (e.g. a main-run-loop hitch during recording), Skylark re-read whether the
  Fn/globe trigger was still held using only the secondary-Fn device flag —
  which reads 0 unreliably while the key is physically held — and would
  synthesize a false key-up, finalizing the utterance while the user was still
  holding the key. Reconcile now treats a modifier trigger as released only when
  BOTH the device flag and the physical key state agree it is up, biasing toward
  "still held" so a flag misread can no longer truncate an active hold. Added
  hotkey diagnostics (tap-disable reason, reconcile flag/key reads, synthetic
  key-ups) to the `hotkey` log category. Note: if the macOS "Press 🌐 key to"
  setting is not "Do Nothing", macOS acts on the Fn key below Skylark's tap and
  can steal focus/mic mid-hold — set it to Do Nothing for reliable Fn dictation.

## 0.7.4 — 2026-07-23

- Fixed a regression in 0.7.3's installer: after updating, Skylark did not
  relaunch and disappeared from Launchpad, Spotlight and the Applications
  folder until macOS re-scanned `/Applications` on its own. The installer had
  been unregistering the `dist/` build copy and then garbage-collecting the
  whole Launch Services database — and because both bundles share one bundle
  ID, that briefly left the app with no registration at all, so there was
  nothing for the relaunch to open. The app itself was always installed
  correctly on disk; only its registration was missing. The installer now
  explicitly registers the installed copy before launching it (no
  database-wide garbage collection), and reports a failed launch instead of
  exiting silently.
- The duplicate-Launchpad-icon cleanup from 0.7.3 now actually holds: rather
  than trying to unregister the `dist/` build copy — which macOS kept
  re-registering as long as the signed bundle sat on disk — the installer now
  deletes that redundant copy after installing to `/Applications`. `make app`
  and `make run` rebuild it on demand, so nothing is lost.

## 0.7.3 — 2026-07-23

- **Update Now actually gives you the new build.** The installer now quits the
  running Skylark before overwriting it and relaunches afterwards, so an update
  no longer finishes with the *old* version still running and no sign anything
  was wrong. If Skylark can't be quit, the installer stops with instructions
  instead of overwriting a running app.
- The installer prints the version and build number of the Skylark it just
  launched, so you can confirm the update took.
- **No more duplicate Skylark icon** in Launchpad and Spotlight. The build
  artifact under `dist/` is kept out of Spotlight's index and unregistered from
  Launch Services after it's copied to `/Applications`, instead of being listed
  as a second copy of the app after every build.

## 0.7.3 — 2026-07-23

- Fixed: the Settings → Dictionary checkboxes ("Learn words from your
  corrections", and by the same defect the History retention controls and
  the auto-learn-from-history toggle) wrote their value but never redrew —
  appearing dead, stuck, or seemingly toggled by a neighboring control.
  Five settings were rebuilt on the observable pattern; a repo rule now
  guards against this class recurring.
- Fixed: opening Settings could hang the entire app — the window's cloud
  warning read the Keychain on the main thread while a background Keychain
  read held the same lock. Key presence is now cached off-main; no UI code
  touches the Keychain anymore. (This also made skylark://settings reliable
  on cold launch.)

## 0.7.2 — 2026-07-22

- Removed **Llama 3.3 70B (Groq)** from the cloud cleanup catalog (Groq
  retires it 2026-08-16; GPT-OSS 120B is its successor). Retired catalog
  entries now disappear from menus on the next launch after an update; a
  model you added yourself is never removed, and an in-use retired model
  keeps working until you pick another.

## 0.7.1 — 2026-07-22

Hardening from the post-wave audit (adversarially reviewed and verified):

- Cleanup can no longer silently lose numbers: a dictated amount that a
  cleanup model drops now rejects the cleanup and keeps your raw words —
  at every tier, cloud included.
- Long local cleanups are now bounded and cancellable; translation always
  runs whole (never chunked), so long translated dictations can't come out
  mixed-language; chunk seams no longer lowercase proper nouns.
- Voice commands now fall back to the on-device model when the cloud is
  unreachable ("Cloud unavailable — used on-device model") instead of
  failing.
- One less audio-thread allocation when hands-free and live preview run
  together.

## 0.7.0 — 2026-07-22

A large feature wave. Everything new that watches, stores, or sends anything
is **off by default**.

- **Voice command mode**: bind a second shortcut (Settings → General), hold
  it, and speak an instruction — "make this shorter", "translate to
  Spanish" — to rewrite the selected text in place (or generate text at the
  cursor). Uses your cleanup model; the pill turns blue while listening.
- **Cleanup intensity** (Light / Standard / High): control how much the
  cleanup stage edits. Light = punctuation, capitalization, and numbers
  only; High adds gentle grammar smoothing. Standard is unchanged.
- **On-screen context** (opt-in): cleanup can read the text around your
  cursor so mid-sentence dictation continues naturally and names already in
  the field keep their spelling.
- **Translation mode** (opt-in): dictate in one language, paste in another
  (9 languages). Cloud models translate best; on-device handles European
  languages, and a failed translation falls back to your original words.
- **Deep vocabulary matching** (opt-in): a second on-device acoustic pass
  re-checks each dictation against your dictionary so names are recognized
  as spoken, not just fixed afterward (~100 MB helper model download).
- **Learned-word banner**: auto-learned dictionary words now announce
  themselves under the recording pill with an Undo button (5 s).
- **Keep audio & re-transcribe** (opt-in): retain dictation audio locally
  (7/30/90 days) to replay or re-run any history entry through a different
  engine.
- **Live preview** (experimental, opt-in, Parakeet): see words appear in
  the pill while you speak; the pasted text is untouched.
- **Per-app style presets**: one-click suggested modes (casual chat,
  polished mail, verbatim terminals/editors, notes, and more) in
  Settings → Modes.
- **`skylark://` automation**: `skylark://record/start|stop|toggle|cancel`
  and `skylark://settings` for Raycast/Shortcuts/Stream Deck.
- **No more silent-clip hallucinations**: a push-to-talk clip with no
  detectable speech shows "No speech detected" instead of pasting whatever
  the model imagined.
- **Whisper Mode** now adaptively normalizes very quiet clips (up to ×8)
  before transcription, so near-silent whispering transcribes reliably.

## 0.6.1 — 2026-07-22

- Local cleanup, tuned against the real on-device model: spoken numbers are
  now written as numerals and symbols ("ninety nine point nine percent" →
  "99.9%"), polite framing ("can you please…") is never compressed away,
  self-corrections resolve cleanly, long unpunctuated dictation is split
  into proper sentences, and prose narration ("first… then… finally…") is
  no longer misformatted as a list. Verified live on an M3 Air across a
  12-case acceptance matrix, three runs each.

## 0.6.0 — 2026-07-22

- New (opt-in, off by default): **learn words from your corrections**. When
  enabled in Settings → Dictionary, if you fix a word Skylark misheard right
  after a dictation (in the field it typed into), the correction is added to
  your dictionary automatically — with a transient menu-bar note and an
  "Auto" badge on learned entries. Entirely on-device: Skylark re-checks the
  field it wrote into twice within ~25 seconds via Accessibility, learns at
  most two distinctive words per dictation, never watches password fields or
  password managers, and stores nothing but the corrected word pair.

## 0.5.0 — 2026-07-22

- New local speech engine: **Apple Speech (macOS)** — Apple's on-device
  SpeechAnalyzer. Fully offline, near-zero memory in Skylark (the model runs
  in a system process), natively punctuated and capitalized output, ~30+
  languages. Measured on an M3 Air: final text ~170 ms after end of speech
  (Parakeet: ~80 ms; both well inside the 300 ms budget). Its model is a
  shared system asset — Settings → Models shows install state and download.
  Great fit when Apple Intelligence is off or punctuation-without-cleanup
  matters.
- `skylark-bench --compare` runs the same audio through Parakeet and Apple
  Speech side by side.

## 0.4.0 — 2026-07-22

- Local (Apple Intelligence) cleanup is far more faithful to what you said:
  deterministic decoding, a compact example-led prompt built for the small
  on-device model, and much stricter guards that reject any output which
  drops or rewords your content (falling back to the raw transcript). Long
  dictations are now cleaned in sentence-sized windows instead of being
  skipped entirely when they exceeded the model's context.
- FluidAudio updated to 0.15.5 (verified: existing downloaded Parakeet
  models keep working, no redownload).
- Settings → Models now correctly reports the Parakeet and voice-activity
  models as installed (it was checking the wrong folder names and showing
  them as missing).

## 0.3.1 — 2026-07-22

- Faster cloud cleanup with GPT-OSS models: requests now ask for low
  reasoning effort, cutting several seconds of hidden "thinking" before the
  cleaned text starts streaming.
- New installs default to **GPT-OSS 20B (Groq)** for cloud cleanup (Groq
  retires the previous Llama default on 2026-08-16). Existing selections are
  unchanged.

## 0.3.0 — 2026-07-22

- New cloud STT choices in the model registry: **Deepgram Nova-3**
  (fast, strong real-world accuracy, ≈$1.30/mo at 5 hrs), **MAI Transcribe
  1.5** (Microsoft — current independent accuracy leader, ≈$1.80/mo), and
  **Voxtral Mini Transcribe** (Mistral — near-leader accuracy at ≈$0.90/mo).
  All single-provider on OpenRouter, no pin needed.
- New cloud cleanup choice: **GPT-OSS 120B (Groq)** — Groq's recommended
  successor to Llama 3.3 70B (which Groq deprecates 2026-08-16 along with
  Llama 3.1 8B; both remain listed for now and fall back to other providers
  after that date).

## 0.2.2 — 2026-07-22

- Fixed: choosing "Apple Intelligence (Local)" in Settings → General's
  "Cleanup model" picker no longer snaps back to the previous selection — the
  picker's underlying state wasn't observable, so SwiftUI never redrew it
  after the choice took effect. The "Default cleanup tier" picker now visibly
  follows suit when a model choice implicitly switches tiers, with a brief
  note confirming the switch.

## 0.2.1 — 2026-07-11

- Cleanup faithfulness: the transcript is now fenced and the model is told it
  is data, never instructions — so a dictated command ("please rewrite this…")
  is cleaned verbatim instead of being answered. Shared output hygiene (local +
  cloud) now rejects chatbot meta-commentary ("Sure, here's the cleaned
  version:", "should be rewritten as…") and, critically, refuses any cleanup
  that drops a negation present in the raw text ("I can't see" never becomes
  "I can see"); rejected output falls back to the faithful raw transcript.
- History window opens correctly: it's now resizable and always shows the list
  and detail panes instead of collapsing to just the search box. Selecting a
  different entry now also refreshes the editable "Final text" field, which
  previously stayed stuck on the first entry viewed.

## 0.2.0 — 2026-07-09

- Cleanup now formats explicitly dictated structure: spoken enumerations
  ("one, bananas. Two, apples…") become numbered/bulleted lists on separate
  lines, and "new line" / "new paragraph" work as layout commands. Numbers
  inside ordinary sentences are left alone.

## 0.1.0 — 2026-07-09

First complete release.

- Push-to-talk dictation (hold / double-tap-lock hands-free / Esc cancel)
  with on-device Parakeet or Whisper, optional OpenRouter cloud STT.
- Configurable dictation shortcut (Fn default, right-side modifiers, F13–F19)
  plus an optional mouse trigger.
- Three-tier cleanup (Raw / local Apple Intelligence / cloud) with per-app
  Modes, register hints, and a global override.
- Dictionary (correct spellings + misspellings, auto-learned from history
  edits), Snippets (spoken triggers), spoken "press enter" command.
- Insights: words dictated, WPM, time saved, streaks, per-app usage,
  12-week activity heatmap.
- History with search, editing, retention windows, opt-in local audio.
- Notch HUD (Standard / Minimal / Hidden), start/stop sound cues with
  volume, optional music auto-pause while dictating.
- Settings → Account: version + build info, Check for Updates → one-click
  `git pull` + reinstall.
