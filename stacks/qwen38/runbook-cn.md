# Qwen3.8-27B-NVFP4 单节点降级栈 runbook

> 栈 id `qwen38` —— 身份与参数见 `stacks/qwen38/stack.env`,本文记录
> **为什么建这套、怎么从零复现、以及所有踩过的坑**。
>
> **不是升级,是降级**:比当时的主力栈慢 2.7 倍、agentic coding 基准低 10~12 分。
> 它唯一不可替代的价值是**只要一台机器** —— TP=2 栈不可拆分,任一节点挂掉就整体
> 停服,而本栈能在幸存的那台上继续服务。
>
> **上下文用原生 262144**,不是原配方 YaRN 外推的 1M(2026-08-15 改),理由见 §5.5。
>
> 相关:S2 死机事故与恢复流程已拆到 `docs/s2-outage-2026-08-15-cn.md`;
> 客户端接入统一见 `docs/clients-cn.md`(本文原 §6 已并入那里,不再重复维护)。

```bash
make run    STACK=qwen38      # 起栈(约 220 秒)
make status STACK=qwen38
make test   STACK=qwen38      # 完整 benchmark,不只是冒烟
```

---

## 2. 为什么选这个模型(以及为什么它不是升级)

**Qwen3.8-27B**:2026-08-14 官方发布,27.78B **稠密**、多模态(图+视频)、Apache 2.0、
原生 262,144 上下文(YaRN factor 4.0 可扩到 1M)。
本栈用的是第三方量化 `unsloth/Qwen3.8-27B-NVFP4`(22GB),
部署配方参考 [MiaAI-Lab/Qwen3.8-27B-DGX-Spark-RTX-6000](https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-RTX-6000)(28 星,第三方)。

### 2.1 质量:明确降级

同基准直接对打:

| Benchmark | Qwen3.8-27B | **DeepSeek V4-Flash** |
|---|---|---|
| Terminal-Bench 2.1 | 73.0 | **82.7** |
| DeepSWE 1.1 | 42.2 | **54.4** |

差 9.7 和 12.2 分,**两项都是 agentic coding** —— 正是 codex/qwen CLI 的主力用途。
它赢的地方:LiveCodeBench v6 **90.3**、GPQA Diamond **89.2**(单轮编码/知识),
以及 V4-Flash 完全没有的**多模态**(OSWorld-Verified 84.3)。

> ⚠️ **数字陷阱**:官方卡上有个 `QwenSWEBench 79.0`,和 V4-Flash 的
> `SWE-bench Verified 79.0` 数字一模一样,但**是两个不同的 benchmark,不可比较**。

### 2.2 速度:反直觉地慢 2.7 倍

2026-08-15 实测(S1 单机,warm,预热 3 次后计数,`stream:false` + `usage.completion_tokens`/墙钟):

| | Qwen3.8-27B(**1** 节点) | V4-Flash(**2** 节点) |
|---|---|---|
| decode 均值 | **24.9 tok/s** | **67.2 tok/s** |
| decode 区间(按内容) | 20.8(散文)– 27.4(数数) | 31 – 84 |
| 投机接受率 | 87.4%(p0 92.4 / p1 82.3) | 75.8%(p0..p4 = .90/.81/.74/.68/.65) |
| **每步 token** | **2.75**(MTP n=2) | **4.79**(DSpark n=5) |
| steps/s(推算) | ~9.0 | ~14.0 |

**为什么小模型反而慢**:Qwen3.8-27B 是**稠密**模型,每个 token 都要算满 27B;
V4-Flash 是 MoE,每 token 只激活 **13B**。所以 V4-Flash 哪怕要跨 200G 链路做 TP 通信,
**每步仍然更快**;再叠加 DSpark 的 5 个草稿位置(MTP 只有 2 个),总差距拉到 2.7 倍。

> **可复用的结论**:在 GB10 上,**决定解码速度的是激活参数量,不是总参数量**。
> 注意 MTP 的*单位置*接受率其实比 DSpark **更高**(92.4/82.3 vs 90/81/74/68/65),
> 只是草稿位置太少,总量吃亏。

