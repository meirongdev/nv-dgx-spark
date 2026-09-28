#!/usr/bin/env bash
# hibrid48 启动包装 —— adapter-docker.sh 把它 scp 到 S2 的 /home/admin/hibrid48-launch.sh,
# 然后在 tmux 里跑(同 fndgx/launch.sh 的规矩:定制全部收在这个文件里,
# 不进 make → ssh → tmux → bash 的四层引号链)。
#
# 上游配方自带完整 kit:/home/admin/hibrid48-recipe/{run.sh,recipe.yaml,stop.sh,tune-host.sh,view.sh}
# run.sh 从 recipe.yaml 读全部参数(镜像/端口/权重/vLLM flags/env)。
# 启动序列:权重检查(index 在则跳过 98G 下载)→ 内存 ≥100G 等待 →
#   清 page cache → docker run(fastsafetensors,~80s 加载权重)→ 健康轮询(20 min 超时)。
# 本地已做的两处偏离(端口 18300 / served 名 qwen3.8-flash-next)固化在 S2 的
# recipe.yaml 里 —— 本文件不叠任何参数,改配方只改 recipe.yaml。
set -euo pipefail
exec bash /home/admin/hibrid48-recipe/run.sh
