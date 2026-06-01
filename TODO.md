# Wave (native) — TODO

**Status: spec complete (2026-05-10).** Every requirement in `project.md` has a green test, a runnable script, or a documented manual gate in `SHIPPING.md`. The remaining items below need user-supplied resources (Apple Developer ID for notarization, recorded audio for end-to-end latency).

> **Note (later change):** the LLM/Ollama cleanup stage has since been removed — cleanup is now the deterministic pure-Swift pass that always ran ahead of the model. History below describing `OllamaClient`, `CleanupPipeline`, the LLM judge, etc. is kept as a record of what was built. See `CHANGELOG.md` for the removal.

Authoritative spec: `project.md`. Each loop iteration historically picked the top item under `## Todo`, completed it, moved it to `## Done`, committed, and exited.

---

## Todo

### 0. Bootstrap
(complete — see Done)

### 1. Menu bar UI
(M1, M2, M3 done — see Done)

### 2. Fn-key hotkey
(H1, H2, H3, H4 done — see Done)

### 3. Audio capture
(A1, A2, A3 done — see Done)

### 4. STT backend
(S1, S2, S3 done — see Done; **S4** end-to-end latency probe deferred to `scripts/bench-latency.sh` since it needs recorded audio fixtures, see SHIPPING.md)

### 5. Cleanup pipeline (token-efficient)
(C1–C8 done — see Done. The LLM/Ollama stage was later removed; cleanup is now the deterministic pure-Swift pass. See CHANGELOG.md.)

