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

1. **Fetch the live catalog — in TWO calls, not one.**
   - Text models: `GET https://openrouter.ai/api/v1/models` (public, no key).
   - Transcription models:
     `GET https://openrouter.ai/api/v1/models?output_modalities=transcription`.

   **The default listing does NOT contain a single transcription model.** Every
   slug this file curates for STT — including the ones already in the seed — is
   absent from it. They sit behind the `output_modalities=transcription` filter
   and carry `architecture.modality == "audio->transcription"`. Verified
   2026-09-15: the unfiltered call returned 443 models and zero seeded STT
   slugs; the filtered call returned 21, all of them.

   Per-provider pricing, uptime and the provider COUNT come from
   `GET https://openrouter.ai/api/v1/models/<slug>/endpoints`.

2. **Shortlist candidates.**
   - STT: everything from the transcription listing above. Do NOT filter the
     default listing on `input_modalities` containing `"audio"` — that returns
     multimodal chat LLMs (Gemini Flash, GPT Audio, Muse Spark) and none of the
     dedicated transcription models. A pass that does this reports "no new STT
     models" no matter what shipped.
   - Prefer SINGLE-provider transcription slugs. OpenRouter ignores provider
     routing on `/api/v1/audio/transcriptions`, so a multi-provider slug's
     latency is whatever the load balancer picks that week — the documented
     cause of Skylark's swinging cloud STT latency. Check the provider count in
     the `/endpoints` response and state it in your summary.
   - Cleanup: fast, cheap instruction-following text models suited to a
     punctuation/capitalization/filler-removal pass on a few sentences at a
     time — small-to-mid open-weight or budget models (the current seed uses
     `meta-llama/llama-3.1-8b-instruct`, `openai/gpt-oss-20b` and
     `openai/gpt-oss-120b`, the last two Groq-pinned for latency).
     Judge these on TIME TO FIRST TOKEN for a two-sentence pass, not on
     headline throughput: a cleanup emits ~30 tokens, so a "1,100 tok/s" claim
     decides almost nothing. Absent a measurement, keep what is seeded.
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
   - **Transcription `pricing.prompt` is NOT in a consistent unit.** OpenRouter
     passes through whatever unit each provider quotes: per hour of audio
     (`microsoft/mai-transcribe-2` = $0.10/hr), per minute (`deepgram/nova-3` =
     $0.0043/min) or per second (`openai/whisper-large-v3-turbo` on DeepInfra).
     Those numbers are not comparable to each other and a straight multiply
     will be wrong by orders of magnitude. Confirm the unit against the
     provider's own published price before computing `costPerMonth`, and name
     the unit in the blurb the way the existing entries do.

5. **Verify.** Run `swift build` and `make test` (on the Mini, first
   `export DEVELOPER_DIR=/Library/Developer/CommandLineTools`). Both must pass before you
   report back — a bad slug or malformed entry breaks the quick-switcher and
   the cloud STT/cleanup path for every user who picks it, and Skylark has no
   server-side kill switch.

Finish with a short summary: what you added, what you left alone and why,
what you'd flag for removal (but didn't remove — deleting a live seed slug
users may have selected is a maintainer call, not an automated one), and the
`ModelInfo.swift` entries the maintainer still needs to write by hand.
