# Handoff: Air QA remediation sprint

**For Fable. Opus did the scoping and the checkpoint; both are already done.**
Start at phase 3 of the `fable-sprint` skill (grind). Do NOT re-run the
checkpoint — JJ's answers are recorded in "Decisions already made" below.

**Base:** `main` at `856c3b6`, version **0.20.1**. Source of truth for every
item: `docs/qa/2026-08-31-air-qa-findings.md`. Every defect there has a full
repro, evidence, and a root-cause anchor; this doc does not repeat them, it
tiers them, resolves the open decisions, and tells you what to build.

**Already fixed in 0.20.1 — do not redo:** D3 (false "Mic interrupted" on the
first dictation after launch) and D10 (History mislabelling local cleanup as
Apple Intelligence).

---

## Decisions already made (JJ answered these — do not re-ask)

1. **Default local cleanup tier stays Apple Intelligence**, and the Models pane
   gains a visible quality/latency comparison so a user can opt up to Qwen3 4B
   knowingly. JJ picked "keep Apple, surface the comparison in Settings" over
   switching the default. Rationale: Qwen3 4B costs a 2.3 GB download and ~3 GB
   resident, which is the wrong first-run default for a non-technical user.
2. **Silently altered numbers get both a guard and a prompt fix.** Add a
   numeric-faithfulness check to `CleanupHygiene` so a cleanup whose output
   contains a figure that does not correspond to the raw text is REJECTED and
   raw is kept; AND fix the prompt so `number/currency` produces `$1.99`
   instead of falling back to raw words.
3. **C1 is fixed in Skylark's own code. Do not patch `Vendor/llama.cpp`.** A
   vendor patch has to be re-applied and re-verified on every llama.cpp bump.
4. **The pre-paste wait drops to 600 ms, and does NOT become a second user
   setting.** See "The two timeouts" below — this one needs reading before you
   touch it, because JJ asked a question about it that has a non-obvious answer.

### The two timeouts, because they are easy to confuse

JJ asked whether the pre-paste wait was the thing changed from 2 s to 5 s
recently. It was not, and the distinction matters:

- **`cleanup.timeoutSeconds`** — a real user setting, default raised 2 s → 5 s
  in v0.19.1. Governs the **detached** path: raw text is already on screen,
  cleanup runs behind it, and this is how long to wait before giving up on the
  in-place replace. Waiting here costs the user nothing visible, which is why
  5 s is fine.
- **`prePasteCeiling`** — a hard internal backstop, currently **10 s**
  (`DictationOrchestrator.swift:306`), never exposed. Governs the **inline**
  path (Terminal, VS Code, anything that refuses AX insertion), where nothing is
  on screen yet.

The effective inline wait is `prePasteCap = min(cleanup.timeoutSeconds,
prePasteCeiling)` (`DictationOrchestrator.swift:2062`). **So v0.19.1 raised the
worst-case blank-screen wait in Terminal and VS Code from 2 s to 5 s** as a side
effect of a fix that was correct for the detached path. The 2.2 s waits D9
measured were sitting under that 5 s cap. This is the actual mechanism behind
D9 and the findings report does not name it.

**What to build:** give the pre-paste path its own tight bound of **600 ms**,
independent of `cleanup.timeoutSeconds`, so the user-facing setting keeps
meaning "how long may cleanup take" and the inline path stops inheriting it.
**Do not add a second user-facing timeout setting** — two interacting timeout
controls is precisely what a non-technical user cannot reason about. The
pre-paste bound protects against staring at an empty cursor; that is a safety
bound, not a preference. 600 ms keeps local Qwen (535 ms) and most cloud
cleanups landing, while Apple Intelligence at ~1240 ms will usually lose and
raw will paste, which is the correct trade on that path.

---

## Tiered ledger

P2 does not ship until every P0 is proven. Tiers are JJ-confirmed.

### P0 — the app is untrustworthy or cannot tell the user anything

| ID | Item | Anchor |
|---|---|---|
| **D2** | Every status note is invisible unless the menu-bar dropdown happens to be open | `App.swift:62` is the only render site; `AppController.swift:1507` sets it, cleared after 4 s |
| **C1** | Quitting after Qwen has loaded aborts in llama.cpp's Metal teardown, corrupting the upgrade path | `ggml_metal_rsets_free` from a static destructor during `exit()` |
| **D1** | A microphone that disappears is abandoned permanently, and Settings then shows a device the app is not using | `AppController.swift:2337,2342` call `applySelectedDevice(note: false)` |
| **CUR** | `"one dollar and ninety nine cents"` cleans to `1.09` — a silently wrong figure | `CleanupCorpus.swift:51`, category `number/currency` |

### P1 — broken or blocked flows

