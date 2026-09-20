# fndgx 基准 —— Qwen3.8-Flash-Next NVFP4 单机(PLE mmap),2026-09-20

栈:`stacks/fndgx`(S2 `100.67.164.92:18300`,served name `qwen3.8-flash-next`)
配方:`native` profile —— `MODE=hybrid` / `CTX=262144` / `YARN=0` / `MTP=2` /
`GPU_MEM=0.80` / **`SEQS=8`** / `DET_TOPK=1` / `DRAFT_VOCAB=1`
checkpoint:`RadixArk/Qwen3.8-Flash-Next-NVFP4`(NVIDIA 那份从节点上下不到)
硬件:一台 DGX Spark(GB10)
并跑:S1 的主力栈 `qwen38un` 全程在跑(不同机器,不共享 GPU)

⚠️ **本目录每张表都有「限频 / 解锁」两列。** 2026-09-20 当天先在 2200 MHz 时钟
上限下测了一轮,随后应要求把两台的 `gb10-clock-cap.service` 都卸掉(不是 `reset`
—— 那个只解当前锁,单元还 enabled,重启会加回来),又测了一轮。
负载下实测频率:**限频 2184 MHz → 解锁 mean 2490 / max 2528**(约 +14%)。
⚠️ 两轮是**前后测,不是交错配对测**。2026-08-25 那次是 n=11 交错才敢下结论,
因为效应量和噪声差不多。这里 decode 的差(+1.5~1.7%)**不构成结论**;
prefill 和 c4 的差大得多,可信度高一些,但仍非配对测。

⚠️ 先读 `docs/benchmarking-cn.md`。本目录的三个脚本都按它的三条避坑写:
非流式、先热身、回答够长。

脚本:`decode.sh`(单流)、`prefill.sh`、`concurrency.py`(并发梯子)、
`probe-think.sh`(思考语义)。都在 S2 本机跑,不经 Tailscale。

---

## 1. 单流解码

非流式、`temperature=0`、`enable_thinking=false`、`max_tokens=700`,
每项 3 次取热身后中位。

| 内容 | 解锁(当前) | 限频 | 差 | 参考:500K+YaRN 限频 |
|---|---|---|---|---|
| 代码(红黑树完整实现) | **48.0** tok/s | 47.2 | +1.7% | 46.5 |
| 结构化 JSON(40 条状态码) | **46.6** | 45.9 | +1.5% | 46.5 |
| 散文(600 词) | **35.3** | 34.7 | +1.7% | 35.7 |

**对上游:** 上游给 RadixArk 的基准是「单流 greedy **散文** 37.1 tok/s」。
我们解锁后 35.3,**−4.9%**(限频时 −6.5%)。**算相符** —— 不同机型
(DGX Spark vs ASUS GX10)、不同日子、不同 harness,5% 之内。

解锁带来的 +1.5~1.7% 与本仓库 2026-08-25 记的「decode 配对差 +0.9%,
95% CI [−1.9%, +3.7%]」一致 —— 都是**测不出**的量级,别当成收益。

---

## 2. Prefill

每条 prompt 内容都不同(随机词流),所以前缀缓存**永远打不中**;
`max_tokens=1`,耗时≈prefill;第 1 条热身丢掉,后 3 条取中位。

| prompt 长度 | 解锁(当前) | 限频 | 差 | 上游(GX10,热) |
|---|---|---|---|---|
| ~13.0K | **2,385** tok/s | 2,297 | +3.8% | 8K: 2,400–2,900 |
| ~51.7K | **3,050** tok/s | 2,810 | +8.5% | 32K: 2,500–3,000 |

解锁后 51.7K 这个点 **3,050 已经高于上游 32K 区间的上沿**,而且我们的 prompt
长 60%。13.0K 那个点 2,385 贴着上游 8K 区间的下沿,同样 prompt 长 60%。**相符或更好。**

prefill 的增益(+3.8% / +8.5%)比 decode 大得多,与本仓库记的「时钟上限对
prefill −3.7%」方向一致,长 prompt 上还更明显。

前缀缓存(上游 `smoke-test.sh`):同一 prompt 第二次 7.20 s → **1.20 s**,
两次首 token logprobs 完全一致(`QSADET active`,确定性内核生效)。

