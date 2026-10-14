# Transcribe

This repository contains a small native macOS application built with Swift Package Manager:

1. Press Option+Space to begin recording.
2. Press Option+Space again to stop.
3. The app sends the recorded audio, held in memory as WAV, to OpenRouter.
4. The resulting text is pasted into the focused application.

Press Escape while recording or waiting on OpenRouter to cancel; nothing is pasted. Escape passes through to other apps at all other times.

Press Option+Shift+V to paste the most recent transcript again. It is kept in memory only, so it is gone after the app quits.

The app has no Dock icon, window, menu-bar item, helper, LaunchAgent, login item, or installer. It runs as one signed process and uses short system sounds for recording and error feedback.

## Requirements

- macOS 13 or later
- Swift 6.0 or later
- Xcode Command Line Tools
- An OpenRouter API key

The Xcode application and an `.xcodeproj` are not required for development.

## Configuration

Create the configuration file if it does not already exist:

```sh
mkdir -p "$HOME/Library/Application Support/Transcribe"
install -m 600 config.example.json "$HOME/Library/Application Support/Transcribe/config.json"
```

Then edit `config.json` and replace `replace-me` with the API key. The optional `model` field selects the OpenRouter transcription model.

Set `"save_recordings": true` to keep a copy of every recording as a WAV file. Files go to `~/Library/Application Support/Transcribe/recordings/` unless `recordings_directory` names another folder (`~` is expanded). A recording is saved as soon as it stops, so it is kept even when transcription fails. Saved recordings are never deleted automatically.

## Build and run

```sh
make test
make run
```

`make run` stops an existing running instance before rebuilding. Stop it without rebuilding by running:

```sh
make stop
```

The bundle is created at `build/Transcribe.app`. The first launch requests Accessibility permission. Grant **Transcribe** access under System Settings → Privacy & Security → Accessibility, then launch it again. Microphone permission is requested the first time recording starts.

Builds are signed with a code-signing certificate named `Transcribe Dev` so that macOS keeps the Accessibility grant across rebuilds. An ad-hoc signature changes with every build and forces a re-grant. Create the certificate once in Keychain Access → Certificate Assistant → Create a Certificate (identity type **Self-Signed Root**, certificate type **Code Signing**), then set its Trust → Code Signing to **Always Trust**. Choose **Always Allow** when `codesign` first asks to use the key. To sign with a different certificate:

```sh
make run SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

Do not add the development build to Open at Login during normal development. Once the prototype is stable, copy the bundle to a fixed location and add that copy manually.

## Feedback and logs

- Tink: recording started
- Pop: recording stopped and transcription began
- Funk: input ignored because the application is busy
- Basso: an operation failed

Logs are written to:

```text
~/Library/Logs/Transcribe.log
```

Follow them with:

```sh
make logs
```

## Architecture

- `Sources/Transcribe`: one executable target containing the workflow and macOS integration
- `Tests/TranscribeTests`: focused tests for state transitions, configuration, and request encoding
- `bundle`: application metadata and the Hardened Runtime audio-input entitlement
- `Makefile`: builds the SwiftPM executable, assembles the `.app`, and signs it

The keyboard event-tap callback only recognizes and consumes Option+Space, Option+Shift+V, and Escape while a recording or transcription is in progress, before scheduling the workflow on the main actor. It performs no audio, file, pasteboard, or network work.

The executable initializes `NSApplication` even though no interface is displayed. A future `NSStatusItem` menu can therefore be added without changing the coordinator architecture.

The original Python prototype remains in `transcribe.py` for reference.

## Intentionally omitted

- Menu-bar interface and settings
- Automatic login registration
- Keychain storage
- Configurable shortcuts or microphones
- Streaming, retry logic, history, or local models
- Clipboard restoration (the transcription remains on the clipboard after pasting)
- Distribution signing, notarization, Homebrew cask, and automatic updates
