#!/bin/bash
# Run the cleanup-pair fixture corpus against the local Ollama model, score
# each pair with an LLM-as-judge prompt, and report aggregate stats. Also
# runs the hallucination-audit fixture and asserts no forbidden token
# appears in the model's cleaned output.
#
# Project.md gates this exercises:
#   F4  cleanup model produces valid output for fixture pairs (≥80% pass)
#   Q1  LLM-as-judge mean score ≥ 7.5 / 10
#   Q2  zero hallucinated tokens across the audit fixture
#
# Requirements: Ollama daemon reachable at $BECK_OLLAMA_URL with the
# cleanup model and the judge model both pulled. `jq` for JSON munging.
#
# Usage: scripts/judge.sh [--cleanup MODEL] [--judge MODEL]
set -euo pipefail

CLEANUP_MODEL="${BECK_CLEANUP_MODEL:-qwen2.5-coder:7b-instruct}"
JUDGE_MODEL="${BECK_JUDGE_MODEL:-qwen2.5:7b-instruct}"
OLLAMA_URL="${BECK_OLLAMA_URL:-http://127.0.0.1:11434}"

while [ $# -gt 0 ]; do
    case "$1" in
        --cleanup) CLEANUP_MODEL="$2"; shift 2;;
        --judge) JUDGE_MODEL="$2"; shift 2;;
        *) echo "unknown flag: $1" >&2; exit 2;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAIRS="$ROOT/Tests/fixtures/cleanup-pairs.json"
AUDIT="$ROOT/Tests/fixtures/hallucination-audit.json"

if ! command -v jq >/dev/null; then
    echo "jq required" >&2; exit 2
fi
if ! curl -sf "$OLLAMA_URL/api/tags" >/dev/null; then
    echo "ollama not reachable at $OLLAMA_URL — start with 'ollama serve'" >&2
    exit 2
fi

SYSTEM_PROMPT="$(cat <<'EOF'
You convert spoken coding dictation to clean text or code.
Rules:
1. Output only the cleaned result. No prose, no explanations.
2. Preserve every identifier the user spelled out letter by letter.
3. Translate spoken punctuation to symbols (paren -> (, dot -> ., equals -> =).
4. Drop fillers (uh, um, you know).
5. Honor self-corrections: if the user said "no wait", drop the prior phrase.
6. Match the user's apparent language unless told otherwise.
EOF
)"

call_model() {
    local model="$1" sys="$2" user="$3"
    jq -n --arg model "$model" --arg sys "$sys" --arg user "$user" '{
        model: $model,
        stream: false,
        messages: [
            { role: "system", content: $sys },
            { role: "user", content: $user }
        ],
        options: { temperature: 0.2, num_predict: 400 }
    }' | curl -sf -X POST "$OLLAMA_URL/api/chat" -H 'Content-Type: application/json' -d @- \
       | jq -r '.message.content'
}

###############################################################################
# F4 + Q1 — judge cleanup-pairs
###############################################################################
echo "[judge] scoring cleanup-pairs (cleanup=$CLEANUP_MODEL judge=$JUDGE_MODEL)"
TOTAL=0
SUM=0
FAILED=0
PASSED=0
N=0

while read -r raw expected skipFlag; do
    if [ "$skipFlag" = "true" ]; then continue; fi
    cleaned="$(call_model "$CLEANUP_MODEL" "$SYSTEM_PROMPT" "$raw")"
    score_raw="$(call_model "$JUDGE_MODEL" \
        "You are a strict grader. Score the model's cleanup of dictated coding speech on a 0-10 integer scale based on how closely it matches the expected output. Output ONLY the integer." \
        "RAW: $raw"$'\n'"EXPECTED: $expected"$'\n'"MODEL: $cleaned")"
    score="$(echo "$score_raw" | grep -oE '^[0-9]+' | head -1)"
    score="${score:-0}"
    SUM=$((SUM + score))
    N=$((N + 1))
    if [ "$score" -ge 6 ]; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); fi
    printf "  [%2d] %s -> %s   (score %s)\n" "$N" "$raw" "$cleaned" "$score"
done < <(jq -r '.entries[] | "\(.raw)\t\(.cleaned)\t\(.expectGateSkip)"' "$PAIRS")

if [ "$N" -gt 0 ]; then
    MEAN_X10="$((SUM * 10 / N))"
    MEAN_INT="$((SUM / N))"
    MEAN_FRAC="$((MEAN_X10 - MEAN_INT * 10))"
    echo "[judge] cleanup mean score: ${MEAN_INT}.${MEAN_FRAC}/10  (passed ${PASSED}/${N})"
fi

###############################################################################
# Q2 — hallucination audit
###############################################################################
echo "[judge] hallucination audit"
HALLUCINATIONS=0
while read -r raw forbidden_json; do
    cleaned="$(call_model "$CLEANUP_MODEL" "$SYSTEM_PROMPT" "$raw")"
    while read -r forbidden; do
        if echo "$cleaned" | grep -iqF -- "$forbidden"; then
            echo "  HALLUCINATION raw='$raw' added='$forbidden' -> '$cleaned'"
            HALLUCINATIONS=$((HALLUCINATIONS + 1))
        fi
    done < <(echo "$forbidden_json" | jq -r '.[]')
done < <(jq -c '.entries[] | [.raw, .mustNotContain] | @tsv' "$AUDIT" \
         | awk -F'\t' '{ print $1 "\t" $2 }')

echo "[judge] hallucinations: $HALLUCINATIONS"
[ "$HALLUCINATIONS" -eq 0 ] || { echo "[judge] FAIL: hallucinations detected"; exit 1; }

if [ "$N" -gt 0 ]; then
    PASS_RATE=$((PASSED * 100 / N))
    [ "$PASS_RATE" -ge 80 ] || { echo "[judge] FAIL: F4 pass rate $PASS_RATE% < 80%"; exit 1; }
    [ "$MEAN_INT" -ge 7 ] || { echo "[judge] FAIL: Q1 mean score < 7.5"; exit 1; }
fi
echo "[judge] PASS"
