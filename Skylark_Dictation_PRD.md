# Skylark — Product Requirements Document

**Working title:** Skylark (rename at will)
**Owner:** JJ
**Shared with:** a second, non-technical user (must run for them with their own credentials)
**Target platform:** macOS (Apple Silicon), primary device MacBook Air M3, 16GB RAM
**Document status:** Final, ready for handoff to Claude Fable
**Primary product goal:** A personal, open-source Mac dictation app that matches the best features of Wispr Flow and superwhisper, with lower latency, running fully local by default and cloud-capable on demand. Latency is the highest-priority attribute.

---

## 0. How to build this (orchestration protocol)

This project is built by Claude Fable acting as an **orchestrator**, not as the primary code author. The intent is to conserve the limited Claude Fable token budget by keeping Fable focused on architecture, decomposition, review, and judgment, while delegating the bulk of code generation to Opus and Sonnet subagents whose context does not draw down the Fable session budget.

**Fable (orchestrator) responsibilities:**
- Read this PRD, produce the system architecture, and maintain the task breakdown.
- Write precise implementation specs for each unit of work, then hand each spec to a subagent.
- Review returned diffs, integrate them, resolve conflicts, and make design decisions.
- Own anything requiring taste or judgment: latency tradeoffs, UX behavior, API surface, data model.
- Keep its own context lean. Fable should avoid pasting large source files into its own context; it reads summaries and diffs, and lets subagents hold the heavy file content.

**Subagent roles** (define these in `.claude/agents/`; verify current Claude Code subagent syntax before implementing, since it changes between releases):
- `opus-implementer` (model: Opus). Use for the hard, architecturally sensitive code: the real-time audio pipeline, voice-activity detection and endpointing, transducer streaming integration, the Accessibility-based text injection and clipboard-preservation layer, the notch HUD, and concurrency or memory-pressure work.
- `sonnet-implementer` (model: Sonnet). Use for routine, high-volume code: SwiftUI settings views, the model registry and switcher UI, the model download manager, the local data layer, serialization, boilerplate, unit tests, and mechanical refactors.

**Delegation rule of thumb:** if the task is "wire a known pattern into a view or a store," send it to Sonnet. If the task is "make audio-to-text feel instant without dropping words," send it to Opus. Fable decides, specs it, and reviews it.

**Budget discipline:** Fable should batch decisions, avoid re-reading unchanged files, and prefer delegating a whole vertical slice with one clear spec over many small back-and-forth turns. Each subagent task should be self-contained enough to complete without returning to Fable mid-task.

---

## 1. Why this exists

The reference apps are Wispr Flow (loved for accuracy plus AI cleanup at very low latency) and superwhisper (loved for its minimal notch UI). Skylark should feel at least as snappy as Wispr Flow while running local-first, remove the subscription, and be a clean open-source project two people can run.

**Guiding principle:** latency is the product. Every architectural decision is judged first by the time between "I stop speaking" and "clean text appears at my cursor." Features that add latency must be optional and, where they add a round-trip, must not block the initial paste.

---

## 2. Scope

**Build v1 only.** The v1 feature set below is the deliverable. Phase 2 items are recorded in the Appendix for reference and are explicitly out of scope for this build.

---

## 3. Target environment

- **Hardware:** MacBook Air M3, 16GB unified memory, Apple Silicon Neural Engine. Must also run acceptably on a second user's Mac (assume comparable Apple Silicon).
- **OS:** current macOS (assume macOS 15 or later; confirm during build).
- **Network:** cloud features require internet; local mode must be fully functional offline.
- **Credentials:** each user supplies their own OpenRouter API key. Keys are per-user, stored in the macOS Keychain, never committed and never shared between users.
- **Distribution:** open-source, personal use. No App Store submission assumed; a local signed build is acceptable. This avoids sandbox limits that would block system-wide dictation.

---

## 4. Repository, licensing, and distribution

Skylark must ship as a clean, shareable open-source project that a second, non-technical user and other people can set up.

