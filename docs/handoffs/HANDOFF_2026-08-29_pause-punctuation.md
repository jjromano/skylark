# Handoff: pause-tolerant punctuation, emphasis control, spoken punctuation

**Target version:** 0.16.0 (MINOR — new features + behavior change)
**Branch:** `bridge/pause-sentence-say-next-08290013`
**Authored by:** Opus, 2026-08-29. Scoping, diagnosis and the Q&A checkpoint are
DONE. Fable starts at phase 3 of the `fable-sprint` skill and does NOT re-run
the checkpoint.
**Baseline at handoff:** v0.15.0, `make test` = 762 tests / 115 suites, green.

---

## 1. The bug, and why it happens

JJ pauses mid-sentence to think. Skylark puts a period there. He also finds that
emphasising a word makes cleanup over-index on it. He reports it on both tiers,
worse on local. All of that is correct, and here is the mechanism, verified
against the code rather than theorised.

**The speech recogniser inserts the period, not cleanup.** Parakeet TDT,
WhisperKit and Apple's `SpeechTranscriber` all emit punctuation and
capitalisation (`SpeechAnalyzerTranscriber.swift:10` states it outright). Their
punctuation heads key on acoustic pause duration, so a 700 ms thinking pause is
indistinguishable from a full stop. The transcript reaching cleanup already
reads `I think we should ship the feature. And then tell the team.`

**Cleanup was written on the assumption that the transcript arrives
unpunctuated.** Every rule in `CleanupPrompt.swift` says "Add punctuation".
Nothing anywhere says the punctuation already present might be wrong.
`Tests/SkylarkTestKit/CleanupCorpus.swift` is 17 cases and 16 of them are
lowercase and unpunctuated. Behaviour on punctuated input has never been
specified or tested. That is the actual gap.

**The local prompt then amplifies it.** `compactStandardBullets`
(`CleanupPrompt.swift:174`) and `compactLightBullets` (`:220`) both carry a line
the cloud prompt does not have:

> "Split a long run-on into separate sentences, each starting with a capital and
> ending with a period."

A 3B model reading that instruction, over a transcript that already contains
pause-periods, keeps every one of them and adds more. That is the
local-is-worse asymmetry.

**No guard can see it.** `CleanupHygiene.validate` checks vocabulary retention,
content-word count, negation and number units. All four tokenise on content
words, so punctuation is invisible to every one of them. A transcript shredded
into six sentences passes cleanly.

**Long dictation cements it.** Above 200 estimated tokens (~130 words)
`LocalCleaner.sentenceChunks` splits on `NLTokenizer(unit: .sentence)`, which is
exactly the set of false periods. Each fragment is then cleaned in isolation, so
the model cannot see that it continues a thought, and `joinChunks` sees
`endsSentence == true` and preserves the capital.

**Emphasis has no handling at all.** Grepping `Sources/` for
emphasis/bold/caps/exclamation returns nothing relevant. The exclamation marks
and capitals come through from the recogniser and nothing forbids the cleanup
model from amplifying them.

**Hands-free is a separate mechanism with the same symptom, and is NOT JJ's
bug.** `FluidAudioVAD.minSilenceDuration = 1.0` ends a hands-free session after
one second of silence. JJ confirmed at the checkpoint that he only ever uses
hold-Fn push-to-talk, so this path is not what he is hitting. Fixed anyway
(WS6), but do not treat it as the headline.

---

## 2. JJ's answers from the checkpoint (binding)

1. **Comma-merge: yes, with a constraint he added.** His words: *"sometimes I
   will pause in the middle of the sentence to think, and it's not at a natural
   pause in the sentence, for example 'I want to... draft the document'. I would
   not want a comma there, only if there is a natural pause at that point in the
   sentence."* This is already satisfied by the algorithm in §3 and there is a
   regression case for his exact example. Do not weaken it.
2. **Hands-free:** he did not know it existed. Ship the slider, keep it quiet.
3. **Spoken punctuation: yes, he explicitly asked for it.** *"I would like to be
   able to dictate 'I love that exclamation mark' and it cleans up to 'I love
   that!'"* This became WS4 and it interlocks with the emphasis rule: an
   exclamation mark is allowed only when it was spoken.
4. **Scope: all of it, one sprint.** *"let's just do it all at once, these
   aren't major changes."*
