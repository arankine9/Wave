# Changelog

All notable iterations from the autonomous loop run on 2026-05-10.

## 2026-05-10

### Added
- **Bootstrap.** Native Swift `Voxflow` exec + `VoxflowCore` library, NSStatusItem with `waveform` SF Symbol, `LSUIElement = true` (no dock icon), `scripts/build-app.sh` producing an ad-hoc-signed `.app`.
- **SwiftUI Settings window.** Backend, cleanup model + URL, paste mode, hotkey timing, plus a Permissions section with one-click jumps to Privacy & Security panes.
- **Fn-key hotkey.** `CGEventTap` on `flagsChanged` for `.maskSecondaryFn`, with `CGPreflightListenEventAccess` permission probe.
- **Hotkey state machine.** Hold-to-dictate (≥ 250 ms) and double-tap-to-lock semantics on an injectable `VoxflowClock`. Six deterministic tests.
- **`SkipGate`.** Token-based gate that bypasses the LLM for short, plain prose; tightened to drop ambiguous English keywords and added a single-letter-spelling heuristic.
- **STT.** `STTBackend` async protocol; `AppleSpeechBackend` using `SFSpeechRecognizer` with on-device recognition; `STTBackendFactory` driven from preferences.
- **Audio.** `AudioRecorder` (AVAudioEngine multi-subscriber tap) and `AudioRingBuffer` for debug captures.
- **Cleanup pipeline.** `OllamaClient` (`URLSession.bytes(for:)` line streaming against `/api/chat`); 116-token system prompt with the project.md ≤ 150 startup hard cap; `CleanupPipeline.run` returning `path`, `inputTokens`, `outputTokens`, `elapsedMs`.
- **Identity cache.** JSON-backed counter; the LLM is short-circuited after 200 consecutive identity passes per normalized raw pattern.
- **Heuristic cleanup fallback.** Order-aware regex+token rewriter (open paren, dot, underscore, single-letter spelling, spoken digits, fat arrow, …). Kicks in automatically when Ollama is unreachable.
- **Cleanup mode preference.** `auto` (default), `heuristic` (no LLM ever), `off` (paste raw).
- **Paster.** `ClipboardPaster` (NSPasteboard + Cmd+V via CGEvent) and `TypingPaster` (per-character Unicode events) behind a `Paster` protocol + `PasterFactory`.
- **Orchestrator.** `DictationOrchestrator` actor wiring hotkey → STT → cleanup → paste; emits `DictationTrace` with full timing breakdown.
- **History.** `HistoryLogger` JSON-lines writer in `~/Library/Application Support/Voxflow/history.jsonl`; SwiftUI `HistoryWindowController` showing the last 50 entries with timing + SKIPPED/CLEANED badges.
- **Status pill.** Floating SwiftUI panel (ultra-thin material, status-bar level, all spaces) with live partial transcript and pulsing recording indicator.
- **Onboarding.** First-launch SwiftUI panel that explains and links to the three required Privacy & Security panes; auto-skipped when everything is already granted.
- **"Test Dictation" menu item.** Runs a fixed sample through the cleanup pipeline + paster so the user can verify F5 without the mic.
- **Permissions probe.** `PermissionsProbe` for Mic / Input Monitoring / Accessibility, with deep-link openers.
- **App icon.** `scripts/make-icon.sh` renders an SF-Symbol-derived 1024 px PNG and runs `iconutil` to produce `Resources/AppIcon.icns`.
- **Release pipeline.** `scripts/release.sh` builds, codesigns with `VOXFLOW_SIGNING_IDENTITY`, notarizes via `notarytool`, staples, produces `dist/Voxflow.dmg`. Falls back to unsigned DMG cleanly when env is missing.
- **Smoke harness.** `scripts/smoke.sh` builds the .app, boots, asserts 5 s survival, TERMs.
- **Idle benchmark.** `scripts/bench-idle.sh` snapshots CPU% and RSS after 30 s, asserting P4 (≤ 1.5%, ≤ 350 MB).
- **Token-budget benchmark.** Offline test asserting cleanup input p95 ≤ 200 across the cleanup-pair fixture.
- **LLM judge.** `scripts/judge.sh` POSTs every cleanup-pair through Ollama, scores via a judge model, asserts F4 (≥ 80% pass), Q1 (mean ≥ 7.5), Q2 (zero hallucinations). Graceful exit when Ollama is unreachable.
- **End-to-end latency benchmark.** `scripts/bench-latency.sh` skeleton; replays recorded audio fixtures through the production code path.
- **Fixtures.** `cleanup-pairs.json` (31), `identifier-spelling.json` (10), `hallucination-audit.json` (12), and an audio fixture README explaining what to record.
- **Docs.** `README.md` (install, env vars, model swap, release walkthrough); `SHIPPING.md` (per-gate status table + one-shot recipe).

### Tests

51 unit tests, all green: AppState, Hotkey, SkipGate, SystemPrompt, IdentityCache, History, CleanupPipeline (3), HeuristicCleanup (7), CleanupMode (4), DictationOrchestrator (4), TokenBudget, FixtureGate (2), HallucinationFixture, **EndToEndIntegration (3)**.

### Polish

- Standard NSApp main menu (App / Edit / Window) so Cm+C/V/X/A and Cmd+, work in the Settings text fields and the About panel opens via the App menu.

### Deferred

- **Voxtral-Mini realtime backend.** Apple Speech covers v1; `STTBackendFactory` keeps a `voxtral` enum case that falls back to Apple. Wiring a Python-sidecar Voxtral runner is documented in TODO.
- **GRDB / SQLite history.** JSON-lines covers v1; swap when query needs grow.
- **Audio waveform inside the status pill.** The pill currently shows the partial transcript and a pulsing recording dot; adding a level meter is a half-day task off `AudioRingBuffer`.
- **Apple Developer signing + notarization.** Pipeline is in place; needs the operator to set `VOXFLOW_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` then `bash scripts/release.sh`.
