#!/usr/bin/env bash
set -euo pipefail

# vLLM launcher for DGX Spark (GB10 Blackwell)
# Usage: VLLM_MODEL=<model> ./run-vllm-qwen.sh

VLLM_MODEL="${VLLM_MODEL:?VLLM_MODEL is required}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm-node-tf5:latest}"
VLLM_PORT="${VLLM_PORT:-30000}"
VLLM_GPU_MEM="${VLLM_GPU_MEM:-0.70}"
VLLM_CONTAINER="${VLLM_CONTAINER:-vllm-qwen}"
VLLM_SERVED_NAME="${VLLM_SERVED_NAME:-${VLLM_MODEL}}"
VLLM_HF_CACHE="${VLLM_HF_CACHE:-/home/admin/.cache/huggingface}"
VLLM_TOOL_PARSER="${VLLM_TOOL_PARSER:-qwen3_coder}"
VLLM_REASONING_PARSER="${VLLM_REASONING_PARSER-qwen3}"
VLLM_KV_DTYPE="${VLLM_KV_DTYPE:-fp8_e4m3}"
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-32768}"
VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-64}"
VLLM_MAX_NUM_BATCHED="${VLLM_MAX_NUM_BATCHED:-8192}"
VLLM_CHAT_TEMPLATE="${VLLM_CHAT_TEMPLATE:-}"
VLLM_MOE_FP8="${VLLM_MOE_FP8:-}"
VLLM_PRESERVE_THINKING="${VLLM_PRESERVE_THINKING:-}"
VLLM_DISABLE_THINKING="${VLLM_DISABLE_THINKING:-}"
VLLM_ENABLE_STORE="${VLLM_ENABLE_STORE:-1}"
VLLM_MS_CACHE="${VLLM_MS_CACHE:-}"
VLLM_PATCH_SCRIPT="${VLLM_PATCH_SCRIPT:-$(dirname "$0")/patch-vllm-chat-utils.py}"
VLLM_ENTRYPOINT_SCRIPT="${VLLM_ENTRYPOINT_SCRIPT:-$(dirname "$0")/vllm-entrypoint.sh}"

docker rm -f "${VLLM_CONTAINER}" 2>/dev/null || true

# Build volume mounts
VOLUMES="-v ${VLLM_HF_CACHE}:/root/.cache/huggingface"
if [ -n "${VLLM_MS_CACHE}" ]; then
  VOLUMES="${VOLUMES} -v ${VLLM_MS_CACHE}:/root/.cache/modelscope"
fi
CHAT_TEMPLATE_ARG=""
if [ -n "${VLLM_CHAT_TEMPLATE}" ] && [ -f "${VLLM_CHAT_TEMPLATE}" ]; then
  VOLUMES="${VOLUMES} -v ${VLLM_CHAT_TEMPLATE}:/app/chat-template.jinja2:ro"
  CHAT_TEMPLATE_ARG="--chat-template /app/chat-template.jinja2"
fi

# Mount patch + entrypoint wrapper for persistent fixes
ENTRYPOINT_ARG=""
if [ -f "${VLLM_PATCH_SCRIPT}" ] && [ -f "${VLLM_ENTRYPOINT_SCRIPT}" ]; then
  VOLUMES="${VOLUMES} -v ${VLLM_PATCH_SCRIPT}:/app/patch-vllm.py:ro"
  VOLUMES="${VOLUMES} -v ${VLLM_ENTRYPOINT_SCRIPT}:/app/vllm-entrypoint.sh:ro"
  ENTRYPOINT_ARG="--entrypoint /app/vllm-entrypoint.sh"
fi

exec docker run -d \
  --name "${VLLM_CONTAINER}" \
  --restart unless-stopped \
  --privileged \
  --gpus all \
  --network host \
  --ipc=host \
  ${VOLUMES} \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_HUB_OFFLINE=1 \
  -e VLLM_ATTENTION_BACKEND=FLASHINFER \
  -e VLLM_ENABLE_RESPONSES_API_STORE="${VLLM_ENABLE_STORE}" \
  ${VLLM_MOE_FP8:+-e VLLM_USE_FLASHINFER_MOE_FP8="${VLLM_MOE_FP8}"} \
  ${ENTRYPOINT_ARG} \
  "${VLLM_IMAGE}" \
  vllm serve "${VLLM_MODEL}" \
    --served-model-name "${VLLM_SERVED_NAME}" \
    --host 0.0.0.0 \
    --port "${VLLM_PORT}" \
    --gpu-memory-utilization "${VLLM_GPU_MEM}" \
    --kv-cache-dtype "${VLLM_KV_DTYPE}" \
    --dtype auto \
    ${VLLM_QUANTIZATION:+--quantization "${VLLM_QUANTIZATION}"} \
    --trust-remote-code \
    --enable-auto-tool-choice \
    --tool-call-parser "${VLLM_TOOL_PARSER}" \
    ${VLLM_REASONING_PARSER:+--reasoning-parser "${VLLM_REASONING_PARSER}"} \
    ${VLLM_PRESERVE_THINKING:+--default-chat-template-kwargs '{"preserve_thinking": true}'} \
    ${VLLM_DISABLE_THINKING:+--default-chat-template-kwargs '{"enable_thinking": false}'} \
    --max-model-len "${VLLM_MAX_MODEL_LEN}" \
    --max-num-seqs "${VLLM_MAX_NUM_SEQS}" \
    ${VLLM_MAX_NUM_BATCHED:+--max-num-batched-tokens "${VLLM_MAX_NUM_BATCHED}"} \
    --enable-prefix-caching \
    --tensor-parallel-size 1 \
    ${CHAT_TEMPLATE_ARG}
