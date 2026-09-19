# GLM-5.3-Flash EXL3 4bpw 首次基线（2026-09-19）

2026-09-19 主力栈从 Qwen3.8-Flash-Next 换成 GLM-5.3-Flash EXL3（上游
MiaAI-Lab 配方，**docker 部署,不在 k3s 里**）。这是换栈当天的第一份基线。

**一句话结论:吞吐全面达标甚至超过上游,墙在主机内存。**

- decode / 并发 / prefill 三项都**达到或超过**上游 README 公布的数字
- 启动不变量与上游**逐字匹配**（权重 82.05 GiB、KV 池 883,552 token、1.04×）
- ⚠️ 但主机 headroom 只有 2.1–2.5 GiB，上游同配置称 "~5 GiB"
- ⚠️ **配置里的 850K 上下文是名义值**:单条冷 prompt 实测上限约 **180–220K**

---

## 被测配置

| | |
|---|---|
| 上游 repo | `MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks` @ `8f29c6dd` |
| 镜像 | `ghcr.nju.edu.cn/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3-instanttensor`<br>ImageID `ef9f5013…`（已核与 ghcr.io 上游逐字节相同） |
| 权重 | `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw` @ `25a44fdb…`，120 分片（逐文件字节核对过） |
| 引擎参数 | TP=2 / nnodes=2 / mp / `exl3` / kv `fp8` / MNBT 7168 / **MAX_NUM_SEQS=4** |
| 内存 | `GPU_MEM_UTIL=0.84` + `--kv-cache-memory-bytes 15032385536`(14 GiB) + `LOAD_FORMAT=`(关 InstantTensor) |
| 上下文 | `MAX_MODEL_LEN=850000`，KV 池 883,552 token，1.04× |
| 投机 | DFlash2 k=7，draft TP=2 |
| MoE | E3 grouped（`effective_tier=grouped`），`GLM53_INDEXER_WORKSPACE=rightsize` |
| 未启用 | `GLM53_ADAPTIVE_K`、`GLM53_DENSE_FP8`、cooperative MoE overlay、ABLIT（**全部上游默认关**） |
| 时钟 | 2200 MHz 上限**生效**（`make clock-cap-verify` 实测:rank0 2178 / rank1 2185，n=60，负载期采样） |

主机侧（测试期间）:图形会话、sparkDash 已停;**k3s 两节点均已停**（并发档之后）。

完整配方与全部决策账:`config/glm53-flash-exl3.yaml`。

---

## 方法与三个必须说明的差异

所有请求 `temperature=0`、**非流式**、token 数取服务端 `usage`
（流式数的是 step 不是 token —— `docs/benchmarking-cn.md` 陷阱 #1）。

1. ⚠️ **本栈没有"关闭 thinking"。** 上游那张 decode 表写的是 "thinking off"，
   但这个 chat template 上**不存在**等价物:不传 `reasoning_effort` 渲染成
   **Max**，可选值只有 `low`/`high`/`max`（`medium` 被模板拒绝）。
   本基线一律用 **`chat_template_kwargs.reasoning_effort=low`**，即最低档。
   **所以与上游"thinking off"不是严格同条件。**
2. ⚠️ **prompt 是上游描述的近似复刻**，不是同一份（上游用 sparkDash 内置集）。
3. ⚠️ **prefill 必须用唯一 nonce 开头。** `--enable-prefix-caching` 开着，
   重复 prompt 会命中缓存测出假的快。本基线每发在**最前面**插 uuid，
   实测 `cached_tokens=0` 全程成立。

---

## 1. Decode（单流，warm，400 token）

`glm53-bench.sh`，3 次 warmup + 3 次计时，取 best。

| 内容 | 我们 best | 上游对照 |
|---|---:|---|
| structured（数数 1→200） | **64.3** | README decode 表 ×1 **62.9** |
| code（50 个 clamp 函数） | **38.8** | README ladder 正文 "code ~35–44 solo" ✅ 落在区间内 |
| prose（讲解 hash map） | **24.6** | 第二台 kit "prose 27.1"；36.1 是**开了** adaptive-k+dense-FP8+coop 的数 |

