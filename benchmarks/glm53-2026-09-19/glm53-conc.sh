#!/usr/bin/env bash
# GLM-5.3-Flash EXL3 并发梯度 —— 对标上游 README「Decode (2026-08-28)」的 x1/x2/x4 行
# (上游: x1 62.9 / x2 103.3 agg / x4 146.5 agg,structured,temp0,400 tok)
#
# ⚠️ 内存熔断:S1 空载 headroom 仅 ~2.4 GiB。每档开始前和结束后采样,
#    低于 FLOOR_MIB 立即停止并不再升档 —— 上游 README 记过 zero MemAvailable
#    crash 掉 head,而这两台没有 BMC。
set -uo pipefail

URL="${URL:-http://localhost:8888/v1}"
MODEL="${MODEL:-GLM-5.3-Flash-EXL3}"
EFFORT="${EFFORT:-low}"
MAXTOK="${MAXTOK:-400}"
LEVELS="${LEVELS:-1 2 3 4}"
FLOOR_MIB="${FLOOR_MIB:-700}"
PROMPT="${PROMPT:-Count from 1 to 200, one number per line. Output only the numbers.}"

avail() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

python3 - "$MODEL" "$PROMPT" "$MAXTOK" "$EFFORT" > /tmp/cq.json <<'PY'
import json, sys
m, p, mt, e = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({"model": m, "messages": [{"role": "user", "content": p}],
                  "max_tokens": mt, "temperature": 0, "stream": False,
                  "chat_template_kwargs": {"reasoning_effort": e}}))
PY

hit() { curl -s -m 600 "$URL/chat/completions" -H 'Content-Type: application/json' -d @/tmp/cq.json; }

echo "=== 并发梯度 ==="
echo "model=$MODEL effort=$EFFORT max_tokens=$MAXTOK 熔断地板=${FLOOR_MIB} MiB"
echo "engine 上限 MAX_NUM_SEQS=$(grep -oP '^MAX_NUM_SEQS=\K.*' /home/admin/glm53-exl3/.env 2>/dev/null || echo '?')"
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
echo "上游对照(structured, thinking off): x1 62.9 / x2 103.3 agg / x4 146.5 agg"
