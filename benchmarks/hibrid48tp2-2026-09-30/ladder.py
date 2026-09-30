#!/usr/bin/env python3
"""并发梯子 —— benchmarks/hibrid48-2026-09-28-concurrency/concurrency.py 的参数化副本。

请求体、8 道题、[req i] 前缀、热身、aggregate 的定义与 09-28 那份**逐字相同**,
所以三个栈(hibrid48 / qwen38un / hibrid48tp2)的数可以直接放在一张表里比。
只改了三处:目标从环境变量读(不写死栈身份,见 stacks/README.md 规则 1)、
档位可配、每档额外记 reasoning tokens(确认 thinking 真关了)并落一份 JSON。

遵守 docs/benchmarking-cn.md:
   - 非流式(流式数的是 steps/s)
   - 先热身(冷+闲置衰减约 30%)
   - 回答够长(短回答被开销压顶):max_tokens=400
   - 每个并发位用**不同**的 prompt,避免前缀缓存把活干没了
   aggregate = 该轮所有请求的 completion_tokens 之和 / 该轮墙钟(含 prefill 与收尾)

用法:
  URL=http://100.67.164.92:18300/v1/chat/completions MODEL=qwen3.8-flash-next-tp2 \
  THINK_OFF='{"chat_template_kwargs":{"enable_thinking":false}}' \
  LEVELS="1 2 4 6 8 12 16 20 24 32 48 64" TAG=hibrid48tp2 python3 ladder.py
"""
import json, os, statistics, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = os.environ.get("URL") or sys.exit("missing URL")
MODEL = os.environ.get("MODEL") or sys.exit("missing MODEL")
THINK_OFF = json.loads(os.environ.get("THINK_OFF") or sys.exit("missing THINK_OFF"))
LEVELS = [int(x) for x in os.environ.get("LEVELS", "1 2 4 6 8 12 16 20 24").split()]
TAG = os.environ.get("TAG", "run")
OUT = os.environ.get("OUT", os.path.join(os.path.dirname(os.path.abspath(__file__)), f"ladder-{TAG}.json"))
TASKS = [
    "Write a Python LRU cache with O(1) get and put. Code only.",
    "Write a Python function that merges k sorted linked lists. Code only.",
    "Write a Go function that does a topological sort with cycle detection. Code only.",
    "Explain in prose why two-phase commit blocks on coordinator failure.",
    "Write a Rust function implementing binary search on a sorted slice. Code only.",
    "Write a SQL query finding the second highest salary per department. Explain briefly.",
    "Write a Python class implementing a fixed-size ring buffer. Code only.",
    "Explain in prose how a bloom filter trades memory for false positives.",
]

def one(i):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": f"[req {i}] " + TASKS[i % len(TASKS)]}],
        "max_tokens": 400, "temperature": 0, "stream": False,
    }
    body.update(THINK_OFF)
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    if d.get("model") != MODEL:   # vLLM 回显自己的 served 名;对不上就是测错了栈
        raise SystemExit(f"response model {d.get('model')!r} != {MODEL!r}")
    u = d["usage"]
    rt = (u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
    return u["completion_tokens"], rt, time.time() - t0

def run(c, tag=""):
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=c) as ex:
        res = list(ex.map(one, range(c)))
    wall = time.time() - t0
    toks = sum(n for n, _, _ in res)
    rtok = sum(r for _, r, _ in res)
    lat = [t for _, _, t in res]
    agg = toks / wall
    print(f"  c{c:<3}{tag} 聚合 {agg:7.1f} tok/s   每流 {agg/c:5.1f}   "
          f"出 {toks:5d} tok / {wall:5.1f}s   单请求延迟 中位 {statistics.median(lat):5.1f}s "
          f"最慢 {max(lat):5.1f}s   reasoning {rtok}", flush=True)
    return {"c": c, "agg": round(agg, 1), "per_stream": round(agg / c, 1), "tokens": toks,
            "reasoning_tokens": rtok, "wall_s": round(wall, 2),
            "lat_median_s": round(statistics.median(lat), 2), "lat_max_s": round(max(lat), 2)}

print(f"=== {TAG}: {URL}  model={MODEL}  think_off={json.dumps(THINK_OFF)} ===", flush=True)
print("=== 热身(不计入)===", flush=True)
run(2, " 热身")
print(f"\n=== 并发梯子 {LEVELS} ===", flush=True)
rows = []
for c in LEVELS:
    rows.append(run(c))
    time.sleep(3)
best = max(rows, key=lambda r: r["agg"])
print(f"\n峰值: c{best['c']} = {best['agg']:.1f} tok/s 聚合")
json.dump({"tag": TAG, "url": URL, "model": MODEL, "think_off": THINK_OFF,
           "when": time.strftime("%Y-%m-%d %H:%M:%S %z"), "rows": rows},
          open(OUT, "w"), ensure_ascii=False, indent=1)
print(f"→ {OUT}")
