#!/usr/bin/env bash
set -euo pipefail
# Qwen3.8-27B-NVFP4 evaluation launch on S1 (GB10).
# Adapted from MiaAI-Lab/Qwen3.8-27B-DGX-Spark-RTX-6000 start.sh, 4 deliberate deviations:
#   1. MODEL = local path, not HF repo id  (S1 has no HF access; repo-wide gotcha)
#   2. gpu-memory-utilization 0.75, not 0.84 (this head node OOM'd at 0.85 on
#      2026-06-29; S2 is down so an S1 OOM would cost a physical site visit)
#   3. proxy env explicitly cleared (~/.docker/config.json injects a possibly-dead
#      xray proxy into every docker run)
#   4. NATIVE 262144 context, not the recipe's YaRN-extended 1M (2026-08-15).
#      The 1M came from a static YaRN factor 4.0 injected via --hf-overrides, and
#      the model card admits "static YaRN can slightly impact short-context
#      quality" -- a penalty paid on EVERY request, including the short coding
#      prompts that are the actual workload. Dropping --hf-overrides restores the
#      checkpoint's own rope_parameters, whose mrope_interleaved / mrope_section /
#      partial_rotary_factor / rope_theta are byte-identical to the override; the
#      only change is rope_type yarn -> default. Also drops
#      VLLM_ALLOW_LONG_MAX_MODEL_LEN, which is only needed to exceed native.
#      Side benefit: max-length concurrency goes 1.95x -> ~7x on the same KV.
MODEL=/home/admin/models/Qwen3.8-27B-NVFP4
NAME=qwen38-27b
IMAGE=vllm/vllm-openai:nightly-aarch64
PORT=8888
mkdir -p /home/admin/.cache/qwen38-triton

docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d --name "$NAME" \
  --network host --ipc host --privileged --gpus all \
  -e VLLM_TARGET_DEVICE=cuda \
  -e VLLM_FLOAT32_MATMUL_PRECISION=high \
  -e CUTE_DSL_ARCH=sm_121a \
  -e HF_HUB_OFFLINE=1 \
  -e TRANSFORMERS_OFFLINE=1 \
  -e TRITON_CACHE_DIR=/root/.triton \
  -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' -e no_proxy='*' \
  -v /home/admin/models:/models:ro \
  -v /home/admin/.cache/qwen38-triton:/root/.triton \
  --entrypoint vllm \
  "$IMAGE" \
  serve /models/Qwen3.8-27B-NVFP4 \
  --served-model-name "$NAME" \
  --host 0.0.0.0 --port "$PORT" \
  --tensor-parallel-size 1 \
  --trust-remote-code \
  --quantization compressed-tensors \
  --attention-backend triton_attn \
  --gpu-memory-utilization 0.75 \
  --max-model-len 262144 \
  --max-num-seqs 4 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  --skip-mm-profiling \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --enable-auto-tool-choice \
  --media-io-kwargs '{"video": {"num_frames": -1}}' \
  --speculative-config '{"method": "mtp", "num_speculative_tokens": 2}'

echo "container started: $(docker inspect -f '{{.Id}}' "$NAME" | cut -c1-12)"
