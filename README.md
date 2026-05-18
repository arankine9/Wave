# Wave

[![CI](https://github.com/arankine9/Wave/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/arankine9/Wave/actions/workflows/ci.yml)

Native macOS dictation built for coding. Hold the Fn (Globe) key, talk, release, get cleaned-up code-aware text in the focused app. Local STT, local cleanup, no dock icon, just a small menu bar item near the battery.

The full spec lives in `project.md`. The active task list lives in `TODO.md`.

## Features

- **Hold-to-dictate.** Hold the Fn key, talk, release. Cleaned text is pasted into the focused app.
- **Double-tap to lock.** Double-tap Fn to lock dictation on. Single tap to stop.
- **Token-efficient.** Short, plain prose is pasted as-is with no LLM round-trip. Identifier spellings ("u s e r underscore i d") are routed through the cleanup model verbatim. Repeated identity passes are cached so frequent inputs skip the LLM entirely.
- **Menu bar only.** No dock icon, no tray icon, no app-switcher entry — `LSUIElement = true`.
- **Local everything.** On-device transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Parakeet TDT v2 (Apple Neural Engine + CoreML), local Ollama for cleanup. Apple's Speech Recognition framework is never used — no "Wave would like to access Speech Recognition" prompt. No data leaves the machine unless you point cleanup at a remote model.
- **Voice isolation.** Apple's system voice processing (acoustic echo cancellation + noise/voice suppression) runs on the input node *before* audio reaches Parakeet, so a podcast playing nearby or a second voice in the room doesn't bleed into the transcript.

## Build from source

```bash
swift build              # SPM debug build
swift test               # run unit tests (see Testing below)
scripts/build-app.sh     # produce build/Wave.app (ad-hoc signed)
open build/Wave.app      # run; look in the menu bar near the battery
scripts/release.sh       # produce dist/Wave.dmg with drag-to-Applications layout
```

Run Wave from `/Applications/Wave.app` (drag from the DMG) rather than directly from `build/`. macOS guards `~/Desktop`, `~/Downloads`, and `~/Documents` with TCC, and an Accessibility grant for a bundle living inside one of those folders can fail to stick. The DMG's branded background is generated at `Resources/dmg-background.tiff` (a HiDPI multi-resolution TIFF — 600×400 @1×, 1200×800 @2×); replace it with your own via `tiffutil -cathidpicheck bg-1x.png bg-2x.png -out Resources/dmg-background.tiff` to use custom artwork.

## Testing

CI runs `swift test` on every push and pull request to `main` (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — status badge at the top of this README). The suite is 100+ tests covering the runtime pipeline end-to-end with stubs at the I/O boundaries, plus offline fixture-driven probes for the LLM cleanup path. Categorically:

- **Hotkey state machine** (`HotkeyControllerTests`). Hold-to-dictate threshold and double-tap-to-lock semantics on an injectable `WaveClock` — no real timers, no real keys, fully deterministic.
- **Orchestrator end-to-end** (`DictationOrchestratorTests`, `EndToEndIntegrationTests`). Drive the production `DictationOrchestrator` from a synthetic Fn-press through cleanup to paste, using `StubBackend` + `StubCleanupClient` + `SpyPaster`. Pins the same code path `AppDelegate` constructs in production.
- **Deterministic cleanup** (`CleanupPipelineTests`, `HeuristicCleanupTests`, `SpacingAndCasingTests`, `DisfluencyFilterTests`, `CleanupModeTests`). Filler removal, stutter dedup, spacing and capitalization, identifier preservation. Pure functions, microsecond-fast.
- **Gate decisions** (`SkipGateTests`, `FixtureGateTests`). The "skip LLM for plain prose, never skip identifier spellings" gate is pinned against the `cleanup-pairs.json` and `identifier-spelling.json` fixture corpora.
- **Hallucination audit** (`HallucinationFixtureTests`). Structural validation of the `hallucination-audit.json` corpus — the actual "did the LLM invent tokens" check runs via `scripts/judge.sh` against Ollama, but the corpus shape is gated in CI so the judge run can't silently no-op.
- **History golden file** (`HistoryGoldenTests`). Replays the user's real dictation history (when present) through `DeterministicCleanup` and writes a before/after report; no-ops in CI where no history exists.
- **Token budget benchmark** (`TokenBudgetBenchmarkTests`). Walks every cleanup-pair fixture and asserts input-token p95 ≤ 200 — the project's P3 token budget gate, enforced in CI.
- **Latency budget benchmark** (`LatencyBudgetBenchmarkTests`). XCTest `measure` block over the stub orchestrator hold→paste cycle. The fixed-budget assertion catches order-of-magnitude regressions and `XCTClockMetric` records baselines Xcode can diff against in detail.
- **Identity cache** (`IdentityCacheTests`). Frequent-input bypass counters; verifies the LLM gets skipped once a pattern crosses threshold.
- **History logging** (`HistoryLoggerTests`). JSONL round-trips and schema invariants.
- **System prompt** (`SystemPromptTests`). Pins the cleanup prompt exactly — drift here is a behavior regression nobody else would catch.
- **Microphone selection** (`MicrophoneChoiceTests`). Default-device fallback and explicit-device routing logic.
- **Ollama probe** (`OllamaHealthProbeTests`). Reachability + model-presence error mapping (so a missing model surfaces as a clear UI error, not a stack trace).
- **AppState transitions** (`AppStateTests`). Status enum and observer fan-out.
- **Paste** (`ClipboardPasterTests`). Clipboard restore semantics so dictation never strands the user's prior clipboard content.

The full transcribe path through Parakeet TDT v2 runs as an opt-in integration test gated by `WAVE_RUN_PARAKEET_TEST=1` (`ParakeetBackendTests`) — it downloads several hundred MB of CoreML models on first run, so it's off by default. End-to-end latency probing against a live Ollama is wrapped in `scripts/bench-latency.sh` (requires recorded audio fixtures, see `Tests/fixtures/audio/README.md`); the LLM hallucination judge is `scripts/judge.sh`.

## First-run permissions

macOS will prompt for these the first time the app needs them. You can also see live status in **Wave → Open Settings → Permissions**, with one-click jumps into the right Privacy & Security pane.

| Permission | Why | Where to grant |
|---|---|---|
| Microphone | Capture audio while the hotkey is held | System Settings → Privacy & Security → Microphone |
| Accessibility | Detect the global Fn-key hotkey (via CGEventTap at the HID level) and synthesize Cmd+V (or per-character keystrokes) into the focused app | System Settings → Privacy & Security → Accessibility |

If the menu bar icon shows "Status: Grant Accessibility in Privacy & Security", the Fn monitor couldn't register — flip the toggle in the Accessibility pane and quit/relaunch the app. (No Input Monitoring grant is required: modifier-flag changes ride on the Accessibility pipeline, so macOS never prompts "would like to receive keystrokes from any application".)

Wave also silently claims the Fn (Globe) key on every launch so the macOS emoji picker, Start Dictation overlay, and Change Input Source actions never fire while the app is running. This is done by writing `AppleFnUsageType=0` to `com.apple.HIToolbox` and posting the `com.apple.KeyboardUIModeDidChange` distributed notification — the same signal System Settings posts when you flip "Press 🌐 key to". No logout or System Settings detour is needed. The full debugging writeup — symptom, what was tried, what failed, and why this specific notification was load-bearing — is in [docs/fn-key-debugging.md](docs/fn-key-debugging.md). The implementation lives in `Sources/WaveCore/Hotkey/FnSystemPreference.swift`.

## Speech-to-text setup

Zero setup — Wave downloads the Parakeet TDT v2 model on first dictation and caches it under `~/Library/Application Support/FluidAudio/`. The first hold-to-talk pays the download cost (a few hundred MB once); subsequent dictations are warm.

## Configuration

All preferences are bound to the Settings window and seeded from environment variables read at launch:

| Env var | Default | Purpose |
|---|---|---|
| `WAVE_CLEANUP_MODEL` | `qwen2.5-coder:7b-instruct` | Ollama model id used for cleanup |
| `WAVE_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama base URL |
| `WAVE_PASTE_MODE` | `paste` | `paste` (clipboard + Cmd+V) or `type` (per-character synthetic events) |

Hotkey timing knobs (hold threshold, double-tap window) live in the Settings window only.

## Swap the cleanup model

```bash
brew install ollama
ollama serve &
ollama pull qwen2.5-coder:7b-instruct  # or any other instruct model
```

To use a different model just set `WAVE_CLEANUP_MODEL` before launching the app, or change the field in Settings → Cleanup. Wave will surface a "model not found" error if Ollama returns 404 for the chosen model.

## Release build, signed and notarized

```bash
export WAVE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"
export APPLE_TEAM_ID="ABCDE12345"

scripts/release.sh
# -> dist/Wave.dmg (signed, notarized, stapled)
```

Without `WAVE_SIGNING_IDENTITY` the script ad-hoc signs and skips notarization; the resulting DMG runs locally but trips Gatekeeper on a fresh user account. Without the `APPLE_*` notary credentials, the script signs but skips the notarization round-trip.

## Layout

```
Sources/
├── Wave/         executable target — AppDelegate, status bar, settings/history/pill windows
└── WaveCore/     library target — state, hotkey, audio, stt, cleanup, paste, history, permissions
Tests/
└── WaveCoreTests/   100+ tests — see [Testing](#testing) for the category breakdown
Resources/
├── Info.plist           LSUIElement = true (no dock icon)
└── Wave.entitlements
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
| `~/Library/Application Support/Wave/history.jsonl` | One JSON line per dictation: timestamps, tokens, raw + cleaned text, timing breakdown |
| `~/Library/Application Support/Wave/identity-cache.json` | Per-pattern identity-pass counters; once a pattern hits the threshold (default 200) the LLM is skipped |