- **Version control:** initialize a Git repository from the first commit. Conventional structure, meaningful commit history, no secrets ever committed.
- **License:** MIT. This keeps the project freely shareable and lets Skylark borrow from MIT-licensed references (see Section 5). Do not paste GPL-licensed code (for example from VoiceInk) into the repo, since that would force the whole project to GPL.
- **README:** clear setup and build instructions, permissions walkthrough (Microphone, Accessibility, Input Monitoring), and a short "add your OpenRouter key" step. Assume a reader who is comfortable installing a Mac app but is not the author.
- **Configuration:** no hardcoded keys or user-specific paths. All secrets come from the Keychain via an in-app onboarding screen. Any non-secret config ships as sane defaults overridable in Settings.
- **Multi-user:** the app must work for a fresh user with their own Keychain entry and their own local model downloads, with zero dependence on the author's machine state.
- **Build reproducibility:** document exact toolchain and dependency versions so another person can build from source.

---

## 5. Open-source references and build-vs-borrow

Skylark is an original codebase, but it should reuse solved sub-problems from existing projects rather than re-deriving them. Recommended approach: build our own app to match this spec, and reference the projects below for the hard parts (engine integration, text injection, VAD, permissions, hotkeys).

- **VoiceInk** (native Swift; whisper.cpp + FluidAudio; app-detection modes). Closest architectural match and validation of our engine stack. License is GPL v3, so study its architecture for reference only and do not copy its code into this MIT repo.
- **Hex** (MIT, Swift, Apple Silicon; FluidAudio + WhisperKit). Best code-level Swift reference; MIT allows reuse.
- **Handy** (MIT, Rust; Silero VAD, global hotkey, push-to-talk vs toggle, text injection). Mature reference for the interaction plumbing; patterns translate even though it is Rust.
- **OpenWhispr** (MIT; local Parakeet/Whisper + BYOK cloud). Reference for dictionary auto-learn-from-corrections and BYOK cleanup patterns.

Rationale for building our own rather than forking: Skylark's spec includes specifics (the notch HUD, the in-app model quick-switcher, clipboard preservation, OpenRouter cleanup pinned to Groq, and the Fable-orchestrated build) that make a clean build cheaper than retrofitting another app's architecture, while still borrowing MIT-licensed solutions for the genuinely hard, already-solved pieces.

---

## 6. Operating modes

Two transcription modes plus a cleanup layer, switchable per profile and via hotkey.

### 6.1 Local mode (default)
Fully on-device. No audio and no text leaves the machine. Default and latency-optimized.

- **Primary engine:** NVIDIA Parakeet TDT 0.6B v3 via **FluidAudio** (Swift, CoreML, Neural Engine). Chosen for sub-100ms transcription, tiny runtime memory footprint, native Swift with no Python daemon, and transducer architecture that streams interim results. This is why Skylark can feel faster than Whisper-based competitors.
- **Fallback engine:** Whisper large-v3-turbo via **WhisperKit** (CoreML, Neural Engine). Available for robustness on noisy or accented audio. English is the primary language; multilingual is not a v1 requirement.
- **Model residency:** keep the active local model warm and resident so the first utterance after a hotkey press has no cold-start penalty.

### 6.2 Cloud mode
For higher accuracy on hard audio and as a fallback when local hardware underperforms. Cloud STT is not the latency winner, so its role is accuracy and model choice.

- **Transport:** OpenRouter's transcription endpoint `POST /api/v1/audio/transcriptions`. Single key, unified interface. It accepts a base64 audio clip and returns text with a 60-second timeout, which fits push-to-talk.
- **Both cloud STT models must be in the build and user-selectable:** Groq fast Whisper (lowest cloud latency) and GPT-4o Transcribe (highest accuracy). Pass the optional English language hint.
- **Fallback:** if cloud is selected but unavailable or times out, transparently fall back to the local engine with a small non-blocking notice.

### 6.3 AI cleanup (default ON, with a raw option)
Cleanup runs after transcription on either local or cloud transcripts. Three tiers:

