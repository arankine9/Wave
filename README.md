# Voxflow

Native macOS dictation built for coding. Hold the Fn key, talk, release, get cleaned-up code-aware text in the focused app. Local STT, local cleanup, no dock icon, just a small menu bar item.

The full spec lives in `project.md`. The active task list lives in `TODO.md`.

## Status

Pre-alpha. Built incrementally by an autonomous Claude Code loop (`/loop` every minute).

## Build

```bash
swift build              # SPM debug build
swift test               # run unit tests
scripts/build-app.sh     # produce build/Voxflow.app
open build/Voxflow.app   # run; look in the menu bar near the battery
```

First run will need:
- Microphone access (granted on first audio capture)
- Input Monitoring (granted in System Settings → Privacy & Security → Input Monitoring) for the global Fn-key hotkey
- Accessibility (granted in System Settings → Privacy & Security → Accessibility) for synthetic paste

## Layout

```
Sources/
├── Voxflow/         executable target — AppDelegate, status bar
└── VoxflowCore/     library target — state, hotkey, audio, stt, cleanup, paste
Tests/
└── VoxflowCoreTests/
Resources/
├── Info.plist       LSUIElement = true (no dock icon)
└── Voxflow.entitlements
scripts/
└── build-app.sh     wraps swift-build output into a .app bundle
```

## Configuration

Environment variables read at launch:
- `VOXFLOW_STT_BACKEND` — `apple` (default) or `voxtral` (future)
- `VOXFLOW_CLEANUP_MODEL` — Ollama model id, default `qwen2.5-coder:7b-instruct`
- `VOXFLOW_OLLAMA_URL` — default `http://127.0.0.1:11434`
- `VOXFLOW_PASTE_MODE` — `paste` (default, clipboard + Cmd+V) or `type` (synthetic per-character)