三次原始值:structured 62.1/63.2/64.3，code 36.8/38.8/35.7，prose 24.6/23.6/23.4。

> **structured 64.3 > 上游 lab kit 的 62.9 → 本 kit 不在上游 issue #163 的慢路径上。**
> #163（仍 open）报告同样走 PYNCCL 跨节点 all-reduce 的一台 decode 慢 ~2×
> （structured 31.0 vs 65.1）。我们的启动日志同样显示
> `Using ['PYNCCL'] all-reduce backends`，但**没有**复现那个 2×。
> 即 PYNCCL fallback 本身不是 #163 的成因（上游 lab 也是双机，也必然走 PYNCCL）。

## 2. 并发梯度（structured，各 400 token）

`glm53-conc.sh`。引擎上限 `MAX_NUM_SEQS=4`。

| 并发 | 聚合 tok/s | 单流 tok/s | 完成 | 内存最低 | 上游对照 |
|---|---:|---:|---:|---:|---|
| c1 | 62.5 | 62.5 | 1/1 | 2444 MiB | 62.9 |
| c2 | **112.0** | 56.0 | 2/2 | 2474 MiB | 103.3 → **+8.4%** |
| c3 | 144.9 | 48.3 | 3/3 | 2521 MiB | （上游未发布） |
| **c4** | **179.8** | 44.9 | 4/4 | 2495 MiB | 146.5 → **+22.7%** |

> **并发不吃主机内存。** 整个梯度里 MemAvailable 在 2444–2521 MiB 之间，
> 最低点甚至高于起始值。KV 池是预留死的 14 GiB，`max_num_batched_tokens=7168`
> 又卡住了激活内存。**威胁节点的不是并发,是长 prefill（见下）。**

⚠️ 上下文长度会吃并发:引擎自报 *"Maximum concurrency for 850,000 tokens
per request: **1.04x**"*，即满长请求只放得下 1 条。883,552 token 的池四条平分
→ c4 时每条约 ≤220K。

## 3. Prefill（TTFT 法，`max_tokens=1`，cold）

`glm53-prefill.sh`，带**飞行中**内存熔断（击穿 450 MiB 即杀掉该请求）。

| 目标 | 实际 tok | TTFT | prefill tok/s | 内存最低 | 缓存命中 | 上游同档 |
|---|---:|---:|---:|---:|---:|---|
| 8K | 11,195 | 7.06s | 1586 | 2473 MiB | 0 | 8k: 1492 |
| 16K（**首发·新形状**） | 22,345 | 19.59s | *1141* | 1662 MiB | 0 | — |
| 16K（暖） | 22,347 | 13.71s | **1630** | 1945 MiB | 0 | 16k: 1554 |
| 16K（暖） | 22,345 | 13.74s | 1626 | 2042 MiB | 0 | |
| 32K | 44,651 | 27.14s | **1645** | 2011 MiB | 0 | 32k: 1428 |
| 32K | 44,647 | 27.13s | 1646 | 2008 MiB | 0 | |
| 64K | 89,255 | 54.00s | **1653** | 1945 MiB | 0 | 64k: 1587 |
| 64K | 89,251 | 54.09s | 1650 | 1817 MiB | 0 | |
| **128K** | **178,468** | 109.69s | **1627** | **1042 MiB** | 0 | 128k: 1562 |

**256K 未测** —— 按下面的内存趋势它会击穿熔断线，而这两台没有 BMC，
赔率不划算。上游报告过 256k prefill 在 zero MemAvailable 下 **crash 掉 head**。

### 3a. 首发假象（本仓库 benchmarking 陷阱 #2 的又一实例）

22K 那档首发 **1141 tok/s**，重发 **1630 / 1626** —— 差 43%。
首发同时付了一次性的形状分配（MemAvailable 2568 → 1662 且不回弹），
之后该形状免费。上游自己的 A/B 表里也有这行:
*"~8k (first request after boot) … 999 … one-time allocation; warm ~1,500"*。
**任何 prefill 数字都必须说明是首发还是暖的。**

### 3b. 内存是超线性的 ← 本次最重要的发现

