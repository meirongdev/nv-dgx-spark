#!/usr/bin/env bash
# 在 **S1** 上构建 dsv41 的引擎镜像 —— 与上游 scripts/prepare.sh 第 2 步**同一条** docker build,
# 唯一区别:TF_REPO 这个 build-arg 指向本机 git daemon 上的副本,而不是 github.com。
#
# 为什么:2026-11-14 从两台节点到 GitHub 只有 13–47 KB/s(直连、xray socks、privoxy http 三路都测了),
# 而且构建里的 `git fetch --depth 1` 在 90 s 处被掐断:
#   fatal: unable to access 'https://github.com/bertholomus/TensorFold.git/': GnuTLS recv error (-110)
# 控制机(Mac)拉同样两个 commit 只要 ~15 s,所以:Mac 上 `git fetch --depth 1` 两个钉住的 commit 进一个裸库
# (9.1 MB)→ 经 Tailscale 送到 S1 /home/admin/dsv41-gitsrv/TensorFold.git → `git daemon` 只听 docker 网桥
# 172.17.0.1:9418 → 构建容器从那里 fetch。
#
# 为什么这样做出来的镜像就是上游那一个:
#   - Dockerfile 自己断言 `git rev-parse HEAD = TF_REF`(commit SHA 覆盖整棵树),来源换了,内容不会换;
#   - tag / label 用的仍是上游 image_hash()(按默认 TF_REPO 算 = 8a98ae503d85),所以之后跑上游
#     prepare.sh 时它判 "Image … already built",不重建,local.sh 也不必永久带一个 TF_REPO。
# git daemon 只在构建期需要,跑完即停(脚本末尾)。
set -euo pipefail
cd /home/admin/dsv41-recipe
source ./scripts/config.sh          # IMAGE / TF_REF / INPUTS_REF / ZIG_* / BASE_IMAGE / image_hash,都按上游默认
LOCAL_TF_REPO="${LOCAL_TF_REPO:-git://172.17.0.1/TensorFold.git}"
GITSRV=/home/admin/dsv41-gitsrv
hash=$(image_hash)
echo "IMAGE=$IMAGE  hash=$hash  (TF_REPO 默认值 $TF_REPO 参与 hash;构建时改从 $LOCAL_TF_REPO 取)"

if [ ! -s "$GITSRV/daemon.pid" ] || ! kill -0 "$(cat "$GITSRV/daemon.pid")" 2>/dev/null; then
  git daemon --base-path="$GITSRV" --export-all --reuseaddr --listen=172.17.0.1 --port=9418 \
             --detach --pid-file="$GITSRV/daemon.pid"
fi
for r in "$TF_REF" "$INPUTS_REF"; do
  git -C "$GITSRV/TensorFold.git" cat-file -e "$r^{commit}" || { echo "FAIL: 本地副本里没有 $r"; exit 1; }
done

# 构建上下文:与 prepare.sh 一字不差
ctx=$(mktemp -d "$STATE_DIR/build.XXXXXX"); trap 'rm -rf -- "$ctx"' EXIT
mkdir -p "$ctx/zig"; cp -r zig/patches "$ctx/zig/patches"; cp -r zig/patches-inputs "$ctx/zig/patches-inputs"; cp zig/Dockerfile "$ctx/Dockerfile"
docker build -t "$IMAGE" -f "$ctx/Dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg TF_REPO="$LOCAL_TF_REPO" --build-arg TF_REF="$TF_REF" --build-arg INPUTS_REF="$INPUTS_REF" \
  --build-arg ZIG_VERSION="$ZIG_VERSION" --build-arg ZIG_SHA256="$ZIG_SHA256" --build-arg ZIG_MIRRORS="$ZIG_MIRRORS" \
  --build-arg PATCHES_HASH="$hash" "$ctx"

got=$(docker image inspect -f '{{index .Config.Labels "tf.patches"}} {{index .Config.Labels "tf.ref"}} {{index .Config.Labels "tf.inputs"}}' "$IMAGE")
[ "$got" = "$hash $TF_REF $INPUTS_REF" ] || { echo "FAIL: 镜像 label 是 [$got]"; exit 1; }
kill "$(cat "$GITSRV/daemon.pid")" 2>/dev/null && rm -f "$GITSRV/daemon.pid"
echo "DONE: $IMAGE  labels: tf.patches=$hash tf.ref=$TF_REF tf.inputs=$INPUTS_REF  (git daemon 已停)"
