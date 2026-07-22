# Changelog

All notable user-facing changes to Skylark. Versions follow
[semver](https://semver.org)-ish `MAJOR.MINOR.PATCH`: MINOR for new features,
PATCH for fixes/polish. Every release bumps `CFBundleShortVersionString` in
`Resources/Info.plist` — the version users see in Settings → Account, where
**Check for Updates** tells them a newer build is on GitHub.

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
