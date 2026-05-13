# Parakeet migration plan

**Goal:** Replace whisper.cpp and Voxtral with a single FluidAudio + Parakeet backend, tuned for the dev's M3 Pro / 36 GB / macOS 26.3 setup.

Single-user app (built for myself). No multi-tier hardware fallbacks, no Intel path.

---

## What we're building

### Core STT swap
- Add **FluidAudio v0.14.5+** as an SPM dependency in `Package.swift`.
- New `Sources/WaveCore/STT/ParakeetBackend.swift`, conforming to the existing `STTBackend` protocol.
  - Records via AVAudioEngine; transcribes with FluidAudio's **Parakeet TDT v2** (`AsrModelVersion.v2`, English-only, highest recall).
  - Sample format: 16 kHz mono **Float** array (was Int16 WAV with whisper-cli).
  - Model download is lazy on first `startSession()`, mirroring the existing Voxtral lazy-load pattern. Future: eager download with progress UI in onboarding.

### Voice isolation
- Call `setVoiceProcessingEnabled(true)` on the AVAudioEngine input node in `ParakeetBackend` so Apple's system voice processing suppresses background noise and voices *before* audio reaches Parakeet.
- Pipeline order: mic → Apple voice processing → Parakeet.

---

## What we're removing

### Code
- `Sources/WaveCore/STT/WhisperCppBackend.swift`
- `Sources/WaveCore/STT/VoxtralBackend.swift`
- `Sources/WaveCore/STT/STTBackendFactory.swift` (or simplify to nothing — direct `ParakeetBackend()` instantiation in `AppDelegate`).
- `Sources/python/` entirely (`voxtral_sidecar.py`, `requirements.txt`, `README.md`).
- `STTBackendKind` enum + related fields/env vars in `Preferences.swift`:
  - `WAVE_STT_BACKEND`, `WAVE_WHISPER_BIN`, `WAVE_WHISPER_MODEL`, `WAVE_VOXTRAL_PYTHON`.

### UI
- "Backend" picker in `SettingsWindow.swift`.
- Whisper/Voxtral lines in `Diagnostics.swift`.

### Tests
- `Tests/WaveCoreTests/WhisperCppBackendTests.swift`
- `Tests/WaveCoreTests/STTBackendFactoryTests.swift` (delete; replace with a minimal Parakeet smoke test if useful — skipped unless models present).

### Scripts & docs
- `scripts/install.sh`: drop `brew install whisper-cpp` and the model curl.
- `scripts/bench-latency.sh`: retarget at Parakeet end-to-end.
- `README.md`, `CHANGELOG.md`, `SHIPPING.md`, `TODO.md`, `project.md`: strike whisper/voxtral references.

---

## Out of scope (explicitly deferred)

- Tiered model selector based on Mac specs.
- Eager model download + progress UI in onboarding.

---

## Acceptance checklist

1. `swift build` succeeds with FluidAudio added.
2. `swift test` passes; whisper/voxtral test files are gone.
3. Cold-launch dictation: first hold-to-talk after install triggers Parakeet model download, then transcribes correctly.
4. Warm dictation: subsequent dictations transcribe a 5-second sample at sub-500ms latency on the M3 Pro.
5. With a second voice playing nearby (laptop speakers running a podcast at moderate volume), my dictation transcribes; the podcast's words do not bleed into the output.
6. No references to whisper.cpp, ggml, Voxtral, or the Python sidecar remain in `Sources/`, `Tests/`, `scripts/`, or the top-level docs.
