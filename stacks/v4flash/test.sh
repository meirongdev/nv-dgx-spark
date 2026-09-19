#!/bin/bash
# Fuller functional test for DeepSeek-V4-Flash (vLLM).
# ⚠️ 身份由 stackctl 从 stacks/v4flash/stack.env 注入(make test STACK=v4flash)。
#    这里**故意不给默认值** —— 一个自带旧栈 model 名的冒烟脚本,手跑时会静默地
#    去测另一个栈,而它照样打印一份看起来很正常的结果。
BASE=${BASE:?缺 BASE —— 用 make test STACK=v4flash}
MODEL=${MODEL:?缺 MODEL —— 用 make test STACK=v4flash}
python3 - "$BASE" "$MODEL" <<'PY'
import sys, json, time, urllib.request
base, model = sys.argv[1], sys.argv[2]
payload = {"model": model,
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
