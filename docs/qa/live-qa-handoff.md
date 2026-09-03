# Skylark live QA handoff (Claude Code, local terminal on the Air)

**You are the live-driver half of a two-track audit.** The other half was a
static code audit by GPT-5.6 Sol reading the source. The two tracks find
*disjoint* defect classes, so do not try to reason about the code. Drive the app
and report what you observe.

The most valuable thing you can produce is a defect that is invisible in source:
text landing in the wrong window, a state the app cannot get out of, a number on
screen that disagrees with the database behind it, something that is broken even
though every line of code does exactly what it says.

**Build under test:** `main` at `c1691f7`, version **0.12.1**. Verify before
starting:

```sh
defaults read /Applications/Skylark.app/Contents/Info.plist CFBundleShortVersionString
pgrep -xl Skylark || open -a Skylark
```

If the installed app is older, run `./Scripts/install.sh` from a fresh clone and
say in your report which version you actually tested.

**You must run on the MacBook Air (M3, macOS 26), where Skylark is installed.**
Confirm with `sysctl -n hw.model`. The Mac Mini build box has no microphone, no
screen, and Apple Intelligence off, so it cannot exercise any of this.

---

## 1. How you drive this app

You do not have hands. Skylark is a menu-bar app with no window, triggered by
holding a key and speaking. Here is how to work around every part of that.

### 1a. Trigger recording without pressing Fn

Three surfaces, in order of preference.

**Deep links (easiest, no permissions needed).** The app registers a `skylark://`
scheme:

```sh
open "skylark://record/start"    # begins a HANDS-FREE session
open "skylark://record/stop"
open "skylark://record/toggle"   # same as the HUD record button
open "skylark://record/cancel"
open "skylark://settings"        # opens the Settings window
```

This covers hands-free dictation completely. Note it does **not** exercise
push-to-talk, which is the primary interaction and a different code path.

**Rebind the hotkey to something synthesizable (for push-to-talk).** You cannot
synthesize a bare Fn press. You can rebind the trigger and then send real key
events. The binding is a plain preference read at launch:

```sh
# F13 is the cleanest: no modifiers, no chord-timing rules.
defaults write com.jjromano.skylark hotkey.keyboard -string "f13"
# Command Mode's separate trigger, if you need it:
defaults write com.jjromano.skylark hotkey.command -string "f14"
killall Skylark; sleep 1; open -a Skylark
```

Accepted formats are `fn`, `f13`-style function keys, `rightCommand`,
`rightOption`, `rightControl`, `chord:opt:49` (modifier tokens `cmd`/`opt`/
`ctrl`/`shift` plus a keycode; 49 is Space), and `mouse4`. Then hold and release
with AppleScript (F13 is key code 105, F14 is 107):

```sh
osascript -e 'tell application "System Events" to key down (key code 105)' \
  -e 'delay 3' \
  -e 'tell application "System Events" to key up (key code 105)'
```

**Restore `fn` when you are done**, and say clearly in your report which tests
ran on a rebound trigger. Rebinding means the Fn-specific behavior (swallowing
the system Globe action, the fn-flag traps, Fn+arrow passthrough) is **not**
under test. Those need a human and belong in your "could not test" list.

**AppleScript UI driving (for menus and Settings).** The menu bar item and the
Settings window are ordinary AX targets. The terminal app hosting you needs
Accessibility permission for this; if `osascript` returns error -1719 or -25211,
that is what is missing.

### 1b. Get speech into the microphone

This is the real constraint. Pick a tier and say which one you used.

**Tier 0, zero setup: play audio out loud and let the built-in mic hear it.**

```sh
say "The quick brown fox jumps over the lazy dog."
```

Crude but sufficient for most of this pass, because nearly every question here
is "did text appear, where did it land, what state resulted", not "was the
transcript perfect". Set a reasonable volume and keep the room quiet. Start
recording first, then speak, then stop.

**Tier 1, better: a virtual audio device, so audio is injected cleanly.**

```sh
brew install blackhole-2ch switchaudio-osx
```

