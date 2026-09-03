# Skylark validation runbook — MacBook Air (M3, 16 GB)

Everything below needs real hardware (mic, keyboard, screen, TCC prompts) and
could not be exercised on the headless build box. Expected time: ~90 min (was
~45; the app roughly tripled in scope since this checklist was last rewritten
2026-07-05, and the 2026-07-31 QA remediation sprint (v0.12.2 → v0.13.0 —
read `CHANGELOG.md`) found several bugs that a checked-off old step would NOT
have caught). Every item below states what to DO, what PASSES, and what
WOULD FAIL — several old steps could be ticked while the bug they were meant
to catch was live, because the step never wrote down a failure signature to
watch for.

## Evidence discipline — read before you start

- **`make test`, never `swift test`.** `swift test` is a silent no-op on this
  CLT-only box: it builds and exits 0 having run nothing. `make test` runs
  the real swift-testing runner (`swift run SkylarkTestRunner --testing-library
  swift-testing`); scope it with `make test TESTFLAGS='--filter <name>'` — a
  bare `make test --filter <name>` is parsed by make itself, prints make's
  help and exits 2 without running the test.
- **The live cleanup eval now fails below baseline**, it doesn't just print:
  `SKYLARK_LIVE_CLEANUP_EVAL=1 make test`. A pass means Skylark's score met or
  beat the recorded baseline, not merely that it ran.
- **The Keychain suite reports a locked keychain as a known issue, not a
  pass.** If `KeychainStoreTests` shows "known issue" output, that means the
  round-trip was never exercised on this run (locked login keychain) — it is
  not evidence the code works, unlock the keychain and re-run for a real
  signal.
- **`Scripts/bench.sh` fails on latency regression vs its checked-in
  baseline** (`Scripts/bench-baseline.tsv`), it doesn't just report numbers.
  A run that exits non-zero is a real regression, not noise — see
  `ARCHITECTURE.md` §8 ("regressions block merge").
- **Synthesized test keystrokes must be posted at the HID level**
  (`CGEvent(..., tap: .cghidEventTap)`); AppleScript `keystroke` is invisible
  to Skylark's event tap and will make a broken hotkey path look fine.
  Useful keycodes: F13 = 105, Esc = 53. Rebind the dictation hotkey to a
  scriptable key for the duration of a test session with:
  `defaults write com.jjromano.skylark hotkey.keyboard -string "f13"` —
  restore it to `"fn"` when done (that key is `HotkeyBinding.defaultsKeyKeyboard`).
- **Logs:** `/usr/bin/log stream --predicate 'subsystem == "com.jjromano.skylark"'
  --level debug` — use the full path; plain `log` is a zsh builtin on this
  shell and resolves to the wrong thing.
- **History:** `sqlite3 ~/Library/Application\ Support/Skylark/skylark.sqlite`.
- **Status notes are visible in the HUD pill (the floating capsule under the
  notch) for 5 s, as well as in the menu-bar dropdown.** When a step below
  says "the note reads …", read it off the pill with the dropdown closed —
  don't open the dropdown to find it, that isn't the surface most users see.

## 0. Onboarding + permissions (the most important section — read this first)

This is the one flow that crashed outright in v0.12.x (P0: AppKit constraint
feedback loop before onboarding could even render), so treat it as gating,
not a formality.

- [ ] **Safe reset recipe — follow this order exactly.** QUIT Skylark first.
      Then `tccutil reset Accessibility com.jjromano.skylark`. Then launch.
      NEVER run `tccutil reset` while Skylark is running — resetting a live
      process's Accessibility grant is the permission-revocation-while-running
      scenario (§21), not an onboarding test, and will exercise a different,
      already-covered code path instead of the one this section is for.
      Pass: the app launches and survives; the onboarding window renders with
      a per-permission Grant button for Microphone, Accessibility, and Input
      Monitoring; no crash report appears in
      `~/Library/Logs/DiagnosticReports` (look for a fresh `.ips` file named
      for Skylark). Fail: the process dies before onboarding paints, or an
      `.ips` file lands with a timestamp matching the launch.
      Note: re-granting Accessibility requires going into System Settings and
      authenticating as admin — the Grant button deep-links you to the right
      pane but the OS still requires the manual toggle + auth.
      Note: a true *never-granted* first run (a machine that has never seen
      `com.jjromano.skylark` in TCC at all) is NOT reproducible by
      `tccutil reset` on a dev machine that's been through onboarding before —
      it stays unverifiable without a fresh machine or a clean VM. Don't claim
      this step covers that case.
