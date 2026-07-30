# Skylark live QA handoff (Claude Cowork, computer use)

**You are the live-driver half of a two-track audit.** The other half is a static
code audit by GPT-5.6 Sol reading the source. The two tracks find *disjoint*
defect classes, so do not try to reason about the code. Drive the app and report
what you observe.

The most valuable thing you can produce is a defect that is invisible in source:
a screen whose numbers are wrong, text landing in the wrong window, a state the
app cannot get out of, something that feels broken even though every line of code
does exactly what it says.

**Build under test:** `main` at `c1691f7`, version **0.12.1**. Confirm the
version in Settings before you start. If the installed app is older, run
`./Scripts/install.sh` from a fresh clone first, and say in your report which
version you actually tested.

---

## 1. Where to run this, and what you may break

**Run on the MacBook Air (M3, 16 GB, macOS 26), where Skylark is installed.**
This is not optional. Skylark needs a real microphone, real keystrokes, a screen
with a notch, and TCC permission grants. The Mac Mini build box is headless, has
no microphone, and has Apple Intelligence off, so it cannot exercise any of this.

**You have free rein over the Air's Skylark installation.** All of the following
are yours to change, break, wipe, and restore:

- Settings, modes, mode presets, custom dictionary, snippets, and history
- Downloaded models in `~/Library/Application Support/Skylark/` (Parakeet,
  Whisper, Qwen GGUF files)
- The Keychain entry (`com.jjromano.skylark` / `openrouter-api-key`)
- TCC grants. You may revoke and re-grant Microphone, Accessibility, and Input
  Monitoring to test what the app does when a permission disappears
- The system clipboard
- Any scratch document, TextEdit window, Terminal tab, or browser tab you create

A read-only pass would be worthless here. The highest-value defects live in
states you have to *create*: a half-downloaded model, a revoked permission, a
disconnected microphone, a cancelled dictation, a cold local LLM. Go create them.

### The three lines not to cross

1. **Do not dictate into anything that sends.** No Messages, Mail compose, Slack,
   or any field with a submit action that reaches another person. This matters
   more than usual here, because Skylark can synthesize a **Return keystroke**
   (the "press enter" voice command). Use scratch documents, TextEdit, Terminal,
   and local text fields. If you must test a web form, use a draft you will
   discard and never submit it.
2. **Do not print or exfiltrate the OpenRouter API key.** You will be handling a
   real key. Refer to it by name and shape only. If you find it exposed anywhere
   it should not be (a log, an error message, a diagnostics export, a screenshot),
   that is a CRITICAL finding: capture *where* it appeared and redact the value.
3. **Do not modify the repository or push anything.** Report findings; fixing
   happens elsewhere.

Everything else is fair game.

---

## 2. What this app is, and who actually uses it

Skylark is a personal, open-source, MIT-licensed macOS menu-bar dictation app.
You hold the **Fn (Globe) key**, speak, release, and text appears at your cursor
in whatever app you were typing in. It runs fully on-device by default, with
optional cloud speech-to-text and cloud cleanup via OpenRouter. There is no Dock
icon and no main window: the mic glyph in the menu bar plus a small floating pill
under the notch is the entire GUI.

What has shipped, so you know the surface area (much of it is newer than any
written test plan):

- **Dictation:** push-to-talk on hold, hands-free on double-tap with VAD
  endpointing, Whisper Mode for quiet speech
- **Speech engines:** local Parakeet (default), local Whisper via WhisperKit,
  Apple SpeechAnalyzer, and two cloud STT models
- **Cleanup tiers:** raw, Apple Intelligence on-device (default), on-device Qwen3
  1.7B/4B via a bundled llama.cpp, and cloud models via OpenRouter, with a
  configurable timeout and a visible degrade chain
- **Injection:** direct Accessibility insertion, with a clipboard-preserving
  synthesized-paste fallback, a focus guard, and read-signaled clipboard restore
- **Command Mode:** select text, speak an instruction, and Skylark rewrites the
  selection in place
- **Personalization:** custom dictionary with auto-learn from your corrections,
  deep vocabulary rescoring, snippets, app-aware modes and presets, translation
- **Other:** searchable history with optional audio retention and
  re-transcription, insights/stats, Export Diagnostics, Check for Updates

**Two real users, and they are not the same person:**

- **JJ**, technical, the author, on this MacBook Air M3. He compares Skylark
  head-to-head against Wispr Flow on his own phrases. If Skylark feels slower,
  the product has failed regardless of what any benchmark says.
