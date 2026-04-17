# nv-dgx-spark

## Project Overview

This is an Ansible-based infrastructure project for managing an NVIDIA DGX Spark cluster running large language model inference services. It provides Makefile-driven workflows for:

- **Infrastructure management**: SSH connectivity testing, Ansible inventory, system unification
- **vLLM deployment**: Multiple LLM models with GPU-optimized configurations
- **LLM Gateway**: FastAPI reverse proxy for routing and load balancing across vLLM backends
- **tmux resilience**: SSH-drop-proof deployments via named tmux sessions

**Target Infrastructure:**
- `100.97.87.120` — DGX Spark (GB10 Grace Blackwell, 128GB unified memory)
- `100.67.164.92` — DGX Spark (GB10 Grace Blackwell, 128GB unified memory)

Both hosts use SSH key `/Users/matthew/.ssh/vgio` with user `admin`.

## Hardware Architecture

**NVIDIA DGX Spark (GB10 Grace Blackwell Superchip):**
- **GPU**: GB10 Blackwell (sm_121, CUDA 13.0)
- **CPU**: 20-core ARM (Cortex-X925 + Cortex-A725)
- **Memory**: 128GB LPDDR5X **unified coherent memory** (CPU+GPU share the same pool)
- **Storage**: 4TB NVMe SSD
- **Key Constraint**: Unified memory requires careful management — `--gpu-memory-utilization 0.7` is mandatory, swap must be disabled (causes full system freeze on unified memory)

## Technologies

| Technology | Purpose |
|------------|---------|
| **Ansible** | Configuration management and remote execution |
| **vLLM** | High-performance LLM inference (PagedAttention + FlashInfer) |
| **Docker** | Container runtime with NVIDIA Container Toolkit |
| **uv** | Fast Python package installer and venv manager |
| **FastAPI** | LLM Gateway (reverse proxy for routing/load balancing) |
| **tmux** | SSH-drop-proof session management |

## Project Structure

```
├── playbooks/          # Ansible playbooks (vLLM deploy, system unification, gateway)
├── scripts/            # Helper scripts (GPU validation, memory monitor, patching)
├── config/             # Environment files, systemd templates, jinja2 templates
├── benchmarks/         # Performance scripts and reports
├── gateway/            # LLM Gateway source (FastAPI reverse proxy)
├── docs/               # Deployment guides and design docs
├── inventory.ini       # Ansible inventory (generated)
├── Makefile            # Primary interface for all operations
└── .venv/              # Python virtual environment (managed via uv)
```

## Quick Start

```bash
# Full setup: venv + inventory + SSH test
make all
```

## Available Commands

### Infrastructure Management

| Command | Description |
|---------|-------------|
| `make venv` / `make install` | Create `.venv` and install Ansible via `uv` |
| `make test` / `make ping` | Test SSH/Ansible connectivity to all hosts |
| `make facts` | Gather system facts from hosts |
| `make cmd COMMAND="uptime"` | Run any ad-hoc command on all hosts |
| `make inventory` | Regenerate `inventory.ini` |
| `make unify-system` | Unify kernel and NVIDIA driver across cluster |
| `make unify-status` | Check system version status |
| `make all` | `make venv inventory test` |
| `make clean` | Remove `.venv` and `inventory.ini` |

### vLLM Deployment — Single Node (Primary)

Each DGX Spark runs an **independent** vLLM instance. Cross-node Tensor Parallelism (TP=2) has known hang risks and is under development.

| Command | Description |
|---------|-------------|
| `make vllm-deploy` | Full deployment (system hardening + container) |
| `make vllm-single-deploy` | Deploy with custom model/port/tool parser |
| `make vllm-test` | Validate API health, completions, and chat endpoints |
| `make vllm-status` | Check container, API, and GPU utilization |
| `make vllm-stop` | Stop all vLLM containers |
| `make vllm-benchmark` | Run inference performance benchmark |
| `make vllm-monitor` | Real-time unified memory monitoring |
| `make vllm-logs HOST=... VLLM_CONTAINER=...` | Follow logs from a specific container on a host |

**Customization:**
```bash
make vllm-deploy VLLM_MODEL=Qwen/Qwen3-8B GPU_MEMORY_UTIL=0.75 VLLM_PORT=8001
```

### Per-Model Deployments

Three pre-configured model deployments with their own container names and configurations:

| Model | Container | Port | Description |
|-------|-----------|------|-------------|
| Qwen3.5-122B-A10B-NVFP4 | `vllm-qwen` | 30000 | Chat template + chat_utils patch + tool calling |
| Gemma-4-31B-IT-NVFP4 | `vllm-gemma4` | 30000 | Local HF cache + gemma4 parser patch |
| Qwen3.6-35B-A3B-FP8 | `vllm-qwen36` | 30000 | ModelScope cache, 256K context, tool calling |

```bash
# Deploy specific model
make vllm-qwen-deploy
make vllm-gemma4-deploy
make vllm-qwen36-deploy

# Status/stop/logs for any model
make vllm-qwen-status
make vllm-qwen-stop
make vllm-qwen-logs HOST=100.97.87.120
```

### LLM Gateway (FastAPI Reverse Proxy)

Routes requests to vLLM backends with sticky routing for Responses API and load balancing for chat completions:

