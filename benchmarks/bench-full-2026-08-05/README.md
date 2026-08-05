# 全轴重测 + NVFP4-KV 社区配方对照（2026-08-05）

回答一个具体问题：

> NVIDIA 论坛帖 [DeepSeek-V4-Flash-0731 DSpark 1M NVFP4 KV 2×DGX Spark](https://forums.developer.nvidia.com/t/deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark/378824)
> （repo `tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark`）
> 报出 84.3 tok/s peak / 67.6 mean、c6 聚合 197 tok/s、100K prefill 2639 tok/s，
> 还有 4-bit `nvfp4_ds_mla` KV。按它重建我们这套栈是不是更好？

**答案：不是。除 100K prefill 外,我们现有栈全面打平或更快。**

方法上关键的一点：直接跑**他们自己的 harness**（`benchmarks/bench_full.py`，
MIT，见下方 attribution），在 S1 上对 `localhost:8000` 打，避免 Tailscale RTT
污染 prefill 那一格；请求里注入 `chat_template_kwargs:{"thinking":false}` 以
对齐他们 launcher 的 `--default-chat-template-kwargs '{"thinking":false}'`。
两边同样是 warm、temp 0、`stream:false`、best-of-2。

## 结果

| 指标 | 他们最好成绩（preview ckpt） | 他们自己在 **0731** 上的数 | **我们**（0731 + jasl + fp8 KV） |
|---|---|---|---|
| decode peak / mean | 84.3 / 67.6 | 78 峰值探针 / ~55 mean | **84.3 / 67.2** |
| c1 / c2 / c4 / c6 聚合 | 61 / 92 / 151 / 197 | – | **67 / 113 / 143 / 186** |
| prefill 8K / 32K / 100K | 1513 / 2284 / 2639 | – | **1760 / 2203 / 2084**(3 次中位数)|
| DSpark 接受率, tok/step | – | 60.2%, 4.01 | **75.8%, 4.79** |
| KV pool | 1.55M tok @ gmu 0.78 | – | 1.34M tok @ gmu 0.80 |

按内容拆分的 decode（我们，warm、temp 0、best-of-2）：

| prompt | tok | 秒 | tok/s |
|---|---:|---:|---:|
| count300（数到 300） | 600 | 7.12 | **84.3** |
| mult12（12×12 乘法表） | 900 | 11.45 | 78.6 |
| json60（60 个对象） | 800 | 10.26 | 78.0 |
| bst（二叉搜索树代码） | 600 | 9.41 | 63.8 |
| story（200 词散文） | 274 | 8.72 | 31.4 |
| **peak / mean** | | | **84.3 / 67.2** |

原始输出见 `bench-full-2026-08-05.log`。

**接受率的两个口径别混用**:上表 75.8% 是**这轮 benchmark 窗口**的差分值(内容偏结构化,
和他们发布数字同口径,可比);同一台服务器的**生命周期**累计值(4 天真实 codex/qwen 流量、
thinking 默认开)是 **48.5%,3.43 tok/step**,per-position 0.807/0.615/0.450/0.323/0.231。
差距来自内容构成 —— thinking 的推理段是散文型,接受率最低(他们按内容拆:结构化 78%、
代码 69%、散文 34%)。规划容量用生命周期值,和别人对比用同口径的 benchmark 值。

## 三个卖点逐条核对

**1. "1M NVFP4 KV" 省不了内存。** 三步推导，第三步是定量的。

**(a) 读它的代码。** `recipe/nvfp4/Dockerfile.stage-c` 干的事就是把 stage A/B 的真
4-bit 布局**改回去** —— 三处 patch 全是 416 → 584：

| 文件 | stage A/B | Stage C 改成 |
|---|---|---|
| `models/deepseek_v4/attention.py` | `head_bytes = 416` | `head_bytes = 584` |
| `models/deepseek_v4/nvidia/flashmla.py` | `return (num_blocks, block_size, 416)` | `…, 584)` |
| `v1/kv_cache_interface.py` | `storage_block_size * 416` | `* 584`（V4 专用分支） |

584 是什么，它自己 `Dockerfile.stage-b:93` 的注释写明了：`DeepseekV4 main MLA: 584B
per token (448 NoPE + 128 RoPE + 8 fp8 scale)` —— 就是 **fp8 布局**，也正是我们
`fp8_ds_mla` 用的那个。`cache_dtype` 换成 `nvfp4_ds_mla` 只改走哪条 kernel,不改一个
token 占多少字节。

**(b) 它自己的 README 承认了**（"Important caveat — Stage C padded NVFP4"）:这不是
真 4-bit 布局,真布局在 **~411 个真实 prompt token** 之后就崩,所以没被当成可复现配方
发出来。troubleshooting 还写着 4-bit KV 在长 agent 上下文下会 "collapse into salad",
让人退回 fp8 的姊妹 repo —— 我们本来就在它的兜底配置上。

**(c) 用两边 boot log 直接算 bytes/token。** vLLM 启动打的 `Available KV cache memory`
÷ `GPU KV cache size` 就是每 token 字节数。**两边都是 `--block-size 256`**（它
`docker-compose.dspark.yml:105`,我们 recipe）,可比：

| | 配置 | 可用 KV 内存 | KV pool | **B/tok** |
|---|---|---:|---:|---:|
| 我们 | `fp8_ds_mla` | 10.03 GiB | 1,450,587 | **7,424** |
| 我们 | `fp8_ds_mla` | 10.02 GiB | 1,449,281 | **7,424** |
| 我们 | `fp8_ds_mla` | 9.29 GiB | 1,344,217 | **7,421** |
| 它 | `nvfp4_ds_mla` Stage C | 14.48 GiB | 2,044,166 | **7,606** |
| — | *若为真 4-bit(416/584)* | | | *预期 ~5,288* |

它的"4-bit KV"每 token 花 **7,606 字节,比我们的 fp8 还多 2.5%**,离真 4-bit 该有的
5,288 差得很远。这就是"省不了内存"的定量版本 —— 不是推断,是它自己发布的 boot log
（`benchmarks/20260629-dspark-nvfp4-1m-context-checkpoint.md:26-27`）算出来的。我们
的三行取自 head node `journalctl -u deepseek-v4-flash | grep -E "Available KV cache
memory|GPU KV cache size"`;第三行日志显示 10.34 GiB 而算出 9.59,因为 pool 按两个
TP rank 的**较小者**定,日志只打了 TP0。

**所以它 pool 更大（1.55M vs 我们 1.34M）只能来自可用内存更多**:更轻的 preview
checkpoint、`gpu_memory_utilization` 0.78/0.85 vs 我们 0.80、
`VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` —— 不是 4-bit KV。而抬到它 C12 lane 的
0.85 正是 2026-06-29 打爆 head node 的那个值。它自己 README:374 也标了这个数不可当固定
属性看:同一配置两次启动测到 1,385,765 和 1,533,940（**11% 抖动**),我们的 1.34M 就落
在这个带里。

