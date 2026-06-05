.PHONY: venv install test ping all clean vllm-deploy vllm-test vllm-status vllm-stop vllm-logs vllm-benchmark vllm-monitor vllm-single-deploy vllm-single-stop vllm-tp2-deploy vllm-tp2-test vllm-tp2-stop vllm-tp2-benchmark vllm-qwen-deploy vllm-qwen-test vllm-qwen-status vllm-qwen-stop vllm-qwen-logs vllm-gemma4-deploy vllm-gemma4-status vllm-gemma4-stop vllm-gemma4-logs vllm-qwen36-deploy vllm-qwen36-status vllm-qwen36-stop vllm-qwen36-logs vllm-qwen3627b-deploy vllm-qwen3627b-status vllm-qwen3627b-stop vllm-qwen3627b-logs bifrost-deploy bifrost-test bifrost-stop bifrost-status stack-deploy stack-stop stack-status unify-system unify-status tmux-cmd tmux-vllm-deploy tmux-attach tmux-list tmux-kill tmux-benchmark modelscope-download remove-thunderbird llmfit-install llmfit-cmd v4flash-run v4flash-status v4flash-logs v4flash-test v4flash-stop v4flash-autostart v4flash-autostart-start v4flash-autostart-status v4flash-autostart-remove

# Ansible inventory file
INVENTORY := inventory.ini
# SSH private key
SSH_KEY := /Users/matthew/.ssh/vgio
# SSH user
SSH_USER := admin
# Remote hosts
HOSTS := 100.97.87.120 100.67.164.92
# Limit a per-model deploy to specific host(s) via Ansible --limit. Empty = all hosts.
# Per-model deploy targets set a sensible default (qwen36 -> server1, qwen3627b -> server2);
# override on the CLI, e.g. `make vllm-qwen36-deploy LIMIT=100.67.164.92`, or `LIMIT=` for both.
LIMIT ?=
# vLLM configuration
VLLM_IMAGE ?= nvcr.io/nvidia/vllm:26.01-py3
VLLM_MODEL ?= Qwen/Qwen2.5-7B-Instruct
VLLM_PORT ?= 8000
GPU_MEMORY_UTIL ?= 0.7
TOOL_CALL_PARSER ?=
TP2_COORDINATOR ?= 100.97.87.120
TP2_WORKER ?= 100.67.164.92
TP2_MODEL ?= NVIDIA/Nemotron-3-Super-120B-A12B-NVFP4
TP2_IMAGE ?= vllm/vllm-openai:gemma4-cu130
TP2_PORT ?= 8030
TP2_MASTER_PORT ?= 29500
TP2_NCCL_IFACE ?= enp1s0f0np0
TP2_GPU_MEMORY_UTIL ?= 0.75
TP2_MAX_MODEL_LEN ?= 262144

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

# vLLM Qwen3.6-27B configuration (dense, NVFP4 - quality / escalation node, runs on Server 2)
VLLM_QWEN36_27B_IMAGE ?= vllm-node-tf5:latest
VLLM_QWEN36_27B_MODEL ?= /root/.cache/huggingface/hub/Qwen3.6-27B-NVFP4
VLLM_QWEN36_27B_SERVED ?= Qwen3.6-27B
VLLM_QWEN36_27B_PORT ?= 30000
VLLM_QWEN36_27B_GPU_MEM ?= 0.70
VLLM_QWEN36_27B_KV_DTYPE ?= fp8_e4m3
# Leave empty so vLLM auto-detects compressed-tensors NVFP4. Set to
# compressed-tensors or modelopt_fp4 only if a checkpoint fails to load.
VLLM_QWEN36_27B_QUANT ?=
VLLM_QWEN36_27B_MAX_MODEL_LEN ?= 262144

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
# vLLM Deployment Commands
# ========================================

# Deploy vLLM on all hosts (system hardening + container deployment)
vllm-deploy:
	@echo "========================================"
	@echo "Deploying vLLM on DGX Spark cluster..."
	@echo "Image: $(VLLM_IMAGE)"
	@echo "Model: $(VLLM_MODEL)"
	@echo "Port: $(VLLM_PORT)"
	@echo "GPU Memory: $(GPU_MEMORY_UTIL)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_IMAGE)" \
		-e "vllm_model=$(VLLM_MODEL)" \
		-e "vllm_port=$(VLLM_PORT)" \
		-e "gpu_memory_utilization=$(GPU_MEMORY_UTIL)"

