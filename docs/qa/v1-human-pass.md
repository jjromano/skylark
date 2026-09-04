# The 30-minute human pass — the v1.0 gate

Everything an agent can test on Skylark has been tested. This document covers
only what a human must do, because it needs a finger on a key, a hand on a
cable, or a real voice.

**How this is meant to run:** open a Claude Code session on the Air in the repo
and say `Run docs/qa/v1-human-pass.md as my instrument`. It does every
observation — log streaming, database queries, crash-report checks, screenshots
— and tells you what it saw. **You only do the numbered ACT lines.** Do not
watch logs yourself; that is what the agent is for and it is the difference
between this taking 25 minutes and taking two hours.

Six blocks, ~25 minutes. Blocks 1-4 are the v1.0 gate: a failure there stops the
release. Blocks 5-6 are wanted, not gating, so drop them if you run short.

**Setup (agent does this before you start, ~4 min, no input from you):**

```sh
cd ~/dev/projects/skylark && git pull --ff-only && ./Scripts/install.sh
defaults read /Applications/Skylark.app/Contents/Info.plist CFBundleShortVersionString   # expect 0.21.0
```

Agent also: opens a scratch TextEdit window, empties
`~/Library/Logs/DiagnosticReports/` of old `Skylark-*.ips` (note the count
first), starts a log stream, and confirms a USB mic is connected and selected
in Settings → Audio.

---

## Block 1 — Push-to-talk on bare Fn (5 min) — GATING

**Why this block exists:** hold-Fn-and-speak is the primary interaction in the
PRD and **no QA pass has ever exercised it.** Nothing automated can press Fn, so
every pass to date used deep links or a rebound key. This is the single largest
untested surface in the product.

1. **ACT.** Click into the TextEdit window. Hold **Fn**, say
   "the quick brown fox jumps over the lazy dog", release.
2. **ACT.** Hold **Fn**, say a sentence about eight seconds long, release.
3. **ACT.** Hold **Fn**, say one word, release.
4. **ACT.** Hold **Fn**, say nothing at all for three seconds, release.
5. **ACT.** Hold **Fn** and start speaking *before* the pill appears, then
   release. (Catches the race where the first syllable is clipped.)
6. **ACT.** Press and release **Fn** quickly, without speaking.
7. **ACT.** Hold **Fn**, and while holding, press **Fn+Right Arrow**.

**Agent reports:** text landed for 1-3 and 5; 4 produced "No speech detected"
visibly in the pill; 6 did not leave the app stuck recording; 7 did not break
the hold, and End/Home still worked. Median latency across 1-3 against the
300 ms bar, plus the `latency_ms` column for the same rows.

**Fails the gate if:** any hold does not record, the first word is clipped in 5,
the app sticks in recording after 6, or Fn passthrough in 7 is swallowed.

---

## Block 2 — Can you see what the app is telling you? (4 min) — GATING

**Why:** until v0.21.0 every status note in the product was invisible unless the
menu-bar dropdown happened to be open. That is fixed but has never been seen by
a human on real hardware, and the exact strings below were never triggered on
the machine that rendered them.

1. **ACT.** With the dropdown **closed**, dictate one normal sentence into
   TextEdit. Watch the pill under the notch, not the menu bar.
2. **ACT.** Hold Fn and say nothing for three seconds, release. Watch the pill.
3. **ACT.** Read the note out loud to yourself. Does it tell you what happened
   and what to do about it?

**Agent reports:** which note strings were emitted in the log, and whether each
appeared on screen (it will screenshot the pill).

**Fails the gate if:** a note is emitted in the log but nothing appears on
screen, or the pill visibly resizes or flickers when a note arrives.

**You are the judge of:** whether the wording would mean anything to Stephanie.
Say so out loud; the agent will write it down.

---

## Block 3 — The microphone cable (4 min) — GATING

