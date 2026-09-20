#!/usr/bin/env bash
# 按上游 README 的口径重测 prefill:8k 和 32k 两个点。
# 每个尺寸发 4 条**内容各不相同**的 prompt(前缀缓存因此永远打不中),
# 第 1 条算热身丢掉,后 3 条取中位。max_tokens=1,所以耗时≈prefill。
U=http://localhost:18300/v1/chat/completions
M=qwen3.8-flash-next
measure(){ # $1=目标 token 数
  local target="$1" rates=""
  for i in 1 2 3 4; do
    python3 - "$M" "$target" "$i" > /tmp/.pf.json <<'PY'
import json, random, sys
m, target, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
random.seed(seed * 7919)
# 随机词流:每次内容都不同 => 前缀缓存打不中;约 0.75 token/词,多给一点再截断
words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota","kappa",
         "lambda","mu","nu","xi","omicron","pi","rho","sigma","tau","upsilon",
         "quantum","tensor","gradient","kernel","buffer","socket","pointer","cache",
         "shard","replica","latency","throughput","entropy","manifold","lattice"]
text = " ".join(random.choice(words) for _ in range(int(target * 1.45)))
print(json.dumps({"model": m, "messages": [{"role":"user","content": text + "\n\nReply with the single word OK."}],
                  "max_tokens": 1, "temperature": 0,
                  "chat_template_kwargs": {"enable_thinking": False}}))
PY
    local t0 t1 n r
    t0=$(python3 -c 'import time;print(time.time())')
    curl -s -m 600 -o /tmp/.pr.json -H 'Content-Type: application/json' -d @/tmp/.pf.json "$U"
    t1=$(python3 -c 'import time;print(time.time())')
    n=$(python3 -c 'import json;print(json.load(open("/tmp/.pr.json"))["usage"]["prompt_tokens"])' 2>/dev/null || echo 0)
    r=$(python3 -c "print(f'{$n/($t1-$t0):.0f}')")
    if [ "$i" = 1 ]; then printf '  %6s 热身  prompt=%6s tok  %6s tok/s\n' "$target" "$n" "$r"
    else printf '  %6s 第%d次 prompt=%6s tok  %6s tok/s\n' "$target" "$i" "$n" "$r"; rates="$rates $r"; fi
  done
  printf '  %6s ==> 热后中位 %s tok/s\n\n' "$target" \
    "$(python3 -c "v=sorted(float(x) for x in '$rates'.split()); print(f'{v[len(v)//2]:.0f}')")"
}
echo "=== prefill(每次内容都不同,前缀缓存打不中;max_tokens=1)==="
measure 8000
measure 32000
rm -f /tmp/.pf.json /tmp/.pr.json
echo "=== GPU 时钟(负载下应当被 2200 MHz 上限压住)==="
nvidia-smi --query-gpu=clocks.current.sm,clocks.max.sm --format=csv,noheader
