# qwen38fn 专属目标 —— 由主 Makefile 的 `-include stacks/*/Makefile.mk` 自动挂上。
.PHONY: ple-test
Q38FN_HEAD  := $(shell . stacks/qwen38fn/stack.env && echo $$STACK_HEAD)
Q38FN_IMAGE := $(shell . stacks/qwen38fn/stack.env && echo $$STACK_IMAGE_FULL)
Q38FN_WTS   := $(shell . stacks/qwen38fn/stack.env && echo $$STACK_WEIGHTS)

# PLE FP8 补丁 + 预检的端到端回归。抽 ConfigMap 里**线上那份**脚本,送到 S1,
# 在真实镜像 + 真实 checkpoint 的容器里跑(不占 GPU,不动运行中的栈)。
# ⚠️ 改 patch-ple-fp8.py 或 ple-preflight.py 之前必跑 —— 它们守的是**静默降级**:
#    51 GiB 的 PLE 表被上采样成 bf16 且没有 scale,模型照常服务,质量悄悄掉下去。
ple-test:
	@python3 -c "import pathlib,re,sys,tempfile,os; \
	s=pathlib.Path('stacks/qwen38fn/k8s/configmap-launch.yaml').read_text(); \
	d=tempfile.mkdtemp(); \
	[pathlib.Path(d,k).write_text('\n'.join(l[4:] for l in re.search(r'\n  '+re.escape(k)+r': \|\n(.*?)(?=\n  [a-z0-9_.-]+\.(?:py|sh): \||\n  # ----)',s,re.S).group(1).split('\n'))) for k in ('patch-ple-fp8.py','ple-preflight.py')]; \
	print(d)" > /tmp/.ple_dir
	@d=$$(cat /tmp/.ple_dir); \
	ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) "rm -rf /tmp/scr && mkdir -p /tmp/scr" && \
	scp -q -i $(SSH_KEY) $$d/patch-ple-fp8.py $$d/ple-preflight.py $(SSH_USER)@$(Q38FN_HEAD):/tmp/scr/ && \
	scp -q -i $(SSH_KEY) scripts/test-ple-patch.sh $(SSH_USER)@$(Q38FN_HEAD):/tmp/e2e.sh && \
	ssh -i $(SSH_KEY) $(SSH_USER)@$(Q38FN_HEAD) "docker run --rm \
	  -v /tmp/scr:/scripts:ro -v /tmp/e2e.sh:/tmp/e2e.sh:ro \
	  -v $(Q38FN_WTS):/model:ro \
	  --entrypoint bash $(Q38FN_IMAGE) /tmp/e2e.sh 2>&1 | grep -vE 'INFO |WARNING |W0902'"