Then set Skylark's input to BlackHole (Settings, Audio) and the *system output*
to BlackHole (`SwitchAudioSource -s "BlackHole 2ch"`), so anything you `afplay`
lands in Skylark's capture instead of the speakers. This gives you deterministic,
repeatable audio and lets you test whisper-quiet and boundary clips precisely.
Installing BlackHole changes the machine's audio setup, so **ask JJ before doing
it** and restore the original devices afterward.

**Generating test clips.** `Scripts/bench.sh` already does exactly this and is
your reference:

```sh
say -o /tmp/clip.aiff "Meet me Tuesday, wait no, Friday."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/clip.aiff /tmp/clip.wav
```

For the quiet-speech tests, generate a normal clip and attenuate it with
`afconvert`/`sox`, or use `say -v` voices and lower the output volume.

**If you can do neither tier**, say so immediately and stop. Roughly two thirds
of this document requires audio reaching the app, and a pass that skips it is not
worth reporting as a pass.

---

## 2. What you may break, and the four lines not to cross

**You have free rein over the Air's Skylark installation.** All of this is yours
to change, break, wipe, and restore:

- Settings and preferences (`defaults` domain `com.jjromano.skylark`)
- The history database, dictionary, snippets, and modes
- Downloaded models under `~/Library/Application Support/Skylark/`
- Skylark's Keychain entry and its TCC grants
- The system clipboard
- Any scratch document, TextEdit window, or Terminal tab you create

A read-only pass would be worthless. The defects live in states you have to
*create*: a half-downloaded model, a revoked permission, a cancelled dictation, a
cold local LLM. Create them.

**Before you start, quit every app that can send a message.** Slack, Messages,
Mail, Discord. This is not politeness: the headline defect under investigation is
Skylark typing and pressing Return in the wrong app, and you will be
synthesizing keystrokes. Removing those windows from the machine is the
containment.

### The four lines

1. **Never dictate into, or synthesize Return into, anything that sends or
   executes.** Use TextEdit, scratch files, and a Terminal tab running a harmless
   `cat > /tmp/scratch.txt`. Never a shell prompt where a stray Return runs a
   command, and never a web form you submit.
2. **Never print or exfiltrate the OpenRouter API key.** You will handle a real
   key. Refer to it by name and shape. If you find it exposed anywhere it should
   not be (a log, an error, the diagnostics export), that is CRITICAL: report
   *where* it appeared, redacted.
3. **Confine destructive shell commands to Skylark's own paths.** `rm -rf` only
   under `~/Library/Application Support/Skylark/`. `tccutil reset` only with
   `com.jjromano.skylark` as the bundle argument, never bare (a bare
   `tccutil reset Accessibility` wipes the grant for every app on the machine,
   including your own terminal, and you will lock yourself out).
4. **Do not modify the repository or push.** Report findings; fixing happens
   elsewhere.

---

## 3. What this app is, and who actually uses it

Skylark is a personal, open-source, MIT macOS menu-bar dictation app. Hold the Fn
(Globe) key, speak, release, and text appears at your cursor in whatever app you
were typing in. Local by default, with optional cloud speech-to-text and cloud
cleanup via OpenRouter. No Dock icon, no main window: a menu-bar mic glyph plus a
floating pill under the notch is the entire GUI.

Shipped surface area, much of it newer than any written test plan: push-to-talk
and hands-free dictation with VAD endpointing; Whisper Mode for quiet speech;
speech engines Parakeet (default), WhisperKit, Apple SpeechAnalyzer, and two
cloud models; cleanup tiers raw, Apple Intelligence, on-device Qwen3 1.7B/4B via
bundled llama.cpp, and cloud; AX text injection with a clipboard-preserving paste
fallback, a focus guard, and read-signaled clipboard restore; Command Mode
(select text, speak an instruction, it rewrites the selection); custom dictionary
with auto-learn, deep vocabulary rescoring, snippets, app-aware modes and
presets, translation; history with optional audio retention and re-transcription;
insights, diagnostics export, update check.

**Two real users, and they are not the same person:**

- **JJ**, technical, the author, on this Air. He benchmarks Skylark against Wispr
  Flow on his own phrases. If it feels slower, the product failed regardless of
  what any measurement says.
- **Stephanie**, **non-technical**, on her own MacBook Pro with her own Keychain
  and her own model downloads. Every error message, empty state, and permission
  prompt has to make sense with no context. **Grade confusing states as her.**
  "I pressed the key and nothing happened" is serious even when the behavior is
  technically correct.

