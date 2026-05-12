# Changelog

All notable iterations from the autonomous loop run on 2026-05-10.

## Unreleased

### Changed
- **STT swapped to FluidAudio's Parakeet TDT v2 (CoreML/ANE).** Single backend, English-only, highest recall on the M3 Pro. New `ParakeetBackend` records via AVAudioEngine with Apple's system voice processing enabled on the input node (AEC + noise/voice suppression), then transcribes a 16 kHz mono Float buffer through `AsrManager.transcribe(_:decoderState:)`. Model is downloaded lazily on the first `startSession()` and pre-warmed in the background at app launch. The backend picker, Whisper.cpp binary, GGML model, Voxtral Python sidecar, `STTBackendKind`/`STTBackendFactory`, and the `BECK_STT_BACKEND`/`BECK_WHISPER_*`/`BECK_VOXTRAL_PYTHON` env vars are all gone — `AppDelegate` instantiates `ParakeetBackend()` directly.

## 2026-05-10

### Added
- **Bootstrap.** Native Swift `Beck` exec + `BeckCore` library, NSStatusItem with `waveform` SF Symbol, `LSUIElement = true` (no dock icon), `scripts/build-app.sh` producing an ad-hoc-signed `.app`.
- **SwiftUI Settings window.** Backend, cleanup model + URL, paste mode, hotkey timing, plus a Permissions section with one-click jumps to Privacy & Security panes.
- **Fn-key hotkey.** `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` (plus a local twin) gated on `AXIsProcessTrusted()` — Accessibility-only, no Input Monitoring prompt. We still check `.maskSecondaryFn` on the underlying `cgEvent` so non-Fn function keys don't trigger the hotkey.
- **Hotkey state machine.** Hold-to-dictate (≥ 250 ms) and double-tap-to-lock semantics on an injectable `BeckClock`. Six deterministic tests.
- **`SkipGate`.** Token-based gate that bypasses the LLM for short, plain prose; tightened to drop ambiguous English keywords and added a single-letter-spelling heuristic.
- **STT.** `STTBackend` async protocol; `AppleSpeechBackend` using `SFSpeechRecognizer` with on-device recognition; `STTBackendFactory` driven from preferences.
- **Audio.** `AudioRecorder` (AVAudioEngine multi-subscriber tap) and `AudioRingBuffer` for debug captures.
- **Cleanup pipeline.** `OllamaClient` (`URLSession.bytes(for:)` line streaming against `/api/chat`); 116-token system prompt with the project.md ≤ 150 startup hard cap; `CleanupPipeline.run` returning `path`, `inputTokens`, `outputTokens`, `elapsedMs`.
- **Identity cache.** JSON-backed counter; the LLM is short-circuited after 200 consecutive identity passes per normalized raw pattern.
- **Heuristic cleanup fallback.** Order-aware regex+token rewriter (open paren, dot, underscore, single-letter spelling, spoken digits, fat arrow, …). Kicks in automatically when Ollama is unreachable.
- **Cleanup mode preference.** `auto` (default), `heuristic` (no LLM ever), `off` (paste raw).
- **Paster.** `ClipboardPaster` (NSPasteboard + Cmd+V via CGEvent) and `TypingPaster` (per-character Unicode events) behind a `Paster` protocol + `PasterFactory`.
- **Orchestrator.** `DictationOrchestrator` actor wiring hotkey → STT → cleanup → paste; emits `DictationTrace` with full timing breakdown.
- **History.** `HistoryLogger` JSON-lines writer in `~/Library/Application Support/Beck/history.jsonl`; SwiftUI `HistoryWindowController` showing the last 50 entries with timing + SKIPPED/CLEANED badges.
- **Status pill.** Floating SwiftUI panel (ultra-thin material, status-bar level, all spaces) with live partial transcript and pulsing recording indicator.
- **Onboarding.** First-launch SwiftUI panel that explains and links to the three required Privacy & Security panes; auto-skipped when everything is already granted.
- **"Test Dictation" menu item.** Runs a fixed sample through the cleanup pipeline + paster so the user can verify F5 without the mic.
- **Permissions probe.** `PermissionsProbe` for Mic / Accessibility, with deep-link openers.
- **App icon.** `scripts/make-icon.sh` renders an SF-Symbol-derived 1024 px PNG and runs `iconutil` to produce `Resources/AppIcon.icns`.
- **Release pipeline.** `scripts/release.sh` builds, codesigns with `BECK_SIGNING_IDENTITY`, notarizes via `notarytool`, staples, produces `dist/Beck.dmg`. Falls back to unsigned DMG cleanly when env is missing.
- **Smoke harness.** `scripts/smoke.sh` builds the .app, boots, asserts 5 s survival, TERMs.
- **Idle benchmark.** `scripts/bench-idle.sh` snapshots CPU% and RSS after 30 s, asserting P4 (≤ 1.5%, ≤ 350 MB).
- **Token-budget benchmark.** Offline test asserting cleanup input p95 ≤ 200 across the cleanup-pair fixture.
- **LLM judge.** `scripts/judge.sh` POSTs every cleanup-pair through Ollama, scores via a judge model, asserts F4 (≥ 80% pass), Q1 (mean ≥ 7.5), Q2 (zero hallucinations). Graceful exit when Ollama is unreachable.
- **End-to-end latency benchmark.** `scripts/bench-latency.sh` skeleton; replays recorded audio fixtures through the production code path.
- **Fixtures.** `cleanup-pairs.json` (31), `identifier-spelling.json` (10), `hallucination-audit.json` (12), and an audio fixture README explaining what to record.
- **Docs.** `README.md` (install, env vars, model swap, release walkthrough); `SHIPPING.md` (per-gate status table + one-shot recipe).

### Tests

57 unit tests, all green: AppState, Hotkey, SkipGate, SystemPrompt, IdentityCache, History, CleanupPipeline (3), HeuristicCleanup (7), CleanupMode (4), DictationOrchestrator (4), TokenBudget, FixtureGate (2), HallucinationFixture, EndToEndIntegration (3), OllamaHealthProbe (3), **STTBackendFactory (3)**.

### Polish

- Standard NSApp main menu (App / Edit / Window) so Cm+C/V/X/A and Cmd+, work in the Settings text fields and the About panel opens via the App menu.
- Settings → Cleanup shows live Ollama reachability + cleanup-model availability, with auto-reprobe whenever URL or model changes.
- History rows have a Copy button.
- Errors auto-fade from the menu bar to "Idle" after 3s instead of pinning.
- Settings → General → "Launch at login" via SMAppService.mainApp; surfaces "approve in System Settings" when macOS asks the user to confirm.
- `scripts/install.sh` walks an operator through everything that needs to be installed (Ollama + cleanup model) before first dictation. Read-only by default; `--yes` actually installs.
- History panel: search field that filters by raw/cleaned/path, "Copy as JSON" exports the filtered set to the clipboard, "Reveal File" opens the JSONL in Finder.
- Status bar: "Copy Diagnostics" (Cmd+D) drops a one-glance support snapshot — version, macOS, preferences, permissions, Ollama health, history file path — onto the clipboard.

### Deferred

- **GRDB / SQLite history.** JSON-lines covers v1; swap when query needs grow.
- **Audio waveform inside the status pill.** The pill currently shows the partial transcript and a pulsing recording dot; adding a level meter is a half-day task off `AudioRingBuffer`.
- **Apple Developer signing + notarization.** Pipeline is in place; needs the operator to set `BECK_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` then `bash scripts/release.sh`.
