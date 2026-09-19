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
LEVELS="${LEVELS:-8000 16000 32000 64000 128000}"   # 目标 prompt token 数
FLOOR_MIB="${FLOOR_MIB:-600}"
KILL_MIB="${KILL_MIB:-450}"   # 飞行中击穿此线 → 立即杀 curl

avail() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

echo "=== 长 prompt prefill 阶梯 ==="
echo "model=$MODEL  档间地板=${FLOOR_MIB} MiB  飞行中熔断=${KILL_MIB} MiB  (prefix caching: 每发唯一 nonce → cold)"
echo "起始 MemAvailable = $(avail) MiB"
echo
echo "上游对照: 8k 1492 / 16k 1554 / 32k 1428 / 64k 1587 / 128k 1562 tok/s"
echo
printf '%-8s %10s %9s %12s %11s %10s\n' "目标" "实际tok" "TTFT(s)" "prefill tok/s" "内存最低" "缓存命中"

for target in $LEVELS; do
  a0=$(avail)
  if [ "$a0" -lt "$FLOOR_MIB" ]; then
    echo "ABORT: 升档前 MemAvailable=${a0} MiB < ${FLOOR_MIB} —— 停止"; break
  fi

  # 构造唯一 cold prompt:nonce 在最前面
  python3 - "$MODEL" "$target" "$THINKING" > /tmp/pq.json <<'PY'
import json, sys, uuid
model, target, effort = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# ~0.75 token/word 的粗估,靠服务端 usage 报真实值;宁可略多
chunk = ("The quick brown fox jumps over the lazy dog while the systems engineer "
         "reviews distributed inference traces and tensor parallel scheduling logs. ")
words_needed = int(target / 0.75)
body = (chunk * (words_needed // len(chunk.split()) + 2))
nonce = uuid.uuid4().hex          # ← 必须在最前面,否则前缀缓存会命中
prompt = f"[{nonce}] " + " ".join(body.split()[:words_needed])
print(json.dumps({"model": model,
                  "messages": [{"role": "user", "content": prompt + "\n\nReply with the single word: ok"}],
                  "max_tokens": 1, "temperature": 0, "stream": False,
                  "chat_template_kwargs": {"enable_thinking": effort == "true"}}))
PY

  # 后台高频采样 + **飞行中**守护。
  # ⚠️ 只在请求结束后判熔断是救不了正在飞的那一发的 —— 而恰恰是那一发会把
  #    内存打到地板。KILL_MIB 一旦击穿就直接杀掉 curl,让引擎回收这次 prefill。
  #    (引擎侧该请求会被客户端断开而中止;这比让节点 OOM 冻住 sshd 便宜得多。)
  echo 999999 > /tmp/plow
  t0=$(date +%s.%N)
  curl -s -m 900 "$URL/chat/completions" -H 'Content-Type: application/json' -d @/tmp/pq.json > /tmp/pr.json &
  CURL=$!
  ( low=999999
    while kill -0 $CURL 2>/dev/null; do
      v=$(avail); [ "$v" -lt "$low" ] && low=$v; echo "$low" > /tmp/plow
      if [ "$v" -lt "$KILL_MIB" ]; then
        echo "!! 飞行中熔断:MemAvailable=${v} MiB < ${KILL_MIB} —— 杀掉本次 prefill" >&2
        kill -9 $CURL 2>/dev/null; echo KILLED > /tmp/pkill; break
      fi
      sleep 0.2
    done ) &
  SAMP=$!
  wait $CURL 2>/dev/null
  t1=$(date +%s.%N)
  kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null
  if [ -f /tmp/pkill ]; then
    rm -f /tmp/pkill
    echo "ABORT: 本档被飞行中熔断掐掉 —— 不再升档。这是本 kit 的 prefill 上限信号。"
    break
  fi
  ttft=$(echo "$t1 - $t0" | bc)
  low=$(cat /tmp/plow)

  read -r ptok cached <<<"$(python3 - /tmp/pr.json <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1])); u = d["usage"]
    c = (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
    print(u["prompt_tokens"], c)
except Exception:
    print(0, 0)
PY
)"
  if [ "$ptok" -lt 100 ]; then
    echo "FAIL: 服务端没返回有效 usage(prompt_tokens=$ptok)"; head -c 200 /tmp/pr.json; echo; break
  fi
  tps=$(python3 -c "print(f'{$ptok/$ttft:.0f}')")
  printf '%-8s %10s %9.2f %12s %8s MiB %10s\n' "${target}" "$ptok" "$ttft" "$tps" "$low" "$cached"

  if [ "$low" -lt "$FLOOR_MIB" ]; then
    echo "ABORT: 本档内存最低 ${low} MiB < ${FLOOR_MIB} —— 停止升档(不再试更长的 prompt)"
    break
  fi
done

echo
echo "结束 MemAvailable = $(avail) MiB"
