# voxim

Local push-to-talk dictation for macOS. Hold **fn**, speak, release — the text is typed at the cursor of whatever app has focus. Speech is transcribed on this Mac (Parakeet TDT v2, with Apple's on-device speech as fallback); audio is never stored or uploaded.

## Install

```sh
scripts/install.sh              # build Release (Developer ID signed), install to /Applications, launch
scripts/install.sh --build-only # build and verify the signature only
```

Requires Xcode 26, macOS 26, and a "Developer ID Application" identity for team `WJTDTA46K5` in the keychain. Reinstalling keeps the Microphone and Accessibility permissions, because the signing identity stays the same.

First run:

1. Grant **Accessibility** when asked (needed to see the fn key and type into apps), and **Microphone** on the first dictation. The menu-bar checklist shows what's missing.
2. Set System Settings › Keyboard › "Press 🌐 key to" to **Do Nothing**, or releasing fn also triggers that action.
3. The speech model (~450 MB) downloads on first launch; Apple speech is used until it's ready.
4. Optional: turn on **Launch at login** in the menu.

## Use

- Hold **fn** until "Listening…" appears, speak, release. **Esc** while listening cancels.
- voxim never presses Return. If it can't type (focus moved, password field, no text field), the transcript is offered to copy.
- **Settings › Vocabulary**: "when I say → type" rules for words the recognizer gets wrong.
- **Settings › Usage**: local counts and timings (never what you said).

## Development

Open `voxim.xcodeproj` and run the `voxim` scheme. Running a copy from Xcode makes the installed copy quit (only one instance listens for fn at a time). Plan and decisions: [`docs/implementation-plan.md`](docs/implementation-plan.md).
