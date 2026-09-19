# Qwen3.8-27B-Uncensored + SGLang + DFlash2 基线（2026-09-19）

2026-09-19 当天第二次换栈：GLM-5.3-Flash EXL3 → Qwen3.8-27B-Uncensored NVFP4，
引擎从 vLLM+EXL3 overlay 换成 **SGLang**，**并且从双节点变成单节点**。

**一句话结论：并发是本仓库有史以来最强，单流代码比 GLM 快但没到 Flash-Next。**

- 并发峰值 **472.7 tok/s @ c12，只用一台机器**（Flash-Next 304 用两台，GLM 179.8 用两台）
- 单流代码 45.4 tok/s：比 GLM 的 38.8 **快 17%**，比 Flash-Next 的 62.1 **慢 27%**
- ⚠️ 比上游自己的同配方数字**低 17%**（54.6），有假说但未证实
- ✅ 主机 headroom **17.4 GiB (14.3%)** 开机 / ~11% 稳态（`mem-fraction 0.80`），**memwatch 常驻中**

---

## 被测配置

见 `stacks/qwen38un/recipe.yaml`（含四个上线时踩的坑）。要点：

| | |
|---|---|
| 上游 | `MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark` @ `9fb18ed`（MIT） |
| 权重 | `orcarouter/Qwen3.8-27B-Uncensored-NVFP4` @ `96d4d0b6`，23.02 GiB / 6 分片 / compressed-tensors |
| 草稿 | `z-lab/Qwen3.8-27B-DFlash2` @ `50307d4c`，3.58 GiB |
| 镜像 | `lmsysorg/sglang:nightly-cu134-20260909-708f51e`（digest `00205b89…`，arm64） |
| 引擎 | SGLang，`--speculative-algorithm DFLASH`，8 个草稿 token |
| 节点 | **1 台（S1）**。S2 全程空闲（116 GiB 可用） |
| 内存 | `--mem-fraction-static` **0.80**（本仓库值；0.85 试过被漂移击穿，上游 0.90，0.95 是硬重启红线） |
| 上下文 | 262144；`.env` 里 `MAX_CONCURRENT_REQUESTS=16`，但 0.85 下 SGLang 按内存自动降到 **`max_running_requests=12`** |
| 时钟 | 2200 MHz 上限生效（本机 `clock-cap-verify` 当天复验：rank0 2178 / rank1 2185） |

主机侧：图形会话与 sparkDash 停着；k3s 已恢复（四个 k3s deployment 均 0 副本）。

## 方法

`temperature=0`、**非流式**、token 数取服务端 `usage`（流式数的是 step，
`docs/benchmarking-cn.md` 陷阱 #1）。三个脚本在本目录，与
`benchmarks/glm53-2026-09-19/` 的同名脚本**同一套方法**，只换模型名和思考 kwarg。

⚠️ **本栈是第五套思考语义**，而且是 GLM 之后第一个**能真正关掉 thinking** 的：

| 栈 | 关思考 | CoT 字段 |
|---|---|---|
| V4-Flash | `thinking:false` | `reasoning_content` |
| Flash-Next | `enable_thinking:false` | `reasoning_content` |
| GLM-5.3 EXL3 | **关不掉**（最低 `reasoning_effort:low`） | **`reasoning`** |
| **本栈** | **`enable_thinking:false`** ✅ | `reasoning_content` |

所以本基线与上游那张 "thinking off" 的表**条件一致**（GLM 那份只能用 effort=low 近似）。

---

## 1. Decode（单流，warm，400 token，thinking off）

| 内容 | 本栈 best | 三次原始值 |
|---|---:|---|
| structured（数数 1→200） | **58.5** | 58.1 / 58.5 / 58.5 |
| code（50 个 clamp 函数） | **45.4** | 45.2 / 45.4 / 45.4 |
| prose（讲解 hash map） | **24.0** | 23.9 / 24.0 / 24.0 |

### 与其它栈横向对比（同一套脚本、同样的 prompt）

| 栈 | 代码 | 散文 | structured | 节点 |
|---|---:|---:|---:|---:|
| Qwen3.8-Flash-Next (vLLM+MTP) | **62.1** | **35.3** | **65.7** | 2 |
| **本栈 (SGLang+DFlash2)** | **45.4** | 24.0 | 58.5 | **1** |
| GLM-5.3-Flash EXL3 | 38.8 | 24.6 | 64.3 | 2 |
| Qwen3.8-27B 裸 vLLM（无投机） | 24.9 均值 | — | — | 1 |

