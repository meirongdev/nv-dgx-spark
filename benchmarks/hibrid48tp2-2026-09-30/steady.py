#!/usr/bin/env python3
"""稳态吞吐 —— 按上游 myllmbox README 的口径("120 s windows",稳态平均)对照用。

与 ladder.py 的区别(两者**不可混比**):
  ladder.py  = 每档发一批 400-token 请求,墙钟含 prefill 与最慢那条的收尾
  steady.py  = c 路请求**持续**占满(一条结束立刻补一条),等引擎里 running 数到位后,
               读服务端 /metrics 计数器在一个固定窗口内的增量 —— 不受客户端收尾影响

每档报:
  gen tok/s    = Δvllm:generation_tokens_total / Δt(整个引擎的输出 token)
  tok/step     = 1 + Δaccepted / Δdrafts(每个引擎步收下的 token,含 bonus —— 上游
                 README 的 "acceptance" 一列就是这个口径:"keeps 5.1 of a possible 6")
  running      = 窗口内采样到的 num_requests_running(确认真的有 c 路在跑)

prompt 仿上游 v4.1 的 "mixed prompt (LRU-cache code + a prose explanation of it)",
thinking off;每条请求带唯一前缀防前缀缓存。temperature 0(本仓库惯例;上游未写)。
流式请求 —— 只为了窗口结束时能**断开连接让 vLLM abort**,不用它计数。
"""
import json, os, re, sys, threading, time, urllib.request, uuid

BASE = os.environ.get("BASE") or sys.exit("missing BASE (e.g. http://100.67.164.92:18300)")
MODEL = os.environ.get("MODEL") or sys.exit("missing MODEL")
LEVELS = [int(x) for x in os.environ.get("LEVELS", "1 8 16 32 64").split()]
WINDOW = float(os.environ.get("WINDOW", "60"))
MAXTOK = int(os.environ.get("MAXTOK", "1500"))
TAG = os.environ.get("TAG", "steady")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"steady-{TAG}.json")
PROMPT = ("Write a Python LRU cache with O(1) get and put (a class with a docstring and type hints), "
          "then explain in prose, in a few paragraphs, how it works and why each operation is O(1).")

def metrics():
    txt = urllib.request.urlopen(f"{BASE}/metrics", timeout=15).read().decode()
    def g(name):
        m = re.search(rf"^{name}{{[^}}]*model_name=\"{re.escape(MODEL)}\"[^}}]*}} ([0-9.e+]+)$", txt, re.M)
        return float(m.group(1)) if m else float("nan")
    return {k: g(f"vllm:{k}") for k in ("generation_tokens_total", "spec_decode_num_accepted_tokens_total",
                                         "spec_decode_num_drafts_total", "num_requests_running",
                                         "num_requests_waiting", "kv_cache_usage_perc")}

def worker(stop):
    while not stop.is_set():
        body = {"model": MODEL, "stream": True, "temperature": 0, "max_tokens": MAXTOK,
                "messages": [{"role": "user", "content": f"[{uuid.uuid4().hex[:12]}] {PROMPT}"}],
                "chat_template_kwargs": {"enable_thinking": False}}
        req = urllib.request.Request(f"{BASE}/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                for _ in r:                 # 读到结束;stop 置位就断开 → 服务端 abort
                    if stop.is_set():
                        break
        except Exception as e:
            if not stop.is_set():
                print(f"    worker error: {e}", flush=True); time.sleep(1)

rows = []
print(f"=== {TAG}: {BASE} model={MODEL} window={WINDOW:.0f}s max_tokens={MAXTOK} levels={LEVELS} ===", flush=True)
for c in LEVELS:
    stop = threading.Event()
    ts = [threading.Thread(target=worker, args=(stop,), daemon=True) for _ in range(c)]
    for t in ts: t.start()
    t0 = time.time()
    while time.time() - t0 < 120:           # 等引擎里真的有 c 路在跑(再多等 10 s 过 prefill 潮)
        if metrics()["num_requests_running"] >= c: break
        time.sleep(1)
    time.sleep(10)
    a, ta = metrics(), time.time()
    run_s, kv_max = [], 0.0
    while time.time() - ta < WINDOW:
        time.sleep(5)
        m = metrics(); run_s.append(m["num_requests_running"]); kv_max = max(kv_max, m["kv_cache_usage_perc"])
    b, tb = metrics(), time.time()
    stop.set()
    dt = tb - ta
    gen = (b["generation_tokens_total"] - a["generation_tokens_total"]) / dt
    dd = b["spec_decode_num_drafts_total"] - a["spec_decode_num_drafts_total"]
    da = b["spec_decode_num_accepted_tokens_total"] - a["spec_decode_num_accepted_tokens_total"]
    tps = 1 + da / dd if dd else float("nan")
    row = {"c": c, "gen_tok_s": round(gen, 1), "per_stream": round(gen / c, 1), "tok_per_step": round(tps, 2),
           "running_min": min(run_s), "running_max": max(run_s), "kv_usage_max": round(kv_max, 3), "window_s": round(dt, 1)}
    rows.append(row)
    print(f"  c{c:<3} gen {gen:7.1f} tok/s   per-stream {gen/c:5.1f}   tok/step {tps:4.2f}   "
          f"running {min(run_s):.0f}-{max(run_s):.0f}   kv_max {kv_max*100:4.1f}%   ({dt:.0f}s)", flush=True)
    for t in ts: t.join(timeout=120)
    t1 = time.time()
    while time.time() - t1 < 120 and metrics()["num_requests_running"] > 0:
        time.sleep(1)
json.dump({"tag": TAG, "base": BASE, "model": MODEL, "window_s": WINDOW, "max_tokens": MAXTOK,
           "prompt": PROMPT, "when": time.strftime("%Y-%m-%d %H:%M:%S %z"), "rows": rows},
          open(OUT, "w"), ensure_ascii=False, indent=1)
print(f"→ {OUT}")
