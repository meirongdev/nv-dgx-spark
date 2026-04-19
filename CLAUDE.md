# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ansible-driven deployment of vLLM inference backends + a Bifrost gateway
(`maximhq/bifrost`) onto two NVIDIA DGX Spark (GB10 Blackwell) servers.
The Makefile is the primary entry point; every command is a `uv run ansible-*`
underneath.

**Target hosts** (edit `HOSTS` in Makefile to change):
- `100.97.87.120` — server 1 (hosts Bifrost gateway on :8080)
- `100.67.164.92` — server 2
- SSH: `admin` + `~/.ssh/vgio`
- 200-subnet (`192.168.200.101/102`) is the internal, low-latency link used by the gateway to reach the vLLM backends.

**Current primary stack:** Qwen3.6-35B-A3B-FP8 (ModelScope cache) + Bifrost gateway on server 1.

## Common Commands

```bash
# Bootstrap: venv + inventory + SSH test
make all

# Deploy full stack (vLLM on both servers + gateway on server 1)
make stack-deploy                  # primary model = qwen36
make stack-deploy STACK_MODEL=gemma4   # override

# Check / stop the stack
make stack-status
make stack-stop

# Per-model deploy (all use the same generic playbook):
make vllm-qwen36-deploy            # Qwen3.6-35B-A3B-FP8 (default primary)
make vllm-gemma4-deploy            # Gemma-4-31B-IT-NVFP4
make vllm-qwen-deploy              # Qwen3.5-122B-A10B-NVFP4

# Per-model status / stop / logs (wrappers around generic targets)
make vllm-qwen36-status
make vllm-qwen36-stop
make vllm-qwen36-logs HOST=100.97.87.120

# Generic variants when the wrappers don't fit (custom model names, etc.)
make vllm-status VLLM_CONTAINER=vllm-xyz VLLM_PORT=30000
make vllm-stop   VLLM_CONTAINER=vllm-xyz
make vllm-logs   HOST=... VLLM_CONTAINER=vllm-xyz

# Bifrost gateway
make bifrost-deploy | bifrost-status | bifrost-test | bifrost-stop

# Misc
make ping                          # ansible ping all hosts
make cmd COMMAND="uptime"          # ad-hoc command on all hosts
```

## Adding a new model

1. Add a `VLLM_<NAME>_*` variable block near the top of the Makefile
   (model path, served name, port, etc.). Copy the Qwen3.6 block.
2. Add three Makefile targets at the bottom of the "Per-model vLLM
   Deployments" section: `vllm-<name>-deploy`, `-status`, `-stop`, `-logs`.
   Copy the Qwen3.6 targets and update the `-e` vars and container name.
3. Deploy with `make vllm-<name>-deploy`.
4. To make it the stack default: `make stack-deploy STACK_MODEL=<name>`.

The single playbook `playbooks/vllm-model-deploy.yml` handles all models.
Optional per-model knobs (chat template, runtime patch script, ModelScope
cache mount, model-path validation, containers to clean up) are all just
`-e` variables — see `vllm_chat_template_src`, `vllm_patch_script_src`,
`ms_cache_dir`, `vllm_model_validate_path`, `vllm_cleanup_containers`.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   DGX Spark Cluster                         │
│                                                             │
│  ┌──────────────────┐   200 Gbps  ┌──────────────────┐      │
│  │ Server 1          │ ◄────────► │ Server 2          │      │
│  │ 192.168.200.101   │            │ 192.168.200.102   │      │
│  │ vLLM :30000       │            │ vLLM :30000       │      │
│  │ + Bifrost :8080   │            │                   │      │
│  └──────────────────┘            └──────────────────┘      │
│         ↑ provider=vllm-server1 → pinned to server 1        │
│         ↕ provider=vllm-server2 → pinned to server 2        │
└──────────────────────────┬──────────────────────────────────┘
                           │ Tailscale VPN (100.x)
                  ┌────────▼──────────┐
                  │   Mac (client)    │
                  │ codex --profile dgx        → :8080 Bifrost
                  │ codex --profile dgx-direct → :30000 server 1
                  └───────────────────┘
```

### Bifrost routing (`config/bifrost-config.json`)

Bifrost uses OpenAI-compatible endpoints but requires the `model` field to be
`<provider>/<model>`. Providers are defined in `config/bifrost-config.json`:

| Provider         | Upstream                     | `/v1/responses*` | `/v1/chat/completions` |
|------------------|------------------------------|------------------|-------------------------|
| `vllm-server1`   | `http://192.168.200.101:30000` | ✅ enabled      | ✅ enabled              |
| `vllm-server2`   | `http://192.168.200.102:30000` | ❌ disabled     | ✅ enabled              |

**Stateful Responses API** must pin to `vllm-server1` because
`previous_response_id` references an in-memory store on one node. For chat
completions use whichever provider you prefer (or add a CEL `routing_rule` for
cross-provider load balancing — not currently configured).

**Model names** served by each provider (see `keys[].models` in the config):
- `Qwen3.6-35B-A3B` (current primary)
- `Qwen3.5-122B-A10B`
- `Gemma-4-31B-IT`

`/v1/models` on :8080 returns `{"data": []}` — Bifrost does not proxy upstream
model lists. Use `curl http://100.97.87.120:30000/v1/models` to see what vLLM
actually has loaded.

### Bifrost authentication (virtual keys)

Governance virtual keys are defined under `governance.virtual_keys[]` in
`config/bifrost-config.json`. Clients send the VK value as a Bearer token:

