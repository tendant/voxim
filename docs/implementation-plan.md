# voxim — Implementation Plan

Implements [voice-coding-agent-mvp-design.md](../voice-coding-agent-mvp-design.md). **Date:** 2026-10-12

## Decisions

- **Build, don't extend.** The repo is a fresh SwiftUI app targeting macOS 26; the Day 1 spike only compares ASR engines.
- **ASR:** macOS 26 on-device `SpeechAnalyzer` / `SpeechTranscriber` first (OS-managed model via `AssetInventory`, nothing to bundle or license). Parakeet (FluidAudio CoreML) is benchmarked behind the same `Transcriber` protocol.
- **Agent delivery:** Claude Code runs inside tmux, so `TmuxAdapter` is primary:
  - Addressing: pane IDs (`%7`) are stable for the pane's lifetime and never reused within a tmux server run.
  - Delivery: `tmux load-buffer -` → `paste-buffer -p -t %7` (bracketed paste; newlines don't submit early) → `send-keys -t %7 Enter`. Exit code 0 is the `injected_into_terminal` receipt.
  - Validation before every send: `tmux display -p -t %7 '#{pane_current_command}'` — pane exists and runs `claude`/`node`.
- **Fallback:** `GhosttyAXAdapter` binds a specific window (pid + AX window), revalidates, raises, pastes, presses Enter. Best-effort; receipt is only `injected_into_terminal`.
- **App sandbox off** (AX insertion, synthetic keystrokes and spawning `tmux` are blocked under sandbox). Hardened runtime stays on.

## Project setup

- `ENABLE_APP_SANDBOX = NO`; `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES` (audio-input entitlement under hardened runtime).
- Info.plist: `LSUIElement = YES`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- `MenuBarExtra` + `Settings` scene instead of `WindowGroup`.
- SPM: `sindresorhus/KeyboardShortcuts` (key-down/key-up for push-to-talk, recorder UI, no Accessibility needed).
- Keep signing with team `WJTDTA46K5` so the Accessibility grant survives rebuilds.

## Code layout (`voxim/`, synchronized groups)

```
App/        voximApp, AppController (idle→recording→transcribing→pending→sending→sent|error)
Input/      ShortcutManager, AudioCapture (AVAudioEngine tap → 16 kHz mono Float32, memory only)
ASR/        Transcriber protocol, AppleSpeechTranscriber, (spike) ParakeetTranscriber
Dictation/  DictationSink protocol, AXInsertSink (kAXSelectedTextAttribute), PasteSink (clipboard save/restore + ⌘V)
Agent/      AgentTarget, AgentAdapter protocol, TmuxAdapter, GhosttyAXAdapter, TargetManager, DeliveryReceipt
UI/         MenuBarView, PendingPanel (NSPanel: editable text, target label, ⏎ send / esc cancel), StatusHUD, SettingsView
Support/    Permissions (mic + AXIsProcessTrusted), Metrics (counters + latency samples → JSON in App Support), Log (os.Logger, privacy: .private)
```

## Phases

| Days | Deliverable | Acceptance |
|---|---|---|
| 1 ✅ | Project settings; `AudioCapture` + `AppleSpeechTranscriber` behind a debug menu item; ASR spike Apple vs Parakeet on coding phrases | Local ASR works; numbers in `docs/asr-spike.md` → Parakeet TDT v2 default, Apple fallback |
| 2 | Hold ⌥⇧Space → record → transcribe → `PendingPanel` → `TmuxAdapter` to a chosen pane | "Run the unit tests and fix the failures" lands in Claude Code, submits only after ⏎ |
| 3–4 | Dictation (⌥Space): AX insert → paste fallback → copyable transcript on failure | Works in Ghostty, VS Code, Safari field; never presses Enter |
| 5 | Menu bar state icon (unmistakable while recording), permission onboarding, tmux pane picker | Denied mic/AX explains itself; no silent fallback |
| 6–7 | Pending panel edit/cancel/retry; empty transcript blocks send; auto-send pref default off | No path submits without confirmation |
| 8–9 | `TargetManager` revalidation before every send; receipts distinguish `injected_into_terminal` vs unknown acceptance; Ghostty fallback adapter | Kill pane mid-flow → error + text retained, never misrouted |
| 10 | (cuttable) "Include selection" button captures AX selected text on click only | Nothing captured implicitly |
| 11–14 | Metrics view (counts, p50/p95, edit rate, failures), dogfooding, usability report | Go/no-go per design gates |

Scope cut order follows the design; targeting and explicit confirmation are never cut.

## Testing

- Unit: state-machine transitions (cancel/error at every stage), `TmuxAdapter` with a fake process runner (stale pane, non-claude command, non-zero exit), clipboard restore, metrics never store transcript text.
- Manual: each of the eight failure rows in design §7 reproduced once before dogfooding.

## Known risks

- Text already typed in Claude Code's input gets appended to; v1 warns rather than detects.
- AX insertion into Ghostty likely fails → terminal dictation uses paste; measure it.
- `SpeechTranscriber` may mangle code identifiers; the Day 1 spike decides whether Parakeet is needed.
