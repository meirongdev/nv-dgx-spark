#!/bin/bash
# 等引擎就绪,然后测一个 arm。 用法: bash run-arm.sh <k>
#
# 与 set-k.sh 分开的理由:set-k.sh 只负责"把 k 换上去并起来",本脚本只负责
# "测"。两件事分开,任何一个 arm 测废了都能单独重测,不用再花 10 分钟重启。
#
# mtp_arm.py 自己会做行为验证(Δdraft_tokens/Δdrafts 必须等于 k),所以即使
# 这里等错了引擎(比如 set-k 失败、跑的还是上一个 k),也不会产出错误结论。
set -uo pipefail

K="${1:?用法: run-arm.sh <k>}"
HEAD=100.97.87.120
SSH_KEY="$HOME/.ssh/vgio"
SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY admin@$HEAD"
REMOTE=/home/admin/mtp-sweep

echo "=== 等 k=$K 的引擎就绪 ==="
deadline=$(( $(date +%s) + 1500 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if $SSH "curl -s -m 5 localhost:8000/v1/models | grep -q qwen38-flash-next" 2>/dev/null; then
    echo "  引擎已可服务"
    break
  fi
  sleep 20
done
if [ "$(date +%s)" -ge "$deadline" ]; then
  echo "❌ 25 分钟内没等到引擎可服务"; exit 4
fi

# 冷引擎首个请求会触发 Triton JIT(启动日志里那批 _qsa_*_kernel 警告),
# 且 benchmarking-cn.md 记录过"冷 + 空闲衰减 ≈30% 且无声" —— mtp_arm.py 的
# warm() 会处理,这里只需保证它确实跑到。
echo "=== 测量 arm k=$K ==="
$SSH "cd $REMOTE && URL=http://localhost:8000/v1 MODEL=qwen38-flash-next \
      THINK_KEY=enable_thinking THINKING=0 K=$K python3 mtp_arm.py 2>&1 | tee arm-k$K.log"
rc=$?
echo "=== arm k=$K 退出码 $rc ==="
exit $rc