- **Stephanie**, **non-technical**, on her own MacBook Pro, with her own Keychain
  entry and her own model downloads, building from source. She has never seen
  this codebase. Every error message, empty state, and permission prompt has to
  make sense to her with no context. **Grade confusing states as her, not as an
  engineer.** "I pressed the key and nothing happened" is a serious defect even
  when the underlying behavior is technically correct.

**How it is meant to be used:** all day, dozens of times an hour, in the middle
of other work. It is not a thing you open; it is a thing that has to already be
working. That is why silent failure is the worst defect class here. A user who
cannot tell "it didn't hear me" from "it's broken" stops trusting it entirely.

---

## 3. The product's own quality bar. Grade findings against this.

Quoted from `Skylark_Dictation_PRD.md` §12 and §1:

> **Latency targets (local, short utterance):** end-of-speech to pasted raw text
> under 300ms; streaming interim tokens under 150ms where implemented. This is
> the acceptance bar for "as snappy as Wispr Flow."
>
> **Memory:** comfortable headroom on a 16GB machine running the user's normal
> workload.
>
> **Offline:** local mode plus Tier 0/Tier 1 cleanup must work with the network
> disabled.
>
> **Privacy defaults:** no audio saved, no network, no telemetry in local mode.
> Cloud calls only when a cloud engine or cloud cleanup is selected. Clipboard
> left intact.
>
> **Reliability:** if any optional stage fails, the user still gets usable text.
> An optional feature never blocks the core paste.

And the guiding principle:

> **Latency is the product.** Every architectural decision is judged first by the
> time between "I stop speaking" and "clean text appears at my cursor."

From §10, an explicit hard requirement:

> The app must insert text without disturbing the user's clipboard [...] snapshot
> the full `NSPasteboard` contents (all types and items, not just plain string),
> perform the paste, then restore the original contents after the paste
> completes.

The menu bar shows a **"Last: N ms"** readout after each dictation. That is the
latency number. Record real values and report a median, never a single sample.

---

## 4. Seed these awkward states deliberately

**Do not spend the session on the happy path.** Clean, well-formed state finds
nothing. Create each state below, then dictate into it.

| State to create | How | What you are hunting |
|---|---|---|
| **Fresh install, no models** | Quit Skylark, `rm -rf ~/Library/Application\ Support/Skylark/Models`, relaunch, immediately press Fn and speak | Does it tell you the model is not ready, or silently eat the sentence? |
| **Mid-download** | Same, but dictate repeatedly *while* the 483 MB Parakeet download runs | Progress accuracy, whether dictation queues, drops, or errors; whether the download survives |
| **Cold local LLM** | Select Qwen3 4B cleanup, leave the app idle 6+ minutes (weights unload after 5), then dictate | Cleanup has to reload 2.3 GB. How long until the cleaned text swaps in, and what happens if you keep typing during it? |
| **Qwen mid-download / cancelled / deleted** | Start a Qwen download, cancel it, delete it, select it anyway | Selection should only stick when fully on disk; verify it silently stays on Apple instead |
| **Empty history** | Clear History, open the History window | Does the empty state read like a product or like a bug? |
| **Large history** | Dictate 30+ utterances, then search | Search correctness, scroll, responsiveness |
| **No API key** | Delete the key, select a cloud engine and cloud cleanup | Falls back to local with a notice, or hangs, fails silently, or crashes? |
| **Invalid API key** | Enter a well-formed but wrong key | Is the error something Stephanie can act on? |
| **Offline with cloud selected** | Cloud STT plus cloud cleanup, turn Wi-Fi off, dictate | PRD promises transparent local fallback with a notice and nothing hanging. Time it. |
| **Network dies mid-request** | Cloud cleanup selected, disconnect Wi-Fi *during* the cleanup call | Does the raw paste survive? Does the replace ever fire, or clobber something later? |
| **Apple Intelligence OFF** | System Settings, Apple Intelligence and Siri, off; cleanup set to local Apple | Dictation must still work, raw text stands, no errors shown |
| **Bluetooth mic** | Connect AirPods, select them in Settings, Audio | HFP quality warning must appear; dictation must still work |
| **Device yanked mid-utterance** | Start dictating on AirPods, disconnect them while speaking | This is the interruption model, rewritten twice in the last three days. Expect "Mic interrupted, text may be incomplete". Check whether the words you spoke before the yank survived. |
| **Mic stolen mid-hold** | Start another dictation app, or trigger a macOS Fn action, while holding Fn | Same interruption model. v0.12.1 fixed this cutting off a still-speaking user. Verify it no longer does, and that a real steal is still caught. |
| **Rich clipboard** | Copy an image from Preview, rich text from Safari, and **a file from Finder** (file promises are the hard case), then dictate into a paste-fallback app such as Terminal | Afterward Cmd-V somewhere and confirm the *original* came back intact. A plain-string check proves nothing. |
| **Clipboard manager running** | If one is available, run it during dictations | Transcripts are marked transient. Verify they do not enter its history, and that its reads do not trigger an early clipboard restore |
| **Permission revoked while running** | With Skylark running, revoke Accessibility or Input Monitoring | Does the hotkey silently stop working with no indication? To a user that presents as "the app is dead." |
| **Sleep/wake** | Close the lid mid-dictation, and separately leave it asleep an hour, then dictate | The event tap has a liveness watchdog. Verify it actually recovers. |
| **Dictionary collision** | Add dictionary entries that overlap or substring one another | Wrong-replacement behavior |
| **Trim silence toggle** | Settings, Audio, "Trim silence from recordings" on (default) then off, with a long mid-sentence pause and a quiet trailing clause | VAD trimming can only shrink pauses, but a soft final word is the risk. Compare transcripts with it on and off. |

