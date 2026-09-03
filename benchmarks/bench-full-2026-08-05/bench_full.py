#!/usr/bin/env python3
"""Full DS4 characterization: peak decode, concurrency scaling, prefill.

Three axes, because single-stream decode alone doesn't describe a serving box:
  1. peak/mean decode by content type (acceptance-driven)
  2. concurrency scaling c1..c6 (aggregate + per-stream)
  3. prefill throughput at depth (TTFT for big prompts)

Env: URL, MODEL, TAG
"""
import json
import os
import threading
import time
import urllib.request
import uuid

URL = os.environ.get("URL", "http://192.168.192.2:8889")
MODEL = os.environ.get("MODEL", "deepseek-v4-flash-dspark")
TAG = os.environ.get("TAG", "current")
THINKING = os.environ.get("THINKING", "0") == "1"
# ⚠️ 关闭 thinking 的 kwarg 名**逐栈不同**,照抄会静默失效(整段 CoT 照常生成,
# 于是测到的是"带思考"的 tok/s,和基线不可比):
#     DeepSeek-V4-Flash → "thinking"          (默认,保持 2026-08-05 基线不变)
#     Qwen3.8-*         → "enable_thinking"
# 2026-09-02 加此开关,以便用同一份 harness 跨栈做 content-matched 对照。
THINK_KEY = os.environ.get("THINK_KEY", "thinking")
# 并发档位。默认 1,2,4,6 = 2026-08-05 基线的档位,保持可复现;
# 引擎上限变了就用它扩(Flash-Next 的 max_num_seqs=8,峰值在 c8,c6 测不到)。
CONC_LEVELS = tuple(int(x) for x in os.environ.get("CONC_LEVELS", "1,2,4,6").split(","))


REQ_SENT = 0  # 本 harness 自己发出的请求数,用于事后检出外部流量


def engine_counters():
    """(running, waiting, finished_total) —— 取不到返回 (None, None, None)。

    finished_total 用来事后核对:引擎完成的请求数若多于本 harness 发出的,
    说明测量期间有别的客户端在用同一个引擎,这一轮数字全部作废。
    """
    try:
        base = URL.rsplit("/v1", 1)[0]
        txt = urllib.request.urlopen(base + "/metrics", timeout=10).read().decode()
    except Exception:
        return None, None, None
    run = wait = None
    fin = 0.0
    for line in txt.splitlines():
        if line.startswith("vllm:num_requests_running"):
            run = float(line.rsplit(" ", 1)[1])
        elif line.startswith("vllm:num_requests_waiting{"):
            wait = float(line.rsplit(" ", 1)[1])
        elif line.startswith("vllm:request_success_total"):
            fin += float(line.rsplit(" ", 1)[1])
    return run, wait, fin


def post(prompt, max_tokens, temp=0.0, timeout=600):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "temperature": temp,
            "chat_template_kwargs": {THINK_KEY: THINKING}}
    req = urllib.request.Request(URL + "/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    global REQ_SENT
    REQ_SENT += 1
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=timeout))
    dt = time.time() - t0
    u = r["usage"]
    return u["completion_tokens"], u.get("prompt_tokens", 0), dt


def prefix_cache_counters():
    """从 /metrics 读 (queries, hits) 累计计数;取不到返回 (None, None)。

    用途:prefill 那一格必须自证"没吃到缓存"。引擎空闲时,一次调用前后的差值
    就是这一条请求的命中情况。
    """
    try:
        base = URL.rsplit("/v1", 1)[0]
        txt = urllib.request.urlopen(base + "/metrics", timeout=10).read().decode()
    except Exception:
        return None, None
    q = h = None
    for line in txt.splitlines():
        if line.startswith("vllm:prefix_cache_queries_total"):
            q = float(line.rsplit(" ", 1)[1])
        elif line.startswith("vllm:prefix_cache_hits_total"):
            h = float(line.rsplit(" ", 1)[1])
    return q, h


PEAK = [
    ("count300", "Print the numbers 1 to 300, one per line, exact format N. No commentary.", 1200),
    ("mult12",   "Print the full 12x12 multiplication table, one line per pair, format A x B = C. No commentary.", 900),
    ("json60",   'Output a JSON array of 60 objects, each exactly {"id":N,"name":"user_N","active":true}. JSON only.', 800),
    ("bst",      "Implement a binary search tree in Python with insert, search, delete, in-order traversal, "
                 "docstrings and usage examples. Code only.", 600),
    ("story",    "Write a 200-word story about an engineer debugging a distributed system at 3am.", 400),
]

