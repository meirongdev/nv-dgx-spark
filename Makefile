.PHONY: venv install test ping all clean tmux-cmd tmux-attach tmux-list tmux-kill modelscope-download v4flash-run v4flash-status v4flash-logs v4flash-logs-worker v4flash-warmer-logs v4flash-drift v4flash-test v4flash-load v4flash-stop v4flash-restart probe-test probe-apply probe-verify v4flash-hotfix-status v4flash-hotfix-test qwen38-run qwen38-status qwen38-test qwen38-logs qwen38-stop qwen38fn-preflight qwen38fn-run qwen38fn-status qwen38fn-logs qwen38fn-logs-worker qwen38fn-test qwen38fn-load qwen38fn-stop qwen38fn-restart qwen38fn-rollback ple-test memwatch-check memwatch memwatch-reset memwatch-test node-exporter-deploy node-exporter-status node-exporter-stop node-exporter-logs smartctl-exporter-deploy smartctl-exporter-status smartctl-exporter-stop smartctl-exporter-logs clock-cap-apply clock-cap-reset clock-cap-status clock-cap-verify clock-cap-install clock-cap-uninstall

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

# warmer sidecar 的日志(重启后预热曲线 + 空闲衰减探测)。warmer.py 的头注释
# 引用了这个目标,但在 2026-09-02 收编分叉之前它并不存在。
# 结构化记录在宿主机 /home/admin/.cache/vllm/warmer.jsonl(跨 Pod 重启保留)。
v4flash-warmer-logs:
	$(K8S) -n $(DSV4_NS) logs --tail=40 deploy/v4flash-leader -c warmer

# 仓库 manifests 与线上的真实差异(服务端 dry-run)。
# ⚠️ apply 之前先跑这个 —— 2026-09-02 就是它挖出 warmer sidecar 和三个 JIT
# 缓存挂载只存在于线上,而 `kubectl apply -f k8s/v4flash/` 会把它们悄悄删掉。
v4flash-drift:
	@$(K8S) diff -f k8s/v4flash/ 2>/dev/null | grep -E '^[+-]' | grep -vE '^[+-]{3}|generation:' \
		|| echo "no drift: 仓库与线上一致"


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

# ---- issue #55 热修:流式 tool call 截断谎报 finish_reason ----
# 补丁本体在 k8s/v4flash/configmap-launch.yaml 的 hotfix-issue55.py(含完整推理),
# rank0.sh 每次启动跑一次(幂等)。改 ConfigMap 后必须 `make v4flash-restart` —— 补丁
# 改的是已经 import 进 API server 进程的模块,光同步文件不生效。
# ⚠️ 只有 rank0 有 OpenAI entrypoint,rank1 是 --headless,不需要也不检查。
v4flash-hotfix-status:
	$(K8S) -n $(DSV4_NS) exec deploy/v4flash-leader -- \
		python3 /scripts/hotfix-issue55.py --status

# 端到端验收(打之前应当 FAIL,打之后应当全 PASS)。含回归用例:自然结束的
# tool call 必须仍报 finish_reason="tool_calls"。
v4flash-hotfix-test:
	python3 scripts/repro-issue55.py

# ========================================
# Qwen3.8-Flash-Next (换装中的主力候选, k3s, TP=2)
# ========================================
# NVFP4 checkpoint (RadixArk, ~126 GiB) + 官方 vllm/vllm-openai:qwen38-flash-next
# 镜像。方案与分阶段执行见 docs/;flags 真相源是 config/qwen38-flash-next.yaml,
# 线上跑的是 k8s/qwen38fn/configmap-launch.yaml —— **两者成对改**。
#
# ⚠️ 与 v4flash 栈和 qwen38-27b fallback 栈**三者互斥**(同一份 GPU 内存,
#    gotcha #2)。qwen38fn-run 会先自检,不再只靠文档提醒。
Q38FN_NS   ?= qwen38fn
Q38FN_HEAD ?= 100.97.87.120
Q38FN_PORT ?= 8000
Q38FN_TEST_SRC ?= scripts/qwen38fn-test.sh
Q38FN_IMAGE ?= docker.m.daocloud.io/vllm/vllm-openai:qwen38-flash-next

# 起栈前的互斥自检 + 掉页缓存。单独跑也行(只读部分),run 会自动带上。
qwen38fn-preflight:
	@v4=$$($(K8S) -n $(DSV4_NS) get deploy -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null \
		| tr ' ' '\n' | awk '{s+=$$1} END{print s+0}'); \
	if [ "$$v4" -gt 0 ]; then \
		echo "ABORT: v4flash 还有 $$v4 个副本在跑 —— 两个栈会抢同一份 GPU 内存(gotcha #2)。"; \
		echo "       先执行: make v4flash-stop"; exit 1; \
	fi
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) \
		"docker ps --filter name=$(Q38_CONTAINER) --format '{{.Names}}' | grep -q . \
		 && { echo 'ABORT: fallback 栈 $(Q38_CONTAINER) 在跑,先 make qwen38-stop'; exit 1; } || true"
	@for h in $(HOSTS); do \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h \
			"test -d /home/$(SSH_USER)/.cache/huggingface/hub/Qwen3.8-Flash-Next-NVFP4 \
			 || { echo \"ABORT: $$h 上没有权重目录(阶段 1 未完成)\"; exit 1; }; \
			 sudo k3s ctr -n k8s.io images ls -q | grep -q vllm-qwen38fn \
			 || { echo \"ABORT: $$h 的 containerd 里没有 vllm-qwen38fn 镜像(阶段 1 未完成)\"; exit 1; }" \
		|| exit 1; \
	done
	@echo "preflight OK: 互斥已确认,两节点的镜像与权重就位"