- VK value: `sk-bf-dgx-spark-cluster-2026` (id `dgx-spark-cluster`)
- Allowed providers: `vllm-server1`, `vllm-server2`
- Allowed models: explicit list (`["*"]` wildcard is documented but did not work in testing — use the model names above)

**Caveat:** Bifrost only enforces VK restrictions when the Bearer matches a
defined VK. Unknown/missing Bearers currently fall through without model
restrictions. Treat the 8080 endpoint as "authenticated when on Tailscale",
not as a hardened public API.

## Unified memory constraints (DGX Spark GB10)

- 128 GB LPDDR5X coherent memory shared between CPU and GPU.
- `VLLM_*_GPU_MEM=0.70` is mandatory — anything higher risks OOM freezes of sshd itself.
- Swap **must** be disabled (`swapoff -a`); the playbook does this on every deploy.
- `nvidia-smi` reports `[N/A]` for per-process memory on GB10; don't rely on it — watch `free -h`.

## Connecting from clients

```bash
# Through Bifrost (auth + provider-scoped routing)
export DGX_SPARK_API_KEY=sk-bf-dgx-spark-cluster-2026    # the Bifrost VK value
# model must be <provider>/<model>, e.g. vllm-server1/Qwen3.6-35B-A3B
codex --profile dgx               # → http://100.97.87.120:8080/v1

# Direct to vLLM on server 1 (no auth, bare model name)
export DGX_SPARK_API_KEY=dummy    # vLLM accepts anything when --api-key not set
codex --profile dgx-direct        # → http://100.97.87.120:30000/v1

# Using pi-mono (pi) agent
# Installed globally via npm link from badlogic/pi-mono
export DGX_SPARK_API_KEY=dummy
pi --model dgx-direct/Qwen3.6-35B-A3B -i
```

**Qwen Code CLI** (`.qwen/.env` in this repo) is configured for the Bifrost
path: `OPENAI_BASE_URL=http://100.97.87.120:8080/v1`,
`OPENAI_MODEL=vllm-server1/Qwen3.6-35B-A3B`,
`OPENAI_API_KEY=sk-bf-dgx-spark-cluster-2026`.

## Known Gotchas

### ModelScope symlinks must be relative
ModelScope `snapshot_download` writes weights to `Qwen/Qwen3___6-35B-A3B-FP8`
and creates an **absolute** symlink `Qwen3.6-35B-A3B-FP8 → /home/admin/...`.
Inside the vLLM container (which mounts the cache at `/root/.cache/modelscope`)
the absolute path does not resolve — vLLM then treats the name as an HF repo id
and crashes with `HFValidationError`.

Fix: replace the symlink with a relative one:
```bash
cd /home/admin/.cache/modelscope/Qwen
ln -snf Qwen3___6-35B-A3B-FP8 Qwen3.6-35B-A3B-FP8
```

### Ansible 2.20 + Docker `--format 'table {{.Names}}…'`
Ansible's Jinja2 eats `{{.Names}}` and errors with `Syntax error in template`.
Don't pass `--format 'table {{.X}}'` strings through `ansible -a`; either drop
`--format` or Jinja-escape with `{{ '{{' }}.Names{{ '}}' }}`.

### Qwen3-family tool calling and reasoning
- Tool parser: `qwen3_coder` (set via `vllm_tool_parser`)
- Reasoning parser: `qwen3` (set via `vllm_reasoning_parser`) — responses will
  put the CoT in `.choices[0].message.reasoning`, final answer in `.content`.
- If you query with `max_tokens=10`, you will usually see `content=""` because
  the reasoning alone consumed the budget. Use ≥256 for smoke tests.

### Gemma-4 `skip_special_tokens` patch
`ResponsesRequest` defaults `skip_special_tokens=True`, stripping the
`<|tool_call>` delimiters Gemma-4 emits. Fix is applied at container start by
`scripts/patch-vllm-gemma4-parser.py` (mounted via the entrypoint wrapper).

### Qwen3.5 chat_utils JSON trailing-data crash
Multi-turn tool-call history with the `qwen3_coder` parser can produce a
trailing byte that breaks `json.loads()` in `chat_utils._postprocess_messages`.
Fix: `scripts/patch-vllm-chat-utils.py` wraps the load with
`JSONDecoder.raw_decode()`. Applied by the entrypoint wrapper.

## Key file map

- `Makefile` — single user-facing interface, plus variable defaults per model.
- `playbooks/vllm-model-deploy.yml` — generic deploy playbook used by every model target.
- `playbooks/bifrost-deploy.yml` — deploys the Bifrost gateway container; mounts `config/bifrost-config.json` into `/app/data/config.json`.
- `config/bifrost-config.json` — Bifrost providers, virtual keys, governance.
- `scripts/run-vllm-qwen.sh` — the actual `docker run` launcher (despite the
  name, it drives all models; all vars are env-parameterised).
- `scripts/vllm-entrypoint.sh` + `scripts/patch-vllm-*.py` — runtime patches
  applied inside the container before `vllm serve`.
- `scripts/modelscope-download.sh` — downloads a model from ModelScope into
  `/home/admin/.cache/modelscope` (run via `make modelscope-download MS_MODEL=...`).

## tmux integration (SSH drop protection)

```bash
make tmux-cmd COMMAND="docker pull ..." SESSION="my-task"
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```

## Conventions

- Ansible always runs via `uv run ansible` / `uv run ansible-playbook`.
- To add/remove hosts: edit `HOSTS` in Makefile, then `make inventory`.
- SSH strict host key checking is disabled (automation).
- Gateway routes to backends over the 200-subnet for low latency.
- Pre-built image `vllm-node-tf5:latest` lives on the servers (compatible with driver 580.142).