CONC_PROMPT = ("Implement a binary search tree in Python with insert, search, delete and in-order "
               "traversal. Include docstrings and two usage examples. Code only.")


# Heavy warm-up is MANDATORY on a freshly booted engine, not politeness.
# Measured 2026-07-29: immediately after "Application startup complete" (graphs already
# captured), count300 ran at 58.5 tok/s; after ~5 long generations it settled at 83.3.
# A 30% penalty, invisible in the boot log. Short 100-token calls do NOT clear it --
# it takes several hundred-token generations. Benchmark cold and you measure the cold path.
WARMUP = [
    ("Implement a binary search tree in Python with insert, search, delete and in-order "
     "traversal. Include docstrings and two usage examples.", 700),
    ("Write a 300-word explanation of how speculative decoding works.", 600),
    ("Compute the running sum of the first 40 prime numbers, showing each step.", 600),
    ('Output a JSON array of 40 objects, each {"id":N,"name":"user_N"}. JSON only.', 600),
    ("Explain tensor parallelism versus pipeline parallelism in detail.", 600),
]


def warm(short=4):
    """Drive the engine to steady state: long generations first, then short calls."""
    for prompt, mt in WARMUP:
        try:
            post(prompt, mt)
        except Exception:
            pass
    for _ in range(short):
        try:
            post("Write a python function that adds two numbers. Code only.", 100)
        except Exception:
            pass


def bench_peak():
    print(f"\n--- [{TAG}] DECODE by content (temp 0, warm) ---")
    print(f"{'prompt':<10}{'tok':>6}{'sec':>7}{'tok/s':>9}")
    vals = []
    for label, p, mt in PEAK:
        try:
            a = post(p, mt); b = post(p, mt)
            ct, _, dt = a if a[0]/a[2] > b[0]/b[2] else b
            tps = ct / dt
            vals.append((label, tps))
            print(f"{label:<10}{ct:>6}{dt:>7.2f}{tps:>9.1f}", flush=True)
        except Exception as e:
            print(f"{label:<10}  FAILED {str(e)[:40]}")
    if vals:
        v = [x[1] for x in vals]
        top = max(vals, key=lambda x: x[1])
        print(f"  PEAK {top[1]:.1f} ({top[0]})   MEAN {sum(v)/len(v):.1f}")
        return top[1], sum(v)/len(v)
    return 0, 0


def bench_conc():
    print(f"\n--- [{TAG}] CONCURRENCY (same prompt, 400 tok each) ---")
    print(f"{'conc':>5}{'ok':>5}{'agg tok/s':>12}{'per-stream':>12}{'wall':>8}")
    out = {}
    for c in CONC_LEVELS:
        results = []
        lock = threading.Lock()

        def worker():
            try:
                ct, _, dt = post(CONC_PROMPT, 400)
                with lock:
                    results.append((ct, dt))
            except Exception:
                pass

        ts = [threading.Thread(target=worker) for _ in range(c)]
        t0 = time.time()
        for t in ts: t.start()
        for t in ts: t.join()
        wall = time.time() - t0
        if results:
            tot = sum(r[0] for r in results)
            agg = tot / wall
            per = sum(r[0] / r[1] for r in results) / len(results)
            out[c] = agg
            print(f"{c:>5}{len(results):>5}{agg:>12.1f}{per:>12.1f}{wall:>8.2f}", flush=True)
        else:
            print(f"{c:>5}    0        FAILED")
    return out


