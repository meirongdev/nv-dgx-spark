#!/bin/bash
echo "=== vllm version ==="
python3 -c "import vllm; print('vllm', vllm.__version__)" 2>&1 | tail -2
echo "=== deepseek model files ==="
python3 -c "import vllm, os, glob; d=os.path.dirname(vllm.__file__); print(sorted(os.path.basename(x) for x in glob.glob(d+'/model_executor/models/*deepseek*')))" 2>&1 | tail -2
echo "=== DeepseekV4 in arch registry? ==="
python3 -c "from vllm.model_executor.models.registry import ModelRegistry; print([a for a in ModelRegistry.get_supported_archs() if 'eepseek' in a])" 2>&1 | tail -3
echo "=== flash_mla / deep_gemm / flashinfer present? ==="
python3 -c "import importlib.util as u; print('flash_mla', u.find_spec('flash_mla') is not None); print('deep_gemm', u.find_spec('deep_gemm') is not None); print('flashinfer', u.find_spec('flashinfer') is not None)" 2>&1 | tail -3
echo "=== grep deepseek_v4 in vllm source ==="
python3 -c "import vllm,os;print(os.path.dirname(vllm.__file__))" 2>/dev/null