If a state is impossible to create for a reason you can name, put it under "could
not test". That list is planning input, not a disclaimer.

---

## 5. What to explore, and specifically what to try to break

`docs/validation-checklist.md` in the repo is a 45-minute runbook covering the
happy paths. **Run it as the floor, not the ceiling**, with one caveat: it was
last updated on 2026-07-21 and the app has gained a large amount of functionality
since, so **it does not cover Command Mode, snippets, translation, Qwen cleanup,
the focus guard, press-Enter, diagnostics export, or update checking.** Note any
step that is now wrong, ambiguous, unperformable as written, or that you could
check off without actually verifying the thing it claims to verify. Then go well
past it.

**Interruption and re-entrancy**
- Press Fn again while the previous dictation is still transcribing or cleaning.
- Double-tap into hands-free while a push-to-talk session is finishing.
- Start a dictation, release Fn, then **immediately switch apps** before the text
  lands. Where does the text go? Where does the cleanup replacement go a second
  later? The focus guard is supposed to re-activate the original app or abort
  with a note. Verify both branches, and check it does not steal focus back from
  you when you deliberately left.
- Cancel with ESC mid-dictation, then confirm nothing pastes afterward. **A
  cancelled dictation that pastes two seconds later, into whatever you switched
  to, is a serious defect.**
- Type more text immediately after the raw paste, before cleanup swaps in. The
  replace must not clobber what you typed.

**Command Mode, which is destructive by design**
- Select existing text you care about, speak an edit instruction, and check the
  result. Then: select text and give a nonsense instruction; give an instruction
  while nothing is selected; change the selection while the command is running;
  let the command time out. In each case, **is the user's original text
  recoverable?**

**Press-Enter**
- Exercise the "press enter" spoken command in a safe target (a Terminal running
  something harmless, or a scratch text field). Then try it while switching apps
  mid-flight. A Return in the wrong window is the worst thing this app can do.

**Boundary input**
- One word. A 90-second monologue. Silence with the key held 30 s. Coughing. Two
  people talking. A URL, an email address, a code snippet with punctuation, a
  list of numbers and currency amounts (there is a spoken-number formatter with a
  history of regressions).
- Whisper Mode on, whispered at normal distance; then Whisper Mode on, spoken at
  full volume.
- Speak while music plays (there is a media-pause controller; verify it pauses
  and, more importantly, that it resumes).

**Recovery**
- Quit and relaunch mid-download, mid-dictation, mid-cleanup.
- Switch displays or Spaces while the HUD is visible. The pill must stay clamped
  under the notch and not drift off-screen.
- Run 50 dictations back to back and watch Activity Monitor. Memory must not
  climb. Switch speech engines and cleanup engines a few times: only the active
  ones should stay resident, and Qwen weights should unload after 5 idle minutes.

**Diagnostics export, worth a careful look**
- Export a diagnostics file after a session with real dictations, then **read the
  whole file**. It claims no audio and no transcript text, only counts and
  timings. Verify that literally, including the embedded log lines and your
  settings dump. Any transcript fragment, dictionary phrase, snippet body, or the
  API key appearing in it is a CRITICAL finding.

**Target-app coverage.** Dictate into each and note where nothing appears or text
lands in the wrong place: TextEdit, Safari address bar, a web form, VS Code,
Terminal, Notes, a Finder rename field, Spotlight, and a password field (safe to
*try*; report what happens).

