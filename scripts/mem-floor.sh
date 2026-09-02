#!/bin/bash
# 找主机可用内存的**真实地板**:逐级加压并采样,安全阀 avail < 4Gi 立即中止。
# 在 S1 上跑(直连 localhost:8000)。改 gpu-memory-utilization 之前/之后都该跑。
#
# 为什么需要它:GB10 是统一内存,vLLM 按 gpu-memory-utilization **顶满**预算,
# 而主机侧占用在预算之外 —— 所以「引擎自报的账」和「宿主机还剩多少」是两回事,
# 只有实测能回答后者。2026-09-02 用它否决了 0.80:
#   空载 7Gi → 8 路并发×8K 掉到 5Gi(4.1%,低于 memwatch CRIT 5%)→ 压测后不回弹,
#   drop_caches 只拿回 52 MiB(是真占用不是页缓存)。改用 0.75。
#
# ⚠️ 它发的是真实请求,会计入 /metrics 统计;别在看接受率的时候跑。
set -u
MODEL=qwen38-flash-next
BASE=http://localhost:8000
PEER=192.168.200.102
FLOOR_ABORT=4

avail(){ free -g | awk '/^Mem:/{print $7}'; }
peer_avail(){ ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$PEER" "free -g | awk '/^Mem:/{print \$7}'" 2>/dev/null || echo "?"; }

sampler(){   # 后台采样,写最低值到文件
  local out=$1; local lo1=999 lo2=999
  while [ -f /tmp/.memfloor_run ]; do
    a=$(avail); b=$(peer_avail)
    [ "$a" -lt "$lo1" ] 2>/dev/null && lo1=$a
    [ "$b" != "?" ] && [ "$b" -lt "$lo2" ] 2>/dev/null && lo2=$b
    echo "$lo1 $lo2" > "$out"
    if [ "$a" -lt "$FLOOR_ABORT" ] 2>/dev/null || { [ "$b" != "?" ] && [ "$b" -lt "$FLOOR_ABORT" ] 2>/dev/null; }; then
      echo "ABORT" >> "$out"; rm -f /tmp/.memfloor_run
    fi
    sleep 1
  done
}

run_stage(){  # $1=描述 $2=prompt字符数 $3=并发
  local desc=$1 chars=$2 conc=$3
  [ ! -f /tmp/.memfloor_run ] && { echo "  (已中止,跳过 $desc)"; return 1; }
  echo "996 996" > /tmp/.memfloor_lo
  touch /tmp/.memfloor_run
  sampler /tmp/.memfloor_lo & spid=$!
  python3 - "$BASE" "$MODEL" "$chars" "$conc" <<'PY'
import json, sys, threading, urllib.request
base, model, chars, conc = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
filler = "The quick brown fox jumps over the lazy dog while both tensor-parallel ranks exchange partial sums. "
prompt = (filler * (chars // len(filler) + 1))[:chars]
def one(i):
    p = {"model": model, "messages": [{"role": "user", "content": f"[{i}]\n{prompt}\nReply with exactly: OK"}],
         "max_tokens": 32, "temperature": 0,
         "chat_template_kwargs": {"enable_thinking": False}}
    r = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(p).encode(),
                               headers={"Content-Type": "application/json"})
    try:
        d = json.load(urllib.request.urlopen(r, timeout=900))
        return d.get("usage", {}).get("prompt_tokens")
    except Exception as e:
        return f"ERR {type(e).__name__}"
ts = [threading.Thread(target=lambda i=i: results.append(one(i))) for i in range(conc)]
results = []
for t in ts: t.start()
for t in ts: t.join()
print("    prompt_tokens:", results[0], "| 并发", conc, "| 全部结果:", results[:3])
PY
  rm -f /tmp/.memfloor_run; wait $spid 2>/dev/null
  read lo1 lo2 rest < /tmp/.memfloor_lo
  printf "  %-28s S1 最低=%sGi  S2 最低=%sGi %s\n" "$desc" "$lo1" "$lo2" "$(grep -q ABORT /tmp/.memfloor_lo && echo '  ⚠️ 触发安全阀')"
  grep -q ABORT /tmp/.memfloor_lo && return 1
  touch /tmp/.memfloor_run
  return 0
}

echo "起始: S1 avail=$(avail)Gi  S2 avail=$(peer_avail)Gi"
echo "安全阀: 任一节点 < ${FLOOR_ABORT}Gi 立即中止"
echo
touch /tmp/.memfloor_run
run_stage "① 短 prompt × 1"        200      1
run_stage "② 8K prompt × 1"        32000    1
run_stage "③ 32K prompt × 1"       128000   1
run_stage "④ 8 路并发 × 短"         200      8
run_stage "⑤ 8 路并发 × 8K"        32000    8
run_stage "⑥ 128K prompt × 1"      512000   1
rm -f /tmp/.memfloor_run /tmp/.memfloor_lo
echo
echo "结束: S1 avail=$(avail)Gi  S2 avail=$(peer_avail)Gi"
