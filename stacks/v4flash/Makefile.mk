# v4flash 专属目标 —— 由主 Makefile 的 `-include stacks/*/Makefile.mk` 自动挂上。
# 只有这个栈需要的东西放这里,不去污染通用动词。
.PHONY: probe-test probe-apply probe-verify v4flash-drift v4flash-warmer-logs \
        v4flash-hotfix-status v4flash-hotfix-test
V4_NS := $(shell . stacks/v4flash/stack.env && echo $$STACK_NS)

# 探针回归。抽 stacks/v4flash/k8s/configmap-launch.yaml 里**线上那份** liveness.py /
# worker_liveness.py,重放 2026-08-16 两次误杀健康 leader 的场景(外加一个真卡死,
# 让探针仍然会咬)。纯 stdlib,本地跑,不碰集群。⚠️ 改任一探针之前必跑。
probe-test:
	python3 scripts/test-liveness-probe.py

# 把探针推到线上。ConfigMap 是普通卷挂载(不是 subPath),kubelet 会把新文件同步
# 进**运行中**的容器 —— 不重启 Pod,不中断推理。探针**字段**(leader.yaml/worker.yaml
# 里的 periodSeconds 之类)是另一回事,那个要重建 Pod 才生效。
probe-apply: probe-test
	$(K8S) apply -f stacks/v4flash/k8s/configmap-launch.yaml
	@echo "ConfigMap updated; kubelet 会在 ~60s 内把 /scripts 同步进两个 Pod。"
	@echo "verify: make probe-verify"

probe-verify:
	@echo "--- leader ---"
	$(K8S) -n $(V4_NS) exec deploy/v4flash-leader -- \
		env V4FLASH_STATE=/tmp/.probe_check python3 /scripts/liveness.py \
		&& echo "leader rc=0 (healthy)"
	@echo "--- worker ---"
	$(K8S) -n $(V4_NS) exec deploy/v4flash-worker -- \
		env V4FLASH_WORKER_STATE=/tmp/.wprobe_check python3 /scripts/worker_liveness.py \
		&& echo "worker rc=0 (healthy)"

# 仓库 manifests 与线上的真实差异(服务端 dry-run)。⚠️ apply 之前先跑这个 ——
# 2026-09-02 就是它挖出 warmer sidecar 和三个 JIT 缓存挂载只存在于线上,
# 而 `kubectl apply -f` 会把它们悄悄删掉。
v4flash-drift:
	@$(K8S) diff -f stacks/v4flash/k8s/ 2>/dev/null | grep -E '^[+-]' | grep -vE '^[+-]{3}|generation:' \
		|| echo "no drift: 仓库与线上一致"

# warmer sidecar 日志(重启后预热曲线 + 空闲衰减探测)。结构化记录在宿主机
# /home/admin/.cache/vllm/warmer.jsonl(跨 Pod 重启保留)。
v4flash-warmer-logs:
	$(K8S) -n $(V4_NS) logs --tail=40 deploy/v4flash-leader -c warmer

# ---- issue #55 热修:流式 tool call 截断谎报 finish_reason ----
# 补丁本体在 stacks/v4flash/k8s/configmap-launch.yaml 的 hotfix-issue55.py(含完整推理),
# rank0.sh 每次启动跑一次(幂等)。改 ConfigMap 后必须 `make restart STACK=v4flash` ——
# 补丁改的是已经 import 进 API server 进程的模块,光同步文件不生效。
# ⚠️ 只有 rank0 有 OpenAI entrypoint,rank1 是 --headless,不需要也不检查。
v4flash-hotfix-status:
	$(K8S) -n $(V4_NS) exec deploy/v4flash-leader -- \
		python3 /scripts/hotfix-issue55.py --status

v4flash-hotfix-test:
	python3 scripts/repro-issue55.py
