.PHONY: venv install test ping all clean vllm-deploy vllm-test vllm-status vllm-stop vllm-benchmark vllm-monitor vllm-single-deploy vllm-single-stop vllm-tp2-deploy vllm-tp2-test vllm-tp2-stop vllm-tp2-benchmark vllm-qwen-deploy vllm-qwen-test vllm-qwen-status vllm-qwen-stop vllm-qwen-logs vllm-gemma4-deploy vllm-gemma4-status vllm-gemma4-stop vllm-gemma4-logs gateway-deploy gateway-test gateway-stop gateway-status bifrost-deploy bifrost-test bifrost-stop bifrost-status stack-deploy stack-stop stack-status unify-system unify-status tmux-cmd tmux-vllm-deploy tmux-attach tmux-list tmux-kill tmux-benchmark remove-thunderbird

# Ansible inventory file
INVENTORY := inventory.ini
# SSH private key
SSH_KEY := /Users/matthew/.ssh/vgio
# SSH user
SSH_USER := admin
# Remote hosts
HOSTS := 100.97.87.120 100.67.164.92
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
TP2_MAX_MODEL_LEN ?= 32768

# LLM Gateway configuration (FastAPI reverse proxy replacing Bifrost)
GATEWAY_HOST ?= 100.97.87.120
GATEWAY_PORT ?= 8080
VLLM_SERVER1_URL ?= http://192.168.200.101:30000
VLLM_SERVER2_URL ?= http://192.168.200.102:30000

# Bifrost (legacy — kept for reference, replaced by LLM Gateway)
BIFROST_HOST ?= $(GATEWAY_HOST)
BIFROST_PORT ?= $(GATEWAY_PORT)
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

# vLLM Gemma4 configuration (native developer role + tool calling)
VLLM_GEMMA4_IMAGE ?= vllm-node-tf5:latest
VLLM_GEMMA4_MODEL ?= /root/.cache/huggingface/hub/Gemma-4-31B-IT-NVFP4
VLLM_GEMMA4_SERVED ?= Gemma-4-31B-IT
VLLM_GEMMA4_PORT ?= 30000
VLLM_GEMMA4_GPU_MEM ?= 0.70
VLLM_GEMMA4_KV_DTYPE ?= fp8_e4m3

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

# Check vLLM status on all hosts
vllm-status:
	@echo "========================================"
	@echo "vLLM Status Check"
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "echo '--- Container Status ---' && docker ps --filter name=vllm-server --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' && echo '' && echo '--- GPU Utilization ---' && nvidia-smi --query-gpu=name,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv && echo '' && echo '--- Memory Usage ---' && free -h && echo '' && echo '--- Swap Status ---' && swapon --show || echo 'Swap disabled'" \
		--ssh-extra-args="-i $(SSH_KEY)"

# Stop vLLM on all hosts
vllm-stop:
	@echo "========================================"
	@echo "Stopping vLLM on all hosts..."
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker stop vllm-server 2>/dev/null && echo 'vLLM stopped' || echo 'vLLM was not running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

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
# vLLM Qwen3.5-122B Deployment Commands
# ========================================
# Each server runs an independent vLLM instance
# with Qwen3.5-122B-A10B (NVFP4, ~72GB)

# Deploy vLLM Qwen on all hosts
vllm-qwen-deploy:
	@echo "========================================"
	@echo "Deploying vLLM (Qwen3.5-122B) on DGX Spark cluster..."
	@echo "Image: $(VLLM_QWEN_IMAGE)"
	@echo "Model: $(VLLM_QWEN_MODEL)"
	@echo "Served as: $(VLLM_QWEN_SERVED)"
	@echo "Port: $(VLLM_QWEN_PORT)"
	@echo "GPU memory: $(VLLM_QWEN_GPU_MEM)"
	@echo "KV cache dtype: $(VLLM_QWEN_KV_DTYPE)"
	@echo "Tool parser: $(VLLM_QWEN_TOOL_PARSER)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-qwen-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_QWEN_IMAGE)" \
		-e "vllm_model=$(VLLM_QWEN_MODEL)" \
		-e "vllm_served_name=$(VLLM_QWEN_SERVED)" \
		-e "vllm_port=$(VLLM_QWEN_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_QWEN_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_QWEN_KV_DTYPE)" \
		-e "vllm_tool_parser=$(VLLM_QWEN_TOOL_PARSER)" \
		-e "vllm_reasoning_parser=$(VLLM_QWEN_REASONING)"