> **没核对上的一个 boot**:`benchmarks/20260702-keys-c12-1p5m-nvfp4-checkpoint.md` 报
> `GPU KV cache size: 3,225,280 tokens`,是其它 boot 的两倍多,但那份文档**没贴**
> `Available KV cache memory`,算不出 B/tok。那个 lane 是 gmu 0.85 + `max_model_len=1.5M`
> + `VLLM_USE_B12X_WO_PROJECTION=1`(改权重路径,腾的是权重内存,仍非 KV dtype 层面的
> 节省)。严格讲这一个 boot 只能算"无法核对",不算已排除。

**2. "B12X MoE ≈ 2×"** 是相对**他们 base image**（`ghcr.io/bjk110/vllm-spark`）
的 DEEPGEMM_MXFP4 fallback，不是相对我们的 build。我们的 Triton sparse-MLA +
torch.compile 路径同样落在 84.3。

**3. 他们的 Patch 4 我们不受影响。** 这是那个 repo 里唯一真有价值的发现：0731 上
vLLM 的 DSpark draft loader 静默丢掉 12 个
`model.layers.{43,44,45}.ffn.shared_experts.gate_up_proj.*` tensor（`w1`/`w3`
没进 `_STACKED_PARAM_NAME_MAPPING`，只在 DEBUG 级打 "Skipping unknown DSpark
weight"），draft 的 always-on shared expert 未初始化 → 输出仍正确、steps/s 不变、
**接受率腰斩**（25.7% vs 60.2%）。因为我们正好跑 0731，专门查了：