**换栈动机（"GLM 太慢"）部分达成**：代码 +17%，但没回到 Flash-Next 的水平。

### 与上游对不上的 17%

上游同配方（DFlash2 + 官方镜像）报 **54.6 tok/s 代码**，我们 **45.4**。

已核的部分解释：
- **格式**：我们是 compressed-tensors（无审核那份只有这个格式），上游 A/B 测得
  compressed-tensors 比 modelopt 慢 **3%**（53.05 vs 54.58）。
- **接受率**：引擎日志 `accept len`，n=32，中位 **5.92**，structured 段 **6.12**；
  上游 issue #163 报的 structured acc/step 是 **6.71** → 低 **8.8%**。

未证实的假说：**DFlash2 草稿模型是对着原版 Qwen3.8-27B 训的，我们的目标是
abliterated 变体**，分布被改动过 → 草稿命中率下降 → 投机解码变慢。
方向与接受率数据吻合，但 3% + 8.8% 仍不足以凑满 17%，剩下的可能是 prompt 不同
（上游用 LRUCache，我们用 50 个 clamp 函数）与上游自己声明的噪声
（"code deltas <15% 算噪声"、"the box drifts"）。**要证实需要拿 RadixArk 原版
checkpoint 在同一台上跑同一个 prompt —— 未做。**

## 2. 并发梯度（structured，各 400 token）

⚠️ 下表是在 **`mem-fraction-static=0.85`** 下测的；采用值后来改成 **0.80**（见 §4），
**0.80 下的吞吐未复测**——KV 池从 137 万降到 122 万但 `max_running_requests` 仍是 12，预计无影响，但那是预计不是实测。

| 并发 | 聚合 tok/s | 单流 tok/s | 完成 | 内存最低 |
|---|---:|---:|---:|---:|
| c1 | 58.1 | 58.1 | 1/1 | 11970 MiB |
| c4 | 208.3 | 52.1 | 4/4 | 11995 MiB |
| c8 | 358.6 | 44.8 | 8/8 | 11972 MiB |
| **c12** | **472.7** ← 峰值 | 39.4 | 12/12 | 11982 MiB |
| c16 | 356.1 | 22.3 | 16/16 | 11951 MiB |

**峰值 472.7 tok/s @ c12，单节点。** c16 掉回 356 是 `max_running_requests=12`
造成的批次凑不整（12 满批 + 4 落单），不是拐点 —— 与 Flash-Next 在 c10 的
「221 那个数是批次凑不整的产物」同形。

### 0.90 vs 0.85 对照（相同档位）

| 并发 | mem-frac 0.90 | mem-frac 0.85 |
|---|---:|---:|
| c1 | 58.1 | 58.1 |
| c4 | 208.8 | 208.3 |
| c8 | 356.2 | 358.6 |
| c16 | 356.6 | 356.1 |
| c2 / c3 | 112.1 / 161.5 | — |
| c12 | **未测** | **472.7** |

decode 三项在 0.85 下与 0.90 **逐位相同**（58.5 / 45.4 / 24.0）。
⚠️ **c12 的 472.7 不能算作 0.85 的收益** —— 0.90 那轮的档位是 1/2/4/8/16，
根本没测 c12。能下的结论只有:**相同档位上两者在噪声内,即 0.85 没有可测量的
吞吐代价**,而 headroom 从 5.0% 升到 9.4%。c12 是顺带发现的真峰值。

### 本仓库历史峰值对比

| 栈 | 峰值聚合 | 档位 | 节点 |
|---|---:|---|---:|
| **本栈** | **472.7** | c12 | **1** |
| Qwen3.8-Flash-Next | 304 | c8 | 2 |
| DeepSeek-V4-Flash | 186 | c6 | 2 |
| GLM-5.3-Flash EXL3 | 179.8 | c4 | 2 |

⚠️ 上游那张并发表（x4 111.6 / x8 184.9 / x16 227.6）用的是
**"synthetic structural-decode fixture"**，上游自己写明 *"Another clock again:
not comparable to the ndec/stream/table rows"*。所以**别把我们的 +93% 当成
跨 kit 的胜负** —— 那是两个不同的负载。我们表内的档位之间是可比的。

