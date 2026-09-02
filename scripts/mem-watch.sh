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
#   (make memwatch-reset)才会解除 —— 引擎只会在你 `make v4flash-run` 时回来,
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

WATCH_NODES="${WATCH_NODES:-100.97.87.120 100.67.164.92}"   # S1 head, S2 worker(tailnet)
SSH_USER="${WATCH_SSH_USER:-admin}"
SSH_KEY="${WATCH_SSH_KEY:-$HOME/.ssh/vgio}"
INTERVAL="${WATCH_INTERVAL:-10}"            # 两次轮询间隔(秒)
WARN_PCT="${WATCH_WARN_PCT:-8}"
CRIT_PCT="${WATCH_CRIT_PCT:-5}"
CRIT_CONSEC="${WATCH_CRIT_CONSEC:-2}"       # 连续多少次低于临界才动作
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/dgx-spark.yaml}"
# ⚠️ 看门狗必须知道**当前主力栈**是哪一个,否则它会静默地什么都不保护:
# 巡检照跑、日志照记,但 scale 的是一组不存在的 deploy。切换主力栈时,这三个
# 值(NS / DEPLOYS / STACK)必须一起改 —— Makefile 的 memwatch 目标已按
# MEMWATCH_STACK 统一注入,正常情况下改 Makefile 顶部那一个变量即可。
STACK="${WATCH_STACK:-v4flash}"                                  # 仅用于日志与提示文案
NS="${WATCH_NS:-$STACK}"
DEPLOYS="${WATCH_DEPLOYS:-v4flash-worker v4flash-leader}"        # ⚠️ 两个 rank 必须一起
STATE="${WATCH_STATE:-/tmp/.${STACK}-memwatch-fired}"
LOGFILE="${WATCH_LOG:-${TMPDIR:-/tmp}/${STACK}-memwatch.log}"
NOTIFY="${WATCH_NOTIFY:-0}"

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
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy \
      -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null \
    | tr ' ' '\n' | awk '{s+=$1} END{print s+0}'
}

# --- 触发自救:两个 rank 一起 scale 到 0 ---
scale_down(){
  local who="$1" pct="$2"
  log "CRITICAL: $who available=${pct}% < ${CRIT_PCT}% sustained — scaling $STACK to 0"
  # shellcheck disable=SC2086  # DEPLOYS 是有意分词的 deploy 名列表
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" scale deploy $DEPLOYS --replicas=0 \
    && { log "scaled both ranks to 0 (no zombie TP group). engine down."; }
  printf 'fired=%s at=%s node=%s avail_pct=%s\n' "$who" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$who" "$pct" > "$STATE"
  log "state written: $STATE  (reset with: make memwatch-reset)"
  notify "dgx mem-watch fired: $who avail=${pct}% — $STACK scaled to 0"
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
  --help|-h)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0
    ;;
  loop) ;;
  *) err "unknown arg: $1"; exit 2 ;;
esac

log "=== mem-watch starting: stack=$STACK ns=$NS deploys=[$DEPLOYS] nodes=[$WATCH_NODES] interval=${INTERVAL}s warn=${WARN_PCT}% crit=${CRIT_PCT}% x${CRIT_CONSEC} ==="

# ⚠️ 最重要的一条自检:确认要 scale 的 deploy **真的存在**。指错栈的后果是
# 看门狗照常巡检、照常记日志,却在真要动手时 scale 一组不存在的对象 —— 一道
# 静默失效的防线比没有防线更危险。宁可现在就不启动。
for d in $DEPLOYS; do
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy "$d" >/dev/null 2>&1 || {
    err "deploy '$d' 不存在于 namespace '$NS' —— 看门狗会保护不到任何东西。"
    err "切换主力栈后请同步 Makefile 顶部的 MEMWATCH_STACK(或设 WATCH_STACK/WATCH_NS/WATCH_DEPLOYS)。"
    exit 3
  }
done

[ -f "$STATE" ] && log "note: state present (previously armed) — will hold; reset with: make memwatch-reset"
if [ "$(engine_running)" -eq 0 ]; then log "note: $STACK currently scaled to 0; nothing to guard until you start it"; fi

while :; do
  if [ "$(engine_running)" -gt 0 ]; then
    tick && : || { err "tick failed early"; }
  fi
  sleep "$INTERVAL"
done
