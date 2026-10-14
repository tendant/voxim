# Long dictation & streaming preview — plan

**Status:** all phases done (0–4). Progressive typing shipped as "Type as you speak" (default on, also for hold-to-talk); hands-free as "Double-tap fn for hands-free" (default on). Phase 0: [`long-dictation-spike.md`](long-dictation-spike.md), commit-as-you-go confirmed, Silero VAD chosen. Phase 1: pipeline in the app · **Date:** 2026-10-13 · Supersedes the earlier streaming-preview sketch.

## Problem

Today every dictation is: hold fn → buffer all audio → transcribe once on release. It works (verified to 133 s English, 153 s Chinese), but long dictations have four weaknesses:

1. **Physical:** holding fn for minutes is tiring, and an accidental release ends the dictation.
2. **All or nothing:** every word depends on one pass at the end. A failure, focus change or accidental release late in the dictation affects all of it.
3. **Cost grows with length:**
   - the release pass and each live-preview refresh re-transcribe everything (preview pass at 86 s: English 206 ms, Auto 470 ms, 中文 261 ms);
   - audio stays in memory until the end.
4. **The preview isn't really streaming:** it re-transcribes the whole clip about every 0.45 s.

## Approach: commit as you go

### 1. Split at pauses, transcribe each piece immediately

- A voice-activity detector splits the recording at natural pauses into sentence-sized **pieces**.
- Each finished piece is transcribed **right away in the background** with the normal batch engine, at full quality. The result is kept as final ("committed") text, and that piece's audio is discarded.
- On release, only the last piece remains to transcribe. Release latency stays constant (~0.05 s) however long you talked, and memory stays bounded.
- Cuts land at pauses, not fixed time windows. That avoids words being cut at chunk boundaries and handles SenseVoice's 30 s input limit naturally.
- **Auto mode:** language is detected per piece, so mixed English/Chinese dictations work per sentence.
- **The live preview comes along for free:**
  - committed pieces are the *confirmed* text;
  - the current piece is the *volatile* tail, re-transcribed while you talk.

  Cost per update is bounded by one piece, not the whole dictation.

### 2. Hands-free mode

- **Double-tap fn** locks recording on. The HUD shows a lock and an elapsed-time counter.
- **Tap fn** stops and types. **Esc** cancels and discards everything, committed pieces included.
- **Safety limits:**
  - auto-stop after ~30 s of silence;
  - a hard cap (~10 min) with a warning a minute before it hits.
- Hold-to-talk stays the default for quick dictations.

### 3. Optional: type each piece as it's committed (hands-free only)

Committed pieces never change, so typing them as they complete is safe, unlike volatile preview text. A long email appears sentence by sentence, and earlier sentences survive a late failure.

- The focus check runs before every piece. If you switch apps, typing pauses and the remainder is offered to copy.
- Setting, **off by default**.

## Design

| Component | Responsibility |
|---|---|
| `AudioCapture` | Pushes audio as it arrives (`onSamples` callback) instead of only buffering; pre-roll audio replayed at press |
| `PauseDetector` | Decides where a piece ends: Silero VAD (FluidAudio, 1 MB), pause ≥ 0.25 s (one 256 ms VAD chunk), piece ≥ 1.5 s, forced cut by 25 s at the quietest point in the last 3 s. Energy threshold rejected in the spike (fragments in noise) |
| `DictationSession` | Owns one dictation: queue of pieces, background transcription in order, committed text, volatile tail, cancellation |
| `DictationEngine` | Unchanged API: transcribes one piece in the current language mode (per-piece language detection in Auto) |
| `AppController` | Starts/stops sessions, hands-free state, typing on release (or per piece when enabled) |
| HUD | Confirmed text normal, volatile tail dimmed, lock + timer in hands-free mode |

Text rules (vocabulary, Chinese script and spacing) apply per piece. Context-aware formatting runs once on the joined text at release, or per piece when typing progressively, with the previous piece as the "text before the cursor".

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| 0 · Spike ✅ | In `spikes/asr-bench`: energy vs Silero pause detection on the 46/86/133 s English and 153 s Chinese clips; commit-as-you-go vs single batch pass; compare preview against Parakeet's native streaming (`SlidingWindowAsrManager`) | Joined-pieces error rate within ~0.5 pt of single-pass batch; release latency flat vs length; pick a detector |
| 1 · Pipeline ✅ | `PauseDetector`, `DictationSession`, push-based capture; release types joined committed text + last piece | Existing tests pass; long-dictation release latency ≈ constant; Esc discards everything |
| 2 · Preview on the pipeline ✅ | Replace the re-transcribe-everything loop with committed + volatile display | Preview cost per update flat over 2 min |
| 3 · Hands-free mode ✅ | Double-tap fn lock, tap to stop, silence auto-stop, cap with warning | Manual check; tests for state transitions and auto-stop |
| 4 · Progressive typing ✅ | Type each committed piece in hands-free mode, focus check per piece | Off by default; focus change pauses and offers the rest to copy |

## Risks and open questions