It is used all day, dozens of times an hour, in the middle of other work. It is
not a thing you open; it has to already be working. That is why silent failure is
the worst class here: a user who cannot tell "it didn't hear me" from "it's
broken" stops trusting it.

---

## 4. The quality bar, quoted. Grade against this.

From `Skylark_Dictation_PRD.md` §12 and §1:

> **Latency targets (local, short utterance):** end-of-speech to pasted raw text
> under 300ms; streaming interim tokens under 150ms where implemented.
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

> **Latency is the product.** Every architectural decision is judged first by the
> time between "I stop speaking" and "clean text appears at my cursor."

From §10:

> The app must insert text without disturbing the user's clipboard [...] snapshot
> the full `NSPasteboard` contents (all types and items, not just plain string),
> perform the paste, then restore the original contents after the paste
> completes.

---

## 5. How to see what happened

You have a shell, which makes you a **better** observer than a human clicking.
Use it. Every "decide by" below assumes these.

**Pipeline logs.** Content-free by design (no transcript or audio is ever
logged), so streaming them is safe:

```sh
log stream --predicate 'subsystem == "com.jjromano.skylark"' --level debug --style compact
log show --last 3m --predicate 'subsystem == "com.jjromano.skylark"' --info --debug --style compact
```

Categories: `audio`, `vad`, `asr`, `injection`, `pipeline`, `audio-devices`,
`history`, `hotkey`. Run the stream in the background during every experiment and
attach the relevant lines to each finding.

**What the app thinks happened.** The history database is the ground truth for
what was transcribed, which engine ran, and how it was injected:

```sh
sqlite3 ~/Library/Application\ Support/Skylark/skylark.sqlite \
  "select id, timestamp, engine, duration_ms, latency_ms, audio_path,
          length(raw_text), length(clean_text) from history order by id desc limit 5;"
```

Prefer lengths and metadata over dumping text. When you must inspect content to
prove a defect, quote the minimum.

**Clipboard, before and after.** For text, hash it. For rich content, fingerprint
the types and sizes:

```sh
pbpaste | shasum
osascript -e 'clipboard info'
```

`clipboard info` lists every type and byte count on the pasteboard, which is
exactly what PRD §10 promises to preserve. Capture it before the dictation and
again afterward and diff the two.

**Network, for the local-mode privacy claims.**

```sh
lsof -nP -i -a -p "$(pgrep -x Skylark)"
```

Sample it in a loop during a dictation. Little Snitch, if installed, is better
because it catches short-lived connections.

**Memory and residency.**

```sh
ps -o rss=,vsz= -p "$(pgrep -x Skylark)"
```

**Current settings**, to confirm a seeded state took effect:

```sh
defaults read com.jjromano.skylark
```

**Screenshots**, for anything visual (HUD state, Settings, a banner):

```sh
screencapture -x /tmp/shot.png
```

Read it back with your image tool. This is the one place you are weaker than a
human, so use it deliberately on HUD and Settings states.

---

## 6. Seed these states deliberately

**Do not spend the session on the happy path.** Clean state finds nothing. Create
each of these, then dictate into it. Quit Skylark before any command that touches
its files, and relaunch after.

