#!/usr/bin/env bash
# hibrid48 冒烟测试 —— **不是基准**(见 docs/benchmarking-cn.md)。
#
# 验四件事,每条的判据都是"回的是什么",不是 curl 的退出码:
#   1. 真的在吐 token
#   2. thinking 语义:chat_template_kwargs.enable_thinking 真能开/关,
#      顶层 enable_thinking 被静默忽略(2026-09-28 实测,与 fndgx 的最大差别)
#   3. /v1/responses(codex wire_api=responses)对 catalog 的档位 xhigh / none 200,
#      none 真无 reasoning item
#   4. CoT 字段是 `reasoning`,`reasoning_content` 恒为 None(负验证;gotcha #9)
# 多模态未在本镜像验证过(fndgx 有四象限图测试,本镜像没有),所以不挂图。
#
# ⚠️ 身份由 stackctl 从 stacks/hibrid48/stack.env 注入,这里**故意不给默认值** ——
#    带自己模型名的冒烟脚本手跑一次,会静默测到别的栈,还打出全绿的数字。
set -uo pipefail

URL="${URL:?missing URL —— 用 make test STACK=hibrid48}"
MODEL="${MODEL:?missing MODEL —— 用 make test STACK=hibrid48}"
COT_FIELD="${COT_FIELD:?missing COT_FIELD —— 用 make test STACK=hibrid48}"
CONTAINER="${CONTAINER:-qwen38-flash-next}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0

post(){
  curl -s -m 240 "$URL/chat/completions" -H 'Content-Type: application/json' -d @"$1" > "$TMP/resp.json"
}
req(){ # $1=prompt $2=max_tokens $3=额外顶层 JSON 片段(可选)
  python3 - "$MODEL" "$1" "$2" "${3:-}" > "$TMP/req.json" <<'PY'
import json, sys
m, p, mt, extra = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
body = {"model": m, "messages": [{"role": "user", "content": p}],
        "max_tokens": mt, "temperature": 0, "stream": False}
if extra:
    body.update(json.loads(extra))
print(json.dumps(body))
PY
}

echo "=== hibrid48 冒烟测试 (Qwen3.8-Flash-Next / bilikaz v4) ==="
echo "url=$URL  model=$MODEL  cot_field=$COT_FIELD"

served=$(curl -s -m 15 "$URL/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)
[ "$served" = "$MODEL" ] || { echo "FAIL: /v1/models 报 '${served:-<无响应>}' —— 本脚本应测 '$MODEL'"; exit 1; }
echo "served_model_name = $served  OK"

# ---------------------------------------------------------------- 1 + 2 + 4
echo
echo "--- 1+2+4. 生成 + thinking 语义(只有 CTX 字段有效,顶层被忽略) ---"
# 这道题 thinking ON 才答得对:9 只留下、买 18 只(共 27)、卖 5 → 22。
# 2026-09-28 实测:ON 答 22,OFF 答 13 —— 与 fndgx 同形。
Q='A farmer has 17 sheep. All but 9 run away. Then he buys twice as many as remain, and sells 5. How many sheep does he have? Give the final number only.'
req "$Q" 1200 '{"chat_template_kwargs":{"enable_thinking":true}}'; post "$TMP/req.json"; cp "$TMP/resp.json" "$TMP/on.json"
req "$Q" 1200 '{"chat_template_kwargs":{"enable_thinking":false}}'; post "$TMP/req.json"; cp "$TMP/resp.json" "$TMP/off.json"
req "$Q" 1200 '{"enable_thinking":false}'; post "$TMP/req.json"; cp "$TMP/resp.json" "$TMP/ignored.json"

python3 - "$TMP/on.json" "$TMP/off.json" "$TMP/ignored.json" "$COT_FIELD" <<'PY' || fails=$((fails+1))
import json, sys
on, off, ign = (json.load(open(p)) for p in sys.argv[1:4])
field = sys.argv[4]
def probe(tag, d):
    m = d["choices"][0]["message"]
    rt = (d.get("usage", {}).get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    print(f"  {tag}: out={d['usage']['completion_tokens']:4d} tok  {field}={len(m.get(field) or ''):4d} chars  {field}_tokens={rt:4d}  content={(m.get('content') or '').strip()[:20]!r}")
    return m, rt
mon, rton = probe("CTX on      ", on)
moff, rtoff = probe("CTX off     ", off)
mign, rtign = probe("顶层 false  ", ign)
ok = True
other = "reasoning_content" if field == "reasoning" else "reasoning"
if mon.get(other) or moff.get(other) or mign.get(other):
    print(f"  !! `{other}` 也有值 —— STACK_COT_FIELD 不再是唯一承载字段,需重新确认"); ok = False
if rton < 20:
    print(f"  !! CTX on 只有 {rton} reasoning tokens —— 说不清 thinking 是否真在跑"); ok = False
if rtoff > 0:
    print(f"  !! CTX off 还有 {rtoff} reasoning tokens —— thinking 没真关"); ok = False
if rtoff >= rton:
    print(f"  !! 关思考后输出没缩水(off {rtoff} >= on {rton}) —— kwarg 可能被静默忽略"); ok = False
if rtign < 20:
    print(f"  !! 顶层 false 把思考关了({rtign} tokens)—— 字段路径变了,更新注册表注释")
print("  PASS" if ok else "  FAIL")
raise SystemExit(0 if ok else 1)
PY

# ---------------------------------------------------------------- 3
echo
echo "--- 3. /v1/responses (codex wire_api=responses) ---"
for eff in xhigh none; do
  code=$(curl -s -m 180 -o "$TMP/resp_$eff.json" -w '%{http_code}' \
    "$URL/responses" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"input\":\"Reply with exactly: OK\",\"max_output_tokens\":256,\"reasoning\":{\"effort\":\"$eff\"}}")
  if [ "$code" != "200" ]; then
    echo "  effort=$eff  HTTP $code  FAIL —— codex 的请求会 400"; head -c 300 "$TMP/resp_$eff.json"; echo; fails=$((fails+1)); continue
  fi
  python3 - "$TMP/resp_$eff.json" "$eff" <<'PY' || fails=$((fails+1))
import json, sys
d, eff = json.load(open(sys.argv[1])), sys.argv[2]
has_r = any(o.get("type") == "reasoning" for o in d.get("output", []))
txt = "".join(b.get("text", "") for o in d.get("output", []) if o.get("type") == "message" for b in o.get("content", []))
print(f"  effort={eff}: 200  reasoning={has_r}  content={txt[:20]!r}")
if eff == "none" and has_r:
    print("  !! effort=none 仍有 reasoning item —— 思考没真关(catalog 的 none 档要复核)")
    raise SystemExit(1)
if eff != "none" and not has_r:
    print(f"  !! effort={eff} 无 reasoning item —— 思考没在跑,catalog 档位失准")
    raise SystemExit(1)
PY
done

echo
echo "============================================================"
if [ "$fails" -eq 0 ]; then
  echo "hibrid48 冒烟测试:全部通过"
else
  echo "hibrid48 冒烟测试:$fails 项失败"
fi
exit "$fails"