5. **Semantic turn detection:** deferred to backlog on Opus's recommendation.
6. **Voice edit mode: already shipped**, see §6. Not work.
7. **Local CLI cleanup routing:** rejected for the cleanup path (latency is the
   product). Backlog note only.

---

## 3. WS1 — `SentenceBoundaryRepair` (the core fix)

New pure file: `Sources/SkylarkCore/Cleanup/SentenceBoundaryRepair.swift`.
Deterministic, no I/O, no clock, fully unit-testable, exactly like
`SpokenNumbers`.

**This algorithm is already prototyped and measured. Do not redesign it.** It
scored 15/15 on the case set in §3.3, including JJ's own example. Measured cost:
`NLTagger(.lexicalClass)` runs in **0.575 ms on a 192-word transcript** on an M4,
so it is free on the paste path.

### 3.1 Where it runs

In `DictationOrchestrator`, on the RAW transcript, immediately before the
cleanup dispatch at `DictationOrchestrator.swift:1943` (`cleanWithTimeout`), and
**gated to `tier != .raw`**. Tier 0 is a verbatim passthrough and must stay
byte-verbatim.

Running it upstream of the cleaner is what makes WS5 free: `LocalCleaner`
receives already-repaired text, so its chunker can no longer split on a false
boundary.

The value stored in history as `rawText` stays the pre-repair transcript.

### 3.2 The rules

Split the transcript on `.`/`!`/`?`. At each boundary whose terminator is `.`
(never `!` or `?`), let `tail` be the last word of the preceding fragment and
`head` the first word of the following one, both reduced to lowercase
letters/digits/apostrophe. Merge when, in this precedence order:

- **R1, dangling tail.** `tail` is a word a sentence cannot end on: determiners
  (`the a an my your our their its this that these those some any every`),
  prepositions (`of to for with in on at by from into onto about over under
  after before during through between`), conjunctions (`and but or so`),
  auxiliaries (`is are was were be been am will would can could should shall may
  might must do does did has have had`), and intensifiers (`really very just kind
  sort`). **Join with a space.**
- **R2, illegal head.** `head` cannot open a standalone sentence: `which whom
  whose than nor of`. **Join with a space.**
- **R3, conjunction.** `head` is in `and but or so then plus because which while
  although though yet nor`, AND the preceding fragment has at least 3 words, AND
  the merged sentence stays at or under 60 words. **Join with a comma ONLY when
  the text after the conjunction is an independent clause** (an explicit nominal
  — noun or pronoun — appearing before a verb, per `NLTagger`). Otherwise join
  with a space.

**R3's independent-clause test is JJ's constraint from answer 1 and is the whole
reason a comma does not appear in the wrong place.** It is why `ship the feature.
And then tell the team` merges with a space while `I shipped it. But I am tired`
merges with a comma.

