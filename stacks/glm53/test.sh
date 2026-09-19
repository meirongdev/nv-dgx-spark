#!/usr/bin/env bash
# GLM-5.3-Flash EXL3 冒烟测试 —— **不是 benchmark**(见 docs/benchmarking-cn.md)。
# 目的:换栈后确认「真的在出 token」+ 把本栈三个与别栈不同的语义验一遍。
#
# ⚠️ **[stack-bound]** —— MODEL / EFFORT_KEY / COT_FIELD 都是本栈专属,
#    换栈时见 docs/stack-switch-cn.md。本栈与另外两个栈**三处都不同**:
#
#    | | V4-Flash | Flash-Next | **GLM-5.3-Flash EXL3** |
#    |---|---|---|---|
#    | 关思考的 kwarg | `thinking:false` | `enable_thinking:false` | **无法关闭**,最低 `reasoning_effort:"low"` |
#    | CoT 响应字段 | `reasoning_content` | `reasoning_content` | **`reasoning`** |
#    | 不传的默认 | 关 | 开 | **Max**(最费) |
#
#    上游 README 原话:"Read the reply from **`reasoning`**, not `reasoning_content`.
#    ... A client reading `reasoning_content` gets nothing and the thinking looks
#    like it leaked into `content` — it did not."
#    ⚠️ 不传 reasoning_effort 时模板渲染成 **Max**,400 token 的预算会被 CoT
#    吃光并以 finish_reason=length + 空 content 返回(上游 issue #162)。
#    ⚠️ `medium` 会被模板拒绝;同一会话内改 effort = 整段 prefix-cache miss
#    (effort 词落在 prompt 第 39 字符)。
set -uo pipefail

# ⚠️ 身份由 stackctl 从 stacks/<id>/stack.env 注入(make test STACK=<id>)。
#    这里**故意不给默认值** —— 一个自带旧栈 model 名的冒烟脚本,手跑时会
#    静默地去测另一个栈,而它照样打印一份看起来很正常的结果。
URL="${URL:?缺 URL —— 用 make test STACK=glm53}"
MODEL="${MODEL:?缺 MODEL —— 用 make test STACK=glm53}"
EFFORT="${EFFORT:-low}"
MAXTOK="${MAXTOK:-400}"
WARMUPS="${WARMUPS:-2}"
REPS="${REPS:-3}"
PROMPT="${PROMPT:-Write a Python function that builds a height-balanced BST from a sorted array. Code only, no explanation.}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

body() {
  python3 - "$MODEL" "$PROMPT" "$MAXTOK" "$EFFORT" <<'PY'
import json, sys
model, prompt, maxtok, effort = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": maxtok,
    "temperature": 0,
    "stream": False,                      # 流式数的是 step 不是 token(benchmarking 陷阱 #1)
    "chat_template_kwargs": {"reasoning_effort": effort},
}))
PY
}

echo "=== GLM-5.3-Flash EXL3 冒烟 ==="
echo "url=$URL  model=$MODEL  effort=$EFFORT  max_tokens=$MAXTOK"

echo "--- /v1/models ---"
served=$(curl -s -m 15 "$URL/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)
if [ "$served" != "$MODEL" ]; then
  echo "FAIL: /v1/models 报的是 '${served:-<无响应>}',本脚本要测的是 '$MODEL'"
  echo "      换栈后忘了改 MODEL? 见 docs/stack-switch-cn.md 第 2 层。"
  exit 1
fi
echo "served_model_name = $served  OK"

body > "$TMP/req.json"
hit() { curl -s -m 300 "$URL/chat/completions" -H 'Content-Type: application/json' -d @"$TMP/req.json"; }

echo "--- warmup x$WARMUPS(冷/闲置衰减约 30%,见 benchmarking 陷阱 #2) ---"
for _ in $(seq 1 "$WARMUPS"); do hit > /dev/null; done

best=0
for i in $(seq 1 "$REPS"); do
  t0=$(date +%s.%N); hit > "$TMP/resp.json"; t1=$(date +%s.%N)
  wall=$(echo "$t1 - $t0" | bc)
  out=$(python3 - "$TMP/resp.json" "$wall" "$i" <<'PY'
import json, sys
path, wall, i = sys.argv[1], float(sys.argv[2]), sys.argv[3]
d = json.load(open(path))
if "choices" not in d:
    print(f"ERR {json.dumps(d)[:200]}"); raise SystemExit(0)
u = d["usage"]; m = d["choices"][0]["message"]
n = u["completion_tokens"]
rt = (u.get("completion_tokens_details") or {}).get("reasoning_tokens")
# ⚠️ 本栈 CoT 在 `reasoning`;读 reasoning_content 会永远拿到 None
cot = m.get("reasoning")
body = (m.get("content") or "").strip()
print(f"OK {n} {rt if rt is not None else -1} {len(cot or '')} {len(body)} "
      f"{d['choices'][0]['finish_reason']} {wall:.3f} {n/wall:.1f}")
PY
)
  case "$out" in
    ERR*) echo "FAIL: 服务端返回异常 -> ${out#ERR }"; exit 1 ;;
  esac
  read -r _ n rtok cotlen bodylen finish wall tps <<<"$out"
  echo "run$i: out=${n}tok reasoning_tok=${rtok} cot_chars=${cotlen} content_chars=${bodylen} finish=${finish} wall=${wall}s -> ${tps} tok/s"
  best=$(python3 -c "print(max($best, $tps))")
  LAST_N=$n; LAST_BODY=$bodylen; LAST_COT=$cotlen; LAST_FINISH=$finish
done

echo
echo "--- 判据 ---"
fail=0
# 1. 真的生成了 —— curl 的退出码不算数(换栈清单 §3 规则 2)
[ "${LAST_N:-0}" -ge 50 ] || { echo "!! 只生成了 ${LAST_N:-0} 个 token(<50)—— 不算跑过"; fail=1; }
# 2. content 非空。空 content + finish=length = CoT 吃光预算(上游 #162),
#    说明 effort 没生效或 max_tokens 太小 —— 这是**静默**失败,必须响。
if [ "${LAST_BODY:-0}" -eq 0 ]; then
  echo "!! content 为空(finish=${LAST_FINISH:-?})—— CoT 吃光了 max_tokens。"
  echo "   effort='$EFFORT' 没生效?或 MAXTOK=$MAXTOK 太小(thinking 开时上游建议 >=32768)。"
  fail=1
fi
# 3. CoT 确实落在 `reasoning` 字段(本栈语义的回归)
[ "${LAST_COT:-0}" -gt 0 ] || echo "   note: reasoning 字段为空(effort=low 下可能正常)"
[ $fail -ne 0 ] && { echo "FAIL"; exit 1; }
printf 'PASS  best=%.1f tok/s (warm, effort=%s, temp0, 非流式, 从 usage 计数)\n' "$best" "$EFFORT"
echo "⚠️ 这是冒烟数,不是 benchmark —— 单条 prompt 的数字描述的是这条 prompt。"
