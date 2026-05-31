#!/bin/bash
# Fix vllm-node-dsv4: its runner ended up with torch 2.10.0+CPU (the vllm wheel
# + ray/fastsafetensors deps clobbered the cu130 torch). vllm._C was built
# against torch 2.11.0 cu130, so libtorch_cuda.so is missing. Reinstall the
# matching CUDA torch into the image and commit, instead of a 43-min rebuild.
set -euo pipefail
PROXY=http://172.17.0.1:10809
docker rm -f dsv4fix 2>/dev/null || true
docker run -d --name dsv4fix --gpus all \
  -e http_proxy=$PROXY -e https_proxy=$PROXY -e HTTP_PROXY=$PROXY -e HTTPS_PROXY=$PROXY \
  --entrypoint sleep vllm-node-dsv4 infinity
echo "=== before: torch ==="
docker exec dsv4fix python3 -c "import torch; print(torch.__version__, torch.version.cuda)" 2>&1 | tail -1
echo "=== reinstalling torch 2.11.0 cu130 (via proxy) ==="
docker exec dsv4fix uv pip install --system torch==2.11.0 torchvision torchaudio triton --index-url https://download.pytorch.org/whl/cu130
echo "=== verify torch + vllm._C ==="
docker exec dsv4fix python3 -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda); import vllm._C; print('vllm._C OK')"
echo "=== commit -> vllm-node-dsv4:latest ==="
docker commit dsv4fix vllm-node-dsv4:latest
docker rm -f dsv4fix
echo "=== copy fixed image to S2 over 200G ==="
docker save vllm-node-dsv4:latest | ssh -o StrictHostKeyChecking=no 192.168.200.102 docker load
echo "FIX_DONE_OK"
