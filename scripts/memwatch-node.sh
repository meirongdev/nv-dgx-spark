#!/usr/bin/env bash
# ============================================================
# memwatch-node.sh —— 把内存看门狗装成栈 head 上的 systemd 服务
#                     (make memwatch-install / memwatch-status / memwatch-reset / memwatch-uninstall)
#
# 为什么:看门狗原先跑在操作机(Mac)的 tmux 里,全程经 Tailscale DERP 看节点。
# 2026-10-27 实测 Mac → S2 断了 40+ 分钟 —— S2 本身好好的,S1 ↔ S2 的 200G 线一包没丢 ——
# 看门狗那段时间对 S2 一直 "unreachable (skip)",也就是没人守;Mac 一睡眠整条防线就没了。
# 驻留到 head 上之后:本机内存直接读、停机动作本机执行、对端走 200G(STACK_NODE_IC_MAP),
# **不再经过 Tailscale**。逻辑还是同一份 scripts/mem-watch.sh(WATCH_ON_NODE 打开驻留形态)。
#
# 用法(在操作机上跑;不给 id 就是 stacks/PRIMARY):
#   scripts/memwatch-node.sh install   [id]   # 部署 + enable + restart,并读回启动横幅
#   scripts/memwatch-node.sh status    [id]   # 服务状态 + 副本是否落后于仓库 + 节点视角 available%
#   scripts/memwatch-node.sh reset     [id]   # 清除节点上的已触发状态(重新武装)
#   scripts/memwatch-node.sh uninstall [id]   # disable + stop(文件和日志留着)
#
# ⚠️ 节点上跑的是**副本**。改了 scripts/mem-watch.sh 或 stack.env 之后,那个进程还在跑旧
#    逻辑 —— "git log 说修好了,不代表修之前起的守护进程也修好了"(AGENTS.md 硬规则 #10)。重跑 install;
#    status 会比对 sha256 把落后的文件报出来。
# ============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/stacks/_lib/common.sh"

ACTION="${1:?用法: memwatch-node.sh install|status|reset|uninstall [stack-id]}"
load_stack "${2:-}"
ID="$STACK_ID"; HEAD="$STACK_HEAD"
NODE_DIR="${MEMWATCH_NODE_DIR:-/home/$STACK_SSH_USER/dgx-memwatch}"
UNIT="dgx-memwatch@$ID"
# mem-watch.sh 靠 ../stacks/_lib/common.sh 找注册表,所以按仓库里的相对路径原样放。
FILES="scripts/mem-watch.sh stacks/_lib/common.sh stacks/$ID/stack.env"
# 节点上以驻留形态跑 mem-watch.sh 的前缀(读每实例 env:WATCH_ON_NODE / WATCH_LOG / 覆盖)
ON_NODE_RUN="set -a; . '$NODE_DIR/$ID.env'; set +a; bash '$NODE_DIR/scripts/mem-watch.sh'"

installed(){ sshx "$HEAD" "test -f '$NODE_DIR/$ID.env'" 2>/dev/null; }