- jasl fork 是另一套实现，`v1/spec_decode/dspark.py` 里根本没有
  `stacked_params_mapping` / `shared_experts` / "Skipping unknown" 这些锚点；
- 实测每个 draft 位置的接受率 **0.904 / 0.814 / 0.739 / 0.683 / 0.648**，全面
  高于他们**打完补丁**的 0.826 / 0.725 / 0.572 / 0.471 / 0.399，更远高于坏
  loader 的 0.631 / 0.282 / 0.181 / 0.114 / 0.067。

## 换过去的代价（另一半理由）

- runtime 要退回 **vLLM 0.21.1** 冻结版 + 15 个手工维护的 overlay 文件（含 340KB
  `gpu_model_runner.py`、109KB `scheduler.py`）。他们自己的 bakeoff
  （`RUNTIME-BAKEOFF-2026-07-29.md`）证明升不上新 runtime：vLLM 0.25.2 在同一
  硬件上 peak -9%、c6 -29%。我们现在是 2026-07-03 的 dev build。
- 13GB `ghcr.io` 镜像（国内网络）、每节点 ~200GB 磁盘。
- 我们的 systemd 开机自启 + boot-race 处理 + Makefile 全部要换成他们的
  docker-compose worker-first launcher；端口 8888、served name
  `deepseek-v4-flash-0731` 都变，客户端要重配；默认 `thinking:false`。
- 他们仍开着的坑：issue #6（持续 agent 负载下偶发"有 token 但内容为空"的软失败）、
  issue #8（gmu 0.80 能启动能过冒烟，但首个真实请求就崩 —— 我们 0.80 稳跑 4 天）、
  镜像里 baked 的 `VLLM_HOST_IP` / `--node-rank` / `NCCL_IB_HCA` 换节点就炸。

## 决定：不切,但 NVFP4 KV 本身留作观察项

**当前决定（2026-08-05）：不切这个 repo。** 但结论是"**这个版本**的 NVFP4 没价值",
不是"NVFP4 KV 这条路没价值" —— 真 4-bit sparse-MLA KV 该省的 ~29% B/tok（7,424 →
~5,288）是真金白银,只是这个 repo 只做到了把 dtype 名字换掉。以后出现更合适的版本再评估。

**重估的触发条件**（任一成立就值得重新算一次）:

1. **真布局落地** —— 出现能稳过 411 个真实 prompt token 的 416 字节 `nvfp4_ds_mla`
   store/decode kernel（上游 vLLM 或任何 fork 都算）。判据不看 README 措辞,直接算
   boot log 的 B/tok:**低于 ~6,000 才是真的**,7,4xx–7,6xx 就还是 padded 那套。
2. **不用退 runtime** —— 该实现能跑在 ≥ 我们现在（2026-07-03 dev）的 vLLM 上,而不是
   绑死在冻结的 0.21.1 + 15 个 overlay 文件上。
3. **长 agent 上下文不崩** —— 4-bit KV 的 "collapse into salad" 有明确修复,而不是靠
   "退回 fp8" 兜底。
4. 附带前提:我们真的缺 KV pool。现在 1.34M tok / 1.39x 并发 @1M ctx,`max_num_seqs=6`
   下并不吃紧 —— 省下来的内存目前没有明确用途,这也是不急的原因。

眼下更现实的脱离 jasl fork 的路径仍是 **eugr 上游 b12x**（见 CLAUDE.md）,和 NVFP4 KV
是两条独立的线。

## 值得白拿的（不用重建）

1. **100K prefill 是他们唯一真实领先项**（复测后 **2639 vs 2084,+27%**）——
   但**目前没有免费的杠杆能拿到它**,见下方「100K prefill 追查」。
2. **warm 状态会随空闲衰减**：同一容器空闲 ~30 分钟后 count300 从 83.5 掉到
   60.4，重新灌几百 token 才恢复，boot log 里看不出来。这是"变慢"的第二个机制，
   和已记录的并发饱和无关。
3. **测量方法**：见 CLAUDE.md「Measuring throughput」。我们文档里
   "~56 tok/s"（单个短 fib prompt + thinking on 的形状产物）和 "~50 tok/s
   聚合"（大概率是按 streaming chunk 计数，spec decode 下会按接受长度低报）
   都已按本次实测校正。

## 100K prefill 追查（2026-08-05,唯一落后项）

