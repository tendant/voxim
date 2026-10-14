# Long dictation — phase 0 spike

**Date:** 2026-10-13 · **Machine:** Apple M4 Max · **Harness:** `spikes/asr-bench` target `segment-bench` · Plan: [`long-dictation-plan.md`](long-dictation-plan.md)

## Question

Does committing pieces as you go (cut at pauses, transcribe each piece right away) keep batch accuracy while making release latency and preview cost independent of length? Which pause detector should it use?

## Method

- **Clips:**
  - English monologues: 46 s, 86 s, 133 s;
  - Mandarin monologue: 153 s;
  - **code-switching clip** (58 s): English, Chinese and mixed sentences alternating, 0.7 s apart.
- **Noise:** each clip clean, and with white noise at **20 dB** and **10 dB** SNR. Synthesized speech has digitally perfect silence, so the clean runs flatter any detector; the noisy runs are the real test. 10 dB of constant hiss is a harsh stress case.
- **Replay:** audio is fed in 100 ms buffers, as the microphone delivers it. Each finished piece is transcribed with the app's real `DictationEngine`, and pieces are joined as the app would. Release latency counts any backlog plus the last piece.
- **Detectors** (prototype `PauseDetector`; pieces ≥ 1.5 s, forced cut by 25 s at the quietest point in the last 3 s):
  - **energy:** RMS against an adaptive noise floor, 32 ms frames;
  - **silero:** FluidAudio's Silero VAD (1 MB), 256 ms chunks, probability > 0.5. Run with minimum pause 0.30 s, and again with 0.25 s.
- **Baseline:** one batch pass over the whole clip, which is today's behavior.

## Results

Error rate (MER), commit-as-you-go vs batch, and release latency. The detector shown is the chosen one, **Silero with 0.25 s minimum pause**:

| Clip | Noise | Pieces (forced) | MER pieces / batch | Release pieces / batch |
|---|---|---|---|---|
| en 46 s | clean / 20 dB / 10 dB | 8 / 8 / 4 (0) | 1.5 / 1.5 / 2.2% vs 1.5 / 1.5 / 1.5% | ~40 ms vs 127–144 ms |
| en 86 s | clean / 20 dB / 10 dB | 15 / 13 / 12 (0–1) | 1.1 / 1.5 / 1.5% vs 1.1 / 1.5 / 2.6% | 37 ms vs ~200 ms |
| en 133 s | clean / 20 dB / 10 dB | 23 / 21 / 14 (0–1) | 1.2 / 2.0 / 2.2% vs 0.7 / 1.5 / 1.7% | 37 ms vs ~295 ms |
| zh 153 s (中文) | clean / 20 dB / 10 dB | 12 / 7 / 7 (3–6) | 1.0 / 12.4 / 98.9% vs 1.6 / 12.1 / 48.2% | 49–86 ms vs ~430 ms |
| **code-switch 58 s (Auto)** | clean / 20 dB / 10 dB | 17 / 17 / 16 (0) | **10.6 / 9.5 / 17.9%** vs 30.2 / 49.2 / 99.4% | 11 ms vs ~195 ms |

Worst-case transcription time for a single piece, which bounds each live-preview update: **≤ ~90 ms** (one 141 ms outlier). For comparison, re-transcribing the whole clip took 200–470 ms per update at 86 s.

**Energy detector:** fine on clean audio, but it fragments in noise. At 10 dB it made 45 pieces as short as 0.5 s, and the error rate rose to 7–11% on English (vs ~2%). It also failed to find pauses in noisy code-switching audio (62.6% vs Silero's 24% at 20 dB). **Rejected.**

**Silero, 0.30 s minimum pause:** robust, but its 256 ms granularity effectively needs ~0.5 s of silence, so it found almost no sentence breaks in English. Pieces fell back to forced 25 s cuts; accuracy was still fine. **0.25 s** (one chunk) finds the natural sentence breaks without fragmenting in noise.

**Native streaming** (`SlidingWindowAsrManager`, Parakeet v2) on the 86 s clip: 0.4% error, 469 ms total compute, 8 updates. Confirmed text only arrives per 11 s chunk. Not needed: per-piece re-transcription already bounds preview updates at ≤ ~90 ms.

## Findings

1. **Accuracy matches batch on English** (within ~0.5 points, sometimes better) at every noise level, with Silero.
2. **Code-switching improves dramatically** (10.6% vs 30.2% clean; 9.5% vs 49.2% at 20 dB). Language detection now runs per sentence instead of once for the whole dictation. Batch Auto on mixed audio is also unstable: the same clean clip scored 22.3% in one run and 30.2% in another, as the single whole-clip language decision flips.
3. **Release latency is constant:** ~11–90 ms regardless of length, vs 125–444 ms growing with length for batch.
4. **Preview cost is bounded** by one piece (≤ ~90 ms), so true incremental preview needs no streaming engine.
5. **Chinese in heavy noise is fragile with any approach.** SenseVoice batch drops to 48% at 10 dB, and per piece it collapsed to 98.9%: pieces came back almost empty. At 20 dB, pieces and batch are equal (~12%). This is SenseVoice's noise robustness, not a segmentation problem, and synthetic white noise is harsher than real rooms. It needs a real noisy-room check with your voice.

## Decision

- **Go: commit as you go.**
- **Detector:** Silero VAD (FluidAudio, 1 MB download), minimum pause 0.25 s, pieces ≥ 1.5 s, forced cut by 25 s at the quietest point in the last 3 s.
- **Preview:** confirmed text = committed pieces; volatile tail = re-transcription of the current piece only. No native streaming engine.
- **Keep** the whole-clip SenseVoice splitting (`SenseVoiceTranscriber.segments`) as a safety net for any piece that still exceeds 30 s.

## Next

Phase 1 (pipeline) per the plan. Before relying on Chinese in noisy places, record a few real-voice clips in a noisy room. If SenseVoice keeps collapsing, add a noise-floor check that falls back to whole-clip transcription.

## Re-run

```sh
cd spikes/asr-bench && swift build -c release --product segment-bench
.build/release/segment-bench <scratch dir with tts-long/, tts-zh-long/, tts-zh/>
DETECTORS=silero MIN_PAUSE=0.25 SKIP_NATIVE=1 .build/release/segment-bench <dir>   # chosen settings only
```
