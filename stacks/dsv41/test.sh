#!/usr/bin/env bash
# dsv41 冒烟测试 —— **不是基准**(见 docs/benchmarking-cn.md)。跑在 head(S1)上,打 localhost。
#
# 验五件事,每条的判据都是"回的是什么",不是 curl 的退出码:
#   1. 真的在吐 token,/v1/models 报的是注册表里的名字
#   2. thinking 语义:chat_template_kwargs.enable_thinking 真能开/关;顶层 enable_thinking 是否生效
#      只记录不判(上游模板只认 chat_template_kwargs)
#   3. CoT 字段是 STACK_COT_FIELD,另一个字段为空(负验证;gotcha #9 —— 读错字段的表现是"一个字都没有")
#   4. /v1/responses(codex wire_api=responses)逐档 effort 列出 HTTP 码;STACK_EFFORT_LEVELS 里的必须 200,
#      none 必须真无 reasoning
#   5. 跨节点交换真在 RoCE 上:生成期间 head 的 HCA 计数在涨
#   6. 上游自己的端到端检查 tools/validate.py(文本 / thinking / 工具调用 / 图片 / 长 prompt)
#
# ⚠️ 身份由 stackctl 从 stacks/dsv41/stack.env 注入,这里**故意不给默认值**。
set -uo pipefail

URL="${URL:?missing URL —— 用 make test STACK=dsv41}"
BASE="${BASE:?missing BASE —— 用 make test STACK=dsv41}"
MODEL="${MODEL:?missing MODEL —— 用 make test STACK=dsv41}"
COT_FIELD="${COT_FIELD:?missing COT_FIELD —— 用 make test STACK=dsv41}"
LEVELS="${EFFORT_LEVELS:-low medium high xhigh max}"
RECIPE="${RECIPE:-/home/admin/dsv41-recipe}"
HCA="${HCA:-rocep1s0f0}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0

post(){ curl -s -m 600 "$URL/chat/completions" -H 'Content-Type: application/json' -d @"$1" > "$2"; }
req(){ # $1=prompt $2=max_tokens $3=额外顶层 JSON(可选)
  python3 - "$MODEL" "$1" "$2" "${3:-}" <<'PY'
import json, sys
m, p, mt, extra = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
body = {"model": m, "messages": [{"role": "user", "content": p}], "max_tokens": mt, "temperature": 0, "stream": False}
if extra: body.update(json.loads(extra))
print(json.dumps(body))
PY
}

