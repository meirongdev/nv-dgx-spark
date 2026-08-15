.PHONY: venv install test ping all clean vllm-status vllm-stop vllm-logs vllm-qwen-deploy vllm-qwen-test vllm-qwen-status vllm-qwen-stop vllm-qwen-logs vllm-gemma4-deploy vllm-gemma4-status vllm-gemma4-stop vllm-gemma4-logs vllm-qwen36-deploy vllm-qwen36-status vllm-qwen36-stop vllm-qwen36-logs bifrost-deploy bifrost-test bifrost-stop bifrost-status stack-deploy stack-stop stack-status unify-system unify-status tmux-cmd tmux-attach tmux-list tmux-kill modelscope-download remove-thunderbird llmfit-install llmfit-cmd v4flash-run v4flash-status v4flash-logs v4flash-logs-worker v4flash-test v4flash-load v4flash-stop v4flash-restart v4flash-autostart v4flash-autostart-start v4flash-autostart-status v4flash-autostart-remove qwen38-run qwen38-status qwen38-test qwen38-logs qwen38-stop node-exporter-deploy node-exporter-status node-exporter-stop node-exporter-logs smartctl-exporter-deploy smartctl-exporter-status smartctl-exporter-stop smartctl-exporter-logs

# Ansible inventory file
INVENTORY := inventory.ini
# SSH private key
SSH_KEY := /Users/matthew/.ssh/vgio
# SSH user
SSH_USER := admin
# Remote hosts
HOSTS := 100.97.87.120 100.67.164.92
# Limit a per-model deploy to specific host(s) via Ansible --limit. Empty = all hosts.
# Per-model deploy targets set a sensible default (qwen36 -> server1);
# override on the CLI, e.g. `make vllm-qwen36-deploy LIMIT=100.67.164.92`, or `LIMIT=` for both.
LIMIT ?=
# Default API port for the generic vllm-status helper (per-model wrappers override it).
VLLM_PORT ?= 8000

# Bifrost gateway (maximhq/bifrost). Sole gateway in front of vLLM.
# Config in config/bifrost-config.json (providers + governance.virtual_keys).
BIFROST_HOST ?= 100.97.87.120
BIFROST_PORT ?= 8080
BIFROST_IMAGE ?= maximhq/bifrost:latest

# vLLM Qwen3.5 configuration (single-node inference with tool calling)
VLLM_QWEN_IMAGE ?= vllm-node-tf5:latest
VLLM_QWEN_MODEL ?= bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4
VLLM_QWEN_SERVED ?= Qwen3.5-122B-A10B
VLLM_QWEN_PORT ?= 30000
VLLM_QWEN_GPU_MEM ?= 0.70
VLLM_QWEN_KV_DTYPE ?= fp8_e4m3
VLLM_QWEN_TOOL_PARSER ?= qwen3_coder
VLLM_QWEN_REASONING ?= qwen3
VLLM_QWEN_MAX_MODEL_LEN ?= 262144

# vLLM Gemma4 configuration (native developer role + tool calling)
VLLM_GEMMA4_IMAGE ?= vllm-node-tf5:latest
VLLM_GEMMA4_MODEL ?= /root/.cache/huggingface/hub/Gemma-4-31B-IT-NVFP4
VLLM_GEMMA4_SERVED ?= Gemma-4-31B-IT
VLLM_GEMMA4_PORT ?= 30000
VLLM_GEMMA4_GPU_MEM ?= 0.70
VLLM_GEMMA4_KV_DTYPE ?= fp8_e4m3
VLLM_GEMMA4_MAX_MODEL_LEN ?= 262144

# vLLM Qwen3.6 configuration (no patches needed, uses ModelScope cache)
VLLM_QWEN36_IMAGE ?= vllm-node-tf5:latest
VLLM_QWEN36_MODEL ?= /root/.cache/modelscope/Qwen/Qwen3.6-35B-A3B-FP8
VLLM_QWEN36_SERVED ?= Qwen3.6-35B-A3B
VLLM_QWEN36_PORT ?= 30000
VLLM_QWEN36_GPU_MEM ?= 0.70
VLLM_QWEN36_KV_DTYPE ?= fp8_e4m3
# 262144 = 256K (model's native max_position_embeddings). Can be pushed to
# 1M with YARN rope-scaling but that needs extra --rope-scaling args and
# trades quality for length.
VLLM_QWEN36_MAX_MODEL_LEN ?= 262144

