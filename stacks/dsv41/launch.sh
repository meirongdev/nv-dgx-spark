#!/usr/bin/env bash
# dsv41 启动包装 —— adapter-docker.sh 把它 scp 到 S1(head)的 /home/admin/dsv41-launch.sh,
# 然后在 tmux 'dsv41-start' 里跑(定制全部收在上游 scripts/local.sh,不进 make → ssh → tmux → bash
# 的四层引号链)。
#
# 上游 start.sh 一条命令做完:必要时跑 scripts/prepare.sh(镜像 / 权重 / kit / 两个 rank 的权重文件 /
# worker 的 NFS 卷)→ 两台 MIN_AVAIL_GIB(112)闸门 → 起两台 memguard → ssh 到 S2 起 rank1 →
# 本机起 rank0 → 等 API → 冒烟一条 → 打印两台 MemAvailable。服务器已在跑就什么都不动。
set -euo pipefail
cd /home/admin/dsv41-recipe
exec ./start.sh