# Test vLLM Qwen deployment (health + chat + tool calling)
vllm-qwen-test:
	@echo "Testing vLLM Qwen endpoints..."
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-qwen-test.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_port=$(VLLM_QWEN_PORT)" \
		-e "vllm_model=$(VLLM_QWEN_SERVED)"

# Check vLLM Qwen status on all hosts
vllm-qwen-status:
	@echo "========================================"
	@echo "vLLM Qwen Status Check"
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "echo '--- Container ---' && docker ps --filter name=vllm-qwen --format 'table {{.Names}}\t{{.Status}}' && echo '--- API ---' && curl -s http://localhost:$(VLLM_QWEN_PORT)/v1/models 2>/dev/null | python3 -m json.tool || echo 'Not responding' && echo '--- GPU ---' && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader" \
		--ssh-extra-args="-i $(SSH_KEY)"

# Stop vLLM Qwen on all hosts
vllm-qwen-stop:
	@echo "Stopping vLLM Qwen on all hosts..."
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker rm -f vllm-qwen 2>/dev/null && echo 'vLLM Qwen stopped' || echo 'vLLM Qwen was not running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

# View vLLM Qwen logs on a specific host (usage: make vllm-qwen-logs HOST=100.97.87.120)
vllm-qwen-logs:
ifndef HOST
	$(error HOST is required. Usage: make vllm-qwen-logs HOST=100.97.87.120)
endif
	ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) "docker logs --tail 100 -f vllm-qwen"

# ========================================
# vLLM Gemma-4-31B-IT Deployment Commands
# ========================================
# Gemma 4 natively supports developer role and has built-in gemma4 tool parser.
# No custom chat template or reasoning parser needed.

# Deploy vLLM Gemma4 on all hosts
vllm-gemma4-deploy:
	@echo "========================================"
	@echo "Deploying vLLM (Gemma-4-31B-IT) on DGX Spark cluster..."
	@echo "Image: $(VLLM_GEMMA4_IMAGE)"
	@echo "Model: $(VLLM_GEMMA4_MODEL)"
	@echo "Served as: $(VLLM_GEMMA4_SERVED)"
	@echo "Port: $(VLLM_GEMMA4_PORT)"
	@echo "GPU memory: $(VLLM_GEMMA4_GPU_MEM)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-gemma4-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "vllm_image=$(VLLM_GEMMA4_IMAGE)" \
		-e "vllm_served_name=$(VLLM_GEMMA4_SERVED)" \
		-e "vllm_port=$(VLLM_GEMMA4_PORT)" \
		-e "vllm_gpu_mem=$(VLLM_GEMMA4_GPU_MEM)" \
		-e "vllm_kv_dtype=$(VLLM_GEMMA4_KV_DTYPE)"

# Check vLLM Gemma4 status on all hosts
vllm-gemma4-status:
	@echo "========================================"
	@echo "vLLM Gemma4 Status Check"
	@echo "========================================"
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "echo '--- Container ---' && docker ps --filter name=vllm-gemma4 --format 'table {{.Names}}\t{{.Status}}' && echo '--- API ---' && curl -s http://localhost:$(VLLM_GEMMA4_PORT)/v1/models 2>/dev/null | python3 -m json.tool || echo 'Not responding' && echo '--- GPU ---' && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader" \
		--ssh-extra-args="-i $(SSH_KEY)"

# Stop vLLM Gemma4 on all hosts
vllm-gemma4-stop:
	@echo "Stopping vLLM Gemma4 on all hosts..."
	uv run ansible all -i $(INVENTORY) -m shell \
		-a "docker rm -f vllm-gemma4 2>/dev/null && echo 'vLLM Gemma4 stopped' || echo 'vLLM Gemma4 was not running'" \
		--ssh-extra-args="-i $(SSH_KEY)"

