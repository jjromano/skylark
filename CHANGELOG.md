# Changelog

All notable user-facing changes to Skylark. Versions follow
[semver](https://semver.org)-ish `MAJOR.MINOR.PATCH`: MINOR for new features,
PATCH for fixes/polish. Every release bumps `CFBundleShortVersionString` in
`Resources/Info.plist` — the version users see in Settings → Account, where
**Check for Updates** tells them a newer build is on GitHub.

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
