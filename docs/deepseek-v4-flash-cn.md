# DeepSeek-V4-Flash 引擎构建与基线(2×DGX Spark / GB10)

**DeepSeek-V4-Flash-0731**(284B / 13B-active,官方 FP8)跨两台 GB10 双机 TP=2 跑 vLLM,
单流 warm **31–84 tok/s(随内容,mean 67)**,1M 上下文。
服务在 `100.97.87.120:8000`,模型名 `deepseek-v4-flash`。

> **本文只讲一次性准备(镜像构建、torch 修复、模型下载)和性能基线。**
> 日常运维用 `make v4flash-*`;**2026-08-13 起服务跑在 k3s 上**,集群设计见
> `docs/k3s-migration-design-cn.md`,manifests 与操作速查见 `k8s/README.md`。
> DSpark 调优细节见 `docs/dspark-upgrade-cn.md`。

> ⚠️ 报数前先看 [性能](#性能):DSpark 的 decode 速度 = `steps/s × 每步接受 token 数`,
> 接受率**由内容决定**,所以单个 prompt 的 tok/s 说的是那个 prompt 而不是这套集群。

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

## 运行(k3s)

日常操作用 `make v4flash-{run,status,test,load,logs,restart,stop}`(已走 kubectl)。
集群拓扑、探针、回滚见 `docs/k3s-migration-design-cn.md` 与 `k8s/README.md`。
**两条必须知道的**:绝不单独重启一个 rank(会造成僵尸 TP 组);镜像 rebuild 后要在
两台各自 `docker save … | k3s ctr -n k8s.io images import -` 再 pin。

vLLM flag 的**唯一真相源**是 `config/deepseek-v4-flash.yaml`;线上实际执行的启动
命令是它的渲染产物 `k8s/v4flash/configmap-launch.yaml`(两者要一起改)。关键 flag:
`--tensor-parallel-size 2 --kv-cache-dtype fp8 --block-size 256 --max-model-len 1000000`、
`--max-num-seqs 6 --max-num-batched-tokens 8192`(实测并发上限,16 会启动失败)、
`--gpu-memory-utilization 0.80`(见下方 OOM 教训)、
`--compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}'`、
`--speculative-config '{"method":"dspark","num_speculative_tokens":5,…}'`(n=5 是
GB10 调优值)、`--override-generation-config '{"top_p":0.95}'`(0731 模型卡对齐);
env:`VLLM_TRITON_MLA_SPARSE=1`、`NCCL_IB_DISABLE=0`(用 CX7 RoCE)、`DG_JIT_USE_NVRTC=0`。

> 注:`--distributed-executor-backend mp` 只在单机 recipe 里有效;多节点启动时
> eugr 的 `--no-ray` 路径会把它剥掉并换成 `--nnodes/--node-rank/--master-addr`,
> k8s 的 ConfigMap 里保留的就是剥掉之后的形态。

## 性能

**当前基线**(2026-08-05 全轴实测,warm、temp 0、`stream:false`、thinking off;
原始数据与复现方法见 `benchmarks/bench-full-2026-08-05/`):

| 轴 | 实测 |
|---|---|
| 单流 decode peak / mean | **84.3 / 67.2 tok/s** |
| 按内容 | count300 84.3 · 乘法表 78.6 · JSON 78.0 · BST 代码 63.8 · 散文 31.4 |
| 聚合 c1 / c2 / c4 / c6 | 67 / 113 / 143 / **186** tok/s(c6 每流 33.5)|
| prefill 8K / 32K / 100K | 1760 / 2203 / 2084 tok/s(3 次中位数,方差 ±2%)|
| DSpark 接受率 | benchmark 窗口 75.8% / 4.79 tok/step;真实流量生命周期 **48.5% / 3.43**(thinking 的推理段是散文型,接受率最低)|

重启/首次请求还有一次性 Triton JIT 编译尖刺(DSpark Markov-sampler kernel),详见
`docs/dspark-upgrade-cn.md`——那一次的数直接丢掉重测。

历史对照(各配置的单流数,均为**同一个短编码 prompt**,只用于比较配置、不代表集群上限):

| 配置 | 单流 decode |
|---|---|
| 无投机解码 | ~25 tok/s |
| MTP(num_speculative_tokens=2) | ~42 tok/s warm(社区 2×Spark 报 ~44)|
| DSpark(num_speculative_tokens=3,2026-07-03 起) | ~51-53 tok/s warm |
| **DSpark 0731(num_speculative_tokens=5,当前)** | **~56 tok/s**(2026-07-31 扫描:n=3 ≈ 53.9、n=5 ≈ 56.6、n=7 ≈ 52.4——`dspark_block_size=5`,draft 位置 4 之后接受率骤降,官方建议的 n=7 反而白费两次 draft)|

**测量三个坑**(本仓库文档都踩过,展开见 CLAUDE.md 的 Measuring throughput):
① streaming 按接受长度低报(量到的是 steps/s,同一请求 ~14 vs ~60)——用
`stream:false` + `usage.completion_tokens` / 墙钟;② 冷启动**和空闲 ~30 分钟**都会
掉 ~30%,日志里看不出来,要几次 500+ token 生成才回稳;③ 短回复被 ~0.5s 固定开销
压住,测就用 500–1400 token。

接受率可以直接观测:`curl -s localhost:8000/metrics | grep spec_decode`,请求前后各取
一次快照做差(`benchmarks/bench-full-2026-08-05/accept_diff.py` 负责算术)。

1M ctx,每节点权重 ~83GB(0731 共 166.9GB 按 TP=2 对半;`--gpu-memory-utilization 0.80`——
2026-06-29 曾在 0.85 触发头节点整机 OOM,详见提交历史/会话记录)。KV pool 实测
1.34M token @ gmu 0.80(1M 请求最大并发 1.34x;这个值每次启动会浮动 ~10%)。

### 已否决:论坛的 "0731 DSpark 1M NVFP4 KV" 配方(2026-08-05)

用它自己的 harness 对照过:**除 100K prefill 外我们全面打平或更快,不要照它重建**;
它的 "NVFP4 KV" 一点内存都不省(7,606 B/tok vs 我们 7,424)。判断未来任何 NVFP4 方案
看启动日志的 B/tok:**低于 ~6,000 才是真的**。逐条分析与复现见
`benchmarks/bench-full-2026-08-05/README.md`,结论摘要见 CLAUDE.md 同名小节。