# Test vLLM deployment (health check + API validation)
vllm-test:
	@echo "========================================"
	@echo "Testing vLLM deployment..."
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-test.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_model=$(VLLM_MODEL)" \
		-e "vllm_port=$(VLLM_PORT)"

# Legacy status/stop targets were removed in favor of generic
# vllm-status / vllm-stop / vllm-logs (see per-model deployment section below).
# Usage examples:
#   make vllm-status VLLM_CONTAINER=vllm-qwen36 VLLM_PORT=30000
#   make vllm-stop   VLLM_CONTAINER=vllm-qwen36
#   make vllm-logs   HOST=100.97.87.120 VLLM_CONTAINER=vllm-qwen36
# For the currently-deployed model, the qwen/gemma4/qwen36 wrappers dispatch
# to those targets with the right container name already filled in.

# Run vLLM benchmark (built-in vLLM benchmark tool)
vllm-benchmark:
	@echo "========================================"
	@echo "Running vLLM Benchmark..."
	@echo "This will test inference performance"
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker exec vllm-server python3 -m vllm.entrypoints.openai.api_server --help 2>/dev/null && \
		echo '--- Running Benchmark ---' && \
		docker exec vllm-server python3 -c \" \
import requests, json, time \
url = 'http://localhost:$(VLLM_PORT)/v1/completions' \
payload = { 'model': '$(VLLM_MODEL)', 'prompt': 'Hello, how are you? ' * 10, 'max_tokens': 100, 'temperature': 0.7 } \
start = time.time() \
resp = requests.post(url, json=payload) \
elapsed = time.time() - start \
print(f'Response time: {elapsed:.2f}s') \
print(f'Tokens generated: {len(resp.json().get(\"choices\", [{}])[0].get(\"text\", \"\").split())}') \
print(f'Tokens/sec: {len(resp.json().get(\"choices\", [{}])[0].get(\"text\", \"\").split()) / elapsed:.2f}') \
\" 2>/dev/null || echo 'Benchmark failed - ensure vLLM is running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

# Monitor unified memory usage (run on local machine, connects to remote)
vllm-monitor:
	@echo "========================================"
	@echo "Starting memory monitor..."
	@echo "Press Ctrl+C to stop"
	@echo "========================================"
	@for host in $(HOSTS); do \
		echo "Monitoring $$host..." && \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$host "bash -s" < scripts/monitor-unified-memory.sh 5 & \
	done; \
	wait

vllm-tp2-deploy:
	@test -f playbooks/vllm-tp2-deploy.yml || { \
		echo "Task 2 not implemented: missing playbooks/vllm-tp2-deploy.yml. Add the Task 2 playbook before running 'vllm-tp2-deploy'."; \
		exit 1; \
	}
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_worker=$(TP2_WORKER)" \
		-e "tp2_model=$(TP2_MODEL)" \
		-e "tp2_image=$(TP2_IMAGE)" \
		-e "tp2_port=$(TP2_PORT)" \
		-e "tp2_master_port=$(TP2_MASTER_PORT)" \
		-e "tp2_nccl_iface=$(TP2_NCCL_IFACE)" \
		-e "tp2_gpu_memory_utilization=$(TP2_GPU_MEMORY_UTIL)" \
		-e "tp2_max_model_len=$(TP2_MAX_MODEL_LEN)"

vllm-tp2-test:
	@test -f playbooks/vllm-tp2-validate.yml || { \
		echo "Task 2 not implemented: missing playbooks/vllm-tp2-validate.yml. Add the Task 2 playbook before running 'vllm-tp2-test'."; \
		exit 1; \
	}
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-validate.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_model=$(TP2_MODEL)" \
		-e "tp2_port=$(TP2_PORT)"

vllm-tp2-stop:
	@test -f playbooks/vllm-tp2-stop.yml || { \
		echo "Task 2 not implemented: missing playbooks/vllm-tp2-stop.yml. Add the Task 2 playbook before running 'vllm-tp2-stop'."; \
		exit 1; \
	}
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-stop.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

vllm-tp2-benchmark:
	bash scripts/vllm-tp2-benchmark.sh "$(TP2_COORDINATOR)" "$(TP2_WORKER)" "$(TP2_MODEL)" "$(TP2_PORT)" "$(SSH_KEY)" "$(SSH_USER)"

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