- [ ] `git clone <repo> && cd skylark && ./Scripts/install.sh` — CLT check,
      one explained sudo (signing cert), build, `/Applications` install,
      launch. Pass: no unexplained sudo prompts, install completes, app
      launches from `/Applications`.
- [ ] Onboarding auto-advances to "You're set" once Microphone, Accessibility,
      and Input Monitoring are all granted (no manual "Continue" needed).
- [ ] Parakeet (~483 MB) downloads with progress shown in the menu bar;
      dictation unlocks once it's ready.
- [ ] **TCC persistence:** after everything works, run `make app` again and
      relaunch — permissions must NOT be re-requested (the whole point of the
      signing cert). Fail: any permission prompt reappears after a rebuild —
      check `security find-identity -v -p codesigning` for "Skylark Dev
      Signing" and report if missing.

## 1. Core dictation

- [ ] Hold Fn in TextEdit, speak a sentence, release → text at cursor.
- [ ] Menu bar "Last: N ms" — under 300 ms for a short utterance (this is the
      acceptance bar; record a few values).
- [ ] Short stray Fn tap (<0.3 s) → nothing pastes.
- [ ] Fn+arrow / Fn+F-keys while NOT dictating → normal system behavior
      (media keys etc. unaffected).
- [ ] Bare Fn does NOT trigger the system Globe action (emoji/dictation
      popup) while Skylark runs.
- [ ] Press another key while holding Fn → cancels (chord intent); pressing
      Esc mid-recording (key still held or already released, see §5) cancels.
- [ ] HUD: pill sits centered under the notch; hover expands it without
      flicker; waveform moves with your voice (steady ~20 Hz animation, not
      choppy); right-click while recording offers Cancel. No drift after
      switching displays/spaces.
- [ ] **Dictation-while-busy is reported, not silent.** Start a second
      dictation while the first is still processing (fast double Fn-tap into
      a slow cleanup tier). Pass: a note says a dictation was already in
      progress. Fail: the second attempt vanishes with no feedback.

## 2. Hands-free recording + the 120 s cap (regression-prone — test twice)

The v0.12.x/v0.13.0 bug was session-count-dependent: auto-endpointing only
worked for the FIRST hands-free session after launch: every session after
that recorded until manually stopped. A single test cannot catch this.

- [ ] Double-tap Fn → hands-free recording. Speak a sentence, stop talking.
      Pass: the session auto-stops on its own ~1-2 s after you stop speaking
      (VAD endpointing). Fail: it keeps recording with no auto-stop.
- [ ] **Immediately repeat the same test — a second consecutive hands-free
      session.** Pass: it ALSO auto-stops ~1-2 s after speech, same as the
      first. Fail: the second (or any later) session records indefinitely —
      this is the exact bug that shipped and was only found by testing a
      session past the first.
- [ ] Double-tap Fn again mid-recording → manually stops it (should still
      work regardless of the auto-stop bug above).
- [ ] **120 s cap.** Start hands-free and keep speaking past 2 minutes (play
      >2 min of continuous speech/audio). Pass: the pill shows an amber
      countdown starting ~100 s in (last ~20 s); the session finalizes AT the
      2-minute mark with the note "Reached the 2-minute recording limit —
      transcribed what fit"; the resulting transcript covers roughly the
      first ~120 s of what you said. Fail: any wording about a microphone
      interruption or a stall/stuck-mic condition appears instead — that
      phrasing means the cap silently discarded the audio and mis-blamed the
      microphone (the old bug), not a clean cap-triggered finalize.

## 3. Cancel

- [ ] Esc while the key is still held / during active recording → cancels
      immediately, nothing pastes, nothing saved to History.
