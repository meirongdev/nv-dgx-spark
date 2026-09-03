#!/bin/bash
# 等上一个 arm 的测量**成功**结束,然后切到下一个 k 并测量。
#   用法: bash chain-next.sh <上一个 arm 的任务输出文件> <下一个 k>
#
# ⚠️ 为什么要等"成功"而不是等"结束":上一个 arm 若被闸门判废(外部流量污染、
# k 行为验证不符),它的数字是不能用的。这时候继续往下切,会得到一份中间缺了
# 一格的扫描 —— 而扫描的全部意义就是几个 k 之间可比。所以这里**失败就停**,
# 不自作主张往下走。
#
# 判据取 run-arm.sh 打印的退出码行,不是"日志里有没有出现数字" ——
# mtp_arm.py 在判废时也会打印前面几行 tok/s(它们是真实测量,只是被污染了),
# 靠 grep 数字会把废数据当成功。docs/stack-switch-cn.md §3 规则 2。
set -uo pipefail

PREV_OUT="${1:?用法: chain-next.sh <上一个任务的输出文件> <下一个 k>}"
NEXT_K="${2:?用法: chain-next.sh <上一个任务的输出文件> <下一个 k>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== 等上一个 arm 结束($PREV_OUT)==="
deadline=$(( $(date +%s) + 2400 ))
rc=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  line=$(grep -oE '=== arm k=[0-9]+ 退出码 [0-9]+ ===' "$PREV_OUT" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    rc=$(echo "$line" | grep -oE '[0-9]+ ===$' | grep -oE '^[0-9]+')
    echo "  上一个 arm 结束:$line"
    break
  fi
  sleep 20
done

if [ -z "$rc" ]; then
  echo "❌ 40 分钟内没等到上一个 arm 结束 —— 不切 k,人工检查。"; exit 4
fi
if [ "$rc" != "0" ]; then
  echo "❌ 上一个 arm 退出码 $rc(被闸门判废)—— **不继续扫描**。"
  echo "   先把那一格重测干净:bash run-arm.sh <那个 k>"
  exit 5
fi

echo "=== 上一个 arm 干净,切到 k=$NEXT_K ==="
bash "$HERE/set-k.sh" "$NEXT_K" || { echo "❌ set-k 失败"; exit 6; }
bash "$HERE/run-arm.sh" "$NEXT_K"