代码质量主观上不错(LRUCache 那题给出了干净正确的实现:Node 类、双向链表、docstring 齐全)。

---

## 3. 从零部署(可在任意机器复现)

### 3.1 权重(ModelScope,国内直连)

HF 在国内拉不动,走 ModelScope —— 该量化版**已在 ModelScope 上架**:

```bash
# 在 S1 上,tmux 里跑(SSH 走 DERP relay,容易断)
# 23.4GB / 14 个文件,实测 ~48MB/s,约 8 分钟
ssh admin@100.97.87.120
tmux new -s qwen38-dl
python3 -m venv /home/admin/modelscope-venv
/home/admin/modelscope-venv/bin/pip install -i https://pypi.tuna.tsinghua.edu.cn/simple modelscope
/home/admin/modelscope-venv/bin/python3 -c '
from modelscope import snapshot_download
snapshot_download("unsloth/Qwen3.8-27B-NVFP4", local_dir="/home/admin/models/Qwen3.8-27B-NVFP4")'
```

> 用 `local_dir=` 而不是 `cache_dir=`,直接写真实文件,
> 规避 HF-cache 绝对符号链接在容器内解析失败的老坑(见 CLAUDE.md)。
> 下载后可用 `find <dir> -type l` 确认无符号链接。

### 3.2 镜像(daocloud 镜像站)

**用上游 vLLM,不需要 jasl fork** —— 这是本栈相对主栈的一个实质优势:

```bash
docker pull docker.m.daocloud.io/vllm/vllm-openai:nightly-aarch64
docker tag  docker.m.daocloud.io/vllm/vllm-openai:nightly-aarch64 vllm/vllm-openai:nightly-aarch64
# 实测拉到的是 vLLM 0.27.2rc1.dev77+gac7509e2b,20.6GB
```

> 镜像 pull 由 daemon 执行,**不受** `~/.docker/config.json` 里那个代理设置影响,
> 所以是国内直连的快速路径。但 `docker run` 会把代理**注入容器**,见 §5.3。

### 3.3 启动

```bash
make run STACK=qwen38       # 或直接:ssh S1 → bash /home/admin/qwen38-start.sh
make status STACK=qwen38    # 容器状态 + /v1/models
make test STACK=qwen38      # 完整基准(预热 3 次 + 4 类 prompt + 接受率)
make logs STACK=qwen38
make stop STACK=qwen38
```

脚本源在 repo 里:`stacks/qwen38/launch.sh`(启动)、`stacks/qwen38/test.sh`(基准)。
`make run STACK=qwen38` 会先 rsync 到 S1 再执行,所以改 repo 里的即可。

启动实测:**约 200~220 秒就绪**(V4-Flash 双节点要 ~5 分半),
25.4GiB 权重 + 65.16GiB KV → **1,870,754 tokens** KV 容量,
**262,144 上下文并发 7.14×**。

---

## 4. 相对官方配方的 3 处刻意改动

`stacks/qwen38/launch.sh` 基于 MiaAI-Lab 的 `start.sh`,但有四处**故意不一样**:

| # | 改动 | 原因 |
|---|---|---|
| 1 | 模型用**本地路径**,不用 HF repo id | S1 上不了 HF;这是本 repo 反复踩过的坑(同 V4-Flash) |
| 2 | `--gpu-memory-utilization` **0.75**(官方 0.84) | 这台 head 节点在 0.85 上 OOM 过(2026-06-29)。0.84 只剩 ~9GiB 余量;S2 已死时再 OOM 掉 S1 就得两台一起去机房捞。0.75 下 KV 仍有 187 万 token,绰绰有余 |
| 3 | 显式清空代理环境变量 | `~/.docker/config.json` 会往每个 `docker run` 注入 xray 代理,而它经常是死的 |
| 4 | **原生 262144**,删掉 `--hf-overrides` 和 `VLLM_ALLOW_LONG_MAX_MODEL_LEN`(官方是 YaRN 外推 1M) | 静态 YaRN 的短上下文质量损失是**每个请求**都付的,而实际负载是短代码提示。详见 §5.5 |