- [ ] **Cancel during processing (deep link).** Release the hotkey to enter
      Processing, then immediately fire `open skylark://record/cancel`. The
      local pipeline finishes in ~180 ms while the deep link takes ~300 ms to
      arrive, so on a fast local engine the cancel will usually land AFTER
      the write — that's expected, not a bug. Pass: EITHER no History row +
      log shows "dictation cancelled during <stage>" (stage being whatever
      pipeline step was in flight — transcription or cleanup) + nothing
      typed anywhere, OR the text stays as pasted and the note "Too late to
      cancel — text already inserted" appears in the pill and the dropdown.
      Fail: silence — text landed and no note at all — which means neither
      path fired.
- [ ] **Esc during processing needs a human.** Esc is a much lower-latency
      path than the deep link and can land inside the ~100 ms cancel window
      where a deep link cannot; the deep-link test above can't prove this
      case, so also fire Esc immediately on release and confirm it cancels
      (no History row, "dictation cancelled during <stage>" in the log,
      nothing typed).
- [ ] **Too-late cancel (well past the write).** Fire the cancel deep link
      more than 2 s after the text has already landed at the cursor. Pass:
      nothing is undone (text stays as pasted), nothing is shown by design,
      and the log reads "cancel ignored — nothing in progress". Fail: a note
      appears, or the already-pasted text gets clobbered.

## 4. Focus guard + press-Enter safety

- [ ] **Same-app, different-window switch mid-dictation.** Open two TextEdit
      documents. Start dictating in one, then Cmd-` (or click) to switch to
      the OTHER TextEdit window before text lands. Pass: nothing is written
      to either window, a note says the transcript was kept in History, log
      shows "focus guard: write refused — reason=window-changed". Fail: text
      lands in the wrong TextEdit window (the bug: the old guard only checked
      the front app, not window identity, so same-app window switches slipped
      through).
- [ ] **Cross-app switch mid-dictation** (different behavior, by design):
      start dictating in TextEdit, switch to Safari before text lands. Pass:
      Skylark re-activates TextEdit and pastes into the original window/app —
      this is intentional and unchanged, don't file it as the bug above.
- [ ] **Press-Enter test — DRAFT-ONLY targets, never a live send surface.**
      The "press Return after paste" option can literally SEND a message if
      tested in the wrong place. Use a TextEdit document or a draft/unsent
      compose window only (e.g. an unsent Mail draft, NOT Messages, Mail with
      a real recipient loaded, or Slack — any app where Return submits).
      Pass: after paste, Return fires only once the pasted text is confirmed
      landed (the target actually read the clipboard), and only in the
      still-focused, still-correct window.

## 5. Clipboard restore (PRD §10)

- [ ] Copy an image or rich text (e.g. from Preview/Safari). Dictate into
      **Terminal running `cat > /tmp/skylark-paste.txt`** — a bare shell
      prompt can itself accept AX insertion, so `cat >` waiting on stdin is
      the target that actually forces the clipboard path to run. TextEdit is
      NOT a valid target for this step: it takes AX insertion and the
      clipboard path never runs there. Check the log for that dictation: it
      must show `inject: paste` and `clipboard restored:` — if it shows
      `inject: ax`, the step tested nothing and must be redone. After the
      paste, paste again manually (Cmd-V) somewhere → your ORIGINAL
      clipboard content must come back intact.
- [ ] **Restore-vs-new-copy race (the v0.13.0 fix).** Dictate into a paste
      target (Terminal works), and the INSTANT the paste lands, copy
      something new (Cmd-C a different piece of text) before Skylark's
      restore fires. Pass: your new copy survives — paste it back (Cmd-V) and
      confirm it's what you just copied, not the pre-dictation clipboard; log
      shows "clipboard restore skipped: another writer took the pasteboard".
      Fail: the restore silently overwrites your new copy with the
      pre-dictation clipboard contents — this is exactly the bug the old
      checklist's clipboard step passed WHILE it was live, because the step
      never copied anything new after the paste to catch the stomp.
- [ ] Dictate into: TextEdit, Safari address bar + a web form, Messages, Mail,
      VS Code, Terminal, Slack/Discord if present. Text lands at the cursor in
      each; note any app where nothing appears.
- [ ] Cleanup replace: with Cleanup=Local and Apple Intelligence ON, dictate
      "um meet me tuesday wait no friday" → raw text appears instantly, then
      swaps in place to "Meet me Friday." within ~a second. Type/click
      elsewhere immediately after the paste → the swap must NOT clobber what
      you did (it aborts silently — this is separate from, and in addition
      to, the focus-guard window check in §4).

## 6. Deep link (skylark://record/start)

- [ ] With another app frontmost (not Skylark), fire
      `open skylark://record/start`, speak, let it finish. Pass: the text
      lands in THAT frontmost app, and the resulting History row's app_name
      is that app — never "Skylark" itself. Fail: text pastes into Skylark's
      own window, or History attributes the dictation to Skylark (the
      v0.13.0 bug — affects Shortcuts/Stream Deck-triggered dictation).

