---
description: Curate the cloud model registry seed (STT + cleanup) against current OpenRouter offerings
---

Curate Skylark's cloud model catalog: `Sources/SkylarkCore/Models/ModelRegistryEntry.swift`
(`ModelRegistryEntry.seed`, the source of truth every install syncs against via
`RegistryStore.syncSeed()`) and `Sources/Skylark/Settings/ModelInfo.swift` (the
descriptive blurbs/scores shown in the Models pane). Read
`Skylark_Dictation_PRD.md` §7 and `ARCHITECTURE.md` §6 first for the product
and API context.

Do this in order:

1. **Fetch the live catalog.** `GET https://openrouter.ai/api/v1/models` (public,
   no key needed). This returns every model OpenRouter serves, with pricing,
   context length, and `architecture.input_modalities` /
   `architecture.output_modalities`.

2. **Shortlist candidates.**
   - STT: models whose `input_modalities` includes `"audio"` (OpenRouter's
     transcription-capable slugs — today `openai/whisper-large-v3-turbo`,
     `openai/gpt-4o-transcribe`, `openai/gpt-4o-mini-transcribe`, and any new
     entrants).
   - Cleanup: fast, cheap instruction-following text models suited to a
     punctuation/capitalization/filler-removal pass on a few sentences at a
     time — small-to-mid open-weight or budget models (the current seed uses
     `meta-llama/llama-3.1-8b-instruct`, `openai/gpt-oss-20b`,
     `meta-llama/llama-3.3-70b-instruct`, all Groq-served for latency).
   Diff this shortlist against `ModelRegistryEntry.seed` — call out slugs that
   are new, slugs in the seed that no longer exist or are deprecated on
   OpenRouter, and pricing/provider changes for slugs that are still current.

3. **Web-research promising new candidates.** For anything not already in the
   seed that looks competitive (new STT model, new cheap-and-fast instruct
   model), check independent accuracy/latency/price signals — release
   announcements, benchmarks (e.g. lmarena, papers-with-code WER leaderboards
   for STT), Groq/OpenRouter provider-uptime notes. Don't rely on vibes or the
   model card alone; corroborate speed and quality claims.

4. **Propose and apply edits.**
   - Edit `ModelRegistryEntry.seed` (add/remove/relabel/re-pin/re-sort
     entries). Preserve existing slugs whose provider/pricing hasn't
     meaningfully changed — `RegistryStore.syncSeed()` only refreshes rows it
     seeded itself, so gratuitous edits to unrelated fields ripple into every
     existing install on next launch.
   - **Reminder to the maintainer (state this explicitly in your summary,
     don't silently do it for them without review):** any slug added, removed,
     or relabeled in `ModelRegistryEntry.seed` needs a matching entry in
     `Sources/Skylark/Settings/ModelInfo.swift` (`cloudSTT` / `cloudCleanup`
     dictionaries) — a one-line description, `primary`/`secondary` scores
     (1–5, half-point steps: Accuracy/Speed for STT, Quality/Speed for
     cleanup), and `costPerMonth`. Compute `costPerMonth` from OpenRouter's
     per-unit pricing at Skylark's assumed usage baseline: **~10 min/day of
     dictation ⇒ ~5 hours of audio per month for STT pricing, or ~9,000 output
     tokens per month for cleanup pricing** (a short cleanup pass is
     input-heavy/output-light; 9k output tokens/mo is the anchor — scale
     input-token cost in if a candidate's input:output price ratio is far from
     the current seed's).

5. **Verify.** Run `swift build` and `make test`. Both must pass before you
   report back — a bad slug or malformed entry breaks the quick-switcher and
   the cloud STT/cleanup path for every user who picks it, and Skylark has no
   server-side kill switch.

Finish with a short summary: what you added, what you left alone and why,
what you'd flag for removal (but didn't remove — deleting a live seed slug
users may have selected is a maintainer call, not an automated one), and the
`ModelInfo.swift` entries the maintainer still needs to write by hand.