---

## 5. 踩过的坑

### 5.1 `--attention-backend triton_attn` 是过时建议 —— 别照抄

MiaAI-Lab 的 README 说 *"triton_attn is required for the FP8 KV cache:
FlashAttention-2 cannot serve FP8 KV on GB10/SM121"*。

实测在 vLLM 0.27.2rc1 上:**这个 flag 被 vLLM 无视了**,它自选了
**FLASHINFER + `xqa` 解码后端**,而 FlashInfer 在 sm121 上**能**跑 FP8 KV:

```
INFO [cuda.py:486] Using FLASHINFER attention backend out of potential backends: ['FLASHINFER', 'TRITON_ATTN'].
INFO [flashinfer.py:890] FlashInfer resolved query dtypes: prefill=bfloat16, decode=bfloat16,
     decode_backend=xqa, kv_cache_dtype=torch.float8_e4m3fn, arch=sm121
```

原文警告的是 **FlashAttention-2**,不是 FlashInfer。这个 nightly 比仓库文档新,
flag 留着无害但没作用。

**验证 FP8 KV 是否真的生效**:看启动日志里的 `kv_cache_dtype=torch.float8_e4m3fn`;
或核对 KV 容量 —— 我们在 util 0.75 拿到 1,948,194 tokens,
按比例外推到 0.84 ≈ 2.27M,与仓库宣称的 2,295,133 吻合 → FP8 KV 确实开着。

### 5.2 thinking 参数名和 V4-Flash **不一样**

- V4-Flash:`chat_template_kwargs: {"thinking": false}`
- **Qwen3.8:`chat_template_kwargs: {"enable_thinking": false}`**(模板里还有 `preserve_thinking`)

照抄 V4-Flash 的写法会**静默失效**。

### ⚠️ 思考内容的字段名两栈也不同(2026-08-15 查清)

**同一个 `/v1/chat/completions` 响应里,两套栈把 CoT 放在不同字段:**

| 栈 | reasoning parser | CoT 字段 |
|---|---|---|
| V4-Flash | `deepseek_v4` | `.choices[0].message.reasoning_content` |
| **Qwen3.8-27B** | `qwen3` | **`.choices[0].message.reasoning`** |

读错字段会看到 `None`,**看起来完全像"thinking 开了但没输出"**——本文早先就据此
误判为"parser 不匹配、未解决"。实际上解析器一直工作正常。

判据很好认:**thinking 开启时 `content` 会短得反常**(只剩最终答案),
因为 CoT 已经被正确分离出去了。实测同一个问题:

| 配置 | `content` 长度 | `reasoning` |
|---|---|---|
| `enable_thinking: true` | **19 字符**(只有 `17 × 23 = **391**`) | 有内容 |
| `enable_thinking: false` | 569 字符(完整推导写在正文里) | 无 |

