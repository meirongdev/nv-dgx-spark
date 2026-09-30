#!/usr/bin/env bash
# hibrid48tp2 启动包装 —— adapter-docker.sh 把它 scp 到 S2(head)的
# /home/admin/hibrid48tp2-launch.sh,然后在 tmux 里跑(同 hibrid48/launch.sh 的规矩:
# 定制全部收在这里,不进 make → ssh → tmux → bash 的四层引号链)。
#
# 上游双机 kit 原样放在 /home/admin/hibrid48tp2-recipe/{run.sh,lib.sh,stop.sh,view.sh,...}。
# run.sh 从 recipe.yaml(模型侧)和 cluster.env(两台机器侧)读全部参数,自己 ssh 到
# worker(S1,192.168.200.101)起 rank1 —— 所以这里只需要在 head 上 exec 它。
# 本地的三处偏离(端口 / host / served 名)固化在 S2 的 recipe.yaml 里,本文件不叠参数。
set -euo pipefail
exec bash /home/admin/hibrid48tp2-recipe/run.sh