# Prometheus Node Exporter (host metrics for the homelab Grafana/Prometheus stack).
# Runs as a docker container (--net=host --pid=host) on BOTH servers; homelab
# Prometheus scrapes :9100 over Tailscale (job node-exporter-dgx-spark). Image is
# pulled via the daocloud mirror (CN-reliable) and retagged to the canonical name.
NODE_EXPORTER_IMAGE ?= quay.io/prometheus/node-exporter:v1.10.0
NODE_EXPORTER_MIRROR_IMAGE ?= quay.m.daocloud.io/prometheus/node-exporter:v1.10.0
NODE_EXPORTER_PORT ?= 9100
# Host used by node-exporter-logs (single host; deploy/status hit all hosts).
NODE_EXPORTER_LOG_HOST ?= 100.97.87.120

# smartctl Exporter (NVMe/SSD SMART disk health for the homelab Grafana/Prometheus
# stack). HOST systemd service (User=root → reads /dev/nvme*) on BOTH servers; homelab
# Prometheus scrapes :9633 over Tailscale (job smartctl-dgx-spark). NOT a container:
# quay smartctl-exporter is amd64-only, so we install the GitHub linux-arm64 binary
# (downloaded on the control machine — DGX can't reach github.com — and shipped over
# SSH; smartctl is already present in DGX OS). Playbook: smartctl-exporter-deploy.yml.
SMARTCTL_EXPORTER_VERSION ?= 0.14.0
SMARTCTL_EXPORTER_ARCH ?= linux-arm64
SMARTCTL_EXPORTER_PORT ?= 9633
SMARTCTL_EXPORTER_LOG_HOST ?= 100.97.87.120

# Create virtual environment and install Ansible
venv:
	uv venv .venv
	uv pip install ansible

# Install dependencies (alias for venv)
install: venv

# Test SSH connection to all hosts
test:
	uv run ansible all -i $(INVENTORY) -m ping --ssh-extra-args="-i $(SSH_KEY)"

# Ping all hosts
ping:
	uv run ansible all -i $(INVENTORY) -m ping --ssh-extra-args="-i $(SSH_KEY)"

# Gather facts from all hosts
facts:
	uv run ansible all -i $(INVENTORY) -m setup --ssh-extra-args="-i $(SSH_KEY)" -l

# Run ad-hoc command on all hosts (usage: make cmd COMMAND="uptime")
cmd:
	uv run ansible all -i $(INVENTORY) -a "$(COMMAND)" --ssh-extra-args="-i $(SSH_KEY)"

# Generate inventory file
inventory:
	@echo "[servers]" > $(INVENTORY)
	@for host in $(HOSTS); do \
		echo "$$host ansible_user=$(SSH_USER) ansible_ssh_private_key_file=$(SSH_KEY) ansible_ssh_common_args='-o StrictHostKeyChecking=no'" >> $(INVENTORY); \
	done
	@echo "Inventory file created: $(INVENTORY)"
	@cat $(INVENTORY)

# Setup everything
all: venv inventory test

# Clean up
clean:
	rm -rf .venv $(INVENTORY)

# ========================================
# System Unification Commands
# ========================================

# Unify kernel and NVIDIA driver versions across all hosts
unify-system:
	@echo "========================================"
	@echo "Unifying system versions across hosts..."
	@echo "Target: NVIDIA Driver 580.142, Latest HWE Kernel"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/unify-system.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

# Check system versions on all hosts
unify-status:
	@echo "========================================"
	@echo "System Version Status"
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "bash -c 'echo \"Host: \$$(hostname)\"; echo \"OS: \$$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d \\\")\"; echo \"Kernel: \$$(uname -r)\"; echo \"Driver: \$$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo N/A)\"; echo \"\"'" \
		--ssh-extra-args="-i $(SSH_KEY)"

# Remove Thunderbird from all hosts
remove-thunderbird:
	@echo "========================================"
	@echo "Removing Thunderbird from all hosts..."
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/remove-thunderbird.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

# ========================================
# llmfit CLI Installation
# ========================================
llmfit-install:
	@echo "========================================"
	@echo "Installing llmfit CLI on all hosts..."
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/llmfit-install.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

llmfit-cmd:
	uv run ansible all -i $(INVENTORY) -a "$(COMMAND)" --ssh-extra-args="-i $(SSH_KEY)"

# ========================================
# tmux Integration for SSH Resilience
# ========================================
# Best practices from:
# - W&B ML Practitioner Guide (2022)
# - DataMade Team Conventions
# - tmux-trainsh Project (2026)
# - DevOps tmux Best Practices (2025)

