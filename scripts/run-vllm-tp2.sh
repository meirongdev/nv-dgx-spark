#!/usr/bin/env bash
set -euo pipefail

TP2_MODEL="${TP2_MODEL:?TP2_MODEL is required}"
TP2_IMAGE="${TP2_IMAGE:-vllm/vllm-openai:gemma4-cu130}"
TP2_MASTER_ADDR="${TP2_MASTER_ADDR:?TP2_MASTER_ADDR is required}"
TP2_MASTER_PORT="${TP2_MASTER_PORT:-29500}"
TP2_NNODES="${TP2_NNODES:-2}"
TP2_NODE_RANK="${TP2_NODE_RANK:?TP2_NODE_RANK is required}"
TP2_TP_SIZE="${TP2_TP_SIZE:-2}"
TP2_PP_SIZE="${TP2_PP_SIZE:-1}"
TP2_PORT="${TP2_PORT:-8000}"
TP2_GPU_MEMORY_UTIL="${TP2_GPU_MEMORY_UTIL:-0.7}"
TP2_MAX_MODEL_LEN="${TP2_MAX_MODEL_LEN:-8192}"
TP2_CONTAINER_NAME="${TP2_CONTAINER_NAME:-vllm-tp2}"
TP2_NCCL_IFACE="${TP2_NCCL_IFACE:-enp1s0f0np0}"
TP2_HF_CACHE_DIR="${TP2_HF_CACHE_DIR:-/home/admin/.cache/huggingface}"
TP2_MODEL_PATH="${TP2_MODEL_PATH:-${TP2_MODEL}}"
TP2_SERVED_MODEL_NAME="${TP2_SERVED_MODEL_NAME:-${TP2_MODEL}}"

api_args=(--host 0.0.0.0 --port "${TP2_PORT}")
if [[ "${TP2_NODE_RANK}" != "0" ]]; then
  api_args=(--headless)
fi

docker rm -f "${TP2_CONTAINER_NAME}" 2>/dev/null || true

docker run -d \
  --name "${TP2_CONTAINER_NAME}" \
  --restart unless-stopped \
  --gpus all \
  --network host \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --entrypoint vllm \
  -v "${TP2_HF_CACHE_DIR}:/root/.cache/huggingface" \
  -e VLLM_ATTENTION_BACKEND="${VLLM_ATTENTION_BACKEND:-FLASHINFER}" \
  -e VLLM_USE_FLASHINFER_MOE_FP8="${VLLM_USE_FLASHINFER_MOE_FP8:-1}" \
  -e VLLM_FLASHINFER_MOE_BACKEND="${VLLM_FLASHINFER_MOE_BACKEND:-latency}" \
  -e NCCL_SOCKET_IFNAME="${TP2_NCCL_IFACE}" \
  -e GLOO_SOCKET_IFNAME="${TP2_NCCL_IFACE}" \
  -e CUDA_VISIBLE_DEVICES=0 \
  "${TP2_IMAGE}" \
  serve "${TP2_MODEL_PATH}" \
    "${api_args[@]}" \
    --served-model-name "${TP2_SERVED_MODEL_NAME}" \
    --distributed-executor-backend mp \
    --pipeline-parallel-size "${TP2_PP_SIZE}" \
    --master-addr "${TP2_MASTER_ADDR}" \
    --master-port "${TP2_MASTER_PORT}" \
    --nnodes "${TP2_NNODES}" \
    --node-rank "${TP2_NODE_RANK}" \
    --tensor-parallel-size "${TP2_TP_SIZE}" \
    --gpu-memory-utilization "${TP2_GPU_MEMORY_UTIL}" \
    --kv-cache-dtype fp8 \
    --dtype auto \
    --max-model-len "${TP2_MAX_MODEL_LEN}" \
    --max-num-seqs 64 \
    --trust-remote-code
