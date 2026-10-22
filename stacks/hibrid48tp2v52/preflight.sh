#!/usr/bin/env bash
# hibrid48tp2v52 的专属闸门(与 hibrid48tp2 同形,读 STACK_DIR)(通用 preflight 之后跑,非 0 退出则起栈失败)。
# 通用层已查:两台的权重 28 分片 / 两台的镜像 / 节点互斥(hibrid48tp2、qwen38un、hibrid48、glm53…)。
# 这里只查"双机 kit 才有"的前提 —— 前三条拦,后两条只警告。
#
# 钩子契约:被 preflight_run 在子 shell 里 source,STACK_* 已加载,sshx 可用。
set -uo pipefail
KIT="$STACK_DIR"
W="$STACK_WORKER_IP"

# --- 1. cluster.env 在 head 上(没有它 run.sh 会去跑交互式 setup.sh,在 tmux 里卡住)
sshx "$STACK_HEAD" "test -s $KIT/cluster.env" \
  || { echo "ABORT: $STACK_HEAD:$KIT/cluster.env 不存在 —— 手写值见 stacks/$STACK_ID/stack.env"; exit 1; }

# --- 2. head → worker 免密 ssh(kit 的 ssh_w 用 BatchMode;不通则 rank1 起不来)
sshx "$STACK_HEAD" "ssh -o BatchMode=yes -o ConnectTimeout=8 $W true" \
  || { echo "ABORT: $STACK_HEAD 免密 ssh 不到 worker $W —— kit 起不来 rank1"; exit 1; }

# --- 3. 两台都有 /dev/infiniband —— 没有的话 NCCL 静默走 TCP,每步慢 ~2×,
#        服务照常、没有报错(上游 README "The RDMA part")。这正是本仓库最怕的
#        "看起来正常、其实错了"那一类,所以拦,而不是警告。
for h in $STACK_GPU_NODES; do
  sshx "$h" "test -d /dev/infiniband" \
    || { echo "ABORT: $h 没有 /dev/infiniband —— NCCL 会静默回落 TCP(慢 ~2×)"; exit 1; }
done

# --- 4. vm.compaction_proactiveness=0(两台)—— 上游实测默认 20 下 ~10% 吞吐损失 +
#        周期性 4-5 s 卡顿;持久化在 /etc/sysctl.d/99-myllmbox-compaction.conf。只警告。
for h in $STACK_GPU_NODES; do
  cp=$(sshx "$h" "cat /proc/sys/vm/compaction_proactiveness 2>/dev/null" || echo "?")
  [ "$cp" = "0" ] || echo "  ⚠️ $h vm.compaction_proactiveness=$cp (应为 0) —— 预期 ~10% 吞吐损失"
done

# --- 5. 线上 recipe.yaml 与本仓库副本一致(本仓库的账才算数)。只警告。
local_sum=$(shasum -a 256 "$STACK_SELF_DIR/recipe.yaml" | cut -d' ' -f1)
remote_sum=$(sshx "$STACK_HEAD" "sha256sum $KIT/recipe.yaml 2>/dev/null | cut -d' ' -f1")
[ "$local_sum" = "$remote_sum" ] \
  || echo "  ⚠️ $STACK_HEAD:$KIT/recipe.yaml 与 stacks/$STACK_ID/recipe.yaml 不一致 —— 先同步再信任本仓库的记录"

echo "  双机 kit 闸门 OK(cluster.env / head→worker ssh / 两台 RDMA)"
exit 0
