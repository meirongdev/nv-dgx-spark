# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ansible-based infrastructure project for managing NVIDIA DGX Spark servers. The Makefile is the primary interface for all operations.

**Target Hosts:** `100.97.87.120`, `100.67.164.92` (SSH user: `admin`, key: `~/.ssh/vgio`)

**Current Stack:** vLLM serving Gemma-4-31B-IT (NVFP4) on both servers + LLM Gateway (FastAPI reverse proxy) on port 8080

## Connecting Codex to the DGX Cluster

### Direct connection (testing / single-user)

Connect Codex directly to vLLM on server 1, bypassing the gateway:

```bash
export DGX_SPARK_API_KEY=dummy    # vLLM accepts any key when --api-key not set
codex --profile dgx-direct
```

Codex profile `dgx-direct` points to `http://100.97.87.120:30000/v1` — vLLM on server 1.  
Use this to verify a new model deployment works before enabling the gateway.

### Gateway connection (production / multi-user)

```bash
export DGX_SPARK_API_KEY=dummy
codex --profile dgx
```

Codex profile `dgx` uses the LLM Gateway at `http://100.97.87.120:8080/v1`.  
The gateway routes `/v1/responses*` (Codex stateful API) exclusively to server 1, and
load-balances `/v1/chat/completions` across both servers.

## Common Commands

```bash
# Setup: create venv, generate inventory, test connections
make all

# Install Ansible into venv
make venv

# Test SSH connectivity
make ping

# Run ad-hoc command on all hosts
make cmd COMMAND="uptime"
```

## vLLM + LLM Gateway Stack

```bash
# Deploy full stack (vLLM Gemma-4 on both servers + LLM Gateway)
make stack-deploy

# Check status of everything
make stack-status

# Stop full stack
make stack-stop

# Individual vLLM operations (Gemma-4)
make vllm-gemma4-deploy            # Deploy vLLM Gemma-4-31B-IT on all hosts
make vllm-gemma4-status            # Check vLLM containers + API
make vllm-gemma4-stop              # Stop vLLM on all hosts
make vllm-gemma4-logs HOST=100.97.87.120

# LLM Gateway operations
make gateway-deploy                 # Build and deploy FastAPI gateway on Server 1
make gateway-test                   # Test health endpoint + models list
make gateway-status                 # Check gateway container + health
make gateway-stop                   # Stop gateway
```

### LLM Gateway Routing Logic

The gateway (`gateway/app.py`) routes as follows:

| Endpoint | Routing | Reason |
|----------|---------|--------|
| `/v1/responses*` | Server 1 only (sticky) | OpenAI Responses API is stateful — `previous_response_id` references an in-memory response store on the server that created the response. Cross-server routing causes 404. |
| `/v1/chat/completions` | Round-robin server 1 + 2 | Stateless — any server can handle any request |
| Everything else | Server 1 (fallback) | Health, models, embeddings, etc. |

### vLLM Gemma-4 Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_GEMMA4_PORT` | `30000` | API port |
| `VLLM_GEMMA4_GPU_MEM` | `0.70` | GPU memory fraction |
| `VLLM_GEMMA4_KV_DTYPE` | `fp8_e4m3` | KV cache dtype |
| `GATEWAY_HOST` | `100.97.87.120` | Gateway host |
| `GATEWAY_PORT` | `8080` | Gateway port |
| `VLLM_SERVER1_URL` | `http://192.168.200.101:30000` | Server 1 backend URL |
| `VLLM_SERVER2_URL` | `http://192.168.200.102:30000` | Server 2 backend URL |

### Critical: Unified Memory Constraints

- DGX Spark GB10 has 128GB unified memory shared between CPU and GPU
- **Swap MUST be disabled** (`swapoff -a`) — the deploy playbook handles this
- Set `VLLM_GEMMA4_GPU_MEM=0.70` to leave headroom (~89.6GB for model + KV cache)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DGX Spark Cluster                        │
│                                                             │
│  ┌──────────────────┐   200Gbps internal   ┌─────────────┐ │
│  │  Server 1         │  ◄───────────────►  │  Server 2   │ │
│  │  192.168.200.101  │  (enp1s0f0np0)      │192.168.200.102│ │
│  │  vLLM :30000      │                     │ vLLM :30000  │ │
│  │  Gemma-4-31B-IT   │                     │ Gemma-4-31B  │ │
│  │  + Gateway :8080  │                     │              │ │
│  └──────────────────┘                      └─────────────┘ │
│          ↑ /v1/responses (sticky)                          │
│          ↕ /v1/chat/completions (round-robin both)         │
└──────────────────────────┬──────────────────────────────────┘
                           │ Tailscale VPN (100.x)
                  ┌────────▼──────────┐
                  │   Mac (client)    │
                  │  codex --profile dgx          → :8080 (gateway)
                  │  codex --profile dgx-direct   → :30000 (direct)
                  └───────────────────┘
