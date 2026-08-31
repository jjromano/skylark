# Skylark Air QA handoff — v0.19.2

**You are driving a live QA pass on the MacBook Air.** A headless pass just ran
on the Mac mini and closed everything the Mini could reach. Your job is the
half it could not: anything needing a microphone, real focus, a screen, or
Apple Intelligence.

**Build under test:** `main` at `080ace1`, version **0.19.2**. Verify before
starting anything:

```sh
sysctl -n hw.model                    # must be a MacBook Air — stop if not
cd ~/dev/projects/skylark && git fetch origin && git log --oneline -1 origin/main
./Scripts/install.sh                  # build + install this commit
defaults read /Applications/Skylark.app/Contents/Info.plist CFBundleShortVersionString
```

If the installed version is not 0.19.2, say so in your report and name what you
actually tested.

---

## 1. Read the mechanics doc, with these corrections

`docs/qa/live-qa-handoff.md` is the manual for HOW to drive and observe this
app: triggering without hands, getting speech into the mic, reading the logs and
the history DB, fingerprinting the clipboard, seeding broken states, and the
report format. **All of that is still accurate — use it.** It was written
against v0.12.1, so four things in it are now wrong:

1. **"Deep links cover hands-free dictation completely" is false.** The focus
   guard refuses `skylark://record/start` whenever Skylark itself is frontmost,
   logging `record deep link refused — Skylark itself holds focus`. On the Mini
   this made deep links useless from a background session. On the Air you have
   real focus control, so put a scratch TextEdit window in front first and
   confirm the refusal is absent from the log before trusting a deep-link run.
2. **`make test --filter <name>` never worked** — `make` parsed the flag as its
   own and exited without running the test. Fixed in v0.19.2. The correct form
   everywhere is now `make test TESTFLAGS='--filter <name>'`.
3. **Its §7 experiment list belongs to the 2026-07-30 audit.** Those are still
   worth running, but §4 below is what this pass is actually for.
4. **Its "known issues" §9 predates six releases.** Check `CHANGELOG.md` for
   0.16.0 through 0.19.2 before filing anything as new.

The four safety lines in its §2 stand unchanged and are not negotiable: never
synthesize Return into anything that sends or executes; never print the
OpenRouter or Groq key; confine destructive commands to Skylark's own paths and
never run a bare `tccutil reset`; do not push to the repo.

---

## 2. Already covered on the Mini — do NOT redo these

The 2026-08-31 Mini pass ran all of this green at `080ace1`. Re-running it wastes
your session and tells you nothing new.

| Covered | Result |
|---|---|
| Unit suite (`make test`) | 839 tests / 129 suites pass on CLT 6.2 |
| Two-engine latency bench + regression gate | No regressions; Parakeet 62/83/144 ms, Whisper 823/1105/1746 ms |
| Qwen 1.7B cleanup eval | 14/29 exact, 265 ms avg |
| Qwen 4B cleanup eval | 25/29 exact, 535 ms avg |
| Silero VAD live clip scan | 2.8 ms mean on a 4 s clip, correct region, no trim |
| Long-capture memory probe | 120 s finalize peaks 21.9 MB over a 26.4 MB baseline |
| Deep-vocabulary corruption regression | Clean — no substitution on a clip with no matching terms |
| GGUF supply-chain pins | Both SHA-256 digests match `LocalCleanupModel.swift` exactly |
| Content-free logging invariant | Re-swept, 116 call sites, none carry content |
| Diagnostics export log scoping | Confirmed scoped to Skylark's own subsystem |

**What that coverage does NOT include:** any audio actually reaching the app,
any text actually landing in another app, and anything visual. The Mini has no
microphone at all.

---

## 3. Priority 1 — confirm the no-mic crash fix on real hardware

**This is the most important thing you will do, because the fix was proven on a
machine that never had a microphone, and your machine does.**

v0.19.2 fixed a P0: starting a dictation with no usable audio input aborted the
process (SIGABRT). `AudioCaptureService.installTapAndStart` handed a 0 Hz /
0-channel format to `AVAudioNode.installTap`, which raises an Objective-C
`NSException` that Swift cannot catch. Granting microphone permission is what
exposes it — a denied mic never reaches the line.