先把数坐实:3 次重复、每次换唯一前缀让 prefix cache 失效(脚本
`prefill_repeat.py`,日志 `prefill-repeats-2026-08-05.log`),方差只有 ±2%:

| depth | 3 次实测 | 中位数 | 他们 | 差距 |
|---|---|---:|---:|---:|
| 8K | 1747 / 1760 / 1800 | **1760** | 1513 | 我们 +16% |
| 32K | 2063 / 2228 / 2203 | **2203** | 2284 | 持平(-4%) |
| 100K | 2051 / 2084 / 2095 | **2084** | 2639 | 他们 +27% |

原先那个 1975 是单次采样偏低 ~5%。差距真实但只出现在 100K 这一格:我们的曲线在
32K→100K 走平(2203→2084),他们的还在爬(2284→2639)。

> 口径说明:两边都开着 `--enable-prefix-caching`,而 harness 按 8K→32K→100K 升序、
> 用同一段 filler,所以 100K 的前 ~24.9K token 命中了上一格留下的缓存 —— `prompt_tokens`
> 仍按 77.8K 计,时间只覆盖约 53K 的真实计算,**两边同样虚高**。我的重复只隔离了
> *repeat 之间*的缓存,保留了 repeat *内部*的升序共享,和他们完全同口径。

**已排除的"免费杠杆"**:

| 候选 | 结论 |
|---|---|
| `--async-scheduling`(他们 launcher 有,我们 recipe 没有) | **本来就开着**。本 build 里 `async_scheduling=None` 走的是"除非不兼容否则自动开启"分支,`dspark` 在白名单里(`config/vllm.py:981-1060`),journal 每次启动都打 `Asynchronous scheduling is enabled`。加这个 flag 是 no-op。 |
| `VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256`(他们显式设) | 我们的默认是 **512**,比他们更宽松。不是他们的优势来源。 |
| `--enable-flashinfer-autotune` | 我们 `KernelConfig` 里已经是 `enable_flashinfer_autotune=True`。 |
| `--max-cudagraph-capture-size` | 与 prefill 无关(分块 prefill 不走 cudagraph)。 |

**剩下最可能的原因是 B12X MoE kernel**:100K prefill 是 ~10 个 8192-token 分块的
大 M MoE GEMM,正是自定义 MXFP4 kernel 最占便宜的地方 —— 而这块恰恰绑死在他们那套
冻结的 0.21.1 runtime 上,拿不出来单独用。

**还没试、但要付出代价的**:`--max-num-batched-tokens` 8192 → 16384(更少更大的
prefill 分块,是提 prefill 吞吐的经典杠杆),代价是并发下 in-flight decode 的每步延迟
变大、KV 池被挤(`max_num_seqs=16` + 16384 曾直接启动失败)。以"37s vs 29s TTFT @100K"
的收益看,不值得在生产 endpoint 上冒这个险。

## 复现

```bash
# 在 head node 上，对 localhost 打（别从 Mac 打，Tailscale RTT 会污染 prefill）
scp benchmarks/bench-full-2026-08-05/bench_full.py admin@100.97.87.120:/tmp/
ssh admin@100.97.87.120 'tmux new-session -d -s benchcmp "URL=http://localhost:8000/v1 \
  MODEL=deepseek-v4-flash TAG=current THINKING=0 python3 /tmp/bench_full.py > /tmp/benchcmp.log 2>&1"'

# 接受率：请求前后各取一次 /metrics 快照再 diff
ssh admin@100.97.87.120 'curl -s localhost:8000/metrics | grep -E "^vllm:spec_decode" | grep -v _created > /tmp/a.txt'
# ...跑负载...
ssh admin@100.97.87.120 'curl -s localhost:8000/metrics | grep -E "^vllm:spec_decode" | grep -v _created > /tmp/b.txt
                         python3 /tmp/accept_diff.py /tmp/a.txt /tmp/b.txt'
```

跑一轮约 12 分钟（含 5 次长 warm-up 生成）。**必须 warm 后再看数**（见上文第 2 点）。

## Attribution

`bench_full.py` 来自
[tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark)
（`benchmarks/bench_full.py`，MIT），本地改动只有两处：`THINKING` 环境变量控制
`chat_template_kwargs.thinking`（用于对齐两边的 thinking 状态）。`accept_diff.py`
是本仓库自己写的 `/metrics` 差分脚本。
