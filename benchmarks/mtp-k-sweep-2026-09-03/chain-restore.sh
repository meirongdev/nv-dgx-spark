#!/bin/bash
# 等 k=5 测干净,然后切回 k=3 做**漂移校验**并恢复线上配置。
#   用法: bash chain-restore.sh
#
# 为什么最后要回到 k=3 再测一次:
#   k 是启动参数,几个 arm **物理上无法交错**(改一次要重启 10 分钟)。
#   而 gb10-tuning-cn.md §2 的教训正是「顺序本身会制造伪影」—— 那次扫描表里
#   两个相同的 uncap arm 差了 5.2%,最后那个最快(升温趋势),中间的 arm 被
#   系统性压低,看起来像 −5%~−11% 的代价,实际是排序伪影。
#   回到起点复测一次,是这次扫描唯一能拿到的漂移估计:
#     |k=3 复测 − k=3 基线| 就是整段实验期的漂移幅度,
#     它必须**明显小于** k 之间的差值,结论才站得住。
#
# 判据用 S1 上 arm-k5.log 里的成功标记行,不用退出码:
#   chain-next.sh 会把上一个 arm 的退出码行原样 echo 进自己的输出,
#   再按 `退出码 0` 匹配会在 k=5 还没开测时就误触发。
#   而 `===== ARM k=5 =====` 只在 mtp_arm.py 走完全部三道闸之后才打印
#   —— fail() 在那之前就 SystemExit 了。每个 k 一个标记,不会串。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HEAD=100.97.87.120
SSH="ssh -o StrictHostKeyChecking=no -i $HOME/.ssh/vgio admin@$HEAD"

echo "=== 等 k=5 测干净 ==="
deadline=$(( $(date +%s) + 3000 ))
ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if $SSH "grep -q '===== ARM k=5 =====' /home/admin/mtp-sweep/arm-k5.log" 2>/dev/null; then
    echo "  k=5 已成功产出结论"; ok=1; break
  fi
  sleep 20
done
if [ "$ok" != "1" ]; then
  echo "❌ 50 分钟内 k=5 没有产出成功标记 —— **不回切**,保持现状供人工检查。"
  echo "   (引擎此刻仍是 k=5,线上配置也是 k=5)"
  exit 5
fi

echo "=== 回切 k=3(漂移校验 + 恢复线上配置)==="
bash "$HERE/set-k.sh" 3 || { echo "❌ set-k 3 失败 —— 线上可能仍是 k=5,人工确认!"; exit 6; }
bash "$HERE/run-arm.sh" 3
rc=$?
echo
echo "=== 扫描结束。线上已恢复 k=3 ==="
echo "    ⚠️ 若某个 k 胜出,需另行改 config/ + k8s/ 两处并重启(set-k.sh <k>)。"
exit $rc
