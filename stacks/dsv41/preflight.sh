#!/usr/bin/env bash
# dsv41 的专属闸门(通用 preflight 之后跑,非 0 退出则起栈失败)。
# 通用层已查:两台的权重 39 分片 / 两台的镜像 / 节点互斥。这里只查上游 recipe 才有的前提。
#
# 钩子契约:被 preflight_run 在子 shell 里 source,STACK_* 已加载,sshx 可用。
set -uo pipefail
R="$STACK_DIR"
W="$STACK_WORKER_IP"

# --- 1. scripts/local.sh 在 head 上,且与本仓库副本一致(WORKER / PORT / CONTEXT 全在里面;
#        没有它上游 start.sh 不知道 worker 是谁,会 die;不一致则本仓库的账不算数)。拦。
local_sum=$(shasum -a 256 "$STACK_SELF_DIR/local.sh" | cut -d' ' -f1)
remote_sum=$(sshx "$STACK_HEAD" "sha256sum $R/scripts/local.sh 2>/dev/null | cut -d' ' -f1")
[ -n "$remote_sum" ] || { echo "ABORT: $STACK_HEAD:$R/scripts/local.sh 不存在 —— scp stacks/$STACK_ID/local.sh 过去"; exit 1; }
[ "$local_sum" = "$remote_sum" ] \
  || { echo "ABORT: $STACK_HEAD:$R/scripts/local.sh 与 stacks/$STACK_ID/local.sh 不一致 —— 先同步"; exit 1; }

# --- 2. head → worker 免密 ssh(start.sh 用它起 rank1、起 worker 的 memguard)。拦。
sshx "$STACK_HEAD" "ssh -o BatchMode=yes -o ConnectTimeout=8 $W true" \
  || { echo "ABORT: $STACK_HEAD 免密 ssh 不到 worker $W —— rank1 起不来"; exit 1; }

# --- 3. 两台都有 /dev/infiniband(上游 docker run 带 --device /dev/infiniband;RDMA=1 是默认)。拦。
for h in $STACK_GPU_NODES; do
  sshx "$h" "test -d /dev/infiniband" \
    || { echo "ABORT: $h 没有 /dev/infiniband"; exit 1; }
done

# --- 4. S1 的 NFS 导出(worker 经 NFS 读 head 的 HF cache;没有它 prepare/start 报
#        "cannot read the model/kit")。拦。
#        ⚠️ 不读 /proc/fs/nfs/exports:NFSv4 下它在客户端第一次挂载前是空的(2026-11-14 实测)。
sshx "$STACK_HEAD" "systemctl is-active -q nfs-server && sudo -n exportfs -v 2>/dev/null | grep -q 192.168.200.102" \
  || { echo "ABORT: $STACK_HEAD 的 nfs-server 没在跑,或没把 HF cache 导出给 192.168.200.102"; exit 1; }

# --- 5. 两台 GPU 时钟上限一致(上游:两个 rank 每层碰头两次,慢的那台定节奏)。只警告。
c1=$(sshx 100.97.87.120 "nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null; systemctl is-enabled gb10-clock-cap 2>/dev/null" | tr '\n' ' ')
c2=$(sshx 100.67.164.92 "nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null; systemctl is-enabled gb10-clock-cap 2>/dev/null" | tr '\n' ' ')
[ "$c1" = "$c2" ] || echo "  ⚠️ 两台时钟状态不同:S1[$c1] S2[$c2] —— TP=2 被慢的那台拖住(make clock-cap-status)"

echo "  dsv41 闸门 OK(local.sh 一致 / head→worker ssh / 两台 RDMA / NFS 导出)"
exit 0
