#!/usr/bin/env python3
"""issue #55 复现 / 验收:max_tokens 在 tool call 中途截断时服务端怎么报。

背景与热修见 k8s/v4flash/configmap-launch.yaml 里 hotfix-issue55.py 上方的注释。

三个用例:
  1. streaming 截断    —— 这是我们唯一在用的路径(codex / qwen 都流式)
  2. non-streaming 截断 —— 本来就不中招,作为对照
  3. 自然结束的 tool call —— **回归检查**:热修绝不能把正常调用也改口径

⚠️ 关于「回放仍会 400」:热修只把 finish_reason 改回 "length" 并丢掉**尾包**里
   不能解析的 args。早先的 delta 已经把半截 args 发出去了 —— 所以一个**无视**
   finish_reason、闷头拼接 delta 的 harness 依然会 400。这是上游补丁的明示边界
   (patch docstring 原话),不是打漏了。热修给的是「客户端有办法知道该丢弃」,
   客户端得真的去读 finish_reason。

纯 stdlib,可从任意机器跑。
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("V4FLASH_URL", "http://100.97.87.120:8000/v1")
MODEL = os.environ.get("V4FLASH_MODEL", "deepseek-v4-flash")

TOOLS = [{
    "type": "function",
    "function": {
        "name": "write_file",
        "description": "Write text content to a file on disk.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "file path"},
                "content": {"type": "string", "description": "full file content"},
            },
            "required": ["path", "content"],
        },
    },
}]

# 长 content → arguments 一定长到能被 max_tokens 切在字符串中间
LONG = [{"role": "user", "content":
         "Use write_file to create /tmp/notes.md containing a 200-word plain-text "
         "summary of the history of the printing press. Write the whole thing."}]
# 短 content → 在预算内自然把 tool call 写完
SHORT = [{"role": "user", "content":
          "Use write_file to create /tmp/a.txt containing exactly: hi"}]


def body(msgs, max_tokens, stream):
    return {"model": MODEL, "messages": msgs, "tools": TOOLS, "tool_choice": "auto",
            "max_tokens": max_tokens, "temperature": 0, "stream": stream,
            "chat_template_kwargs": {"thinking": False}}


def post(payload, timeout=180):
    req = urllib.request.Request(BASE + "/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def json_ok(s):
    if s in (None, ""):
        return True
    try:
        json.loads(s)
        return True
    except Exception:
        return False


def stream_call(msgs, max_tokens):
    """按 harness 的做法累积 delta,返回 (finish_reason, 拼出的 args, 尾包 args 是否合法)"""
    req = urllib.request.Request(BASE + "/chat/completions",
                                 data=json.dumps(body(msgs, max_tokens, True)).encode(),
                                 headers={"Content-Type": "application/json"})
    fr, acc, tail_ok, tc_id, tc_name = None, "", True, None, None
    with urllib.request.urlopen(req, timeout=180) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            p = line[6:]
            if p == "[DONE]":
                break
            ch = json.loads(p)["choices"][0]
            for tc in ((ch.get("delta") or {}).get("tool_calls") or []):
                f = tc.get("function") or {}
                tc_id = tc.get("id") or tc_id
                tc_name = f.get("name") or tc_name
                acc += f.get("arguments") or ""
            if ch.get("finish_reason"):
                fr = ch["finish_reason"]
                # 尾包自己带的 args 是否合法(热修丢掉的就是这一份)
                for tc in ((ch.get("delta") or {}).get("tool_calls") or []):
                    tail_ok = tail_ok and json_ok((tc.get("function") or {}).get("arguments"))
    return fr, acc, tail_ok, tc_id, tc_name


def nostream_call(msgs, max_tokens):
    st, raw = post(body(msgs, max_tokens, False))
    if st != 200:
        return st, None, []
    ch = json.loads(raw)["choices"][0]
    return st, ch.get("finish_reason"), (ch["message"].get("tool_calls") or [])


def main():
    print(f"endpoint: {BASE}   model: {MODEL}\n")
    fails = []

    # ---- 1. streaming 截断 ----
    print("=" * 74)
    print("用例 1  streaming + max_tokens 截断  【主判据】")
    print("=" * 74)
    for mt in (48, 96, 192):
        fr, acc, tail_ok, tc_id, tc_name = stream_call(LONG, mt)
        acc_ok = json_ok(acc)
        verdict = "PASS" if fr == "length" else "FAIL"
        if fr != "length":
            fails.append(f"streaming max_tokens={mt}: finish_reason={fr!r},应为 'length'")
        if not tail_ok:
            fails.append(f"streaming max_tokens={mt}: 尾包仍带非法 JSON args")
        print(f"  max_tokens={mt:4d}  finish_reason={str(fr):<11s} [{verdict}]   "
              f"尾包 args 合法={tail_ok}   累积 args 合法={acc_ok}")
        if not acc_ok:
            print(f"{'':16s}累积 args 尾部: ...{acc[-60:]!r}")
    print("\n  注:『累积 args 合法=False』是预期的 —— 早先的 delta 已经发出去了。")
    print("     热修保证的是 finish_reason 变回 'length',让客户端有依据丢弃。\n")

    # ---- 2. non-streaming 截断(对照) ----
    print("=" * 74)
    print("用例 2  non-streaming + max_tokens 截断  【对照,本来就不中招】")
    print("=" * 74)
    for mt in (96, 192):
        st, fr, tcs = nostream_call(LONG, mt)
        ok = all(json_ok(t["function"].get("arguments")) for t in tcs)
        bad = fr == "tool_calls" or not ok
        if bad:
            fails.append(f"non-streaming max_tokens={mt}: finish_reason={fr!r} args_ok={ok}")
        print(f"  max_tokens={mt:4d}  HTTP {st}  finish_reason={str(fr):<11s} "
              f"tool_calls={len(tcs)}  args 合法={ok}  [{'FAIL' if bad else 'PASS'}]")
    print()

    # ---- 3. 自然结束的 tool call(回归检查) ----
    print("=" * 74)
    print("用例 3  自然结束的 tool call  【回归:热修不能碰这条】")
    print("=" * 74)
    st, fr, tcs = nostream_call(SHORT, 512)
    ok = bool(tcs) and all(json_ok(t["function"].get("arguments")) for t in tcs)
    good = (fr == "tool_calls") and ok
    if not good:
        fails.append(f"自然结束的 tool call 被改坏: finish_reason={fr!r} tool_calls={len(tcs)} args_ok={ok}")
    print(f"  [no-stream] HTTP {st}  finish_reason={str(fr):<11s} tool_calls={len(tcs)} "
          f"args 合法={ok}  [{'PASS' if good else 'FAIL'}]")
    if tcs:
        print(f"{'':14s}args: {tcs[0]['function'].get('arguments')}")

    fr2, acc2, _, _, _ = stream_call(SHORT, 512)
    good2 = fr2 == "tool_calls" and json_ok(acc2)
    if not good2:
        fails.append(f"自然结束的流式 tool call 被改坏: finish_reason={fr2!r} args_ok={json_ok(acc2)}")
    print(f"  [stream]    finish_reason={str(fr2):<11s} args 合法={json_ok(acc2)}  "
          f"[{'PASS' if good2 else 'FAIL'}]")

    print("\n" + "=" * 74)
    if fails:
        print(f"结论:未通过 —— 热修未生效或已回退({len(fails)} 项)")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("结论:全部通过 —— 截断改报 length,自然结束的 tool call 未受影响")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
