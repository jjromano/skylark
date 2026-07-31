# Turning daily use into a QA loop

A plan for using JJ's real Skylark usage to measure and improve transcription and
cleanup quality. Written 2026-07-31 against v0.12.1 (`c1691f7`).

## The premise needs one correction

**The logs cannot tell you where the models are wrong.** Logging is content-free
by hard rule, and the cross-model audit verified that across all 112 source
files: no transcript, no partial transcript, no prompt, no audio ever reaches a
log line. What the logs and the diagnostics export give you is *metadata and
anomaly flags*: engine, clip duration, raw and clean word counts, which cleanup
engine actually ran, latency, degrade events, a "likely truncation" flag when
clean words drop below half the raw words, and a "likely silent tail" flag. Those
catch regressions. They cannot tell you that "A ten G" should have been "A10G".

**The history database is the real asset, and it is already accumulating.** After
the v3 and v4 migrations, every dictation writes:

```
timestamp, raw_text, clean_text, mode_id, engine, duration_ms, latency_ms,
audio_path, word_count, app_bundle_id, app_name, cleanup_engine
```

That is a per-dictation record of what the ASR produced, what cleanup made of it,
which engine did the work, which app it went into, and how long it took. For
cleanup evaluation you need nothing else. `raw_text` is the input and
`clean_text` is the output, already paired, already labeled by engine and app.

Live at `~/Library/Application Support/Skylark/skylark.sqlite` **on the Air**.

## The two models are different problems

This distinction drives everything below.

**Cleanup is directly improvable and directly measurable.** The levers are the
prompt (`CleanupPrompt`), the hygiene filter, the `SpokenNumbers` pass, cleanup
intensity, and model choice. A curated corpus with an exact-match rate is a real
objective function, and one already exists.

**Transcription is not retrainable.** Parakeet is a CoreML artifact from
FluidAudio; WhisperKit likewise. You will not fine-tune either. The levers are
the custom dictionary, the deep-vocabulary rescorer (already built), VAD and trim
parameters, Whisper Mode tuning, and engine routing. So the ASR loop does not
produce a better model. It produces **a ranked list of words Skylark gets wrong
for JJ specifically**, which feeds the dictionary and rescorer, plus evidence
about when to route to a different engine.

Anyone proposing to "improve the speech model" should be redirected to that.

## What already exists, and what is in the way

| Asset | State | Note |
|---|---|---|
| History with raw and clean pairs | **Live, accumulating** | Nothing to build for cleanup eval |
| Audio retention | **Built, opt-in, OFF by default** | WAV under `Application Support/Skylark/Audio`, with a `history.retentionDays` window |
| `CleanupCorpus` | 17 curated `(raw, expected)` cases with categories | Apple Intelligence scored 13/17, Qwen3 4B 15/17 |
| Model-free hygiene gate | Runs on every change | Asserts every expected output survives `CleanupHygiene.validate`. This one bites. |
| Live cleanup eval (`SKYLARK_LIVE_CLEANUP_EVAL=1`) | Opt-in, **prints and never asserts** | Can report 0/17 and pass. Found by the cross-model audit. |
| `Retranscription.run` | Built, wired to History UI | **Destructive: overwrites `raw_text` and clears `clean_text`.** Unusable as-is for A/B, since it destroys the thing you want to compare against. |
| `CorrectionWatcher` | Built, opt-in, **default OFF** | Deliberately discards the corrected field text and keeps only the learned word pair |
| `SkylarkBench` | File-based decode benchmark, both local engines | The natural host for a batch QA sweep |

Two of these are the plan's main obstacles: `Retranscription` is destructive, and
the live eval does not assert.

## The highest-value signal is free, and it is being thrown away

When JJ fixes a word after dictation, that edit is a **human-labeled error**,
weighted by real usage, costing nothing and touching no network. `CorrectionWatcher`
already detects it: it re-reads the AX field twice after injection, diffs against
what was inserted, and extracts the changed word pair.

Then it discards everything else. Its own header says so:

> Privacy: only the learned word pair ever leaves this actor; the field text read
> back is never logged or persisted.

That was the right call for a shipping product and it is the wrong call for a QA
window. The `(what Skylark produced, what JJ actually wanted)` pair is exactly
the training signal for both models, and it is the only source that reflects
genuine intent rather than a second model's opinion.

**Recommendation: an opt-in local corrections corpus.** Persist the pair to a
local table when QA mode is on. Local only, never in the diagnostics export,
purgeable in one command, off by default and off in Stephanie's build.

This is the most privacy-sensitive item in the plan, because it stores what he
actually wrote rather than what he said. It is also the cheapest and best. Worth
an explicit decision rather than a quiet default.

## The batch reference-model sweep

The idea is sound. It is pseudo-labeling: use a materially stronger model to
produce a reference transcript, and treat disagreement as a candidate error.
Four design points decide whether it produces signal or noise.

**1. Use local Whisper as the reference first, not the cloud.** WhisperKit
large-v3-turbo is already integrated, is a much stronger acoustic model than
Parakeet on hard audio, costs nothing, and sends nothing anywhere. Run it over
everything. Escalate to cloud `gpt-4o-transcribe` only for the subset where
Parakeet and local Whisper disagree, which is a small fraction. This keeps the
privacy surface near zero and the cost near zero while giving a second and third
opinion where it matters.