| ID | Item | Anchor |
|---|---|---|
| **D8** | Cancel during processing silently ignored past ~100 ms; "Too late to cancel" is unreachable | `cancelRecording()` first case is `case .idle: return`, `DictationOrchestrator.swift:1721` |
| **D9** | Inline cleanup in non-AX targets misses the latency bar | `prePasteCap`, `DictationOrchestrator.swift:2062` — see "The two timeouts" |
| **D4** | Groq engine selected with no key transcribes locally and says nothing at all | no note emitted even internally |
| **D5** | `groqDirect` has no case in `SpeechEngineMenu`, so no engine is checked while it is active | `App.swift:145` |
| **D6/D11** | `model_registry` seeded once, never migrated, so existing installs still offer "Groq Fast Whisper" and the pane asserts routing the transport cannot keep | `ModelRegistryEntry.swift` comment says the opposite |

### P2 — polish, and only after P0 is proven

| ID | Item |
|---|---|
| **D12** | Spoken "slash" and "at" are not converted while "dot" is, so URLs and email addresses come out half-formatted |
| **D7** | Clipboard restore reorders declared pasteboard types (no harm demonstrated — do not invent one) |
| **D13** | Hands-free deep links refused while Settings is open. Largely a D2 symptom; re-check after D2 and only fix what remains |
| **DOC1** | `validation-checklist.md` §5 names no paste-fallback target. Name **Terminal running `cat > somefile`** — TextEdit takes AX insertion so the clipboard path never runs and the box gets ticked having tested nothing |
| **DOC2** | `validation-checklist.md` §3's cancel step cannot pass as written (D8). Rewrite against real behaviour once D8 is fixed |
| **DOC3** | `live-qa-handoff.md` §8 is stale in the app's favour — it claims the checklist covers none of Command Mode, the focus guard, press-Enter or the cloud dictionary filter. It now covers all four (§4, §8) |
| **DOC4** | Harvested from the spent Air handoff: `appleIntelligenceBaseline` is still **13**, measured against the OLD 17-example corpus. The Air pass measured **17/29** with Apple Intelligence on. Re-base it (16 gives one case of slack, consistent with how the Qwen floors at 24 and 13 were set) |

---

## D2 is the hard one. Read this before writing any code.

D2 is first in the tier order because it is the mechanism that makes every other
failure in this product silent, and because most of the other fixes here are
unverifiable until a note can actually be seen. It is also the one that already
crashed the app once, so it gets the most specific brief.

**A previous attempt was reverted. Do not repeat it.** Read C2 in the findings
report in full. Summary of what failed: rendering notes under the pill by
reusing `HUDBannerPanelController` recursed through
`NSHostingView.windowDidLayout` → `updateAnimatedWindowSize` → `NSWindow
_setFrameCommon` → layout, exhausting the main thread's stack. **13 SIGSEGVs in
a single 25-note stress run.** Constraining the capsule to one intrinsic line
did not help.

Note that `HUDBannerPanelController.swift:15` carries a comment claiming it
"sidesteps that entirely" by using `.preferredContentSize`. C2 disproves that
comment. `HUDPanelController.swift:26` sets the same `sizingOptions`, so the
hazard is not unique to the banner.

**The invariant:** nothing you build may resize a hosting panel from inside a
view update. The size must be decided *before* the note is shown.

**The recommended shape:** a fixed-size note area inside the existing pill, with
its dimensions coming from `HUDMetrics.size(for:hovering:style:)`
(`HUDMetrics.swift:10`), which already returns per-state sizes and is already
the thing that decides how big the pill is. Add a note-bearing state (or a
note-bearing variant of the existing states) whose size is a constant, and
render the note inside it with truncation rather than growth. A note that is too
long gets clipped; it does not resize the panel.

**Acceptance, all four required:**
1. Each of these appears on screen, in the pill, during a normal dictation with
   the dropdown closed: "Mic interrupted — text may be incomplete", "No
   microphone is available…", "No speech detected", "Selected mic unavailable —
   using the system default", "Reached the 2-minute recording limit…".
2. **A 25-note back-to-back stress run leaves the app alive**, and
   `~/Library/Logs/DiagnosticReports/` gains no new `Skylark-*.ips`. Check the
   directory explicitly; do not infer survival from the app still being open.
3. The longest note above does not change the panel's frame.
4. Notes still appear in the menu-bar dropdown (do not remove the existing
   surface, add to it).

Run `visual-qa` on this and look at the pixels yourself.

---

## Notes on the rest

**D1.** The correct sentence already exists in `applySelectedDevice`; it is just
called with `note: false` from the device-list listener. Two things to fix: emit
the note, and reconcile `selectedDeviceUID` when the chosen device returns so
Settings stops displaying a device the app is not recording from. Decide what
Settings shows while the chosen device is absent — showing it as selected while
recording from another is the misleading part.