def bench_prefill():
    """Prefill 吞吐。⚠️ 每条 prompt 前置一个 UUID —— 这是承重的,不是装饰。

    2026-09-03 发现并修复:本函数原先对三个 target 复用同一段 filler,于是
      - 同一次运行内:32K 的前缀**就是** 8K 的内容、100K 的前缀就是 32K 的
        → 后两格级联命中缓存;
      - 跨运行:整条 prompt 逐字相同 → 全中。
    引擎开着 --enable-prefix-caching,所以测到的是缓存查表速度,不是 prefill。
    实测(同一台、同一时刻、封顶 2200):
        100K 同一 prompt  63807 tok/s   ← 旧写法测的是这个
        100K 唯一前缀      2990 tok/s   ← 真实 prefill
    21 倍。**2026-09-03 之前所有 prefill 数字都是高报的,不可与本函数的输出比较。**

    每格额外采样 prefix cache 命中率并打印;超过 10% 就大声报警 —— 一个不能
    自证"没吃到缓存"的 prefill 测量,和没测一样。
    """
    print(f"\n--- [{TAG}] PREFILL (TTFT method, 1 output token, unique prefix) ---")
    print(f"{'target':>8}{'prompt tok':>12}{'sec':>8}{'tok/s':>10}{'cache hit':>11}")
    filler = ("Distributed inference on GB10 schedules prefill and decode in the same step; "
              "long prompts dominate the step budget and delay in-flight decodes. ")
    res = {}
    for target in (8000, 32000, 100000):
        try:
            n = max(1, int(target / 22))
            # UUID 必须在最前面:vLLM 的 block hash 是链式的,首块一变,后面全 miss。
            prompt = (f"[run {uuid.uuid4()}] " + (filler * n)[:target * 4]
                      + "\nSummarize in one sentence.")
            q0, h0 = prefix_cache_counters()
            ct, pt, dt = post(prompt, 1, timeout=900)
            q1, h1 = prefix_cache_counters()
            res[target] = pt / dt
            if q0 is not None and q1 is not None and q1 > q0:
                hit = (h1 - h0) / (q1 - q0)
                hit_s = f"{hit:>10.1%}"
            else:
                hit, hit_s = None, f"{'n/a':>11}"
            print(f"{target:>8}{pt:>12}{dt:>8.1f}{pt/dt:>10.0f}{hit_s}", flush=True)
            if hit is not None and hit > 0.10:
                print(f"    !! cache hit {hit:.1%} —— 这一格测的不是 prefill,数字作废。"
                      f" 引擎里已有相同前缀,换个 prompt 或重启引擎再测。", flush=True)
        except Exception as e:
            print(f"{target:>8}   FAILED {str(e)[:40]}")
    return res


if __name__ == "__main__":
    print(f"=== {TAG} @ {URL} ===")

    # ⚠️ 引擎必须独占。2026-09-03 有一轮基线被一个后台客户端(持续 1 路生成)
    # 整体拉低 15-25%:decode 56.2→49.2、c8 287→210、prefill 也降。现象和
    # "这台机器就是慢" 完全一样,不查 metrics 根本看不出来。
    run0, wait0, fin0 = engine_counters()
    if run0 is None:
        print("⚠️ 读不到 /metrics —— 无法确认引擎独占,结果可能被外部流量污染。")
    elif run0 > 0 or (wait0 or 0) > 0:
        print(f"❌ 引擎不空闲(running={run0:.0f} waiting={wait0:.0f})—— 有别的客户端在用。")
        print("   现在测出来的数字会被静默拉低。等它空闲,或 make qwen38fn-load 看是谁。")
        raise SystemExit(3)

    warm()
    pk, mn = bench_peak()
    cc = bench_conc()
    pf = bench_prefill()
    print(f"\n===== SUMMARY [{TAG}] =====")
    _, _, fin1 = engine_counters()
    if fin0 is not None and fin1 is not None:
        foreign = (fin1 - fin0) - REQ_SENT
        if foreign > 0:
            print(f"❌ 测量期间引擎多完成了 {foreign:.0f} 条本 harness 之外的请求"
                  f"(引擎 {fin1 - fin0:.0f} vs 本 harness {REQ_SENT})。")
            print("   有别的客户端在抢同一个引擎 —— **本轮全部数字作废,重测。**")
        else:
            print(f"engine exclusivity OK ({REQ_SENT} reqs, no foreign traffic)")
    print(f"decode peak {pk:.1f} | mean {mn:.1f}")
    if cc:
        print("concurrency agg: " + "  ".join(f"c{k}={v:.0f}" for k, v in cc.items()))
    if pf:
        print("prefill: " + "  ".join(f"{k//1000}K={v:.0f}t/s" for k, v in pf.items()))
