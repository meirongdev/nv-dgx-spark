# nv-dgx-spark

## Project Overview

This is an Ansible-based infrastructure project for managing NVIDIA DGX Spark servers. It provides a Makefile-driven workflow for setting up a Python virtual environment, managing SSH connections, deploying vLLM inference servers, and running Ansible commands against remote DGX hosts.

**Key Components:**
- **Makefile**: Primary interface for all operations (dependency management, SSH testing, vLLM deployment, benchmarking)
- **inventory.ini**: Ansible inventory file defining target hosts
- **playbooks/**: Ansible playbooks for vLLM deployment and testing
- **config/**: Configuration files (vLLM environment, systemd services)
- **scripts/**: Utility scripts (GPU validation, memory monitoring)
- **.venv/**: Python virtual environment with Ansible installed (managed via `uv`)

**Target Hosts:**
- `100.97.87.120` (DGX Spark, GB10, 128GB unified memory)
- `100.67.164.92` (DGX Spark, GB10, 128GB unified memory)

Both hosts use the `admin` user with SSH key authentication.

## Hardware Architecture

**NVIDIA DGX Spark (GB10 Grace Blackwell Superchip):**
- **GPU**: NVIDIA GB10 Blackwell (sm_121, CUDA 13.0)
- **CPU**: 20-core ARM (Cortex-X925 + Cortex-A725)
- **Memory**: 128GB LPDDR5X unified coherent memory (CPU+GPU shared)
- **Storage**: 4TB NVMe SSD
- **Key Feature**: Unified memory eliminates PCIe bottlenecks but requires careful memory management

## Technologies

- **Ansible**: Configuration management and remote execution
- **vLLM**: High-performance LLM inference server (PagedAttention + FlashInfer)
- **Docker**: Container runtime with NVIDIA Container Toolkit
- **uv**: Fast Python package installer and virtual environment manager
- **SSH**: Secure remote access to DGX Spark servers

## Building and Running

### Quick Start

```bash
# Setup everything: venv, inventory, and test connections
make all
```

### Available Commands

#### Infrastructure Management

| Command | Description |
|---------|-------------|
| `make venv` | Create virtual environment and install Ansible |
| `make install` | Alias for `make venv` |
| `make test` | Test SSH connection to all hosts |
| `make ping` | Ping all hosts via Ansible |
| `make facts` | Gather system facts from hosts |
| `make cmd COMMAND="uptime"` | Run ad-hoc command on all hosts |
| `make inventory` | Regenerate the inventory.ini file |
| `make all` | Run venv, inventory, and test |
| `make clean` | Remove .venv and inventory.ini |

#### vLLM Deployment

| Command | Description |
|---------|-------------|
| `make vllm-deploy` | Deploy vLLM on all hosts (system hardening + container) |
| `make vllm-test` | Test vLLM API endpoints (health, completions, chat) |
| `make vllm-status` | Check vLLM container and GPU status |
| `make vllm-stop` | Stop vLLM containers on all hosts |
| `make vllm-benchmark` | Run inference performance benchmark |
| `make vllm-monitor` | Monitor unified memory usage (real-time) |

### Examples

```bash
# Deploy vLLM with default settings (Qwen2.5-7B)
make vllm-deploy

# Deploy with custom model and memory
make vllm-deploy VLLM_MODEL=Qwen/Qwen3.5-35B-A3B GPU_MEMORY_UTIL=0.75

# Test vLLM deployment
make vllm-test

# Check status
make vllm-status

# Run benchmark
make vllm-benchmark

# Monitor memory usage
make vllm-monitor

# Check uptime on all hosts
make cmd COMMAND="uptime"

# Check disk space
make cmd COMMAND="df -h"

# Test connectivity
make ping
```

## vLLM Deployment Architecture

### Best Practices (April 2026)

**Why This Setup is Special for DGX Spark:**

1. **Unified Memory Management (Critical!)**
   - GB10 uses 128GB coherent unified memory (NOT traditional VRAM + system RAM)
   - `--gpu-memory-utilization 0.7` is mandatory (leaves 30% headroom for fragmentation)
   - Swap MUST be disabled (causes system-wide freeze on unified memory)
   - OOM protection configured for SSH processes

2. **FlashInfer Backend (Performance)**
   - `VLLM_ATTENTION_BACKEND=FLASHINFER` for Blackwell optimization
   - MoE acceleration via `VLLM_USE_FLASHINFER_MOE_FP8=1`
   - KV cache in FP8 saves 50% memory with minimal quality loss

3. **Single-Node Deployment Strategy**
   - Each DGX Spark runs independent vLLM instance
   - Cross-node Tensor Parallelism (TP=2) has hang risks (community-tested)
   - Future: Load balance via LiteLLM/Nginx (round-robin)

### Model Recommendations

| Use Case | Model | Memory | Expected Performance |
|----------|-------|--------|---------------------|
| Quick validation | `Qwen3-0.6B` | <5GB | >200 tok/s |
| Daily workload | `Qwen/Qwen2.5-7B-Instruct` | ~15GB | 100-150 tok/s |
| High performance MoE | `Qwen3.5-35B-A3B` | ~70GB | 30-100 tok/s |
|极限 testing | `Qwen3.5-122B-A10B-NVFP4` | ~75GB | 10-30 tok/s |

### Deployment Flow

```
1. System Hardening
   ├─ Disable swap (critical!)
   ├─ Configure OOM protection
   ├─ Add admin to docker group
   └─ Deploy environment files

2. vLLM Deployment
   ├─ Pull Docker image (nvcr.io/nvidia/vllm:26.01-py3)
   ├─ Start container with optimized flags
   ├─ Mount HuggingFace cache
   └─ Wait for model loading

3. Validation
   ├─ Health check (/health)
   ├─ Test completions API
   ├─ Test chat API
   └─ Verify GPU utilization
```

### Key Configuration Files

- **`config/vllm.env`**: Environment variables (FlashInfer, memory limits, model config)
- **`config/vllm.service`**: Systemd service template (OOM protection, restart policy)
- **`playbooks/vllm-deploy.yml`**: Main deployment playbook (system hardening + deployment)
- **`playbooks/vllm-test.yml`**: Validation playbook (API testing, health checks)
- **`scripts/monitor-unified-memory.sh`**: Real-time memory monitoring script
- **`scripts/validate-gpu.sh`**: GPU passthrough validation script

## Configuration

- **SSH Key**: `/Users/matthew/.ssh/vgio`
- **SSH User**: `admin`
- **Inventory File**: `inventory.ini`
- **Hosts**: Defined in Makefile `HOSTS` variable

To add/remove hosts, edit the `HOSTS` variable in the Makefile and run `make inventory`.

### Customizing vLLM Deployment

```bash
# Use different model
make vllm-deploy VLLM_MODEL=Qwen/Qwen3-8B

# Adjust GPU memory utilization
make vllm-deploy GPU_MEMORY_UTIL=0.75

# Use custom Docker image
make vllm-deploy VLLM_IMAGE=eugr/spark-vllm-docker:latest

# Change port
make vllm-deploy VLLM_PORT=8001
```

## Development Conventions

- All Ansible commands use `uv run` to execute within the virtual environment
- SSH connections use strict host key checking disabled (`StrictHostKeyChecking=no`) for automation
- The project uses `uv` instead of traditional `pip`/`venv` for faster Python environment management
- vLLM deployments use infrastructure-as-code principles (Ansible + Makefile)
- All configurations are version-controlled and reproducible

## Troubleshooting

### vLLM Won't Start
```bash
# Check container logs
make cmd COMMAND="docker logs vllm-server --tail 100"

# Verify GPU
make cmd COMMAND="nvidia-smi"

# Check memory
make cmd COMMAND="free -h"
```

### Out of Memory Errors
- Ensure `--gpu-memory-utilization` is set to 0.7 (not default 0.9)
- Verify swap is disabled: `make cmd COMMAND="swapon --show"`
- Reduce `--max-model-len` or `--max-num-seqs`

### Slow Inference
- Confirm FlashInfer backend: `make cmd COMMAND="echo $$VLLM_ATTENTION_BACKEND"`
- Check GPU utilization: `make vllm-status`
- Run benchmark: `make vllm-benchmark`

## Health Monitoring

Monitor unified memory usage (critical for DGX Spark):
```bash
make vllm-monitor
```

This runs the monitoring script that tracks:
- Memory utilization percentage
- GPU utilization
- Container memory usage
- Swap usage (warning if enabled)
- OOM risk alerts

## References

- [vLLM Documentation](https://docs.vllm.ai)
- [NVIDIA DGX Spark User Guide](https://docs.nvidia.com/dgx/dgx-spark/)
- [FlashInfer Optimization](https://github.com/flashinfer-ai/flashinfer)
- [DGX Spark vLLM Community](https://forums.developer.nvidia.com/t/vllm-containers/)
