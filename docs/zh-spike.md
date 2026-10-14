# Chinese + language-ID spike

**Date:** 2026-10-13 · **Machine:** Apple M4 Max, macOS 26.6.1 · **Harness:** `spikes/asr-bench` target `zh-bench`

## Question

How should voxim support Mandarin, including English terms inside Chinese sentences, and can it detect the spoken language automatically (LID) so the user never switches modes?

## Method

- 28 phrases (`spikes/asr-bench/zh-phrases.tsv`) in three groups, each with short (1–3 words, down to 0.4 s) and normal sentences:
  - **en:** English coding commands.
  - **zh:** Mandarin.
  - **mix:** Mandarin with English dev terms ("帮我跑一下 unit tests…", "把 auth middleware 重构一下").
- Two voices each, giving 56 clips: en Samantha (US) + Daniel (UK); zh/mix Tingting (mainland) + Meijia (Taiwan). Mixed phrases are spoken by the Mandarin voices, so English terms carry a Mandarin accent.
  - Voice names with parentheses ("Eddy (Chinese (China mainland))") silently fall back to the default voice; an earlier run with them was discarded.
- **Mixed error rate (MER):** each CJK character and each Latin word is one token; punctuation and spacing are ignored, and Traditional is folded to Simplified. This equals CER for Chinese and WER for English.
- Synthesized speech: good for relative comparison and LID behavior, not for absolute accuracy on a real mic.

## Results

### Error rate · median latency (release → text)

| Engine | en short | en normal | zh short | zh normal | mix short | mix normal |
|---|---|---|---|---|---|---|
| SenseVoice Small (auto LID) | 36.4% · 11 ms | 12.8% · 11 ms | **0.0%** · 11 ms | **1.4%** · 11 ms | 64.3% | 25.4% |
| SenseVoice Small (forced zh) | — | — | **0.0%** | **1.4%** | **35.7%** | **21.2%** |
| Paraformer-large zh (int8) | — | — | 3.1% | 13.0% | 71.4% | 46.6% |
| Apple `SpeechTranscriber` zh_CN | — | — | **0.0%** · 40 ms | **1.4%** · 56 ms | 42.9% | 29.7% |
| Apple `SpeechTranscriber` en_US | 36.4% | 12.8% | — | — | — | — |
| Parakeet TDT v2 (current) | **0.0%** · 37 ms | **7.4%** · 40 ms | 100% | 100% | 92.9% | 94.9% |
| **Auto: SenseVoice LID → Parakeet for English** | **0.0%** · 48 ms | **7.4%** · 52 ms | **0.0%** · 11 ms | **1.4%** · 11 ms | 64.3% | 24.6% |

### Language ID (SenseVoice, auto)

| Group | Correct | Misses |
|---|---|---|
| en short | 9/10 | "Commit" (0.4 s) → `ja`. Harmless: the text has no CJK, so routing still picks Parakeet |
| en normal | 10/10 | |
| zh short | 10/10 | |
| zh normal | 10/10 | |
| mix short | 2/4 | "跑一下 tests" → `en` (both voices), so it's routed to Parakeet and comes out as garbage |
| mix normal | 11/12 | "给 login API 加一个 test" (Meijia) → `en` |

LID costs nothing extra: SenseVoice emits the language tag in the same pass as the text. It returns only the top tag, with no confidence score.

### Other findings

- **Pure Chinese is solved.** SenseVoice and Apple zh_CN are both near-perfect. SenseVoice is about 4–5× faster (11 ms vs 40–56 ms) and also detects the language; Apple needs no download.
- **Parakeet is still the best English engine.** SenseVoice and Apple en_US both mishear short English ("Undo that" → "And do that" / "Don't do that"). Routing English to Parakeet keeps today's English quality.
- **Mixed Chinese-English is the weak spot for every engine.** English terms in Mandarin-accented speech get mangled: "functionction", "NTM" for npm, "bg" for bug, "offme lu" for auth middleware. Forced-zh SenseVoice is best at ~21% on normal sentences. Real bilingual speakers likely do better than the TTS voices, but this needs real-voice data.
- **Apple contextual strings had no effect.** Feeding zh_CN a list of ~40 dev terms (`AnalysisContext.contextualStrings`) produced identical transcripts. Not pursued.
- **Paraformer is ruled out:**
  - worse on normal Mandarin (13%);
  - leaks sub-word markers into its output (`un@@itte@@sts`);
  - the largest download (639 MB);
  - truncates audio after ~128 characters.