**Latency, measured properly.** Collect at least 10 "Last: N ms" values for short
utterances and report the median. Note whether *felt* latency matches the number.
If the readout says 180 ms but text visibly appears half a second later, the
readout measures the wrong thing, and that is a finding.

---

## 6. Known issues, so you do not spend the session rediscovering them

Recently fixed, so do not re-file them, but **do** file if you can still
reproduce them:

- Press-and-hold clipping a sentence mid-hold (v0.7.5).
- Cloud cleanup keeping only the first few words (v0.7.10).
- History recording cleaned text when the in-place replace had actually failed
  (v0.8.1).
- A mid-hold tap stall cutting off a still-speaking user (v0.12.1, one day old).
- Full History search field overlapping the list (v0.7.8).
- Settings toggles appearing dead or stuck (v0.2.2, v0.7.3, twice).

Documented as intentional. Confirm each matches what you see, and **file it if it
does not**:

- If a synthesized paste fails outright, the transcript is deliberately left on
  the clipboard as your manual fallback. This is the one case the clipboard is
  not restored.
- Cleanup model provider pinning is soft, so Groq outages route elsewhere.
- Qwen cleanup selection only sticks when the model is fully downloaded;
  otherwise cleanup silently stays on Apple Intelligence. ("Silently" is worth
  judging as a UX defect even though it is intentional.)

---

## 7. What to report, and how

Keep judgment separate from defects. A defect is something that is wrong; a
recommendation is something you think would be better.

### Defects
Ordered by severity, graded by **user harm**, not by how deep the cause is:

- **CRITICAL**: loses the user's work, exposes the API key or audio/transcript
  content, sends a Return into the wrong app, or makes the app unusable until
  relaunch or reinstall.
- **HIGH**: silent failure the user cannot diagnose, clipboard destroyed, text
  landing in the wrong app or overwriting content, latency far past 300 ms on the
  local happy path.
- **MEDIUM**: a real defect with a workaround, or a confusing state.
- **LOW**: cosmetic, wording, polish.

Each defect needs:
- **Literal repro steps**, numbered, from a known starting state, such that
  someone else can follow them exactly. "Sometimes it fails" is not a repro.
- **What I saw** and **what I expected**, stated separately.
- **Does it reproduce?** How many times out of how many attempts. Say so honestly
  if it fired once and never again. An intermittent defect flagged as
  intermittent is useful; one presented as deterministic is not.
- A screenshot where the defect is visual.
- Relevant log lines. Skylark logs its pipeline through unified logging and
  **never logs transcript or audio content**, so streaming logs is safe:
  ```sh
  log stream --predicate 'subsystem == "com.jjromano.skylark"' --level debug --style compact
  ```
  Categories: `audio`, `vad`, `asr`, `injection`, `pipeline`, `audio-devices`,
  `history`. After the fact:
  ```sh
  log show --last 3m --predicate 'subsystem == "com.jjromano.skylark"' --info --debug --style compact
  ```
  Settings, Account, Export Diagnostics also produces a single file with recent
  per-dictation metadata and ~2 hours of logs. Attach it to defect reports.

### What worked well
Specifically, naming the flows you exercised hard that held up. This is the
calibration anchor. It tells us what we can stop worrying about and is the main
defense against inventing problems.

### Recommendations
Product judgment, kept separate from defects.

### What I could not test, and what would unblock it
Be complete. This list becomes the next round of work, so an honest gap is worth
more than a guess. Say what you would need: a second Mac, an OpenRouter key with
credit, a notched display, a specific app installed, a human speaker.

### Latency table
The raw "Last: N ms" values, with utterance length and target app for each, plus
the median.

### Checklist verdict
Which `docs/validation-checklist.md` items passed, failed, or could not be run as
written, and which of its steps you judge unable to detect the failure they
target.

---

## 8. Sol's open questions for you

The static audit found defects it could not settle without a real machine. Each
item below is a concrete experiment with a defined observation. **Run these
first**, before the general exploration in §5, because each one either confirms
or clears a specific suspected defect.

The full audit is at `docs/reviews/2026-07-30-cross-model-audit.md` if you want
the reasoning. You do not need it to run these.

