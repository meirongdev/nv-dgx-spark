#!/bin/bash
# Download a model from ModelScope. Run inside tmux for SSH resilience.
# Usage: modelscope-download.sh [model_id] [cache_dir]
set -euo pipefail

MODEL="${1:-unsloth/Qwen3.8-27B-NVFP4}"
CACHE_DIR="${2:-/home/admin/.cache/modelscope}"
VENV="/home/admin/modelscope-venv"

echo "========================================"
echo "ModelScope download starting"
echo "  Model:     $MODEL"
echo "  Cache dir: $CACHE_DIR"
echo "  Venv:      $VENV"
echo "  Started:   $(date)"
echo "========================================"

# Create venv if needed and install modelscope
python3 -m venv "$VENV" 2>/dev/null || true
"$VENV/bin/pip" install -q modelscope

# Download
"$VENV/bin/python3" - <<PYEOF
from modelscope import snapshot_download
import sys

model_id = "$MODEL"
cache_dir = "$CACHE_DIR"
print(f"Downloading {model_id} to {cache_dir} ...")
path = snapshot_download(model_id, cache_dir=cache_dir)
print(f"Download complete: {path}")
PYEOF

echo "========================================"
echo "  Finished:  $(date)"
echo "========================================"
