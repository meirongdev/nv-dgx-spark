#!/bin/bash
# 把 MTP num_speculative_tokens 切到 $1,重启两个 rank,等到能服务为止。
#
# ⚠️ 这个脚本存在的唯一理由是 **TP=2 两个 rank 必须拿到同一个 k**。
# 手动改 ConfigMap 时漏掉 rank1,配置读起来完全正常 —— 而实验测的是一个
# 两侧参数不一致的引擎。这正是 docs/stack-switch-cn.md 反复讲的那类静默失败,
# 所以这里 sed 完立刻数出现次数,数不对就退出、绝不 apply。
#
# 同时遵守本仓库的成对修改约定:config/qwen38-flash-next.yaml(真相源)
# 和 k8s/qwen38fn/configmap-launch.yaml(线上执行的)一起改,不留仓库/线上分叉
# (5148382 收编过一次这种分叉)。
#
# 用法:  bash set-k.sh 4
set -euo pipefail

K="${1:?用法: set-k.sh <num_speculative_tokens>}"
[[ "$K" =~ ^[0-9]+$ ]] || { echo "k 必须是整数"; exit 2; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RECIPE="$REPO/config/qwen38-flash-next.yaml"
CM="$REPO/k8s/qwen38fn/configmap-launch.yaml"
K8S="kubectl --kubeconfig $HOME/.kube/dgx-spark.yaml"
NS=qwen38fn
HEAD=100.97.87.120
SSH_KEY="$HOME/.ssh/vgio"

echo "=== 切到 num_speculative_tokens=$K ==="

# --- 改两处 -----------------------------------------------------------------
sed -i '' -E "s/(\"num_speculative_tokens\":)[0-9]+/\1$K/g" "$RECIPE" "$CM"

# --- 数出现次数:配方 1 处,ConfigMap 2 处(rank0 + rank1),其余值 0 处 -------
n_recipe=$(grep -c "\"num_speculative_tokens\":$K" "$RECIPE" || true)
n_cm=$(grep -c "\"num_speculative_tokens\":$K" "$CM" || true)
n_other=$(grep -E "\"num_speculative_tokens\":[0-9]+" "$RECIPE" "$CM" \
          | grep -vc "\"num_speculative_tokens\":$K" || true)

echo "  config 配方   : $n_recipe 处 (期望 1)"
echo "  ConfigMap 两 rank: $n_cm 处 (期望 2)"
echo "  残留的其它 k 值 : $n_other 处 (期望 0)"
if [ "$n_recipe" -ne 1 ] || [ "$n_cm" -ne 2 ] || [ "$n_other" -ne 0 ]; then
  echo "❌ 出现次数不对 —— 可能只改到了一个 rank。**不 apply**,请人工检查。"
  exit 3
fi

# --- 上线 -------------------------------------------------------------------
$K8S apply -f "$CM"
$K8S -n $NS delete pod --all
echo "  两个 rank 已重建,126GiB 权重加载 8-11min…"

# --- 等到真的能服务(不是等 Pod Ready,是等 /v1/models 有响应)---------------
deadline=$(( $(date +%s) + 1200 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 20
  ready=$($K8S -n $NS get pods --no-headers 2>/dev/null \
          | awk '$2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')
  serving=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" admin@$HEAD \
            "curl -s -m 5 localhost:8000/v1/models | grep -c qwen38-flash-next" 2>/dev/null || echo 0)
  printf "\r  ready=%s/2  serving=%s  (%ds)" "$ready" "$serving" "$(( $(date +%s) - deadline + 1200 ))"
  if [ "$ready" = "2" ] && [ "$serving" != "0" ]; then
    echo; echo "✅ k=$K 已上线并可服务"
    exit 0
  fi
done
echo; echo "❌ 20 分钟内没能服务 —— 去看 make qwen38fn-logs"
exit 4