# Run any command in a named tmux session on remote hosts
# Usage: make tmux-cmd COMMAND="docker pull nvcr.io/nvidia/vllm:26.01-py3" SESSION="my-task"
tmux-cmd:
ifndef SESSION
	$(error SESSION is required. Usage: make tmux-cmd COMMAND="..." SESSION="session-name")
endif
	@echo "========================================"
	@echo "Running command in tmux session: $(SESSION)"
	@echo "========================================"
	@for host in $(HOSTS); do \
		echo "--- $$host ---" && \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$host \
			"tmux new-session -d -s $(SESSION) '$(COMMAND)' 2>/dev/null || \
			 (tmux kill-session -t $(SESSION) 2>/dev/null; tmux new-session -d -s $(SESSION) '$(COMMAND)') && \
			 echo 'Command sent to tmux session \"$(SESSION)\"' && \
			 echo 'Reattach: ssh -i $(SSH_KEY) $(SSH_USER)@$$host \"tmux attach -t $(SESSION)\"' && \
			 echo 'Detach:  Ctrl+B, then D'"; \
	done

# Reattach to a tmux session on a specific host
# Usage: make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
tmux-attach:
ifndef HOST
	$(error HOST is required. Usage: make tmux-attach HOST=100.97.87.120 SESSION=session-name)
endif
ifndef SESSION
	$(error SESSION is required. Usage: make tmux-attach HOST=100.97.87.120 SESSION=session-name)
endif
	@echo "Attaching to tmux session '$(SESSION)' on $(HOST)..."
	@echo "Press Ctrl+B, then D to detach without stopping the session"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) "tmux attach -t $(SESSION) || echo 'Session not found. Run: make tmux-list HOST=$(HOST)'"

# List all tmux sessions on a specific host
# Usage: make tmux-list HOST=100.97.87.120
tmux-list:
ifndef HOST
	$(error HOST is required. Usage: make tmux-list HOST=100.97.87.120)
endif
	@echo "========================================"
	@echo "tmux sessions on $(HOST)"
	@echo "========================================"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) \
		"tmux list-sessions -F '#S (created #S, #W windows, #P panes)' 2>/dev/null || echo 'No active tmux sessions'"

# Kill a tmux session on a specific host
# Usage: make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
tmux-kill:
ifndef HOST
	$(error HOST is required. Usage: make tmux-kill HOST=100.97.87.120 SESSION=session-name)
endif
ifndef SESSION
	$(error SESSION is required. Usage: make tmux-kill HOST=100.97.87.120 SESSION=session-name)
endif
	@echo "Killing tmux session '$(SESSION)' on $(HOST)..."
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) \
		"tmux kill-session -t $(SESSION) && echo 'Session killed' || echo 'Session not found'"

# Download a model from ModelScope inside tmux (survives SSH disconnection)
# Usage: make modelscope-download [MS_MODEL=Qwen/Qwen3.6-35B-A3B-FP8]
MS_MODEL ?= Qwen/Qwen3.6-35B-A3B-FP8
MS_VENV ?= /home/admin/modelscope-venv
MS_CACHE ?= /home/admin/.cache/modelscope
MS_SESSION ?= ms-download

modelscope-download:
	@echo "========================================"
	@echo "Downloading $(MS_MODEL) via ModelScope"
	@echo "Session: $(MS_SESSION) | Cache: $(MS_CACHE)"
	@echo "========================================"
	@for host in $(HOSTS); do \
		echo "--- $$host ---" && \
		scp -i $(SSH_KEY) -o StrictHostKeyChecking=no \
			scripts/modelscope-download.sh \
			$(SSH_USER)@$$host:/tmp/modelscope-download.sh && \
		ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$$host \
			"chmod +x /tmp/modelscope-download.sh; \
			 tmux kill-session -t $(MS_SESSION) 2>/dev/null || true; \
			 tmux new-session -d -s $(MS_SESSION) \
			   '/tmp/modelscope-download.sh $(MS_MODEL) $(MS_CACHE) 2>&1 | tee /tmp/$(MS_SESSION).log; echo done'" && \
		echo "Started on $$host" && \
		echo "  Watch: make tmux-attach HOST=$$host SESSION=$(MS_SESSION)" && \
		echo "  Log:   ssh -i $(SSH_KEY) $(SSH_USER)@$$host tail -f /tmp/$(MS_SESSION).log"; \
	done

