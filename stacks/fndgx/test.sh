#!/usr/bin/env bash
# fndgx 冒烟 —— **不是 benchmark**(见 docs/benchmarking-cn.md)。
#
# 验五件事,每一件的判据都是「回来的产物」,不是 curl 的退出码:
#   1. 真的在出 token
#   2. 本栈的思考语义(**第六套**):CoT 在 `reasoning`,`reasoning_content` 恒 None,
#      enable_thinking=false 是真关 —— 三条全是实测,不是从 qwen38fn 抄的
#   3. 顶层 reasoning_effort=high 不 400(serve.sh 的 EFFORT_ALIAS;codex 直接依赖它)
#   4. **PLE mmap 真的在用** —— 这是本栈能在一台机器上跑起来的唯一原因,
#      不验它,这个栈就没有存在理由
#   5. 多模态(视觉)真的在跑
#
# ⚠️ 身份由 stackctl 从 stacks/fndgx/stack.env 注入。这里**故意不给默认值** ——
#    一个自带 model 名的冒烟脚本,手跑时会静默去测另一个栈,还打印一份
#    看起来很正常的结果。
set -uo pipefail

URL="${URL:?缺 URL —— 用 make test STACK=fndgx}"
MODEL="${MODEL:?缺 MODEL —— 用 make test STACK=fndgx}"
COT_FIELD="${COT_FIELD:?缺 COT_FIELD —— 用 make test STACK=fndgx}"
CONTAINER="${CONTAINER:-qwen38-flash}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0

