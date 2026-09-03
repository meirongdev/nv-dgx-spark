# 换栈基准闸门 — Qwen3.8-Flash-Next NVFP4 vs DeepSeek-V4-Flash（2026-09-03）

2026-09-02 主力栈从 DeepSeek-V4-Flash 换成 Qwen3.8-Flash-Next NVFP4，这是当初
方案里定的**唯一决策点**：速度掉太多就回滚。

**结论:速度这一半通过。** 均值 −12.8%，但**真实代码任务基本打平**，并发和
prefill 明显更强。质量那一半(aider-polyglot)另行记录。

## 方法

同一份 harness (`../bench-full-2026-08-05/bench_full.py`)、同一批 prompt、
同样 warm / temp 0 / `stream:false` / **best-of-2**，在 S1 上打 `localhost:8000`
(避免 Tailscale RTT 污染 prefill 那一格)。

```bash
URL=http://localhost:8000/v1 MODEL=qwen38-flash-next \
THINK_KEY=enable_thinking THINKING=0 TAG=qwen38fn-2026-09-02 \
python3 bench_full.py
```

> ⚠️ **`THINK_KEY=enable_thinking` 是这次对照能成立的前提。** harness 原先把
> kwarg 名硬编码成 `"thinking"`，那是 V4-Flash 的名字；在本栈上它**静默无效**
> (实测 `{"thinking":false}` → reasoning_tokens 40，`{"enable_thinking":false}`
> → 0)。照原样跑测到的是「带完整 CoT」的 tok/s，与 2026-08-05 那份「已关
> thinking」的基线根本不可比，而且不会有任何报错提示你。见 commit c96fcf3。

引擎配置差异(有意为之，非对照噪声)：V4-Flash `gmu 0.80` / fp8 KV；
Flash-Next `gmu 0.75` / bf16 KV / `--enforce-eager`。**Flash-Next 是在更小的
KV 池(20.9 vs ~27 GiB)上取得下面这些数的** —— 0.75 的实测依据见
`config/qwen38-flash-next.yaml` 与 `scripts/mem-floor.sh`。

## Decode（按内容，tok/s）

| prompt | V4-Flash | Flash-Next | Δ |
|---|---:|---:|---:|
| count300（数数） | 84.3 | 65.7 | −22.1% |
| mult12（乘法表） | 78.6 | 64.7 | −17.7% |
| json60（JSON） | 78.0 | 65.4 | −16.2% |
| **bst（真实代码）** | 63.8 | **62.1** | **−2.7%** |
| **story（散文）** | 31.4 | **35.3** | **+12.4%** |
| **peak / mean** | 84.3 / 67.2 | 65.7 / **58.6** | −22.1% / **−12.8%** |

**方差塌缩是这次最重要的观察。** V4-Flash 跨内容散布 31.4→84.3（2.7×），因为
DSpark 的投机接受率完全由内容驱动；Flash-Next 是 35.3→65.7，其中四项挤在 62–66。

于是 V4 的优势**全部集中在高度重复的合成内容上**（数数/乘法表/JSON —— 投机
几乎百发百中）。真实代码生成打平，散文反而更快。那个 −12.8% 的均值主要由三个
不代表真实工作负载的 prompt 拉低 —— **别用它单独判断日常体感**。

## 并发（同一 prompt，各 400 token）

| | V4-Flash | Flash-Next | Δ |
|---|---:|---:|---:|
| c1 聚合 | 67 | 60 | −10.4% |
| c2 | 113 | 111 | −1.8% |
| **c4** | 143 | **179** | **+25.2%** |
| **c6** | 186 | **240** | **+29.0%** |

单流略慢，但**并发越高越占优**。`max_num_seqs=8` 下这条比单流数字更贴近多客户端实际。

### 补测：c6 以上直到闸门（2026-09-03）

上表止于 c6，而引擎上限是 `max_num_seqs=8` —— 峰值没测到。补测（同 prompt、
同参数、warm、best-of-2，在 S1 上打 localhost）：

| 并发 | 聚合 tok/s | 单流 tok/s | 墙钟（各 400 tok） |
|---:|---:|---:|---:|
| c1 | 61 | 60.7 | 6.6s |
| c6 | 252 | 42.3 | 9.5s |
| **c8** | **304** ← 峰值 | 38.6 | 10.5s |
| c10 | 221 | 33.7 | 18.1s |
| c12 | 251 | 32.6 | 19.1s |
| c16 | 295 | 28.4 | 21.7s |

**峰值 ~304 tok/s 聚合 @ c8，单流仍有 38.6 tok/s。**

- **卡吞吐的是 `max_num_seqs=8`，不是显存。** c8 满载时 `GPU KV cache usage`
  只有 **14.6%**（gmu 0.75 / 20.9 GiB 池）；c16 时引擎日志明确是
  `Running: 8 reqs, Waiting: 8 reqs`。超过 8 就排队，聚合不再涨，只有延迟翻倍。
- **c10 那个 221 是批次凑不整的产物**，不是拐点：8 + 落单的 2，尾批以极低批
  效率跑完。c16 是两波满 8，聚合又回到 295。
- 时钟上限 2200MHz 在测的时候是**生效**的（`clock-cap-verify` 复验：双机
  2171/2190，n=20）。⚠️ 注意 `docs/gb10-tuning-cn.md` 的 A/B **只覆盖单流
  decode 和 prefill**，并发档从未做过 A/B —— c8 批次更大、算术强度更高，
  「几乎不要钱」这个结论在并发上是**外推，不是实测**。

> ⚠️ 想抬 `max_num_seqs` 之前先跑 `scripts/mem-floor.sh`：gmu 0.80 时 8 路 × 8K
> prompt 已经把 S1 可用内存压到 5Gi（4.1%，低于 memwatch CRIT）。抬并发会同时
> 抬激活内存，而这两台没有 BMC，OOM 会冻住 sshd。

## Prefill（TTFT 法，1 个输出 token）

| | V4-Flash | Flash-Next | Δ |
|---|---:|---:|---:|
| 8K | 1760 | **3198** | **+81.7%** |
| 32K | 2203 | **3192** | **+44.9%** |
| **100K** | 2084 | **4161** | **+99.7%** |

100K prefill **翻倍** —— 读大文件、整仓分析这类长上下文任务的首字延迟直接砍半。

## 闸门判定

当初判据:`content-matched decode ≥ 45 tok/s` 且 aider-polyglot 在噪声内。

- ✅ 速度:均值 58.6、代码任务 62.1，均远超 45
- ⏳ 质量:aider-polyglot 待测。RadixArk 的 NVFP4 是**无校准 RTN 权重量化**，
  GSM8K/AIME 分数是量化方自报的，本仓库尚未独立验证。基线见
  `../aider-polyglot-deepseek-v4-flash-2026-08-01/`（pass_rate_2 82.4% diff /
  88.2% whole，格式合规 100%）。

原始输出:`bench-qwen38fn-2026-09-03.log`。
