.PHONY: venv install ping facts cmd inventory all clean tmux-cmd tmux-attach tmux-list tmux-kill modelscope-download run stop restart status logs logs-worker boot-log load preflight info test stacks stack-info switch stack-table stack-check preflight-test memwatch memwatch-check memwatch-reset memwatch-test clock-cap-apply clock-cap-reset clock-cap-status clock-cap-verify clock-cap-install clock-cap-uninstall node-exporter-deploy node-exporter-status node-exporter-stop node-exporter-logs smartctl-exporter-deploy smartctl-exporter-status smartctl-exporter-stop smartctl-exporter-logs

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

# k3s 集群(kubeconfig 在这台操作机上)。栈级的 namespace / deploy 名不在这里 ——
# 那些住在 stacks/<id>/stack.env,由 stacks/_lib/adapter-k3s.sh 读取。
K8S ?= kubectl --kubeconfig $(HOME)/.kube/dgx-spark.yaml

# Create virtual environment and install Ansible
venv:
	uv venv .venv
	uv pip install ansible

# Install dependencies (alias for venv)
install: venv

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

# ===========================================================================
# 栈的生命周期 —— 所有栈共用这一组动词
# ===========================================================================
# 这里**不认识任何一个栈的名字**。栈的身份住在 stacks/<id>/stack.env,
# 当前主力栈住在 stacks/PRIMARY(一行 id)。加一个模型 = 新建 stacks/<id>/,
# 本文件一个字都不用改。契约见 stacks/README.md。
#
#   make run                      # 起当前主力栈(stacks/PRIMARY)
#   make run    STACK=glm53       # 起指定栈
#   make logs   STACK=qwen38fn WORKER=1
#   make stacks                   # 注册表一览
#   make switch TO=qwen38fn       # 换主力栈(含验收)
#
# ⚠️ 所有栈**互斥**(同一份 GPU 内存,gotcha #2)。run 前的 preflight 会遍历
#    **整个注册表**逐个探测,不是一张手写的名单 —— 所以新栈一落地,所有既有栈
#    自动开始检查它。
STACKCTL := stacks/_lib/stackctl.sh
STACK    ?=
TAIL     ?= 60

run stop restart status boot-log load preflight info test:
	@$(STACKCTL) $@ $(STACK)

# make logs STACK=x WORKER=1 看 rank1(双节点栈);单节点栈会直说"没有 worker"。
logs:
	@TAIL=$(TAIL) $(STACKCTL) $(if $(WORKER),logs-worker,logs) $(STACK)

logs-worker:
	@TAIL=$(TAIL) $(STACKCTL) logs-worker $(STACK)

stacks:                    # 注册表一览(谁是主力、端口、served name)
	@$(STACKCTL) list
	@echo
	@echo "PRIMARY = $$($(STACKCTL) primary)"

# ---- 换主力栈 --------------------------------------------------------------
# 「当前主力栈是谁」以前写死在 ~8 个地方,每一处改错都**不报错**
# (docs/stack-switch-cn.md §0 记了同形状的三次事故)。现在只有 stacks/PRIMARY
# 一处,其余全部从注册表推导 —— 这个目标负责改它并跑验收。
switch:
ifndef TO
	$(error 用法: make switch TO=<stack-id>;可选的栈见 make stacks)
endif
	@bash scripts/stack-switch.sh $(TO)

# ---- 注册表与文档的一致性 ---------------------------------------------------
# stack-table 重新生成 CLAUDE.md / README.md / docs/clients-cn.md 里的栈表格;
# stack-check 只校验不改写,不一致就**非 0 退出**。
# 这是"文档静默过期"那一类事故的机械化防线:091b6e4 换了主力栈却一份文档都没动,
# CLAUDE.md 因此在 24 小时里持续告诉每个 session 错误的主力栈。
stack-table:
	@python3 scripts/stack-table.py --write

stack-check:
	@python3 scripts/stack-table.py --check

# 互斥自检的回归(纯本地,探测打桩)。它守的是 gotcha #2 —— 两个栈抢同一份 GPU
# 内存会 OOM 整机,而这两台没有 BMC。⚠️ 改 stacks/_lib/preflight.sh 之前必跑。
preflight-test:
	bash scripts/test-preflight.sh

# ---- 各栈自带的专属目标(可选)----------------------------------------------
# 栈可以放一个 stacks/<id>/Makefile.mk 声明只有它需要的目标(探针回归、补丁
# 回归之类)。没有就没有 —— 又一处"加模型不用改既有文件"。
-include stacks/*/Makefile.mk

# ===========================================================================
# 宿主机内存看门狗(防整机 OOM)
# ===========================================================================
# GB10 统一内存上,引擎预占的 ~100GB 会**绕过容器 cgroup**,所以只有节点级
# available 内存看得见它。看门狗在节点 OOM 之前把栈整体停掉(不留僵尸 TP 组)。
# 不自动恢复:`make run` 才会把引擎拉回来。建议放 tmux 里常驻。
#
# ⚠️ 换主力栈时**这里没有任何东西要改** —— 看门狗自己去读 stacks/PRIMARY。
#    (在此之前它靠 Makefile 里一段 ifeq 阶梯 + 脚本里的一组 WATCH_* 默认值,
#     指错栈时它会照常巡检、照常记日志,真要动手时 scale 一组不存在的对象。)
MEMWATCH ?= scripts/mem-watch.sh

memwatch-check:            # 单次打印各节点 available%(只读)
	@$(MEMWATCH) --once $(STACK)

memwatch:                  # 常驻循环(防 OOM,建议放 tmux)
	@$(MEMWATCH) $(STACK)

memwatch-reset:            # 清除已触发状态,解除保持
	@$(MEMWATCH) --reset $(STACK)

# 去抖逻辑回归(纯本地,不碰集群)。改 tick() 前必跑。
memwatch-test:
	bash scripts/test-mem-watch.sh

# ===========================================================================
# GB10 GPU 时钟上限(能效)
# ===========================================================================
# 2026-08-25 双机 A/B:2200 MHz 下 decode 无显著变化(配对差 +0.9%,95%CI
# [-1.9%,+3.7%], n=11 交错)、prefill -3.7%、双机 GPU rail 功耗 -36%。
# ⚠️ 两台必须对称(TP=2 锁步);⚠️ -lgc 重启即失效(用 clock-cap-install 持久化);
# ⚠️ nvidia-smi 无任何字段能报告锁是否生效 —— 只能用 clock-cap-verify(带负载采样)。
# ⚠️ verify 要发真实生成,所以它需要知道 model 名/端口/思考 kwarg ——
#    这三个现在从 stacks/PRIMARY 推导,换栈时不用改脚本。
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
