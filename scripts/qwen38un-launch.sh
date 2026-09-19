#!/usr/bin/env bash
# Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2 启动包装。
#
# 为什么需要这一层:上游 start-dflash.sh 要靠三个**带空格的**环境变量来定制
# (DF_EXTRA / DOCKER_ENV / IMAGE),而从 make → ssh → tmux → bash 四层传下去,
# 引号会在中途断掉 —— 2026-09-19 实测:DF_EXTRA 静默丢失,EXTRA_ARGS 里仍是上游
# 硬编码的 RadixArk 路径,于是引擎去联网下一个我们没有的模型然后失败。
# **失败信息完全不提"你的 DF_EXTRA 没生效"**,只说连不上 huggingface.co。
# 把变量固定在脚本里,这一类就不会再发生。
set -euo pipefail

SGLANG_DIR="${SGLANG_DIR:-/home/admin/qwen38-sglang}"

# 容器内路径。⚠️ 必须在被挂载的 HF_HOME 树内 —— start.sh 只挂
# $SGLANG_DIR/.cache/huggingface -> /root/.cache/huggingface(和 triton 缓存)。
# 放 /home/admin/models 下容器看不见,transformers 会把它当 HF repo id 解析,
# 报 "Repo id must be in the form 'namespace/repo_name'"。
export DF_EXTRA="--model-path ${MODEL_CT:-/root/.cache/huggingface/local/Qwen3.8-27B-Uncensored-NVFP4}"

# 草稿模型是按 **repo id** 传给 SGLang 的(--speculative-draft-model-path
# z-lab/Qwen3.8-27B-DFlash2),即便已预缓存,HF hub 仍会发 HEAD 探更新 →
# 容器内 "Network is unreachable" 重试 5 轮。离线开关让它直接吃缓存。
# 本仓库另外两个栈(qwen38fn / qwen38-27b)本来就带这两个变量。
export DOCKER_ENV="HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1"

# 从 daocloud 拉后重打的规范 tag(ghcr/dockerhub 直连在 DGX 上不通)。
export IMAGE="${IMAGE:-lmsysorg/sglang:nightly-cu134-20260909-708f51e}"

cd "$SGLANG_DIR"

echo "=== qwen38un launch ==="
echo "IMAGE     = $IMAGE"
echo "DF_EXTRA  = $DF_EXTRA"
echo "DOCKER_ENV= $DOCKER_ENV"
echo ".env      : $(grep -vE '^\s*#|^\s*$' .env | tr '\n' ' ')"
echo

# ⚠️ mem-fraction-static 不在这里设 —— start-dflash.sh 会追加 0.90,覆盖
#    start.sh 的 0.95。上游注释原文:0.95 hard-rebooted the box。别去"修"。
exec ./start-dflash.sh