# 126 GiB 加载期间热页缓存会饿死 GPU allocator(x00byte 实测),先在两台宿主机
# 上 drop 一次。rank 脚本里还有一次 best-effort 兜底,覆盖 kubelet 自行重建的路径。
qwen38fn-run: qwen38fn-preflight
	@for h in $(HOSTS); do \
		ssh -i $(SSH_KEY) $(SSH_USER)@$$h "sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" \
			&& echo "$$h: page cache dropped"; \
	done
	$(K8S) -n $(Q38FN_NS) scale deploy qwen38fn-worker qwen38fn-leader --replicas=1
	@echo "loads 8-11min (126GiB weights) — 比 V4 的 5min 长,别急着判死"
	@echo "poll: make qwen38fn-status"

qwen38fn-status:
	@$(K8S) -n $(Q38FN_NS) get pods -o wide
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) \
		"curl -s http://localhost:$(Q38FN_PORT)/v1/models | python3 -m json.tool 2>/dev/null || echo 'not serving yet'"

qwen38fn-logs:
	$(K8S) -n $(Q38FN_NS) logs --tail=60 deploy/qwen38fn-leader

qwen38fn-logs-worker:
	$(K8S) -n $(Q38FN_NS) logs --tail=60 deploy/qwen38fn-worker

# 冒烟测试 + tool-call parser 验证(qwen3_xml vs qwen3_coder,见脚本注释)。
# ⚠️ 这是冒烟不是 benchmark —— 引用 tok/s 前先读 docs/benchmarking-cn.md。
qwen38fn-test:
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(Q38FN_TEST_SRC) $(SSH_USER)@$(Q38FN_HEAD):/home/$(SSH_USER)/qwen38fn-test.sh
	ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) \
		"BASE=http://localhost:$(Q38FN_PORT) bash /home/$(SSH_USER)/qwen38fn-test.sh"

qwen38fn-load:
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) \
		"curl -s http://localhost:$(Q38FN_PORT)/metrics | grep -E 'num_requests_(running|waiting)\{|kv_cache_usage' | grep -v '^#'; \
		echo '--- client IPs on :$(Q38FN_PORT) ---'; \
		ss -tn | grep ':$(Q38FN_PORT)' | awk '{print \$$5}' | cut -d: -f1 | sort | uniq -c | sort -rn"
	@echo '--- engine last minute ---'
	@$(K8S) -n $(Q38FN_NS) logs --since=1m deploy/qwen38fn-leader 2>/dev/null | grep 'loggers.py' | tail -3 || true

# PLE FP8 补丁 + 预检的端到端回归。抽 ConfigMap 里**线上那份**脚本,送到 S1,
# 在真实镜像 + 真实 checkpoint 的容器里跑(不占 GPU,不动运行中的栈)。
# ⚠️ 改 patch-ple-fp8.py 或 ple-preflight.py 之前必跑 —— 它们守的是静默降级。
ple-test:
	@python3 -c "import pathlib,re,sys,tempfile,os; \
	s=pathlib.Path('k8s/qwen38fn/configmap-launch.yaml').read_text(); \
	d=tempfile.mkdtemp(); \
	[pathlib.Path(d,k).write_text('\n'.join(l[4:] for l in re.search(r'\n  '+re.escape(k)+r': \|\n(.*?)(?=\n  [a-z0-9_.-]+\.(?:py|sh): \||\n  # ----)',s,re.S).group(1).split('\n'))) for k in ('patch-ple-fp8.py','ple-preflight.py')]; \
	print(d)" > /tmp/.ple_dir
	@d=$$(cat /tmp/.ple_dir); \
	ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) "rm -rf /tmp/scr && mkdir -p /tmp/scr" && \
	scp -q -i $(SSH_KEY) $$d/patch-ple-fp8.py $$d/ple-preflight.py $(SSH_USER)@$(Q38FN_HEAD):/tmp/scr/ && \
	scp -q -i $(SSH_KEY) scripts/test-ple-patch.sh $(SSH_USER)@$(Q38FN_HEAD):/tmp/e2e.sh && \
	ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) "docker run --rm \
	  -v /tmp/scr:/scripts:ro -v /tmp/e2e.sh:/tmp/e2e.sh:ro \
	  -v /home/$(SSH_USER)/.cache/huggingface/hub/Qwen3.8-Flash-Next-NVFP4:/model:ro \
	  --entrypoint bash $(Q38FN_IMAGE) /tmp/e2e.sh 2>&1 | grep -vE 'INFO |WARNING |W0902'"