On merge, lowercase the continuation's first letter unless it is `I`/`I'…` or an
all-caps token of 2+ letters. This mirrors the existing rule in
`LocalCleaner.lowercasedContinuation`; reuse that helper rather than writing a
second one.

Never merge across a newline. Never merge when the preceding terminator is `!`
or `?`.

**A fourth rule was prototyped and MUST NOT be added.** "Merge a short verbless
fragment" scored 10/15: it wrongly produced `Yes ship it.` and `That is the whole
plan any questions?`. It is out.

### 3.3 Regression cases (all 15 pass in the prototype — port them verbatim)

| Raw | Expected |
|---|---|
| `I want to. Draft the document.` | `I want to draft the document.` |
| `I think we should ship the feature. And then tell the team on Friday.` | `I think we should ship the feature and then tell the team on Friday.` |
| `I shipped it. But I am tired.` | `I shipped it, but I am tired.` |
| `I want to talk about the migration. Because it keeps failing on staging.` | `I want to talk about the migration, because it keeps failing on staging.` |
| `Send the draft to Bob. Then loop in Alice.` | `Send the draft to Bob then loop in Alice.` |
| `We need to rewrite the parser. Which is going to take a week.` | `We need to rewrite the parser which is going to take a week.` |
| `We should move the deadline to. Next Friday at the earliest.` | `We should move the deadline to next Friday at the earliest.` |
| `It costs about. Twenty three dollars.` | `It costs about twenty three dollars.` |
| `I was thinking we could. Really just ship it today.` | `I was thinking we could really just ship it today.` |
| `Can you look at the. Auth bug before standup?` | `Can you look at the auth bug before standup?` |
| `I need to check the logs. And the metrics dashboard.` | `I need to check the logs and the metrics dashboard.` |
| `The deploy went out at noon. I am going to bed.` | unchanged |
| `Let us review the metrics on Tuesday. Sarah will bring the deck.` | unchanged |
| `Yes. Ship it.` | unchanged |
| `That is the whole plan. Any questions?` | unchanged |

Add adversarial cases of your own: an abbreviation (`Dr. Smith called.`), a
decimal (`It cost 3.5 million. And we paid cash.`), a URL or file path, an
ellipsis, and a transcript that is a single sentence with no periods at all
(must be returned byte-identical).

---

## 4. WS2 — the re-punctuation contract in the prompts

`Sources/SkylarkCore/Cleanup/CleanupPrompt.swift`.

1. **Delete the run-on splitting instruction** from `compactStandardBullets`
   (`:174`) and `compactLightBullets` (`:220`). It is the single most direct
   cause of the local tier's behaviour.
2. **Add a re-punctuation rule to BOTH builders at ALL THREE intensities.**
   Substance (wording is yours; keep it short and imperative for the compact
   builder):
   > The punctuation already in the transcript was inserted by a speech
   > recogniser guessing from how long the speaker paused, not from grammar. It
   > is unreliable. Re-punctuate from sentence structure and meaning. A pause is
   > not a sentence boundary: when a period falls where the sentence is
   > grammatically incomplete, or where the next words continue the same thought,
   > remove it and join the fragments.
   Frame it as "re-punctuate", never "add punctuation". Borrow the framing from
   "Mind the Pause" (arXiv 2605.12242): the transcript is not ground truth to
   lightly polish.
3. **Add pause-shredded few-shot examples to the compact builder.** The compact
   prompt is example-anchored, so for the local tier this is the highest-leverage
   single change in the sprint. Every existing example feeds the model
   lowercase unpunctuated input, which teaches it nothing about what to do with a
   false period. At minimum:
   ```
   Raw: I think we should ship the feature. And then. Tell the team on Friday.
   Cleaned: I think we should ship the feature and then tell the team on Friday.

   Raw: Can you look at the. Um. The auth bug before standup?
   Cleaned: Can you look at the auth bug before standup?

   Raw: I want to. Draft the document.
   Cleaned: I want to draft the document.
   ```
4. **`CleanupPromptTests` lines 80-91 assert both `.standard` prompts are
   byte-identical to the v0.6.1 text.** They WILL fail. Re-golden them
   deliberately with the new strings and update the comments to say the golden
   was reset at 0.16.0 and why. Do not delete the tests.

---

## 5. WS3 + WS4 — emphasis and spoken punctuation (one interlocking contract)

These two are designed together: the emphasis rule says never invent an
exclamation mark, and the spoken-punctuation rule is how the user asks for one
on purpose.

### WS3, emphasis

**Prompt rule, both builders, all intensities:**
> Vocal stress is not typography. Never add an exclamation mark, ALL-CAPS word,
> bold or italic marker, or repeated punctuation to convey that the speaker
> stressed a word. A stressed word gets ordinary punctuation.

**Hygiene pass in `CleanupHygiene`. Repair, do not reject** — throwing away a
whole good cleanup over one exclamation mark is a worse outcome than the mark.
Run after `validate` succeeds, before `SpokenNumbers.format`:
- `!` in the cleaned text may not exceed (`!` in raw + spoken exclamation
  commands counted per WS4). Downgrade the excess to `.`.
- An ALL-CAPS token of 2+ letters present in cleaned but appearing NOT-all-caps
  in raw gets reverted to the raw's casing. Acronyms the speaker actually said in
  caps are untouched by construction.
- Strip `**`/`__` emphasis markers absent from the raw.
- Collapse `!!`, `?!`, `!?` beyond what the raw had.

Skip this entire pass when `translated == true`, matching how the other
source-language guards behave.

### WS4, spoken punctuation (JJ explicitly requested this)

Target: dictating `I love that exclamation mark` yields `I love that!`

**Implement it as a prompt rule with few-shots, NOT a regex.** A deterministic
substitution cannot tell `I need a period of rest` from `that is all period`,
and getting that wrong is worse than not shipping the feature. The model does it
well with examples, and the hygiene guards catch a catastrophic result.

Commands to support: period / full stop, comma, question mark, exclamation mark
/ exclamation point, colon, semicolon, dash, open quote / close quote, open
paren / close paren. The existing `new line` / `new paragraph` layout commands
stay as they are.

**Disambiguation rule for the prompt:** treat the word as a command only when it
appears where punctuation would go — at the end of a clause, and where deleting
it leaves a grammatical sentence. When it is functioning as an ordinary noun,
keep it as a word. Give at least one negative few-shot:
```
Raw: I love that exclamation mark
Cleaned: I love that!

