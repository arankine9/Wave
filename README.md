# Wave

[![CI](https://github.com/arankine9/Wave/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/arankine9/Wave/actions/workflows/ci.yml)

Native macOS dictation built for coding. Hold the Fn (Globe) key, talk, release, get cleaned-up code-aware text in the focused app. Local STT, on-device deterministic cleanup, no dock icon, just a small menu bar item near the battery.

The full spec lives in `project.md`. The active task list lives in `TODO.md`.

Like Wispr Flow but you keep your data all on device

## Features

- **Hold-to-dictate.** Hold the Fn key, talk, release. Cleaned text is pasted into the focused app.
- **Double-tap to lock.** Double-tap Fn to lock dictation on. Single tap to stop.
- **Code-aware cleanup.** A pure-Swift pass drops disfluencies ("um", "uh", filler "like"), turns spoken symbols ("open paren", "dot", "underscore") into real punctuation for code, reassembles letter-by-letter identifier spellings ("u s e r underscore i d" → `user_id`), and applies sentence spacing and capitalization to prose. Runs inline in well under a millisecond — no network round-trip, no model to install.
- **Menu bar only.** No dock icon, no tray icon, no app-switcher entry — `LSUIElement = true`.
- **Local everything.** On-device transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Parakeet TDT v2 (Apple Neural Engine + CoreML); cleanup is deterministic pure-Swift text processing. Apple's Speech Recognition framework is never used — no "Wave would like to access Speech Recognition" prompt. No data ever leaves the machine.
- **Voice isolation.** Apple's system voice processing (acoustic echo cancellation + noise/voice suppression) runs on the input node *before* audio reaches Parakeet, so a podcast playing nearby or a second voice in the room doesn't bleed into the transcript.

## Build from source

```bash
swift build              # SPM debug build
swift test               # run unit tests (see Testing below)
scripts/build-app.sh     # produce build/Wave.app (ad-hoc signed)
open build/Wave.app      # run; look in the menu bar near the battery
scripts/release.sh       # produce dist/Wave.dmg with drag-to-Applications layout
```

Run Wave from `/Applications/Wave.app` (drag from the DMG) rather than directly from `build/`. macOS guards `~/Desktop`, `~/Downloads`, and `~/Documents` with TCC, and an Accessibility grant for a bundle living inside one of those folders can fail to stick. The DMG opens to a branded "drag Wave to Applications" window — [`scripts/release.sh`](scripts/release.sh) builds the layout with [`dmgbuild`](https://dmgbuild.readthedocs.io) (which writes the window's `.DS_Store` directly, so it works the same on a headless CI runner as it does locally). The backdrop lives at `Resources/dmg-background.png`; edit and re-render it with `bash scripts/make-dmg-background.sh`, then commit the PNG.

## Testing

CI runs `swift test` on every push and pull request to `main` (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — status badge at the top of this README). The suite covers the runtime pipeline end-to-end with stubs at the I/O boundaries. Categorically:

- **Hotkey state machine** (`HotkeyControllerTests`). Hold-to-dictate threshold and double-tap-to-lock semantics on an injectable `WaveClock`. no real timers, no real keys, deterministic.
- **Orchestrator end-to-end** (`DictationOrchestratorTests`, `EndToEndIntegrationTests`). Drive the production `DictationOrchestrator` from a synthetic Fn-press through cleanup to paste, using `StubBackend` + `SpyPaster`. Pins the same code path `AppDelegate` constructs in production.
- **Deterministic cleanup** (`HeuristicCleanupTests`, `SpacingAndCasingTests`, `DisfluencyFilterTests`). Filler removal, stutter dedup, spoken-symbol substitution, spacing and capitalization, identifier preservation. Pure functions, microsecond-fast.
- **History golden file** (`HistoryGoldenTests`). Replays the user's real dictation history (when present) through `DeterministicCleanup` and writes a before/after report; no-ops in CI where no history exists.
- **Latency budget benchmark** (`LatencyBudgetBenchmarkTests`). XCTest `measure` block over the stub orchestrator hold->paste cycle. The fixed-budget assertion catches order-of-magnitude regressions and `XCTClockMetric` records baselines Xcode can diff against in detail.
- **History logging** (`HistoryLoggerTests`). JSONL round-trips and schema invariants.
- **Microphone selection** (`MicrophoneChoiceTests`). Default-device fallback and explicit-device routing logic.
- **AppState transitions** (`AppStateTests`). Status enum and observer fan-out.
- **Paste** (`ClipboardPasterTests`). Clipboard restore semantics so dictation never strands the user's prior clipboard content.

The full transcribe path through Parakeet TDT v2 runs as an opt-in integration test gated by `WAVE_RUN_PARAKEET_TEST=1` (`ParakeetBackendTests`) — it downloads several hundred MB of CoreML models on first run, so it's off by default. End-to-end latency probing is wrapped in `scripts/bench-latency.sh` (requires recorded audio fixtures, see `Tests/fixtures/audio/README.md`).

## First-run permissions

macOS will prompt for these the first time the app needs them. You can also see live status in **Wave -> Open Settings -> Permissions**, with one-click jumps into the right Privacy & Security pane.

| Permission | Why | Where to grant |
|---|---|---|
| Microphone | Capture audio while the hotkey is held | System Settings -> Privacy & Security -> Microphone |
| Accessibility | Detect the global Fn-key hotkey (via CGEventTap at the HID level) and synthesize Cmd+V (or per-character keystrokes) into the focused app | System Settings -> Privacy & Security -> Accessibility |


## Layout

```
Sources/
├── Wave/         executable target: AppDelegate, status bar, settings/history/pill windows
└── WaveCore/     library target: state, hotkey, audio, stt, cleanup, paste, history, permissions
Tests/
└── WaveCoreTests/   unit + integration suite: see [Testing](#testing) for the category breakdown
Resources/
├── Info.plist           LSUIElement = true (no dock icon)
└── Wave.entitlements
scripts/
├── build-app.sh         wraps swift-build output into a .app bundle
└── release.sh           build -> codesign -> notarize -> staple -> DMG
Tests/fixtures/
└── audio/               recorded-audio prompts for the latency bench (gitignored)
```
