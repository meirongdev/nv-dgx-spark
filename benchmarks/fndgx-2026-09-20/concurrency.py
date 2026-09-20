#!/usr/bin/env python3
"""fndgx 并发梯子。遵守 docs/benchmarking-cn.md:
   - 非流式(流式数的是 steps/s)
   - 先热身(冷+闲置衰减约 30%)
   - 回答够长(短回答被开销压顶):max_tokens=400
   - 每个并发位用**不同**的 prompt,避免前缀缓存把活干没了
   aggregate = 该轮所有请求的 completion_tokens 之和 / 该轮墙钟
"""
import json, statistics, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = "http://localhost:18300/v1/chat/completions"
MODEL = "qwen3.8-flash-next"
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
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": f"[req {i}] " + TASKS[i % len(TASKS)]}],
        "max_tokens": 400, "temperature": 0, "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    return d["usage"]["completion_tokens"], time.time() - t0

def run(c, tag=""):
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=c) as ex:
        res = list(ex.map(one, range(c)))
    wall = time.time() - t0
    toks = sum(n for n, _ in res)
    lat = [t for _, t in res]
    agg = toks / wall
    print(f"  c{c:<3}{tag} 聚合 {agg:7.1f} tok/s   每流 {agg/c:5.1f}   "
          f"出 {toks:5d} tok / {wall:5.1f}s   单请求延迟 中位 {statistics.median(lat):5.1f}s "
          f"最慢 {max(lat):5.1f}s", flush=True)
    return agg

print("=== 热身(不计入)===", flush=True)
run(2, " 热身")
print("\n=== fndgx 并发梯子(SEQS=8,262144 native)===", flush=True)
best = (0, 0)
for c in (1, 2, 4, 6, 8, 12, 16):
    a = run(c)
    if a > best[1]:
        best = (c, a)
    time.sleep(3)
print(f"\n峰值: c{best[0]} = {best[1]:.1f} tok/s 聚合")
