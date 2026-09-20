#!/usr/bin/env python3
"""fndgx SEQS 扫描用的并发梯子 —— benchmarks/fndgx-2026-09-20/concurrency.py 的直系版本。

⚠️ **请求形状与基线逐字相同**(TASKS / max_tokens=400 / temperature=0 /
   非流式 / enable_thinking=false / 每个并发位不同 prompt)。本仓库反复吃过
   「不同 harness 的数不能排名」的亏,所以这里只加三件事,不改任何一个请求参数:

   1. 梯子加长到 c24 / c32 / c48(基线到 c16 为止,因为 SEQS=8 时再往上没意义);
   2. **每一级都量主机内存**。本仓库在 glm53 上学过「prefill 主机内存超线性」,
      在 qwen38un 上学过「启动余量≠稳态余量」。更要紧的是 memwatch 守着本栈,
      crit=5% 会**直接把栈停掉**(no auto-restore)—— 在它动手前自己先停;
   3. 每一级采 `vllm:ple_mmap_*` 计数器差值(本轮刚打开 PROM_MULTIPROC=1)。
      页缓存只有约 13 GiB 而 PLE 表 48 GiB,缺页代价是本栈的头号嫌疑,
      而在此之前**没有任何一条指标能看到它**。
"""
import json, statistics, sys, time, urllib.request

URL = "http://localhost:18300/v1/chat/completions"
METRICS = "http://localhost:18300/metrics"
MODEL = "qwen3.8-flash-next"
ABORT_PCT = 7.0          # memwatch: warn=8% crit=5%。低于这条自己先停,别让看门狗动手。

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

# 基线:benchmarks/fndgx-2026-09-20/README.md §3(SEQS=8,解锁时钟,同一天同一套脚本)
BASELINE = {1: 44.5, 2: 67.8, 4: 92.1, 6: 93.8, 8: 112.4, 12: 111.1, 16: 113.1}


def mem():
    d = {}
    for line in open("/proc/meminfo"):
        k, _, v = line.partition(":")
        d[k] = int(v.split()[0])
    return d["MemAvailable"] / 1048576.0, 100.0 * d["MemAvailable"] / d["MemTotal"], d["Cached"] / 1048576.0


def ple():
    """所有 ple_mmap_* 计数器的当前值。PROM_MULTIPROC=0 时返回空 dict。"""
    out = {}
    try:
        with urllib.request.urlopen(METRICS, timeout=10) as r:
            for line in r.read().decode().splitlines():
                if "ple_mmap" in line and not line.startswith("#"):
                    name, _, val = line.rpartition(" ")
                    try:
                        out[name] = float(val)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"    (ple 计数器读不到: {e})")
    return out


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
    from concurrent.futures import ThreadPoolExecutor
    p0 = ple()
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=c) as ex:
        res = list(ex.map(one, range(c)))
    wall = time.time() - t0
    p1 = ple()
    toks = sum(n for n, _ in res)
    lat = [t for _, t in res]
    agg = toks / wall
    avail, pct, cached = mem()

    base = BASELINE.get(c)
    cmp_ = f"  基线 {base:6.1f} → {100*(agg/base-1):+6.1f}%" if base else "  基线 —— 新格"
    print(f"  c{c:<3}{tag} 聚合 {agg:7.1f} tok/s   每流 {agg/c:5.1f}   "
          f"出 {toks:5d} tok / {wall:5.1f}s   延迟 中位 {statistics.median(lat):5.1f}s "
          f"最慢 {max(lat):5.1f}s{cmp_}", flush=True)
    print(f"        主机 available {avail:5.1f} GiB ({pct:4.1f}%)  Cached {cached:5.1f} GiB", flush=True)

    delta = {k: p1[k] - p0.get(k, 0.0) for k in p1 if p1[k] - p0.get(k, 0.0) > 0}
    if delta:
        for k in sorted(delta):
            short = k.split("{")[0].replace("vllm:ple_mmap_", "")
            print(f"        ple {short:<28} +{delta[k]:,.3f}", flush=True)
    return agg, pct


if __name__ == "__main__":
    rungs = [int(x) for x in sys.argv[1:]] or [1, 2, 4, 6, 8, 12, 16, 24, 32, 48]
    a0, p0, c0 = mem()
    print(f"=== 起点:主机 available {a0:.1f} GiB ({p0:.1f}%)  Cached {c0:.1f} GiB ===", flush=True)
    print(f"=== 计数器:{'ple_mmap_* 已导出' if ple() else '⚠️ ple_mmap_* 没导出(PROM_MULTIPROC 没生效?)'} ===", flush=True)
    print("=== 热身(不计入)===", flush=True)
    run(2, " 热身")

    print("\n=== fndgx 并发梯子(SEQS=32,262144 native,解锁时钟)===", flush=True)
    best = (0, 0.0)
    for c in rungs:
        agg, pct = run(c)
        if agg > best[1]:
            best = (c, agg)
        if pct < ABORT_PCT:
            print(f"\n⛔ 主机可用内存 {pct:.1f}% < {ABORT_PCT}% —— 自己停在这里,"
                  f"不等 memwatch(crit=5%)动手。已完成到 c{c}。", flush=True)
            break
        time.sleep(3)
    print(f"\n峰值: c{best[0]} = {best[1]:.1f} tok/s 聚合"
          f"(基线峰值 c16 = 113.1)", flush=True)