Raw: we need to ship this week question mark
Cleaned: We need to ship this week?

Raw: I need a period of rest before the next sprint
Cleaned: I need a period of rest before the next sprint.
```

**Assumption shipped under (flag it in the report):** spoken punctuation is
honoured at ALL THREE intensities including `.light`, on the grounds that an
explicit spoken command is user intent rather than editing. Note that this makes
`.light` slightly less literal than it was. If JJ disagrees, moving it to
standard+high is a one-line change.

WS4 must run before WS3's `!` cap, and the cap must count spoken exclamation
commands in the raw as permission for a mark.

---

## 6. WS5 — WS9: the rest

**WS5, chunker.** No code change expected: WS1 runs upstream, so
`LocalCleaner.sentenceChunks` receives repaired text. Prove it with a test —
build a pause-shredded transcript over 200 estimated tokens and assert the chunk
boundaries do not fall at the false periods.

**WS6, hands-free tolerance.** `FluidAudioVAD.minSilenceDuration` is a hardcoded
`1.0` (`SpeechEndpointer.swift:38`). Make it configurable, add a Settings →
General control (1s / 2s / 3s), default **2.0s**. Per the hard rule in
`CLAUDE.md`, any `AppController` setting bound to SwiftUI must be a STORED
`private(set) var`, never a computed property reading `UserDefaults` — that bug
has shipped twice. Affects hands-free only; push-to-talk is untouched.

**WS7, short-transcript cleanup skip.** There is no guard before
`cleanWithTimeout` (`DictationOrchestrator.swift:1943`), so a one-word "yes"
takes a full LLM round trip, which is both the slowest and the likeliest place
for a model to hallucinate structure. Skip the LLM below 3 words and instead
apply capitalisation plus a terminal period deterministically. Skip on empty
transcript entirely. (Prior art: VoiceInk v1.72, Handy's empty-input guard.)

**WS8, pasteboard hardening.** `PasteboardSnapshot.swift:22-23` iterates
`item.types` and calls `item.data(forType:)` for every type, i.e. a blind full
read of whatever is on the clipboard. A future macOS gates unattributed
pasteboard reads behind a user alert. `detectPatterns(for:completionHandler:)`,
`detectValues(for:completionHandler:)` and `accessBehavior` are all **confirmed
present on this machine's macOS 26.5 SDK** (I checked via `responds(to:)`), so
this is buildable today. Use the detect methods to establish content type before
a full read where possible. Do not regress the snapshot/restore invariant: the
clipboard must still be restored exactly around every synthesized paste.

**WS9, dependency bump.** `Package.swift:42`, FluidAudio `0.15.5` → `0.15.6`.
Read the release notes before bumping; if anything touches VAD or Parakeet
behaviour, say so in the report, because WS1 and WS6 both sit downstream.

**WS10, corpus.** `Tests/SkylarkTestKit/CleanupCorpus.swift` needs new
`pausePunctuation` and `spokenPunctuation` categories, roughly 12 cases,
mirroring §3.3 plus the WS4 examples. The existing baselines in
`QwenCleanupEvalTests` (Qwen 4B 15/17, Qwen 1.7B 7/17) and
`CleanupCorpusTests.liveOnDeviceEval` (Apple 13/17) are counts out of the corpus
size and will need re-basing once the corpus grows. **Re-base from a measured
run, never from an estimate**, and only on the Air (see §7).

**WS11, discoverability (standing-license item).** JJ did not know that either
hands-free dictation or Voice Command Mode existed. Voice Command Mode is fully
built (`Command/CommandPrompt.swift`, `CommandRunner.swift`: select text, hold
its hotkey, speak an instruction, it rewrites the selection in place) but ships
**default UNBOUND** (`HotkeyBinding.defaultsKeyCommand`), so it is invisible
unless you go looking. Hands-free is a double-tap of the dictation hotkey and is
documented nowhere the user will see. Surface both — an onboarding card, a
Settings hint, or a README section, your call. Keep it small; this is polish, and
it is gated behind every P0 above.

---

## 7. Validation duties

- **`make test`, never `swift test`.** On the CLT-only box `swift test` builds
  the bundle, executes nothing and exits 0. Baseline to beat: 762 tests green.
- **Live cleanup evals must run on the Air.** This handoff was written on the
  Mini (`Mac16,10`, macOS 26.5) where `SystemLanguageModel.default.availability`
  returns `appleIntelligenceNotEnabled` (verified live) and no cleanup GGUF is
  installed. Both eval harnesses already exist:
  `CleanupCorpusTests.liveOnDeviceEval` and
  `QwenCleanupEvalTests` (`SKYLARK_LIVE_QWEN_EVAL=1 make test`).
- **The prompt changes are unverifiable without a live eval run.** If you cannot
  get to the Air, the prompt work goes in the report's **not verified** section.
  Do not report a prompt improvement as confirmed on the strength of unit tests
  over golden strings, which only prove the string changed.
- Run `visual-qa` on the WS6 and WS11 settings UI.
- Run `ship-and-verify` before any done claim.
- Anything JJ reports a second time routes through `empirical-debugging`.

## 8. Versioning (hard rule, same commit)

Bump `CFBundleShortVersionString` in `Resources/Info.plist` to **0.16.0** and
increment `CFBundleVersion`. Add a `CHANGELOG.md` entry written for JJ, meaning
what changes for him when he dictates, not which files moved. Lead with the
pause fix and the spoken punctuation, because those are what he asked for.

No em dashes in the changelog, the commit message, or any product copy.

## 9. Report contract

Follow `fable-sprint` phase 4. Echo JJ's seven checkpoint answers back in his own
words with one line of outcome each. Be explicit about anything that could only
be verified on the Air, and about the `.light`-intensity assumption in §5. If any
workstream is parked, name the blocker.

---

## Appendix A — the working prototype

This ran on macOS 26.5 / Swift 6.2.x and produced all 15 expected results in
§3.3. It is a scratch prototype, not shippable code: it has no newline handling,
no abbreviation guard, and its sentence splitter is naive. Port the RULES and the
`isIndependentClause` test, then write the real thing properly against
`CleanupCorpus` and the adversarial cases.

```swift
let coordinators: Set<String> = ["and","but","or","so","then","plus","because",
  "which","while","although","though","yet","nor"]
