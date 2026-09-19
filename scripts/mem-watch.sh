#!/usr/bin/env bash
# ============================================================
# mem-watch.sh — 宿主机级内存看门狗(防 V4-Flash 整机 OOM)
#
# 为什么要有它(2026-08-15 实测,见 docs/auto-mitigation-cn.md §2):
#   GB10 统一内存上,vLLM 预占的 ~100GB(权重+KV)会**绕过容器 cgroup**——
#   容器 cgroup 只记 ~18GiB,节点却用了 107Gi。因此 k8s 的 resources.limits.memory
#   兜不住真正会搞崩整机的那个 100GB;只有**节点级 available 内存**看得见它。
#   本脚本轮询每台节点的 /proc/meminfo,available 掉到临界地板以下时,在节点 OOM
#   之前把 V4-Flash 两个 rank **一起 scale 到 0**(干净拆机,不产生 zombie TP 组)。
#
# 现实基线(直接影响阈值):这些节点稳态可用就只剩 ~11%(13Gi/121Gi),
#   因为 ~100GB 已被权重预占。所以阈值必须贴地板:
#     WARN_PCT=8(低于 8% 持续 CRIT_CONSEC 次 → 告警/记日志)
#     CRIT_PCT=5(低于 5% 持续 CRIT_CONSEC 次 → 自动 scale 0)
#   请按实测校准,别套通用阈值。
#
# 模型:**不自动恢复**。触发后写一个 state 文件并保持,只有显式清除/重跑
#   (make memwatch-reset)才会解除 —— 引擎只会在你 `make run STACK=v4flash` 时回来,
#   避免"scale 0 → 内存松动 → 又拉起 → 又掉"的抖动。
#
# 位置:跑在这台操作机(有 kubectl + SSH)。局限:操作机要在线;
#       节点本身不自保(见文档 §4 展望,节点内自保需另配 kubectl 到 S2)。
#
# 用法:
#   scripts/mem-watch.sh --once      # 单次打印各节点 available%(只读,验证用)
#   scripts/mem-watch.sh --reset     # 清除已触发状态(解除保持)
#   scripts/mem-watch.sh             # 常驻循环(建议放 tmux,ctrl-c 退出)
# 环境变量可覆盖:WATCH_NODES / INTERVAL / WARN_PCT / CRIT_PCT / CRIT_CONSEC /
#   WATCH_SSH_USER / WATCH_SSH_KEY / KUBECONFIG / NOTIFY=1(macOS 桌面通知)
#   WATCH_STACK / WATCH_NS / WATCH_DEPLOYS —— **换主力栈时必须一起改**,
#   否则看门狗会 scale 一组不存在的 deploy(启动自检已会挡住这种情况)。
#   正常路径是只改 Makefile 顶部的 MEMWATCH_STACK,由 make memwatch* 注入。
# ============================================================
set -u


# ============================================================
# 身份从**注册表**推导,不再是这里的一组默认值
# ============================================================
# 旧版在这里写死 WATCH_NS / WATCH_DEPLOYS / WATCH_DOCKER_* 的默认值,Makefile 那边
# 还有一段 ifeq 阶梯逐栈拼环境变量。换栈时漏改的后果是这道防线**静默失效**:
# 巡检照跑、日志照记,真要动手时 scale 一组不存在的对象。
# 现在只读 stacks/<id>/stack.env(不给 id 就是 stacks/PRIMARY)。
#
#   scripts/mem-watch.sh                 # 守当前主力栈
#   scripts/mem-watch.sh --once glm53    # 只看 glm53 那套节点的 available%
#
# 所有 WATCH_* 环境变量仍然优先于注册表 —— 回归测试(test-mem-watch.sh)靠这条打桩。
MW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_STACK_ARG=""; MW_FLAGS=""
for _a in "$@"; do case "$_a" in --*) MW_FLAGS="$MW_FLAGS $_a" ;; *) MW_STACK_ARG="$_a" ;; esac; done
# shellcheck disable=SC2086  # flags only, 有意分词
set -- $MW_FLAGS

if [ -z "${MEMWATCH_LIB_ONLY:-}" ]; then
  # shellcheck source=/dev/null
  . "$MW_HERE/../stacks/_lib/common.sh"
  set +o pipefail          # common.sh 带 pipefail,本脚本的管道不按那个语义写
  load_stack "$MW_STACK_ARG"
fi