# ========================================
# Per-model vLLM Deployments
# ========================================
# All per-model targets below invoke the SAME generic playbook
# (playbooks/vllm-model-deploy.yml). Adding a new model = add a new
# triple of targets (deploy/status/stop) that sets the appropriate
# VLLM_* vars. See the Qwen3.6 target for the canonical template.
#
# Generic Makefile helpers:
#   vllm-status CONTAINER=...     show container + API + GPU
#   vllm-stop   CONTAINER=...     docker rm -f CONTAINER on all hosts
#   vllm-logs   HOST=... CONTAINER=...   follow logs on one host

VLLM_CONTAINER ?=

vllm-status:
ifeq ($(strip $(VLLM_CONTAINER)),)
	$(error VLLM_CONTAINER is required. Usage: make vllm-status VLLM_CONTAINER=vllm-qwen36 [VLLM_PORT=30000])
endif
	@echo "======== $(VLLM_CONTAINER) status ========"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "echo '--- Container ---' && docker ps --filter name=$(VLLM_CONTAINER) && echo '--- API ---' && curl -sf -m 3 http://localhost:$(VLLM_PORT)/v1/models 2>/dev/null | python3 -m json.tool || echo 'Not responding' && echo '--- GPU ---' && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader" \
		--ssh-extra-args="-i $(SSH_KEY)"

vllm-stop:
ifeq ($(strip $(VLLM_CONTAINER)),)
	$(error VLLM_CONTAINER is required. Usage: make vllm-stop VLLM_CONTAINER=vllm-qwen36)
endif
	@echo "Stopping $(VLLM_CONTAINER) on all hosts..."
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker rm -f $(VLLM_CONTAINER) 2>/dev/null && echo 'stopped' || echo 'was not running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

vllm-logs:
ifndef HOST
	$(error HOST is required. Usage: make vllm-logs HOST=100.97.87.120 VLLM_CONTAINER=vllm-qwen36)
endif
ifeq ($(strip $(VLLM_CONTAINER)),)
	$(error VLLM_CONTAINER is required. Usage: make vllm-logs HOST=... VLLM_CONTAINER=vllm-qwen36)
endif
	ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) "docker logs --tail 100 -f $(VLLM_CONTAINER)"

# ----------------------------------------
# Qwen3.5-122B-A10B-NVFP4 (chat template + chat_utils patch)
# ----------------------------------------
vllm-qwen-deploy:
	@echo "Deploying vLLM (Qwen3.5-122B-A10B-NVFP4)..."
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-model-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_QWEN_IMAGE)" \
		-e "vllm_model=$(VLLM_QWEN_MODEL)" \
		-e "vllm_served_name=$(VLLM_QWEN_SERVED)" \
		-e "vllm_container=vllm-qwen" \
		-e "vllm_port=$(VLLM_QWEN_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_QWEN_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_QWEN_KV_DTYPE)" \
		-e "vllm_max_model_len=$(VLLM_QWEN_MAX_MODEL_LEN)" \
		-e "vllm_tool_parser=$(VLLM_QWEN_TOOL_PARSER)" \
		-e "vllm_reasoning_parser=$(VLLM_QWEN_REASONING)" \
		-e "vllm_moe_fp8=1" \
		-e "vllm_chat_template_src=../config/qwen3.5-chat-template.jinja2" \
		-e "vllm_patch_script_src=../scripts/patch-vllm-chat-utils.py" \
		-e '{"vllm_cleanup_containers": ["vllm-gemma4", "vllm-qwen36"]}'

vllm-qwen-test:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-qwen-test.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_port=$(VLLM_QWEN_PORT)" \
		-e "vllm_model=$(VLLM_QWEN_SERVED)"

vllm-qwen-status:    ; @$(MAKE) --no-print-directory vllm-status VLLM_CONTAINER=vllm-qwen   VLLM_PORT=$(VLLM_QWEN_PORT)
vllm-qwen-stop:      ; @$(MAKE) --no-print-directory vllm-stop   VLLM_CONTAINER=vllm-qwen
vllm-qwen-logs:      ; @$(MAKE) --no-print-directory vllm-logs   VLLM_CONTAINER=vllm-qwen   HOST=$(HOST)