let danglingTails: Set<String> = ["the","a","an","my","your","our","their","its",
  "this","that","these","those","some","any","every","of","to","for","with","in",
  "on","at","by","from","into","onto","about","over","under","after","before",
  "during","through","between","and","but","or","so","is","are","was","were","be",
  "been","am","will","would","can","could","should","shall","may","might","must",
  "do","does","did","has","have","had","really","very","just","kind","sort"]
let illegalHeads: Set<String> = ["which","whom","whose","than","nor","of"]

/// Does this clause carry BOTH an explicit nominal subject and a verb after it?
/// Only then does a comma before the conjunction read correctly. This is the
/// test that satisfies JJ's "I want to... draft the document" constraint.
func isIndependentClause(_ s: String) -> Bool {
    let t = NLTagger(tagSchemes: [.lexicalClass]); t.string = s
    var sawNominal = false, sawVerb = false
    t.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word,
                    scheme: .lexicalClass,
                    options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
        guard let tag else { return true }
        if tag == .verb { if sawNominal { sawVerb = true }; return !sawVerb }
        if tag == .noun || tag == .pronoun { sawNominal = true }
        return true
    }
    return sawNominal && sawVerb
}

// At each '.' boundary, in this precedence order:
//   R1  danglingTails.contains(tail)   -> join with " "
//   R2  illegalHeads.contains(head)    -> join with " "
//   R3  coordinators.contains(head)
//         && prevWords.count >= 3
//         && prevWords.count + words.count <= 60
//       -> join with ", " when isIndependentClause(words.dropFirst()),
//          otherwise join with " "
//   else: leave the boundary alone.
// On join, lowercase the continuation's first letter unless it is "I"/"I'…"
// or an all-caps token of 2+ letters.
```

Measured: `NLTagger(.lexicalClass)` costs 0.575 ms over a 192-word transcript on
an M4. The paste path can absorb that without a latency note.