## 7. Local cleanup quality (needs Apple Intelligence enabled)

- [ ] System Settings → Apple Intelligence & Siri → ON (first model download
      can take a while).
- [ ] Filler removal, self-corrections, question inference ("are you coming
      tomorrow" → "Are you coming tomorrow?"), repeated-word collapse.
- [ ] With Apple Intelligence OFF: dictation still works, raw text stands, no
      errors shown (silent fallback).

## 8. Cloud (needs your OpenRouter key)

Model names below are the CURRENT registry — the old checklist named
retired Groq/Llama models; don't chase those.

- [ ] Settings → Account: paste key → "Key OK" + remaining credit shows.
- [ ] Speech Engine → cloud STT (`openai/whisper-large-v3-turbo`): dictate →
      correct text (expect noticeably higher latency than local).
- [ ] Cleanup → Cloud with `openai/gpt-oss-20b`: instant raw paste, cloud-
      cleaned replace. Try the quick-switch (A/B) between available cloud
      cleanup models from the registry.
- [ ] Turn Wi-Fi OFF with a cloud engine selected → dictation transparently
      uses local + a small notice; nothing hangs. Turn Wi-Fi back on.
- [ ] Remove key (Settings → Account) → cloud entries fall back to local with
      a notice, no crash.
- [ ] **Cloud dictionary filter — content-minimization check.** With a
      dictionary populated and Cleanup=Cloud, dictate a sentence that
      matches NONE of your dictionary terms. Pass: log shows "cloud
      dictionary filter — sent: 0 of N" (N = your dictionary size) — no
      terms uploaded when none are relevant. Then dictate a sentence that
      DOES approximate a dictionary term; pass: the sent count is > 0 and
      less than N (only the relevant subset went out, not the whole list).
      Fail: the full dictionary is sent regardless of relevance (the old
      privacy bug this release fixed).

## 9. Dictionary + deep vocabulary

Deep vocabulary shipped a real corruption bug in v0.12.x (unrelated words
silently replaced by dictionary terms, e.g. "The meeting starts" →
"CLAUDE.md" at a 0.06 similarity score) and was force-disabled, then fixed
and re-enabled by default in v0.12.3. Test both the regression and the
positive case — checking only the positive case is how the old checklist
missed this class of bug.

- [ ] **Corruption regression.** Turn deep vocabulary ON. Dictate a plain
      sentence containing NONE of your dictionary terms. Pass: the
      transcript comes back clean/unchanged — no dictionary term appears
      anywhere in it. Also run the eval harness:
      `SKYLARK_LIVE_DEEPVOCAB_EVAL=1 SKYLARK_DEEPVOCAB_CLIP=<path-to-clip>
      make test` — pass means 0 replacements reported on a clip with no
      matching terms. Fail: any dictionary term appears in text that didn't
      warrant it, at any similarity score.
- [ ] **Positive case.** Speak a phrase using a misspelling/alias you've
      listed in the dictionary (e.g. say "cloud dot m d" for an alias
      mapping to "CLAUDE.md"). Pass: it comes back corrected to the
      canonical term.
- [ ] If you were running with deep vocabulary silently force-disabled by the
      v0.12.2 kill switch, confirm the one-time re-enable notice appeared and
      the feature is back on.

## 10. Engines + audio

- [ ] Settings → Models: download Whisper (~626 MB); switch Speech Engine to
      Local (Whisper) → dictation works (slower decode is expected). Check
      Activity Monitor memory while switching engines a few times — no
      runaway growth (only the active engine should stay resident).
- [ ] **Engine switch mid-session applies at the next idle moment, not
      mid-flight.** Start a dictation on one engine, and while it's still
      transcribing, switch Speech Engine in Settings. Pass: the in-flight
      dictation completes normally on the engine it started with; the new
      engine only takes effect on the NEXT dictation. Fail: the switch tears
      down the model mid-transcription (dropped/garbled result) or a stale
      cloud response lands after you'd already switched back to local
      (implying audio was uploaded after the switch).
- [ ] Settings → Audio: pick AirPods → HFP quality warning appears; dictation
      still works. Unplug/disconnect the selected device mid-session → next
      dictation falls back to built-in mic with a notice, no crash.
- [ ] Whisper Mode ON: dictate at a whisper from normal distance → usable
      transcript; HUD dot shows the hollow style. OFF: normal behavior back.
- [ ] **Capture-interruption recovery.** Trigger a genuine audio interruption
      mid-recording (e.g. an incoming call on a paired device, or force a
      brief route change). Pass: the session finalizes cleanly at the
      interruption boundary (or recovers, if a brief stall) — no false
      "microphone capture failed" for a real transient hiccup, and no lost
      audio between the interruption and the recovery/finalize. Fail: the
      session hangs, or the hotkey processor is left holding a stale
      double-tap lock that eats your next Fn press (this shipped and was
      fixed alongside the endpointing bug in v0.13.0).
- [ ] **Failed mic start says so and doesn't leak.** If you can force a mic
      start failure (device busy in another app), pass: the note reads
      "Microphone capture failed" and a subsequent normal dictation works
      (no leaked audio tap holding the device).

## 11. VAD trim toggle

- [ ] Settings → toggle VAD trim OFF: dictate with a couple seconds of
      silence before/after speech → the raw clip (and transcript) may include
      the silence padding; no trimming applied.
- [ ] Toggle VAD trim ON: same test → leading/trailing silence is trimmed
      from the finalized clip, but quiet speech near the start/end of your
      utterance is preserved (not clipped away) — mumble the first and last
      word of a sentence and confirm both survive.

## 12. Local cleanup model management (Qwen)

- [ ] Settings → Models → download a Qwen cleanup model (llama.cpp-backed
      local cleanup). Progress shows; once complete, select it as the active
      local cleanup model and confirm cleaned output actually differs from
      raw (i.e. it's really running, not silently falling through).
- [ ] **Download validates before replacing.** If you can interrupt a model
      re-download or update (kill network mid-download, or re-trigger a
      download and cancel partway), pass: your previously-working model is
      left untouched and still functions — the new download is staged,
      SHA-256-verified, and only swapped in atomically on full success. Fail:
      a partial/corrupt download replaces the working model, or cleanup
      breaks after an interrupted update.

## 13. Command Mode

- [ ] Trigger Command Mode (its configured hotkey/mode), select some text in
      a document first, then speak a command that acts on the selection
      (e.g. rewrite/shorten). Pass: the selection is transformed correctly.
- [ ] **Selection-changed safety.** Start a Command Mode dictation with text
      selected, then change the selection (click elsewhere, select different
      text) before the command result comes back. Pass: NOTHING is
      overwritten, and a note reads "Selection changed — command result not
      applied". Fail: the command result gets written over the new
      selection or the wrong location — the transcript should be safely
      discarded/kept in History instead.

## 14. Snippets

- [ ] Define a snippet (short phrase → expansion) in Settings. Dictate the
      trigger phrase → the expansion is what gets inserted, not the literal
      spoken words.
- [ ] A dictation that does NOT match any snippet trigger → passes through
      unchanged (no false-positive expansion).

## 15. Translation

- [ ] Enable translation to a target language different from what you speak.
      Dictate in your normal language → inserted text is translated. Confirm
      it doesn't silently fall back to untranslated raw text without a
      notice if translation fails.

## 16. Per-app modes (incl. per-mode Whisper Mode override)

- [ ] Configure a mode scoped to a specific app (e.g. a "Slack" mode with its
      own cleanup/dictionary settings) and confirm dictating in that app uses
      the mode's settings, while dictating elsewhere uses the default/global
      mode.
- [ ] **Per-mode Whisper Mode override — three states.** Each mode has an
      override with three values: Follow Global, On, Off. With the global
      Whisper Mode toggle OFF, set one mode's override to On → dictating in
      that mode's app behaves as if Whisper Mode is on (hollow HUD dot) even
      though the global switch is off. Set another mode's override to Off
      while global is ON → that mode dictates normally (not whisper-tuned)
      despite the global switch. Leave a third mode on Follow Global → it
      tracks whatever the global toggle currently says. Fail: any mode's
      behavior doesn't match its own override setting, or Follow Global
      modes fail to track a live change to the global toggle.

## 17. Diagnostics export

- [ ] Settings → export diagnostics. Pass: a file is produced; open it and
      confirm it contains NO transcript text and no raw audio — logs/config/
      state only. Fail: any dictated content (words you spoke, or text that
      was pasted) appears anywhere in the export.

## 18. Update check

- [ ] Settings → Account → Check for Updates, with no update pending →
      reports up to date, no background/automatic check happens on its own
      (only fires when you click the button). Pass: nothing happens on
      launch or in the background without you initiating it. Fail: an update
      check fires automatically at launch or on a timer.

## 19. Correction watcher / auto-learn (History)

- [ ] History… shows your dictations; search works; copy works.
- [ ] Edit an entry: fix a name it got wrong → dictionary chip offered →
      accept → dictate the name again → it's now correct (auto-learn loop).
- [ ] Settings → History: enable audio retention → dictate → play button
      appears on the new entry and plays your audio. Delete the row → file
      gone. Disable retention (leave it OFF — the default).
- [ ] Launch at login toggle registers without error (from the installed
      /Applications copy) and reflects the actual LaunchAgent/SMAppService
      state, not just the switch position.

## 20. Cleanup cycle hotkey (new — PRD §7, previously unimplemented)

- [ ] Settings → bind the optional "cycle cleanup model" hotkey (default is
      unbound — you must set one to test this). Press it a few times in a
      row without dictating. Pass: each press advances to the next cleanup
      option in the ring and the menu bar shows a note naming the new
      selection (e.g. "Cleanup: Qwen3 4B Instruct"); the NEXT dictation uses
      whatever the cycle last landed on.

## 21. Permission revocation while running

**Safe order only — do NOT approach this with the old checklist's
expectations; a live revocation used to wedge recording or the whole Mac.**
Do this test with Skylark already past onboarding and idle or mid-dictation,
not as a substitute for the §0 fresh-onboarding flow.

- [ ] With Skylark running and idle, revoke Accessibility (System Settings →
      Privacy & Security → Accessibility → toggle Skylark off) — NOT via
      `tccutil reset` while running, use the System Settings toggle. If
      currently mid-recording when you do this: pass = the session finalizes
      cleanly at the revocation boundary (transcript saved to History), the
      mic is released, the HUD returns to idle, and a note names
      Accessibility and points at the Settings pane to re-grant. Fail: the
      app hangs, recording gets stuck, or the Mac becomes unresponsive (the
      old bug — the event-tap recovery loop used to retry forever every
      60 s instead of giving up loudly after bounded retries).
- [ ] Re-grant Accessibility via System Settings (admin auth required) and
      confirm dictation resumes working without a relaunch, or note if a
      relaunch is required and file that as a finding.

## 22. The benchmark that matters

- [ ] Side-by-side with Wispr Flow on your own phrases: does Skylark feel as
      fast or faster? Record 10 "Last: N ms" values for short/medium
      utterances — median must be < 300 ms.
- [ ] 16 GB memory check: with your normal workload open, Activity Monitor →
      Skylark's memory footprint while idle-but-warm, and no system pressure
      while dictating.
- [ ] `Scripts/bench.sh` run — pass means it exits 0 (no regression vs
      `Scripts/bench-baseline.tsv`); a non-zero exit is a real latency
      regression, not noise (see Evidence discipline above).

## Known intentional behaviors (don't file as bugs)

- Paste-fallback apps wait up to 2 s for cleanup instead of replacing in
  place (deliberate: select-back is unsafe there).
- If a synthesized paste fails outright, your transcript is left ON the
  clipboard as a fallback (the one case the clipboard isn't restored).
- Cleanup model pin is a soft pin — provider outages route to other
  providers.
- Cross-app focus switches mid-dictation re-activate the original app and
  paste there (§4) — this is different from, and not the same bug as, the
  same-app window-switch case above it.