> 这条其实早就记在本 repo 里了 —— 退役栈文档的"Qwen3 系列"gotcha 就写着
> *reasoning parser `qwen3`(CoT 在 `.choices[0].message.reasoning`,答案在
> `.content`)*。**Qwen3.8 沿用同一套。** 那份文档已随退役栈删除,结论现收在
> [gotchas-cn.md](../../docs/gotchas-cn.md#9-跨栈标识写死后会静默失效cot-字段kwarg-名model-名) #9.1。

`/v1/responses` 路径不受影响:CoT 走 `type:"reasoning"` 的输出项(codex 用的是这条)。

### 5.3 `docker run` 会注入代理

同 CLAUDE.md 里记的老坑:`~/.docker/config.json` 的 `proxies.default` 是**客户端**配置,
会给每个 `docker run` 注入 `HTTP(S)_PROXY`。本栈从本地路径加载模型不需要外网,
但如果代理是死的,某些库的 phone-home 会卡住。启动脚本里已显式清空,并加了
`HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1`。

### 5.5 上下文用原生 262144,不要 YaRN 外推的 1M

2026-08-15 从官方配方的 1M 改回**原生 262144**。

**怎么改**:**直接删掉整个 `--hf-overrides`**,不要去改里面的字段。因为 checkpoint
自带的 `rope_parameters` 里 `mrope_interleaved`、`mrope_section [11,11,10]`、
`partial_rotary_factor 0.25`、`rope_theta 10000000` 与 override **逐字段相同**,
唯一差别就是 `rope_type: yarn → default` 加 `factor: 4.0`。所以删掉即回归原生,
且不会误伤多模态需要的 mrope 设置。同时删掉 `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`
(只在超过原生长度时才需要),并把 `--max-model-len` 设为 `262144`。

**为什么改**(三条,按重要性):

1. **短上下文质量损失是全局的**。模型卡自己承认 *"static YaRN can slightly impact
   short-context quality"* —— 这个代价**每个请求**都付,包括实际负载的短代码提示。
   为了一个几乎用不到的 1M 去牺牲天天用的短上下文,不划算。
2. **1M 在这台机器上并不实用**。大海捞针实测:**336,010 token** 的 prompt 光 prefill
   就跑了 8 分钟还没结束(`--max-num-batched-tokens 8192` + chunked prefill,
   1M 要切成约 122 个块)。**"配置支持"和"实际可用"是两回事。**
3. **并发反而变好**。同样的 KV,满长请求并发从 **1.95× 提升到 7.14×**
   (1M 一个请求就吃掉一半 KV;262144 则能同时放下 7 个)。

真需要百万上下文时用 V4-Flash —— 它是**原生** 1M,且 prefill 快得多
(8K/32K/100K = 1760/2203/2084 tok/s,见 `benchmarks/bench-full-2026-08-05/`)。

**改后实测**:`/v1/models` 报 `max_model_len: 262144`,启动日志里 `yarn` 出现 **0** 次,
KV 1,870,754 tokens / 并发 7.14×,加载 ~200s。

### 5.4 容器**故意**不设 `--restart`

如果设了 `--restart unless-stopped`,S1 重启后 qwen38 会自启并占住 ~91GB,
而 k3s 可能同时在拉 V4-Flash → **OOM 掉整台机器**(那种会连 tmux 一起带走的故障)。
两栈互斥,必须手工控制。见 §7。

---


---

## 6. 客户端接入

已统一到 **`docs/clients-cn.md`**(2026-08-15 从 CLAUDE.md 拆出,是当前唯一事实源),
本文原来的 §6/§6.1/§6.2/§6.3 与它重复且更旧,2026-09-19 拆分时删除。

切换启动默认:

```bash
./scripts/qwen-model-switch.sh qwen38    # 别名来自 stacks/<id>/stack.env 的 STACK_CLIENT_ALIAS
./scripts/qwen-model-switch.sh status
```

---

## 8. 定位总结

| | V4-Flash(主栈) | Qwen3.8-27B(降级栈) |
|---|---|---|
| 定位 | **日常主力** | **S2/S1 任一挂掉时的救火** |
| 节点 | 必须 2 台 | 1 台 |
| 速度 | 67.2 tok/s 均值 | 24.9 tok/s 均值 |
| agentic coding | 更强 10~12 分 | 更弱 |
| 多模态 | ❌ | ✅ 图+视频 |
| 引擎 | jasl fork(自建镜像) | 上游 vLLM nightly |
| 恢复时间 | 需两台都在 | **~4 分钟**(权重已在盘上) |

**它不是"更快的备胎",是"少一台机器也能用的备胎"。**
权重 22GB 躺在 S1 盘上不占显存,随时可拉起 —— 这正是本次 S2 死机暴露的缺口:
以前 S2 一挂就只能彻底停摆等人去机房。