| State | How | What you are hunting |
|---|---|---|
| Fresh install, no models | `killall Skylark; rm -rf ~/Library/Application\ Support/Skylark/Models; open -a Skylark` then immediately record and speak | Does it say the model is not ready, or silently eat the sentence? |
| Mid-download | Same, but record repeatedly while the 483 MB Parakeet download runs | Progress accuracy; whether dictation queues, drops, or errors; whether the download survives |
| Cold local LLM | Select Qwen3 4B cleanup, idle 6+ minutes (weights unload at 5), then dictate | Cleanup must reload 2.3 GB. Time from raw paste to cleaned swap. Type during it. |
| Qwen download interrupted | With Qwen installed and working, re-download and kill Wi-Fi mid-way | Whether the previously working model survives or you are left with none |
| Empty history | Clear History, open the window | Does the empty state read like a product or a bug? |
| Large history | 30+ dictations, then search | Correctness and responsiveness |
| No API key | Delete the key, select cloud STT and cloud cleanup | Falls back to local with a notice, or hangs, fails silently, or crashes? |
| Invalid API key | Enter a well-formed but wrong key | Is the error actionable for Stephanie? |
| Offline, cloud selected | Cloud STT plus cloud cleanup, `networksetup -setairportpower en0 off`, dictate | PRD promises transparent local fallback with a notice and nothing hanging. Time it. |
| Network dies mid-request | Cloud cleanup selected, kill Wi-Fi *during* the cleanup call | Does the raw paste survive? Does the replace fire late and clobber something? |
| Apple Intelligence off | System Settings, Apple Intelligence and Siri, off; cleanup set to local Apple | Dictation must still work, raw text stands, no error shown |
| Bluetooth mic | Connect AirPods, select them in Settings, Audio | HFP quality warning must appear; dictation must still work |
| Device yanked mid-utterance | Start dictating on AirPods, disconnect them while speaking | The interruption model, rewritten twice in three days. Expect "Mic interrupted, text may be incomplete". Did the words before the yank survive? |
| Rich clipboard | Copy an image from Preview, rich text from Safari, and **a file from Finder** (file promises are the hard case), then dictate into a paste-fallback target | Fingerprint with `osascript -e 'clipboard info'` before and after. A plain-string check proves nothing. |
| Permission revoked while running | `tccutil reset Accessibility com.jjromano.skylark` with Skylark running | Does the hotkey silently die with no indication? To a user that reads as "the app is dead." |
| Sleep and wake | `pmset sleepnow`, wake, dictate | The event tap has a liveness watchdog. Does it actually recover? |
| Dictionary collisions | Add entries that overlap or substring one another | Wrong-replacement behavior |
| VAD trim off | `defaults write com.jjromano.skylark vadClipTrimEnabled -bool false`, relaunch, compare against default-on | Whether trimming eats a soft opening or a quiet trailing clause |

If a state is impossible for a reason you can name, put it in "could not test".
That list is planning input, not a disclaimer.

---

## 7. Targeted experiments from the static audit

**Run these first.** Each one confirms or clears a specific defect that Sol found
in the source but could not settle without a running machine. The full audit is
at `docs/reviews/2026-07-30-cross-model-audit.md` if you want the reasoning; you
do not need it.

1. **The big one: text and Return in the wrong app.** Open a scratch TextEdit
   document. Set cleanup to Qwen3 4B and idle 6+ minutes so it unloads. Dictate a
   short sentence ending with the words "press enter", stop recording, then
   **immediately activate a different app** (`osascript -e 'tell application
   "TextEdit" to activate'` works, or use a second scratch window). *Decide by:*
   where the text lands and where the Return goes. Correct behavior is that
   nothing is typed and a "focus moved" note appears. **Then repeat with a second
   window of the same app**, which is the case the guard provably cannot see.
2. **Command Mode overwriting the wrong selection.** Select a paragraph in a
   TextEdit document, start a voice command, and while the model runs switch to a
   different document and select different text. *Decide by:* whether the result
   overwrites the new selection, and whether the original is recoverable by any
   means including Undo.
3. **Cancel after the key is released.** Dictate, stop recording, then during
   Processing run `open "skylark://record/cancel"`. *Decide by:* whether text
   still pastes afterward, and whether anything reports the cancel was refused.
4. **A target that ignores synthetic Cmd-V.** Dictate into an app that does not
   accept a synthesized paste. *Decide by:* whether Skylark reports any failure,
   and whether the transcript is still on the clipboard one second later or has
   been silently replaced by your previous clipboard content. Poll `pbpaste`.
5. **Copying during the restore window.** Dictate into a paste-fallback target,
   then `printf 'NEWCOPY' | pbcopy` within about half a second of the text
   appearing. *Decide by:* whether `pbpaste` still reads `NEWCOPY` a second
   later, or has been replaced by your pre-dictation clipboard.
6. **Event-tap timeout mid-hold.** With a rebound trigger, hold it, force a
   main-run-loop stall (launch a heavy app, or `mdutil -E /` to kick indexing),
   keep the audio playing, then release. *Decide by:* whether the HUD exits and
   the utterance is delivered exactly once without a second press, and whether a
   retry's speech gets appended to the first recording.
