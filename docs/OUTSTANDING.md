# Outstanding

Open items after the 1.0.0 release (2026-09-17). Each is small and none blocks
use. Remove an item when it ships or is decided against.

## Needs the Air

- **Confirm the 1.0.1 launch fix.** Before 1.0.1, launch awaited the Qwen
  preload before installing the selected speech engine, so with a cloud engine
  selected the first dictation after launch silently used Parakeet
  (`docs/qa/2026-09-16-v1-recheck-findings.md`, follow-up 1). Fixed in
  `AppController.bootstrapSelection` but never run on hardware. Check: update,
  dictate right after the relaunch, and the History row's engine must be the
  cloud engine, not `parakeet`.
- **Status notes in the pill have never been seen by a human.** Block 2 of
  `docs/qa/v1-human-pass.md` was skipped on 2026-09-08, and JJ runs with the pill
  style Hidden, which hides every note. Cable-test notes were seen once on
  2026-09-08. Run Block 2 with the style set to Standard before the next release.
- **The cloud speech 2-second fallback (0.24.5) has never met a real slow
  response.** Unit tests only. A throttled network (Network Link Conditioner)
  with a cloud engine selected would exercise it.
- **The silent-hold filler discard ("Yeah." dropped when the VAD hears no
  speech) has not fired live on the Air.** All eight recheck holds were stopped
  earlier, by the silence gate or an empty transcript. Covered by unit tests and
  a live-VAD test on the Mini (`SilentHoldHallucinationTests`).

## Code

- **Licences screen.** Bundle and show the third-party notices (FluidAudio
  Apache-2.0, WhisperKit MIT, GRDB MIT, llama.cpp MIT). Apache-2.0 asks for its
  NOTICE to travel with redistributions; today the notices live only in the
  repo and the Homebrew formula's `licenses/` folder.

## For JJ

- Add "Qwen" to Skylark's dictionary on the Air; it transcribes as "Quen",
  "Quan" or "Quinn".