# 注册表值 → 本脚本变量的映射。注册表没加载(lib-only)时落到历史默认值。
WATCH_NODES="${WATCH_NODES:-${STACK_MEMWATCH_NODES:-${STACK_NODES_IPS:-${STACK_HEAD:-100.97.87.120}}}}"
SSH_USER="${WATCH_SSH_USER:-${STACK_SSH_USER:-admin}}"
SSH_KEY="${WATCH_SSH_KEY:-${STACK_SSH_KEY:-$HOME/.ssh/vgio}}"
INTERVAL="${WATCH_INTERVAL:-10}"            # 两次轮询间隔(秒)
WARN_PCT="${WATCH_WARN_PCT:-8}"
CRIT_PCT="${WATCH_CRIT_PCT:-5}"
CRIT_CONSEC="${WATCH_CRIT_CONSEC:-2}"       # 连续多少次低于临界才动作
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/dgx-spark.yaml}"

STACK="${WATCH_STACK:-${STACK_ID:-unknown}}"
MODE="${WATCH_MODE:-${STACK_RUNTIME:-k8s}}"              # k8s | docker
[ "$MODE" = k3s ] && MODE=k8s                            # 注册表说 k3s,本脚本一直叫 k8s
NS="${WATCH_NS:-${STACK_NS:-$STACK}}"
DEPLOYS="${WATCH_DEPLOYS:-${STACK_DEPLOYS:-}}"           # ⚠️ 两个 rank 必须一起
STATE="${WATCH_STATE:-/tmp/.${STACK}-memwatch-fired}"
LOGFILE="${WATCH_LOG:-${TMPDIR:-/tmp}/${STACK}-memwatch.log}"
NOTIFY="${WATCH_NOTIFY:-0}"

# --- docker 形态的"拆机"动作 -------------------------------------------------
# 新增于 2026-09-19。起因:GLM-5.3-Flash EXL3 按上游配方跑在 **docker** 上,不在
# k3s 里,而在此之前本脚本唯一的动作是 `kubectl scale` —— 对 docker 栈它会
# **巡检照跑、日志照记、真要动手时什么也没停**。这正是本仓库最贵的那一类 bug:
# 防线看起来在,实际是哑的。而这两台**没有 BMC**,整机 OOM 要有人到机器跟前。
#
# 停机命令逐栈不同(`./start.sh stop` / `./stop.sh` / `docker rm -f`),
# 但都必须是**成对**停 head+worker 的那一个,理由同 gotcha #1。
DOCKER_HOST_IP="${WATCH_DOCKER_HOST:-${STACK_HEAD:-100.97.87.120}}"
DOCKER_DIR="${WATCH_DOCKER_DIR:-${STACK_DIR:-/home/admin}}"
DOCKER_CONTAINERS="${WATCH_DOCKER_CONTAINERS:-${STACK_CONTAINERS:-}}"
DOCKER_STOP="${WATCH_DOCKER_STOP:-${STACK_MEMWATCH_STOP:-${STACK_STOP_CMD:-}}}"
SSH_KEY_W="$SSH_KEY"
SSH_USER_W="$SSH_USER"
ssh_head(){ ssh -i "$SSH_KEY_W" -o StrictHostKeyChecking=no -o BatchMode=yes \
                -o ConnectTimeout=15 "$SSH_USER_W@$DOCKER_HOST_IP" "$@"; }

# 每节点各自的连续临界计数(仅单次循环内累计)+ 上次报告状态(warn 时不刷屏)
#
# ⚠️ 这里**不能用关联数组**。macOS 自带的是 bash 3.2(本机实测 3.2.57),
# `declare -A` 在它上面直接报错并静默降级成普通索引数组,于是 "100.97.87.120"
# 这样的下标被当算术求值 → 未定义变量名取 0 → **两个节点塌到同一个下标**。
#
# 后果比"计数不准"严重得多:tick() 每轮按顺序遍历两个节点,健康的那个走
# `kv_set crit 0` 会把**共享**计数清零。于是只要另一台还健康,危险那台的计数
# 永远攒不到 CRIT_CONSEC —— **看门狗根本不会触发**。而节点 OOM 恰恰是一台一台
# 来的,所以这道防线在 bash 3.2 上等于不存在(只有两台在同一轮里同时危险、
# 且危险的那台排在最后,才会侥幸触发)。
#
# 2026-09-02 发现并修复,回归测试见 scripts/test-mem-watch.sh(make memwatch-test)。
# 改用「变量名后缀」做 key→value,bash 3.2 和 5.x 行为一致。
_key(){ printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }
kv_get(){ local v="kv_$1_$(_key "$2")"; printf '%s' "${!v:-$3}"; }   # $3 = 缺省值
kv_set(){ local v="kv_$1_$(_key "$2")"; eval "$v=\$3"; }

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"; }
err(){ printf '%s %s\n' "$(date '+%F %T')" "ERROR: $*" | tee -a "$LOGFILE" >&2; }
notify(){ [ "$NOTIFY" = 1 ] && osascript -e "display notification \"$*\" with title \"dgx mem-watch\"" 2>/dev/null || true; }