- **Tier 0, raw (no cleanup).** Pastes the transcript verbatim as you speak. Zero added latency. Available as a dedicated mode and hotkey.
- **Tier 1, local cleanup (default).** A small on-device model (Apple Foundation Models on this M3, or a small local model) performs the default light pass: remove filler and self-corrections, collapse repeated words, infer sentence type and add correct terminal punctuation including question marks, fix capitalization. Offline, no cost, a few hundred ms.
- **Tier 2, cloud cleanup.** For stronger Wispr-grade rewriting, a fast small cloud model via OpenRouter (see Section 7). One-click switch from Tier 1.

**Default cleanup behavior spec:** handle self-corrections ("meet Tuesday, wait no, Friday" becomes "meet Friday"), remove filler words and duplicated words, auto-punctuate including inferring questions, fix capitalization, and lightly match the register of the target app.

**Latency contract:** paste the raw transcript first, then replace it in place with the cleaned version, so the user never waits on the cleanup model to see text.

---

## 7. Model selection and quick-switch

Because the user wants to A/B cleanup models easily, model switching is a first-class feature, not a buried setting.

- **Model registry:** a list of entries `{label, openrouter_slug, provider_pin, kind}` where kind is `stt` or `cleanup`. Seed it with the cleanup candidates (for example Llama 3.1 8B, GPT-OSS 20B, Llama 3.3 70B on Groq) and the two cloud STT models.
- **Quick-switch:** a menu-bar dropdown and an optional cycle hotkey to change the active cleanup model on the fly, so the same phrase can be re-run across models for comparison without opening Settings.
- **Free-text slug:** allow entering any OpenRouter model slug to try it immediately.
- **Provider pinning:** pin cloud requests to the fast provider (Groq) and enable the fastest-provider routing option, so switching models never silently routes to a slow backend. OpenRouter's own routing overhead is negligible (roughly 25 to 40ms), so the model and provider choice, not the router, governs latency.
- **Per-mode model:** each mode may specify its own cleanup model; otherwise it uses the global default.

---

## 8. Feature requirements (v1)

### Core dictation
- System-wide dictation: press a global hotkey, speak, clean text lands at the cursor in any app.
- Global hotkey defaulting to **Fn**, push-to-talk (hold to record, release to paste) as primary, plus a hands-free toggle (double-tap to start/stop). Confirm bare-Fn can be bound on macOS; if not, fall back to a combo such as Option+Space and keep Fn as the documented target.
- Voice Activity Detection and endpointing so hands-free mode auto-stops on silence.

### Accuracy and personalization
- **Custom dictionary** for names, acronyms, and jargon. Manual entries plus **auto-add when the user corrects a transcription**. Implemented as recognition biasing plus a post-transcription correction map.
- **App-aware modes:** detect the frontmost application and auto-select the matching mode (engine, cleanup tier, model, formatting rules). This is the tone/context adaptation behavior.
- **Whisper Mode:** a mode for quiet, whispered speech in shared spaces. Boosts input gain and tunes VAD for low-amplitude audio. Accept a modest accuracy tradeoff at whisper volume.

### Audio input
- **Input device selection** in Settings.
- **Bluetooth warning:** when a Bluetooth hands-free (HFP) input such as AirPods is selected, surface a gentle notice that it degrades recognition quality and suggest the built-in or a wired/USB mic. (Rationale: activating a Bluetooth earbud mic forces macOS into the low-quality HFP profile.)

### History
- Local, searchable history of past dictations (text). Audio retention OFF by default; if the user opts in, store audio locally only.

---

## 9. UI/UX: notch HUD

Mimic superwhisper's minimal notch-adjacent recorder, with clearly defined states. The HUD is a small floating pill centered at the top of the screen, tucked just beneath the camera notch. A menu-bar item provides Settings, History, and quit.

