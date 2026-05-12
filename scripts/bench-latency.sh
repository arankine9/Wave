#!/bin/bash
# End-to-end latency benchmark: replays the audio fixture corpus through
# the same code path the runtime uses (audio file -> Parakeet TDT v2 ->
# CleanupPipeline against Ollama) and reports p50 / p95 in ms. Asserts the
# project.md P1/P2 bounds (p50 ≤ 800, p95 ≤ 1800).
#
# Requirements:
#   - Ollama running at $BECK_OLLAMA_URL with $BECK_CLEANUP_MODEL pulled
#   - Audio fixtures in Tests/fixtures/audio/*.wav (record per the README)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO_DIR="$ROOT/Tests/fixtures/audio"

if [ ! -d "$AUDIO_DIR" ] || [ -z "$(ls -A "$AUDIO_DIR"/*.wav 2>/dev/null || true)" ]; then
    echo "[bench-latency] no audio fixtures in $AUDIO_DIR"
    echo "                 see Tests/fixtures/audio/README.md for what to record"
    exit 2
fi

OLLAMA_URL="${BECK_OLLAMA_URL:-http://127.0.0.1:11434}"
if ! curl -sf "$OLLAMA_URL/api/tags" >/dev/null; then
    echo "[bench-latency] ollama not reachable at $OLLAMA_URL"
    exit 2
fi

# The latency harness lives inside the test target so it shares all the
# wiring with the production code path.
exec swift test --filter LatencyBenchmark 2>&1 \
    | tee "$ROOT/build/latency-bench.log"
