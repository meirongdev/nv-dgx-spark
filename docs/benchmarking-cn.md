# 吞吐测量方法学(报 tok/s 之前先读这个)

> 从 `CLAUDE.md` 拆出(2026-08-15)。**这一页的三个陷阱都曾在本 repo 自己的文档里
> 产出过错误数字**——"~56 tok/s"和"6 路聚合 ~50"都是测法artifact,不是真实性能。

## 核心:单个 tok/s 数字是没有意义的

DSpark 的解码速度 = `steps/s × 每步接受的 token 数`,而**接受率是内容驱动的**。
所以单个 prompt 的 tok/s 描述的是**那个 prompt**,和描述集群一样多。

同一套配置、同一台服务器,2026-08-05 实测:
**31 tok/s(散文)→ 84 tok/s(数到 300)**,均值 67。

**报数字时要给区间,并说明 prompt 是什么。**

## 当前基线

`benchmarks/bench-full-2026-08-05/`(warm、temp 0、`stream:false`、thinking off):

| 轴 | 实测 |
|---|---|
| decode 峰值 / 均值 | 84.3 / 67.2 tok/s |
| 聚合 c1 / c2 / c4 / c6 | 67 / 113 / 143 / 186 tok/s(c6 时每流 33.5) |
| prefill 8K / 32K / 100K | 1760 / 2203 / 2084 tok/s(3 次中位数,±2%) |
| DSpark 接受率 | 75.8%,4.79 tok/step(p0..p4 = .90/.81/.74/.68/.65) |

降级栈 Qwen3.8-27B 的对照数字见 `docs/qwen38-27b-fallback-cn.md` §2.2
(均值 24.9 tok/s,MTP 2.75 tok/step)——**稠密 27B 比 MoE A13B 慢 2.7 倍**,
这是本集群最反直觉的一条结论。

## 三个陷阱

### 1. 流式计数会按接受长度低报

投机解码下 vLLM **每个 decode *step* 最多发一个 SSE chunk**,而这个 chunk 里
携带了该步接受的**全部** token。所以数 stream delta 测到的是 **steps/s**
——同一个请求上 ~14 vs ~60,差 4 倍多。

**正确做法**:用 `stream:false`,读 `usage.completion_tokens` 除以墙钟时间
(`scripts/v4-test.sh` 就是这么做的);或者用服务端的
`vllm:generation_tokens_total` 除以墙钟时间。

### 2. 冷启动**和空闲**衰减约 30%

(重)启动后的头几个请求——**或者空闲约 30 分钟之后**——会慢约 30%,
而且**日志里什么都不会说**。这是叠加在一次性 Triton JIT 尖峰之上的另一回事。

短请求清不掉这个状态,需要**几个 500+ token 的生成**才能回到稳态。
**绝不要在闲置之后立刻开始压测。**

### 3. 短回复被固定开销压住

每请求约 0.5 秒的固定开销意味着:**130 token 的回复无论多可预测都跑不出高 tok/s**。
用 **500–1400 token** 的生成来测。

## 接受率可以在线观测

不需要额外埋点:

```bash
curl -s localhost:8000/metrics | grep spec_decode
```

在一个请求前后各取一次快照做差值即可;`benchmarks/bench-full-2026-08-05/accept_diff.py`
会替你做这个算术。

---

## 已否决:论坛的 "0731 DSpark 1M NVFP4 KV" 配方(2026-08-05)

**用它自己的测试工具做了正面对比:我们这套在除 100K prefill 外的每一个轴上
都持平或更好——不要在它上面重建。**

- 它的 "NVFP4 KV" **省不下任何内存**:Stage C 的 `nvfp4_ds_mla` 仍保留 DeepSeek
  的 584 字节信封——**它 7,606 B/tok vs 我们 fp8 的 7,424 B/tok**。
- 它宣称的 "B12X ≈ 2×" 是拿它自己 base image 的 fallback 当分母测的。
- 采用它意味着冻结在 vLLM 0.21.1 + 约 15 个手工维护的 overlay 文件。

逐条分析见 `benchmarks/bench-full-2026-08-05/README.md`。

**两条留给未来的判据:**

- **NVFP4 KV 仍是观察项** —— 否决的是*这个配方*,不是 4-bit sparse-MLA KV 本身。
  判断任何未来方案就看启动日志里的 **B/tok:低于约 6,000 是真的,
  7,4xx–7,6xx 是那个填充出来的假货。** 不紧急(在 `max_num_seqs=6` 下
  我们也用不上省出来的内存)。
- **它唯一真实的领先是 100K prefill(2639 vs 2084,+27%),而且没有免费手段能追平。**
  `--async-scheduling` 在我们这边**已经自动启用**(每次启动都记在日志里),
  加这个 flag 是空操作;它的 `VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256` 比我们的
  默认值更紧。差距的可能来源是它那个 B12X MXFP4 MoE kernel,而那东西和它
  冻结的 runtime 焊死在一起。