# ----------------------------------------
# Gemma-4-31B-IT-NVFP4 (local HF cache + gemma4 parser patch)
# ----------------------------------------
vllm-gemma4-deploy:
	@echo "Deploying vLLM (Gemma-4-31B-IT-NVFP4)..."
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-model-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_GEMMA4_IMAGE)" \
		-e "vllm_model=$(VLLM_GEMMA4_MODEL)" \
		-e "vllm_served_name=$(VLLM_GEMMA4_SERVED)" \
		-e "vllm_container=vllm-gemma4" \
		-e "vllm_port=$(VLLM_GEMMA4_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_GEMMA4_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_GEMMA4_KV_DTYPE)" \
		-e "vllm_max_model_len=$(VLLM_GEMMA4_MAX_MODEL_LEN)" \
		-e "vllm_tool_parser=gemma4" \
		-e "vllm_model_validate_path=/home/admin/.cache/huggingface/hub/Gemma-4-31B-IT-NVFP4" \
		-e "vllm_patch_script_src=../scripts/patch-vllm-gemma4-parser.py" \
		-e '{"vllm_cleanup_containers": ["vllm-qwen", "vllm-qwen36"]}'

vllm-gemma4-status:  ; @$(MAKE) --no-print-directory vllm-status VLLM_CONTAINER=vllm-gemma4 VLLM_PORT=$(VLLM_GEMMA4_PORT)
vllm-gemma4-stop:    ; @$(MAKE) --no-print-directory vllm-stop   VLLM_CONTAINER=vllm-gemma4
vllm-gemma4-logs:    ; @$(MAKE) --no-print-directory vllm-logs   VLLM_CONTAINER=vllm-gemma4 HOST=$(HOST)

# ----------------------------------------
# Qwen3.6-35B-A3B-FP8 (ModelScope cache, no patches)
# ----------------------------------------
vllm-qwen36-deploy:
	@echo "Deploying vLLM (Qwen3.6-35B-A3B-FP8, ctx=$(VLLM_QWEN36_MAX_MODEL_LEN)) -> $(if $(LIMIT),$(LIMIT),100.97.87.120)..."
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-model-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		--limit $(if $(LIMIT),$(LIMIT),100.97.87.120) \
		-e "vllm_image=$(VLLM_QWEN36_IMAGE)" \
		-e "vllm_model=$(VLLM_QWEN36_MODEL)" \
		-e "vllm_served_name=$(VLLM_QWEN36_SERVED)" \
		-e "vllm_container=vllm-qwen36" \
		-e "vllm_port=$(VLLM_QWEN36_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_QWEN36_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_QWEN36_KV_DTYPE)" \
		-e "vllm_max_model_len=$(VLLM_QWEN36_MAX_MODEL_LEN)" \
		-e "vllm_tool_parser=qwen3_coder" \
		-e "vllm_reasoning_parser=qwen3" \
		-e "vllm_preserve_thinking=1" \
		-e "ms_cache_dir=/home/admin/.cache/modelscope" \
		-e "vllm_model_validate_path=/home/admin/.cache/modelscope/Qwen/Qwen3.6-35B-A3B-FP8" \
		-e '{"vllm_cleanup_containers": ["vllm-gemma4", "vllm-qwen"]}'

vllm-qwen36-status:  ; @$(MAKE) --no-print-directory vllm-status VLLM_CONTAINER=vllm-qwen36 VLLM_PORT=$(VLLM_QWEN36_PORT)
vllm-qwen36-stop:    ; @$(MAKE) --no-print-directory vllm-stop   VLLM_CONTAINER=vllm-qwen36
vllm-qwen36-logs:    ; @$(MAKE) --no-print-directory vllm-logs   VLLM_CONTAINER=vllm-qwen36 HOST=$(HOST)

# ========================================
# Bifrost Gateway (maximhq/bifrost)
# ========================================
# Single OpenAI-compatible entry point in front of the vLLM backends.
# Listens on $(BIFROST_PORT) (default 8080). Config lives in
# config/bifrost-config.json (providers + governance.virtual_keys).
bifrost-deploy:
	@echo "========================================"
	@echo "Deploying Bifrost Gateway..."
	@echo "Host:  $(BIFROST_HOST):$(BIFROST_PORT)"
	@echo "Image: $(BIFROST_IMAGE)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/bifrost-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "bifrost_host=$(BIFROST_HOST)" \
		-e "bifrost_port=$(BIFROST_PORT)" \
		-e "bifrost_image=$(BIFROST_IMAGE)"

bifrost-test:
	uv run ansible-playbook -i $(INVENTORY) playbooks/bifrost-test.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "bifrost_host=$(BIFROST_HOST)" \
		-e "bifrost_port=$(BIFROST_PORT)"

bifrost-status:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(BIFROST_HOST) \
		"docker ps --filter name=bifrost-gateway --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' && echo '' && curl -s http://localhost:$(BIFROST_PORT)/api/health"

