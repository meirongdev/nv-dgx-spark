# Copilot instructions — nv-dgx-spark

Purpose: Short, actionable guidance for Copilot sessions working in this repository. Focus on concrete commands, high-level architecture, and repository-specific conventions that Copilot should assume.

---

1) Build, test, and lint (how to run things)

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
- Run an ad-hoc command for a single host:
  - `uv run ansible 100.97.87.120 -i inventory.ini -a "uptime" --ssh-extra-args="-i /Users/matthew/.ssh/vgio"`
- Run a playbook for a single host (limit):
  - `uv run ansible-playbook -i inventory.ini playbooks/vllm-test.yml --limit 100.97.87.120 --ssh-extra-args="-i /Users/matthew/.ssh/vgio" -e "vllm_port=8000"`
- Run a single named task from a playbook (start at task):
  - `uv run ansible-playbook -i inventory.ini playbooks/vllm-test.yml --start-at-task "Test vLLM health endpoint" --limit 100.97.87.120 --ssh-extra-args="-i /Users/matthew/.ssh/vgio"`
- Ad-hoc health check (uri module):
  - `uv run ansible -i inventory.ini -m uri -a 'url=http://localhost:8000/health method=GET status_code=200' --limit 100.67.164.92 --ssh-extra-args="-i /Users/matthew/.ssh/vgio"`

vLLM-specific Make targets (common):
- `make vllm-deploy` (overrides: `VLLM_MODEL`, `VLLM_IMAGE`, `GPU_MEMORY_UTIL`, `VLLM_PORT`)
- `make vllm-test`
- `make vllm-status`
- `make vllm-stop`
- `make vllm-benchmark`
- `make vllm-monitor`

Linting:
- No repository-wide linter enabled. To lint playbooks:
  - `uv run ansible-lint playbooks/` (install `ansible-lint` in the venv first)

---

2) High-level architecture (big picture)

- Purpose: Ansible-based infra to manage NVIDIA DGX Spark nodes, deploy vLLM inference containers, and front them with a Bifrost (`maximhq/bifrost`) OpenAI-compatible gateway.
- Makefile: canonical entrypoint; defines HOSTS, SSH_KEY, SSH_USER and provides wrappers for `uv run ansible` / `uv run ansible-playbook`.
- Inventory: `inventory.ini` is generated from the Makefile (use `make inventory`).
- Environment: `.venv/` created/managed by `uv`; always run Ansible via `uv run`.
- Playbooks: `playbooks/vllm-model-deploy.yml` (generic per-model deploy + hardening), `playbooks/bifrost-deploy.yml` (gateway), plus TP2 playbooks.
- Config: `config/` holds `vllm.env`, `vllm.service`, and `bifrost-config.json` (providers, keys, `governance.virtual_keys`).
- Runtime: vLLM runs in Docker (per-model container names like `vllm-qwen36`). `scripts/` contains helpers for GPU validation and unified-memory monitoring. Bifrost runs as `bifrost-gateway` on server 1 :8080.
- Gateway surface: OpenAI-compatible on `:8080`. Clients must send `model` as `<provider>/<model>` (e.g. `vllm-server1/Qwen3.6-35B-A3B`) and the Bearer token as the virtual key value.
- Typical workflow: `make venv` → `make inventory` → `make vllm-qwen36-deploy` → `make bifrost-deploy` → `make bifrost-test`.

---

3) Key conventions (assume these when generating or modifying code/playbooks)

- Always run Ansible via the venv: use `uv run ansible` / `uv run ansible-playbook`.
- Hosts: edit `HOSTS` in the Makefile and run `make inventory`. Do NOT edit `inventory.ini` unless you know why.
- SSH settings centralized in Makefile:
  - `SSH_KEY` defaults to `/Users/matthew/.ssh/vgio`
  - `SSH_USER` defaults to `admin`
  - `StrictHostKeyChecking=no` is intentionally used for automation
- Makefile env → playbook var mappings (use these when suggesting overrides):
  - `VLLM_IMAGE` → `vllm_image`
  - `VLLM_MODEL` → `vllm_model`
  - `VLLM_PORT` → `vllm_port`
  - `GPU_MEMORY_UTIL` → `gpu_memory_utilization`
  - `TOOL_CALL_PARSER` → `tool_call_parser`
  - `TP2_*` → `tp2_*`
- Container & service names: per-model vLLM containers (`vllm-qwen`, `vllm-gemma4`, `vllm-qwen36`); Bifrost gateway container `bifrost-gateway`; systemd unit `config/vllm.service`.
- Unified memory and operational constraints (important):
  - GB10/GPU unified memory requires swap disabled; set `GPU_MEMORY_UTIL` ≈ `0.7` to leave headroom.
  - For Blackwell/GB10, `VLLM_ATTENTION_BACKEND=FLASHINFER` and `VLLM_USE_FLASHINFER_MOE_FP8=1` are recommended for performance where appropriate.
- Use tmux for long-running remote tasks (helpers available: `make tmux-vllm-deploy`, `make tmux-cmd`, `make tmux-benchmark`).

---

4) Where to look (primary sources for Copilot guidance)

- `Makefile` — canonical commands and env overrides
- `CLAUDE.md` — detailed deployment notes and critical operational warnings
- `README.md` — project overview and examples
- `playbooks/`, `config/`, `scripts/` — deployment tasks, env templates, and helpers
- `inventory.ini` — generated inventory; useful for SSH details

---

5) AI assistant configs present

- `CLAUDE.md` — long-form deployment and operational guidance; consult for memory/FlashInfer specifics
- `QWEN.md` — model notes
- Existing `.github/copilot-instructions.md` (this file is the canonical Copilot guidance; updated periodically)

---

Quick tips for Copilot sessions

- Prefer concrete Makefile/uv commands when suggesting CLI snippets (avoid inventing new top-level scripts).
- When proposing changes to inventory or hosts, suggest edits to the Makefile HOSTS and running `make inventory` rather than editing `inventory.ini` directly.
- Cite playbooks and config files when suggesting variable names or defaults (e.g., `gpu_memory_utilization` in playbooks).

---

If you want this update applied to the repo, approve the change when prompted. If more detailed task/tag maps or playbook annotations are desired, request a follow-up and those can be added.