- **Seam quality:** each piece loses context from the previous one, so engines may capitalize or punctuate each as a new sentence. The formatter already fixes mid-sentence capitals; the spike measures any accuracy loss.
- **Pause detection in noise:** an energy threshold may cut too often or never in noisy rooms. Silero VAD is the fallback; there's also the forced cut by ~25 s.
- **Mic left on in hands-free mode:** needs an unmistakable recording indicator, silence auto-stop and the cap.
- **Native streaming engines:** Parakeet's `SlidingWindowAsrManager` and the Parakeet Unified streaming model (separate download, ~2 s latency) remain options for the volatile preview if per-piece re-transcription feels laggy. Decide after the spike; not needed for the final text.

## Phase 1 results (2026-10-13)

- **Built:** `PauseDetector` (pure, tested), `VoiceActivityModel` / `SileroSpeechClassifier` (Silero loaded once, one streaming state per dictation), and `DictationSession`. Audio is pushed in via `AudioCapture.onSamples`; pieces are transcribed in order in the background and their audio dropped. The controller starts a session with the mic (including pre-roll), discards it on tap/Esc, and finishes it on release.
- **Fallback:** without the VAD model (e.g. offline on first run), a session is one piece at release, i.e. the previous behavior.
- **Failures:** if a piece fails, nothing is typed and the recognized rest is offered to copy.
- **Metrics:** dictations spanning languages record `mixed`.
- **App's real session** (`spikes/asr-bench` target `session-check`, replay at 10× real time):

| Clip | Mode | Pieces | MER | Release → text | Previous (single pass) |
|---|---|---|---|---|---|
| en 46 s | English | 8 | 1.5% | 55 ms | ~140 ms |
| en 133 s | English | 23 | 1.2% | 55 ms | ~300 ms |
| zh 153 s | 中文 | 12 | 0.8% | 126 ms | ~440 ms |
| zh 153 s | Auto | 12 | 1.1% | 123 ms | ~440 ms |

- **Live preview** still re-transcribes the whole clip; it moves onto the pipeline in phase 2.

## Type as you speak (2026-10-13)

Brought forward from phase 4 at the user's request, **default on**, and available while holding fn (not only hands-free).

- **Typing:** `ProgressiveTyper` consumes the session's ordered `committedPieces` stream and types each piece as soon as it's transcribed. Formatting uses the real field for the first piece, then what this dictation already typed (spacing and capitalization continue naturally).
- **Stopping:** the first failure stops typing — a focus change, secure input, or a failed piece. Text already typed stays; the rest is offered to copy.
- **Esc:** stops further typing; typed text stays (⌘Z removes it).
- **Terminals:** still type once at release, because terminal style (no trailing period) needs the whole text.
- **Live preview:** now transcribes only the piece in progress (phase 2). It shows just that tail when typing as you speak, otherwise committed text + tail.
- **Menu toggle:** "Type as you speak"; off restores type-at-release.
- **Tests:** five controller tests with real sessions, a loudness classifier and a fake mic. They cover typing before release, Esc, toggle off, terminals, and a focus change mid-dictation.

## Hands-free (2026-10-13)

- **Gesture:** a quick fn press-release is now reported as `.tap`. `DoubleTapDetector` turns two taps whose releases are ≤ 0.45 s apart into `.lock`. The second tap's pre-roll session becomes the recording, so speech right after the double-tap isn't lost.
- **While locked:**
  - a tap (or a press-and-release) of fn finishes;
  - **Esc** cancels: the detector's `handsFree` flag lets Esc cancel without fn held;
  - Type as you speak keeps typing sentence by sentence.
- **Safety:**
  - auto-finish after **30 s** of silence (the session's VAD reports seconds since speech);
  - a **10 min** cap, with a countdown in the last minute;
  - the HUD shows a lock, an elapsed timer and the controls throughout.
- **Accidental-tap filter:** the 250 ms minimum hold doesn't apply to hands-free stops, since the recording was started deliberately.
- **Metrics:** events carry `handsFree: true`; Usage shows the count.
- **Conflict:** macOS's "Press 🌐 key to: Start Dictation" also reacts to fn taps. It must be set to Do Nothing; the menu already warns while it isn't.
- **Tests:** detector (tap, Esc in hands-free), `DoubleTapDetector` timing, and six controller tests — lock + typing + tap to finish, Esc, silence auto-stop, cap with countdown, setting off, hold-and-release to finish.

## Idle hands-free (2026-10-13)

The user wanted hands-free to wait longer and idle in the background:

- **Limits are settings** (Settings › General): *Finish after silence* 30 s / 2 min / **5 min** (default) / Never; *Maximum length* 10 min / 30 min / **1 hour** (default) / No limit.
- **Idle pill:** after 5 s without speech, the HUD shrinks to a small "🔒 Hands-free · listening · m:ss" pill. It expands again when speech or preview text appears, and never disappears while the mic is on.
- **No transcribing silence:** forced 25 s cuts of pieces with no speech are dropped instead of transcribed, which would have cost CPU and risked engines "hearing" stray words.
- **Constant memory:** `AudioCapture` no longer keeps its own copy of audio while a session consumes it (previously ~230 MB per hour). It only counts captured seconds for metrics.