bifrost-stop:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(BIFROST_HOST) \
		"docker rm -f bifrost-gateway 2>/dev/null && echo 'Bifrost stopped' || echo 'Bifrost was not running'"

# ========================================
# Full Stack (vLLM + Bifrost gateway)
# ========================================
# Change STACK_MODEL to switch primary model for the stack.
# Values: qwen36 (default) | gemma4 | qwen
STACK_MODEL ?= qwen36

stack-deploy: vllm-$(STACK_MODEL)-deploy bifrost-deploy
	@echo "========================================"
	@echo "Full stack deployed (model: $(STACK_MODEL))"
	@echo "  Bifrost gateway: $(BIFROST_HOST):$(BIFROST_PORT)"
	@echo "========================================"

stack-stop: bifrost-stop vllm-$(STACK_MODEL)-stop

stack-status: vllm-$(STACK_MODEL)-status bifrost-status

# ========================================
# Prometheus Node Exporter (monitoring)
# ========================================
# Host metrics for the homelab Grafana/Prometheus stack. Docker container on BOTH
# servers (--net=host --pid=host → true host metrics). homelab Prometheus scrapes
# :9100 over Tailscale (job node-exporter-dgx-spark, cluster=dgx-spark); dashboard
# "DGX Spark / Node Exporter" in Grafana. Playbook: playbooks/node-exporter-deploy.yml.
node-exporter-deploy:
	@echo "========================================"
	@echo "Deploying Node Exporter on all hosts ($(HOSTS))"
	@echo "Image: $(NODE_EXPORTER_IMAGE)  Port: $(NODE_EXPORTER_PORT)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/node-exporter-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "node_exporter_image=$(NODE_EXPORTER_IMAGE)" \
		-e "node_exporter_mirror_image=$(NODE_EXPORTER_MIRROR_IMAGE)" \
		-e "node_exporter_port=$(NODE_EXPORTER_PORT)"

# docker ps + a /metrics probe per host. Uses ssh (not ansible -a) to avoid the
# Jinja2-eats-{{.Names}} trap with docker --format (see CLAUDE.md gotcha).
node-exporter-status:
	@for h in $(HOSTS); do \
		echo "=== $$h ==="; \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h \
			"docker ps --filter name=node-exporter --format 'table {{.Names}}\t{{.Status}}' && curl -s -o /dev/null -w 'metrics: HTTP %{http_code}\n' http://localhost:$(NODE_EXPORTER_PORT)/metrics"; \
	done

node-exporter-stop:
	@for h in $(HOSTS); do \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h \
			"docker rm -f node-exporter >/dev/null 2>&1 && echo \"$$h: node-exporter stopped\" || echo \"$$h: node-exporter was not running\""; \
	done

# Tail logs from one host: make node-exporter-logs NODE_EXPORTER_LOG_HOST=100.67.164.92
node-exporter-logs:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(NODE_EXPORTER_LOG_HOST) "docker logs --tail 50 node-exporter"

# ========================================
# smartctl Exporter (NVMe/SSD SMART disk health)
# ========================================
# SMART disk health on BOTH servers. HOST systemd service (User=root → reads
# /dev/nvme*); arm64 binary from GitHub (shipped via the control machine). homelab
# Prometheus scrapes :9633 over Tailscale (job smartctl-dgx-spark, cluster=dgx-spark);
# SMART panels live in the "DGX Spark / Node Exporter" Grafana dashboard.
# Playbook: playbooks/smartctl-exporter-deploy.yml.
smartctl-exporter-deploy:
	@echo "========================================"
	@echo "Deploying smartctl Exporter on all hosts ($(HOSTS))"
	@echo "Binary: smartctl_exporter v$(SMARTCTL_EXPORTER_VERSION) $(SMARTCTL_EXPORTER_ARCH)  Port: $(SMARTCTL_EXPORTER_PORT)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/smartctl-exporter-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "smartctl_exporter_version=$(SMARTCTL_EXPORTER_VERSION)" \
		-e "smartctl_exporter_arch=$(SMARTCTL_EXPORTER_ARCH)" \
		-e "smartctl_exporter_port=$(SMARTCTL_EXPORTER_PORT)"

# systemctl state + a /metrics probe per host.
smartctl-exporter-status:
	@for h in $(HOSTS); do \
		echo "=== $$h ==="; \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h \
			"systemctl is-active smartctl_exporter; curl -s -o /dev/null -w 'metrics: HTTP %{http_code}\n' http://localhost:$(SMARTCTL_EXPORTER_PORT)/metrics"; \
	done

