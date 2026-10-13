# voxim — Implementation Plan

**Date:** 2026-10-12 · Started from [voice-coding-agent-mvp-design.md](../voice-coding-agent-mvp-design.md); **re-scoped the same day to a generic voice input tool.**

## Scope

A local-first macOS menu-bar dictation tool: **hold fn**, speak, release, and the text is typed at the cursor of whatever app has focus (editor, browser, chat, terminal, …).

- **In:** push-to-talk, local ASR, typing into the focused field, a copyable transcript when typing isn't possible, unmistakable recording state.
- **Out (dropped in the re-scope):** agent mode, coding-agent/terminal targeting, tmux integration, confirm-before-send panel. The removed Day 2 agent/tmux code is preserved as `docs/archive/day2-agent-mode.patch`.
- Still out per the design: cloud ASR, TTS, wake words, context harvesting, auto-pressing Return.

## Decisions

- **ASR:** Parakeet TDT v2 (FluidAudio, Apache-2.0) is the default; Apple `SpeechTranscriber` is the zero-download fallback while Parakeet loads or if it fails. See `docs/asr-spike.md`.
- **Insertion:** clipboard + synthetic ⌘V, the one method that works across native, browser, Electron and terminal inputs. The previous clipboard is snapshotted and restored, unless something else wrote to it meanwhile. Dictated entries are marked `org.nspasteboard.TransientType` so clipboard managers skip them.
- **Safety:** never presses Return. Refuses to type if focus moved to another app while speaking, if no element has focus, or if secure input (password fields) is active. In those cases it shows the transcript with Copy.
- **Permissions:** Microphone (record) and Accessibility (post ⌘V, read focus). Each missing permission is explained, with no silent fallback.
- **Shortcut: hold fn, fixed.** Holding fn alone for 300 ms starts recording; releasing fn stops it. fn used as a modifier (fn+arrow, fn+F-key, fn+E) or together with ⌘⌃⌥⇧ never starts recording, and no events are swallowed. Carbon hotkeys can't express fn, so a session `CGEventTap` observes key events; it needs Accessibility, so voxim asks at launch and retries until granted. Decision logic lives in `FnHoldDetector` (unit-tested).
- **🌐 key conflict:** System Settings › Keyboard › "Press 🌐 key to" fires on fn release. On this Mac it's set to Start Dictation; the menu warns until it's set to Do Nothing.
- **App sandbox off**, hardened runtime on. Signed with team `WJTDTA46K5` so the Accessibility grant survives rebuilds.

## Code layout (`voxim/`)

```
App/        voximApp (MenuBarExtra + HUD wiring), AppController (idle→recording→transcribing→inserted|failed)
Input/      ShortcutManager (fn event tap, Esc cancel, 🌐 setting check), FnHoldDetector, AudioCapture (16 kHz mono, memory only)
ASR/        Transcriber, AppleSpeechTranscriber, ParakeetTranscriber, FallbackTranscriber, ModelStatus
Dictation/  DictationSink, PasteInserter (clipboard snapshot/restore + ⌘V), AXAccess, FocusedApp, FocusContext (chars before cursor, terminal detection), TextFormatter, Replacements (rules + store)
UI/         MenuView (status, shortcut hint), SetupSection (mic / Accessibility / model checklist), VocabularySettingsView (Settings window), StatusHUD (non-activating, never key)
Support/    Log (no transcript contents), Duration helpers
```

## Phases

| Step | Deliverable | Acceptance |
|---|---|---|
| 1 ✅ | Project setup, audio capture, ASR spike | Local ASR works; Parakeet v2 chosen |
| 2 🟡 | Hold fn → transcribe → paste at cursor; HUD; permission handling; clipboard restore | Works in VS Code, Safari/Chrome text field, Notes, Slack, Ghostty; clipboard unchanged afterwards; never presses Return |
| 3 🟡 | Esc cancels while recording (swallowed only then); menu setup checklist for mic, Accessibility and speech model with fix-it buttons; Parakeet download/compile progress, Apple speech used meanwhile | No dead ends on a fresh install |
| 4 🟡 | Smart formatting (menu toggle, default on): leading space after a word, lowercase first word mid-sentence (keeps I/acronyms/mixed case), terminal style — no trailing period, lowercase start — in known terminal apps. Context = ≤3 chars before the cursor via AX; unreadable context → transcript only trimmed | Inserted text reads naturally in prose and in shells |
| 5 🟡 | Vocabulary as "when I say → type" replacement rules (Settings window; whole-word, case-insensitive, flexible spacing/hyphens, longest phrase first), applied before smart formatting. Acoustic biasing (FluidAudio CTC boosting, +~100 MB model) deferred | Day 1 misrecognitions (MUX→tmux, within PM→with npm) fixed by rules; homophones (pain/pane) out of reach |
| 6 | Local metrics (counts, p50/p95 latency, failures by reason — never text), dogfooding | Daily-use report and go/no-go |

## Testing

- Unit: `FnHoldDetector` (hold vs tap, fn as modifier, other modifiers, keys while recording, Esc cancel, tap reset); `ModelStatus` (late progress can't override ready).
- Unit: `ReplacementEngine` (Day 1 outputs, whole words, flexible spacing, longest-first, literal regex chars, Unicode boundaries).
- Unit: `TextFormatter` (start of field, after sentence end, mid-sentence, special first words, brackets/prefixes, terminal style).
- Unit: `PasteInserter` with a private pasteboard and fake ⌘V poster (restore, transient marker, empty clipboard, clipboard changed meanwhile, secure input refused).
- Manual matrix: target apps × {normal, focus switched mid-speech, password field, no focused field, Accessibility revoked, mic denied}.

## Known risks

- Many apps (terminals, some Electron editors) don't expose the text before the cursor via AX; there smart formatting only applies terminal style or nothing. Proper nouns at the start of a mid-sentence dictation get lowercased ("…and Python" → "…and python").

- A few apps ignore synthetic ⌘V or read the clipboard late; the 250 ms restore delay may need tuning per app.
- Restoring the clipboard is best-effort: exotic promised/lazy pasteboard types may not round-trip.
- The paste is posted with explicit ⌘-only flags so modifiers the user happens to hold don't alter it; check apps with custom key handling.
- Recording starts 300 ms after fn goes down, so speech in that window is lost; the HUD appearing is the cue to talk. Tune after dogfooding.