install_(){
  echo "=== $UNIT → $STACK_SSH_USER@$HEAD:$NODE_DIR ==="
  sshx "$HEAD" 'sudo -n true' 2>/dev/null || die "$HEAD 上 sudo 要密码(或 ssh 不通)—— 装不了 systemd 单元"

  # 1. 文件
  # macOS 的 bsdtar 默认把 xattr / AppleDouble(._*)一起打包:GNU tar 解包时刷警告,
  # 还会在节点上留下 ._mem-watch.sh 这种垃圾(2026-10-27 首装实测)。
  ( cd "$REPO" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -cf - $FILES ) \
    | sshx "$HEAD" "mkdir -p '$NODE_DIR' && tar xf - -C '$NODE_DIR' && find '$NODE_DIR' -name '._*' -delete" \
    || die "拷文件到 $HEAD 失败"

  # 2. 每实例环境。阈值**不在这里**,在 stack.env(注册表);只有 make 命令行上显式给了
  #    WATCH_* 的才落进来,并打印 —— 否则那个覆盖会被静默丢掉。
  local v
  for v in WATCH_WARN_PCT WATCH_CRIT_PCT WATCH_CRIT_CONSEC WATCH_INTERVAL; do
    [ -n "${!v:-}" ] && echo "  ⚠️ 覆盖注册表:$v=${!v}(写进 $NODE_DIR/$ID.env)"
  done
  {
    echo "WATCH_ON_NODE=$HEAD"
    echo "WATCH_LOG=$NODE_DIR/$ID.log"
    # 必须是 if,不能是 `[ ] && echo`:最后一个变量没设时那一句返回 1,而 common.sh 开着
    # pipefail —— 文件明明写好了,整条管道却判失败(2026-10-27 首装就死在这)。
    for v in WATCH_WARN_PCT WATCH_CRIT_PCT WATCH_CRIT_CONSEC WATCH_INTERVAL; do
      if [ -n "${!v:-}" ]; then echo "$v=${!v}"; fi
    done
  } | sshx "$HEAD" "cat > '$NODE_DIR/$ID.env'" || die "写 $NODE_DIR/$ID.env 失败"

  # 3. 先用节点视角读一遍。读到的已经在 crit 线以下 = 一装上就会把栈停掉(glm53 在默认
  #    阈值下就是这样,它的余量只有 1.8–2.0%)—— 那是要人决定的事,不是安装脚本。
  # ⚠️ 读不到 ≠ 读到了没问题:ssh 失败时 once 是空的,下面的 ≤crit 判断会因为"没有一行"
  #    而放行 —— 这道闸就成了摆设。所以失败必须当场停。
  local once crit
  once="$(sshx "$HEAD" "$ON_NODE_RUN --once '$ID'")" && echo "$once" | grep -q 'available=' \
    || die "没从 $HEAD 读到节点视角的 available%(ssh 失败?)—— 不能在不知道余量的情况下装"
  crit="$(sshx "$HEAD" "$ON_NODE_RUN --config '$ID'" | awk -F= '$1=="CRIT_PCT"{print $2}')"
  [ -n "$crit" ] || die "没从 $HEAD 读到 CRIT_PCT(ssh 失败?)"
  echo "$once" | sed 's/^/  节点视角  /'
  echo "$once" | grep -q 'available=N/A' \
    && die "节点视角下有节点读不到(见上)—— 查 STACK_NODE_IC_MAP 和 $HEAD → 对端的 ssh"
  if [ -z "${FORCE:-}" ] && echo "$once" | awk -v c="$crit" -F'available=' '/available=/{sub(/%.*/,"",$2); if ($2+0 <= c+0) bad=1} END{exit !bad}'; then
    die "有节点已经 ≤ crit ${crit}% —— 装上就会停栈。先看阈值(stacks/$ID/stack.env),确定要装再加 FORCE=1"
  fi

  # 4. 单元模板(所有栈共用,实例名 = 栈 id)
  sshx "$HEAD" "sudo tee /etc/systemd/system/dgx-memwatch@.service >/dev/null" <<EOF || die "写单元文件失败"
# 由 nv-dgx-spark scripts/memwatch-node.sh 生成 —— 改仓库,别改这里。
[Unit]
Description=DGX host-memory watchdog for stack %i (nv-dgx-spark scripts/mem-watch.sh)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$STACK_SSH_USER
EnvironmentFile=$NODE_DIR/%i.env
ExecStart=/bin/bash $NODE_DIR/scripts/mem-watch.sh %i
Restart=on-failure
RestartSec=30
# exit 3 = 配置错(停不下这个栈):重试没有意义,停在 failed,status 一眼看得见。
# exit 4 = 对端暂时读不到(断电后晚起几分钟):重试。
RestartPreventExitStatus=3

[Install]
WantedBy=multi-user.target
EOF

  # 5. restart 而不是 start:已经在跑的旧副本必须换成新逻辑。
  local before
  before="$(sshx "$HEAD" "if [ -f '$NODE_DIR/$ID.log' ]; then wc -l < '$NODE_DIR/$ID.log'; else echo 0; fi" | tr -d '[:space:]')"
  sshx "$HEAD" "sudo systemctl daemon-reload && sudo systemctl enable '$UNIT' 2>/dev/null && sudo systemctl restart '$UNIT'" \
    || die "systemctl enable/restart $UNIT 失败"

  # 6. 读回横幅 —— 它到底在守什么,以它为准,不以本脚本以为的为准。
  sleep 10
  echo "--- 启动横幅($HEAD:$NODE_DIR/$ID.log 新增)---"
  sshx "$HEAD" "tail -n +$((before + 1)) '$NODE_DIR/$ID.log'"
  if [ "$(sshx "$HEAD" "systemctl is-active '$UNIT'")" != active ]; then
    sshx "$HEAD" "sudo journalctl -u '$UNIT' -n 20 --no-pager"
    die "$UNIT 没在跑(见上)"
  fi
  echo "✅ $UNIT active on $HEAD。操作机上如果还有 tmux 里的旧实例,现在可以停了。"
}

