#!/usr/bin/env bash
# ============================================================
# stack-switch.sh —— 换主力栈(make switch TO=<id>)
#
# 在此之前,「当前主力栈是谁」写死在 ~8 个地方,分四层,越靠后越沉默:
#   1 服务端  改错会当场崩(最安全)
#   2 判据工具 改错 = 得到一个**看起来正常的错误结论** ⚠️ 三次事故全在这层
#   3 客户端  改错 = CLI 连到已停的栈,会响
#   4 文档    改错 = 下一个 session 在错误前提下工作 ⚠️ 最容易跳过
#
# 现在第 2 层和第 4 层是**推导出来的**:工具读 stacks/PRIMARY,文档表格由
# make stack-table 生成、make stack-check 校验。这个脚本负责按顺序做完,
# 并把**机器做不了的那几件**明确列出来 —— 而不是假装全自动。
# ============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/stacks/_lib/common.sh"

TO="${1:?用法: make switch TO=<stack-id>}"
FROM="$(primary_stack)"
[ -f "$STACKS_DIR/$TO/stack.env" ] || die "未知的栈 '$TO'。已注册:$(stack_ids | tr '\n' ' ')"
[ "$TO" != "$FROM" ] || die "'$TO' 已经是主力栈了"

NEW_NAME=$(stack_field "$TO" STACK_NAME)
echo "=== 换主力栈:$FROM → $TO ($NEW_NAME) ==="
echo

# --- 1. 先停旧的。所有栈互斥(同一份 GPU 内存),这一步不能省。---------------
echo "--- 1/5 停掉 $FROM ---"
bash "$STACKS_DIR/_lib/stackctl.sh" stop "$FROM" || warn "停 $FROM 失败(可能本来就没跑)"

# --- 2. 改注册表。这是唯一一处"当前主力栈是谁"的事实源。---------------------
echo "--- 2/5 stacks/PRIMARY: $FROM → $TO ---"
echo "$TO" > "$STACKS_DIR/PRIMARY"

# --- 3. 起新的(含遍历整个注册表的互斥自检)---------------------------------
echo "--- 3/5 起 $TO ---"
if ! bash "$STACKS_DIR/_lib/stackctl.sh" run "$TO"; then
  echo "$FROM" > "$STACKS_DIR/PRIMARY"
  die "起 $TO 失败,PRIMARY 已回滚到 $FROM"
fi

# --- 4. 文档表格 ------------------------------------------------------------
echo "--- 4/5 重新生成文档里的栈表格 ---"
python3 "$REPO/scripts/stack-table.py" --write

# --- 5. 客户端 --------------------------------------------------------------
ALIAS=$(stack_field "$TO" STACK_CLIENT_ALIAS); [ -n "$ALIAS" ] || ALIAS="$TO"
echo "--- 5/5 客户端(Qwen Code 启动默认)---"
bash "$REPO/scripts/qwen-model-switch.sh" "$ALIAS"

cat <<EOF

============================================================
换栈动作做完了。**下面这些机器替你做不了,逐条走。**
============================================================

验收(第 2 层的哨兵 —— 任一条响就说明还有工具没跟上):

  make status STACK=$TO          # 起来了,且 /v1/models 报新的 served name
  make test   STACK=$TO          # 冒烟 + 身份闸门
  make clock-cap-verify          # 必须打印"负载:生成 300 token";打印"生成失败"=没跟上
  make memwatch                  # 启动时自检能不能真停掉本栈,指错就 exit 3
  make stack-check               # 文档表格与注册表一致
  ./scripts/qwen-model-switch.sh status   # 客户端三文件一致

还要人来做的:

  · codex:~/.codex/<profile>.config.toml 的 model 名 + ~/.codex/models.json 的
    \`context_window\`(**不是** model_context_window)。这两处不在本仓库里,
    脚本够不着 —— 曾经静默不一致过:catalog 写 65536、config 写 1000000,
    于是一直按 64K 在跑,没有任何提示。见 docs/clients-cn.md。
  · **实际发一个请求**验证客户端,不要只看配置文件写对没有。
  · CLAUDE.md 的 \`## Current state\`:表格是生成的,那一段散文不是。
    通读它,问自己:只读过这一段的人,会不会据此得出错误结论?
  · 基准:新栈的数字在 stacks/$TO/recipe.yaml 和 benchmarks/ 里,
    别把上一个栈的 tok/s 继续挂在文档上(docs/benchmarking-cn.md)。
EOF