**States:**
1. **Idle / collapsed.** A thin, unobtrusive rounded pill beneath the notch, with a small color-coded status dot. Minimal footprint, always available.
2. **Hover (not recording).** On mouse-over, the pill expands to reveal controls: an AI/mode control (the current mode), a center record control, and an expand control that opens the main window. Match the layout and feel of the reference screenshots.
3. **Active listening (recording).** The pill expands slightly and shows an animated audio **waveform** driven by live mic input, giving real-time feedback that audio is being captured. Hovering during recording reveals a stop control. A right-click context menu offers cancel and open-history.
4. **Processing.** After stop, show a brief processing indicator before text is inserted. In streaming local mode, interim words may appear live.

**Behavior details:** the HUD stays clamped to the screen edge and does not drift off-screen; it has a stable placeholder waveform in the ready state to avoid layout popping; state transitions are quick and quiet. The status dot color reflects idle, listening, and processing.

---

## 10. Text injection and clipboard preservation

The app must insert text without disturbing the user's clipboard. This is an explicit requirement, since many dictation apps clobber the clipboard by pasting through it.

- **Primary path:** insert text directly at the cursor via the Accessibility API, which does not touch the clipboard at all.
- **Fallback path:** for apps that resist direct insertion and require a synthesized paste, the app must snapshot the full `NSPasteboard` contents (all types and items, not just plain string), perform the paste, then restore the original contents after the paste completes. Handle timing so the restore does not race the paste.
- **Verification:** include a test that copies known content to the clipboard, runs a dictation into a paste-fallback target, and asserts the clipboard is byte-for-byte unchanged afterward.

---

## 11. Technical architecture

**Implementation:** native Swift and SwiftUI, packaged as a menu-bar (LSUIElement) macOS app with the notch HUD as a floating panel. Native is required for low-latency audio, global hotkeys, Neural Engine model execution, and Accessibility text insertion.

**Components:**
- **Hotkey and lifecycle:** global event tap for push-to-talk and toggle; menu-bar item; permissions onboarding (Microphone, Accessibility, Input Monitoring).
- **Audio capture:** AVAudioEngine capture with a ring buffer and VAD. Opus-tier.
- **STT abstraction:** a `Transcriber` protocol with implementations `FluidAudioParakeet`, `WhisperKitWhisper`, and `OpenRouterCloud`. The app targets the protocol, never a concrete engine.
- **Cleanup abstraction:** a `Cleaner` protocol with `RawPassthrough`, `LocalCleaner` (Apple Foundation Models or small local model), and `OpenRouterCleaner`. Model chosen from the registry.
- **Text pipeline:** transcript, optional voice-command parsing, optional cleanup, injection. Each stage is skippable for latency.
- **Injection layer:** Accessibility insertion with clipboard-preserving paste fallback. Opus-tier.
- **Notch HUD:** floating panel with the state machine in Section 9. Opus-tier.
- **Persistence:** local store (Core Data or SQLite) for history, modes, dictionary, and settings.
- **Credentials:** OpenRouter key in the macOS Keychain, entered via onboarding. Never plaintext on disk.

**Key dependencies to evaluate first:** FluidAudio (Parakeet on Neural Engine), WhisperKit (Whisper on Neural Engine), a Silero-class VAD if the engines do not endpoint well on their own.

---

## 12. Non-functional requirements

- **Latency targets (local, short utterance):** end-of-speech to pasted raw text under 300ms; streaming interim tokens under 150ms where implemented. This is the acceptance bar for "as snappy as Wispr Flow."
- **Memory:** comfortable headroom on a 16GB machine running the user's normal workload. Use FluidAudio's Neural Engine path to keep runtime memory small; avoid the Python MLX path.
- **Offline:** local mode plus Tier 0/Tier 1 cleanup must work with the network disabled.
- **Privacy defaults:** no audio saved, no network, no telemetry in local mode. Cloud calls only when a cloud engine or cloud cleanup is selected. Clipboard left intact (Section 10).
- **Reliability:** if any optional stage fails, the user still gets usable text. An optional feature never blocks the core paste.

---

## 13. Build plan (v1)

Each phase is a shippable increment. Fable specs each into subagent tasks.

