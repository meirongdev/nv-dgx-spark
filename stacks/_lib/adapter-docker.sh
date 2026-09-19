#!/usr/bin/env bash
# ============================================================
# 运行时适配器:docker(glm53 / qwen38un / qwen38)
#
# 三个 docker 栈的形态并不相同 —— 一个跑上游编排器(glm53 的 start.sh)、
# 一个跑我们的包装脚本(qwen38un 的 launch.sh)、一个是裸 docker run(qwen38)。
# 差异全部用 stack.env 的三个变量表达,适配器本身不认识任何一个栈:
#   STACK_START_CMD / STACK_STOP_CMD / STACK_STATUS_CMD
#
# ⚠️ STACK_TMUX=1 的栈**必须**走 tmux:start.sh 这类长时编排器(镜像自检 →
#    起容器 → wait_for_health → warmup)跑几分钟,而 SSH 走 DERP 中继会掉线,
#    掉一次就把它打断在半路,可能留下半启动的容器。
# ============================================================

_remote_launch(){ echo "/home/$STACK_SSH_USER/${STACK_ID}-launch.sh"; }
_remote_bootlog(){ echo "/home/$STACK_SSH_USER/${STACK_ID}-start.log"; }

adapter_is_running(){   # rc=0 表示在跑
  [ -n "${STACK_CONTAINERS:-}" ] || return 1
  sshx "$STACK_HEAD" \
    "for c in $STACK_CONTAINERS; do docker ps --filter name=\$c --format '{{.Names}}' | grep -q . && exit 0; done; exit 1"
}

adapter_start(){
  # 本栈自带 launch.sh 就先送过去。⚠️ 所有定制固定在那个脚本里,不穿越
  # make → ssh → tmux → bash 四层引号 —— 2026-09-19 实测带空格的变量会在
  # 中途断掉,而失败信息完全不提「你的变量没生效」。
  local cmd="$STACK_START_CMD"
  if [ -f "$STACK_SELF_DIR/launch.sh" ]; then
    scp -q -i "$STACK_SSH_KEY" -o StrictHostKeyChecking=no \
        "$STACK_SELF_DIR/launch.sh" "$STACK_SSH_USER@$STACK_HEAD:$(_remote_launch)" \
      || die "launch.sh 送不过去"
  fi
  if [ "${STACK_TMUX:-0}" = "1" ]; then
    local sess="${STACK_ID}-start" log; log=$(_remote_bootlog)
    sshx "$STACK_HEAD" \
      "tmux kill-session -t $sess 2>/dev/null; \
       tmux new-session -d -s $sess '$cmd 2>&1 | tee $log'"
    echo "  已在 $STACK_HEAD 的 tmux '$sess' 里启动"
    echo "  跟进: make boot-log STACK=$STACK_ID   状态: make status STACK=$STACK_ID"
  else
    sshx "$STACK_HEAD" "$cmd"
    echo "  加载约 ${STACK_LOAD_TIME:-未知};poll: make status STACK=$STACK_ID"
  fi
}

adapter_stop(){
  sshx "$STACK_HEAD" "$STACK_STOP_CMD"
}

adapter_restart(){
  # ⚠️ 双节点 docker 栈(glm53)同样绝不单独重建一个 rank —— 这是 TP=2 的
  #    固有性质,与引擎和运行时都无关(gotcha #1)。STACK_STOP_CMD 成对停。
  adapter_stop; sleep 3; adapter_start
}

adapter_status(){
  sshx "$STACK_HEAD" \
    "${STACK_STATUS_CMD:+$STACK_STATUS_CMD; } \
     docker ps -a --filter name=${STACK_CONTAINERS%% *} --format '{{.Names}}  {{.Status}}'; \
     echo '--- /v1/models ---'; \
     curl -s http://localhost:$STACK_PORT/v1/models | python3 -m json.tool 2>/dev/null \
       || echo 'not serving yet'; \
     echo '--- host mem ---'; free -h | head -2"
}

adapter_logs(){
  local which="${1:-head}" tail="${2:-80}"
  if [ "$which" = "worker" ]; then
    [ -n "${STACK_WORKER_CONTAINER:-}" ] \
      || { echo "本栈是单节点,没有 worker(STACK_NODES=$STACK_NODES)"; return 0; }
    # worker 容器在 S2 上,从 head 经 200G 内网跳过去
    sshx "$STACK_HEAD" \
      "ssh -o BatchMode=yes ${STACK_WORKER_IP} 'docker logs --tail=$tail $STACK_WORKER_CONTAINER'"
  else
    sshx "$STACK_HEAD" "docker logs --tail=$tail ${STACK_CONTAINERS%% *}"
  fi
}

adapter_load(){
  sshx "$STACK_HEAD" \
    "curl -s http://localhost:$STACK_PORT/metrics 2>/dev/null \
       | grep -E 'num_requests_(running|waiting)\{|kv_cache_usage' | grep -v '^#' \
       || echo '(本引擎未暴露 vLLM 风格的 /metrics)'; \
     echo '--- client IPs on :$STACK_PORT ---'; \
     ss -tn | grep ':$STACK_PORT' | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -rn"
}

adapter_boot_log(){
  sshx "$STACK_HEAD" \
    "tail -40 $(_remote_bootlog) 2>/dev/null | tr -d '\r' || echo 'no boot log yet'"
}
