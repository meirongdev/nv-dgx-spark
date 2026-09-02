#!/usr/bin/env bash
# 把 qwen38fn 镜像从 docker 导入本机 containerd 并 pin。**每台节点各跑一次。**
#
# 为什么必须做:Pod 是 imagePullPolicy: Never + 本地镜像,containerd 里没有就永远
# 起不来;不 pin 的话 kubelet 的镜像 GC 会在磁盘压力下把它删掉,表现为"某天早上
# Pod 突然 ImageNeverPull"。这条路径与 v4flash 完全相同(k8s/README.md「镜像
# rebuild 之后」)。
#
# 幂等:重复跑安全 —— tag 已存在会跳过,label 会覆盖。
set -uo pipefail

SRC="${SRC:-docker.m.daocloud.io/vllm/vllm-openai:qwen38-flash-next}"
TARGET="${TARGET:-docker.io/library/vllm-qwen38fn:latest}"
LOCAL="${LOCAL:-vllm-qwen38fn:latest}"
CTR=(sudo k3s ctr -n k8s.io)

echo "=== $(hostname) 导入 containerd ==="
echo "src=$SRC"
echo "target=$TARGET"

# 记录源镜像身份,导入后要比对(防止两台导入了不同的东西 —— TP=2 是锁步的)
SRC_ID=$(docker inspect --format='{{.Id}}' "$SRC" 2>/dev/null) || {
  echo "FAIL: 本机 docker 里没有 $SRC,先 docker pull"; exit 1; }
echo "src ImageID=$SRC_ID"

if ! docker image inspect "$LOCAL" >/dev/null 2>&1; then
  docker tag "$SRC" "$LOCAL" || { echo "FAIL: docker tag"; exit 1; }
fi

echo "--- docker save | k3s ctr images import(约 20GB,数分钟)---"
t0=$(date +%s)
docker save "$LOCAL" | "${CTR[@]}" images import - || { echo "FAIL: import"; exit 1; }
echo "import 用时 $(( $(date +%s) - t0 ))s"

# import 后的名字取决于 docker save 写进 manifest 的 RepoTags。确认 TARGET 存在,
# 不存在就从实际导入的名字 tag 过去。
if ! "${CTR[@]}" images ls -q | grep -qx "$TARGET"; then
  actual=$("${CTR[@]}" images ls -q | grep -E 'vllm-qwen38fn' | head -1)
  [ -z "$actual" ] && { echo "FAIL: 导入后找不到 vllm-qwen38fn"; exit 1; }
  echo "--- tag $actual -> $TARGET ---"
  "${CTR[@]}" images tag "$actual" "$TARGET" || { echo "FAIL: ctr tag"; exit 1; }
fi

echo "--- pin(防 kubelet 镜像 GC 回收)---"
"${CTR[@]}" images label "$TARGET" io.cri-containerd.pinned=pinned >/dev/null \
  || { echo "FAIL: label"; exit 1; }

echo "--- 校验 ---"
"${CTR[@]}" images ls | awk -v t="$TARGET" '$1==t {print "  name="$1"\n  digest="$3"\n  size="$4}'
pinned=$("${CTR[@]}" images ls | awk -v t="$TARGET" '$1==t {print $0}' | grep -c "pinned=pinned")
[ "$pinned" -ge 1 ] && echo "  pinned: YES" || { echo "  pinned: NO —— 未生效"; exit 1; }

echo "=== $(hostname) DONE ==="
