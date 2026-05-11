# Voxflow

Native macOS dictation built for coding. Hold the Fn (Globe) key, talk, release, get cleaned-up code-aware text in the focused app. Local STT, local cleanup, no dock icon, just a small menu bar item near the battery.

The full spec lives in `project.md`. The active task list lives in `TODO.md`.

## Features

- **Hold-to-dictate.** Hold the Fn key, talk, release. Cleaned text is pasted into the focused app.
- **Double-tap to lock.** Double-tap Fn to lock dictation on. Single tap to stop.
- **Token-efficient.** Short, plain prose is pasted as-is with no LLM round-trip. Identifier spellings ("u s e r underscore i d") are routed through the cleanup model verbatim. Repeated identity passes are cached so frequent inputs skip the LLM entirely.
- **Menu bar only.** No dock icon, no tray icon, no app-switcher entry — `LSUIElement = true`.
- **Local everything.** On-device transcription via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal-accelerated), local Ollama for cleanup. Apple's Speech Recognition framework is never used — no "Voxflow would like to access Speech Recognition" prompt. No data leaves the machine unless you point cleanup at a remote model.

## Build from source

```bash
swift build              # SPM debug build
swift test               # run unit tests (35 currently)
scripts/build-app.sh     # produce build/Voxflow.app (ad-hoc signed)
open build/Voxflow.app   # run; look in the menu bar near the battery
```

## First-run permissions

macOS will prompt for these the first time the app needs them. You can also see live status in **Voxflow → Open Settings → Permissions**, with one-click jumps into the right Privacy & Security pane.

| Permission | Why | Where to grant |
|---|---|---|
| Microphone | Capture audio while the hotkey is held | System Settings → Privacy & Security → Microphone |
| Input Monitoring | Detect the global Fn-key hotkey | System Settings → Privacy & Security → Input Monitoring |
| Accessibility | Synthesize Cmd+V (or per-character keystrokes) into the focused app | System Settings → Privacy & Security → Accessibility |

If the menu bar icon shows "Status: Grant Input Monitoring in Privacy & Security", the CGEventTap couldn't register — flip the toggle in the Input Monitoring pane and quit/relaunch the app.

## Speech-to-text setup (one-time)

Voxflow ships its STT engine on top of [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Install once and point it at a model:

```bash
brew install whisper-cpp
mkdir -p ~/.voxflow/models
curl -L -o ~/.voxflow/models/ggml-base.en.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
# (run `bash scripts/install.sh` to do all of this in one shot)
```

`base.en` (~150 MB) is the default and runs in real-time on Apple Silicon. Swap in `small.en`, `medium.en`, or `large-v3` for higher accuracy by overriding `VOXFLOW_WHISPER_MODEL`.

## Configuration

All preferences are bound to the Settings window and seeded from environment variables read at launch:

| Env var | Default | Purpose |
|---|---|---|
| `VOXFLOW_STT_BACKEND` | `whisper-cpp` | `whisper-cpp` (default, ships with the app) or `voxtral` (Python sidecar — see `Sources/python/README.md`) |
| `VOXFLOW_WHISPER_BIN` | auto-detected | Override path to `whisper-cli`. Defaults to `/opt/homebrew/bin/whisper-cli`. |
| `VOXFLOW_WHISPER_MODEL` | `~/.voxflow/models/ggml-base.en.bin` | Override path to the GGML model file. |
| `VOXFLOW_CLEANUP_MODEL` | `qwen2.5-coder:7b-instruct` | Ollama model id used for cleanup |
| `VOXFLOW_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama base URL |
| `VOXFLOW_PASTE_MODE` | `paste` | `paste` (clipboard + Cmd+V) or `type` (per-character synthetic events) |

Hotkey timing knobs (hold threshold, double-tap window) live in the Settings window only.

## Swap the cleanup model

```bash
brew install ollama
ollama serve &
ollama pull qwen2.5-coder:7b-instruct  # or any other instruct model
```

To use a different model just set `VOXFLOW_CLEANUP_MODEL` before launching the app, or change the field in Settings → Cleanup. Voxflow will surface a "model not found" error if Ollama returns 404 for the chosen model.

## Release build, signed and notarized

```bash
export VOXFLOW_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"
export APPLE_TEAM_ID="ABCDE12345"

scripts/release.sh
# -> dist/Voxflow.dmg (signed, notarized, stapled)
```

Without `VOXFLOW_SIGNING_IDENTITY` the script ad-hoc signs and skips notarization; the resulting DMG runs locally but trips Gatekeeper on a fresh user account. Without the `APPLE_*` notary credentials, the script signs but skips the notarization round-trip.

## Layout

```
Sources/
├── Voxflow/         executable target — AppDelegate, status bar, settings/history/pill windows
└── VoxflowCore/     library target — state, hotkey, audio, stt, cleanup, paste, history, permissions
Tests/
└── VoxflowCoreTests/   35 tests (gate, hotkey, identity cache, history, system prompt, orchestrator, fixtures)
Resources/
├── Info.plist           LSUIElement = true (no dock icon)
└── Voxflow.entitlements
scripts/
├── build-app.sh         wraps swift-build output into a .app bundle
└── release.sh           build → codesign → notarize → staple → DMG
tests/fixtures/
├── cleanup-pairs.json       raw → cleaned + gate-decision expectations
└── identifier-spelling.json letter-by-letter spellings the gate must NEVER skip
```

## Where data is stored

| File | Purpose |
|---|---|
| `~/Library/Application Support/Voxflow/history.jsonl` | One JSON line per dictation: timestamps, tokens, raw + cleaned text, timing breakdown |
| `~/Library/Application Support/Voxflow/identity-cache.json` | Per-pattern identity-pass counters; once a pattern hits the threshold (default 200) the LLM is skipped |