- **Phase 0, skeleton.** Menu-bar app, permissions onboarding, global Fn push-to-talk, audio capture, notch HUD idle/hover states, and Accessibility paste with a stub transcriber. Proves end-to-end plumbing and clipboard preservation.
- **Phase 1, local Parakeet MVP.** FluidAudio + Parakeet v3, push-to-talk, instant raw paste, active-listening waveform state. Latency-defining milestone; benchmark against Wispr Flow on the user's own phrases.
- **Phase 2, cleanup + dictionary.** Tier 0/1/2 cleanup with default light cleanup and self-correction handling, custom dictionary with auto-add, app-aware mode selection.
- **Phase 3, models + cloud.** Model registry and quick-switch, OpenRouter cleanup pinned to Groq, both cloud STT models, Keychain onboarding, offline fallback.
- **Phase 4, engines + audio.** WhisperKit fallback, model download manager, input device picker with Bluetooth warning, Whisper Mode.
- **Phase 5, history + polish.** Searchable local history, settings polish, README and build docs, privacy hardening, MIT license and repo cleanup for sharing.

---

## 14. Open decisions (resolved defaults)

1. **Language:** English primary. Parakeet default, Whisper available. Resolved.
2. **Cloud STT:** both Groq fast Whisper and GPT-4o Transcribe in the build, user-selectable. Resolved.
3. **Cleanup:** default ON, Tier 1 local as the default with one-click Tier 2 cloud; Tier 0 raw always available. Resolved.
4. **Cleanup model default:** a fast Groq model (start with Llama 3.1 8B) with easy in-app switching to 20B and 70B. Resolved.
5. **Distribution:** open-source MIT repo, personal use, local signed build, runnable by a second non-technical user. Resolved.

---

## 15. Appendix

### A. Phase 2 backlog (tracked, out of scope for v1)
- Snippets / voice macros (trigger phrase inserts a text block). **Shipped in v0.1.0** (2026-07-09, first complete release), listed in CHANGELOG.md as "Snippets (spoken triggers)".
- Command Mode (highlight text, speak an edit instruction, rewrite the selection in place). **Shipped in v0.7.0** (2026-07-22) as "Voice command mode": bind a second shortcut, hold it, speak an instruction to rewrite the selection or generate text at the cursor.
- Text shortcuts (for example "btw" expands to "by the way"). Satisfied by the Snippets feature above (spoken trigger phrase, not a typed one), also shipped in v0.1.0.
- User-defined custom mode prompts UI. **Shipped in v0.15.0** (2026-08-01) as
  Settings → Modes → Custom instruction: a per-mode free-text instruction, capped
  at 500 characters, appended to the standard cleanup rules rather than replacing
  them (the faithfulness guard still judges the output). This closes Appendix A.

### B. Explicitly skipped (not planned)
- Cross-device sync, wake word, scratchpad, team/shared features, deep IDE integrations (file tagging, variable recognition): still not planned.
- 100+ languages and translation: partially reversed. **Translation mode shipped in v0.7.0** (2026-07-22, opt-in): dictate in one language, paste in another, covering 9 languages, well short of "100+". Cloud models translate best; on-device handles European languages; a failed translation falls back to the original words.
- Gamified stats: partially reversed. **Insights shipped in v0.1.0** (2026-07-09): words dictated, WPM, time saved, streaks, per-app usage, a 12-week activity heatmap. Streaks are the one game-like element; there is no points/badges/leaderboard system, so "gamified" in the fuller sense described here was still skipped.

### C. Reference notes
- Local engine landscape (Apple Silicon): Parakeet via FluidAudio on the Neural Engine is the low-latency, low-memory leader for English and streams naturally; Whisper via WhisperKit is the robustness fallback. Avoid the Python MLX path for a background app.
- Cloud access: OpenRouter exposes a dedicated transcription endpoint (OpenAI Whisper, GPT-4o Transcribe, Google Chirp, Groq fast Whisper, and others) plus chat completions for cleanup. One key covers both. STT there is per-clip, not streaming; local Parakeet provides the streaming feel.
- Open-source references: VoiceInk (GPL, reference only), Hex and Handy and OpenWhispr (MIT, reusable).

*End of PRD.*