The Mini proved the guard refuses cleanly when there is *no device at all*. The
case it could not test is **a device that disappears**, which is the one a real
user hits.

Run each of these, and after every one check `pgrep -x Skylark` and
`ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i skylark`. A fresh `.ips`
file is a CRITICAL finding.

1. **Baseline probe.** `SKYLARK_LIVE_MIC_PROBE=1 make test TESTFLAGS='--filter
   liveCaptureStart'`. On the Air, with a built-in mic, this should report
   `input devices present: true` and `start() succeeded and stopped cleanly`.
   If it reports `false` on a MacBook Air, stop and investigate — that is itself
   a finding.
2. **Unplug the only mic, then dictate.** Connect AirPods or a USB mic, select
   it in Settings → Audio, disconnect it, then trigger a dictation. Expected: a
   note naming the missing microphone, app alive. Fail: crash, hang, or silence.
3. **Yank mid-utterance.** Start dictating on AirPods, disconnect them while
   speaking, release. Expected: "Mic interrupted, text may be incomplete" and
   the words before the yank survive.
4. **Select a device, remove it at the moment recording starts.** Retry
   immediately afterward. Expected: the second attempt starts cleanly, with no
   leaked tap (the symptom would be attempt #2 failing where #1 failed too).
5. **Reconnect and dictate again.** The app must recover without a relaunch.

Report the exact note text the user sees in each case. "It didn't crash" is half
the answer; whether Stephanie could act on the message is the other half.

---

## 4. Priority 2 — re-base the Apple Intelligence cleanup floor

`CleanupCorpusTests.appleIntelligenceBaseline` is **13**, measured against the
OLD 17-example corpus. The corpus is now 29. The Mini could not re-measure it
(Apple Intelligence is off there) and the Air is the only machine that can.

```sh
SKYLARK_LIVE_CLEANUP_EVAL=1 make test TESTFLAGS='--filter liveOnDeviceEval'
```

Confirm Apple Intelligence is actually on first — if it is off, the eval now
prints `[cleanup-eval] NOT RUN — the on-device model is unavailable here` rather
than a misleading "regressed 0/29", and you have measured nothing.

Report the measured score and the per-category MATCH/DIFF report. **Do not edit
the floor yourself** — hand the number back. For reference, the same 29-case
corpus scores 25/29 on Qwen3 4B and 14/29 on Qwen3 1.7B, so a wildly lower
Apple number is interesting rather than automatically wrong.

---

## 5. Priority 3 — the voice-driven surface nothing has ever tested

Everything in 0.16.0 through 0.19.2 was verified only by golden-string tests or
by a machine with no microphone. **These features have never once been exercised
by a human voice.** This is where undiscovered defects most likely live.

**Spoken punctuation and pause tolerance (0.16.0, 0.16.1).** All of this needs
real prosody; `say(1)` is too clean to be evidence.

- Say a sentence with a genuine 1–2 second thinking pause in the middle. It must
  NOT become a period. This is the headline feature of 0.16.0.
- Say "comma", "period", "question mark", "exclamation mark", "colon",
  "semicolon" out loud mid-sentence and confirm each becomes the mark.
- Say a sentence where one of those words is a NOUN, not a command — "the
  question mark was missing" — and confirm it stays as words.
- Say a one- or two-word dictation ("yes", "no thanks"). It skips the model
  entirely; confirm it is still capitalised and punctuated.
- Say "yes period" — the 0.16.1 fix. It must not paste the word "period".
- **Stress a word heavily** and confirm you do NOT get ALL CAPS or an
  exclamation mark (the 0.16.0 emphasis repair). Also confirm a genuine acronym
  you speak is not de-capitalised.
- Hands-free: confirm the longer silence tolerance feels right and does not cut
  you off mid-thought. There is a 1/2/3 s picker in Settings that has never been
  rendered on screen — look at it.

**Groq direct speech engine (0.19.0), never used by anyone.**

- Enter a Groq key in Settings → Account (it is a SEPARATE Keychain item from
  the OpenRouter key — confirm entering one does not disturb the other).
- Dictate on "Groq direct — Whisper large-v3-turbo" and compare latency against
  the OpenRouter cloud route on the same phrases. The entire point of 0.19.0 was
  removing OpenRouter's provider lottery; confirm the swing actually narrowed.
- With NO Groq key stored, select the engine and dictate. Does it fall back with
  a note, or fail silently? Grade as Stephanie.
- While dictating on Groq, sample `lsof -nP -i -a -p "$(pgrep -x Skylark)"` and
  confirm traffic goes to `api.groq.com` and NOT to `openrouter.ai`.

**Cleanup timeout behaviour (0.18.0, 0.19.1).**

- The default timeout moved 2 s → 5 s. Confirm a fresh install shows 5 s and
  that an install with a hand-picked value keeps it.
- Force repeated cleanup timeouts (cloud cleanup + throttled network) and
  confirm the "recommend a fix" advice appears and is actionable.

**Per-stage latency diagnostics (0.17.0).**

- After a dozen real dictations, export diagnostics and confirm the per-stage
  breakdown is present and that the numbers are plausible against the
  `latency_ms` column in the history DB.
- **Read the entire exported file.** Confirm no transcript fragment, dictionary
  phrase, snippet body, or API key appears. The static audit came back clean, so
  this is a confirmation, not a hunt — but it has never been read on a machine
  with real dictations in it.

---

## 6. Priority 4 — the whole injection and clipboard half

None of this can run without a real focus target. It is the core of the product
and the Mini pass covered none of it.

- **Clipboard preservation, properly.** Copy an image from Preview, rich text
  from Safari, and **a file from Finder** (file promises are the hard case).
  Fingerprint with `osascript -e 'clipboard info'` before and after a dictation
  into a paste-fallback target. A plain-string check proves nothing.
- **Copy during the restore window.** `printf 'NEWCOPY' | pbcopy` within about
  half a second of the text appearing; confirm `pbpaste` still reads `NEWCOPY` a
  second later.
- **A target that ignores synthesized Cmd-V.** Confirm Skylark reports the
  failure, and that the transcript is deliberately left on the clipboard (this
  is the one documented case where the clipboard is NOT restored).
- **Text into the wrong app.** Dictate, stop, then immediately activate a
  different app. Correct behavior is nothing typed plus a "focus moved" note.
  Repeat with a second window of the SAME app — the case the guard provably
  cannot see.
- **Press-Enter into the wrong app.** Same setup, sentence ending in "press
  enter". A Return landing in the wrong window is CRITICAL.
- **Command Mode overwriting the wrong selection.** Select a paragraph, start a
  voice command, switch documents and select different text while the model
  runs.
- **Target coverage.** TextEdit, Safari's address bar, a web form, VS Code,
  Terminal, Notes, a Finder rename field, Spotlight. Note anywhere text does not
  appear or lands in the wrong place.
- **Bare Fn behaviour**, which nothing automated can test: swallowing the system
  Globe action, Fn+arrow and Fn+F-key passthrough. Do not rebind the hotkey for
  this section.
- **The HUD**, which no machine has ever rendered for QA: hover expansion,
  flicker, notch clamping, drift across displays and Spaces, the cap countdown,
  waveform animation. Screenshot the states and judge them.
- **Latency as felt.** Collect at least 10 "Last: N ms" values for short
  utterances, report the median, and cross-check against `latency_ms` in the
  history DB. If the readout says 180 ms but text lands half a second later, the
  readout measures the wrong thing and that is a finding.

---

## 7. What to report

Follow `live-qa-handoff.md` §11 exactly — defects graded by user harm with
literal repro steps, what you saw vs expected, reproduction count, and captured
evidence; then what worked well, recommendations, what you could not test, the
latency table, and the checklist verdict.

Three additions specific to this pass:

- **State the microphone tier** you used (real speech, `say` out loud, or a
  virtual device) for every finding. Synthesized audio is cleaner than a human
  and will overstate accuracy — say so where it matters.
- **The Apple Intelligence number goes in its own section**, with the full
  per-category report, so the floor can be re-based from it.
- **Confirm the machine is restored** at the end: hotkey back to `fn`, audio
  devices restored, TCC grants intact, Wi-Fi on, any seeded `defaults` cleared,
  and any deleted models restored or noted as missing.

Write the report to `docs/qa/2026-08-31-air-qa-findings.md`. Do not fix what you
find and do not push — findings only, so the fixes can be reviewed as their own
change.
