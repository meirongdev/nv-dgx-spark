#!/bin/bash
# GPU Validation Script for DGX Spark
# Verifies GPU accessibility and CUDA functionality

set -e

echo "======================================"
echo "DGX Spark GPU Validation"
echo "======================================"
echo ""

# Check if nvidia-smi is available
if ! command -v nvidia-smi &> /dev/null; then
    echo "❌ ERROR: nvidia-smi not found"
    exit 1
fi

echo "✓ nvidia-smi found"
echo ""

# Display GPU information
echo "GPU Information:"
echo "--------------------------------------"
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free,utilization.gpu --format=csv
echo ""

# Check CUDA availability
if ! command -v nvcc &> /dev/null; then
    echo "⚠ WARNING: nvcc (CUDA compiler) not found in PATH"
else
    echo "✓ nvcc found"
    echo "CUDA Version: $(nvcc --version | grep 'release' | awk '{print $6}')"
    echo ""
fi

# Test GPU accessibility via Docker (if Docker is available)
if command -v docker &> /dev/null; then
    echo "Testing GPU access in Docker container..."
    if docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
        echo "✓ GPU accessible in Docker containers"
    else
        echo "❌ ERROR: GPU not accessible in Docker containers"
        echo "  Ensure NVIDIA Container Toolkit is installed and configured"
        exit 1
    fi
else
    echo "⚠ WARNING: Docker not found - skipping container GPU test"
fi

echo ""
echo "======================================"
echo "GPU Validation Complete"
echo "======================================"
