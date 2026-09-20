#!/usr/bin/env bash
U=http://localhost:18300/v1/chat/completions
M=qwen3.8-flash-next
probe(){
  local label="$1" body="$2"
  local code
  code=$(curl -s -m 240 -o /tmp/.pt.json -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" "$U")
  LABEL="$label" CODE="$code" python3 - <<'PY'
import json, os
label, code = os.environ["LABEL"], os.environ["CODE"]
raw = open("/tmp/.pt.json").read()
try: d = json.loads(raw)
except Exception:
    print(f"{label:36s} HTTP {code}  <非 JSON> {raw[:100]}"); raise SystemExit
if code != "200":
    print(f"{label:36s} HTTP {code}  ERR {str(d.get('error') or d)[:120]}"); raise SystemExit
m = d["choices"][0]["message"]
rc, rs = m.get("reasoning_content"), m.get("reasoning")
ct = m.get("content") or ""
tok = d.get("usage", {}).get("completion_tokens", "?")
print(f"{label:36s} HTTP 200  reasoning_content={len(rc) if rc else 0:5d}字  "
      f"reasoning={len(rs) if rs else 0:4d}字  content={len(ct):4d}字  出token={tok}")
PY
}
Q='"messages":[{"role":"user","content":"9.11 and 9.9 which is larger? Answer with the number only."}],"max_tokens":800,"temperature":0'
echo "--- 1. 基线:不传任何思考参数 ---"
probe "baseline (什么都不传)" "{\"model\":\"$M\",$Q}"
echo
echo "--- 2. chat_template_kwargs.reasoning_effort(模板自己的档位)---"
for e in low medium xhigh; do
  probe "cts_kwargs effort=$e" "{\"model\":\"$M\",$Q,\"chat_template_kwargs\":{\"reasoning_effort\":\"$e\"}}"
done
echo
echo "--- 3. 顶层 reasoning_effort(codex / Claude Code 走这条,EFFORT_ALIAS 管它)---"
for e in high max minimal low xhigh; do
  probe "top-level effort=$e" "{\"model\":\"$M\",$Q,\"reasoning_effort\":\"$e\"}"
done
echo
echo "--- 4. 别的栈的「关思考」kwarg 在本栈是什么下场(gotcha #9)---"
probe "enable_thinking=false (qwen38fn/qwen38un 的)" "{\"model\":\"$M\",$Q,\"chat_template_kwargs\":{\"enable_thinking\":false}}"
probe "thinking=false (v4flash 的)" "{\"model\":\"$M\",$Q,\"chat_template_kwargs\":{\"thinking\":false}}"
echo
echo "--- 5. 负向闸门:错的 model 名(SGLang 会照收,vLLM 应该 404)---"
probe "model=nope-not-a-model" "{\"model\":\"nope-not-a-model\",$Q}"
rm -f /tmp/.pt.json