```

## Known Fixes Applied

### 1. Gemma-4 skip_special_tokens (commit 175b12b)
`ResponsesRequest` defaults `skip_special_tokens=True`, which strips the `<|tool_call>` delimiters
Gemma-4 uses in its tool call format, producing garbled output (`call:shell{command:...}`).

Fix: `scripts/patch-vllm-gemma4-parser.py` patches `adjust_request()` in `gemma4_tool_parser.py`
to set `skip_special_tokens=False` for both `ChatCompletionRequest` and `ResponsesRequest`.
Applied at container startup by `vllm-entrypoint.sh`.

### 2. Responses API stateful routing (this session)
OpenAI Responses API stores each response in vLLM's in-memory `response_store`. The next request
includes `previous_response_id` which references that store. Bifrost's round-robin routing sent
turn 2 to the wrong server → 404 `"Response not found"` → Codex showed errors.

Fix: Replaced Bifrost with a custom FastAPI gateway (`gateway/`) that routes all `/v1/responses*`
traffic to server 1 exclusively, while still load-balancing `/v1/chat/completions`.

### 3. Developer role support (earlier)
Qwen3.5 chat template rejects `developer` role. Fixed via custom Jinja2 template.

## Key Conventions

- All Ansible commands use `uv run` to stay within the venv
- To add/remove hosts: edit `HOSTS` in Makefile, then run `make inventory`
- SSH strict host key checking disabled for automation
- Gateway uses 200-subnet internal IPs for low-latency backend routing
- vLLM image `vllm-node-tf5:latest` is pre-built on servers (compatible with driver 580.142)

## tmux Integration (SSH Drop Protection)

```bash
make tmux-cmd COMMAND="docker pull ..." SESSION="my-task"
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```


## Model Inventory (as of 2026-04)

| Model | Server 1 | Server 2 | Notes |
|-------|----------|----------|-------|
| `bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4` | ✅ 72GB | ✅ 72GB | **Currently deployed** |
| `nvidia/Qwen3.5-397B-A17B-NVFP4` | ✅ 240GB | ✅ 228GB | Too large for single-server |
| `Qwen3-235B-A22B-NVFP4` | ✅ 125GB | ❌ | Likely too large (>89.6GB usable at 0.7) |
| `Qwen/Qwen3.5-35B-A3B` | ❌ tokenizer only | ❌ | No weights cached |
| `Jackrong/Qwen3.5-35B-A3B-*` | ❌ 20KB metadata | ❌ 4/14 shards (incomplete) | Cannot use |

> **Note:** No complete Qwen3.5-35B is available in vLLM-compatible format on either server.
> Any Qwen3.5 model still requires the custom chat template (`config/qwen3.5-chat-template.jinja2`)
> for `developer` role support. Switching model size does not remove this requirement.

## Common Commands

```bash
# Setup: create venv, generate inventory, test connections
make all

# Install Ansible into venv
make venv

# Test SSH connectivity
make ping

# Run ad-hoc command on all hosts
make cmd COMMAND="uptime"
```

## vLLM + Bifrost Stack

```bash
# Deploy full stack (vLLM on both servers + Bifrost gateway)
make stack-deploy

# Check status of everything
make stack-status

# Stop full stack
make stack-stop

# Individual vLLM operations
make vllm-qwen-deploy              # Deploy vLLM Qwen on all hosts
make vllm-qwen-test                # Test vLLM endpoints + tool calling
make vllm-qwen-status              # Check vLLM containers + API
make vllm-qwen-stop                # Stop vLLM on all hosts
make vllm-qwen-logs HOST=100.97.87.120  # View vLLM logs