smartctl-exporter-stop:
	@for h in $(HOSTS); do \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h \
			"sudo systemctl disable --now smartctl_exporter >/dev/null 2>&1 && echo \"$$h: smartctl-exporter stopped\" || echo \"$$h: smartctl-exporter was not running\""; \
	done

# Tail logs from one host: make smartctl-exporter-logs SMARTCTL_EXPORTER_LOG_HOST=100.67.164.92
smartctl-exporter-logs:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(SMARTCTL_EXPORTER_LOG_HOST) "sudo journalctl -u smartctl_exporter --no-pager -n 50"

# ========================================
# DeepSeek-V4-Flash (dual-node vLLM; eugr spark-vllm-docker + jasl/vllm fork)
# ========================================
# NOT Ansible-driven: drives eugr's run-recipe on the head node over SSH.
# One-time build + torch-fix + proxy revival: see docs/deepseek-v4-flash-cn.md.
# Recipe mirror lives at config/deepseek-v4-flash.yaml.
DSV4_HEAD   ?= 100.97.87.120
DSV4_HARNESS ?= /home/admin/spark-vllm-docker
DSV4_PORT   ?= 8000
DSV4_WORKER ?= 192.168.200.102
# Boot autostart (systemd unit on the head node) — RETIRED 2026-08-13, kept as
# the rollback path (unit still installed but disabled). See k8s/README.md.
DSV4_SERVICE  ?= deepseek-v4-flash
DSV4_BOOT_SRC ?= scripts/v4flash-boot.sh
DSV4_UNIT_SRC ?= config/deepseek-v4-flash.service
# k3s (current runtime): kubeconfig on this machine, namespace, manifests.
K8S           ?= kubectl --kubeconfig $(HOME)/.kube/dgx-spark.yaml
DSV4_NS       ?= v4flash

# Launch = scale both ranks to 1. Boot autostart is k3s's own systemd service
# (nodes Ready + GPU registered gate the pods), so there is no separate unit.
v4flash-run:
	$(K8S) -n $(DSV4_NS) scale deploy v4flash-worker v4flash-leader --replicas=1
	@echo "loads ~5min (167GB weights), poll: make v4flash-status"

v4flash-status:
	@$(K8S) -n $(DSV4_NS) get pods -o wide
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) \
		"curl -s http://localhost:$(DSV4_PORT)/v1/models | python3 -m json.tool 2>/dev/null || echo 'not serving yet'"

v4flash-logs:
	$(K8S) -n $(DSV4_NS) logs --tail=60 deploy/v4flash-leader

v4flash-logs-worker:
	$(K8S) -n $(DSV4_NS) logs --tail=60 deploy/v4flash-worker

v4flash-test:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) "BASE=http://localhost:$(DSV4_PORT) bash /home/admin/v4-test.sh"

# Who is using the engine right now. "Feels slow" is usually concurrency
# saturation (max_num_seqs=6), not the engine — check this before anything else
# (2026-08-02 incident: a 6-way batch workload was misread as an upgrade regression).
v4flash-load:
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) \
		"curl -s http://localhost:$(DSV4_PORT)/metrics | grep -E 'num_requests_(running|waiting)\{|kv_cache_usage' | grep -v '^#'; \
		echo '--- client IPs on :$(DSV4_PORT) ---'; \
		ss -tn | grep ':$(DSV4_PORT)' | awk '{print \$$5}' | cut -d: -f1 | sort | uniq -c | sort -rn"
	@echo '--- engine last minute ---'
	@$(K8S) -n $(DSV4_NS) logs --since=1m deploy/v4flash-leader 2>/dev/null | grep 'loggers.py' | tail -3 || true

# Stop = scale both ranks to 0. NOTE: k8s/v4flash/*.yaml carry `replicas: 1`,
# so a later `kubectl apply` restarts the stack — that is intended (apply should
# converge to the steady state), but don't apply while you mean to stay stopped.
v4flash-stop:
	$(K8S) -n $(DSV4_NS) scale deploy v4flash-leader v4flash-worker --replicas=0

# Restart both ranks together. Never restart one alone: a single-rank restart
# leaves the surviving rank hung in collectives (zombie TP group — /health still
# returns 200). See docs/k3s-migration-design-cn.md §4.7.
v4flash-restart:
	$(K8S) -n $(DSV4_NS) delete pod --all
	@echo "both ranks recreated; loads ~5min, poll: make v4flash-status"

