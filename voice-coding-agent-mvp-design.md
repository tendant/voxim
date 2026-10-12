# Voice Interface for Coding Agents — MVP Design

**Status:** Proposed · **Date:** 2026-10-11 · **Timebox:** 14 days / 20–30 engineering hours

## 1. Goal

Validate whether a lightweight, local-first voice interface makes interacting with an existing coding agent faster and more comfortable than typing. The differentiator is **agent-aware commands**, not another generic dictation app.

**Day-2 milestone:** Hold a shortcut, say “Run the unit tests and fix the failures,” release, and deliver the instruction to the intended active coding-agent input.

**Success after two weeks:** The author voluntarily uses the tool in real coding sessions, with reliable delivery and clear evidence of when voice is preferable to typing.

## 2. Scope

### MVP

- macOS menu-bar utility with visible recording/transcribing/sending/error states.
- Two explicit push-to-talk modes:
  - **Dictate** (`Option+Space`, configurable): transcribe and insert into the focused editable field.
  - **Agent** (`Option+Shift+Space`, configurable): transcribe and submit to an explicitly selected coding-agent target.
- Local ASR; start with an existing macOS-compatible implementation (prefer reusing a working OSS dictation stack over building one).
- One initial target: a terminal-hosted coding-agent session (Claude Code as first validation target).
- Basic correction: review/edit pending transcript before sending, plus cancel before dispatch.
- Local-only preferences and minimal privacy-preserving diagnostic counters.

### Out of scope

- New ASR model/runtime, model training, cloud backend, authentication, payments.
- LiveKit, WebRTC, Kubernetes, TTS, voice conversations, wake-word detection.
- General desktop autonomy, screen scraping, broad context harvesting.
- New agent framework, sandbox backend, multi-agent orchestration, durable workflows.
- Guaranteed session discovery or cancellation for agents that lack a supported API.

## 3. Product Behavior

### Dictation mode

1. User presses and holds Dictate shortcut.
2. Capture microphone audio; show recording state.
3. On release, finalize recognition.
4. Insert text into the focused editable element; **do not automatically submit**.
5. If insertion is unavailable, present a copyable transcript and a clear error.

### Agent mode

1. User selects a target (initially a terminal window/session) and presses Agent shortcut.
2. Capture and transcribe speech.
3. Display a short, editable pending command with target identity; user confirms submission. An optional auto-send preference can be tested later, default off.
4. Deliver command through the selected adapter; show `sent` only when delivery is acknowledged at the supported boundary.
5. If target is stale, ambiguous, or unavailable, **do not guess or redirect**; keep text available for retry/copy.

**Important:** “Delivered” means the adapter successfully submitted input, **not** that the agent accepted, executed, or completed the instruction.

### Context and corrections

- MVP context is limited to selected target identity, app/window title, and optional user-initiated selected-text capture.
- No silent clipboard or screen collection.
- “Change X to Y” can initially be implemented as editing the pending transcript, not as modifying an already submitted agent instruction.
- Once sent, cancellation or amendment is adapter-specific and is not promised in v1.

## 4. Architecture

```text
macOS menu-bar app
  ├── ShortcutManager ──► Mode (Dictate | Agent)
  ├── AudioCapture (AVFoundation)
  ├── Transcriber (local ASR adapter)
  ├── PendingTranscript UI (edit / cancel / send)
  ├── DictationSink (Accessibility / paste fallback)
  ├── TargetManager (explicit selection + validity check)
  └── AgentAdapter
       └── TerminalTargetAdapter (initial implementation)
             └── Existing coding agent
```

**Implementation strategy:** Start with an existing OSS dictation application if its license, architecture, and extension points make it economical. Otherwise build a minimal Swift menu-bar app. Keep the ASR implementation behind a small interface to avoid coupling to a specific model.

### Component interfaces (conceptual)

```swift
enum InputMode { case dictate, agent }

protocol Transcriber {
    func transcribe(_ audio: AudioBuffer) async throws -> String
}

protocol DictationSink {
    func insert(_ text: String, into target: FocusedElement) async throws
}

protocol AgentAdapter {
    func validate(_ target: AgentTarget) async throws
    func submit(_ text: String, to target: AgentTarget) async throws -> DeliveryReceipt
}
```

No generic session-listing or cancellation contract until the first real integration demonstrates those capabilities.

## 5. Agent Integration Decision

**Preferred:** A supported API or extension mechanism that can address the intended running agent session and acknowledge delivery.

**Fallback for two-week validation:** Explicitly bind a known terminal window/input and inject the confirmed command through Accessibility or terminal-specific automation. This is a **best-effort UI integration**, not a stable Claude Code session API.

Rules:

