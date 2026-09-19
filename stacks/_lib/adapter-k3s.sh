#!/usr/bin/env bash
# ============================================================
# 运行时适配器:k3s(TP=2 栈 —— qwen38fn / v4flash)
#
# 适配器契约 —— 新增一种运行时 = 新增一个这样的文件,不改任何既有文件:
#   adapter_start / adapter_stop / adapter_restart / adapter_status
#   adapter_logs [worker] / adapter_is_running / adapter_load
# 读 STACK_* (由 common.sh 的 load_stack 注入),不持有任何栈身份。
#
# ⚠️ 本适配器刻意**不提供**「只重启一个 rank」的动作。TP=2 下单 rank 重启会
#    留下僵尸集合通信组,`/health` 和 `/v1/models` 照常 200 而所有生成超时
#    (gotcha #1,本仓库最贵的一条)。restart 一律成对。
# ============================================================

adapter_is_running(){   # rc=0 表示在跑
  local n
  n=$($K8S -n "$STACK_NS" get deploy -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null \
      | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')
  [ "${n:-0}" -gt 0 ]
}

adapter_start(){
  # 126 GiB 级别的加载期,热页缓存会饿死 GPU allocator(x00byte 实测),
  # 先在两台宿主机上 drop 一次。rank 脚本里还有 best-effort 兜底。
  if [ "${STACK_DROP_CACHES:-0}" = "1" ]; then
    local h
    for h in ${STACK_NODES_IPS:-$STACK_HEAD}; do
      sshx "$h" "sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" \
        && echo "  $h: page cache dropped"
    done
  fi
  $K8S -n "$STACK_NS" scale deploy $STACK_DEPLOYS --replicas=1
  echo "  加载约 ${STACK_LOAD_TIME:-未知};poll: make status STACK=$STACK_ID"
}

adapter_stop(){
  $K8S -n "$STACK_NS" scale deploy $STACK_DEPLOYS --replicas=0
}

adapter_restart(){
  # 成对重建。⚠️ 绝不单独重建一个 rank(gotcha #1)。
  $K8S -n "$STACK_NS" delete pod --all
  echo "  两个 rank 已一起重建;加载约 ${STACK_LOAD_TIME:-未知}"
}

adapter_status(){
  $K8S -n "$STACK_NS" get pods -o wide
  sshx "$STACK_HEAD" \
    "curl -s http://localhost:$STACK_PORT/v1/models | python3 -m json.tool 2>/dev/null \
     || echo 'not serving yet'"
}

adapter_logs(){
  local which="${1:-leader}" tail="${2:-60}"
  case "$which" in
    worker) $K8S -n "$STACK_NS" logs --tail="$tail" "deploy/$STACK_WORKER" ;;
    *)      $K8S -n "$STACK_NS" logs --tail="$tail" "deploy/$STACK_LEADER" ;;
  esac
}

# 谁在用引擎。「感觉变慢」通常是并发打满(max_num_seqs),不是引擎坏了 ——
# 2026-08-02 就把一个 6 路 batch 负载误判成了升级回归。
adapter_load(){
  sshx "$STACK_HEAD" \
    "curl -s http://localhost:$STACK_PORT/metrics \
       | grep -E 'num_requests_(running|waiting)\{|kv_cache_usage' | grep -v '^#'; \
     echo '--- client IPs on :$STACK_PORT ---'; \
     ss -tn | grep ':$STACK_PORT' | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -rn"
  echo '--- engine last minute ---'
  $K8S -n "$STACK_NS" logs --since=1m "deploy/$STACK_LEADER" 2>/dev/null \
    | grep 'loggers.py' | tail -3 || true
}

adapter_boot_log(){
  echo "(k3s 栈没有独立的 boot log —— 引擎日志就是启动日志)"
  adapter_logs leader 80
}