| prompt | 瞬时内存消耗 |
|---|---:|
| 89K | ~0.2 GiB |
| **178K** | **~1.4 GiB**（2435 → 最低 1042） |

吞吐从 22K 到 178K 平得像一条线（1627–1653），**内存却在加速**。

> ⚠️ **实际影响:`MAX_MODEL_LEN=850000` 是名义值,不是可达值。**
> 单条冷 prompt 在本 kit 上的实测上限约 **180–220K**。KV 池有 883K token
> 的容量,但没法用一次冷 prefill 填进去。需要长上下文时,得靠多轮累积
> + prefix caching 渐进逼近,不能一次投喂。

---

## 4. 与上游对不上的那一项:主机 headroom

| | 上游 issue #193 / README | 我们 |
|---|---|---|
| Model loading | 82.05 GiB | 82.05 GiB ✅ |
| KV 池 | 883,552 tokens | 883,552 ✅ |
| 并发 @850K | 1.04× | 1.04× ✅ |
| Initial free memory | 110.12 GiB | **107.64 GiB** |
| 主机 headroom（空载） | README 称 "~5 GiB free" | **2.1–2.5 GiB (1.8–2.0%)** |

差异**不是** docker/k3s 造成的 —— 实测完全停掉 k3s 只给 head **+0.11 GiB**
（S2 +0.61）。原因是 head 上多跑的东西:S1 全部非 vLLM 进程 2.79 GiB，
其中 `zcode` 系列 ~1.07 GiB、桌面 ~0.4 GiB;另外 head 天生比 worker 重
1.71 GiB（API server / tokenizer / 多模态处理器缓存）。

上游 README 对这个区间的原话:
> *"15 GiB buys 1.11x but measured only **0.8-2.2 GiB free under load, which is
> not enough margin on this UMA**."*

⚠️ **此状态下 `make memwatch` 启不了**（1.8% < CRIT 5%，启动即触发），
即当前**没有 OOM 防线**，而这两台没有 BMC。
上下文与 headroom 是 1:1 换的（KV 上限每降 1 GiB，主机多 1 GiB）:

| max_model_len | KV 上限 | S1 headroom | memwatch |
|---:|---:|---:|---|
| **850K（当前）** | 14.0 GiB | 2.1 GiB (1.8%) | ❌ |
| 700K | 11.1 GiB | ~5.0 GiB (4.1%) | ❌ 勉强 |
| 600K | 9.5 GiB | ~6.6 GiB (5.4%) | ✅ |

---

## 复现

三个脚本都在本目录，都带内存熔断，都只读集群。在 **S1 上**跑（打 localhost，
避免 Tailscale RTT 污染 TTFT 那一格）:

```bash
scp scripts/glm53-*.sh admin@100.97.87.120:/tmp/
ssh admin@100.97.87.120 'bash /tmp/glm53-bench.sh'                    # decode
ssh admin@100.97.87.120 'bash /tmp/glm53-conc.sh'                     # 并发 c1..c4
ssh admin@100.97.87.120 'LEVELS="8000 16000 32000" bash /tmp/glm53-prefill.sh'
```

⚠️ **别直接用 `benchmarks/bench-full-2026-08-05/bench_full.py` 测本栈** ——
它硬编码的是 V4-Flash 的 model 名和 `thinking` kwarg，对 GLM 是第三套语义
（`chat_template_kwargs.reasoning_effort`，CoT 在 `reasoning` 字段，且无法关闭），
照跑会**静默**测错。见 `docs/stack-switch-cn.md` 第 2 层。

原始输出:`raw-2026-09-19.log`。

## 还欠的

- **质量未验**。EXL3 4bpw 的 KLD 0.0246（≈ 官方 FP8 的 0.0246）是
  malaiwah 的独立 teacher-logit panel，**不是本仓库测的**。
  aider-polyglot 对 GLM 未跑。V4-Flash 基线:
  `../aider-polyglot-deepseek-v4-flash-2026-08-01/`（pass_rate_2 82.4%）。
  注:Flash-Next 的质量闸门也一直没关 —— 这笔债现在有两份。
- 256K prefill 未测（见上，有意不测）。
- 长上下文下的 decode 未测（本基线全是短 prompt 的 decode）。