| Command | Description |
|---------|-------------|
| `make gateway-deploy` | Deploy the FastAPI gateway |
| `make gateway-test` | Test health, models, and chat endpoints |
| `make gateway-stop` | Stop the gateway |
| `make gateway-status` | Check gateway status |

Gateway architecture:
- Routes `/v1/responses*` with sticky affinity to Server 1
- Load balances `/v1/chat/completions` across both servers
- ~11μs routing overhead with automatic failover

### tmux Resilient Sessions

Commands running inside named tmux sessions survive SSH disconnections:

```bash
# Deploy in tmux (survives network drops)
make tmux-vllm-deploy

# Run any command in a tmux session
make tmux-cmd COMMAND="docker pull nvcr.io/nvidia/vllm:26.01-py3" SESSION="docker-pull"

# Manage sessions on a host
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```

### Model Download

```bash
# Download from ModelScope (survives SSH disconnection)
make modelscope-download
```

## vLLM Best Practices for DGX Spark

### Unified Memory Management (Critical)
1. `--gpu-memory-utilization 0.7` — mandatory (leaves 30% headroom for fragmentation)
2. **Disable swap** — causes system-wide freeze on unified memory
3. OOM protection configured for SSH processes

### Performance Optimization
- `VLLM_ATTENTION_BACKEND=FLASHINFER` — Blackwell-optimized attention
- `VLLM_USE_FLASHINFER_MOE=1` — MoE acceleration
- KV cache in FP8 — 50% memory savings with minimal quality loss

### Tool Calling Support
```bash
make vllm-single-deploy \
  VLLM_MODEL=Qwen/Qwen3.5-35B-A3B \
  TOOL_CALL_PARSER=qwen3_coder
```

**Supported parsers:** `qwen3_coder`, `llama3_json`, `pythonic`, `hermes`, `mistral`, `gemma4`

### Model Recommendations

| Use Case | Model | Memory | Expected Throughput |
|----------|-------|--------|-------------------|
| Quick validation | `Qwen3-0.6B` | <5GB | >200 tok/s |
| Daily workload | `Qwen2.5-7B-Instruct` | ~15GB | 100-150 tok/s |
| MoE high perf | `Qwen3.5-35B-A3B` | ~70GB | 30-100 tok/s |
| Edge case | `Qwen3.5-122B-A10B-NVFP4` | ~75GB | 10-30 tok/s |

## Deployment Flow

```
1. System Hardening
   ├─ Disable swap
   ├─ Configure OOM protection
   ├─ Add admin to docker group
   └─ Deploy environment files

2. vLLM Deployment
   ├─ Pull Docker image
   ├─ Start container with optimized flags
   ├─ Mount HuggingFace/ModelScope cache
   └─ Wait for model loading

3. Validation
   ├─ Health check (/health)
   ├─ Test completions API
   ├─ Test chat API
   └─ Verify GPU utilization
```

## Key Configuration

| File | Purpose |
|------|---------|
| `config/vllm.env` | Environment variables (FlashInfer, memory limits, model config) |
| `config/vllm.service` | Systemd service template (OOM protection, restart policy) |
| `scripts/monitor-unified-memory.sh` | Real-time unified memory monitoring |
| `scripts/validate-gpu.sh` | GPU passthrough validation |
| `playbooks/vllm-model-deploy.yml` | Generic model-specific deployment playbook |
| `playbooks/gateway-deploy.yml` | LLM Gateway deployment |

## Development Conventions

- **Ansible**: YAML best practices, descriptive variable names in playbooks
- **Scripts**: Python for complex logic (patching), Bash for system automation
- **Naming**: kebab-case for all files (e.g., `vllm-tp2-deploy.yml`)
- **Environment**: `uv` for Python dependency management — never `pip`/`venv` directly
- **All Ansible commands**: use `uv run` for virtual environment execution
- **SSH**: Strict host key checking disabled (`StrictHostKeyChecking=no`) for automation
- **Commits**: Conventional Commits format (`feat:`, `fix:`, `docs:`, `perf:`)

## Troubleshooting

### vLLM Won't Start
```bash
make vllm-logs HOST=100.97.87.120 VLLM_CONTAINER=vllm-server
make cmd COMMAND="docker logs vllm-server --tail 100"
make cmd COMMAND="nvidia-smi"
```

### Out of Memory
- Verify `--gpu-memory-utilization 0.7` (not default 0.9)
- Confirm swap is disabled: `make cmd COMMAND="swapon --show"`
- Reduce `--max-model-len` or `--max-num-seqs`

### Tool Calling Errors (OpenClaw returns 400)
```bash
# Requires --enable-auto-tool-choice
make vllm-single-deploy \
  VLLM_MODEL=Qwen/Qwen3.5-35B-A3B \
  TOOL_CALL_PARSER=qwen3_coder
```

### Slow Inference
- Confirm FlashInfer: `make cmd COMMAND="echo $$VLLM_ATTENTION_BACKEND"`
- Check GPU utilization: `make vllm-status`

## Health Monitoring

```bash
# Real-time unified memory monitoring
make vllm-monitor

# Manual checks
make vllm-status VLLM_CONTAINER=vllm-qwen36 VLLM_PORT=30000
```