echo "=== dsv41 冒烟测试 (DeepSeek-V4.1-Flash-1017 EXL3 / TensorFold Zig, TP=2) ==="
echo "url=$URL  model=$MODEL  cot_field=$COT_FIELD"
served=$(curl -s -m 15 "$URL/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)
[ "$served" = "$MODEL" ] || { echo "FAIL: /v1/models 报 '${served:-<无响应>}' —— 本脚本应测 '$MODEL'"; exit 1; }
echo "served_model_name = $served  OK"

# ---------------------------------------------------------------- 1 + 2 + 3
echo; echo "--- 1+2+3. 生成 + thinking 开关 + CoT 字段 ---"
Q='A farmer has 17 sheep. All but 9 run away. Then he buys twice as many as remain, and sells 5. How many sheep does he have? Give the final number only.'
req "$Q" 4000 '{"chat_template_kwargs":{"enable_thinking":true}}'  > "$TMP/q.json"; post "$TMP/q.json" "$TMP/on.json"
req "$Q" 4000 '{"chat_template_kwargs":{"enable_thinking":false}}' > "$TMP/q.json"; post "$TMP/q.json" "$TMP/off.json"
req "$Q" 4000 '{"enable_thinking":false}'                          > "$TMP/q.json"; post "$TMP/q.json" "$TMP/top.json"
req "$Q" 4000                                                      > "$TMP/q.json"; post "$TMP/q.json" "$TMP/dflt.json"
python3 - "$TMP" "$COT_FIELD" <<'PY' || fails=$((fails+1))
import json, sys, os
d, field = sys.argv[1], sys.argv[2]
other = "reasoning" if field == "reasoning_content" else "reasoning_content"
ok = True
def probe(tag, f):
    global ok
    try:
        r = json.load(open(os.path.join(d, f)))
        m = r["choices"][0]["message"]
    except Exception as e:
        print(f"  {tag}: 无有效响应 ({e})"); ok = False; return 0, ""
    cot, oth, txt = m.get(field) or "", m.get(other) or "", (m.get("content") or "").strip()
    print(f"  {tag}: out={r.get('usage',{}).get('completion_tokens','?'):>5} tok  {field}={len(cot):5d} chars  {other}={len(oth)}  "
          f"finish={r['choices'][0].get('finish_reason')}  content={txt[:24]!r}")
    if oth:
        print(f"  !! `{other}` 也有值 —— STACK_COT_FIELD 不再是唯一承载字段"); ok = False
    return len(cot), txt
on, ton = probe("CTX on    ", "on.json")
off, toff = probe("CTX off   ", "off.json")
top, _ = probe("顶层 false", "top.json")
dflt, _ = probe("不传      ", "dflt.json")
if on < 20:   print(f"  !! CTX on 只有 {on} chars CoT —— thinking 没在跑,或 CoT 不在 `{field}`"); ok = False
if off > 0:   print(f"  !! CTX off 还有 {off} chars CoT —— thinking 没真关"); ok = False
if not toff:  print("  !! CTX off 没有 content"); ok = False
if dflt < 20: print(f"  !! 不传时没有 CoT —— 上游默认 THINKING=1 应该在想")
print(f"  (记录)顶层 enable_thinking=false → CoT {top} chars:{'被忽略' if top >= 20 else '生效了'}")
print(f"  (记录)答案 on={ton!r} off={toff!r}(正确答案 22)")
print("  PASS" if ok else "  FAIL")
raise SystemExit(0 if ok else 1)
PY

# ---------------------------------------------------------------- 4
echo; echo "--- 4. /v1/responses effort 档位 ---"
for eff in none minimal low medium high xhigh max; do
  code=$(curl -s -m 600 -o "$TMP/r_$eff.json" -w '%{http_code}' "$URL/responses" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"input\":\"Reply with exactly: OK\",\"max_output_tokens\":2048,\"reasoning\":{\"effort\":\"$eff\"}}")
  info=$(python3 - "$TMP/r_$eff.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
has_r = any(o.get("type") == "reasoning" for o in d.get("output", []))
txt = "".join(b.get("text", "") for o in d.get("output", []) if o.get("type") == "message" for b in o.get("content", []))
print(f"reasoning={has_r} content={txt.strip()[:16]!r}")
PY
)
  want=""; case " $LEVELS none " in *" $eff "*) want="(须 200)";; esac
  echo "  effort=$eff  HTTP $code  ${info:-}  $want"
  if [ -n "$want" ] && [ "$code" != 200 ]; then fails=$((fails+1)); echo "  !! catalog 列了 $eff,但它不是 200"; fi
  if [ "$eff" = none ] && [ "$code" = 200 ] && echo "$info" | grep -q 'reasoning=True'; then
    fails=$((fails+1)); echo "  !! effort=none 仍有 reasoning item"; fi
done

# ---------------------------------------------------------------- 5
echo; echo "--- 5. 跨节点交换走 RoCE ---"
C="/sys/class/infiniband/$HCA/ports/1/counters/port_xmit_data"   # 单位 4 字节
if [ ! -r "$C" ]; then echo "  SKIP: 读不到 $C"; else
  a=$(cat "$C")
  req "Write a 300-word story about a lighthouse keeper." 600 '{"chat_template_kwargs":{"enable_thinking":false}}' > "$TMP/q.json"
  post "$TMP/q.json" "$TMP/rdma.json"
  b=$(cat "$C"); mb=$(( (b - a) * 4 / 1048576 ))
  n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["usage"]["completion_tokens"])' "$TMP/rdma.json" 2>/dev/null || echo 0)
  echo "  生成 $n tokens 期间 $HCA 发送 $mb MB"
  [ "$mb" -gt 1 ] || { echo "  !! HCA 计数几乎没动 —— 交换没走 RDMA?"; fails=$((fails+1)); }
fi

# ---------------------------------------------------------------- 6
echo; echo "--- 6. 上游 tools/validate.py ---"
if [ -f "$RECIPE/tools/validate.py" ]; then
  python3 -I "$RECIPE/tools/validate.py" "$BASE" --model "$MODEL" 2>&1 | tail -25
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "  !! validate.py 非 0"; fails=$((fails+1)); }
else
  echo "  SKIP: $RECIPE/tools/validate.py 不存在"
fi

echo
[ "$fails" -eq 0 ] && echo "=== 全部通过 ===" || echo "=== $fails 项失败 ==="
exit "$fails"
