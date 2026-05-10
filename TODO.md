# Voxflow (native) — TODO

Authoritative spec: `project.md`. Each loop iteration picks the top item under `## Todo`, completes it, moves it to `## Done`, commits, and exits.

When stuck after 3 attempts, move the task to `## Blocked` and append a `STUCK.md` entry.

---

## Todo

### 0. Bootstrap
(complete — see Done)

### 1. Menu bar UI
(M1, M2, M3 done — see Done)

### 2. Fn-key hotkey
(H1, H2, H4 done — see Done)
- [ ] **H3** Permission probe surface: detect missing Input Monitoring and surface an in-app prompt with a "Open System Settings" deep link, instead of just a console error.

### 3. Audio capture
- [ ] **A1** `AudioRecorder` using `AVAudioEngine` tap on the input node. Streams 16kHz mono Float32 chunks. Start/stop methods.
- [ ] **A2** Mic permission probe with the same surfacing pattern as Input Monitoring.
- [ ] **A3** Persist last 30s of audio to a ring buffer for debug capture (gated by a flag).

### 4. STT backend
- [ ] **S1** `STTBackend` protocol: `start()`, `feedAudio(buffer)`, `finalize() async -> String`, `dispose()`. Events: `partial`, `final`, `error`.
- [ ] **S2** `AppleSpeechBackend` using `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Default backend.
- [ ] **S3** Backend selection via env var `VOXFLOW_STT_BACKEND` (`apple` default, `voxtral` future).
- [ ] **S4** Latency probe test: feed 5 short clips, assert non-empty transcripts and `< 800ms` finalize.

### 5. Cleanup pipeline (token-efficient)
- [ ] **C1** `SkipGate.shouldSkipCleanup(_:)`: short, no spoken-code keywords → skip. Tests cover positive/negative cases.
- [ ] **C2** `OllamaClient` HTTP streaming client. Default model `qwen2.5-coder:7b-instruct`. Configurable.
- [ ] **C3** `SystemPrompt`: ≤ 150 tokens hard cap; startup assertion fails launch if exceeded. Token counter (cl100k or rough heuristic).
- [ ] **C4** `IdentityCache`: SQLite-backed (or simple JSON for v1) cache; if raw == cleaned for last N=200 instances of a pattern, skip the LLM.
- [ ] **C5** `CleanupPipeline.run(rawTranscript)` ties gate + cache + Ollama. Streaming output. No prior turns.
- [ ] **C6** Fixture corpus: `tests/fixtures/cleanup-pairs.json` with 30+ raw→cleaned pairs.
- [ ] **C7** Identifier-spelling fixtures: 100% preservation when user spells out letter-by-letter.

### 6. Paste
- [ ] **P1** `Paster` writes to `NSPasteboard` and synthesizes Cmd+V via `CGEvent`. Configurable mode: `paste` (default) or `type` (per-character `CGEvent` keystrokes).
- [ ] **P2** Permission probe: Accessibility required for `CGEvent.post`. Surface in settings.
- [ ] **P3** Test in a sandbox `NSTextField` window.

### 7. Orchestrator
- [ ] **O1** State machine: idle → recording → transcribing → cleaning → pasting → idle. Cancellable mid-flight.
- [ ] **O2** Wire hotkey → orchestrator → audio → stt → cleanup → paste.
- [ ] **O3** Status pill window (small floating SwiftUI panel) shows live waveform + raw transcript while recording.

### 8. Persistence & history
- [ ] **D1** SQLite (`GRDB.swift`) schema for `dictations` (raw, cleaned, audio_ms, stt_ms, cleanup_ms, paste_ms, ts) and `settings`.
- [ ] **D2** History panel SwiftUI view, last 50 entries.

### 9. Performance gates
- [ ] **G1** End-to-end p50 ≤ 800ms, p95 ≤ 1800ms over 50 dictations on M1/16GB.
- [ ] **G2** Cleanup input p95 ≤ 200 tokens, output p95 ≤ 400.
- [ ] **G3** Idle CPU ≤ 1.5%, idle RAM ≤ 350MB excluding model weights.

### 10. Packaging & signing
- [ ] **K1** `scripts/build-app.sh` creates a proper `Voxflow.app` bundle from the SPM build output.
- [ ] **K2** Codesign with Developer ID Application identity (env `VOXFLOW_SIGNING_IDENTITY`).
- [ ] **K3** Notarize via `notarytool` (env `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`).
- [ ] **K4** Stapled, signed `.dmg` produced by `scripts/release.sh`.
- [ ] **K5** README documents install, first-run permissions (Mic, Accessibility, Input Monitoring), and how to swap cleanup model / STT backend.

---

## Done

- **B1** `swift build` green with menu bar skeleton (2026-05-10)
- **B2** `swift test` green, 4 AppState tests pass (2026-05-10)
- **B3** `scripts/build-app.sh` produces ad-hoc-signed `build/Voxflow.app` bundle with `LSUIElement` set (2026-05-10)
- **M1** `NSStatusItem` displays the `waveform` SF Symbol as a template image (2026-05-10, in initial bootstrap)
- **M2** Menu items "Status: …", "Open Settings…", "Quit" wired to AppState callback (2026-05-10, in initial bootstrap)
- **M3** SwiftUI Settings window with backend, cleanup-model, paste-mode, and hotkey-timing controls bound to `PreferencesStore` (2026-05-10)
- **H1** `FnKeyMonitor` CGEventTap on `flagsChanged` for `.maskSecondaryFn`, with `CGPreflightListenEventAccess` permission probe (2026-05-10)
- **H2** `HotkeyController` state machine: hold-to-dictate (≥250ms) and double-tap-to-lock semantics, on injectable `VoxflowClock` (2026-05-10)
- **H4** 6 deterministic `HotkeyControllerTests` covering hold, single tap, double-tap, second-press-held, out-of-window second tap, spurious release (2026-05-10)

---

## Blocked

(empty at start)