7. **Accessibility revoked during a hold.** Hold the trigger, run
   `tccutil reset Accessibility com.jjromano.skylark`, release, then re-grant.
   *Decide by:* whether recording finalizes or cancels visibly, and whether the
   next trigger works.
8. **Capture start failure.** Force one by selecting a device and removing it at
   the moment recording starts (disconnect a USB mic, or select AirPods and
   disconnect). Retry immediately. *Decide by:* whether the first attempt
   surfaces any error, and whether the retry starts cleanly or logs an
   AVAudioEngine tap error in the `audio` category.
9. **Hands-free past 120 seconds.** `open "skylark://record/start"`, play audio
   for over two minutes, then stop speaking. *Decide by:* whether VAD ever ends
   the session, and whether words spoken after the two-minute mark appear.
10. **VAD trim on quiet speech.** With trimming on (default), dictate a clip with
    a soft opening, a 1.2 second pause in the middle, and a quiet trailing
    clause. Repeat with `vadClipTrimEnabled` false. *Decide by:* whether the two
    transcripts differ at the start and end.
11. **Engine switch mid-transcription.** Start a Whisper transcription and switch
    to an already-warm Parakeet immediately. *Decide by:* whether the in-flight
    utterance completes, fails silently, or logs concurrent unload errors.
12. **Diagnostics export contents.** After a session with real dictations, export
    diagnostics and read the entire file. *Decide by:* whether any transcript
    fragment, dictionary phrase, snippet body, real-name path, or the API key
    appears. The static audit read this closely and came back clean, so this is a
    confirmation, not a hunt.
13. **Uploading while the menu says Local.** With a key stored, select a cloud
    speech engine and then within a second or two select a local engine. Confirm
    the menu shows Local, then dictate while sampling
    `lsof -nP -i -a -p "$(pgrep -x Skylark)"` in a loop. *Decide by:* whether any
    connection to `openrouter.ai` occurs. If a keychain dialog ever appears
    during engine switching, that widens the window, so try it in that state too.
14. **What your dictionary sends to the cloud.** Add several distinctive
    dictionary entries (invent unique nonsense words). Select cloud cleanup.
    Dictate a sentence containing **none** of them. *Decide by:* whether those
    terms leave the machine, and whether any UI discloses that they will. The
    static audit says the full dictionary is sent on every cloud cleanup request.
15. **Local-mode network at launch.** Select local Whisper or Apple Speech,
    delete only the Parakeet model, quit, and relaunch while watching `lsof`.
    *Decide by:* whether Skylark connects to Hugging Face and downloads Parakeet
    despite a fully local configuration on a different engine.
16. **Latency, measured properly.** Collect at least 10 "Last: N ms" values for
    short utterances and report the median, not the best. Cross-check against
    `latency_ms` in the history table. *Decide by:* whether the readout matches
    the database, and whether either matches when text visibly appears. If the
    readout says 180 ms but text lands half a second later, the readout measures
    the wrong thing, and that is a finding.

---

## 8. Then go past the checklist

`docs/validation-checklist.md` covers the happy paths. **Run it as the floor.**
It has grown since 2026-07-05 and now has sections for Command Mode (§13), the
focus guard and press-Enter (§4), Qwen cleanup (§12), translation (§15),
snippets (§14), deep vocabulary (§9), diagnostics export (§17), and update
checking (§18); the cloud dictionary filter lives under §8. Note any step that
is still wrong, ambiguous, or that you could check off without verifying the
thing it claims to verify. Its §5 clipboard step is a known example: if the
target accepts AX insertion, the clipboard path never runs and the box still
gets checked.

Beyond that:

**Interruption and re-entrancy.** Trigger again during transcribing or cleaning.
Start hands-free while a push-to-talk session is finishing. Type more text
immediately after the raw paste, before cleanup swaps in, and confirm the replace
does not clobber what you typed.

**Boundary input.** One word. A 90 second monologue. 30 seconds of silence with
the trigger held. A URL, an email address, a code snippet, a list of currency
amounts (the spoken-number formatter has a regression history). Whisper Mode on,
with quiet audio and then with loud audio.

