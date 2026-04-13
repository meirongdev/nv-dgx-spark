# Copilot instructions — nv-dgx-spark

Purpose: Short, actionable guidance for Copilot sessions working in this repository (commands, high-level architecture, and repository-specific conventions).

---

## 1) Build, test, and lint (how to run things)

Note: The Makefile is the canonical entry point; Ansible is executed via `uv run` inside the `.venv` created by `uv venv .venv`.

- Create venv / install Ansible:
  - `make venv`  (alias: `make install`)
- Full setup (venv + inventory + connectivity test):
  - `make all`
- Regenerate inventory from Makefile HOSTS:
  - `make inventory`  (edit HOSTS in Makefile first)
- Test connectivity / ping:
  - `make ping` or `make test`
- Run an ad-hoc command (all hosts):
  - `make cmd COMMAND="uptime"`
- Run an ad-hoc command for a single host directly (example):
  - `uv run ansible 100.97.87.120 -i inventory.ini -a "uptime" --ssh-extra-args="-i /Users/matthew/.ssh/vgio"`
- Run a playbook for a single host (limit):
  - `uv run ansible-playbook -i inventory.ini playbooks/vllm-test.yml --limit 100.97.87.120 --ssh-extra-args="-i /Users/matthew/.ssh/vgio" -e "vllm_port=8000"`
  - To start at a particular task: add `--start-at-task "Task Name"`
- vLLM deploy / test / status / stop / benchmark / monitor (Makefile targets):
  - `make vllm-deploy` (overrides: `VLLM_MODEL`, `VLLM_IMAGE`, `GPU_MEMORY_UTIL`, `VLLM_PORT`)
  - `make vllm-test`
  - `make vllm-status`
  - `make vllm-stop`
  - `make vllm-benchmark`
  - `make vllm-monitor`
- Clean workspace:
  - `make clean`

Linting: No repository-wide linter configured. To lint playbooks manually (optional):
- `uv run ansible-lint playbooks/` (install `ansible-lint` in the venv first)

---

## 2) High-level architecture (big picture)

- Purpose: Ansible-based infrastructure to manage NVIDIA DGX Spark nodes and deploy vLLM inference containers.
- Makefile: single entry point (defines `HOSTS`, `SSH_KEY`, `SSH_USER`, and provides wrappers for `ansible` / `ansible-playbook` using `uv run`).
- Inventory: `inventory.ini` is generated from `HOSTS` in the Makefile (`make inventory`).
- Environment: `.venv/` created/managed by `uv` (use `uv run` to execute Ansible and related tools inside it).
- Playbooks: `playbooks/vllm-deploy.yml` (deployment + hardening) and `playbooks/vllm-test.yml` (validation).
- Config: `config/` holds `vllm.env` and `vllm.service` systemd template used by the deployment.
- Runtime: vLLM runs inside a Docker container (expected name: `vllm-server`). Scripts under `scripts/` provide GPU validation and unified-memory monitoring.
- Typical workflow: `make venv` → `make inventory` → `make vllm-deploy` → `make vllm-test` → monitor via `make vllm-status` / `make vllm-monitor`.

---

## 3) Key repository conventions (what Copilot should assume)

- Always run Ansible via the venv: use `uv run ansible` / `uv run ansible-playbook` (the Makefile and CLAUDE.md rely on this).
- Hosts management: edit `HOSTS` in the Makefile and run `make inventory`. Do not edit `inventory.ini` directly unless you know why.
- SSH settings are centralized in the Makefile:
  - `SSH_KEY` defaults to `/Users/matthew/.ssh/vgio`
  - `SSH_USER` defaults to `admin`
  - `StrictHostKeyChecking=no` is intentionally used for automation
- Configuration-by-env: The Makefile exposes environment overrides for deployments: `VLLM_IMAGE`, `VLLM_MODEL`, `VLLM_PORT`, `GPU_MEMORY_UTIL`.
- Container and service names: playbooks and helpers assume a container named `vllm-server` and a systemd unit based on `config/vllm.service`.
- Monitoring and debugging helpers are available (`make vllm-status`, `make vllm-benchmark`, `make vllm-monitor`, `scripts/monitor-unified-memory.sh`).

Operational constraints (from CLAUDE.md — important to preserve in automation suggestions):
- DGX Spark uses unified coherent memory: swap must be disabled; leaving headroom is critical. Default `GPU_MEMORY_UTIL` ~ `0.7` is recommended.
- FlashInfer backend is recommended for Blackwell/GB10: set `VLLM_ATTENTION_BACKEND=FLASHINFER` and `VLLM_USE_FLASHINFER_MOE_FP8=1` for MoE/FP8 acceleration when appropriate.
- Avoid cross-node TP=2 defaults unless tested — single-node vLLM per DGX Spark is the stable pattern here.

---

## 4) Where to look for details

- `Makefile` — canonical commands and env overrides
- `CLAUDE.md` — detailed deployment notes, memory and performance considerations (critical operational warnings)
- `playbooks/`, `config/`, `scripts/` — deployment tasks, environment, and monitoring utilities
- `inventory.ini` — generated inventory. Use as a quick reference for hosts and SSH config

---

## 5) Other AI assistant configs found

- `CLAUDE.md` (detailed guidance)
- `QWEN.md`
- No `.github/copilot-instructions.md` existed prior to this file creation.

---

If more targeted content is desired (e.g., Playbook task/tag map, example `uv run` invocations, or a mapping of Makefile overrides to playbook variables), request the specific area and it will be added.

---

Additions (2026-04-13):

1) Single-test examples

- Run a single named task from the test playbook (start at the named task):
  - uv run ansible-playbook -i inventory.ini playbooks/vllm-test.yml --start-at-task "Test vLLM health endpoint" --ssh-extra-args="-i /Users/matthew/.ssh/vgio" --limit 100.97.87.120

- Run only one host (limit):
  - uv run ansible-playbook -i inventory.ini playbooks/vllm-test.yml --limit 100.67.164.92 --ssh-extra-args="-i /Users/matthew/.ssh/vgio"

- Run a focused ad-hoc health check (uri module):
  - uv run ansible servers -i inventory.ini -m uri -a 'url=http://localhost:8000/health method=GET status_code=200' --ssh-extra-args="-i /Users/matthew/.ssh/vgio" --limit 100.67.164.92

- Run the local benchmarking script for a single host:
  - ./scripts/vllm-benchmark.sh 100.67.164.92 /Users/matthew/.ssh/vgio admin

- TP=2 / distributed launcher:
  - See scripts/run-vllm-tp2.sh header for required env vars (TP2_MODEL, TP2_MASTER_ADDR, TP2_NODE_RANK, TP2_NNODES). Use the script to start per-node containers for tensor-pipeline=2 experiments.

2) Makefile env -> playbook variable mapping

- VLLM_IMAGE -> vllm_image (playbooks)
- VLLM_MODEL -> vllm_model
- VLLM_PORT -> vllm_port
- GPU_MEMORY_UTIL -> gpu_memory_utilization
- TP2_* -> tp2_* (tp2_image, tp2_model, tp2_coordinator, etc.)

If you'd like, I can expand these additions into a dedicated section or produce a full replacement of this file with a more exhaustive Copilot guide.
