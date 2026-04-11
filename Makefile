.PHONY: venv install test ping all clean vllm-deploy vllm-test vllm-status vllm-stop vllm-benchmark vllm-monitor vllm-tp2-deploy vllm-tp2-test vllm-tp2-stop

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
TP2_COORDINATOR ?= 100.97.87.120
TP2_WORKER ?= 100.67.164.92
TP2_MODEL ?= Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled
TP2_IMAGE ?= $(VLLM_IMAGE)
TP2_PORT ?= 8000
TP2_MASTER_PORT ?= 29500
TP2_NCCL_IFACE ?= enp1s0f0np0
TP2_GPU_MEMORY_UTIL ?= 0.7
TP2_MAX_MODEL_LEN ?= 8192

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
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-validate.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_model=$(TP2_MODEL)" \
		-e "tp2_port=$(TP2_PORT)"

vllm-tp2-stop:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-stop.yml \
		--ssh-extra-args="-i $(SSH_KEY)"
