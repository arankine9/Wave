#!/bin/bash
# Idle resource benchmark: launches Beck, lets it sit for 30 seconds,
# then samples CPU% and RSS via `ps`. Asserts the project.md P4 bound
# (idle CPU ≤ 1.5%, idle RAM ≤ 350MB excluding model weights — STT model
# weights and Ollama RAM are external).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Beck.app"
BIN="$APP/Contents/MacOS/Beck"

if [ ! -x "$BIN" ]; then
    echo "[bench-idle] building"
    bash "$ROOT/scripts/build-app.sh" release >/dev/null
fi

"$BIN" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

echo "[bench-idle] settling 30s"
sleep 30

# %cpu = average CPU since launch; rss in KB.
SAMPLE=$(ps -o %cpu=,rss= -p "$PID" | awk '{print $1, $2}')
CPU=$(echo "$SAMPLE" | awk '{print $1}')
RSS_KB=$(echo "$SAMPLE" | awk '{print $2}')
RSS_MB=$(awk "BEGIN { printf \"%.1f\", $RSS_KB/1024 }")

echo "[bench-idle] cpu=${CPU}%  rss=${RSS_MB}MB"
kill "$PID"
wait "$PID" 2>/dev/null || true

awk -v cpu="$CPU" 'BEGIN { exit (cpu+0 <= 1.5) ? 0 : 1 }' \
    || { echo "[bench-idle] FAIL: idle CPU > 1.5% (got $CPU%)"; exit 1; }
awk -v rss="$RSS_MB" 'BEGIN { exit (rss+0 <= 350) ? 0 : 1 }' \
    || { echo "[bench-idle] FAIL: idle RAM > 350MB (got ${RSS_MB}MB)"; exit 1; }
echo "[bench-idle] PASS"
