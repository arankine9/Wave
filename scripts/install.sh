#!/bin/bash
# One-shot Voxflow setup. Detects what's missing, prints exact next steps,
# and offers to install when --yes is supplied. Idempotent: safe to re-run.
#
# Without --yes the script is read-only: it prints a status report and the
# commands you'd run to fix anything missing, but does not modify the system.
#
# Usage:
#   bash scripts/install.sh         # check & report
#   bash scripts/install.sh --yes   # check, install, & continue
set -euo pipefail

YES=0
WANT_VOXTRAL=0
WANT_LAUNCH_AT_LOGIN=0
for arg in "$@"; do
    case "$arg" in
        --yes) YES=1 ;;
        --voxtral) WANT_VOXTRAL=1 ;;
        --no-voxtral) WANT_VOXTRAL=0 ;;
        --launch-at-login) WANT_LAUNCH_AT_LOGIN=1 ;;
        --help|-h)
            cat <<'EOF'
Voxflow installer.

Flags:
  --yes               actually install missing pieces (default: report only)
  --voxtral           also set up the Voxtral Python sidecar (large download)
  --launch-at-login   open the app once so it can register as a Login Item
EOF
            exit 0 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_FAILED=0
CHECKS_OK=0
ACTIONS=()

note()  { printf '  • %s\n' "$1"; }
ok()    { CHECKS_OK=$((CHECKS_OK+1));   printf '  ✓ %s\n' "$1"; }
miss()  { CHECKS_FAILED=$((CHECKS_FAILED+1)); printf '  ✗ %s\n' "$1"; }
say()   { printf '\n== %s ==\n' "$1"; }
do_or_record() {
    local label="$1"; shift
    if [ "$YES" = "1" ]; then
        echo "+ $label"; "$@"
    else
        ACTIONS+=("$label  →  $*")
    fi
}

###############################################################################
say "Toolchain"
###############################################################################
if command -v swift >/dev/null 2>&1; then
    ok "swift  ($(swift --version | head -1))"
else
    miss "swift not found — install Xcode or 'xcode-select --install'"
fi
if command -v xcodebuild >/dev/null 2>&1; then
    ok "xcodebuild ($(xcodebuild -version | head -1))"
else
    miss "xcodebuild not found — install Xcode"
fi

###############################################################################
say "Cleanup model (Ollama)"
###############################################################################
if command -v ollama >/dev/null 2>&1; then
    ok "ollama installed ($(ollama --version 2>/dev/null | head -1))"
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null; then
        ok "ollama daemon reachable on :11434"
        if curl -sf http://127.0.0.1:11434/api/tags | grep -q 'qwen2.5-coder'; then
            ok "qwen2.5-coder model present"
        else
            miss "qwen2.5-coder:7b-instruct not pulled"
            do_or_record "pull cleanup model" ollama pull qwen2.5-coder:7b-instruct
        fi
    else
        miss "ollama daemon not running"
        note "Start it with: ollama serve &  (or 'brew services start ollama')"
        if [ "$YES" = "1" ]; then
            ollama serve >/dev/null 2>&1 &
            sleep 2
        fi
    fi
else
    miss "ollama not installed"
    if command -v brew >/dev/null 2>&1; then
        do_or_record "install ollama" brew install ollama
    else
        miss "Homebrew not installed — see https://brew.sh"
    fi
fi

###############################################################################
say "Permissions (these can only be granted by the user via System Settings)"
###############################################################################
note "Microphone, Input Monitoring, Accessibility — flip them on after first launch."
note "The app's Settings → Permissions section deep-links each pane."

###############################################################################
say "Build"
###############################################################################
if [ -d "$ROOT/build/Voxflow.app" ]; then
    ok "build/Voxflow.app exists ($(stat -f '%Sm' "$ROOT/build/Voxflow.app"))"
else
    miss "build/Voxflow.app missing"
    do_or_record "build .app bundle" bash "$ROOT/scripts/build-app.sh" release
fi

###############################################################################
if [ "$WANT_VOXTRAL" = "1" ]; then
    say "Voxtral sidecar (optional)"
    VENV="$HOME/.voxflow/venv"
    if [ -x "$VENV/bin/python" ]; then
        ok "venv at $VENV"
    else
        miss "venv missing"
        do_or_record "create venv" python3 -m venv "$VENV"
    fi
    if [ -x "$VENV/bin/pip" ]; then
        if "$VENV/bin/pip" show transformers >/dev/null 2>&1; then
            ok "transformers installed in venv"
        else
            miss "Voxtral python deps missing"
            do_or_record "install voxtral deps" "$VENV/bin/pip" install -r "$ROOT/Sources/python/requirements.txt"
        fi
    fi
    if [ -n "${VOXFLOW_VOXTRAL_PYTHON:-}" ]; then
        ok "VOXFLOW_VOXTRAL_PYTHON=$VOXFLOW_VOXTRAL_PYTHON"
    else
        miss "VOXFLOW_VOXTRAL_PYTHON not set"
        note "Add to your shell profile: export VOXFLOW_VOXTRAL_PYTHON=\"$VENV/bin/python\""
    fi
fi

###############################################################################
say "Launch at login (optional)"
###############################################################################
if [ "$WANT_LAUNCH_AT_LOGIN" = "1" ]; then
    note "Open Voxflow once — Settings → General → 'Launch at login' is a one-click toggle."
fi

###############################################################################
say "Summary"
###############################################################################
printf "  %d ok, %d missing\n" "$CHECKS_OK" "$CHECKS_FAILED"
if [ "${#ACTIONS[@]}" -gt 0 ] && [ "$YES" != "1" ]; then
    printf "\n  Actions queued (rerun with --yes to apply):\n"
    for a in "${ACTIONS[@]}"; do printf "    - %s\n" "$a"; done
fi

if [ "$CHECKS_FAILED" -gt 0 ] && [ "$YES" != "1" ]; then
    exit 1
fi
exit 0