# View Gemma4 logs on a specific host (usage: make vllm-gemma4-logs HOST=100.97.87.120)
vllm-gemma4-logs:
ifndef HOST
	$(error HOST is required. Usage: make vllm-gemma4-logs HOST=100.97.87.120)
endif
	ssh -i $(SSH_KEY) $(SSH_USER)@$(HOST) "docker logs --tail 100 -f vllm-gemma4"


# Routes to vLLM backends via 200-subnet:
# - 192.168.200.101:30000 (Server 1)
# - 192.168.200.102:30000 (Server 2)
# <11μs overhead, automatic failover

# Deploy LLM Gateway (FastAPI reverse proxy)
# Routes /v1/responses* sticky to server1, load-balances /v1/chat/completions
gateway-deploy:
	@echo "========================================"
	@echo "Deploying LLM Gateway..."
	@echo "Host: $(GATEWAY_HOST):$(GATEWAY_PORT)"
	@echo "Server1 (Responses API + fallback): $(VLLM_SERVER1_URL)"
	@echo "Server2 (chat LB): $(VLLM_SERVER2_URL)"
	@echo "========================================"
	uv run ansible-playbook -i $(INVENTORY) playbooks/gateway-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "gateway_host=$(GATEWAY_HOST)" \
		-e "gateway_port=$(GATEWAY_PORT)" \
		-e "vllm_server1_url=$(VLLM_SERVER1_URL)" \
		-e "vllm_server2_url=$(VLLM_SERVER2_URL)"

# Test LLM Gateway health and routing
gateway-test:
	@echo "========================================"
	@echo "Testing LLM Gateway..."
	@echo "========================================"
	ssh -i $(SSH_KEY) $(SSH_USER)@$(GATEWAY_HOST) \
		"echo '--- Health ---' && curl -s http://localhost:$(GATEWAY_PORT)/health | python3 -m json.tool && echo '' && echo '--- Models ---' && curl -s http://localhost:$(GATEWAY_PORT)/v1/models | python3 -c 'import json,sys; print([m[\"id\"] for m in json.load(sys.stdin)[\"data\"]])'"

# Check LLM Gateway status
gateway-status:
	@echo "========================================"
	@echo "LLM Gateway Status"
	@echo "========================================"
	ssh -i $(SSH_KEY) $(SSH_USER)@$(GATEWAY_HOST) \
		"docker ps --filter name=llm-gateway --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' && echo '' && curl -s http://localhost:$(GATEWAY_PORT)/health"

# Stop LLM Gateway
gateway-stop:
	@echo "========================================"
	@echo "Stopping LLM Gateway..."
	@echo "========================================"
	ssh -i $(SSH_KEY) $(SSH_USER)@$(GATEWAY_HOST) \
		"docker rm -f llm-gateway 2>/dev/null && echo 'Gateway stopped' || echo 'Gateway was not running'"

# Legacy Bifrost aliases (now deploy LLM Gateway instead)
bifrost-deploy: gateway-deploy
bifrost-test: gateway-test
bifrost-stop: gateway-stop
bifrost-status: gateway-status

# ========================================
# Full Stack (vLLM Qwen + Bifrost)
# ========================================

# Deploy full stack: vLLM Gemma-4 on both servers + LLM Gateway
stack-deploy: vllm-gemma4-deploy gateway-deploy
	@echo "========================================"
	@echo "Full stack deployed!"
	@echo "  vLLM: both servers on port $(VLLM_GEMMA4_PORT)"
	@echo "  Gateway: $(GATEWAY_HOST):$(GATEWAY_PORT)"
	@echo "  Model: Gemma-4-31B-IT"
	@echo "========================================"

# Stop full stack
stack-stop: gateway-stop vllm-gemma4-stop

# Check full stack status
stack-status: vllm-gemma4-status gateway-status
