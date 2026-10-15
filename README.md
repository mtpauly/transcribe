# Transcribe

A small macOS app that records your voice, transcribes it with OpenRouter, and pastes the text into the focused app.

| Key | Action |
|---|---|
| Option+Space | Start / stop recording; the transcript is pasted where your cursor is |
| Escape | Cancel while recording or transcribing |
| Option+Shift+V | Paste the last transcript again |

Your clipboard is restored after pasting. The app has no Dock icon or window; a menu-bar icon shows its state, and clicking it gives recording controls, the last transcript, config and log paths, and Reload Config.

## Setup

Requires macOS 13+, Swift 6+, Xcode Command Line Tools, and an OpenRouter API key.

```sh
mkdir -p "$HOME/Library/Application Support/Transcribe"
install -m 600 config.example.json "$HOME/Library/Application Support/Transcribe/config.json"
```

Edit `config.json`:

| Key | Meaning |
|---|---|
| `openrouter_api_key` | Required |
| `model` | OpenRouter transcription model (default `microsoft/mai-transcribe-2`) |
| `save_recordings` | `true` to keep every recording as a WAV file |
| `recordings_directory` | Where to save them (default `recordings/` next to `config.json`) |

Use **Reload Config** in the menu-bar menu to apply changes without restarting.

Builds are signed with a certificate named `Transcribe Dev` so macOS keeps the Accessibility grant across rebuilds. Create it once in Keychain Access → Certificate Assistant → Create a Certificate (**Self-Signed Root**, **Code Signing**), set Trust → Code Signing to **Always Trust**, or pass `SIGN_IDENTITY="…"` to `make`.

## Build and run

```sh
make test     # run tests
make run      # stop any running instance, rebuild, launch
make stop     # stop without rebuilding
make verify   # check signature, entitlements, and plists
make logs     # follow ~/Library/Logs/Transcribe.log
make clean    # remove build output
```

On first launch, grant **Transcribe** Accessibility access in System Settings → Privacy & Security, then launch again. Microphone access is requested on first recording.

## Feedback

| Sound | Meaning |
|---|---|
| Tink | Recording started |
| Pop | Recording stopped; transcribing |
| Funk | Ignored because busy |
| Basso | Something failed; see the log |

The log includes the full text of every transcript.

## Layout

- `Sources/Transcribe`: the app
- `Tests/TranscribeTests`: tests
- `bundle`: Info.plist and entitlements
- `Makefile`: builds, bundles, and signs the `.app`
