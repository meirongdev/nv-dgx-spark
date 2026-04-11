#!/usr/bin/env bash
set -euo pipefail

COORDINATOR_HOST="${1:?coordinator host required}"
WORKER_HOST="${2:?worker host required}"
MODEL_NAME="${3:?model required}"
PORT="${4:?port required}"
SSH_KEY="${5:?ssh key required}"
SSH_USER="${6:?ssh user required}"
REPORT_DIR="benchmarks"
REPORT_FILE="${REPORT_DIR}/dgx-spark-tp2-qwen35a3b-2026-04-11.md"

mkdir -p "${REPORT_DIR}"

ssh_cmd() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
}

collect_node_snapshot() {
  local host="$1"
  ssh_cmd "${host}" "printf 'host=%s\n' \"\$(hostname)\" && free -h | sed -n '1,2p' && nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader"
}

run_case() {
  local label="$1"
  local prompt="$2"
  local max_tokens="$3"
  local start_ns end_ns elapsed_ms
  start_ns="$(date +%s%N)"
  response="$(curl -sS -w '\n%{http_code}' "http://${COORDINATOR_HOST}:${PORT}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"${prompt}\",\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}")"
  end_ns="$(date +%s%N)"
  elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"
  http_code="$(printf '%s' "${response}" | tail -n1)"
  body="$(printf '%s' "${response}" | sed '$d')"
  completion_tokens="$(printf '%s' "${body}" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data.get("usage",{}).get("completion_tokens",0))')"
  first_text="$(printf '%s' "${body}" | python3 -c 'import sys,json; data=json.load(sys.stdin); choices=data.get("choices") or []; first_choice=choices[0] if choices else {}; text=first_choice.get("text","") if isinstance(first_choice, dict) else ""; error=data.get("error"); error_msg=error.get("message","") if isinstance(error, dict) else (str(error) if error else ""); preview=(text or (("API error: " + error_msg) if error_msg else "")).replace("\n"," "); print(preview[:80])')"
  tokens_per_sec="$(python3 - <<PY
elapsed_ms = ${elapsed_ms}
tokens = ${completion_tokens}
print(round((tokens * 1000 / elapsed_ms), 2) if elapsed_ms else 0)
PY
)"
  printf '| %s | %s | %s | %s | %s | %s |\n' "${label}" "${http_code}" "${completion_tokens}" "${elapsed_ms}" "${tokens_per_sec}" "${first_text}"
}

{
  echo '# DGX Spark TP=2 Benchmark Report'
  echo
  echo '## Environment'
  echo
  echo "| Field | Value |"
  echo "|------|-------|"
  echo "| Date | 2026-04-11 |"
  echo "| Coordinator | ${COORDINATOR_HOST} |"
  echo "| Worker | ${WORKER_HOST} |"
  echo "| Model | ${MODEL_NAME} |"
  echo "| TP Size | 2 |"
  echo "| Port | ${PORT} |"
  echo
  echo '## Pre-run snapshots'
  echo
  echo '```text'
  collect_node_snapshot "${COORDINATOR_HOST}"
  echo '---'
  collect_node_snapshot "${WORKER_HOST}"
  echo '```'
  echo
  echo '## Benchmark results'
  echo
  echo '| Case | HTTP | Completion Tokens | Latency (ms) | Tokens/s | Preview |'
  echo '|------|------|-------------------|--------------|----------|---------|'
  run_case "short-greeting" "Say hello in one sentence." 32
  run_case "memory-summary" "Explain unified memory on DGX Spark in under 80 words." 96
  run_case "code-snippet" "Write a Python function that computes Fibonacci with memoization." 160
  echo
  echo '## Post-run snapshots'
  echo
  echo '```text'
  collect_node_snapshot "${COORDINATOR_HOST}"
  echo '---'
  collect_node_snapshot "${WORKER_HOST}"
  echo '```'
} > "${REPORT_FILE}"

echo "Report written to ${REPORT_FILE}"