**C1.** Unload the Qwen model on quit before `exit()` runs static destructors.
If that proves unreliable (it reproduced only intermittently, perhaps 2 in a
dozen cycles, so absence of a crash in three tries is not evidence), fall back
to `_exit()` after Skylark's own cleanup so ggml's static destructors never run
at all. Reproduce it first — this is an `empirical-debugging` case, and a fix
you cannot show failing beforehand is not verified.

**CUR.** The guard is the durable half: a cleanup that changes a figure's value
must be rejected so raw stands. Put it in `CleanupHygiene` next to the existing
retention and content-loss floors, and add corpus coverage. Then fix the prompt
so the case actually produces `$1.99`. Watch the model-free corpus gate — every
`expected` in `CleanupCorpus` must still survive `CleanupHygiene.validate` at
both floors after you add the numeric check, or you will have broken the gate
that catches this class of bug.

**D8.** `cancelTooLateNote` is unreachable via deep link because the local
pipeline finishes in ~180 ms while an `open skylark://…` takes ~300 ms to
arrive, so the phase is already `.idle`. Fixing this means the orchestrator has
to remember that a dictation *just* committed, rather than only knowing its
current phase. At minimum a late cancel must log and must raise a note — the
checklist calls silence an explicit FAIL. Esc is a lower-latency path that may
land inside the window; that needs a human and stays parked.

**D4/D5/D6/D11 — the Groq surface.** These four are one coherent piece of work,
so do them together: emit a note (or disable the entry) when Groq is selected
with no key; add the `.groqDirect` case to `SpeechEngineMenu` so it is
selectable and checkmarked; migrate `model_registry` on upgrade rather than
seeding only fresh installs; and fix the description that asserts Groq routing
for a slug OpenRouter load-balances. **JJ has no Groq key stored**, so you can
verify the no-key path, the menu, the migration and the copy, but not Groq
actually transcribing. Say so.

**D9.** See "The two timeouts". Also record the injection stalls (worst 3.0 s in
VS Code, outside any timeout Skylark owns) as a known Electron-specific
observation; do not chase them in this sprint unless the 600 ms bound exposes
something new.

---

## Fable operating contract

Phases 3 and 4 of `~/.claude/skills/fable-sprint`. The parts that bite here:

- **Delegate by default.** The delegation test is "would Fable do this
  meaningfully better than Sonnet or Opus?" D2's design judgment and C1's
  diagnosis clear that bar. The Groq cluster, the registry migration, the
  numeric-faithfulness guard, D12, and every doc fix do not — fan those out to
  subagents in parallel, one per item or small cluster. Do not grind them
  serially in your own thread.
- **Keep in your own hands:** the D2 design and its pass/fail call on real
  pixels, C1's diagnosis, and the final judgment on whether each P0 is actually
  fixed.
- **Gate the tiers.** No P2 until every P0 is proven.
- **`empirical-debugging`** for C1 and for anything that does not hold first
  try. Show it failing, then show it passing.
- **`visual-qa`** for D2 and the Models-pane comparison UI. Delegate the
  capture, read the pixels yourself.
- **`ship-and-verify`** before any done claim.
- **`concurrent-sessions`** at start — JJ runs several sessions at once.

**Project rules that are not optional:** `make test`, never `swift test` (it
exits 0 having run nothing); scope with `make test TESTFLAGS='--filter <name>'`
(a bare `--filter` is eaten by make). Every behaviour or UI change needs a
`CFBundleShortVersionString` bump in `Resources/Info.plist`, an incremented
`CFBundleVersion`, and a `CHANGELOG.md` entry in the same commit. Keep the build
free of Swift 6 concurrency warnings. Any `AppController` setting bound to
SwiftUI must be a stored `private(set) var` — a computed property reading
`UserDefaults` is invisible to `@Observable` and the control will look dead.
Never log audio or transcript content. Never print the OpenRouter or Groq key.
Never dictate or synthesize Return into anything that sends or executes.

**Verify on the Air.** `sysctl -n hw.model` first. The Mini has no microphone
and Apple Intelligence is off, so it cannot judge any of this.

---

## Needs a human — plan around these, do not burn time on them

From the findings report, confirmed still true:

- **Push-to-talk and all bare-Fn behaviour.** Nothing automated can press Fn.
  Everything in the report used deep links or a rebound key.
- **A physical USB unplug.** The mid-utterance yank was done by software
  disconnect.
- **Real speech.** Every transcript in the report is `say` played out loud,
  which is cleaner than a human and overstates accuracy.
- **Groq direct actually transcribing.** No Groq key is stored on the machine.
- **Onboarding and TCC reset** (checklist §0), which needs an attended machine.
- **Esc as a cancel path** (D8), which may land inside the window a deep link
  cannot.

Park anything that hits one of these with a stated cause. Never idle on it.

---

## Report

Phase 4 shape: JJ's items in roughly his words with one line of outcome each;
what you verified and by what method; what you changed but could not prove;
what you parked and why; and the assumptions you shipped under. The final
message is the deliverable — no "see docs/X.md" in place of an answer.