# Individual Bifrost operations
make bifrost-deploy             # Deploy Bifrost gateway on Server 1
make bifrost-test               # Test Bifrost routing + benchmarks
make bifrost-status             # Check Bifrost health
make bifrost-stop               # Stop Bifrost
```

### vLLM Qwen Configuration (overridable via Makefile vars)

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_QWEN_IMAGE` | `vllm-node-tf5:latest` | Docker image (pre-built on servers) |
| `VLLM_QWEN_MODEL` | `bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4` | HuggingFace model |
| `VLLM_QWEN_SERVED` | `Qwen3.5-122B-A10B` | Served model name for API |
| `VLLM_QWEN_PORT` | `30000` | API port |
| `VLLM_QWEN_GPU_MEM` | `0.70` | GPU memory fraction (critical for unified memory) |
| `VLLM_QWEN_KV_DTYPE` | `fp8_e4m3` | KV cache dtype for GB10 |
| `VLLM_QWEN_TOOL_PARSER` | `qwen3_coder` | Tool call parser for agent support |

### Critical: Unified Memory Constraints

- DGX Spark GB10 has 128GB unified memory shared between CPU and GPU
- **Swap MUST be disabled** (`swapoff -a`) — the deploy playbook handles this
- Set `VLLM_QWEN_GPU_MEM=0.70` to leave headroom (~89.6GB for model + KV cache)
- The NVFP4 model uses ~72GB; remaining ~17GB is for KV cache

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DGX Spark Cluster                        │
│                                                             │
│  ┌──────────────────┐   200Gbps internal   ┌─────────────┐ │
│  │  Server 1         │  ◄───────────────►  │  Server 2    │ │
│  │  192.168.200.101  │  (enp1s0f0np0)      │192.168.200.102│ │
│  │  vLLM :30000      │                     │ vLLM :30000  │ │
│  │  Qwen3.5-122B    │                     │ Qwen3.5-122B  │ │
│  │  + Bifrost :8080  │                     │               │ │
│  └──────────────────┘                      └──────────────┘ │
│                   Bifrost LB (round-robin + failover)        │
└──────────────────────────┬──────────────────────────────────┘
                           │ Tailscale VPN (100.x)
                  ┌────────▼─────────┐
                  │   Mac (client)    │
                  │  Codex → :8080    │
                  │  OpenClaw → :8080 │
                  └──────────────────┘
```

- **Makefile** — single entry point; defines hosts, SSH key, and all targets
- **inventory.ini** — generated by `make inventory`
- **`.venv/`** — managed by `uv`; Ansible runs via `uv run ansible`
- **vLLM** — inference server on both nodes (port 30000), image: `vllm-node-tf5:latest`
- **Bifrost** — load balancer on Server 1 (port 8080), routes via 200-subnet

## Known Fixes Applied

### 1. Developer role support (commit b92c6b9, 08877e6)
Qwen3.5 chat template rejects `developer` role. Fixed via custom Jinja2 template
(`config/qwen3.5-chat-template.jinja2`) that normalizes `developer` → `system` (leading
messages) or `user` (mid-conversation).

### 2. Tool call JSON "Extra data" error (commit e02bd72)
`vllm/entrypoints/chat_utils.py:_postprocess_messages()` calls `json.loads()` on tool
call arguments in multi-turn history. The qwen3_coder streaming parser can produce
arguments with trailing bytes, causing `JSONDecodeError: Extra data`.

Fix: wrap with `try/except` + `JSONDecoder.raw_decode()` fallback (ignores trailing data).
**Persistent:** `scripts/patch-vllm-chat-utils.py` is mounted in the container and run by
`scripts/vllm-entrypoint.sh` before every vLLM start. Re-applied automatically on restart.



- All Ansible commands use `uv run` to stay within the venv
- To add/remove hosts: edit `HOSTS` in Makefile, then run `make inventory`
- SSH strict host key checking disabled for automation
- Bifrost uses 200-subnet internal IPs for low-latency backend routing
- vLLM CLI flags: use `fp8_e4m3` not `fp8` for `--kv-cache-dtype`
- vLLM image `vllm-node-tf5:latest` is pre-built on servers (compatible with driver 580.142)

## tmux Integration (SSH Drop Protection)

```bash
make tmux-cmd COMMAND="docker pull ..." SESSION="my-task"
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```