- Never send to whichever terminal happens to be frontmost without explicit binding or user confirmation.
- Do not synthesize Enter until the user confirms sending.
- Detect closed/changed windows and stop rather than silently choosing another target.
- Distinguish `injected_into_terminal` from `accepted_by_agent` in logs and UI.
- Prefer manual re-selection over unreliable session heuristics.

## 6. macOS Details

- **Swift + AppKit/SwiftUI:** Menu bar, overlay, preferences.
- **AVFoundation:** Audio capture and microphone permission.
- **Accessibility:** Focused-element insertion and optional target interaction; handle permission denial explicitly.
- **Shortcuts:** Register configurable system-wide shortcuts, detect collisions, and avoid interfering with standard OS shortcuts.
- **Local ASR:** Evaluate Parakeet/MLX or an existing bundled runtime on the actual target Mac. Check model distribution and license before packaging.
- **Fallback insertion:** Clipboard-based paste only with explicit handling; preserve/restore prior clipboard content when feasible and warn about clipboard exposure.

No background audio recording when push-to-talk is inactive. Audio is discarded after transcription by default.

## 7. Reliability and Safety

| Failure | Behavior |
|---|---|
| Mic/Accessibility permission denied | Explain required permission; no silent fallback |
| ASR error or empty transcript | Show retry; do not send |
| No editable field | Show copyable transcript |
| Missing/stale agent target | Require re-selection |
| Multiple possible targets | Ask user to choose; never guess |
| Shortcut collision | Prompt to remap |
| Agent command with destructive effect | User must confirm submission; agent retains its own approval safeguards |
| Unexpected process/app focus change | Revalidate target before delivery |

Treat recognized text as **user input**, not trusted system instructions. The app must not bypass the coding agent's own approval controls. No credential collection or elevated privileges.

## 8. Privacy

- Default local transcription; no audio uploads.
- Do not persist raw audio or transcript history by default.
- Store only preferences, explicit target binding, and aggregate operational metrics locally.
- Debug logs must exclude transcript contents, selected text, clipboard contents, and secrets unless the user explicitly opts into a temporary diagnostic mode.
- Make microphone recording state unmistakable.

## 9. Implementation Plan

| Day | Work | Acceptance |
|---|---|---|
| 1 | Evaluate reuse of Handy / VoiceInk / BetterWispr; select implementation | Written build-vs-extend decision; local ASR runs |
| 2 | Push-to-talk → ASR → confirmed agent input | Spoken test instruction reaches chosen coding-agent input |
| 3–4 | Dictation mode and focused-field insertion | Works in terminal, editor, browser text field |
| 5 | Menu bar, permissions, target selection | Permission failures and stale targets handled |
| 6–7 | Pending transcript edit/cancel/confirm | No accidental auto-submission |
| 8–9 | Target validation and delivery receipts | No silent misrouting; meaningful status |
| 10 | Selected-text context (optional) | Only captured on explicit request |
| 11–14 | Daily dogfooding and instrumentation | Usability report and go/no-go decision |

**Scope cut order if behind schedule:** selected-text context → polish → configurable shortcuts → extra insertion fallbacks. Preserve reliable targeting and explicit confirmation.

## 10. Evaluation

Record counts and timings without transcript content:

- Dictation and agent commands per day.
- Capture-stop → transcript-ready latency (p50/p95).
- Transcript-ready → delivery latency (p50/p95).
- Successful delivery / failed delivery / wrong-target incidents.
- Manual edit rate, retries, and keyboard fallback.
- Qualitative notes on when speaking helps or hurts.

**Provisional gates (not industry benchmarks):**

- Zero observed wrong-target submissions during testing.
- ≥90% successful delivery to an explicitly selected available target.
- Voluntary daily use after the novelty period.
- Evidence that agent mode adds value beyond dictation-only tools.

**Decision at Day 14:**

- **Continue:** Repeated use and demonstrable agent-mode value; recruit 5–10 external developers.
- **Narrow:** Dictation useful but agent mode weak; improve one concrete integration issue only.
- **Stop:** Little repeat usage or no advantage over existing tools; return focus to agent sandboxing / voice-agent evaluation.

## 11. Open Decisions

1. **Primary coding-agent surface:** Terminal (Ghostty/iTerm2/Terminal), VS Code, or another app? Default assumption: terminal-hosted Claude Code.
2. **Reuse vs build:** Choose after a one-day spike based on code quality, licensing, ASR performance, and integration extensibility.
3. **ASR packaging:** Bundled model versus first-run download; optimize for easiest personal installation first.
4. **Command delivery:** Prefer a supported session API if available; otherwise use explicitly bound terminal UI injection as a disposable prototype.

## 12. Guiding Principle

**Build the smallest reliable bridge from speech to an existing coding-agent session.** Do not build an agent platform to validate a voice interface. If two weeks of actual usage reveal a compelling workflow, then invest in deeper context awareness and supported agent integrations.