# --- 读单台节点 available%,输出 0-100 整数;失败输出 N/A 并返回 1 ---
node_avail_pct(){
  local node="$1" data avail total pct kv line
  data="$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
      "$SSH_USER@$node" \
      "awk '/MemAvailable|MemTotal/{gsub(/:/,\"\",\$1); print \$1,\$2}' /proc/meminfo" 2>/dev/null)" \
    || { echo N/A; return 1; }
  avail=-1; total=-1
  while IFS=' ' read -r k v; do
    [ "$k" = MemAvailable ] && avail="$v"
    [ "$k" = MemTotal ]     && total="$v"
  done <<< "$data"
  [ -n "$avail" ] && [ "$avail" -ge 0 ] && [ -n "$total" ] && [ "$total" -gt 0 ] || { echo N/A; return 1; }
  pct=$(( avail * 100 / total ))
  [ "$pct" -gt 100 ] && pct=100
  echo "$pct"
}

# --- 检查 vLLM 当前有没有在跑(replicas 求和),返回>0 表示在跑 ---
engine_running(){
  if [ "$MODE" = docker ]; then
    # 探不到(ssh 挂了)时回 0 = 本轮不巡检,与 k8s 分支探不到时同样 fail-open。
    ssh_head "docker ps --filter name=$DOCKER_CONTAINERS --format '{{.Names}}' 2>/dev/null | wc -l" \
      2>/dev/null | tr -d '[:space:]' | awk '{print $1+0}'
    return
  fi
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy \
      -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null \
    | tr ' ' '\n' | awk '{s+=$1} END{print s+0}'
}

# --- 触发自救:两个 rank 一起停掉 ---
scale_down(){
  local who="$1" pct="$2"
  log "CRITICAL: $who available=${pct}% < ${CRIT_PCT}% sustained — stopping $STACK"
  if [ "$MODE" = docker ]; then
    # ./start.sh stop 成对停 head+worker(stop_containers),不留 zombie TP 组。
    ssh_head "cd '$DOCKER_DIR' && $DOCKER_STOP" \
      && { log "'$DOCKER_STOP' done — engine down."; } \
      || err "'$DOCKER_STOP' 失败 —— 手动介入: make $STACK-stop"
  else
    # shellcheck disable=SC2086  # DEPLOYS 是有意分词的 deploy 名列表
    kubectl --kubeconfig "$KUBECONFIG" -n "$NS" scale deploy $DEPLOYS --replicas=0 \
      && { log "scaled both ranks to 0 (no zombie TP group). engine down."; }
  fi
  printf 'fired=%s at=%s node=%s avail_pct=%s\n' "$who" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$who" "$pct" > "$STATE"
  log "state written: $STATE  (reset with: make memwatch-reset)"
  notify "dgx mem-watch fired: $who avail=${pct}% — $STACK stopped"
}

# 单次巡检全部节点;返回 0 表示健康,1 表示触发过动作
tick(){
  local fired=0 node pct n
  for node in $WATCH_NODES; do
    pct="$(node_avail_pct "$node")"
    if [ "$pct" = N/A ]; then
      kv_set crit "$node" 0                    # 探不到不算数(fail-open,遵循仓库探针哲学)
      [ "$(kv_get last "$node" x)" != down ] && log "$node: unreachable (skip)"
      kv_set last "$node" down
      continue
    fi
    if [ "$pct" -le "$CRIT_PCT" ]; then
      n=$(( $(kv_get crit "$node" 0) + 1 ))
      kv_set crit "$node" "$n"
      log "$node: available=${pct}% (crit ${n}/${CRIT_CONSEC})"
      if [ "$n" -ge "$CRIT_CONSEC" ]; then
        [ -f "$STATE" ] && { log "already fired, holding (state present): $STATE"; continue; }
        scale_down "$node" "$pct"
        fired=1
        kv_set crit "$node" 0
      fi
    elif [ "$pct" -le "$WARN_PCT" ]; then
      kv_set crit "$node" 0
      [ "$(kv_get last "$node" x)" != warn ] && log "$node: available=${pct}% (< ${WARN_PCT}% warn)"
      kv_set last "$node" warn
    else
      kv_set crit "$node" 0
      [ "$(kv_get last "$node" x)" != ok ] && log "$node: available=${pct}% (ok)"
      kv_set last "$node" ok
    fi
  done
  return $fired
}