status_(){
  echo "=== $UNIT @ $HEAD ==="
  # **一次** ssh 取全。Mac → head 走 Tailscale DERP:2026-10-27 实测单次 5 s 起、偶尔被
  # reset。逐项 ssh 不只慢(一次 status 跑了 5 分钟),还会把"这一次没连上"(远端 hash 为空)
  # 误报成"副本落后于仓库" —— 分不清"不一致"和"根本没读到"。远端脚本最后 exit 0,
  # 所以 sshx 非 0 只可能是连接本身的问题。
  local out
  out="$(sshx "$HEAD" "
    test -f '$NODE_DIR/$ID.env' || { echo NOT_INSTALLED; exit 0; }
    printf 'active=%s enabled=%s since=%s\n' \"\$(systemctl is-active '$UNIT')\" \"\$(systemctl is-enabled '$UNIT' 2>/dev/null)\" \"\$(systemctl show -p ActiveEnterTimestamp --value '$UNIT')\"
    cd '$NODE_DIR' && for f in $FILES; do printf 'HASH %s %s\n' \"\$(sha256sum \"\$f\" 2>/dev/null | cut -c1-64)\" \"\$f\"; done
    echo '--- 节点视角 available%(对端经 200G)---'
    ( $ON_NODE_RUN --once '$ID' )
    echo '--- 最近日志 ---'
    tail -n 8 '$NODE_DIR/$ID.log' 2>/dev/null
    exit 0
  ")" || { echo "⚠️ ssh 到 $HEAD 没成功 —— 这说明不了看门狗的状态,只说明这一次没连上(Mac → head 走 Tailscale),重试"; return 2; }
  [ "$out" = NOT_INSTALLED ] && { echo "未安装(make memwatch-install STACK=$ID)"; return 1; }
  printf '%s\n' "$out" | sed -n '1p'
  local f l r stale=0
  for f in $FILES; do
    l="$(shasum -a 256 "$REPO/$f" | cut -c1-64)"
    r="$(printf '%s\n' "$out" | awk -v f="$f" '$1=="HASH" && $3==f {print $2}')"
    if [ -z "$r" ]; then echo "⚠️ 节点上没有 $f"; stale=1
    elif [ "$l" != "$r" ]; then echo "⚠️ 节点上的副本落后于仓库:$f"; stale=1
    fi
  done
  [ "$stale" = 0 ] && echo "副本与仓库一致" || echo "   → 重跑 make memwatch-install STACK=$ID(进程在跑旧逻辑)"
  printf '%s\n' "$out" | sed '1d' | grep -v '^HASH '
}

reset_(){
  installed || { echo "$UNIT 未安装,节点上没有状态要清"; return 0; }
  sshx "$HEAD" "$ON_NODE_RUN --reset '$ID'"
}

uninstall_(){
  installed || { echo "$UNIT 未安装"; return 0; }
  sshx "$HEAD" "sudo systemctl disable --now '$UNIT'" && echo "$UNIT 已停用(文件和日志留在 $HEAD:$NODE_DIR)"
}

case "$ACTION" in
  install)   install_ ;;
  status)    status_ ;;
  reset)     reset_ ;;
  uninstall) uninstall_ ;;
  *) die "未知动作 '$ACTION'(install|status|reset|uninstall)" ;;
esac
