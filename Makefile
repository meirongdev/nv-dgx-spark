.PHONY: venv install test ping all clean tmux-cmd tmux-attach tmux-list tmux-kill modelscope-download v4flash-run v4flash-status v4flash-logs v4flash-logs-worker v4flash-test v4flash-load v4flash-stop v4flash-restart probe-test probe-apply probe-verify qwen38-run qwen38-status qwen38-test qwen38-logs qwen38-stop node-exporter-deploy node-exporter-status node-exporter-stop node-exporter-logs smartctl-exporter-deploy smartctl-exporter-status smartctl-exporter-stop smartctl-exporter-logs

# Ansible inventory file
INVENTORY := inventory.ini
# SSH private key
SSH_KEY := /Users/matthew/.ssh/vgio
# SSH user
SSH_USER := admin
# Remote hosts
HOSTS := 100.97.87.120 100.67.164.92
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
# Usage: make modelscope-download [MS_MODEL=unsloth/Qwen3.8-27B-NVFP4]
MS_MODEL ?= unsloth/Qwen3.8-27B-NVFP4
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

# Liveness-probe regression test. Extracts liveness.py / worker_liveness.py
# straight out of k8s/v4flash/configmap-launch.yaml and replays the scenarios
# that got a HEALTHY leader killed twice on 2026-08-16 (plus a real hang, so the
# probe still bites). Pure stdlib, runs locally — no cluster, no venv.
# ⚠️ Run this before touching either probe script.
probe-test:
	python3 scripts/test-liveness-probe.py

# Push the probe scripts to the live cluster. ConfigMap is a plain volume mount
# (NOT subPath), so kubelet syncs the new files into the RUNNING containers —
# no pod restart, no inference downtime. Probe *fields* in leader.yaml/worker.yaml
# are a different story: those need a pod rebuild to take effect.
probe-apply: probe-test
	$(K8S) apply -f k8s/v4flash/configmap-launch.yaml
	@echo "ConfigMap updated; kubelet syncs /scripts into both pods within ~60s."
	@echo "verify: make probe-verify"

# Run the live probe scripts by hand inside both running pods (isolated state
# file, so the real probe's own state is untouched). rc=0 on a healthy stack.
probe-verify:
	@echo "--- leader ---"
	$(K8S) -n $(DSV4_NS) exec deploy/v4flash-leader -- \
		env V4FLASH_STATE=/tmp/.probe_check python3 /scripts/liveness.py \
		&& echo "leader rc=0 (healthy)"
	@echo "--- worker ---"
	$(K8S) -n $(DSV4_NS) exec deploy/v4flash-worker -- \
		env V4FLASH_WORKER_STATE=/tmp/.wprobe_check python3 /scripts/worker_liveness.py \
		&& echo "worker rc=0 (healthy)"

# ---- Host-level memory watchdog (防整机 OOM). See scripts/mem-watch.sh ----
# On GB10 unified memory, vLLM's ~100GB pre-allocation bypasses the container
# cgroup (verified 2026-08-15), so node-level available memory is the only
# signal that sees it. The watchdog polls both nodes over SSH and, before the
# node OOMs, scales BOTH vLLM ranks to 0 (clean, no zombie TP group). No
# auto-restore — bring the engine back with `make v4flash-run`.
MEMWATCH ?= scripts/mem-watch.sh

memwatch-check:            # 单次打印两节点 available%(只读)
	$(MEMWATCH) --once

memwatch:                  # 常驻循环(防 OOM,建议放 tmux)
	$(MEMWATCH)

memwatch-reset:            # 清除已触发状态,解除保持
	$(MEMWATCH) --reset

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
