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
LEVELS="${LEVELS:-1 2 4 8 16}"
FLOOR_MIB="${FLOOR_MIB:-700}"
PROMPT="${PROMPT:-Count from 1 to 200, one number per line. Output only the numbers.}"

avail() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

python3 - "$MODEL" "$PROMPT" "$MAXTOK" "$THINKING" > /tmp/cq.json <<'PY'
import json, sys
m, p, mt, e = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({"model": m, "messages": [{"role": "user", "content": p}],
                  "max_tokens": mt, "temperature": 0, "stream": False,
                  "chat_template_kwargs": {"enable_thinking": e == "true"}}))
PY

hit() { curl -s -m 600 "$URL/chat/completions" -H 'Content-Type: application/json' -d @/tmp/cq.json; }

echo "=== 并发梯度 ==="
echo "model=$MODEL thinking=$THINKING max_tokens=$MAXTOK 熔断地板=${FLOOR_MIB} MiB"
echo "engine 上限 MAX_CONCURRENT_REQUESTS=$(grep -oP '^MAX_CONCURRENT_REQUESTS=\K.*' /home/admin/qwen38-sglang/.env 2>/dev/null || echo '?')"
echo "起始 MemAvailable = $(avail) MiB"
echo
echo "warmup..."; hit > /dev/null

printf '%-5s %10s %12s %12s %10s %10s\n' "并发" "墙钟(s)" "聚合tok/s" "单流tok/s" "内存最低" "完成/发出"
for c in $LEVELS; do
  a0=$(avail)
  if [ "$a0" -lt "$FLOOR_MIB" ]; then
    echo "ABORT: 升档前 MemAvailable=${a0} MiB < ${FLOOR_MIB} —— 停止,不再升档"; break
  fi
  rm -f /tmp/cres_*.json
  # 后台采样内存最低点
  ( low=999999; for _ in $(seq 1 200); do v=$(avail); [ "$v" -lt "$low" ] && low=$v; echo "$low" > /tmp/clow; sleep 0.3; done ) &
  SAMP=$!
  t0=$(date +%s.%N)
  for i in $(seq 1 "$c"); do hit > "/tmp/cres_$i.json" & done
  wait $(jobs -rp | grep -v "$SAMP") 2>/dev/null
  t1=$(date +%s.%N)
  kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null
  w=$(echo "$t1 - $t0" | bc)
  low=$(cat /tmp/clow 2>/dev/null || echo "$a0")
  read -r tot ok <<<"$(python3 - "$c" <<'PY'
import glob, json, sys
tot = ok = 0
for f in glob.glob("/tmp/cres_*.json"):
    try:
        d = json.load(open(f))
        tot += d["usage"]["completion_tokens"]; ok += 1
    except Exception:
        pass
print(tot, ok)
PY
)"
  agg=$(python3 -c "print(f'{$tot/$w:.1f}')")
  per=$(python3 -c "print(f'{$tot/$w/max($ok,1):.1f}')")
  printf '%-5s %10.2f %12s %12s %8s MiB %9s\n' "c$c" "$w" "$agg" "$per" "$low" "$ok/$c"
  [ "$low" -lt "$FLOOR_MIB" ] && { echo "ABORT: 本档内存最低 ${low} MiB < ${FLOOR_MIB} —— 停止升档"; break; }
done

echo
echo "结束 MemAvailable = $(avail) MiB"
echo "上游对照 DFlash2 并发梯度(0.90/16): x1 56.6 / x2 58.4 / x4 111.6 / x8 184.9 / x16 227.6 agg"
