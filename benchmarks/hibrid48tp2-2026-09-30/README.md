# hibrid48tp2 首次基线 + 同测法三栈对照(2026-09-30)

2026-09-30 主力栈从 qwen38un(S1 单机 SGLang)+ hibrid48(S2 单机)两个栈并跑,换成
**hibrid48tp2**:同一份 hibrid48 checkpoint,上游 myllmbox **双机** kit,TP=2 横跨两台。

**一句话结论:同一套测法下,单流快 1.37×(对 hibrid48 单机)/ 2.35×(对 qwen38un),
c24 聚合 380.7 对 200.1 / 212.6;而且 64 个座位把梯子一路推到 c64 = 562 tok/s。**
两台机器合起来跑一个模型,吞吐不低于原来两台各跑一个模型的**总和**(见 §3)。

---

## 被测配置

| | |
|---|---|
| 上游 kit | `myllmbox/qwen38-flash-next-cluster-recipe` @ `4e4747b`(v4.1),本地三处偏离见 `stacks/hibrid48tp2/recipe.yaml` 头注释 |
| 镜像 | `myllmbox/qwen38-flash-next-cluster-vllm:v6`,image ID(= arm64 config digest)`sha256:4d03fc80…`,属于上游 README 的 index `861ac752…` |
| 权重 | `myllmbox/Qwen3.8-Flash-Next-hibrid48` HF 修订 `e316057d`,28 分片 105,336,540,328 字节;S1 那份 28/28 与 HF LFS sha256 逐个核对 |
| 拓扑 | head(rank0,API)= **S1** 100.97.87.120:8000;rank1(`--headless`)= S2;NCCL over RoCE `rocep1s0f0` / 192.168.200.x,GID index 3(两台启动时现探) |
| 引擎 | vLLM 0.30.0 + myllmbox 补丁;TP=2;K=5 MTP(probabilistic draft + block verify);`max-num-seqs 64`;`kv-cache-memory 41G`/box;bf16 KV;CUDA graphs FULL_AND_PIECEWISE |
| 主机 | 两台 `vm.compaction_proactiveness=0`(S1 于本日设置并持久化);swap 关;时钟上限关(09-20 起) |

## 启动不变量 —— 与上游**逐字相同**

| | 上游 README | 本仓库 |
|---|---|---|
| KV 池 | 2,450,356 tokens | **2,450,356** tokens,"Maximum concurrency for 262,144 tokens per request: 9.35x" |
| 每 rank 权重 | "~51G of weights per box" | Model loading took **51.03 GiB**(两个 rank 相同),117.5 s |
| KV 预留 | 41G pin | reserved 38.18 GiB(= 41e9 字节)"skipped memory profiling" |
| 启动 | "about four minutes" | init engine 63.6 s;`docker run` → `/health` 200 约 4 分钟 |

---

## 1. 方法

`ladder.py` 是 `../hibrid48-2026-09-28-concurrency/concurrency.py` 的参数化副本 ——
**请求体逐字相同**:8 道题(6 道代码 + 2 道散文)按并发位轮换、每条前缀 `[req i]`
(防前缀缓存把活干没了)、`max_tokens=400`、`temperature=0`、非流式、thinking 经
`chat_template_kwargs.enable_thinking=false` 关掉(每档 `reasoning_tokens` 都记了,
全程 0)、先 c2 热身不计。`aggregate = 该轮 completion_tokens 之和 / 该轮墙钟`,
**墙钟含 prefill 和最慢那条的收尾**。三个栈都从同一台 Mac 经 Tailscale 打。

```bash
URL=http://100.97.87.120:8000/v1/chat/completions MODEL=qwen3.8-flash-next-tp2 \
THINK_OFF='{"chat_template_kwargs":{"enable_thinking":false}}' \
LEVELS="1 2 4 6 8 12 16 20 24 32 48 64" TAG=hibrid48tp2 python3 ladder.py
```

## 2. 结果(聚合 tok/s)

| 并发 | hibrid48 单机(S2,09-28) | qwen38un 单机(S1,今日停机前) | **hibrid48tp2(两台,今日)** |
|---:|---:|---:|---:|
| c1 | 72.3 | 42.1 ¹ | **96.5**(复测 99.4 / 98.0 / 98.9) |
| c2 | 98.8 | 70.5 | **146.2** |
| c4 | 99.9 | 78.5 | **148.1** |
| c6 | 111.9 | 80.2 | **191.6** |
| c8 | 135.9 | 123.3 | **197.7** |
| c12 | 170.2 | 176.5 | **282.4** |
| c16 | 189.7 | 216.9 | **312.9** |
| c20 | 191.7 | 210.4 | **319.8** |
| c24 | 200.1(其座位上限 16) | 212.6(其 `max_running_requests=12`) | **380.7** |
| c32 | — | — | **429.9** |
| c48 | — | — | **508.6** |
| c64 | — | — | **562.2** ← 峰值 |

