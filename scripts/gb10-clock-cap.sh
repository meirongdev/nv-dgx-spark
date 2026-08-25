#!/usr/bin/env bash
# ============================================================
# gb10-clock-cap.sh — GB10 GPU 时钟上限(能效优化)
#
# 为什么(2026-08-25 双机 A/B 实测,见 docs/gb10-tuning-cn.md):
#   GB10 空载就把 SM 频率顶在 ~2400-2500 MHz(max 3003),而 V4-Flash 的 decode
#   受限于 LPDDR5X 带宽而非 SM 频率 —— 于是把频率上限压到 2200 MHz 几乎不要钱:
#     decode   配对差 +0.9%,95%CI [-1.9%, +3.7%] → 无法与 0 区分(n=11 交错配对)
#     prefill  -3.7%(8655 token 唯一前缀,击穿 prefix cache)
#     功耗     双机 GPU rail 86.2W → 55.2W = -36%
#   ⚠️ nvidia-smi 的 power.draw 只覆盖真实整机功耗的一小部分(论坛实测 12-27%),
#      墙插口上的实际节省远小于 36% —— 同行 wall 实测 2200 档约 -17%。
#
# ⚠️ 三个必须知道的点:
#   1. **两台必须对称**。TP=2 是锁步的,只压一台 = 全部代价 + 一半收益。
#   2. **-lgc 重启即失效**,所以有 `install` 子命令装 systemd 单元。
#   3. **nvidia-smi 没有任何字段能告诉你锁是否生效** ——
#      `Applications Clocks Setting` 恒为 Not Active、`clocks.max.sm` 恒为 3003。
#      唯一可靠的检测是**有负载时**读 `clocks.current.sm`,即本脚本的 `verify`。
#      (锁稳定一段时间后空载读数也会跟随上限,但刚加锁时仍显示旧值,不能当判据。)
#
# 用法:
#   scripts/gb10-clock-cap.sh apply [MHZ]   # 两节点加锁(默认 2200)
#   scripts/gb10-clock-cap.sh reset         # 两节点解锁(-rgc)
#   scripts/gb10-clock-cap.sh status        # systemd 单元 + 空载频率(注意:测不出锁)
#   scripts/gb10-clock-cap.sh verify        # 发真实生成,采样两节点负载期频率 ← 真正的判据
#   scripts/gb10-clock-cap.sh install [MHZ] # 装并启用 systemd 单元(重启后仍生效)
#   scripts/gb10-clock-cap.sh uninstall     # 停用并删除单元 + 解锁
# 环境变量:CAP_HOSTS / CAP_MHZ / CAP_SSH_USER / CAP_SSH_KEY / CAP_HEAD / CAP_PORT
# ============================================================
set -uo pipefail

HOSTS="${CAP_HOSTS:-100.97.87.120 100.67.164.92}"
HEAD="${CAP_HEAD:-100.97.87.120}"          # 只有 head 暴露 OpenAI API
PORT="${CAP_PORT:-8000}"
SSH_USER="${CAP_SSH_USER:-admin}"
SSH_KEY="${CAP_SSH_KEY:-$HOME/.ssh/vgio}"
MHZ="${CAP_MHZ:-2200}"
UNIT=gb10-clock-cap.service

