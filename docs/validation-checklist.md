# Skylark validation runbook — MacBook Air (M3, 16 GB)

Everything below needs real hardware (mic, keyboard, screen, TCC prompts) and
could not be exercised on the headless build box. Expected time: ~45 min.
Check items off; anything that fails, note the app + what happened — the
signpost logs (`log stream --predicate 'subsystem == "com.jjromano.skylark"'`)
are the first diagnostic.

## 0. Install (validates Scripts/install.sh end-to-end)
- [ ] `git clone <repo> && cd skylark && ./Scripts/install.sh` — CLT check,
      one explained sudo (signing cert), build, `/Applications` install, launch.
- [ ] Onboarding appears; grant Microphone, Accessibility, Input Monitoring
      via its buttons (deep links land on the right Settings panes).
- [ ] Onboarding auto-advances to "You're set" once all three are granted.
- [ ] Parakeet (~483 MB) downloads with progress in the menu bar; dictation
      unlocks when ready.
- [ ] **TCC persistence:** after everything works, run `make app` again and
      relaunch — permissions must NOT be re-requested (the whole point of the
      cert). If they are, `security find-identity -v -p codesigning` should
      show "Skylark Dev Signing"; report if missing.

## 1. Core dictation (Phase 0/1)
- [ ] Hold Fn in TextEdit, speak a sentence, release → text at cursor.
- [ ] Menu bar "Last: N ms" — **under 300 ms** for a short utterance (this is
      the acceptance bar; record a few values).
- [ ] Short stray Fn tap (<0.3 s) → nothing pastes.
- [ ] Fn+arrow / Fn+F-keys while NOT dictating → normal system behavior
      (media keys etc. unaffected).
- [ ] Bare Fn does NOT trigger the system Globe action (emoji/dictation
      popup) while Skylark runs.
- [ ] ESC mid-dictation cancels; click mid-dictation within the first moment
      discards; pressing another key while holding Fn cancels (chord intent).
- [ ] Double-tap Fn → hands-free recording; stops by itself ~1 s after you
      stop speaking (VAD); double-tap again also stops it.
- [ ] HUD: pill sits centered under the notch; hover expands it without
      flicker; waveform moves with your voice; right-click while recording
      offers Cancel. No drift after switching displays/spaces.

## 2. Injection + clipboard (Phase 0/2 — PRD §10)
- [ ] Copy an image or rich text (e.g. from Preview/Safari). Dictate into a
      paste-fallback app (Terminal is a good candidate). After the paste,
      paste again manually (Cmd-V) somewhere → your ORIGINAL clipboard
      content must come back intact.
- [ ] Dictate into: TextEdit, Safari address bar + a web form, Messages,
      Mail, VS Code, Terminal, Slack/Discord if present. Text lands at the
      cursor in each; note any app where nothing appears.
- [ ] Cleanup replace: with Cleanup=Local and Apple Intelligence ON, dictate
      "um meet me tuesday wait no friday" → raw text appears instantly, then
      swaps in place to "Meet me Friday." within ~a second. Type/click
      elsewhere immediately after the paste → the swap must NOT clobber what
      you did (it aborts silently).

## 3. Local cleanup quality (Phase 2 — needs Apple Intelligence enabled)
- [ ] System Settings → Apple Intelligence & Siri → ON (first model download
      can take a while).
- [ ] Filler removal, self-corrections, question inference ("are you coming
      tomorrow" → "Are you coming tomorrow?"), repeated-word collapse.
- [ ] With Apple Intelligence OFF: dictation still works, raw text stands,
      no errors shown (silent fallback).

## 4. Cloud (Phase 3 — needs your OpenRouter key)
- [ ] Settings → Account: paste key → "Key OK" + remaining credit shows.
- [ ] Speech Engine → Groq Fast Whisper: dictate → correct text (expect
      noticeably higher latency than local).
- [ ] Cleanup → Cloud with Llama 3.1 8B: instant raw paste, cloud-cleaned
      replace. Try the same phrase across 8B/20B/70B via Cleanup Model
      quick-switch (the A/B feature).
- [ ] Turn Wi-Fi OFF with a cloud engine selected → dictation transparently
      uses local + a small notice; nothing hangs. Turn Wi-Fi back on.
- [ ] Remove key (Settings → Account) → cloud entries fall back to local
      with a notice, no crash.

## 5. Engines + audio (Phase 4)
- [ ] Settings → Models: download Whisper (~626 MB); switch Speech Engine to
      Local (Whisper) → dictation works (slower decode is expected). Check
      Activity Monitor memory while switching engines a few times — no
      runaway growth (only the active engine should stay resident).
- [ ] Settings → Audio: pick AirPods → HFP quality warning appears; dictation
      still works. Unplug/disconnect the selected device mid-session → next
      dictation falls back to built-in mic with a notice, no crash.
- [ ] Whisper Mode ON: dictate at a whisper from normal distance → usable
      transcript; HUD dot shows the hollow style. OFF: normal behavior back.

## 6. History + learning (Phase 5)
- [ ] History… shows your dictations; search works; copy works.
- [ ] Edit an entry: fix a name it got wrong → dictionary chip offered →
      accept → dictate the name again → it's now correct (auto-learn loop).
- [ ] Settings → History: enable audio retention → dictate → play button
      appears on the new entry and plays your audio. Delete the row → file
      gone. Disable retention (leave it OFF — the default).
- [ ] Launch at login toggle registers without error (from the installed
      /Applications copy).

## 7. The benchmark that matters (PRD §1)
- [ ] Side-by-side with Wispr Flow on your own phrases: does Skylark feel as
      fast or faster? Record 10 "Last: N ms" values for short/medium
      utterances — median must be < 300 ms.
- [ ] 16 GB memory check: with your normal workload open, Activity Monitor →
      Skylark's memory footprint while idle-but-warm, and no system pressure
      while dictating.

## Known intentional behaviors (don't file as bugs)
- Paste-fallback apps wait up to 2 s for cleanup instead of replacing in
  place (deliberate: select-back is unsafe there).
- If a synthesized paste fails outright, your transcript is left ON the
  clipboard as a fallback (the one case the clipboard isn't restored).
- Cleanup model pin is a soft pin — Groq outages route to other providers.
