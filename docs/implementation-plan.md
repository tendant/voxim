# voxim — Implementation Plan

**Status (2026-10-13):** steps 1–6 built; end-to-end dictation confirmed working on the installed `/Applications` build. Now dogfooding.

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
UI/         MenuView (status, shortcut hint), SetupSection (mic / Accessibility / model checklist), VocabularySettingsView + UsageView (Settings tabs), StatusHUD (non-activating, never key)
Support/    Log (no transcript contents), Metrics (events, summary, JSONL store), Duration helpers
```

## Phases

| Step | Deliverable | Acceptance |
|---|---|---|
| 1 ✅ | Project setup, audio capture, ASR spike | Local ASR works; Parakeet v2 chosen |
| 2 ✅ | Hold fn → transcribe → paste at cursor; HUD; permission handling; clipboard restore | Works in VS Code, Safari/Chrome text field, Notes, Slack, Ghostty; clipboard unchanged afterwards; never presses Return |
| 3 ✅ | Esc cancels while recording (swallowed only then); menu setup checklist for mic, Accessibility and speech model with fix-it buttons; Parakeet download/compile progress, Apple speech used meanwhile | No dead ends on a fresh install |
| 4 ✅ | Smart formatting (menu toggle, default on): leading space after a word, lowercase first word mid-sentence (keeps I/acronyms/mixed case), terminal style — no trailing period, lowercase start — in known terminal apps. Context = ≤3 chars before the cursor via AX; unreadable context → transcript only trimmed | Inserted text reads naturally in prose and in shells |
| 5 ✅ | Vocabulary as "when I say → type" replacement rules (Settings window; whole-word, case-insensitive, flexible spacing/hyphens, longest phrase first), applied before smart formatting. Acoustic biasing (FluidAudio CTC boosting, +~100 MB model) deferred | Day 1 misrecognitions (MUX→tmux, within PM→with npm) fixed by rules; homophones (pain/pane) out of reach |
| 6 ✅ | Local metrics: one text-free event per push-to-talk (outcome, failure reason, engine, audio length, release→transcript and transcript→⌘V timings, word count) in `~/Library/Application Support/voxim/metrics.jsonl`, 90-day retention; menu "today" line; Settings › Usage tab (period, p50/p95, failures by reason, reset, reveal file). Then dogfooding | Daily-use report and go/no-go |
| 7 🟡 | Pre-roll (menu toggle, default on): mic starts the moment fn goes down alone (only if mic + Accessibility are already granted, no HUD); a tap or fn+key discards that audio unheard and records nothing in metrics; a qualifying hold keeps it as the start of the clip. Trade-offs: mic indicator flashes on every fn press; Bluetooth headsets may switch to call quality | First word no longer clipped |

### Installable build

- `scripts/install.sh`: Release build signed with the Developer ID Application identity (team `WJTDTA46K5`), checks (Developer ID authority, hardened runtime, microphone entitlement present, no `get-task-allow`), quits a running copy, installs to `/Applications`, launches. Build number = git commit count.
- Entitlements come from `voxim.entitlements` (microphone only). `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` for the release build: plain `xcodebuild build` otherwise injects `get-task-allow` even in Release, and disabling injection also drops setting-generated entitlements — hence the explicit file.
- Launch at login via `SMAppService.mainApp` (menu toggle, only offered for the `/Applications` copy). Newest launched instance asks older ones to quit, so the installed copy and an Xcode run never both type.
- Debug builds use bundle ID `ai.weilabs.voxim.debug` ("voxim Dev"). With a shared ID, macOS kept one Accessibility grant whose code requirement matched only one signature (Apple Development vs Developer ID), so enabling it for one build silently broke the other. If a grant still looks on but voxim reports it missing: `tccutil reset Accessibility ai.weilabs.voxim`, relaunch, re-grant.
- `--adhoc` builds without an Apple Developer account (permissions re-prompt after each reinstall); `VOXIM_TEAM_ID` selects another Developer ID team.
- App icon is original artwork generated by `scripts/make-icon.swift` (SF Symbols' license forbids use in app icons).
- Not notarized: unnecessary for a locally built app (no quarantine). Needed before sharing a download with other people.

## Testing

- Unit: `FnHoldDetector` (hold vs tap, fn as modifier, other modifiers, keys while recording, Esc cancel, tap reset); `ModelStatus` (late progress can't override ready).
- Unit: `AppController` with fake mic/permissions/engine/sink (pre-roll kept through recording, tap discards unheard, toggle off, no mic grant → no pre-roll and no prompt, no Accessibility, Esc, fn during transcription).
- Unit: metrics (summary/percentiles, persistence, 90-day pruning, corrupt line, reset, stored keys are text-free, error→reason mapping).
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

## Dogfooding (after step 6)

Use voxim for daily work for a week, then read Settings › Usage (7 days) against the design's gates, adapted to dictation:

| Gate | Where to read it |
|---|---|
| Typed into the intended field ≥ 90% | "Typed successfully" (cancels and accidental taps excluded) |
| No text typed into the wrong app | "Focus changed" failures are the guard working; any wrong-app typing observed by hand is a blocker |
| Fast enough not to notice | "Release → text typed" p95 (target: under ~500 ms) |
| Voluntary daily use after the novelty period | Dictations and words per day in the second half of the week |
| Where it fails | Failures by reason → next fixes (e.g. many "No focused field" → revisit focus detection) |

Also note by hand when speaking helped or hurt versus typing; the metrics deliberately hold no text.

## Next candidates (pick from dogfooding data)

- **Acoustic vocabulary biasing:** FluidAudio CTC boosting (+~100 MB model) if replacement rules aren't enough.
- **Per-app paste timing:** tune the 250 ms clipboard-restore delay for apps that paste the old clipboard.
- **Notarization + prebuilt download:** needed before offering a release on GitHub; today visitors build from source.
- **Long dictation:** verified fine up to 133 s (see `docs/asr-spike.md`); no streaming needed.
