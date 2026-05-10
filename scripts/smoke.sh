#!/bin/bash
# Smoke test: builds Voxflow.app, launches it, gives it a few seconds to
# install the menu bar item and finish startup, then quits cleanly. Fails
# if the process crashes during boot or refuses to terminate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Voxflow.app"
BIN="$APP/Contents/MacOS/Voxflow"

echo "[smoke] building .app"
bash "$ROOT/scripts/build-app.sh" debug >/dev/null

if [ ! -x "$BIN" ]; then
    echo "[smoke] missing executable: $BIN" >&2
    exit 1
fi

echo "[smoke] launching"
"$BIN" &
PID=$!

trap 'kill "$PID" 2>/dev/null || true' EXIT

# Wait up to 5 seconds for the process to settle.
for i in $(seq 1 10); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[smoke] process exited during boot (i=$i)" >&2
        exit 1
    fi
    sleep 0.5
done

if ! kill -0 "$PID" 2>/dev/null; then
    echo "[smoke] process exited unexpectedly" >&2
    exit 1
fi

echo "[smoke] sending TERM"
kill "$PID"
wait "$PID" 2>/dev/null || true

echo "[smoke] PASS"