### 6. Paste
(P1, P2 done — see Done; permissions surface lives in Settings → Permissions. P3 sandbox test folded into smoke harness — `scripts/smoke.sh` boots the app and verifies it doesn't crash registering its event taps.)

### 7. Orchestrator
(O1, O2, O3 done — see Done)

### 8. Persistence & history
(D1, D2 done — see Done.)

### 9. Performance gates
(G1 deferred — needs recorded audio. Harness in `scripts/bench-latency.sh`. See SHIPPING.md.)
(G2, G3 covered — see Done)

### 10. Packaging & signing
(K1–K5 done — see Done; needs an actual Developer ID identity + notary creds for a fully-stapled run.)

---

## Done

- **B1** `swift build` green with menu bar skeleton (2026-05-10)
- **B2** `swift test` green, 4 AppState tests pass (2026-05-10)
- **B3** `scripts/build-app.sh` produces ad-hoc-signed `build/Wave.app` bundle with `LSUIElement` set (2026-05-10)
- **M1** `NSStatusItem` displays the `waveform` SF Symbol as a template image (2026-05-10, in initial bootstrap)
- **M2** Menu items "Status: …", "Open Settings…", "Quit" wired to AppState callback (2026-05-10, in initial bootstrap)
- **M3** SwiftUI Settings window with backend, cleanup-model, paste-mode, and hotkey-timing controls bound to `PreferencesStore` (2026-05-10)
- **H1** `FnKeyMonitor` CGEventTap on `flagsChanged` for `.maskSecondaryFn`, with `CGPreflightListenEventAccess` permission probe (2026-05-10)
- **H2** `HotkeyController` state machine: hold-to-dictate (≥250ms) and double-tap-to-lock semantics, on injectable `WaveClock` (2026-05-10)
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
- **D1** `HistoryLogger` JSON-lines writer in `~/Library/Application Support/Wave/history.jsonl`, plumbed into the orchestrator (2026-05-10)
- **K1/K2** `scripts/build-app.sh` produces an .app bundle, ad-hoc-signed by default and Developer-ID-signed with entitlements when `WAVE_SIGNING_IDENTITY` is set (2026-05-10)
- **K3/K4** `scripts/release.sh` builds, codesigns, notarizes via `notarytool` (when creds are set), staples, and produces a `dist/Wave.dmg`; falls back to unsigned DMG cleanly when env is missing (2026-05-10, dry-run produced 200KB DMG)
- **O3** Floating `StatusPillController` (NSPanel + SwiftUI, ultraThinMaterial, status-bar level) shows live partial transcript + animated recording indicator; hides on idle, lingers 1.5s on errors (2026-05-10)
- **D2** `HistoryWindowController` SwiftUI list backed by `HistoryLogger.recent(limit:)` with per-entry timing breakdown and SKIPPED/CLEANED badge (2026-05-10)
- **H3/A2** `PermissionsProbe` (`AVCaptureDevice` + `CGPreflightListenEventAccess` + `AXIsProcessTrusted`) plus a Permissions section in Settings with an "Open System Settings" deep-link button per pane (2026-05-10)
- **A3** `AudioRingBuffer` for the last N seconds of mic audio (off by default, capacity-gated) (2026-05-10)
- **S3** `STTBackendFactory.make(for:)` driven by `PreferencesStore.value.sttBackend` (2026-05-10)
- **C6** `tests/fixtures/cleanup-pairs.json` (31 entries) with raw → cleaned pairs and gate-decision expectations (2026-05-10)
- **C7** `tests/fixtures/identifier-spelling.json` (10 entries) with letter-by-letter spellings; gate must never skip them (verified by `FixtureGateTests`) (2026-05-10)
- **C8** `SkipGate` keyword list tightened (dropped ambiguous English words like `for`, `try`, `error`) and a single-letter-spelling heuristic added (2026-05-10)
- **K5** README rewritten with first-run permissions table, env-var configuration table, model-swap recipe, and signed/notarized release walkthrough (2026-05-10)
- **F1** `scripts/smoke.sh` builds the .app, boots it, asserts the process survives 5s, and sends TERM. Passing on host. (2026-05-10)
- **G2** `TokenBudgetBenchmarkTests` walks the cleanup-pair fixture and asserts input-token p95 ≤ 200 (the project.md P3 budget) (2026-05-10)
- **G3** `scripts/bench-idle.sh` snapshots CPU% and RSS after 30s and fails if either exceeds 1.5% / 350MB (2026-05-10)
- **Q2** `Tests/fixtures/hallucination-audit.json` (12 entries) with raw → must-not-contain tokens, plus `HallucinationFixtureTests` structural validation (2026-05-10)
- **Icon** `scripts/make-icon.sh` renders an SF-Symbol-derived 1024px PNG and turns it into `Resources/AppIcon.icns`; bundle now includes it via `CFBundleIconFile = AppIcon` (2026-05-10)
- **judge.sh** `scripts/judge.sh` POSTs every cleanup-pair through the configured Ollama model, scores via a judge model, and asserts F4 (≥80% pass), Q1 (mean ≥7.5), Q2 (zero hallucinations). Exits cleanly if Ollama isn't reachable. (2026-05-10)
- **bench-latency.sh** Audio-fixture replay harness for E2E p50/p95 latency. Exits with a clear message if audio fixtures or Ollama are missing. (2026-05-10)
- **Audio fixture README** `Tests/fixtures/audio/README.md` lists 20 prompts to record and explains the `afconvert` recipe; directory gitignored so recordings stay local. (2026-05-10)
- **SHIPPING.md** Per-gate status table mapping every project.md requirement to its automated test or its real-env command, with a one-shot end-to-end recipe for an operator with Developer ID + Ollama. (2026-05-10)
- **HeuristicCleanup** Regex+token fallback that converts spoken symbols ("open paren self dot id close paren" → "(self.id)"), spoken digits ("five" → "5"), and joins single-letter spelling runs ("u s e r underscore i d" → "user_id"). Wired as the pipeline's automatic fallback when Ollama isn't reachable. 7 unit tests. (2026-05-10)
- **OnboardingWindow** First-launch SwiftUI panel with hierarchical waveform symbol, three permission rows (Mic / Input Monitoring / Accessibility) each with explainer, status icon, and Grant button that deep-links into the right Privacy & Security pane. Auto-opens only if any permission is missing; auto-refreshes every second. (2026-05-10)
- **Cleanup mode preference** `auto` (default) / `heuristic` / `off`. Pipeline branches on it; Settings UI exposes the selector and disables Ollama fields outside `auto`. Env var `WAVE_CLEANUP_MODE` honored. (2026-05-10)
- **Test Dictation menu item** Cmd+T from the status bar runs a fixed sample (`open paren self dot user underscore id close paren`) through pipeline + paster. Verifies F5 without recording mic audio. (2026-05-10)
- **CHANGELOG.md** Added (2026-05-10)
- **OllamaHealthProbe** `/api/tags` reachability + model-presence probe; Settings shows live health row with manual reprobe and per-state remediation text. 3 unit tests via in-process URLProtocol stub. (2026-05-10)
- **History row Copy** Each row gets a Copy button with 1.5s "Copied" badge. (2026-05-10)
- **Error auto-fade** AppState.setStatus(.error) auto-resets to .idle after 3s so the menu bar doesn't pin a stale error. (2026-05-10)
- **ParakeetBackend** FluidAudio + Parakeet TDT v2 (CoreML/ANE) replacing the prior backends; AVAudioEngine input with Apple system voice processing enabled; 16 kHz mono Float buffer; lazy model download on first session, background prewarm at app launch. `STTBackendFactory`, `STTBackendKind`, the backend picker, the Whisper.cpp binary, the GGML model, the Python sidecar, and `WAVE_STT_BACKEND` / `WAVE_WHISPER_*` / `WAVE_VOXTRAL_PYTHON` env vars all removed. (2026-05-12)

---

## Blocked

(empty at start)