# 只加载函数、不执行主流程 —— 给 scripts/test-mem-watch.sh 用(make memwatch-test)。
# 回归测的是「按节点各自去抖」这条:它守的是整机 OOM,而 2026-09-02 之前它是坏的。
[ -n "${MEMWATCH_LIB_ONLY:-}" ] && return 0

case "${1:-loop}" in
  --once)
    for node in $WATCH_NODES; do
      printf '%-15s available=%s%%\n' "$node" "$(node_avail_pct "$node")"
    done
    exit 0
    ;;
  --reset)
    rm -f "$STATE" && log "state cleared; watchdog re-armed"
    exit 0
    ;;
  --config)
    # 打印从注册表推导出来的身份(不出网)。用途:排查"看门狗到底在守谁",
    # 以及让 test-mem-watch.sh 能在不碰集群的情况下钉住这套映射。
    printf 'STACK=%s\nMODE=%s\nNODES=%s\nNS=%s\nDEPLOYS=%s\nDOCKER_HOST=%s\nDOCKER_DIR=%s\nDOCKER_CONTAINERS=%s\nDOCKER_STOP=%s\nSTATE=%s\n' \
      "$STACK" "$MODE" "$WATCH_NODES" "$NS" "$DEPLOYS" \
      "$DOCKER_HOST_IP" "$DOCKER_DIR" "$DOCKER_CONTAINERS" "$DOCKER_STOP" "$STATE"
    exit 0
    ;;
  --help|-h)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0
    ;;
  loop) ;;
  *) err "unknown arg: $1"; exit 2 ;;
esac

if [ "$MODE" = docker ]; then
  log "=== mem-watch starting: mode=docker stack=$STACK head=$DOCKER_HOST_IP dir=$DOCKER_DIR containers=[$DOCKER_CONTAINERS] nodes=[$WATCH_NODES] interval=${INTERVAL}s warn=${WARN_PCT}% crit=${CRIT_PCT}% x${CRIT_CONSEC} ==="
else
  log "=== mem-watch starting: mode=k8s stack=$STACK ns=$NS deploys=[$DEPLOYS] nodes=[$WATCH_NODES] interval=${INTERVAL}s warn=${WARN_PCT}% crit=${CRIT_PCT}% x${CRIT_CONSEC} ==="
fi

# ⚠️ 最重要的一条自检:确认**真要动手时动得了**。指错栈/指错形态的后果是
# 看门狗照常巡检、照常记日志,却在真要动手时对着一组不存在的对象使劲 —— 一道
# 静默失效的防线比没有防线更危险。宁可现在就不启动。
if [ "$MODE" = docker ]; then
  # docker 模式:ssh 必须通,且 start.sh 必须在、可执行。两者缺一,动手时就是空转。
  ssh_head true 2>/dev/null || {
    err "ssh 不通:$SSH_USER_W@$DOCKER_HOST_IP(key=$SSH_KEY_W) —— 看门狗动不了手。"
    exit 3
  }
  ssh_head "cd '$DOCKER_DIR' && test -x ${DOCKER_STOP%% *}" 2>/dev/null || {
    err "'$DOCKER_DIR/${DOCKER_STOP%% *}' 不存在或不可执行 —— 看门狗会保护不到任何东西。"
    err "确认 WATCH_DOCKER_DIR 指向上游 repo(或改 Makefile 顶部的 MEMWATCH_STACK)。"
    exit 3
  }
else
  for d in $DEPLOYS; do
    kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy "$d" >/dev/null 2>&1 || {
      err "deploy '$d' 不存在于 namespace '$NS' —— 看门狗会保护不到任何东西。"
      err "切换主力栈后请同步 Makefile 顶部的 MEMWATCH_STACK(或设 WATCH_STACK/WATCH_NS/WATCH_DEPLOYS)。"
      exit 3
    }
  done
fi

[ -f "$STATE" ] && log "note: state present (previously armed) — will hold; reset with: make memwatch-reset"
if [ "$(engine_running)" -eq 0 ]; then log "note: $STACK currently scaled to 0; nothing to guard until you start it"; fi

while :; do
  if [ "$(engine_running)" -gt 0 ]; then
    tick && : || { err "tick failed early"; }
  fi
  sleep "$INTERVAL"
done
