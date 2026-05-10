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
(H1, H2, H3, H4 done — see Done)

### 3. Audio capture
(A1, A2 done — see Done)
- [ ] **A3** Persist last 30s of audio to a ring buffer for debug capture (gated by a flag).

### 4. STT backend
(S1, S2 done — see Done)
- [ ] **S3** Backend selection via env var `VOXFLOW_STT_BACKEND` (`apple` default, `voxtral` future). PreferencesStore already reads it; expose a `STTBackendFactory` that returns the correct backend.
- [ ] **S4** Latency probe test: feed 5 short clips, assert non-empty transcripts and `< 800ms` finalize. (Requires real audio fixtures; can be marked skip-on-CI.)

### 5. Cleanup pipeline (token-efficient)
(C1, C2, C3, C4, C5 done — see Done)
- [ ] **C6** Fixture corpus: `tests/fixtures/cleanup-pairs.json` with 30+ raw→cleaned pairs.
- [ ] **C7** Identifier-spelling fixtures: 100% preservation when user spells out letter-by-letter.
- [ ] **C2** `OllamaClient` HTTP streaming client. Default model `qwen2.5-coder:7b-instruct`. Configurable.
- [ ] **C3** `SystemPrompt`: ≤ 150 tokens hard cap; startup assertion fails launch if exceeded. Token counter (cl100k or rough heuristic).
- [ ] **C4** `IdentityCache`: SQLite-backed (or simple JSON for v1) cache; if raw == cleaned for last N=200 instances of a pattern, skip the LLM.
- [ ] **C5** `CleanupPipeline.run(rawTranscript)` ties gate + cache + Ollama. Streaming output. No prior turns.
- [ ] **C6** Fixture corpus: `tests/fixtures/cleanup-pairs.json` with 30+ raw→cleaned pairs.
- [ ] **C7** Identifier-spelling fixtures: 100% preservation when user spells out letter-by-letter.

### 6. Paste
(P1 done — see Done)
- [ ] **P2** Permission probe: Accessibility required for `CGEvent.post`. Surface in settings.
- [ ] **P3** Test in a sandbox `NSTextField` window. (Manual; fold into smoke test.)

### 7. Orchestrator
(O1, O2, O3 done — see Done)

### 8. Persistence & history
(D1, D2 done — see Done.)

### 9. Performance gates
- [ ] **G1** End-to-end p50 ≤ 800ms, p95 ≤ 1800ms over 50 dictations on M1/16GB.
- [ ] **G2** Cleanup input p95 ≤ 200 tokens, output p95 ≤ 400.
- [ ] **G3** Idle CPU ≤ 1.5%, idle RAM ≤ 350MB excluding model weights.

### 10. Packaging & signing
(K1, K2, K3, K4 done — see Done; needs an actual Developer ID identity + notary creds for a fully-stapled run.)
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
- **C1** `SkipGate.shouldSkipCleanup` token-based gate + 7 tests (plain prose, empty, code keywords, case-insensitive, non-allowed chars, long input, substring guard) (2026-05-10)
- **S1** `STTBackend` / `STTSession` async protocol with `STTPartial` and typed `STTError` (2026-05-10)
- **S2** `AppleSpeechBackend` using `SFSpeechRecognizer` with on-device recognition when supported (2026-05-10)
- **A1** `AudioRecorder` using `AVAudioEngine` tap with multi-subscriber buffer dispatch (2026-05-10)
- **C2** `OllamaClient` streams `/api/chat` over `URLSession.bytes(for:)` line-by-line; surfaces 404 as `modelMissing` (2026-05-10)
- **C3** `SystemPrompt.text` (116 estimated tokens) plus `assertWithinBudget()` startup hard cap at 150 (2026-05-10)
- **C5** `CleanupPipeline.run` ties gate + client; returns `CleanupResult` with `path`, `inputTokens`, `outputTokens`, `elapsedMs` (2026-05-10)
- **P1** `ClipboardPaster` (NSPasteboard + Cmd+V via CGEvent) and `TypingPaster` (per-character Unicode key events) behind a `Paster` protocol + `PasterFactory` (2026-05-10)
- **O1** `DictationOrchestrator` actor: idle → recording → transcribing → cleaning → pasting → idle, with `DictationTrace` timing capture and a pluggable `DictationLogger` (2026-05-10)
- **O2** AppDelegate wires `FnKeyMonitor` → `HotkeyController` → `DictationOrchestrator` with `AppleSpeechBackend` + `OllamaClient` + `PasterFactory` from `PreferencesStore`. Asserts system-prompt budget at launch. (2026-05-10)
- **C4** `IdentityCache` JSON-backed counter; pipeline now short-circuits the LLM after `threshold` (default 200) consecutive identity passes per normalized raw pattern (2026-05-10)
- **D1** `HistoryLogger` JSON-lines writer in `~/Library/Application Support/Voxflow/history.jsonl`, plumbed into the orchestrator (2026-05-10)
- **K1/K2** `scripts/build-app.sh` produces an .app bundle, ad-hoc-signed by default and Developer-ID-signed with entitlements when `VOXFLOW_SIGNING_IDENTITY` is set (2026-05-10)
- **K3/K4** `scripts/release.sh` builds, codesigns, notarizes via `notarytool` (when creds are set), staples, and produces a `dist/Voxflow.dmg`; falls back to unsigned DMG cleanly when env is missing (2026-05-10, dry-run produced 200KB DMG)
- **O3** Floating `StatusPillController` (NSPanel + SwiftUI, ultraThinMaterial, status-bar level) shows live partial transcript + animated recording indicator; hides on idle, lingers 1.5s on errors (2026-05-10)
- **D2** `HistoryWindowController` SwiftUI list backed by `HistoryLogger.recent(limit:)` with per-entry timing breakdown and SKIPPED/CLEANED badge (2026-05-10)
- **H3/A2** `PermissionsProbe` (`AVCaptureDevice` + `CGPreflightListenEventAccess` + `AXIsProcessTrusted`) plus a Permissions section in Settings with an "Open System Settings" deep-link button per pane (2026-05-10)

---

## Blocked

(empty at start)