# ---- Boot autostart: install/enable the systemd unit so the stack comes back
# ---- after a reboot. One unit on the head; it drives the worker over SSH.
v4flash-autostart:
	@echo ">> Installing boot launcher + systemd unit on $(DSV4_HEAD)"
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(DSV4_BOOT_SRC) $(SSH_USER)@$(DSV4_HEAD):/home/$(SSH_USER)/v4flash-boot.sh
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(DSV4_UNIT_SRC) $(SSH_USER)@$(DSV4_HEAD):/tmp/$(DSV4_SERVICE).service
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(DSV4_HEAD) \
		"chmod +x /home/$(SSH_USER)/v4flash-boot.sh && sudo install -m 0644 /tmp/$(DSV4_SERVICE).service /etc/systemd/system/$(DSV4_SERVICE).service && rm -f /tmp/$(DSV4_SERVICE).service && sudo systemctl daemon-reload && sudo systemctl enable $(DSV4_SERVICE) && echo 'enabled $(DSV4_SERVICE) (auto-starts on boot). start now: make v4flash-autostart-start'"

v4flash-autostart-start:
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(DSV4_HEAD) \
		"sudo systemctl restart $(DSV4_SERVICE) && echo 'started; loads ~3-4min, poll: make v4flash-status'"

v4flash-autostart-status:
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(DSV4_HEAD) \
		"systemctl status $(DSV4_SERVICE) --no-pager -l | head -n 25; echo; echo '--- last 20 journal lines ---'; journalctl -u $(DSV4_SERVICE) -n 20 --no-pager"

v4flash-autostart-remove:
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(DSV4_HEAD) \
		"sudo systemctl disable --now $(DSV4_SERVICE) 2>/dev/null; sudo rm -f /etc/systemd/system/$(DSV4_SERVICE).service; sudo systemctl daemon-reload; echo 'removed $(DSV4_SERVICE) (no longer auto-starts)'"

# ----------------------------------------
# Qwen3.8-27B-NVFP4 — single-node FALLBACK stack (S1 only, plain docker)
# ----------------------------------------
# Exists because V4-Flash is TP=2 and indivisible: when one node dies the whole
# service dies (2026-08-15 S2 hardware death). This stack keeps serving on the
# surviving node. It is SLOWER (24.9 vs 67.2 tok/s mean — dense 27B beats no
# MoE with 13B active) and weaker at agentic coding; it is a fallback, not an
# upgrade. Full runbook + benchmark: docs/qwen38-27b-fallback-cn.md
#
# MUTUALLY EXCLUSIVE with V4-Flash — both want the same GPU memory. Always
# `make qwen38-stop` before `make v4flash-run`, and vice versa.
Q38_HOST      ?= 100.97.87.120
Q38_PORT      ?= 8888
Q38_CONTAINER ?= qwen38-27b
Q38_START_SRC ?= scripts/qwen38-start.sh
Q38_TEST_SRC  ?= scripts/qwen38-test.sh

qwen38-run:
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(Q38_START_SRC) $(SSH_USER)@$(Q38_HOST):/home/$(SSH_USER)/qwen38-start.sh
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(Q38_HOST) \
		"chmod +x /home/$(SSH_USER)/qwen38-start.sh && bash /home/$(SSH_USER)/qwen38-start.sh"
	@echo "loads ~220s (22GB weights), poll: make qwen38-status"

qwen38-status:
	@ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(Q38_HOST) \
		"docker ps -a --filter name=$(Q38_CONTAINER) --format '{{ .Names }}  {{ .Status }}'; \
		curl -s http://localhost:$(Q38_PORT)/v1/models | python3 -m json.tool 2>/dev/null || echo 'not serving yet'; \
		free -h | head -2"

# Full benchmark: 3 warm-ups (discarded) + 4 prompt shapes + MTP acceptance.
# Never count SSE deltas under spec decode — that measures steps/s, not tok/s.
qwen38-test:
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(Q38_TEST_SRC) $(SSH_USER)@$(Q38_HOST):/home/$(SSH_USER)/qwen38-test.sh
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(Q38_HOST) \
		"BASE=http://localhost:$(Q38_PORT) bash /home/$(SSH_USER)/qwen38-test.sh"

qwen38-logs:
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(Q38_HOST) \
		"docker logs --tail=60 $(Q38_CONTAINER)"

qwen38-stop:
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(Q38_HOST) \
		"docker rm -f $(Q38_CONTAINER) 2>/dev/null; echo 'stopped'; free -h | head -2"
