# Beck

Native macOS dictation built for coding. Hold the Fn (Globe) key, talk, release, get cleaned-up code-aware text in the focused app. Local STT, local cleanup, no dock icon, just a small menu bar item near the battery.

The full spec lives in `project.md`. The active task list lives in `TODO.md`.

## Features

- **Hold-to-dictate.** Hold the Fn key, talk, release. Cleaned text is pasted into the focused app.
- **Double-tap to lock.** Double-tap Fn to lock dictation on. Single tap to stop.
- **Token-efficient.** Short, plain prose is pasted as-is with no LLM round-trip. Identifier spellings ("u s e r underscore i d") are routed through the cleanup model verbatim. Repeated identity passes are cached so frequent inputs skip the LLM entirely.
- **Menu bar only.** No dock icon, no tray icon, no app-switcher entry — `LSUIElement = true`.
- **Local everything.** On-device transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Parakeet TDT v2 (Apple Neural Engine + CoreML), local Ollama for cleanup. Apple's Speech Recognition framework is never used — no "Beck would like to access Speech Recognition" prompt. No data leaves the machine unless you point cleanup at a remote model.
- **Voice isolation.** Apple's system voice processing (acoustic echo cancellation + noise/voice suppression) runs on the input node *before* audio reaches Parakeet, so a podcast playing nearby or a second voice in the room doesn't bleed into the transcript.

## Build from source

```bash
swift build              # SPM debug build
swift test               # run unit tests (35 currently)
scripts/build-app.sh     # produce build/Beck.app (ad-hoc signed)
open build/Beck.app      # run; look in the menu bar near the battery
scripts/release.sh       # produce dist/Beck.dmg with drag-to-Applications layout
```

Run Beck from `/Applications/Beck.app` (drag from the DMG) rather than directly from `build/`. macOS guards `~/Desktop`, `~/Downloads`, and `~/Documents` with TCC, and an Accessibility grant for a bundle living inside one of those folders can fail to stick. The DMG's branded background is generated at `Resources/dmg-background.tiff` (a HiDPI multi-resolution TIFF — 600×400 @1×, 1200×800 @2×); replace it with your own via `tiffutil -cathidpicheck bg-1x.png bg-2x.png -out Resources/dmg-background.tiff` to use custom artwork.

## First-run permissions

macOS will prompt for these the first time the app needs them. You can also see live status in **Beck → Open Settings → Permissions**, with one-click jumps into the right Privacy & Security pane.

| Permission | Why | Where to grant |
|---|---|---|
| Microphone | Capture audio while the hotkey is held | System Settings → Privacy & Security → Microphone |
| Accessibility | Detect the global Fn-key hotkey (via NSEvent flagsChanged monitor) and synthesize Cmd+V (or per-character keystrokes) into the focused app | System Settings → Privacy & Security → Accessibility |

If the menu bar icon shows "Status: Grant Accessibility in Privacy & Security", the Fn monitor couldn't register — flip the toggle in the Accessibility pane and quit/relaunch the app. (No Input Monitoring grant is required: modifier-flag changes ride on the Accessibility pipeline, so macOS never prompts "would like to receive keystrokes from any application".)

## Speech-to-text setup

Zero setup — Beck downloads the Parakeet TDT v2 model on first dictation and caches it under `~/Library/Application Support/FluidAudio/`. The first hold-to-talk pays the download cost (a few hundred MB once); subsequent dictations are warm.

## Configuration

All preferences are bound to the Settings window and seeded from environment variables read at launch:

| Env var | Default | Purpose |
|---|---|---|
| `BECK_CLEANUP_MODEL` | `qwen2.5-coder:7b-instruct` | Ollama model id used for cleanup |
| `BECK_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama base URL |
| `BECK_PASTE_MODE` | `paste` | `paste` (clipboard + Cmd+V) or `type` (per-character synthetic events) |

Hotkey timing knobs (hold threshold, double-tap window) live in the Settings window only.

## Swap the cleanup model

```bash
brew install ollama
ollama serve &
ollama pull qwen2.5-coder:7b-instruct  # or any other instruct model
```

To use a different model just set `BECK_CLEANUP_MODEL` before launching the app, or change the field in Settings → Cleanup. Beck will surface a "model not found" error if Ollama returns 404 for the chosen model.

## Release build, signed and notarized

```bash
export BECK_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"
export APPLE_TEAM_ID="ABCDE12345"

scripts/release.sh
# -> dist/Beck.dmg (signed, notarized, stapled)
```

Without `BECK_SIGNING_IDENTITY` the script ad-hoc signs and skips notarization; the resulting DMG runs locally but trips Gatekeeper on a fresh user account. Without the `APPLE_*` notary credentials, the script signs but skips the notarization round-trip.

## Layout

```
Sources/
├── Beck/         executable target — AppDelegate, status bar, settings/history/pill windows
└── BeckCore/     library target — state, hotkey, audio, stt, cleanup, paste, history, permissions
Tests/
└── BeckCoreTests/   35 tests (gate, hotkey, identity cache, history, system prompt, orchestrator, fixtures)
Resources/
├── Info.plist           LSUIElement = true (no dock icon)
└── Beck.entitlements
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
| `~/Library/Application Support/Beck/history.jsonl` | One JSON line per dictation: timestamps, tokens, raw + cleaned text, timing breakdown |
| `~/Library/Application Support/Beck/identity-cache.json` | Per-pattern identity-pass counters; once a pattern hits the threshold (default 200) the LLM is skipped |
