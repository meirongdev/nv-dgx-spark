#!/bin/bash
# Fuller functional test for DeepSeek-V4-Flash (vLLM, deepseek-v4-flash served name).
BASE=${BASE:-http://localhost:8000}
python3 - "$BASE" <<'PY'
import sys, json, time, urllib.request
base = sys.argv[1]
payload = {"model": "deepseek-v4-flash",
           "messages": [{"role": "user", "content": "Write a Python function fib(n) that returns the nth Fibonacci number iteratively, with a one-line docstring. Then call print(fib(10))."}],
           "max_tokens": 900, "temperature": 0.2}
req = urllib.request.Request(base + "/v1/chat/completions",
                             data=json.dumps(payload).encode(),
                             headers={"Content-Type": "application/json"})
t0 = time.time()
r = json.load(urllib.request.urlopen(req, timeout=600))
dt = time.time() - t0
ch = r["choices"][0]; m = ch["message"]; u = r.get("usage", {}); ct = u.get("completion_tokens")
print("REASONING (first 240):", (m.get("reasoning_content") or "")[:240])
print("----- CONTENT -----")
print((m.get("content") or "")[:900])
print("----- -----")
print("finish_reason:", ch.get("finish_reason"))
print("usage:", u)
print("decode_tok/s=%.2f  (%s tok / %.1fs)" % ((ct/dt if ct else 0), ct, dt))
PY
