#!/bin/bash
# vLLM container entrypoint wrapper
# Applies runtime patches before starting vLLM, then exec's the original command.
# Mount this as /app/vllm-entrypoint.sh and set --entrypoint /app/vllm-entrypoint.sh

set -euo pipefail

if [ -f /app/patch-vllm.py ]; then
    python3 /app/patch-vllm.py || echo "WARNING: vllm patch failed, continuing anyway"
fi

exec "$@"
