#!/usr/bin/env bash
# GLM-5.3-Flash EXL3 长 prompt prefill 阶梯 —— 对标上游 README
# 「Cold prefill (E3 grouped MoE, 2026-09-07)」:8k 1492 / 16k 1554 / 32k 1428
#  / 64k 1587 / 128k 1562 / 256k 1517 tok/s。
#
# 方法(与上游、与本仓库 benchmarks/ 一致):prefill tok/s = prompt_tokens / TTFT,
# TTFT 用 max_tokens=1 的墙钟近似,prompt_tokens 取服务端 usage 的真实值。
#
# ⚠️ 陷阱 1:`--enable-prefix-caching` 是开着的。重复 prompt = 缓存命中 = 假的快。
#    每发在**最开头**插唯一 nonce(前缀缓存从头匹配),保证 0 命中,即 cold。
# ⚠️ 陷阱 2(本脚本存在的理由):上游 README —— "Prompts >= ~100k are near the
#    head's host-memory limit at any setting (a 256k prefill at util 0.87 with
#    zero MemAvailable **crashed the head** on 2026-09-06)"。这两台没有 BMC。
#    → prefill 期间每 0.2s 采样 MemAvailable,记录**最低点**;任一档跌破
#      FLOOR_MIB 立即停止且不再升档。
set -uo pipefail

URL="${URL:-http://localhost:8888/v1}"
MODEL="${MODEL:-GLM-5.3-Flash-EXL3}"
EFFORT="${EFFORT:-low}"
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
  python3 - "$MODEL" "$target" "$EFFORT" > /tmp/pq.json <<'PY'
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
                  "chat_template_kwargs": {"reasoning_effort": effort}}))
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