**Why:** the unplug path was fixed but proven only on a machine with no
microphone at all. A physical unplug has never been tested.

1. **ACT.** With the USB mic selected and working, **physically unplug it.**
2. **ACT.** Dictate a sentence.
3. **ACT.** **Plug it back in.** Wait three seconds.
4. **ACT.** Dictate another sentence.
5. **ACT.** Open Settings → Audio and look at the device list.
6. **ACT.** Start dictating, and **unplug the mic mid-sentence.** Release.

**Agent reports:** the note after 1 ("Selected mic unavailable — using the
system default") and after 3 ("Selected mic is back — using <name>"); the
`input device applied: requested <id> engine now <id>` log line and critically
whether it says `MISMATCH`; whether the sentence in 6 kept the words spoken
before the unplug.

**Fails the gate if:** the app crashes, a dictation is lost entirely, or
Settings shows the unplugged mic as active rather than "(unavailable)".

**A `MISMATCH` line is a finding** — it means the audio unit refused the device
and the app does not currently tell you. Tell me if it appears; it decides an
open question about whether that deserves a note.

---

## Block 4 — Quit with the big model loaded (3 min) — GATING

**Why:** quitting after Qwen loaded used to abort the process, and `install.sh`
quits the app before replacing it — so this crash landed mid-upgrade. Fixed, but
it reproduced only intermittently, so one clean quit is not proof.

1. **ACT.** Settings → Models → Cleanup · on device → **Qwen3 4B Instruct**,
   cleanup tier Local. (If it is not downloaded, the agent will have started
   the download during setup.)
2. **ACT.** Dictate once so the model actually loads.
3. **ACT.** Quit Skylark from the menu bar. Relaunch. **Repeat this quit and
   relaunch five times**, dictating once between each.

**Agent reports:** RSS climbing to ~3 GB before each quit (proving the model was
really resident), and the count of new `Skylark-*.ips` files, which must be
zero across all five cycles.

**Fails the gate if:** a single crash report appears.

---

## Block 5 — Real speech (5 min) — wanted, not gating

**Why:** every transcript in every QA report so far is `say` played out loud,
which is cleaner than a human and overstates accuracy. Nobody has measured this
product against an actual voice.

1. **ACT.** Dictate three sentences of your own real work — whatever you would
   actually have said today, at your normal pace, including a pause to think.
2. **ACT.** Dictate one sentence containing two names or bits of jargon from
   your custom dictionary.
3. **ACT.** Dictate "github dot com slash jjromano slash skylark" and
   "j j romano at example dot com".
4. **ACT.** Dictate a sentence with a real thinking pause of about two seconds
   in the middle.
5. **ACT.** Say a sentence and stress one word hard.

**Agent reports:** raw and cleaned text for each, and flags any number that
changed value between them.

**You judge:** was the pause left alone, did the stressed word stay normal, did
the addresses come out whole, and did your dictionary terms land.

---

## Block 6 — Onboarding, as Stephanie meets it (4 min) — wanted, not gating

**Why:** checklist §0 is the section that crashed outright in v0.12.x and it has
never been run since. It needs admin auth, so it cannot be automated.

**Do this one last — it revokes a permission and you must re-grant it.**

1. **ACT.** Quit Skylark. Let the agent run
   `tccutil reset Accessibility com.jjromano.skylark`, then launch the app.
2. **ACT.** Walk the onboarding as if you had never seen it. Grant each
   permission it asks for.
3. **ACT.** Dictate once to confirm you are back to working.

**Agent reports:** whether any crash report appeared during launch, and whether
onboarding auto-advanced to "You're set" once all three grants landed.

**You judge:** whether a non-technical person could complete this alone.

---

## At the end

The agent writes `docs/qa/2026-09-04-v1-human-pass-findings.md` with what it
observed per block, your spoken judgments, and a plain verdict on each of the
four gating blocks. Ask it for a one-paragraph answer to: **is this a v1.0?**