qwen38fn-stop:
	$(K8S) -n $(Q38FN_NS) scale deploy qwen38fn-leader qwen38fn-worker --replicas=0

# 成对重启。⚠️ 绝不单独重建一个 rank —— 幸存方会永久卡在集合通信里,
# /health 和 /v1/models 照常 200(gotcha #1,与引擎无关,是 TP=2 的固有性质)。
qwen38fn-restart:
	$(K8S) -n $(Q38FN_NS) delete pod --all
	@echo "both ranks recreated; loads 8-11min, poll: make qwen38fn-status"

# 回滚到 V4-Flash(约 5 分钟)。观察期内 V4 的权重和镜像必须保留。
qwen38fn-rollback:
	$(K8S) -n $(Q38FN_NS) scale deploy --all --replicas=0
	@echo "qwen38fn stopped; 等 free -h 回落后执行: make v4flash-run"
	@echo "⚠️ 别忘了把 MEMWATCH_STACK 改回 v4flash,以及回滚客户端配置"

# ---- Host-level memory watchdog (防整机 OOM). See scripts/mem-watch.sh ----
# On GB10 unified memory, vLLM's ~100GB pre-allocation bypasses the container
# cgroup (verified 2026-08-15), so node-level available memory is the only
# signal that sees it. The watchdog polls both nodes over SSH and, before the
# node OOMs, scales BOTH vLLM ranks to 0 (clean, no zombie TP group). No
# auto-restore — bring the engine back with `make v4flash-run`.
MEMWATCH ?= scripts/mem-watch.sh

# ⚠️ 换主力栈时**改这一个变量**(v4flash → qwen38fn)。看门狗认的是具体的
# namespace + deploy 名;指错了它会照常巡检、照常记日志,却在真要动手时 scale
# 一组不存在的对象 —— 一道静默失效的防线。脚本启动时会自检并拒绝启动。
# 2026-09-02 主力栈切到 qwen38fn;回滚 V4 时改回 v4flash。
# ⚠️ 注释另起一行 —— 写成行尾注释会让变量带上尾随空格,
#    WATCH_DEPLOYS 会变成 "qwen38fn   -worker" 这种拼不出来的名字。
MEMWATCH_STACK ?= qwen38fn
MEMWATCH_ENV = WATCH_STACK=$(MEMWATCH_STACK) WATCH_NS=$(MEMWATCH_STACK) \
               WATCH_DEPLOYS="$(MEMWATCH_STACK)-worker $(MEMWATCH_STACK)-leader"

memwatch-check:            # 单次打印两节点 available%(只读)
	$(MEMWATCH_ENV) $(MEMWATCH) --once

memwatch:                  # 常驻循环(防 OOM,建议放 tmux)
	$(MEMWATCH_ENV) $(MEMWATCH)

memwatch-reset:            # 清除已触发状态,解除保持
	$(MEMWATCH_ENV) $(MEMWATCH) --reset

# 去抖逻辑回归(纯本地,不碰集群)。直接 source 线上那份 mem-watch.sh,
# 复现 2026-09-02 修掉的那个「看门狗永不触发」的 bug。改 tick() 前必跑。
memwatch-test:
	bash scripts/test-mem-watch.sh

# ---- GB10 GPU clock cap (能效). See scripts/gb10-clock-cap.sh + docs/gb10-tuning-cn.md ----
# 2026-08-25 双机 A/B 实测:上限 2200 MHz 下 decode 无显著变化(配对差 +0.9%,
# 95%CI [-1.9%,+3.7%], n=11 交错)、prefill -3.7%、双机 GPU rail 功耗 -36%。
# ⚠️ 两台必须对称(TP=2 锁步);⚠️ -lgc 重启即失效(用 clock-cap-install 持久化);
# ⚠️ nvidia-smi 无任何字段能报告锁是否生效 —— 只能用 clock-cap-verify(带负载采样)。
CLOCKCAP ?= scripts/gb10-clock-cap.sh

clock-cap-apply:           # 两节点加锁(CAP_MHZ 可覆盖,默认 2200);运行时,重启失效
	$(CLOCKCAP) apply

clock-cap-reset:           # 两节点解锁(-rgc)
	$(CLOCKCAP) reset

clock-cap-status:          # systemd 单元状态 + 空载频率(⚠️ 测不出锁是否生效)
	$(CLOCKCAP) status

clock-cap-verify:          # ← 唯一可靠判据:发真实生成,采样两节点负载期频率
	$(CLOCKCAP) verify

clock-cap-install:         # 装 systemd 单元,重启后仍生效
	$(CLOCKCAP) install

clock-cap-uninstall:       # 移除单元并解锁
	$(CLOCKCAP) uninstall

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
