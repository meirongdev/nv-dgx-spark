#!/usr/bin/env bash
# fndgx 单流解码 —— 按 docs/benchmarking-cn.md 的三条避坑:
#   1. 不用流式(流式数的是 steps/s,不是 tok/s)
#   2. 先热身再计(冷 + 闲置衰减约 30%,静默)
#   3. 回答要够长(短回答被开销压顶)
# 每种内容各 3 次,取热身后两次的中位数。内容分开报 —— 投机解码的接受率是内容驱动的。
U=http://localhost:18300/v1/chat/completions
M=qwen3.8-flash-next
run(){ # $1=label $2=prompt $3=max_tokens
  local label="$1" p="$2" mt="$3"
  python3 - "$M" "$p" "$mt" > /tmp/.b.json <<'PY'
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],
 "max_tokens":int(sys.argv[3]),"temperature":0,"stream":False,
 "chat_template_kwargs":{"enable_thinking":False}}))
PY
  local out=""
  for i in 1 2 3; do
    local t0 t1 n
    t0=$(python3 -c 'import time;print(time.time())')
    curl -s -m 600 -o /tmp/.br.json -H 'Content-Type: application/json' -d @/tmp/.b.json "$U"
    t1=$(python3 -c 'import time;print(time.time())')
    n=$(python3 -c 'import json;print(json.load(open("/tmp/.br.json"))["usage"]["completion_tokens"])' 2>/dev/null || echo 0)
    local r; r=$(python3 -c "print(f'{$n/($t1-$t0):.1f}')")
    [ "$i" = 1 ] && printf '  %-12s 热身 %5s tok  %6s tok/s\n' "$label" "$n" "$r" \
                 || { printf '  %-12s 第%d次 %5s tok  %6s tok/s\n' "$label" "$i" "$n" "$r"; out="$out $r"; }
  done
  printf '  %-12s => 热后中位 %s tok/s\n' "$label" "$(python3 -c "
v=sorted(float(x) for x in '$out'.split()); print(f'{(v[len(v)//2] if len(v)%2 else (v[0]+v[1])/2):.1f}')")"
}
echo "=== fndgx 单流解码(非流式,enable_thinking=false,temperature=0)==="
run "代码"   "Write a complete Python implementation of a red-black tree with insert, delete and in-order traversal. Include docstrings. Code only, no explanation." 700
run "散文"   "Write a 600-word essay on why distributed consensus is hard, in plain prose." 700
run "结构化" "List 40 HTTP status codes as a JSON array of objects with fields code, name and when_to_use." 700
rm -f /tmp/.b.json /tmp/.br.json
echo
echo "=== 稳态主机内存(服务中)==="
free -h | head -2
echo "available%: $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.1f", a/t*100}' /proc/meminfo)"
