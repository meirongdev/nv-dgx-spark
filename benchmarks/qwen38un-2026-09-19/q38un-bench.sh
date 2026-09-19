#!/usr/bin/env bash
# Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2 —— 与 benchmarks/glm53-2026-09-19/
# 的同名脚本**同一套方法**,只换了模型名和思考 kwarg,好让两个栈的数字直接可比。
#
# ⚠️ 本栈的思考语义(第五套,与前四个栈都不同):
#     kwarg      chat_template_kwargs {"enable_thinking": false}   ← 可以关
#     CoT 字段   reasoning_content   (--reasoning-parser qwen3)
#     默认       ON
#   对照:V4=thinking / Flash-Next=enable_thinking / GLM=reasoning_effort(关不掉)
#   本栈能真正关掉 thinking,所以数字与上游那张 "thinking off" 的表**条件一致**。
#
# 非流式 + 从 usage 计数(流式数的是 step,benchmarking 陷阱 #1)。

set -uo pipefail

URL="${URL:-http://localhost:8888/v1}"
MODEL="${MODEL:-qwen3.8-27b-sglang}"
THINKING="${THINKING:-false}"
MAXTOK="${MAXTOK:-400}"
WARMUPS="${WARMUPS:-2}"
REPS="${REPS:-3}"
MIN_AVAIL_MIB="${MIN_AVAIL_MIB:-800}"

avail_mib() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

guard() {
  local a; a=$(avail_mib)
  if [ "$a" -lt "$MIN_AVAIL_MIB" ]; then
    echo "ABORT: MemAvailable=${a} MiB < ${MIN_AVAIL_MIB} MiB —— 停止压测,避免 OOM 冻住节点"
    exit 1
  fi
  printf '%s' "$a"
}

# $1=name  $2=prompt
run_phase() {
  local name="$1" prompt="$2" i t0 t1 w best=0 n tps a
  python3 - "$MODEL" "$prompt" "$MAXTOK" "$THINKING" > /tmp/bq.json <<'PY'
import json, sys
m, p, mt, e = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({"model": m, "messages": [{"role": "user", "content": p}],
                  "max_tokens": mt, "temperature": 0, "stream": False,
                  "chat_template_kwargs": {"enable_thinking": e == "true"}}))
PY
  for _ in $(seq 1 "$WARMUPS"); do
    curl -s -m 300 "$URL/chat/completions" -H 'Content-Type: application/json' -d @/tmp/bq.json > /dev/null
  done
  for i in $(seq 1 "$REPS"); do
    a=$(guard)
    t0=$(date +%s.%N)
    curl -s -m 300 "$URL/chat/completions" -H 'Content-Type: application/json' -d @/tmp/bq.json > /tmp/br.json
    t1=$(date +%s.%N)
    w=$(echo "$t1 - $t0" | bc)
    read -r n tps <<<"$(python3 - /tmp/br.json "$w" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); w = float(sys.argv[2])
if "usage" not in d: print("0 0"); raise SystemExit
n = d["usage"]["completion_tokens"]
print(f"{n} {n/w:.1f}")
PY
)"
    [ "$n" -lt 50 ] && { echo "  FAIL: $name 只生成 $n token,不算数"; return 1; }
    printf '  %-11s run%s  out=%3s tok  wall=%5.2fs  %5.1f tok/s   (avail %s MiB)\n' \
      "$name" "$i" "$n" "$w" "$tps" "$a"
    best=$(python3 -c "print(max($best,$tps))")
  done
  printf '  %-11s BEST  %.1f tok/s\n\n' "$name" "$best"
}

echo "=== Qwen3.8-27B-Uncensored SGLang decode bench ==="
echo "model=$MODEL thinking=$THINKING max_tokens=$MAXTOK warmups=$WARMUPS reps=$REPS"
echo "起始 MemAvailable = $(avail_mib) MiB"
echo

run_phase structured "Count from 1 to 200, one number per line. Output only the numbers." || exit 1
run_phase code       "Write 50 tiny Python functions named clamp_00 through clamp_49. Each takes (v, lo, hi) and returns v clamped to [lo, hi]. Code only, no explanation, no comments." || exit 1
run_phase prose      "Explain in plain prose how a hash map works, including collisions and resizing. No code, no bullet points." || exit 1

echo "结束 MemAvailable = $(avail_mib) MiB"
echo
echo "上游 README「Decode (this kit, 2026-08-28)」x1 = 62.9 tok/s (structured/code, thinking off)"
echo "上游 issue #163 同样走 PYNCCL 的那台      x1 = 31.0 tok/s (structured)"
