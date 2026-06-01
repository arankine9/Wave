#!/bin/bash
# End-to-end latency benchmark: replays the audio fixture corpus through
# the same code path the runtime uses (audio file -> Parakeet TDT v2 ->
# DeterministicCleanup -> paste) and reports p50 / p95 in ms. Asserts the
# project.md P1/P2 bounds (p50 ≤ 800, p95 ≤ 1800).
#
# Requirements:
#   - Audio fixtures in Tests/fixtures/audio/*.wav (record per the README)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO_DIR="$ROOT/Tests/fixtures/audio"

if [ ! -d "$AUDIO_DIR" ] || [ -z "$(ls -A "$AUDIO_DIR"/*.wav 2>/dev/null || true)" ]; then
    echo "[bench-latency] no audio fixtures in $AUDIO_DIR"
    echo "                 see Tests/fixtures/audio/README.md for what to record"
    exit 2
fi

# The latency harness lives inside the test target so it shares all the
# wiring with the production code path.
exec swift test --filter LatencyBenchmark 2>&1 \
    | tee "$ROOT/build/latency-bench.log"