post(){ # $1=请求体文件 -> $TMP/resp.json
  curl -s -m 240 "$URL/chat/completions" -H 'Content-Type: application/json' -d @"$1" > "$TMP/resp.json"
}
req(){  # $1=prompt $2=max_tokens $3=额外的顶层 JSON 片段(可空)
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

echo "=== fndgx 冒烟(Qwen3.8-Flash-Next 单机 / PLE mmap)==="
echo "url=$URL  model=$MODEL  cot_field=$COT_FIELD"

served=$(curl -s -m 15 "$URL/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)
[ "$served" = "$MODEL" ] || { echo "FAIL: /v1/models 报 '${served:-<无响应>}',本脚本要测 '$MODEL'"; exit 1; }
echo "served_model_name = $served  OK"

# ---------------------------------------------------------------- 1 + 2
echo
echo "--- 1+2. 生成 + 思考语义(本栈第六套)---"
# 这道题必须思考才做得对:17 只羊「除了 9 只都跑了」→ 剩 9,买 18 → 27,卖 5 → 22。
Q='A farmer has 17 sheep. All but 9 run away. Then he buys twice as many as remain, and sells 5. How many sheep does he have? Give the final number only.'
req "$Q" 1200 ''; post "$TMP/req.json"; cp "$TMP/resp.json" "$TMP/on.json"
req "$Q" 1200 '{"chat_template_kwargs":{"enable_thinking":false}}'; post "$TMP/req.json"; cp "$TMP/resp.json" "$TMP/off.json"

python3 - "$TMP/on.json" "$TMP/off.json" "$COT_FIELD" <<'PY' || fails=$((fails+1))
import json, sys
on, off, field = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
for tag, d in (("思考开", on), ("思考关", off)):
    if "choices" not in d:
        print(f"  !! {tag}: {json.dumps(d, ensure_ascii=False)[:200]}"); raise SystemExit(1)
mon, moff = on["choices"][0]["message"], off["choices"][0]["message"]
n_on, n_off = on["usage"]["completion_tokens"], off["usage"]["completion_tokens"]
cot_on, cot_off = mon.get(field), moff.get(field)
other = "reasoning_content" if field == "reasoning" else "reasoning"
print(f"  思考开: out={n_on:4d} tok  {field}={len(cot_on) if cot_on else 0} 字  content={(mon.get('content') or '').strip()[:20]!r}")
print(f"  思考关: out={n_off:4d} tok  {field}={len(cot_off) if cot_off else 0} 字  content={(moff.get('content') or '').strip()[:20]!r}")
ok = True
if n_on < 30:
    print(f"  !! 只生成 {n_on} 个 token —— 不算跑过"); ok = False
if not cot_on:
    print(f"  !! 思考开着,但 `{field}` 是空的 —— CoT 字段可能变了(引擎升级?)"); ok = False
# 负向:另一个字段必须是空的。不验这一条的话,两个字段都有值时也会「通过」,
# 而注册表里 STACK_COT_FIELD 写哪个就都无所谓了 —— 那正是 gotcha #9 的温床。
if mon.get(other):
    print(f"  !! `{other}` 也有值 —— stack.env 的 STACK_COT_FIELD 已不唯一,请复核"); ok = False
if cot_off:
    print(f"  !! enable_thinking=false 没关掉思考(`{field}` 仍有 {len(cot_off)} 字)"); ok = False
if n_off >= n_on:
    print(f"  !! 关思考后输出没变少({n_off} >= {n_on})—— kwarg 多半被静默忽略了"); ok = False
print("  PASS" if ok else "  FAIL")
raise SystemExit(0 if ok else 1)
PY

# ---------------------------------------------------------------- 3
echo
echo "--- 3. 顶层 reasoning_effort=high(EFFORT_ALIAS;codex/Claude Code 走这条)---"
# checkpoint 自带的模板只认 xhigh/medium/low,其余一律 raise。serve.sh 会另存一份
# 改写过 effort 解析行的模板副本挂进容器。副本没生成时**每一个** codex 请求都 400,
# 而那是启动期一句 warning,极易漏看 —— 所以在这里当成闸门。
req "$Q" 64 '{"reasoning_effort":"high"}'
code=$(curl -s -m 120 -o "$TMP/resp.json" -w '%{http_code}' \
       "$URL/chat/completions" -H 'Content-Type: application/json' -d @"$TMP/req.json")
if [ "$code" = "200" ]; then
  echo "  HTTP 200  PASS"
else
  echo "  HTTP $code  FAIL —— EFFORT_ALIAS 没生效,codex 的每个请求都会 400"
  head -c 300 "$TMP/resp.json"; echo
  fails=$((fails+1))
fi

# ---------------------------------------------------------------- 4
echo
echo "--- 4. PLE mmap 真的在用(本栈能单机跑的唯一原因)---"
# 48 GiB 的 n-gram 表从 NVMe mmap 读,而不是占显存。
# ⚠️ /metrics 上的 vllm:ple_mmap_* 计数器默认**不导出**(需要 PROM_MULTIPROC=1),
#    所以判据取引擎自己在启动时打的那一行 + 容器 env,两者都必须在。
env_ok=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
         | grep -c '^VLLM_PLE_MMAP=1$')
log_ok=$(docker logs "$CONTAINER" 2>&1 | grep -c 'PLE mmap patch applied to')
echo "  VLLM_PLE_MMAP=1 在容器 env 里: $env_ok 处"
echo "  'PLE mmap patch applied to' 在引擎日志里: $log_ok 处"
if [ "$env_ok" -ge 1 ] && [ "$log_ok" -ge 1 ]; then
  echo "  PASS"
else
  echo "  FAIL —— 补丁没挂上。此时模型要么根本装不下,要么正在吃掉本该给 KV 的显存。"
  fails=$((fails+1))
fi

# ---------------------------------------------------------------- 5
echo
echo "--- 5. 多模态(视觉)---"
# ⚠️ 判据是**同一段文字带图 vs 不带图的 prompt_tokens 差值**,不是「答案看起来对」。
#    本镜像的 usage.prompt_tokens_details 是 null,qwen38un 那套 image_tokens>0
#    的写法在这里用不了。图被静默丢掉时模型照样会自信地编 —— 2026-09-20 实测,
#    不带图时它答 'Red Blue Green Yellow',一个字都不对,却毫不犹豫。
# 图是脚本自己生成的 200 字节 PNG(纯 zlib+struct,不依赖 PIL、不下载任何东西)。
for mode in without with; do
  python3 - "$MODEL" "$mode" > "$TMP/img-$mode.json" <<'PY'
import base64, json, struct, sys, zlib
m, mode = sys.argv[1], sys.argv[2]
TXT = ("The image has four quadrants. Name the colours in order "
       "top-left, top-right, bottom-left, bottom-right. Four words only.")
if mode == "without":
    content = TXT
else:
    W = H = 128                      # 128x128 + patch16/merge2
    def px(x, y):                    # 左上紫 / 右上白 / 左下黑 / 右下橙
        if y < H // 2: return (128, 0, 255) if x < W // 2 else (255, 255, 255)
        return (0, 0, 0) if x < W // 2 else (255, 165, 0)
    raw = b"".join(bytes([0]) + b"".join(bytes(px(x, y)) for x in range(W)) for y in range(H))
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    content = [{"type": "image_url",
                "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}},
               {"type": "text", "text": TXT}]
print(json.dumps({"model": m, "messages": [{"role": "user", "content": content}],
                  "max_tokens": 96, "temperature": 0,
                  "chat_template_kwargs": {"enable_thinking": False}}))
PY
  post "$TMP/img-$mode.json"; cp "$TMP/resp.json" "$TMP/imgresp-$mode.json"
done

python3 - "$TMP/imgresp-without.json" "$TMP/imgresp-with.json" <<'PY' || fails=$((fails+1))
import json, sys
wo, wi = (json.load(open(p)) for p in sys.argv[1:3])
for tag, d in (("不带图", wo), ("带图", wi)):
    if "choices" not in d:
        print(f"  !! {tag}: {json.dumps(d, ensure_ascii=False)[:300]}")
        print("     400 且提到 image/content 多半是模板不认多模态 content 数组。")
        raise SystemExit(1)
n_wo, n_wi = wo["usage"]["prompt_tokens"], wi["usage"]["prompt_tokens"]
a_wo = (wo["choices"][0]["message"].get("content") or "").strip()
a_wi = (wi["choices"][0]["message"].get("content") or "").strip()
low = a_wi.lower()
hit = [n for n, ks in (("紫", ("紫", "purple")), ("白", ("白", "white")),
                       ("黑", ("黑", "black")), ("橙", ("橙", "orange")))
       if any(k in low for k in ks)]
print(f"  不带图: prompt_tokens={n_wo:4d}  答案={a_wo[:45]!r}   ← 这一行应当是错的")
print(f"  带  图: prompt_tokens={n_wi:4d}  答案={a_wi[:45]!r}  命中颜色={len(hit)}/4")
ok = True
if n_wi - n_wo < 32:
    print(f"  !! 带图只多了 {n_wi - n_wo} 个 prompt token —— 图**根本没进模型**,"
          f"上面那句描述是编的。")
    ok = False
if len(hit) < 3:
    print("  !! 视觉路径跑了但认色失败(<3/4)—— 视觉塔权重或预处理器可能不对。")
    ok = False
print("  PASS" if ok else "  FAIL")
raise SystemExit(0 if ok else 1)
PY

echo
echo "============================================================"
if [ "$fails" -eq 0 ]; then
  echo "fndgx 冒烟:全部通过"
else
  echo "fndgx 冒烟:$fails 项失败"
fi
exit "$fails"
