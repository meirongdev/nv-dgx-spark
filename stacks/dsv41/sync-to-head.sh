#!/usr/bin/env bash
# 在 **S2** 上跑:把 fetch-weights.sh 落在 S2 的东西摆到上游 recipe 要的位置。
#   1. checkpoint(196 GiB)+ Engram(189 GiB)的 HF cache 目录 → S1 同路径(200G 线,逐文件并行 rsync)
#   2. 基础镜像 nvcr.io/nvidia/pytorch:26.07-py3 → S1(docker save | docker load,同一条线)
#   3. S2 本机:Engram 两张表 hardlink 到 WORKER_ENGRAM_DIR(上游 prepare.sh 第 7 步按大小核对,
#      对上了就不再经 NFS 拷 203 GB)
#
# ⚠️ **必须在 S1 停了服务之后跑。** 上游 docs/memory-and-safety.md:在服务中的 Spark 上做大拷贝会把
#    MemAvailable 压到 memguard 线下(5.8 GB 的拷贝就触发过,issue #117)—— 2026-11-14 时 S1 只剩 3.2%。
#    所以脚本先确认 S1 上没有 GPU 栈在跑,否则拒绝。
#
# 幂等:rsync 增量;docker load 跳过已有层;cp -al 只补缺的。
set -uo pipefail

HF_HUB="${HF_HUB:-/home/admin/.cache/huggingface/hub}"
PEER="${PEER:-192.168.200.101}"
JOBS="${JOBS:-6}"
BASE_IMAGE="${BASE_IMAGE:-nvcr.io/nvidia/pytorch:26.07-py3}"
MODEL_DIR=models--Mia-AiLab--DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw
ENGRAM_DIR=models--deepseek-ai--DeepSeek-V4.1-Flash-1017
ENGRAM_REV=1bae0e1088993b9b82de08f59de5be5a34e42170
WORKER_ENGRAM_DIR="${WORKER_ENGRAM_DIR:-$HOME/.cache/dsv41-tensorfold/engram-${ENGRAM_REV:0:8}}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no"

echo "=== sync-to-head @ $(hostname) $(date '+%F %T') → $PEER ==="

# --- 0. S1 上不能有在跑的 GPU 栈 ------------------------------------------------
running=$($SSH "$PEER" "docker ps --format '{{.Names}}'" | grep -vE '^(spark-dashboard|node-exporter)$' || true)
[ -z "$running" ] || { echo "ABORT: $PEER 上还有容器在跑:$running —— 先停服务(大拷贝会压垮在线 rank 的余量)"; exit 1; }
avail=$($SSH "$PEER" "awk '/MemAvailable/ {printf \"%d\", \$2/1048576}' /proc/meminfo")
echo "S1 MemAvailable ${avail} GiB"

# --- 1. 权重 → S1 ----------------------------------------------------------------
cd "$HF_HUB" || exit 1
$SSH "$PEER" "mkdir -p $HF_HUB" || exit 1
t0=$(date +%s)
find "$MODEL_DIR" "$ENGRAM_DIR" -type f | sort | \
  xargs -P "$JOBS" -I{} rsync -aR --partial -e "$SSH -c aes128-gcm@openssh.com" {} "$PEER:$HF_HUB/" || { echo "FAIL: rsync"; exit 1; }
t1=$(date +%s)
here=$(find "$MODEL_DIR" "$ENGRAM_DIR" -type f -printf '%p %s\n' | LC_ALL=C sort | sha256sum | cut -c1-16)
there=$($SSH "$PEER" "cd $HF_HUB && find $MODEL_DIR $ENGRAM_DIR -type f -printf '%p %s\n' | LC_ALL=C sort | sha256sum | cut -c1-16")
[ "$here" = "$there" ] || { echo "FAIL: S1 的文件清单(路径+大小)与 S2 不同 ($here vs $there)"; exit 1; }
echo "权重 → S1 OK:$(du -sh "$MODEL_DIR" "$ENGRAM_DIR" | awk '{print $1}' | tr '\n' ' ')用时 $((t1 - t0)) s,路径+大小清单一致"

# --- 2. 基础镜像 → S1 --------------------------------------------------------------
want=$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE") || { echo "FAIL: S2 上没有 $BASE_IMAGE"; exit 1; }
have=$($SSH "$PEER" "docker image inspect -f '{{.Id}}' $BASE_IMAGE 2>/dev/null" || true)
if [ "$have" != "$want" ]; then
  docker save "$BASE_IMAGE" | $SSH -c aes128-gcm@openssh.com "$PEER" docker load || { echo "FAIL: docker save | load"; exit 1; }
  have=$($SSH "$PEER" "docker image inspect -f '{{.Id}}' $BASE_IMAGE")
fi
[ "$have" = "$want" ] || { echo "FAIL: S1 的 $BASE_IMAGE = $have,S2 = $want"; exit 1; }
echo "基础镜像 → S1 OK:$want"

# --- 3. S2 本机:Engram → WORKER_ENGRAM_DIR(hardlink,零拷贝) -------------------------
mkdir -p "$WORKER_ENGRAM_DIR"
for f in model.safetensors.index.json config.json model-00047-of-00048.safetensors model-00048-of-00048.safetensors; do
  src="$HF_HUB/$ENGRAM_DIR/snapshots/$ENGRAM_REV/$f"
  [ -f "$src" ] || { echo "FAIL: 缺 $src"; exit 1; }
  [ "$WORKER_ENGRAM_DIR/$f" -ef "$src" ] || ln -f "$src" "$WORKER_ENGRAM_DIR/$f"
done
ls -l "$WORKER_ENGRAM_DIR"
echo "=== DONE $(date '+%F %T') ==="
