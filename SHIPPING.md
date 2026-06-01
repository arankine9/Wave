# Shipping checklist

Wave's spec lives in `project.md`. The autonomous loop took the codebase from empty repo to a runnable native menu-bar app with a full dictation pipeline. Some final gates need a real environment (Apple Developer account, recorded audio). This file lists each gate and the exact command to flip it green.

## Status legend

- ✅ green in CI / repo-state
- 🟡 needs a one-time environment prep then green
- 🔴 needs a real-world recording or live model

## Functional gates

| ID | Gate | Status | How to flip |
|---|---|---|---|
| F1 | App boots without crashing | ✅ | `bash scripts/smoke.sh` |
| F2 | Fn-key hotkey detection | ✅ | `swift test --filter HotkeyControllerTests` |
| F3 | STT backend boots and accepts audio | 🔴 | Record audio fixtures (see `Tests/fixtures/audio/README.md`), then `bash scripts/bench-latency.sh` |
| F5 | Synthetic paste reaches a target window | 🟡 | Manual: launch app, focus a TextEdit window, dictate |
| F6 | Deterministic cleanup (code vs prose routing) | ✅ | `swift test --filter HeuristicCleanupTests` |
| F7 | History panel renders last 50 | ✅ | Open via menu bar → Open History… |

## Performance gates

| ID | Gate | Status | How to flip |
|---|---|---|---|
| P1 | E2E p50 ≤ 800ms | 🔴 | Record audio + run `scripts/bench-latency.sh` |
| P2 | E2E p95 ≤ 1800ms | 🔴 | Same as P1 |
| P4 | Idle CPU ≤ 1.5%, RAM ≤ 350MB | 🟡 | `bash scripts/bench-idle.sh` |

## Quality gates

| ID | Gate | Status | How to flip |
|---|---|---|---|
| Q3 | Identifier-spelling preservation | ✅ | `swift test --filter HeuristicCleanupTests` |

## Packaging & release

| ID | Gate | Status | How to flip |
|---|---|---|---|
| K1 | `Wave.app` bundle | ✅ | `bash scripts/build-app.sh release` |
| K2 | Developer-ID code signing | 🟡 | `export WAVE_SIGNING_IDENTITY="Developer ID Application: …" && bash scripts/build-app.sh release` |
| K3 | Notarization | 🟡 | Set `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, then `bash scripts/release.sh` |
| K4 | Stapled, signed `.dmg` | 🟡 | Same as K3 (`scripts/release.sh` chains all four) |
| K5 | README install + permissions docs | ✅ | `README.md` |

## One-shot end-to-end

If you have Developer ID + audio fixtures already in place:

```bash
swift test                              # unit + integration suite
bash scripts/smoke.sh                   # F1
bash scripts/bench-idle.sh              # P4
bash scripts/bench-latency.sh           # F3 + P1 + P2 (after recording fixtures)

export WAVE_SIGNING_IDENTITY="Developer ID Application: …"
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"
export APPLE_TEAM_ID="ABCDE12345"

bash scripts/release.sh                 # K1 + K2 + K3 + K4 -> dist/Wave.dmg
```

## What's deliberately deferred

- **Tiered model selector.** Parakeet TDT v2 covers v1; future work could expose a Settings option to swap in a multilingual or smaller variant based on Mac specs.
- **Eager Parakeet download in onboarding.** Today the first hold-to-talk triggers the lazy download (pre-warmed in the background at launch); a progress UI inside the onboarding panel would surface the wait explicitly.
- **GRDB / SQLite history.** JSON-lines covers v1; swap in GRDB once history queries grow beyond "last 50 entries."
- **Audio waveform inside the status pill.** The pill currently shows the partial transcript and a pulsing recording dot; a full waveform needs the recorder to expose a level meter, which can plug into `AudioRingBuffer`.