**并发不吃主机内存**：整个梯度 11951–11995 MiB，纹丝不动（0.90 那轮是 6323–6353，同样纹丝不动）。

## 3. 冒烟 + abliteration 验证

`stacks/qwen38un/test.sh`（`make` 未挂；直接跑）：

```
out=150 tok  finish=stop  content=520 字符  reasoning_content=空     ← enable_thinking 生效
安全教育     ANSWERED  1171 字符 / 300 tok
小说反派台词  ANSWERED  1216 字符 / 300 tok
急救信息     ANSWERED  1242 字符 / 300 tok
PASS: 3/3 正常作答 —— abliteration 生效
```

判据用的是**良性过度拒答**（模型方自报 5.6% → 0.4%）：安全教育 / 虚构创作 /
医学信息这类「对齐过度的模型常误拒、但内容完全正当」的请求。
**没有用真正有害的提示词测** —— 良性过度拒答同样能区分 abliterated 与否，
也不该在冒烟脚本里留下那种东西。模型方自报的拒答率 64-99% → 0-6% **本仓库未独立验证**。

---

## 4. memwatch:0.90 装不回去,0.85 可以

| mem-fraction | S1 空载 headroom | memwatch | KV 池 | max_running_requests |
|---|---:|---|---:|---:|
| 0.90（上游默认） | 6.10 GiB (**5.0%**) | ❌ **启动第一拍就 `crit 1/2`** | — | 16 |
| 0.85（试过，**不够**） | 11.4 GiB (9.4%) 开机<br>7.4 → **5.0%** 服务 2h 后 | ❌ **2h10m 后真的触发，栈被停** | 1,368,663 tok | 12 |
| **0.80（采用）** | **17.4 GiB (14.3%)** 开机<br>~11% warmup 后 | ✅ 稳定 | 1,220,951 tok | 12 |

⚠️ **上面两个 headroom 数字都要看 —— 它会漂。** 11.4 GiB 是**刚启动**测的;
服务 + 压测约 2 小时后实测降到 **7.4 GiB (6.1%)**,且 `drop_caches` 只回收
137 MiB(不是页缓存)。掉的是**引擎自己的主机侧 RSS**:`sglang::scheduler`
4.4 GiB + `sglang::detokenizer` 1.4 GiB + python3 1.7 GiB ≈ 7.5 GiB,
随请求历史/radix cache 元数据增长。
6.1% 仍高于 memwatch 的 CRIT 5%,但余量从 4.4 个百分点缩到 **1.1 个** ——
**这是要长期观察的一条**:若继续漂到 5% 以下,memwatch 会把栈停掉(这正是它的职责,
但届时要么重启引擎回收,要么再降 mem-fraction)。
拿开机读数当稳态是我这次的取数错误,记在这里免得重犯。

memwatch 的 `CRIT_PCT=5`、判据 `pct <= CRIT` —— 0.90 下稳态恰好 5.0%,所以它
**看起来能启动、实际会立刻把栈停掉**,等于没有防线。而这两台没有 BMC。

0.85 换来的 KV 仍有 **136 万 token,是 262144 上下文的 5.2 倍** —— 0.90 划走的
~112 GiB 里权重只占 24 GB,其余全是用不上的 KV。这笔交换是免费的(见上表:
相同档位吞吐在噪声内)。

⚠️ **别调到 0.95** —— 上游脚本注释原文:hard-rebooted the box。
覆盖链:start.sh 0.95 → start-dflash.sh 0.90 → 我们的 DF_EXTRA 0.85(last-wins),
三个值都会出现在容器命令行里。

## 还欠的

- **prefill 未测**（`q38un-prefill.sh` 已就绪，没跑）。GLM 那次的教训是
  prefill 主机内存超线性，本栈 headroom 更紧，值得单独测。
- **质量未验**。abliteration 只验了「不误拒」，没验「能力没退化」。
  aider-polyglot 现在欠三个栈（V4 有基线，Flash-Next / GLM / 本栈都没跑）。
- 上游 17% 差距的假说未证实（需要 RadixArk 原版 checkpoint 做对照）。

原始输出：`raw-2026-09-19.log`。
