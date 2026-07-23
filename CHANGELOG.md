# Changelog

All notable user-facing changes to Skylark. Versions follow
[semver](https://semver.org)-ish `MAJOR.MINOR.PATCH`: MINOR for new features,
PATCH for fixes/polish. Every release bumps `CFBundleShortVersionString` in
`Resources/Info.plist` — the version users see in Settings → Account, where
**Check for Updates** tells them a newer build is on GitHub.

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