sshx(){ ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SSH_USER@$1" "${@:2}"; }

cmd_apply(){
  local mhz="${1:-$MHZ}"
  for h in $HOSTS; do
    printf '%-16s ' "$h"
    sshx "$h" "sudo nvidia-smi -i 0 -lgc 0,$mhz 2>&1 | head -1"
  done
  echo "→ 已加锁 ${mhz} MHz。这是运行时设置,重启失效;要持久化用 install。"
  echo "→ 立刻验证:scripts/gb10-clock-cap.sh verify"
}

cmd_reset(){
  for h in $HOSTS; do
    printf '%-16s ' "$h"
    sshx "$h" 'sudo nvidia-smi -i 0 -rgc 2>&1 | head -1'
  done
  echo "→ 已解锁。注意:若 systemd 单元还 enabled,下次重启会再加锁(用 uninstall 彻底移除)。"
}

cmd_status(){
  for h in $HOSTS; do
    echo "=== $h ==="
    sshx "$h" "systemctl is-enabled $UNIT 2>/dev/null | sed 's/^/  unit enabled: /' || echo '  unit: 未安装'
      systemctl is-active $UNIT 2>/dev/null | sed 's/^/  unit active : /'
      nvidia-smi --query-gpu=clocks.current.sm,clocks.max.sm,power.draw --format=csv,noheader | sed 's/^/  idle clk|max|pw: /'"
  done
  echo "⚠️ 上面不是可靠判据:没有任何显式'已加锁'标志位(clocks.max.sm 恒 3003、"
  echo "   Applications Clocks Setting 恒 Not Active),且刚加锁时空载读数仍显示旧值。用 verify。"
}

cmd_verify(){
  local script=/tmp/.gb10_cap_verify.sh
  # 采样必须在两节点同时进行,且要有真实负载 —— 所以让 head 自己去驱动 S2。
  cat > /tmp/.gb10_cap_verify.local <<'SH'
#!/bin/bash
set +e
PEER="${PEER:-192.168.200.102}"; PORT="${PORT:-8000}"
nvidia-smi --query-gpu=clocks.current.sm --format=csv,noheader,nounits -lms 400 > /tmp/.cap_v1 2>/dev/null &
P=$!
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER" \
  'nohup nvidia-smi --query-gpu=clocks.current.sm --format=csv,noheader,nounits -lms 400 > /tmp/.cap_v2 2>/dev/null & echo $! > /tmp/.cap_v2.pid'
python3 -c "
import json
print(json.dumps({'model':'deepseek-v4-flash','messages':[{'role':'user','content':'Explain tensor parallelism in distributed inference.'}],'max_tokens':300,'min_tokens':300,'temperature':0}))" > /tmp/.cap_pl.json
curl -s -m 120 "http://localhost:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d @/tmp/.cap_pl.json \
  | python3 -c 'import sys,json;print("  负载:生成",json.load(sys.stdin)["usage"]["completion_tokens"],"token")' 2>/dev/null \
  || echo "  !! 生成失败(引擎没在跑?)"
kill $P 2>/dev/null
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER" 'kill $(cat /tmp/.cap_v2.pid) 2>/dev/null'
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER:/tmp/.cap_v2" /tmp/.cap_v2 2>/dev/null
python3 - <<'PY'
for tag,f in (("head/rank0","/tmp/.cap_v1"),("peer/rank1","/tmp/.cap_v2")):
    try: v=[int(x) for x in open(f).read().split() if x.strip().isdigit()]
    except OSError: v=[]
    print(f"  {tag}: max={max(v)} mean={sum(v)/len(v):.0f} n={len(v)}" if v else f"  {tag}: 无采样")
PY
SH
  scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/.gb10_cap_verify.local "$SSH_USER@$HEAD:$script"
  sshx "$HEAD" "PORT=$PORT bash $script"
  echo "→ 判据:负载期 mean/max 若明显低于 ~2400 且贴住你设的上限,锁生效。"
  echo "  (GB10 按离散档位吸附,设 2200 实测约落在 2177-2190。)"
}

cmd_install(){
  local mhz="${1:-$MHZ}" tmp=/tmp/.gb10-clock-cap.service
  cat > "$tmp" <<EOF
[Unit]
# GB10 GPU 时钟上限 —— 能效优化。依据与实测数据:docs/gb10-tuning-cn.md
# ⚠️ 两台必须对称(TP=2 锁步);⚠️ nvidia-smi 无字段可报告锁是否生效,
#    验证只能用 \`make clock-cap-verify\`(有负载时读 clocks.current.sm)。
Description=GB10 GPU clock cap (${mhz} MHz) for energy efficiency
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -i 0 -lgc 0,${mhz}
ExecStop=/usr/bin/nvidia-smi -i 0 -rgc

[Install]
WantedBy=multi-user.target
EOF
  for h in $HOSTS; do
    echo "=== $h ==="
    scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no "$tmp" "$SSH_USER@$h:$tmp"
    sshx "$h" "sudo install -m 0644 $tmp /etc/systemd/system/$UNIT \
      && sudo systemctl daemon-reload \
      && sudo systemctl enable --now $UNIT \
      && echo '  installed+enabled' \
      && systemctl is-active $UNIT | sed 's/^/  active: /'"
  done
  echo "→ 装好了。重启后仍生效。验证:scripts/gb10-clock-cap.sh verify"
}

cmd_uninstall(){
  for h in $HOSTS; do
    echo "=== $h ==="
    sshx "$h" "sudo systemctl disable --now $UNIT 2>/dev/null | tail -1
      sudo rm -f /etc/systemd/system/$UNIT && sudo systemctl daemon-reload
      sudo nvidia-smi -i 0 -rgc 2>&1 | head -1 | sed 's/^/  /'"
  done
  echo "→ 单元已移除、时钟已解锁。"
}

case "${1:-status}" in
  apply)     cmd_apply     "${2:-}" ;;
  reset)     cmd_reset ;;
  status)    cmd_status ;;
  verify)    cmd_verify ;;
  install)   cmd_install   "${2:-}" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