1. **The big one: text and Return landing in the wrong app.** Open a Chrome or
   Terminal text field. Set cleanup to Qwen3 4B and leave the app idle 6+ minutes
   so the model unloads. Dictate a short sentence ending with the words "press
   enter", release Fn, and **immediately switch to another app** while the HUD
   shows Processing. *Decide by:* where the text lands and where the Return goes.
   Expected-correct behavior is that nothing is typed and you get a "focus moved"
   note. Repeat with a second window of the *same* app rather than a different
   app, which is the case the guard provably cannot see.
2. **Command Mode overwriting the wrong selection.** Select a paragraph in Notes,
   start a voice command, and while the model is running switch to another app
   and select different text. *Decide by:* whether the command result overwrites
   the new selection. Check whether the original text is recoverable by any
   means.
3. **Cancel after you have released the key.** Dictate, release Fn, then trigger
   cancel while the HUD shows Processing (via `skylark://recordCancel`, a
   Shortcut, or the HUD control). *Decide by:* whether text still pastes
   afterward, and whether anything tells you the cancel was refused.
4. **A target that ignores synthetic Cmd-V.** Dictate into an app that does not
   accept a synthesized paste. *Decide by:* whether Skylark reports any failure,
   and whether the transcript is still on the clipboard 1 second later or has
   been silently replaced by your previous clipboard content.
5. **Copying during the restore window.** Dictate into a paste-fallback target,
   then copy something new within about half a second of the text appearing.
   *Decide by:* whether your new copy survives or is replaced by your
   pre-dictation clipboard.
6. **Event-tap timeout mid-hold.** Force a main-run-loop stall while holding Fn
   (a heavy app launch or Spotlight indexing can do it), keep speaking, then
   release. *Decide by:* whether the HUD exits and the utterance pastes exactly
   once without needing a second press, and whether a retry's speech gets
   appended to the first recording.
7. **Accessibility revoked during a hold.** Revoke Accessibility while Fn is
   held, release, then re-grant. *Decide by:* whether recording finalizes or
   cancels visibly, and whether the next press works normally.
8. **Audio route failure at start.** Force a capture start failure (yank the
   selected input device at the moment you press Fn), then retry immediately.
   *Decide by:* whether the first attempt surfaces any error, and whether the
   retry starts cleanly or throws an AVAudioEngine tap error.
9. **Hands-free past 120 seconds.** Run a hands-free session longer than two
   minutes, then stop speaking. *Decide by:* whether VAD ever ends the session,
   and whether any words spoken after the two-minute mark appear.
10. **VAD trim on quiet speech.** With "Trim silence from recordings" on, dictate
    a sentence with a soft 700 ms opening, a 1.2-second thinking pause in the
    middle, and a whispered trailing clause. Repeat with the toggle off.
    *Decide by:* whether the two transcripts differ, specifically at the start
    and end.
11. **Engine switch mid-transcription.** Start a Whisper transcription and switch
    to an already-warm Parakeet immediately. *Decide by:* whether the in-flight
    utterance completes, fails silently, or produces errors in the log.
12. **Diagnostics export contents.** After a session with real dictations, export
    diagnostics and read the entire file. *Decide by:* whether any transcript
    fragment, dictionary phrase, snippet body, file path containing a real name,
    or the API key appears anywhere in it. (The static audit read this closely
    and came back clean, so this is a confirmation, not a hunt.)
13. **Uploading while the menu says Local.** With a key stored, select a cloud
    speech engine and then, within a second or two, select a local engine. Wait
    for both to settle, confirm the menu shows Local, then dictate with a network
    monitor running (Little Snitch, or `nettop -p $(pgrep -x Skylark)`).
    *Decide by:* whether any connection to `openrouter.ai` occurs. If a keychain
    authorization dialog ever appears during engine switching, that widens the
    window, so try it in that state too.
14. **What actually goes to the cloud with your dictionary loaded.** Add several
    distinctive dictionary entries (invent unique nonsense words so they are easy
    to spot). Select cloud cleanup. Dictate a sentence containing **none** of
    them. *Decide by:* whether those terms leave the machine. The static audit
    says the full dictionary is sent on every request; confirm it against real
    traffic and check whether any UI discloses it.
15. **Qwen download failure.** With a Qwen model already installed and working,
    start a download of the *same* model and interrupt it (kill Wi-Fi mid-way).
    *Decide by:* whether the previously working model survives, or whether you
    are left with no local cleanup model.
16. **Local-mode network at launch.** Select local Whisper or Apple Speech,
    delete the Parakeet model, quit, and relaunch with a network monitor running.
    *Decide by:* whether Skylark connects to Hugging Face and starts downloading
    Parakeet despite a fully local configuration on a different engine.