**Recovery.** Quit and relaunch mid-download, mid-dictation, mid-cleanup. Run 50
dictations back to back and watch `ps -o rss=`; memory must not climb. Switch
speech and cleanup engines repeatedly; only the active ones should stay resident
and Qwen should unload after 5 idle minutes.

**Target coverage.** Dictate into TextEdit, Safari's address bar, a web form, VS
Code, Terminal, Notes, a Finder rename field, and Spotlight. Note anywhere
nothing appears or text lands in the wrong place.

---

## 9. Known issues, so you do not rediscover them

Recently fixed. Do not re-file, but **do** file if you can still reproduce:
press-and-hold clipping a sentence mid-hold (v0.7.5); cloud cleanup keeping only
the first few words (v0.7.10); history recording cleaned text when the replace
failed (v0.8.1); a mid-hold tap stall cutting off a still-speaking user
(v0.12.1); History search overlapping the list (v0.7.8); Settings toggles
appearing stuck (v0.2.2 and v0.7.3).

Documented as intentional. Confirm each matches, and **file it if it does not**:

- A synthesized paste that fails outright deliberately leaves the transcript on
  the clipboard. This is the one case the clipboard is not restored.
- Cleanup provider pinning is soft, so Groq outages route elsewhere.
- Qwen selection only sticks when the model is fully downloaded; otherwise
  cleanup silently stays on Apple Intelligence. ("Silently" is worth judging as a
  UX defect even though it is intentional.)

---

## 10. What you cannot test here, and should say so

Be explicit about these in your report rather than implying coverage:

- **Bare Fn behavior**, if you rebound the trigger: swallowing the system Globe
  action, Fn+arrow and Fn+F-key passthrough, and the fn-flag traps.
- **HUD visual quality**: hover expansion, flicker, notch clamping, drift across
  displays and Spaces, waveform animation. You can screenshot states but you
  cannot judge motion or feel.
- **Felt latency** versus measured latency, and the Wispr Flow comparison. Both
  need JJ.
- **Real speech**: accents, natural prosody, background noise, genuine whispering.
  Synthesized `say` audio is cleaner than a human and will overstate accuracy.
- Anything requiring a second machine or Stephanie's environment.

---

## 11. What to report

Keep judgment separate from defects. A defect is something that is wrong; a
recommendation is something that would be better.

### Defects
Ordered by severity, graded by **user harm**:

- **CRITICAL**: loses the user's work, exposes the API key or transcript content,
  sends a Return into the wrong app, or bricks the app until relaunch or
  reinstall.
- **HIGH**: silent failure the user cannot diagnose, clipboard destroyed, text
  landing in or overwriting the wrong place, latency far past 300 ms locally.
- **MEDIUM**: a real defect with a workaround, or a confusing state.
- **LOW**: cosmetic, wording, polish.

Each needs:
- **Literal repro steps**, numbered, from a known starting state, including the
  exact commands you ran, so someone else can replay them.
- **What I saw** and **what I expected**, stated separately.
- **Does it reproduce?** How many times out of how many attempts. An intermittent
  defect flagged as intermittent is useful; one presented as deterministic is not.
- **Evidence**: the relevant `log show` lines, the `sqlite3` row, the
  `clipboard info` diff, the `lsof` line, or a screenshot for visual defects.
  Prefer captured output over description.
- Which **audio tier** (0 or 1) and whether the **trigger was rebound**.

### What worked well
Specifically, naming the flows you exercised hard that held up. This is the
calibration anchor and the main defense against inventing problems.

### Recommendations
Your product judgment, separate from defects.

### What I could not test, and what would unblock it
Complete and honest. Start from §10 and add anything else. This list becomes the
next round of work.

### Latency table
Raw "Last: N ms" values with utterance length and target app, the `latency_ms`
values from the database alongside them, and the median.

### Checklist verdict
Which `docs/validation-checklist.md` items passed, failed, or could not be run as
written, and which steps you judge unable to detect the failure they target.

### Machine restored
Confirm at the end: hotkey binding back to `fn`, audio devices restored, TCC
grants re-granted, Wi-Fi on, `vadClipTrimEnabled` cleared, and any test models
you deleted either restored or noted as still missing.
