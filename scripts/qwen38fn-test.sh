#!/bin/bash
# Qwen3.8-Flash-Next 冒烟测试(不是 benchmark —— 只有一个短 prompt,
# 引用 tok/s 之前先读 docs/benchmarking-cn.md)。
#
# 除了 v4-test.sh 那套「能出词 + 单流 tok/s」之外,多做一件切换期专属的事:
# **验证 tool-call parser 选对了没有**。官方 recipe 写 qwen3_xml,x00byte 用
# qwen3_coder,取决于 checkpoint 里的 chat template。选错的表现不是报错,而是
# 工具调用**以纯文本形式**出现在 content 里、tool_calls 为空 —— 客户端那边
# 看起来就是"模型不会用工具了"。
BASE=${BASE:-http://localhost:8000}
MODEL=${MODEL:-qwen38-flash-next}

python3 - "$BASE" "$MODEL" <<'PY'
import sys, json, time, urllib.request

base, model = sys.argv[1], sys.argv[2]

def post(payload, timeout=600):
    req = urllib.request.Request(base + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=timeout))
    return r, time.time() - t0

# ---- 1. 生成 + 单流 decode 速率 -------------------------------------------
print("=" * 60)
print("1. 生成冒烟 + 单流 decode")
print("=" * 60)
r, dt = post({
    "model": model,
    "messages": [{"role": "user", "content":
                  "Write a Python function fib(n) that returns the nth Fibonacci "
                  "number iteratively, with a one-line docstring. Then call print(fib(10))."}],
    "max_tokens": 900, "temperature": 0.2,
})
ch = r["choices"][0]; m = ch["message"]; u = r.get("usage", {})
ct = u.get("completion_tokens")
reasoning = m.get("reasoning_content") or ""
print("REASONING (first 240):", reasoning[:240])
print("----- CONTENT -----")
print((m.get("content") or "")[:900])
print("----- -----")
print("finish_reason:", ch.get("finish_reason"))
print("usage:", u)
print("decode_tok/s=%.2f  (%s tok / %.1fs)" % ((ct / dt if ct else 0), ct, dt))
if reasoning:
    # 有报告称该模型输出里 86% 是 thinking token。这里给一个粗略占比,便于判断
    # 是否要在客户端侧关掉:{"chat_template_kwargs":{"enable_thinking":false}}
    print("note: reasoning_content 长度 %d 字符,content 长度 %d 字符"
          % (len(reasoning), len(m.get("content") or "")))

# ---- 2. tool-call parser 验证 ---------------------------------------------
print()
print("=" * 60)
print("2. tool-call parser 验证 (qwen3_xml ?)")
print("=" * 60)
r2, _ = post({
    "model": model,
    "messages": [{"role": "user", "content": "What's the weather in Hangzhou right now? Use the tool."}],
    "tools": [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city.",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string", "description": "City name"}},
                "required": ["city"],
            },
        },
    }],
    "tool_choice": "auto",
    "max_tokens": 400, "temperature": 0.2,
}, timeout=300)

ch2 = r2["choices"][0]; m2 = ch2["message"]
calls = m2.get("tool_calls") or []
print("finish_reason:", ch2.get("finish_reason"))
print("tool_calls:", json.dumps(calls, ensure_ascii=False)[:600])
if calls:
    args = calls[0].get("function", {}).get("arguments")
    try:
        json.loads(args)
        print("PASS: parser 正确,arguments 是合法 JSON")
    except Exception as e:
        print("FAIL: arguments 不是合法 JSON (%s) — 检查是否被截断" % e)
else:
    print("content:", (m2.get("content") or "")[:400])
    print("FAIL: tool_calls 为空。若上面的 content 里能看到工具调用的原文,")
    print("      说明 parser 选错了 —— 把 --tool-call-parser 从 qwen3_xml 改成")
    print("      qwen3_coder(config/qwen38-flash-next.yaml 与 ConfigMap 成对改)。")
PY
