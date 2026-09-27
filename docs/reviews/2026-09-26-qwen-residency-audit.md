# Qwen cleanup residency audit, 2026-09-26

## Question and verdict

Should Skylark keep the selected Qwen 4B cleanup model loaded from launch until the user switches models or quits? For consistent local cleanup, yes, provisionally. The previous five minute idle unload made the next dictation after an ordinary pause use Apple Intelligence. Keeping the selected model resident removes that recurring cold state without adding model loading to the paste path. The cost on the M3 Air was about 2.9 to 3.1 GiB of Skylark RSS with 4B loaded, versus about 190 to 237 MB without it. The work laptop's memory pressure during a normal day has not been measured.

## Method and coverage

GPT-6 inspected the startup, backend, switch, fallback, quit and Settings paths at `0bbd422`, plus the dated M3 Air QA results. Claude Opus 5.5 at high effort independently challenged the design from exact source excerpts. Two earlier Opus repository-reading attempts failed through CLI context compaction and produced no verdict; the completed Opus pass had tools disabled and is an excerpt review, not an independent full-tree read. GPT-6 verified each reported mechanism against the current source and ran the live retirement test before accepting it. A separate GPT-6 Sol agent researched current official product docs and primary GitHub repositories; GPT-6 checked the cited pages before using those claims.

No cold-launch timing or memory pressure was measured on the work laptop. The Mini has no installed 4B GGUF and cannot reproduce the user's push-to-talk flow.

## Findings and disposition

| Finding | Verification and disposition |
|---|---|
| A replaced backend can reload after its unload | Confirmed. A dictation holding the old cleaner can invoke its readiness check or generation after `swapLocalCleanupBackend` unloads that backend. With no idle timer, the old model would remain loaded. Fixed by terminal retirement and a live GGUF test covering both calls. |
| Switching between two Qwen models briefly holds both | Confirmed from `swapLocalCleanupBackend`: it preloaded the next model before unloading the old one. Fixed by retiring the old backend first. The selected model's Apple fallback covers the transition. |
| Settings claimed a five minute idle unload | Confirmed. The text at `SettingsView` contradicted the new default residency policy. Corrected in 1.0.4. |
| A queued preload could run after quit-time unload | Confirmed from the quit hook and backend preload task ordering. The quit hook now retires each backend before exiting, preventing a later preload from reviving it. |
| Memory pressure may make a loaded model slow without changing the backend's readiness flag | Plausible, unconfirmed. `LlamaRunner` sets `n_gpu_layers` for Metal and does not explicitly control mmap/mlock. The excerpt review could not establish whether macOS would evict relevant buffers, or whether this would exceed the cleanup budget. Do not change the fallback policy without a work-laptop measurement. |

## Timing and resource evidence

- In the [2026-09-16 M3 Air recheck](../qa/2026-09-16-v1-recheck-findings.md), `llama model loaded` appeared about 2.7 seconds after the hotkey became available on a cold relaunch. This is one startup observation, not a timed distribution of `preload()`. Prefix warming may have continued after that log line. The user dictated for 10.7 seconds, so Qwen was ready before cleanup.
- The same recheck reported 644 ms mean cleanup generation in a 34-case Qwen 4B evaluation, while one real dictation took 2,082 ms in Qwen cleanup. The latter includes prompt and output work; it is not a 2,082 ms model-load measurement.
- The [2026-09-08 human pass](../qa/2026-09-08-v1-human-pass-findings.md) measured 2.91 GiB RSS with Qwen 4B resident and 2.98 GiB after a cleanup. An earlier [M3 Air QA pass](../qa/2026-08-31-air-qa-findings.md) saw about 3.07 GB with 4B, versus 190 to 237 MB without it. The 2.5 GB GGUF file size is not itself a RAM measurement.

## Other apps and policy choice

| App | Documented policy | Relevance |
|---|---|---|
| [Wispr Flow](https://docs.wisprflow.ai/articles/4048537120) | Transcribes in the cloud and requires an internet connection. | No comparable local model lifecycle is documented. |
| [Superwhisper](https://superwhisper.com/changelog) | Preloads Cohere Transcribe from recording start; earlier release notes say offline voice models load in the background when recording starts. | Recording-start preload can hide cold speech-model work. Its local cleanup model's residency policy is not documented. |
| [OwnWhisper](https://github.com/oVservant/OwnWhisper#model-storage-and-memory) | Offers Low Memory, Balanced (ten minute unload and immediate release under memory pressure), and Always Ready for its speech model. | Confirms that readiness versus RAM is a user-visible choice in at least one peer app, but its model is smaller and serves transcription rather than Qwen cleanup. |
| [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac#readme) | Auto-unload Never restores previously loaded models at launch; other policies load on first use. | Also exposes the readiness versus RAM tradeoff; no specific cleanup-LLM lifecycle is stated. |
| [HoldTalk](https://github.com/DevWizardHQ/HoldTalk#how-it-works) | Starts its speech-model server when recording begins and unloads it after an idle timeout, three minutes by default. | A lower-memory pattern, with first short dictations still exposed to cold load. Reported timings are project claims on an M1 8 GB Mac. |

Keep persistent residency for the selected Qwen model while it is the user's local cleanup choice. Continue to fall back to Apple Intelligence during the brief initial launch load. A recording-start readiness check could help recover from an initial load failure, but it would compete with speech work for memory bandwidth; it needs an M3 Air or work-laptop measurement before adoption. If normal work shows material memory pressure or swap, test an explicit low-memory policy with a longer idle timeout and recording-start preload. Do not lengthen the paste timeout to cover a cold load: that trades the visible fallback for a multi-second paste delay.

## Validation and remaining measurement

The live GGUF retirement test passed on the Mini with a 1.7B test model. The full Swift suite is the release check. The app compiled, but the Mini has no valid Skylark signing identity: `make app` fell back to ad hoc signing. The resulting bundle was not launched for screenshot QA, since ad hoc signing breaks TCC permission continuity. On the work laptop after installing 1.0.4, capture a normal workday's memory pressure and swap with 4B selected, plus the elapsed time from Skylark launch to Qwen readiness for several cold starts. Export diagnostics after any unexpected Apple fallback. Those measurements decide whether Always Ready should remain the default for that machine.
