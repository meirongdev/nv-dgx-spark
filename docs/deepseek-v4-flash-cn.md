# DeepSeek-V4-Flash 双机部署(2×DGX Spark / GB10)

当前主力栈(2026-05-31 起;2026-07-03 从 MTP 升级到 DSpark;2026-07-31 换到 **0731 官方正式版**
checkpoint `DeepSeek-V4-Flash-0731` 并把 `num_speculative_tokens` 调到 5):**DeepSeek-V4-Flash
(284B / 13B-active,官方 FP8)跨两台 GB10 双机 TP=2 跑 vLLM**,单流 warm **~56 tok/s**
(DSpark n=5;n=3 时 ~51-53,此前 MTP ~42,不开投机解码约 ~25),1M 上下文。
服务在 head `100.97.87.120:8000`,模型名 `deepseek-v4-flash`。

> 这条栈**不走本仓库的 Ansible/Makefile-vLLM 流程**,而是用 eugr 的 `spark-vllm-docker` 工具链 + jasl/vllm fork。
> 便捷封装见 `make v4flash-run | v4flash-status | v4flash-test | v4flash-load | v4flash-logs | v4flash-stop`。
> **DSpark 升级 runbook**(MTP 的继任投机解码)见 `docs/dspark-upgrade-cn.md`。

## 为什么是这套(踩过的坑)

- **SGLang 死路**:SGLang 0.5.12 的 V4 NSA 注意力依赖 **FlashMLA**,GB10(sm_121)无对应 kernel → `RuntimeError: Unsupported architecture for sparse decode fwd`。换 vLLM。
- **必须用 jasl/vllm fork**:`codex/ds4-sm120-min-enable` 带 GB10 sm_121 支持 + **triton 稀疏 MLA**(`VLLM_TRITON_MLA_SPARSE=1`,绕开 FlashMLA)。
  **⚠️ 2026-07-04 更正**:官方 vLLM 其实**能**在 GB10 双机 TP=2 跑通普通 V4-Flash(需带
  `DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=...`,缺了会报看似"架构不支持"的错)——
  **jasl fork 现在唯一不可替代的价值是 DSpark**,详见 `docs/dspark-upgrade-cn.md`。
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
当前权重(2026-07-31 起)在两台的 `/home/admin/.cache/huggingface/hub/DeepSeek-V4-Flash-0731`
(ModelScope 下的 flat 目录,48 shards / 166.9GB,**官方正式版,DSpark 模块内置**;
它替换了此前的 preview 底模 `DeepSeek-V4-Flash`(46 shards / 149GB)+ 独立 DSpark checkpoint 组合,
结构相同、config.json 逐字节一致,纯换权重即可)。
recipe 里 `model:` 直接写**容器内路径** `/root/.cache/huggingface/hub/DeepSeek-V4-Flash-0731`——
因为 worker(S2)无代理、HF repo-id 解析会失败或想重下;而 HF 缓存软链必须相对路径才能在容器内解析(同 ModelScope 坑)。

## 启动 / 验证 / 停止

```bash
make v4flash-run        # run-recipe.sh deepseek-v4-flash --no-ray(tmux),~3-4min 加载 + cuda graph
make v4flash-status     # /v1/models + 容器状态
make v4flash-test       # 编码冒烟 + 量 tok/s
make v4flash-load       # 谁在用引擎(running/waiting 请求数、KV%、客户端 IP)——"变慢"先查这个
make v4flash-logs       # tail head 日志
make v4flash-stop       # 停双机
```

recipe:`config/deepseek-v4-flash.yaml`(镜像里 `~/spark-vllm-docker/recipes/deepseek-v4-flash.yaml` 的镜像)。
关键 flag:`--tensor-parallel-size 2 --kv-cache-dtype fp8 --block-size 256 --max-model-len 1000000`、
`--max-num-seqs 6 --max-num-batched-tokens 8192`(实测并发上限,16 会启动失败,见
`docs/dspark-upgrade-cn.md`)、`--gpu-memory-utilization 0.80`(见下方 OOM 教训)、
`--distributed-executor-backend mp`、
`--compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}'`、
`--speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"greedy"}'`
(DSpark,n=5 是 GB10 调优值,详见 `docs/dspark-upgrade-cn.md`;此前用的是 `deepseek_mtp`)、
`--override-generation-config '{"top_p":0.95}'`(0731 官方模型卡对齐);
env:`VLLM_TRITON_MLA_SPARSE=1`、`NCCL_IB_DISABLE=0`(用 CX7 RoCE)、`DG_JIT_USE_NVRTC=0`。

## 开机自启(systemd,重启后自动拉起)

容器是 `--rm` 且无 restart policy,**重启后整套服务不会自己回来**。装一次 systemd unit 即可:

```bash
make v4flash-autostart          # 一次性:装 + enable(开机自启)
make v4flash-autostart-start    # 现在就起(= sudo systemctl restart)
make v4flash-autostart-status   # systemctl status + 最近 journal
make v4flash-autostart-remove   # 卸载(disable + 删 unit)
```

要点:

- **只在 head 装一个 unit**(`User=admin`)。head 的 `launch-cluster.sh` 通过 SSH
  拉起 TP worker,所以 worker 不需要 unit——只要 docker + sshd(默认都自启)在跑。
- **docker `--restart` 救不了**:vLLM 是在 `sleep infinity --rm` 容器里以前台
  `docker exec` 跑的,restart policy 只会把那个 sleep 重启回来。必须重跑整套编排
  (`run-recipe.sh --no-ray`),这正是 unit `ExecStart` 做的事。
- **开机竞态**:`scripts/v4flash-boot.sh` 在启动前会等(≤15min,`DSV4_WAIT_TIMEOUT`)
  worker 的 ssh+docker+GPU 经 200G 链路就绪,避免两台同时重启时 `launch-cluster.sh`
  因连不上 worker 而 abort。`Restart=on-failure` 兜底(顺带白送崩溃自恢复)。
- **装好之后,`make v4flash-run`/`v4flash-stop` 自动走 systemd**
  (`systemctl restart`/`stop`),手动和开机路径一致;手动 `docker rm` 不会再触发
  `Restart=on-failure` 打架。tmux 启动只在 unit 未安装时(如重新编译期间)兜底。
  日志从 `/tmp/dsv4-run.log` 改看 `journalctl -u deepseek-v4-flash`。

## 性能

| 配置 | 单流 decode |
|---|---|
| 无投机解码 | ~25 tok/s |
| MTP(num_speculative_tokens=2) | ~42 tok/s warm(社区 2×Spark 报 ~44)|
| DSpark(num_speculative_tokens=3,2026-07-03 起) | ~51-53 tok/s warm(接受率随内容波动 40-85%)|
| **DSpark 0731(num_speculative_tokens=5,当前)** | **~56 tok/s warm**(2026-07-31 扫描:n=3 ≈ 53.9、n=5 ≈ 56.6、n=7 ≈ 52.4——`dspark_block_size=5`,draft 位置 4 之后接受率骤降,官方建议的 n=7 反而白费两次 draft;重启/首次请求有一次性 Triton JIT 编译尖刺,详见 `docs/dspark-upgrade-cn.md`)|

1M ctx,每节点权重 ~83GB(0731 共 166.9GB 按 TP=2 对半;`--gpu-memory-utilization 0.80`——
2026-06-29 曾在 0.85 触发头节点整机 OOM,详见提交历史/会话记录)。
