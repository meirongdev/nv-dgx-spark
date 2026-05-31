# DeepSeek-V4-Flash 双机部署(2×DGX Spark / GB10)

当前主力栈(2026-05-31 起):**DeepSeek-V4-Flash(284B / 13B-active,官方 FP8)跨两台 GB10 双机 TP=2 跑 vLLM**,
单流 warm **~42 tok/s**(开 MTP;不开约 ~25),200K 上下文。服务在 head `100.97.87.120:8000`,模型名 `deepseek-v4-flash`。

> 这条栈**不走本仓库的 Ansible/Makefile-vLLM 流程**,而是用 eugr 的 `spark-vllm-docker` 工具链 + jasl/vllm fork。
> 便捷封装见 `make v4flash-run | v4flash-status | v4flash-test | v4flash-logs | v4flash-stop`。

## 为什么是这套(踩过的坑)

- **SGLang 死路**:SGLang 0.5.12 的 V4 NSA 注意力依赖 **FlashMLA**,GB10(sm_121)无对应 kernel → `RuntimeError: Unsupported architecture for sparse decode fwd`。换 vLLM。
- **必须用 jasl/vllm fork**:`codex/ds4-sm120-min-enable` 带 GB10 sm_121 支持 + **triton 稀疏 MLA**(`VLLM_TRITON_MLA_SPARSE=1`,绕开 FlashMLA)。官方/裸 vLLM 不支持 V4 或缺 sm_121。
- **预构建镜像 China 拿不到**(daocloud 拒冷门 org、直连被墙),只能源码编译。

## 一次性准备

### 1. 外网代理(编译要 clone github)
S1 的 v2rayN 代理(privoxy `172.17.0.1:10809` → xray SOCKS `127.0.0.1:10808` → SS 节点)在无头机上核心不会自启。复活:
```bash
bash scripts/v2rayn-launch.sh      # 从 v2rayN DB 取 SS 节点,无头拉起 xray core(tmux)
# 验证: curl -x http://172.17.0.1:10809 https://github.com  → 200
git config --global http.proxy http://172.17.0.1:10809
# docker build 走代理: ~/.docker/config.json 的 proxies.default.http(s)Proxy = http://172.17.0.1:10809
```

### 2. 编译 jasl/vllm fork(~43 分钟,tmux)
```bash
cd /home/admin/spark-vllm-docker
tmux new-session -d -s dsv4build "./build-and-copy.sh \
  --vllm-repo https://github.com/jasl/vllm.git \
  --vllm-ref codex/ds4-sm120-min-enable --rebuild-vllm \
  -t vllm-node-dsv4 --copy-to 192.168.200.102 2>&1 | tee /tmp/dsv4-build.log"
```
产出镜像 `vllm-node-dsv4:latest`,经 200G 自动拷到 S2。

### 3. 修 torch(关键!构建产物的运行阶段 torch 变成了 CPU 版)
eugr 从源码构建后,runner 里的 vllm wheel + ray/fastsafetensors 依赖会把 cu130 torch 覆盖成 `2.10.0+cpu`,
导致 `vllm._C: libtorch_cuda.so missing`。重装匹配的 cu130 torch 并 commit:
```bash
bash scripts/vllm-fix-torch.sh     # 在镜像内重装 torch==2.11.0 cu130 → 验证 vllm._C → commit → 拷 S2
```

### 4. 模型(官方 FP8,本地路径,**不要用 repo-id**)
权重在两台的 `/home/admin/.cache/huggingface/hub/DeepSeek-V4-Flash`(ModelScope 下的 flat 目录,46 shards / 149GB)。
recipe 里 `model:` 直接写**容器内路径** `/root/.cache/huggingface/hub/DeepSeek-V4-Flash`——
因为 worker(S2)无代理、HF repo-id 解析会失败或想重下;而 HF 缓存软链必须相对路径才能在容器内解析(同 ModelScope 坑)。

## 启动 / 验证 / 停止

```bash
make v4flash-run        # run-recipe.sh deepseek-v4-flash --no-ray(tmux),~3-4min 加载 + cuda graph
make v4flash-status     # /v1/models + 容器状态
make v4flash-test       # 编码冒烟 + 量 tok/s
make v4flash-logs       # tail head 日志
make v4flash-stop       # 停双机
```

recipe:`config/deepseek-v4-flash.yaml`(镜像里 `~/spark-vllm-docker/recipes/deepseek-v4-flash.yaml` 的镜像)。
关键 flag:`--tensor-parallel-size 2 --kv-cache-dtype fp8 --block-size 256 --max-model-len 200000`、
`--distributed-executor-backend mp`、`--compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE"}'`、
`--speculative-config '{"method":"deepseek_mtp","num_speculative_tokens":2}'`(MTP);
env:`VLLM_TRITON_MLA_SPARSE=1`、`NCCL_IB_DISABLE=0`(用 CX7 RoCE)、`DG_JIT_USE_NVRTC=0`。

## 性能

| 配置 | 单流 decode |
|---|---|
| 无 MTP | ~25 tok/s |
| **MTP(num_speculative_tokens=2)** | **~42 tok/s warm**(社区 2×Spark 报 ~44)|

200K ctx 下 KV cache ≈ 2M tokens、并发 ~10x。每节点权重 ~74GB(`--gpu-memory-utilization 0.85`)。