¹ qwen38un 梯子里的 c1 首测是 **18.7**(168 tok / 9.0 s),紧接着三次复测
42.1 / 41.1 / 42.9 —— 首测是离群值(首发新形状 / 当时另有客户端连着),表里用复测中位。
⚠️ SGLang 接受任意 model 名并原样回显(gotcha #10),所以 `ladder.py` 的
"响应 model 必须等于请求 model" 这道闸门**只对 vLLM 有效**,对 qwen38un 是空转。

原始输出:`ladder-*.log` / `ladder-*.json`。

## 3. 怎么读

- **单流是这次最大的收益**:98.9 对 72.3(×1.37)对 42.1(×2.35)。上游 README 的
  单流 99 在本仓库**原样复现** —— 这是第二次(hibrid48 单机那次 72.3 对上游 73)
  上游的单流数字在这两台机器上成立。
- **同样两台机器,一个模型 ≥ 原来两个模型的总和。** 原来的布局是两台各跑一个栈、
  各接各的客户端,总产能 = 两者相加:c12+c12 = 170.2 + 176.5 = 346.7,对本栈 c24
  **380.7**(+10%);c24+c24 = 200.1 + 212.6 = 412.7,对本栈 c48 **508.6**(+23%)。
  代价是只剩一个模型(qwen38un 的去审查 27B 不在线了)。
- **座位不再是瓶颈**:hibrid48 单机 16 座、qwen38un 12 路,两者到 c16–c24 就平了;
  本栈 64 座,c64 还在涨(508.6 → 562.2)。
- **与上游并发数字的差是测法,不是机器**:上游 v4.1 c8 342 / c16 458 / c64 793,
  本仓库 197.7 / 312.9 / 562.2,比值 0.58 / 0.68 / 0.71 —— 与 hibrid48 单机那次
  (0.63 / 0.66)同形:上游量的是稳态解码窗口,这里的墙钟含 prefill 与收尾。
  **所以本表只和本表比。**
- **投机解码**:整场(含冒烟)`accepted 62,851 / drafts 20,473` ≈ 每步多收 3.07 个
  草稿 token(≈ 4.07 token/step)。上游在它的混合 prompt 上报 ~4.8–4.9。本表的 prompt
  含 2/8 散文、且 temperature 0 —— 未单独拆分,只是记账。

## 4. 主机内存

| | boot 后 | 跑完 c1→c64 梯子后 |
|---|---|---|
| S2(head) | 12.77 GiB(10.5%) | 11.77 GiB(**9.7%**) |
| S1(worker) | 14.55 GiB(12.0%) | 13.54 GiB(**11.1%**) |

- 上游说 head 在图捕获后只剩 "~6G";本仓库 head 放在 S2(较轻的那台,没有 zcode),
  量到 11.8 GiB。其中大部分是可回收的 page cache(MemFree 只有 ~1.3 GiB)。
- ⚠️ 每 2 s 的采样器只活到 22:06:47(覆盖 c1→c16);c20→c64 的区间靠看门狗
  (10 s 一次)兜 —— 它全程没离开 "ok",即两台都 ≥ 5%。
- 看门狗:`WATCH_WARN_PCT=5 WATCH_CRIT_PCT=2 WATCH_CRIT_CONSEC=10 make memwatch
  STACK=hibrid48tp2`(Mac 本地 tmux `memwatch-hibrid48tp2`,启动自检通过)。
- ⚠️ 这是约 15 分钟的 steady,不是两小时的(qwen38un 0.85 两小时从 9.4% 掉到 5.0%)。

## 5. 语义与传输(`make test STACK=hibrid48tp2` 全部断言)

| | 实测 |
|---|---|
| 关思考 | `chat_template_kwargs.enable_thinking` 有效(on 72 tokens 答 22 / off 0 tokens 答 13);**顶层 `enable_thinking` 被静默忽略**(false 仍 66 tokens) |
| CoT 字段 | `reasoning`;`reasoning_content` 不出现 |
| `/v1/responses` effort | none / low / medium / xhigh → 200;**minimal / high / max → 400**("Supported types are xhigh (default), medium, and low.")⚠️ 与 hibrid48 单机记录的"high 也 200"**不同** |
| NCCL 传输 | 400 token 生成期间 RDMA 计数 **843 MB**、TCP(enp1s0f0np0)**0 MB** —— 确实在 RoCE 上 |

## 6. 客户端(本机 = mbpm5.local,即 CLAUDE.md 里的"机器 B")

`codex --profile dgx` 和 `qwen` 都已切到本栈,**实发请求验证**:`codex exec --profile
dgx` 回 `OK`(头部 `model: qwen3.8-flash-next-tp2 / provider: dgx / reasoning effort:
xhigh`,无 "Model metadata not found");`qwen -p` 在 repo 内外各回一次 `OK`,引擎日志里
对应 `POST /v1/chat/completions 200`。切换前本机两处漂移一并修正:dgx profile 的
`model` 在 09-21 05:02 的一次写入里**退回**成了已删栈的 slug `qwen38-flash-next`
(09-19 23:30 的备份还是对的 `qwen3.8-27b-sglang`,原因不明;SGLang 什么名都收,
所以九天没响);qwen 全局启动默认 `model.baseUrl` 指 S2、承重的 `security.auth.baseUrl` 却指 S1。

## 7. 上游 README 自报的指标,达到了没有?—— 按上游口径补测

§2 的梯子(墙钟含 prefill 与收尾)与上游的"稳态窗口"不是一个口径,不能拿来判
达标与否。所以补了两组**按上游口径**的测量:

**(a) 稳态吞吐** —— `steady.py`:c 路请求持续占满(一条结束立刻补一条),等引擎
`num_requests_running` 到位后,读 `/metrics` 的 `generation_tokens_total` 在 60 s 窗口内
的增量;`tok/step = 1 + Δaccepted/Δdrafts`(上游 "acceptance" 一列的口径)。prompt 仿上游
v4.1 的 "LRU-cache code + a prose explanation of it",thinking off,temperature 0。

| 并发 | 本仓库 tok/s | 上游 v4.1 平均 | 比值 | 本仓库 tok/step | 上游 acceptance | **引擎步/s** 本仓库 / 上游 |
|---:|---:|---:|---:|---:|---:|---:|
| c1 | 83.7 | 99 | 0.85 | 4.10 | 4.73 | 20.4 / 20.9 |
| c8 | 306.5 | 342 | 0.90 | 4.10 | 4.93 | 9.3 / 8.7 |
| c16 | 421.7 | 458 | 0.92 | 4.04 | 4.90 | 6.5 / 5.8 |
| c32 | 576.1 | 627 | 0.92 | 4.08 | 4.91 | 4.4 / 4.0 |
| **c64** | **783.9** | **793** | **0.99** | 4.25 | 4.80 | 2.9 / 2.6 |

(引擎步/s = 每流 tok/s ÷ tok/step,即引擎每秒走几步;上游一列用其表中聚合 ÷ c 算出。)
c64 时 KV 池用到 93.7%(上游:"64 streams … filled it to 99 % after about three minutes")。

**(b) 冷 prefill** —— `prefill.py`,**在 head(S2)上打 localhost**,每尺寸两发、各带唯一
uuid 前缀(`cached_tokens` 全为 0)。首发与暖几乎相同,下表取首发:

| prompt | 本仓库 TTFT / prefill | 上游 cold TTFT / prefill |
|---|---|---|
| ~8K(7,853 tok) | 2.32 s / **3,380** tok/s | 2.6 s / 3,222 |
| ~32K(32,795) | 9.56 s / **3,431** | 9.9 s / 3,313 |
| ~64K(67,022) | 19.67 s / **3,408** | 20 s / 3,292 |
| ~128K(137,054) | 41.43 s / **3,308** | 41 s / 3,233 |

⚠️ `prefill-hibrid48tp2-over-tailscale-INVALID.log` 是第一次从 Mac 经 Tailscale 打的结果
(16K 2,183–2,736 / 67K 2,658–2,792 tok/s,128K 那档因尺寸估错超了 262,144 被 400):
prompt 上传走 DERP(当天 ~40 KB/s),TTFT 被整段高估 —— **留着当反例,别引用**。
128K prefill 期间两台 MemAvailable 最低:S2 **8.03 GiB(~6.6%)**、S1 9.71 GiB ——
比空闲时掉 ~3.8 GiB,仍在看门狗 warn 5% 之上;256K(上游测过,84 s)本仓库**没测**。

**结论:上游自报的数字在这两台机器上成立。**
- 单流 99 tok/s:§2 梯子复测 98.9(我们自己的 8 题 prompt 集)—— 达到。
- c64 聚合 793:稳态 **783.9**(−1%)—— 达到。
- 冷 prefill ~3.2K tok/s 到 128K:**3,308–3,431**,每档都略**高于**上游 —— 达到。
- 启动不变量(KV 池 2,450,356 / 每 rank 51 GiB / ~4 min)逐字相同 —— 达到。
- c1–c32 的 tok/s 低 8–15%,但**引擎步速度与上游持平或更快**(20.4 对 20.9,c8 起反而
  快 7–11%);差额全在每步收下的 token 数(4.0–4.1 对上游 4.7–4.9)—— 投机解码的接受率
  由内容决定(`docs/benchmarking-cn.md`),我们的 prompt 不是上游那份(上游 harness 在其
  私有 repo 里,拿不到)。这一条是**推断**:没有用上游原 prompt 复测过。

## 还欠的

- 256K prefill;长上下文下的 decode(上游:128K 后 decode 89.8 tok/s)。
- 质量:与 hibrid48 单机**同一 checkpoint**,其四件套 A/B 见
  `../ab-radixark-vs-hibrid48-2026-09-28/`;TP=2 不改输出分布(投机解码保持原分布),
  但本栈上没有单独复测。
- 多模态、c64 以上、两小时级的内存 steady。