# Deploy vLLM inside a tmux session (resilient to SSH drops)
# Usage: make tmux-vllm-deploy [VLLM_MODEL=...] [GPU_MEMORY_UTIL=...]
tmux-vllm-deploy:
	@echo "========================================"
	@echo "Deploying vLLM in tmux session (resilient to SSH drops)"
	@echo "Image: $(VLLM_IMAGE)"
	@echo "Model: $(VLLM_MODEL)"
	@echo "Port: $(VLLM_PORT)"
	@echo "GPU Memory: $(GPU_MEMORY_UTIL)"
	@echo "========================================"
	@for host in $(HOSTS); do \
		echo "--- $$host ---" && \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$host \
			"tmux new-session -d -s vllm-deploy \
				'ansible-playbook -i /home/$(SSH_USER)/inventory.ini /home/$(SSH_USER)/playbooks/vllm-deploy.yml \
					-e vllm_image=$(VLLM_IMAGE) \
					-e vllm_model=$(VLLM_MODEL) \
					-e vllm_port=$(VLLM_PORT) \
					-e gpu_memory_utilization=$(GPU_MEMORY_UTIL) \
					2>&1 | tee /tmp/vllm-deploy.log' && \
			 echo 'vLLM deployment started in tmux session \"vllm-deploy\"' && \
			 echo 'Watch progress: ssh -i $(SSH_KEY) $(SSH_USER)@$$host \"tmux attach -t vllm-deploy\"' && \
			 echo 'Check logs:  tail -f /tmp/vllm-deploy.log'"; \
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

# Run vLLM benchmark inside a tmux session (long-running, resilient)
# Usage: make tmux-benchmark [VLLM_MODEL=...] [VLLM_PORT=...]
tmux-benchmark:
	@echo "========================================"
	@echo "Running vLLM benchmark in tmux session"
	@echo "This will survive SSH disconnection"
	@echo "========================================"
	@for host in $(HOSTS); do \
		echo "--- $$host ---" && \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$host \
			"tmux new-session -d -s vllm-benchmark \
				'python3 -c \" \
import requests, json, time \
url = \"http://localhost:$(VLLM_PORT)/v1/completions\" \
payload = { \"model\": \"$(VLLM_MODEL)\", \"prompt\": \"Hello, how are you? \" * 10, \"max_tokens\": 100, \"temperature\": 0.7 } \
start = time.time() \
resp = requests.post(url, json=payload) \
elapsed = time.time() - start \
print(f\"Response time: {elapsed:.2f}s\") \
print(f\"Tokens/sec: {len(resp.json().get(\\\"choices\\\", [{}])[0].get(\\\"text\\\", \\\"\\\").split()) / elapsed:.2f}\") \
\" 2>&1 | tee /tmp/vllm-benchmark.log' && \
			 echo 'Benchmark started in tmux session \"vllm-benchmark\"' && \
			 echo 'Check results: tail -f /tmp/vllm-benchmark.log'"; \
	done

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
# Single-Node vLLM Deployment (Stable)
# ========================================
# Each server runs independent vLLM instance
# Avoids cross-node TP=2 hang risks

# Deploy single-node vLLM on all hosts
vllm-single-deploy:
	@echo "========================================"
	@echo "Deploying single-node vLLM on all hosts..."
	@echo "Image: $(VLLM_IMAGE)"
	@echo "Model: $(VLLM_MODEL)"
	@echo "Port: $(VLLM_PORT)"
	@echo "GPU Memory: $(GPU_MEMORY_UTIL)"
	@echo "Tool Call Parser: $(TOOL_CALL_PARSER)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-single-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_IMAGE)" \
		-e "vllm_model=$(VLLM_MODEL)" \
		-e "vllm_port=$(VLLM_PORT)" \
		-e "gpu_memory_utilization=$(GPU_MEMORY_UTIL)" \
		-e "tool_call_parser=$(TOOL_CALL_PARSER)"

# Stop single-node vLLM on all hosts
vllm-single-stop:
	@echo "========================================"
	@echo "Stopping single-node vLLM on all hosts..."
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker rm -f vllm-server 2>/dev/null && echo 'vLLM stopped' || echo 'vLLM was not running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

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