⚠️ **本目录最初写错过一次**:引用了 `smoke-test.sh` 的 1,482 tok/s 去对比上游的
2,400–2,900,判成「差一半,原因不明」。那是**冷的、且是该 prompt 形状的第一次**,
而上游那张表是热的。1,482 × 1.43 ≈ 2,120,与重测的 2,297 吻合。
**更强的佐证**:上游另有一行**冷** prefill 数据 ——「RadixArk 8k / 32k (cold):
5.1 s / 10.6 s」= 1,569 / 3,019 tok/s。我们那个冷数字 1,482 @10.6K 正落在
它 8K 冷(1,569)附近。**也就是说冷对冷本来就是相符的,错的是拿冷去比热。**

---

## 3. 并发梯子 ★

每个并发位用**不同**的 prompt(8 道题轮转,带 `[req N]` 前缀),`max_tokens=400`,
`enable_thinking=false`。`aggregate = 该轮 completion_tokens 之和 / 该轮墙钟`。

| 并发 | 聚合(解锁) | 每流(解锁) | 聚合(限频) | 每流(限频) | 延迟 中位/最慢(解锁) |
|---:|---:|---:|---:|---:|---|
| 1 | 44.5 | 44.5 | 44.1 | 44.1 | 3.7 s / 3.7 s |
| 2 | 67.8 | 33.9 | 66.6 | 33.3 | 9.2 s / 9.9 s |
| 4 | 92.1 | **23.0** | 83.8 | 21.0 | 14.3 s / 14.9 s |
| 6 | 93.8 | 15.6 | 96.9 | 16.1 | 14.9 s / 19.1 s |
| **8** | **112.4** | 14.1 | 111.1 | 13.9 | 20.6 s / 24.0 s |
| 12 | 111.1 | 9.3 | 106.7 | 8.9 | 22.8 s / 36.9 s |
| 16 | 113.1 | 7.1 | 111.3 | 7.0 | 27.7 s / 43.8 s |

### 结论一:c4 现在**反超**上游

上游给 RadixArk 的唯一并发数据点是「**4 concurrent agents,每流 21.6 tok/s**」。

| | 每流 tok/s | vs 上游 |
|---|---|---|
| 上游 RadixArk | 21.6 | — |
| 我们(限频) | 21.0 | −2.8% |
| 我们(解锁) | **23.0** | **+6.5%** |

限频时是"在噪声内相符",解锁后是"超过"。c4 是这条梯子上解锁收益最大的一格
(+9.5%),合理:c4 时 prefill 占比仍高,而时钟上限对 prefill 的影响最大。

### 结论二:c8 之后完全平掉,而这是 `SEQS=8` 在封顶,不是硬件饱和

c8 = 112.4,c12 = 111.1,c16 = 113.1 —— 聚合**不再增长**,只有延迟在涨
(最慢 24.0 s → 43.8 s)。限频那一轮同形(111.1 / 106.7 / 111.3)。这正是 `max_num_seqs=8` 的形状:第 9 个请求开始排队。

⚠️ 上游 README 把这件事写成一条明确的警告:
> **A low `--max-num-seqs` is indistinguishable from saturation if you only look
> at tok/s.** With `--max-num-seqs 2` their sweep flatlined at ~33 tok/s while
> `vllm:request_queue_time_seconds_sum` climbed to 142 s. Check `max-num-seqs`
> before quoting an aggregate number — this repo's default is now `8` for that reason.

所以 **113 tok/s 不是这台机器的并发上限**,是这份配置的上限。
解锁时钟只把它从 111.1 推到 112.4(+1.2%)—— **封顶的不是频率,是 SEQS**。
上游引的 @jschmied 实测(不同配置:无投机解码、用 vLLM 原生 PLE CPU offload、8K 上下文)
显示聚合一路涨到 **c48 = 266.8 tok/s**,而且**每 token 的缺页代价从 c1 到 c48 降了 4.4 倍**
——「分页的表是并发的**理由**,不是负担」。

⏳ **`SEQS` 没有调过。** 本栈 KV 池 496,770 tokens,而这一轮每个请求也就约 1K token,
32 路并发只占 32K,池子绰绰有余。提 `SEQS` 大概率能把聚合再往上推一大截 ——
但会放大上游记的另一个问题(并发 prefill 期间解码被饿住,对策是
`--long-prefill-token-threshold 1024` 或降 `SEQS`),而且要重测。**是个待办,不是结论。**

### 结论三:与 qwen38fn(同一模型,TP=2 两台机器)差 2.7 倍

本仓库给 `qwen38fn` 记的是 **~304 tok/s @ c8**(同样 `max_num_seqs=8`)。
我们解锁后 112.4。两台变一台只能解释 2 倍,**剩下的 0.7 倍没有解释** ——
候选是 PLE 表走 mmap 在批处理下的缺页代价(qwen38fn 把表放在显存里,另带 FP8 补丁)。

