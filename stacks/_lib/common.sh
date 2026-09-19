#!/usr/bin/env bash
# ============================================================
# stacks/_lib/common.sh —— 栈注册表的读取层
#
# 为什么存在:在此之前,「当前主力栈是谁」这个事实被写死在 ~8 个地方
# (Makefile 的 ifeq 阶梯、mem-watch.sh 的 WATCH_* 默认值、gb10-clock-cap.sh 的
# MODEL/PORT/CHAT_KWARGS、qwen-model-switch.sh 的 case 分支、三份文档的表格),
# 而**每一处改错都不报错**。docs/stack-switch-cn.md §0 记了同形状的三次事故。
#
# 现在只有一个事实源:stacks/<id>/stack.env,外加 stacks/PRIMARY 一行 id。
# 所有工具从这里读,不再各自持有默认值。
#
# 用法(被 source):
#   . stacks/_lib/common.sh
#   load_stack qwen38un          # 把 STACK_* 注入当前 shell
#   primary_stack                # 打印当前主力栈 id
#   stack_ids / stack_ids_active # 枚举注册表
#   stack_field glm53 STACK_PORT # 只取一个字段(子 shell,不污染环境)
# ============================================================
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STACKS_DIR="$REPO_ROOT/stacks"

# stack.env 必填字段。缺任何一个 → 拒绝加载(宁可起不来,也不要带着半个身份跑)。
# 这条是 docs/stack-switch-cn.md §3 规则 5 的落地:一个分不清「通过」和
# 「根本没运行」的检查器比没有检查器更糟。
STACK_REQUIRED_FIELDS="STACK_ID STACK_NAME STACK_RUNTIME STACK_MODEL STACK_PORT STACK_HEAD"

die(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "WARN: $*" >&2; }

# --- 注册表枚举 --------------------------------------------------------------
# 一个目录 + 一个 stack.env = 一个栈。加模型 = 新建目录,不改任何既有文件。
stack_ids(){
  local d
  for d in "$STACKS_DIR"/*/; do
    d="${d%/}"; local id="${d##*/}"
    [ "$id" = "_lib" ] && continue
    [ -f "$d/stack.env" ] || continue
    echo "$id"
  done
}

# 参与 GPU 互斥 / make 目标的栈(排除 STACK_RUNTIME=external 的本地模型)。
stack_ids_active(){
  local id
  for id in $(stack_ids); do
    [ "$(stack_field "$id" STACK_RUNTIME)" = "external" ] && continue
    echo "$id"
  done
}

primary_stack(){
  local f="$STACKS_DIR/PRIMARY"
  [ -f "$f" ] || die "缺 $f —— 注册表不知道谁是主力栈"
  local id; id=$(grep -vE '^\s*#|^\s*$' "$f" | head -1 | tr -d '[:space:]')
  [ -n "$id" ] || die "$f 是空的"
  [ -f "$STACKS_DIR/$id/stack.env" ] || die "PRIMARY 指向 '$id',但 stacks/$id/stack.env 不存在"
  echo "$id"
}

# --- 加载 --------------------------------------------------------------------
# id 为空时落到 PRIMARY。这是「不带 STACK= 的 make 目标操作主力栈」的实现。
resolve_stack_id(){
  local id="${1:-}"
  [ -n "$id" ] || id=$(primary_stack) || exit 1
  [ -f "$STACKS_DIR/$id/stack.env" ] \
    || die "未知的栈 '$id'。已注册:$(stack_ids | tr '\n' ' ')"
  echo "$id"
}

load_stack(){
  local id; id=$(resolve_stack_id "${1:-}") || exit 1
  STACK_DIR_LOCAL="$STACKS_DIR/$id"
  # shellcheck disable=SC1090
  . "$STACK_DIR_LOCAL/stack.env"
  local f
  for f in $STACK_REQUIRED_FIELDS; do
    [ -n "${!f:-}" ] || die "stacks/$id/stack.env 缺必填字段 $f"
  done
  [ "$STACK_ID" = "$id" ] \
    || die "stacks/$id/stack.env 里 STACK_ID=$STACK_ID 与目录名不符(复制粘贴没改?)"
  export STACK_SELF_DIR="$STACK_DIR_LOCAL"
}

# 只取一个字段,不污染调用者的环境。枚举全表时用。
stack_field(){
  local id="$1" var="$2"
  ( . "$STACKS_DIR/$id/stack.env" 2>/dev/null; echo "${!var:-}" )
}

# --- SSH ---------------------------------------------------------------------
STACK_SSH_USER="${STACK_SSH_USER:-admin}"
STACK_SSH_KEY="${STACK_SSH_KEY:-$HOME/.ssh/vgio}"
sshx(){
  local host="$1"; shift
  ssh -i "$STACK_SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o ConnectTimeout=15 "$STACK_SSH_USER@$host" "$@"
}

K8S="${K8S:-kubectl --kubeconfig $HOME/.kube/dgx-spark.yaml}"
