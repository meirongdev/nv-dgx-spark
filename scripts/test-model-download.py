#!/usr/bin/env python3
"""
Test model download from different sources on DGX Spark servers.
Usage: python test-model-download.py <model-name>
"""

import sys
import time
from huggingface_hub import hf_hub_download, list_repo_files
from pathlib import Path

def test_huggingface(model_id: str, timeout: int = 180):
    """Test HuggingFace download."""
    print(f"\n{'='*60}")
    print(f"Testing HuggingFace: {model_id}")
    print(f"Timeout: {timeout}s")
    print(f"{'='*60}")
    
    start_time = time.time()
    try:
        # Try to download config.json as a quick test
        print(f"Downloading config.json from {model_id}...")
        config_path = hf_hub_download(
            repo_id=model_id,
            filename="config.json",
            timeout=timeout
        )
        elapsed = time.time() - start_time
        print(f"✅ Success! Downloaded to: {config_path}")
        print(f"⏱  Download time: {elapsed:.2f}s")
        return True
    except Exception as e:
        elapsed = time.time() - start_time
        print(f"❌ Failed after {elapsed:.2f}s")
        print(f"Error: {e}")
        return False

def test_modelscope(model_id: str, timeout: int = 180):
    """Test ModelScope download."""
    try:
        from modelscope import snapshot_download
        print(f"\n{'='*60}")
        print(f"Testing ModelScope: {model_id}")
        print(f"Timeout: {timeout}s")
        print(f"{'='*60}")
        
        start_time = time.time()
        cache_dir = Path.home() / ".cache" / "modelscope"
        print(f"Downloading to: {cache_dir}")
        
        result = snapshot_download(
            model_id,
            timeout=timeout,
            cache_dir=str(cache_dir)
        )
        elapsed = time.time() - start_time
        print(f"✅ Success! Downloaded to: {result}")
        print(f"⏱  Download time: {elapsed:.2f}s")
        return True
    except ImportError:
        print("⚠️  ModelScope not installed, skipping...")
        return None
    except Exception as e:
        print(f"❌ ModelScope test failed: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        model = "Qwen/Qwen3.5-35B-A3B"
        print(f"Using default model: {model}")
    else:
        model = sys.argv[1]
    
    print(f"Testing model download for: {model}")
    print(f"Testing environment: {sys.platform}")
    
    # Test HuggingFace first (current project method)
    hf_success = test_huggingface(model)
    
    # Test ModelScope (optional)
    ms_result = test_modelscope(model)
    
    print(f"\n{'='*60}")
    print("Summary:")
    print(f"  HuggingFace: {'✅ PASS' if hf_success else '❌ FAIL'}")
    print(f"  ModelScope: {'✅ PASS' if ms_result else '❌ FAIL (or not installed)'}")
    print(f"{'='*60}")