⚠️⚠️ **但这两个数不是同一套 harness 量的**(题目、输出长度、并发发起方式都可能不同),
**不能当排名用**。要真比,必须停掉本栈、起 qwen38fn、用本目录的
`concurrency.py` 再跑一遍。**没做**,因为那要占掉 S2 并让本栈下线 8-11 分钟。

### 一条读数提醒

c1 的 44.5 tok/s 别单独引用:那一轮只生成了 166 token(第一道题答得短),
**短回答被开销压顶**(`docs/benchmarking-cn.md` 的三个坑之一)。
单流要看 §1 那张表 —— 它强制 700 token。

---

## 4. 启动期指标

| | 500K + YaRN | 262144 native |
|---|---|---|
| Available KV cache memory | 13.54 GiB | **14.03 GiB** |
| GPU KV cache size | 500,000 tok | **496,770 tok** |
| Maximum concurrency | 1.00x | **1.90x** |
| 主机稳态可用内存 | 10.7% | **12.9%** |

`Actual usage is 81.85 GiB for consumed memory (weights + non-torch),
1.47 GiB for peak activation, 0.48 GiB for CUDAGraph`(预算 97.35 GiB = 0.80 × 121.69)

**降上下文换不来 KV 池**:池子由「权重+激活之后还剩多少显存」决定,不是由
`max-model-len` 决定。变的只有 concurrency 比值。

**KV 池 vs 上游 —— 两个要分开的缺口:**

| | KV 池 @500k, GPU_MEM=0.80 | 权重 |
|---|---|---|
| 上游 NVIDIA | 679K | 74.9 GiB |
| 上游 RadixArk | **589K** | 77.3 GiB |
| 我们(RadixArk) | **500K** | 81.85 GiB(含 non-torch) |

- **679K → 589K 是 RadixArk 自己的已知代价**,启动日志直接点名:
  `modelopt block-moe: experts mtp.layers.48.mlp.experts -> **checkpoint algo None**`
  —— MTP 草稿专家是 bf16,NVIDIA 那份量化了它们。上游标价「~3.4 GB less on the card」
  「+22% KV」。两条修法(换 checkpoint / `prepare-mtp-graft.sh`)都要过
  huggingface.co,从节点上走不通。
- **589K → 500K 是我们自己的,仍未解释。** 最可能的机制(**未验证**):`GPU_MEM`
  是**总**显存的比例而非空闲的比例(上游 serve.sh 原话),而我们启动时
  `Free memory on device (113.24/121.69 GiB)` —— 已有 8.45 GiB 被 k3s server /
  Cilium / 桌面 / node-exporter 占着。⚠️ 别当结论:glm53 那次把 k3s **整个停掉
  只换回 0.11 GiB**。要查就是停 k3s → 重启 → 读 `Available KV cache memory`。

⚠️ **不要照做的诱惑**:同一行日志说 `--kv-cache-memory=…` 给到 29.29 GiB 就能
「fully utilize gpu memory」。GB10 上显存和主机内存是同一池,剩下那部分正是
mmap 的 48 GiB PLE 表要用的页缓存 —— 上游原话「claiming it trades prefill for KV」。
主机可用内存现在只有约 13%。

---

## 5. 一句话总结

**解除时钟上限后,上游公布的每一项 RadixArk 基准我们都相符或更好:单流散文
−4.9%、4 路并发每流 **+6.5%**、prefill 在更长的 prompt 上高于上游区间上沿。
聚合吞吐在 c8 封顶于 113 tok/s —— 封顶的是 `SEQS=8` 这个配置,不是这台机器
(解锁时钟只推动了 +1.2%)。唯一没对上的仍是 KV 池:比上游 RadixArk 基准低 15%,
原因未查。**

| 轴 | 上游 RadixArk | 我们(解锁) | 判定 |
|---|---|---|---|
| 单流 greedy 散文 | 37.1 tok/s | 35.3 | −4.9% ✅ |
| 4 并发 每流 | 21.6 tok/s | **23.0** | **+6.5%** ✅ |
| prefill ~32K | 2,500–3,000 | **3,050 @51.7K** | 超出上沿 ✅ |
| prefill ~8K | 2,400–3,000 | 2,385 @13.0K | 贴下沿,prompt 长 60% ✅ |
| 确定性 | yes | yes | ✅ |
| KV 池 @GPU_MEM=0.80 | 589K tok | 500K tok | **−15% ❌ 未解释** |