If the full-cloud version is ever wanted anyway: Groq's whisper-large-v3-turbo is
about $0.04 per audio hour, so a fortnight of heavy dictation is well under a
dollar. Cost is not the constraint. Privacy is.

**2. Non-destructive, always.** Do not call `Retranscription.run` for this. Write
reference transcripts to a sidecar (a QA table or a JSONL next to the corpus),
keyed by history row id, never over `raw_text`.

**3. Normalize before diffing, or drown in false positives.** Case, terminal
punctuation, contractions, digits versus number words, and filler are all
legitimate differences that are not errors. The standard approach is a text
normalizer applied to both sides before scoring, then word error rate over the
normalized forms. Without this step, the review queue will be 90 percent noise
and get abandoned after one session.

**4. The output is a ranked review queue, not a verdict.** Disagreement is not
error; the reference model is also wrong sometimes. Rank by normalized edit
distance, cluster by the type of difference, and have JJ triage the top slice in
a few minutes. Expect three clusters, each with a different remedy:

- **Proper nouns and jargon** goes to the dictionary and deep vocabulary
- **Domain homophones** goes to vocabulary biasing
- **Genuine acoustic failure** goes to engine routing, Whisper Mode, or a mic
  recommendation

## Phases

**Phase 0. Mine what already exists. Zero code, do this first.**
Run read-only SQL against the history DB on the Air and get the baseline picture
before building anything: total volume and per-day rate; distribution by
`app_name`, `engine`, and `cleanup_engine`; how often `clean_text` is null or
identical to `raw_text` (cleanup doing nothing); the raw-to-clean word ratio
distribution with the low tail flagged (content dropped); the `latency_ms`
distribution against the 300 ms bar, split by engine and cleanup tier. This is an
hour of work and it decides where the remaining effort should go. It may well
show cleanup is fine and latency is the problem, or the reverse.

**Phase 1. Start collecting. Small.**
Turn on audio retention with a bounded window, say 14 days, and let a corpus
accumulate through normal use. Nothing else changes. Decide the window now so
disk does not grow without limit.

**Phase 2. The sweep. The real build.**
A `SkylarkQA` CLI target alongside `SkylarkBench` that: reads retained clips plus
their stored raw and clean text, runs the local Whisper reference over each,
normalizes and diffs, escalates only disagreements to a cloud reference, and
emits a ranked review file. Triage output promotes into dictionary entries, deep
vocabulary entries, `CleanupCorpus` cases, or a new ASR corpus.

**Phase 3. Make the evidence bite.**
Fix the live eval so it fails rather than prints, with a per-model exact-match
floor (Apple at 13/17, Qwen3 4B at 15/17 as the current baselines) plus a handful
of must-pass cases. Add an ASR corpus with a WER ceiling. Only after this does a
prompt or model change get measured rather than eyeballed. This also closes a
finding from the cross-model audit.

**Phase 4. Close the loop passively.**
The corrections corpus above. Once Phase 3 exists to measure against, real
corrections become the renewable source of new corpus cases.

## Decisions owed before any of this starts

1. **Audio retention on, and for how long?** Required for Phase 2. Reversible,
   local, already built.
2. **Corrections corpus, yes or no?** Highest value, highest sensitivity. It
   stores what JJ wrote, not just what he said.
3. **Cloud reference model, yes or no?** The recommendation is local Whisper
   first and cloud only for adjudication. If cloud is used, JJ's voice reaches
   OpenRouter's provider, which is a real change to the app's central promise
   even on his own machine.
4. **Related, and worth settling first:** the cross-model audit found that the
   full custom dictionary is already sent to OpenRouter on every cloud cleanup
   request, undisclosed. Before adding deliberate cloud surface for QA, decide
   what to do about the accidental cloud surface that already exists.

## One caveat on the data

JJ's daily use is biased toward his own vocabulary, his own apps, his own
acoustics, and his own microphone. That is exactly right for tuning his
experience and exactly wrong for judging general quality or predicting
Stephanie's. Anything promoted into `CleanupCorpus` as a regression gate should
be checked for whether it generalizes, or it will overfit the suite to one voice.

## Learning from other projects

Worth a scoped research pass, with a clear expectation: **dictation apps are a
weak source for evaluation methodology.** Most ship no eval harness at all, which
is why Skylark's corpus is already ahead of most of them. The strong prior art is
in the ASR evaluation world rather than in dictation UIs.

What to look for, in priority order:

1. **Text normalization before scoring.** Whisper's own normalizer (MIT) is the
   de facto standard and is directly reusable as a concept for Phase 2's diffing
   step. This is the single most load-bearing borrowed idea in the plan.
2. **WER and CER computation conventions**, including how alignment handles
   insertions and deletions, so the ranking is meaningful.
3. **Whether any MIT dictation project ships a regression corpus or eval gate**,
   and what they assert. If one does, that is a shortcut worth taking.
4. **Handy's VAD smoothing parameters**, which the sprint doc already cites for
   onset gating and hangover, relevant to the trim thresholds the audit flagged
   as capable of eating quiet speech.
5. **OpenWhispr's correction learning**, already partly borrowed, for how it
   filters a diff down to a trustworthy learned pair.

Licensing rule stands: VoiceInk is GPL and is ideas only; Hex, Handy, and
OpenWhispr are MIT and adaptable with a source comment.

I have not verified the current contents of any of these repositories in this
session. Treat the list as what to go and check, not as findings.
