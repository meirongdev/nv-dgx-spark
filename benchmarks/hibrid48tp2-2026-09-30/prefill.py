#!/usr/bin/env python3
"""冷 prefill(TTFT 法)—— 对照上游 README 的 "cold time to first token" 表。

每个尺寸发两次,每次最前面插不同的 uuid(前缀缓存一个 token 都命中不了;回包里的
cached_tokens 也记下来核对)。第一次是"该形状首发",第二次是"同形状暖" ——
docs/benchmarking-cn.md:首发新形状会慢 ~43%,必须说明引用的是哪一个。
max_tokens=1 + 非流式,于是总延迟 ≈ TTFT;prefill tok/s = prompt_tokens / 延迟。
同时每 3 s 采两台 MemAvailable(长 prefill 的主机内存在别的栈上是超线性的)。

⚠️ **要在 head 上打 localhost 跑**(NODES="local 192.168.200.101")。2026-09-30 第一次从 Mac
经 Tailscale 打,prompt 上传走 DERP(当天实测 ~40 KB/s),67K token ≈ 230 KB 光上传就几秒,
TTFT 被整段高估 —— 与 09-03 / 09-19 基准"在节点上打 localhost"同一条教训。
"""
import json, os, subprocess, sys, threading, time, urllib.request, uuid

BASE = os.environ.get("BASE") or sys.exit("missing BASE")
MODEL = os.environ.get("MODEL") or sys.exit("missing MODEL")
SIZES = [int(x) for x in os.environ.get("SIZES", "8000 32000 128000").split()]
NODES = os.environ.get("NODES", "100.67.164.92 100.97.87.120").split()
TAG = os.environ.get("TAG", "prefill")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"prefill-{TAG}.json")

# 一段不重复的"文档":编号句子,内容各不相同,避免分词器把整段压成极少 token
def doc(n_tokens):
    parts, i = [], 0
    while len(parts) * 26 < n_tokens:      # 实测每句 ~26 token(2026-09-30 回包 prompt_tokens;13 是错估)
        parts.append(f"Record {i}: sensor {i*7%101} reported value {(i*37)%997} at step {i*3}, status {'ok' if i%5 else 'warn'}.")
        i += 1
    return " ".join(parts)

mem_min = {n: 1e9 for n in NODES}; stop = threading.Event()
def poll():
    while not stop.is_set():
        for n in NODES:
            try:
                if n == "local":
                    kb = int(next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemAvailable")))
                else:
                    key = os.path.expanduser("~/.ssh/vgio")
                    o = subprocess.run(["ssh"] + (["-i", key] if os.path.exists(key) else []) +
                                       ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                                        f"admin@{n}", "awk '/MemAvailable/{print $2}' /proc/meminfo"],
                                       capture_output=True, text=True, timeout=10)
                    kb = int(o.stdout.strip())
                mem_min[n] = min(mem_min[n], kb / 1048576)
            except Exception:
                pass
        time.sleep(3)

threading.Thread(target=poll, daemon=True).start()
rows = []
print(f"=== {TAG}: {BASE} model={MODEL} sizes={SIZES} ===", flush=True)
for n in SIZES:
    body_text = doc(n)
    for attempt in ("首发", "暖"):
        prompt = f"[{uuid.uuid4().hex}] Here is a log.\n{body_text}\nHow many records have status warn? Reply with one number."
        body = {"model": MODEL, "max_tokens": 1, "temperature": 0, "stream": False,
                "messages": [{"role": "user", "content": prompt}],
                "chat_template_kwargs": {"enable_thinking": False}}
        req = urllib.request.Request(f"{BASE}/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=1800) as r:
            d = json.loads(r.read())
        dt = time.time() - t0
        u = d["usage"]; pt = u["prompt_tokens"]
        cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        row = {"target": n, "attempt": attempt, "prompt_tokens": pt, "cached_tokens": cached,
               "ttft_s": round(dt, 2), "prefill_tok_s": round(pt / dt, 0)}
        rows.append(row)
        print(f"  ~{n//1000:>3}K {attempt}: {pt:7d} tok  TTFT {dt:6.2f}s  prefill {pt/dt:6.0f} tok/s  cached {cached}", flush=True)
stop.set(); time.sleep(1)
print("  MemAvailable 最低: " + "  ".join(f"{n} {v:.2f} GiB" for n, v in mem_min.items()))
json.dump({"tag": TAG, "rows": rows, "mem_min_gib": mem_min, "when": time.strftime("%Y-%m-%d %H:%M:%S %z")},
          open(OUT, "w"), ensure_ascii=False, indent=1)
print(f"→ {OUT}")