- **Footprint:** SenseVoice Small is 453 MB on disk (one-time download), loads in about 0.1 s once cached, and transcribes in about 11 ms per utterance.

## Decision

Add a **Language** setting:

| Mode | Engines | For |
|---|---|---|
| **English** (default) | Parakeet only, as today | English-only users; no extra download |
| **Auto: English + 中文** | SenseVoice LID → Parakeet when English with no CJK, otherwise SenseVoice text | Bilingual use; English stays at Parakeet quality, Chinese is near-perfect |
| **中文** | SenseVoice forced zh | Mostly-Chinese use; best on mixed sentences and short Chinese |

- Routing for the remaining tags: `ja`/`ko` count as Chinese if the text has CJK characters, otherwise English. `nospeech` means "Nothing recognized".
- While SenseVoice downloads (453 MB), Auto behaves as English. Apple zh_CN can back up 中文 mode in the meantime.
- The HUD briefly shows the detected language (`EN` / `中`) so a wrong guess is visible. Metrics record the language code (never text).

Text handling needed alongside, since it assumes space-separated words:
- **Smart formatting:**
  - no spaces inserted next to CJK characters;
  - strip a trailing `。` in terminals;
  - no capitalization rules for CJK;
  - optional space between CJK and Latin (`用 npm 安装`).
- **Vocabulary rules:** whole-word boundaries only apply at Latin edges, so Chinese terms match inside Chinese text. Rules are also the practical fix for recurring mangled terms ("NTM" → npm).
- **Simplified ↔ Traditional:** optional conversion for zh_TW / zh_HK users (`StringTransform("Hans-Hant")`).
- **Metrics:** count CJK characters as words.

## Implemented (2026-10-13)

The Language setting shipped as decided above. The app's real `DictationEngine`, run by `spikes/asr-bench` target `engine-check` over the same 56 clips:

| Mode | English speech | Chinese speech | Mixed |
|---|---|---|---|
| English | 6.0% (Parakeet) | 100% | 94.7% |
| **Auto** | **6.0%** (20/20 routed to Parakeet) | **1.1%** (20/20 → 中文) | 28.8% (3/16 routed to English) |
| 中文 | 21.6% | **1.1%** | **22.7%** |

**SenseVoice input limit:** the model only accepts 0.2–30 s per call (larger inputs throw). `SenseVoiceTranscriber` splits longer audio into ≤28 s pieces, cutting at the quietest 100 ms in each piece's last 3 s, and joins the text (no spaces between Chinese). A 153 s Mandarin monologue: 1.1% CER (Auto), 1.5% (中文).

**Sticky language in Auto (2026-10-13).** With pieces, Auto decided the language per sentence, and per preview refresh, so short pieces flipped between Chinese and English. Now:

1. **The dictation's language becomes a hint** for later pieces and the preview: the language of the first piece that produced words.
2. **Inside a Chinese dictation, short pieces (< 4 s) stay Chinese.** Leaving Chinese also requires that SenseVoice *forced to Chinese* finds no Chinese characters.
3. **Pieces routed to Chinese against SenseVoice's own tag are re-transcribed forced-zh.** Its auto transcript is English-ish gibberish then ("Howo Y outhes." for 跑一下 tests).
4. **Chinese characters always win.**

Real engines (`session-check`, three runs each):

| Clip | Before | After |
|---|---|---|
| Chinese + English terms, Auto | 15.8–23.0%, with 0–1 pieces flipped to Parakeet | **10.8%** every run, 13/13 pieces Chinese |
| same clip, 中文 mode | 10.1% | 10.1–14.4% |
| Alternating en / zh / mixed sentences, Auto | 10.6% (spike, no stickiness) | **9.5%** |
| English 133 s / Chinese 153 s | unchanged: all Parakeet / all SenseVoice | |

**Trade-off:** short English sentences inside a Chinese dictation are transcribed by SenseVoice, which is weaker than Parakeet on jargon.

## Open risk

The two weak spots are short mixed utterances (LID picks English) and English terms inside Chinese sentences. Both need a **real-voice test** before deciding the default mode for bilingual users. Record about 15 phrases (zh, en, mix) as `NN.wav` with a matching manifest and rerun `zh-bench`.

## Re-run

```sh
cd spikes/asr-bench && swift build -c release --product zh-bench
.build/release/zh-bench <dir with manifest.tsv + NN_V.wav> [--details]
# manifest.tsv rows: file<TAB>lang(en|zh|mix)<TAB>length(short|normal)<TAB>voice<TAB>reference text
```
