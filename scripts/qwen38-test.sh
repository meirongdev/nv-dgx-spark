#!/bin/bash
# Benchmark harness mirroring scripts/v4-test.sh methodology:
# stream:false + usage.completion_tokens over wall time (never count SSE deltas
# under spec decode -- that measures steps/s, not tok/s).
BASE=${BASE:-http://localhost:8888}
MODEL=${MODEL:-qwen38-27b}
python3 - "$BASE" "$MODEL" <<'PY'
import sys, json, time, urllib.request
base, model = sys.argv[1], sys.argv[2]

PROMPTS = [
 ("coding-fib", "Write a Python function fib(n) that returns the nth Fibonacci number iteratively, with a one-line docstring. Then call print(fib(10))."),
 ("coding-real", "Write a Python class LRUCache with get(key) and put(key,value) in O(1), using a dict plus a doubly linked list. Include the node class, full method bodies, and a short docstring on each method. No explanation outside code."),
 ("count-300", "Count from 1 to 300, separated by spaces. Output only the numbers."),
 ("prose", "Explain in about 400 words why speculative decoding speeds up LLM inference, and what limits its speedup."),
]

def run(name, prompt, think, max_tok=1400):
    payload = {"model": model,
               "messages": [{"role":"user","content":prompt}],
               "max_tokens": max_tok, "temperature": 0.2,
               "chat_template_kwargs": {"enable_thinking": think}}
    req = urllib.request.Request(base+"/v1/chat/completions",
          data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
    t0=time.time()
    try:
        r=json.load(urllib.request.urlopen(req, timeout=900))
    except Exception as e:
        print("  %-12s ERROR %s" % (name, str(e)[:120])); return None
    dt=time.time()-t0
    u=r.get("usage",{}); ct=u.get("completion_tokens") or 0
    pt=u.get("prompt_tokens") or 0
    msg=r["choices"][0]["message"]
    return {"name":name,"tok_s":ct/dt if dt else 0,"ct":ct,"pt":pt,"dt":dt,
            "content":(msg.get("content") or ""), "reasoning":(msg.get("reasoning_content") or ""),
            "finish":r["choices"][0].get("finish_reason")}

print("=== WARM-UP (discarding: first request pays JIT + cold-start) ===")
for i in range(3):
    w=run("warmup%d"%i, "Write a Python function to reverse a linked list.", False, 500)
    if w: print("  warmup%d: %.1f tok/s (%d tok)" % (i, w["tok_s"], w["ct"]))

print("\n=== MEASURED (thinking OFF) ===")
res=[]
for n,p in PROMPTS:
    r=run(n,p,False)
    if r:
        res.append(r)
        print("  %-12s %6.1f tok/s   %4d tok / %5.1fs  prompt=%d  finish=%s" % (n,r["tok_s"],r["ct"],r["dt"],r["pt"],r["finish"]))

if res:
    ts=[r["tok_s"] for r in res]
    print("\n  decode range: %.1f - %.1f tok/s   mean %.1f" % (min(ts),max(ts),sum(ts)/len(ts)))

print("\n=== SAMPLE OUTPUT (coding-real, thinking OFF) ===")
for r in res:
    if r["name"]=="coding-real":
        print(r["content"][:1500])

print("\n=== thinking ON, one coding prompt ===")
r=run("think-on", PROMPTS[1][1], True)
if r:
    print("  %.1f tok/s  %d tok / %.1fs  finish=%s" % (r["tok_s"],r["ct"],r["dt"],r["finish"]))
    print("  reasoning chars:", len(r["reasoning"]))

print("\n=== spec-decode acceptance (from /metrics) ===")
try:
    m=urllib.request.urlopen(base.replace("/v1","")+"/metrics", timeout=30).read().decode()
    for line in m.splitlines():
        if "spec_decode" in line and not line.startswith("#"):
            print("  "+line[:160])
except Exception as e:
    print("  metrics err:", str(e)[:100])
PY
