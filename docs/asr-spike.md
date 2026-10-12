# Day 1 — ASR spike

**Date:** 2026-10-12 · **Machine:** Apple M4 Max, macOS 26.6.1 · **Harness:** `spikes/asr-bench` (shares `voxim/ASR` + `voxim/Input` sources with the app)

## Method

- 12 coding-agent instructions (`spikes/asr-bench/phrases.txt`), synthesized with macOS `say` at 16 kHz mono.
  Clean TTS audio: this measures latency and vocabulary handling, **not** robustness to a real mic, accent or room noise.
- Batch transcription of the whole clip after "release" (the push-to-talk flow). One warm-up run excluded.
- WER is strict string matching, so formatting the agent would happily accept (`user.profile.email`, `30 seconds`, `package.json`) counts as an error. The "real errors" column is hand-scored meaning changes.

## Results

| Engine | Strict WER | Exact | Real misrecognitions | Stop→text p50 / p95 | First-run setup |
|---|---|---|---|---|---|
| Apple `SpeechTranscriber` (en-US) | 15.5% | 4/12 | 5 — *add→at*, *auth→off*, *npm→within PM*, *tmux→muck's*, *pane→pain* | 61 / 71 ms | 0.8 s, OS-managed model |
| Parakeet TDT 0.6B **v2** (en) | **7.3%** | **8/12** | **1** — *tmux→MUX*, *pane→pain* | 41 / 44 ms | ~80 s, 453 MB download |
| Parakeet TDT 0.6B v3 (multilingual) | 10.9% | 6/12 | 2 — *npm→within PM*, *tmux→mux*, *pane→pain* | 39 / 41 ms | ~90 s, 470 MB download |

Latency doesn't separate the engines: all three finish a 2–4 s utterance in under 75 ms, well below anything a user would notice.

## Decision

- **Default engine: Parakeet TDT v2 via FluidAudio** (Apache-2.0; models from HuggingFace on first run, cached in `~/Library/Application Support/FluidAudio/Models`). It made the fewest errors on developer vocabulary (README, auth, npm, async/await).
- **Keep `AppleSpeechTranscriber`** as the zero-download fallback while the Parakeet model downloads, or if it fails to load. Both sit behind the `Transcriber` protocol.
- **No engine handles "tmux pane".** Follow-ups: try `AnalysisContext.contextualStrings` (Apple) and FluidAudio custom vocabulary / post-correction with a small project word list, then re-run with a real-voice recording set (put `NN.wav` files next to a phrases file and pass the directory).

## Re-run

```sh
cd spikes/asr-bench && swift build -c release
.build/release/asr-bench <dir-with-01.wav..12.wav> phrases.txt [apple] [parakeet-v2] [parakeet-v3]
```