# ----------------------------------------
# Qwen3.6-27B-NVFP4 (dense quality node - Server 2)
# ----------------------------------------
vllm-qwen3627b-deploy:
	@echo "Deploying vLLM (Qwen3.6-27B-NVFP4, ctx=$(VLLM_QWEN36_27B_MAX_MODEL_LEN)) -> $(if $(LIMIT),$(LIMIT),100.67.164.92)..."
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-model-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		--limit $(if $(LIMIT),$(LIMIT),100.67.164.92) \
		-e "vllm_image=$(VLLM_QWEN36_27B_IMAGE)" \
		-e "vllm_model=$(VLLM_QWEN36_27B_MODEL)" \
		-e "vllm_served_name=$(VLLM_QWEN36_27B_SERVED)" \
		-e "vllm_container=vllm-qwen3627b" \
		-e "vllm_port=$(VLLM_QWEN36_27B_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_QWEN36_27B_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_QWEN36_27B_KV_DTYPE)" \
		-e "vllm_quantization=$(VLLM_QWEN36_27B_QUANT)" \
		-e "vllm_max_model_len=$(VLLM_QWEN36_27B_MAX_MODEL_LEN)" \
		-e "vllm_tool_parser=qwen3_coder" \
		-e "vllm_reasoning_parser=qwen3" \
		-e "vllm_disable_thinking=1" \
		-e "vllm_model_validate_path=/home/admin/.cache/huggingface/hub/Qwen3.6-27B-NVFP4" \
		-e '{"vllm_cleanup_containers": ["vllm-qwen36", "vllm-gemma4", "vllm-qwen"]}'

vllm-qwen3627b-status:  ; @$(MAKE) --no-print-directory vllm-status VLLM_CONTAINER=vllm-qwen3627b VLLM_PORT=$(VLLM_QWEN36_27B_PORT)
vllm-qwen3627b-stop:    ; @$(MAKE) --no-print-directory vllm-stop   VLLM_CONTAINER=vllm-qwen3627b
vllm-qwen3627b-logs:    ; @$(MAKE) --no-print-directory vllm-logs   VLLM_CONTAINER=vllm-qwen3627b HOST=$(HOST)

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
# DeepSeek-V4-Flash (dual-node vLLM; eugr spark-vllm-docker + jasl/vllm fork)
# ========================================
# NOT Ansible-driven: drives eugr's run-recipe on the head node over SSH.
# One-time build + torch-fix + proxy revival: see docs/deepseek-v4-flash-cn.md.
# Recipe mirror lives at config/deepseek-v4-flash.yaml.
DSV4_HEAD   ?= 100.97.87.120
DSV4_HARNESS ?= /home/admin/spark-vllm-docker
DSV4_PORT   ?= 8000
DSV4_WORKER ?= 192.168.200.102
# Boot autostart (systemd unit on the head node)
DSV4_SERVICE  ?= deepseek-v4-flash
DSV4_BOOT_SRC ?= scripts/v4flash-boot.sh
DSV4_UNIT_SRC ?= config/deepseek-v4-flash.service

# Launch. If the autostart unit is installed, go through systemd (so the boot
# path and the manual path are identical); otherwise fall back to the tmux
# launch used during builds / before the unit exists.
v4flash-run:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) \
		"if systemctl list-unit-files 2>/dev/null | grep -q '^$(DSV4_SERVICE).service'; then sudo systemctl restart $(DSV4_SERVICE) && echo 'started via systemd ($(DSV4_SERVICE)); loads ~3-4min, poll: make v4flash-status'; else cd $(DSV4_HARNESS) && tmux kill-session -t dsv4run 2>/dev/null; tmux new-session -d -s dsv4run 'DOTENV_CONTAINER_HF_HUB_OFFLINE=1 DOTENV_CONTAINER_TRANSFORMERS_OFFLINE=1 ./run-recipe.sh deepseek-v4-flash --no-ray > /tmp/dsv4-run.log 2>&1' && echo 'started in tmux (no autostart unit); loads ~3-4min, poll: make v4flash-status'; fi"

v4flash-status:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) \
		"curl -s http://localhost:$(DSV4_PORT)/v1/models | python3 -m json.tool 2>/dev/null || echo 'not serving yet'; docker ps --format '{{.Names}} | {{.Status}}' | grep -i vllm || true"

v4flash-logs:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) "tail -n 60 /tmp/dsv4-run.log"

v4flash-test:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) "BASE=http://localhost:$(DSV4_PORT) bash /home/admin/v4-test.sh"

# Stop. When the unit is active, stop via systemd (runs ExecStop teardown and
# avoids a Restart=on-failure fight); otherwise tear the containers down by hand.
v4flash-stop:
	ssh -i $(SSH_KEY) $(SSH_USER)@$(DSV4_HEAD) \
		"if systemctl is-active --quiet $(DSV4_SERVICE); then sudo systemctl stop $(DSV4_SERVICE) && echo 'stopped via systemd ($(DSV4_SERVICE))'; else docker rm -f vllm_node 2>/dev/null; ssh -o StrictHostKeyChecking=no $(DSV4_WORKER) 'docker rm -f vllm_node 2>/dev/null'; echo stopped; fi"

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
