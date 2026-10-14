# Transcribe

This repository contains a small native macOS application built with Swift Package Manager:

1. Press Option+Space to begin recording.
2. Press Option+Space again to stop.
3. The app sends the WAV file to OpenRouter.
4. The resulting text is pasted into the focused application.

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

## Build and run

```sh
make test
make run
```

`make run` stops an existing Swift development instance before rebuilding. Stop it without rebuilding by running:

```sh
make stop
```

The development bundle is created at `build/Transcribe Swift Dev.app`. The first launch requests Accessibility permission. Grant **Transcribe Swift Dev** access under System Settings → Privacy & Security → Accessibility, then launch it again. Microphone permission is requested the first time recording starts.

The default build uses an ad-hoc signature. For more stable permissions across rebuilds, use a consistent signing certificate:

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
~/Library/Logs/Transcribe Swift Dev.log
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

The keyboard event-tap callback only recognizes and consumes Option+Space before scheduling the workflow on the main actor. It performs no audio, file, pasteboard, or network work.

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
