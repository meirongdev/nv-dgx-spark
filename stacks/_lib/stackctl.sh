#!/usr/bin/env bash
# ============================================================
# stackctl.sh —— 所有栈的统一驱动。Makefile 只调它。
#
#   stacks/_lib/stackctl.sh <verb> [stack-id]
#   不给 stack-id 就落到 stacks/PRIMARY(即「操作当前主力栈」)。
#
# 动词:
#   run | stop | restart | status | logs | logs-worker | boot-log
#   test | load | preflight | info | list | primary | served-name
#
# 加一个模型要改这个文件吗?**不要。** 它不认识任何一个栈的名字。
# 见 stacks/README.md 的「新增一个模型」契约。
# ============================================================
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LIB/common.sh"
. "$LIB/preflight.sh"

VERB="${1:-}"; STACK_ARG="${2:-}"
[ -n "$VERB" ] || die "用法: stackctl.sh <verb> [stack-id]"

# --- 不需要加载具体栈的动词 --------------------------------------------------
case "$VERB" in
  list)
    # 列名用 ASCII —— CJK 在终端是双宽,printf 的 %-Ns 按字符数补齐,混排必错位。
    prim=$(primary_stack)
    printf '%-2s %-10s %-14s %-7s %-34s %s\n' '' ID RUNTIME/NODES PORT SERVED-MODEL-NAME STATUS
    for id in $(stack_ids); do
      printf '%-2s %-10s %-14s %-7s %-34s %s\n' \
        "$([ "$id" = "$prim" ] && echo '*')" "$id" \
        "$(stack_field "$id" STACK_RUNTIME)/$(stack_field "$id" STACK_NODES)" \
        "$(stack_field "$id" STACK_PORT)" "$(stack_field "$id" STACK_MODEL)" \
        "$(stack_field "$id" STACK_STATUS)"
    done
    echo
    echo '* = stacks/PRIMARY(当前主力栈)'
    exit 0 ;;
  primary) primary_stack; exit 0 ;;
esac

load_stack "$STACK_ARG"
case "$STACK_RUNTIME" in
  k3s)      . "$LIB/adapter-k3s.sh" ;;
  docker)   . "$LIB/adapter-docker.sh" ;;
  external) die "'$STACK_ID' 是 external 栈(本地/非本仓库部署),没有生命周期动词" ;;
  *)        die "未知 STACK_RUNTIME='$STACK_RUNTIME'。可用适配器:$(ls "$LIB"/adapter-*.sh | sed 's|.*adapter-||;s|\.sh||' | tr '\n' ' ')" ;;
esac

# --- 身份闸门:服务端报的 served name 必须与注册表一致 -----------------------
# ⚠️ 这一条曾经只存在于 gb10-clock-cap.sh 里,是被咬了两次才加上的:
#   · 2026-09-03 model 名写死成旧栈 → 服务端 400,而 `curl` 照样 rc=0 →
#     判据行用**空载采样**算了出来,读起来完全像「通过」(静默失效 ~24h)。
#   · 2026-09-19 换到 SGLang 才发现「写错名字会被 404 挡住」是 **vLLM 专属**
#     假设 —— SGLang 接受任意 model 名并原样回显(gotcha #10)。
# 所以判据不能是「请求成功了吗」,必须是「/v1/models 报的名字对得上吗」。
# 放在 stackctl 里 = 每个栈、每个工具都白拿这道闸门,不用各自重写一遍。
stack_served_name(){
  sshx "$STACK_HEAD" "curl -s -m 15 http://localhost:$STACK_PORT/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null
}
stack_assert_served_name(){
  local got; got=$(stack_served_name)
  [ -n "$got" ] || die "$STACK_HEAD:$STACK_PORT 上的 /v1/models 没有响应 —— 栈没起来?"
  [ "$got" = "$STACK_MODEL" ] || die \
    "服务端报 '$got',注册表说 '$STACK_MODEL'。
       线上跑的不是这个栈,或者 stacks/$STACK_ID/stack.env 的 STACK_MODEL 过期了。
       当前主力栈: $(primary_stack)"
  echo "  served_model_name = $got  OK"
}

case "$VERB" in
  preflight) preflight_run "$STACK_ID" ;;

  run)
    preflight_run "$STACK_ID" || exit 1
    echo "=== 启动 $STACK_ID ($STACK_NAME) ==="
    adapter_start
    ;;

  stop)        adapter_stop ;;
  restart)     adapter_restart ;;
  status)      adapter_status ;;
  logs)        adapter_logs leader "${TAIL:-60}" ;;
  logs-worker) adapter_logs worker "${TAIL:-60}" ;;
  boot-log)    adapter_boot_log ;;
  load)        adapter_load ;;
  served-name) stack_served_name ;;

  test)
    [ -f "$STACK_SELF_DIR/test.sh" ] \
      || die "stacks/$STACK_ID/ 没有 test.sh(冒烟测试是可选的,但强烈建议有)"
    stack_assert_served_name
    scp -q -i "$STACK_SSH_KEY" -o StrictHostKeyChecking=no \
        "$STACK_SELF_DIR/test.sh" "$STACK_SSH_USER@$STACK_HEAD:/home/$STACK_SSH_USER/${STACK_ID}-test.sh"
    # 身份从注册表注入 —— test.sh 里不再写死 model 名/端口/思考 kwarg。
    sshx "$STACK_HEAD" \
      "URL=http://localhost:$STACK_PORT/v1 BASE=http://localhost:$STACK_PORT \
       MODEL='$STACK_MODEL' THINK_KWARG='${STACK_THINK_KWARG:-}' \
       THINK_OFF='${STACK_THINK_OFF:-}' COT_FIELD='${STACK_COT_FIELD:-}' \
       bash /home/$STACK_SSH_USER/${STACK_ID}-test.sh"
    ;;

  info)
    echo "id          : $STACK_ID$([ "$STACK_ID" = "$(primary_stack)" ] && echo '   ← 当前主力栈')"
    echo "name        : $STACK_NAME"
    echo "runtime     : $STACK_RUNTIME (${STACK_NODES} 节点)"
    echo "endpoint    : $STACK_HEAD:$STACK_PORT"
    echo "served name : $STACK_MODEL"
    echo "engine      : ${STACK_ENGINE:-?}"
    echo "思考 kwarg  : ${STACK_THINK_KWARG:-(关不掉)}    CoT 字段: ${STACK_COT_FIELD:-?}"
    echo "关思考       : ${STACK_THINK_OFF:-(本栈无法关闭)}"
    echo "recipe      : stacks/$STACK_ID/recipe.yaml"
    echo "benchmark   : ${STACK_BENCH:-(未测)}"
    ;;

  *) die "未知动词 '$VERB'" ;;
esac
