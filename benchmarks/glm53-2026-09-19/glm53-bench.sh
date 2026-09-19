#!/usr/bin/env bash
# GLM-5.3-Flash EXL3 decode benchmark —— 复刻上游 README「Decode (this kit, 2026-08-28)」
# 那张表的行,好让数字**可直接对比**:
#   上游 sparkDash Decode bench, DFlash2 k=7, temp 0, thinking off, 400 tokens,
#   CUDA graphs, fused EXL3 MoE。结构化/代码 x1 = 62.9 tok/s。
#
# 本栈差异(必须写明,否则不可比):
#   - thinking **关不掉**,最低 reasoning_effort=low(上游那张表写的 "thinking off"
#     在本模板上没有等价物)。
#   - 非流式 + 从 usage 计数(流式数的是 step,benchmarking 陷阱 #1)。
#
# ⚠️ 内存:S1 空载 headroom 仅 ~2.4 GiB。本脚本每轮采样 MemAvailable,
#    低于 MIN_AVAIL_MIB 直接中止 —— 上游 README 记过「256k prefill 在 zero
#    MemAvailable 下 crash 掉 head」,而这两台没有 BMC。
set -uo pipefail

URL="${URL:-http://localhost:8888/v1}"
MODEL="${MODEL:-GLM-5.3-Flash-EXL3}"
EFFORT="${EFFORT:-low}"
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
  python3 - "$MODEL" "$prompt" "$MAXTOK" "$EFFORT" > /tmp/bq.json <<'PY'
import json, sys
m, p, mt, e = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({"model": m, "messages": [{"role": "user", "content": p}],
                  "max_tokens": mt, "temperature": 0, "stream": False,
                  "chat_template_kwargs": {"reasoning_effort": e}}))
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

echo "=== GLM-5.3-Flash EXL3 decode bench ==="
echo "model=$MODEL effort=$EFFORT max_tokens=$MAXTOK warmups=$WARMUPS reps=$REPS"
echo "起始 MemAvailable = $(avail_mib) MiB"
echo

run_phase structured "Count from 1 to 200, one number per line. Output only the numbers." || exit 1
run_phase code       "Write 50 tiny Python functions named clamp_00 through clamp_49. Each takes (v, lo, hi) and returns v clamped to [lo, hi]. Code only, no explanation, no comments." || exit 1
run_phase prose      "Explain in plain prose how a hash map works, including collisions and resizing. No code, no bullet points." || exit 1

echo "结束 MemAvailable = $(avail_mib) MiB"
echo
echo "上游 README「Decode (this kit, 2026-08-28)」x1 = 62.9 tok/s (structured/code, thinking off)"
echo "上游 issue #163 同样走 PYNCCL 的那台      x1 = 31.0 tok/s (structured)"
