# Skylark v1 recheck findings

- **Run:** 2026-09-16 on JJ's MacBook Air (`Mac15,12`)
- **Source:** "Recheck (0.24.7 or later)" in `docs/qa/v1-human-pass.md`
- **Commit:** `1615f0ee27b7468396b7a91daaae87a637bd61c9` (matched `origin/main`)
- **Installed app:** Skylark 0.24.7 (build 57), stamped commit `1615f0e`

## Agent-only part

- **Install:** `Scripts/install.sh` built, signed, installed and launched
  0.24.7 (build 57) from `/Applications/Skylark.app`.
- **Unit suite:** `make test` ran **957 tests in 144 suites, all passed**.
- **Baseline:** History max id 2090; zero `Skylark-*.ips` crash reports on
  disk (and still zero at the end); USB Audio was the system default input
  with no Skylark device override.
- **Settings before the ACTs:** Cleanup tier **Cloud**
  (`openai/gpt-oss-120b`), on-device engine already `llama:qwen3-4b-instruct`,
  speech engine `cloud:microsoft/mai-transcribe-2`, **pill style Hidden**.
  JJ switched Cleanup to Qwen3 4B from the menu bar; nothing else was
  changed.
- **Target:** a Terminal window running `cat > /dev/null`. Its buffer held
  only the banner line after the silent holds.

### Five deep-link silent holds: PASS, but the log check can't pass as written

| Hold | Wall | Log path | History row | Pasted |
|---|---:|---|---|---|
| 1 | 3,003 ms | silence gate (`capture finalize`, no decode) | none | nothing |
| 2 | 3,043 ms | `vad trim — regions: 0`, no transcript/paste/latency line | none | nothing |
| 3 | 3,041 ms | silence gate | none | nothing |
| 4 | 2,866 ms | silence gate | none | nothing |
| 5 | 3,005 ms | silence gate | none | nothing |

**Doc gap:** the recheck expects `No speech detected` in the log each time,
but the silence-gate branch in `DictationOrchestrator` yields that note to the
HUD without logging it. Only the filler-word discard branch logs
(`no speech: VAD found none…`). So "nothing pasted, no row" is the evidence,
and the recheck's log check can never pass as written. Either log the note
(content-free) or change the doc.

### Live cleanup evals

| Eval | Score | Floor |
|---|---|---|
| Apple Intelligence (`SKYLARK_LIVE_CLEANUP_EVAL=1`) | 17/34 | 16 |
| Qwen3 4B (`SKYLARK_QWEN_MODEL=qwen3-4b-instruct SKYLARK_LIVE_QWEN_EVAL=1`) | 28/34, avg 644 ms | 24 |

The three new corpus cases:

| Case | Apple | Qwen3 4B |
|---|---|---|
| `spokenAddress/spelledURL` | DIFF: `the repo is at github.com/jjromano/skylark` (address right, no capital or period) | **MATCH** |
| `spokenAddress/spelledEmail` | DIFF: `email me at jjromano@example.com` (address right, no capital or period) | DIFF: `Email me at jjromano@example.com` (only the final period missing) |
| `faithful/emphasis` | DIFF: `really` kept, no capital or period | **MATCH** (`really` kept) |

Neither model broke either address or dropped the stressed word; every DIFF
is sentence casing or the final period.

## ACTs (JJ dictating into the Terminal target, Cleanup = Qwen3 4B)

| ACT | Verdict | Evidence |
|---|---|---|
| 1. Three silent Fn holds | **PASS** (pasting); note **not verifiable** | Holds of 3,039 / 3,738 / 3,065 ms. Holds 1 and 3 stopped at the silence gate; hold 2 had `vad trim regions: 0` and no transcript/paste line. No History rows, Terminal buffer unchanged. JJ saw no note because `hud.style = hidden` hides the whole pill, notes included (`HUDMetrics.isVisible`). The pill check needs the style set back to Standard. |
| 2. "github dot com slash j j romano slash skylark" | **PASS**, cosmetic differences | Landed `GitHub.com/jjromano/skylark.` (row 2091). The cloud STT (`mai-transcribe-2`) joined the address itself; cleanup was skipped as too short and only added the period. 580 ms total. The address is whole, which is the 2026-09-08 failure being rechecked. Differences from the doc: capital G (harmless in a host name) and a trailing period. |
| 3. "email j j romano at example dot com" | **PASS** | Landed `Email jjromano@example.com.` (row 2092), from the cloud STT; cleanup skipped as too short. 470 ms total. |
| 4. Quit, relaunch, dictate at once | **PASS** | Relaunched pid 32185: Parakeet ready +0.2 s, `llama model loaded` +2.7 s after the hotkey tap came up, so no Apple stand-in was needed. Row 2093: 10.7 s clip, **2,331 ms** from Fn release to paste (transcribe 218, Qwen cleanup 2,082, inject 18), under the 5 s bar. Qwen ran (`cleanup-ran: local:qwen3-4b-instruct`, out=24 tokens). No crash report. |
| 5. Menu dropdown and Check for Updates | **PASS** | JJ's screenshot: Status/Last (2,331 ms)/words, then Speech Engine, Cleanup, Whisper Mode, Settings…, History…, Check for Updates…, Quit. Speech Engine sits above Cleanup and there is no Onboarding item. Check for Updates opened Settings on **Account** showing "Skylark 0.24.7, Build 1615f0e · Sep 16, 2026" and **"Skylark is up to date."** |

Every paste into Terminal logged `AX insert unconfirmed; using clipboard paste
fallback` followed by `clipboard restored` about 127 ms later, as designed.

## Follow-ups (none gating)

1. **Cloud STT skipped on the first dictation after relaunch.** Speech is set
   to `cloud:microsoft/mai-transcribe-2`, but row 2093 (first dictation of the
   new process) used `parakeet` with no `stt fallback` line in the log. JJ's
   next dictation (row 2094, outside the recheck) used the cloud engine again.
   Looks like the cloud engine isn't in place when the first dictation starts,
   and the switch is silent.
2. **Drop the trailing period on fragments** (JJ): a lone URL or address
   shouldn't get a sentence period, e.g. ACT 2's `GitHub.com/jjromano/skylark.`
3. **Log the `No speech detected` note** (content-free) on the silence-gate
   path, or change the recheck text, so the agent check can be met.
4. **Status-note visibility (Block 2) is still unseen on real hardware.** It
   was skipped on 2026-09-08, and today the pill style was Hidden.
5. **"Qwen" transcribes as "Quen"** (row 2093), the same name-accuracy miss as
   the 2026-09-08 quit cycles; a dictionary entry would fix it.

## Is this a v1.0?

**Yes.** Every ACT in the recheck passed on 0.24.7. Silent holds no longer
paste (8 of 8 today, counting the five agent holds and JJ's three real Fn
holds), where 0.21.1 inserted `Yeah.` 2 of 2 times. Spelled-out URLs and
emails land whole. A cold relaunch with Qwen3 4B pastes in 2.3 s. The
restructured menu and the update check look right. With 957 unit tests
passing, Qwen3 4B scoring 28/34 against a floor of 24, Apple 17/34 against
16, and zero crash reports, nothing found today blocks the release. The
caveats are real but small: the `No speech detected` note wasn't seen,
because JJ runs with the pill hidden, so on-screen notes (Block 2) are still
unseen by a human; the first dictation after launch silently used Parakeet
instead of the selected cloud engine; and a trailing period lands on bare
URLs. I'd tag 1.0 and take those as 1.0.x fixes.
