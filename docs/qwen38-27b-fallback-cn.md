# Qwen3.8-27B-NVFP4 单节点降级栈 runbook

> 状态:**已部署,作为降级预案**(2026-08-15,S1 单机 `:8888`,served name `qwen38-27b`)。
> **不是 V4-Flash 的替代品** —— 实测比 V4-Flash **慢 2.7 倍**、agentic coding 基准低 10~12 分。
> 它唯一不可替代的价值是**只要一台机器**:V4-Flash 是 TP=2 不可拆分,任一节点挂掉就整体停服
> (2026-08-15 S2 硬件死机即是如此),而本栈能在幸存的那台上继续服务。
>
> **📌 当前状态(2026-08-15)**:S2 硬件死机未恢复;V4-Flash 已手工停止
> (S1 上 `k3s-agent` 已 `disable --now`);本栈在 S1 运行中,Qwen Code 默认指向它。
> 恢复步骤见文末[§7 恢复流程](#7-恢复流程v4-flash-回归)。
>
> **📌 2026-08-15 二次调整:上下文改回原生 262144**(原配方是 YaRN 外推的 1M)。
> 理由与实测见[§5.5](#55-上下文用原生-262144不要-yarn-外推的-1m)。
> 需要百万上下文时用 V4-Flash(原生 1M 且 prefill 快得多)。
>
> 本文记录**为什么建这套、怎么从零复现、以及所有踩过的坑**,供任何机器/会话复现。
> 主栈见 `docs/deepseek-v4-flash-cn.md`;基准方法学见 `benchmarks/bench-full-2026-08-05/`。

---

## 1. 起因:2026-08-15 S2 硬件死机

**08:29:40 CST,server 2(spark-2435)整机猝死**,至今未恢复。

判定方法(三条**互相独立**的路径同时消失 → 排除网络问题):

| 路径 | 证据 |
|---|---|
| Tailscale(走 S2 自己的上联+公网) | `offline, last seen ~08:30` |
| 200G 直连线(不经任何交换机) | S1 侧两个 CX7 口同时 `Link down` → `NO-CARRIER` |
| 实验室内网 `10.14.20.0/24`(全网段扫描) | 只有网关响应,S2 无踪影 |
| homelab Prometheus | `up{instance="100.67.164.92:9100"}` 08:30 归零 |

**关键判据是第 2 条**:直连线载波消失 = 对端网卡失去供电。内核 panic 时 PHY 通常还亮着,
所以这是**断电级别**的死亡,不是软件挂起。

死前监控(homelab Prometheus,60s 采样)**无任何异常前兆**:

- 温度 87~94°C —— 但这是这两台的日常(过去 7 天每天峰值 95~98°C 都活着),
  且 S1 同一时刻 92°C 毫发无损 → **不是过热**
- 内存 13.6GB 可用、load 2.8、vLLM 正在跑 1 个请求 → **不是 OOM,不是空载**
- S1 的 dmesg 在 08:29:40 之前只有 tailscaled 的 apparmor 噪声

→ 最可能是 **S2 本地的电源级事件**(适配器/USB-C PD 供电、插头接触、整机保护跳闸)。
不是全屋断电(S1 同房间正常)。**确凿死因要等开机后看 `journalctl -b -1`**:
日志戛然而止=断电,有 panic 栈=软件。

### 1.1 远程抢救手段:只有 WoL,且失败了

DGX Spark **没有 BMC/IPMI**,无法远程开机。唯一可试的是 Wake-on-LAN:

```bash
# S2 上联口 MAC(从 Prometheus 的 node_network_info 历史指标里挖出来的)
#   enP7s7 = 4c:bb:47:7e:24:35
# 同型号机器确认 ethtool 显示 "Wake-on: g"(已启用)
# 从 S1 同网段广播魔术包,每 15s 一轮共 18 轮 → 全部失败
```

失败本身也是证据:网卡连待机电都没有,进一步指向电源侧。

> **教训 / 待办**:给两台配一个 Tailscale 可控的智能插座或 PDU,
> 就能把"人去机房按电源键"变成远程电源循环。BIOS 里 AC 恢复策略设为 always-on。

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
make qwen38-run       # 或直接:ssh S1 → bash /home/admin/qwen38-start.sh
make qwen38-status    # 容器状态 + /v1/models
make qwen38-test      # 完整基准(预热 3 次 + 4 类 prompt + 接受率)
make qwen38-logs
make qwen38-stop
```

脚本源在 repo 里:`scripts/qwen38-start.sh`(启动)、`scripts/qwen38-test.sh`(基准)。
`make qwen38-run` 会先 rsync 到 S1 再执行,所以改 repo 里的即可。

启动实测:**约 200~220 秒就绪**(V4-Flash 双节点要 ~5 分半),
25.4GiB 权重 + 65.16GiB KV → **1,870,754 tokens** KV 容量,
**262,144 上下文并发 7.14×**。

---

## 4. 相对官方配方的 3 处刻意改动

`scripts/qwen38-start.sh` 基于 MiaAI-Lab 的 `start.sh`,但有四处**故意不一样**:

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

照抄 V4-Flash 的写法会**静默失效**。验证方法:thinking 关掉时 `reasoning_content` 应为空。

> ⚠️ **未解决**:`enable_thinking: true` 时 `reasoning_content` **也是空的**,
> 而且会一路生成到 token 上限(`finish=length`)。推测 `--reasoning-parser qwen3`
> 不匹配 Qwen3.8 的思考格式,思考内容混进了 `content`。
> **日常用 thinking off 无影响**;要开思考需要另找 parser。

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

## 6. 客户端切换(Qwen Code)

两个模型都已进 `modelProviders`,**会话内用 `/model` 实时切换,不用改配置**。
需要改配置的只有**启动默认**:

```bash
./scripts/qwen-model-switch.sh qwen38     # 启动默认 → Qwen3.8-27B  :8888
./scripts/qwen-model-switch.sh v4flash    # 启动默认 → V4-Flash     :8000
./scripts/qwen-model-switch.sh status     # 看三处配置现在各指向哪
```

### 6.1 为什么需要脚本而不是手改

Qwen Code 的**启动路径根本不读 `modelProviders`**(那只在交互式 `/model` 里可达),
启动默认散落在三个文件里且必须一致:

| 文件 | 字段 | 备注 |
|---|---|---|
| `~/.qwen/settings.json` | `security.auth.baseUrl` | ⚠️ **这个才是真正生效的端点** |
| `~/.qwen/settings.json` | `model.name`、`model.baseUrl` | `model.baseUrl` 只是选择器元数据,**不是连接设置** |
| `~/.qwen/settings.json` | `model.generationConfig.contextWindowSize` | ⚠️ **必须跟着模型切**,见下 |
| `<repo>/.qwen/settings.json` | `model.name`、`...contextWindowSize` | repo 级**覆盖**全局,两个字段都要改 |
| `<repo>/.qwen/.env` | `OPENAI_MODEL`、`OPENAI_BASE_URL` | gitignored,settings 被覆盖时的兜底 |

只改 `model.baseUrl` 而漏掉 `security.auth.baseUrl`,CLI 会 fallback 到
阿里 DashScope 然后 401。

**`contextWindowSize` 必须随模型切换,不能写死**:

| 模型 | 值 | 原因 |
|---|---|---|
| `deepseek-v4-flash` | **1000000** | CLI 匹配 `deepseek-v4*` 会**预留 384000 输出 token**(`contextLimit = max(0, contextWindowSize - 384000)`)。任何小于 ~384k 的值(含未设置时的 131072 默认)都会把硬阈值夹到 **0**,导致**每个请求**都报 `hard limit: 0`——哪怕只有 4k 提示词 |
| `qwen38-27b` | **262144** | 服务端只接受 262144。实测**不**命中 384k 预留规则(repo 内/外两条路径都验证过),所以 262144 安全 |

写死 1000000 然后切到 qwen38 → CLI 会发出服务端拒收的超长请求;
写死 262144 然后切回 V4-Flash → 触发 hard-limit-0,**全部请求失败**。
`scripts/qwen-model-switch.sh` 会把这个字段和模型一起翻转(全局 + repo 两处)。

### 6.2 换机器时:重建客户端配置

`~/.qwen/settings.json` 是**机器本地**的,不在 repo 里。新机器上需要先建好骨架
(下面是最小可用版,`$version: 4`):

```jsonc
{
  "security": { "auth": {
      "selectedType": "openai", "apiKey": "dummy",
      "baseUrl": "http://100.97.87.120:8888/v1"     // 载荷端点,随切换脚本变
  }},
  "model": {
    "name": "qwen38-27b",
    "baseUrl": "http://100.97.87.120:8888/v1",
    "generationConfig": { "timeout": 300000, "maxRetries": 8,
                          "contextWindowSize": 262144 }   // 随模型切换,见上表
  },
  "modelProviders": { "openai": [
    { "id": "qwen38-27b", "name": "Qwen3.8-27B NVFP4 (DGX Spark S1, single-node :8888)",
      "envKey": "DGX_SPARK_API_KEY", "baseUrl": "http://100.97.87.120:8888/v1",
      "generationConfig": { "timeout": 300000, "maxRetries": 8, "contextWindowSize": 262144 } },
    { "id": "deepseek-v4-flash", "name": "DeepSeek-V4-Flash (DGX Spark, dual-node :8000)",
      "envKey": "DGX_SPARK_API_KEY", "baseUrl": "http://100.97.87.120:8000/v1",
      "generationConfig": { "timeout": 300000, "maxRetries": 8, "contextWindowSize": 1000000 } }
  ]},
  "env": { "DGX_SPARK_API_KEY": "dummy" },
  "$version": 4
}
```

> 注意上面**两个模型的 `contextWindowSize` 不同**(qwen38 = 262144,
> deepseek = 1000000),原因见 §6.1 的表格 —— 顶层 `model.generationConfig` 里的那个
> 要跟着**当前启动默认**走,用 `scripts/qwen-model-switch.sh` 翻转即可,别手填。
> `timeout: 300000` 是因为 Mac↔DGX 的 Tailscale 被迫走 DERP(hkg) 中继。

---

## 6.3 codex CLI

```bash
codex --profile qwen38     # → S1 :8888, qwen38-27b
codex --profile dgx        # → V4-Flash :8000(S2 恢复后)
codex                      # 默认不变:ChatGPT 免费额度 gpt-5.5
```

⚠️ **codex 的 `/model` 不能跨 provider 切换**(只能在当前 provider 内换模型和档位),
所以换后端必须**重启**并带 `--profile`。这点和 Qwen Code 不同 —— 后者 `/model` 能跳 provider。

配置文件(**机器本地,不在 repo 里**,换机器要重建):

| 文件 | 作用 |
|---|---|
| `~/.codex/qwen38.config.toml` | profile overlay:model、provider、档位 |
| `~/.codex/qwen38-models.json` | model catalog:窗口 262144、档位枚举、base_instructions |

**照搬 `dgx.config.toml` 的"catalog 说话"结构**,不要用 `model_context_window`
——那个键对压缩阈值不起作用。catalog 直接从 `dgx-models.json` 派生(保留其
17,730 字符的 base_instructions),只改 slug / 窗口 / 档位 / 显示名:

```bash
python3 - <<'PY'
import json, os
d = json.load(open(os.path.expanduser("~/.codex/dgx-models.json")))
m = d["models"][0]
m["slug"] = "qwen38-27b"
m["context_window"] = m["max_context_window"] = 262144   # ×95% = 249,036,卡在服务端 262144 内
m["display_name"] = "Qwen3.8-27B NVFP4 (DGX Spark S1)"
m["default_reasoning_level"] = "medium"
m["supported_reasoning_levels"] = [{"effort": e, "description": e} for e in
                                   ["none","low","medium","high","xhigh"]]
json.dump(d, open(os.path.expanduser("~/.codex/qwen38-models.json"), "w"), indent=2, ensure_ascii=False)
PY
```

provider 段的三个要点:

```toml
[model_providers.qwen38]
base_url = "http://100.97.87.120:8888/v1"
env_key  = "LOCAL_LLM_API_KEY"   # dummy,~/.zshrc 导出;vLLM 没设 --api-key 但 codex 仍要求能解析
wire_api = "responses"           # codex 0.142+ 删掉了 "chat",必须用 responses
```

**前提已验证**::8888 确实提供 `/v1/responses`(HTTP 200,`/openapi.json` 路由表里也有)。
这是能否接入 codex 的先决条件 —— 不是所有推理服务都开 Responses API。

### reasoning effort 档位(实测枚举,别信服务端报错文本)

直接打 `/v1/responses` 探测的结果:

| 档位 | 结果 |
|---|---|
| `none` | ✅ 200,**thinking 完全关闭**(reasoning_chars=0) |
| `low` / `medium` / `high` / `xhigh` | ✅ 200(`xhigh` 是服务端默认) |
| `minimal` / `max` | ❌ 400 拒绝 |

⚠️ 服务端的 400 报错写的是 *"Supported types are xhigh (default), medium, and low"*,
**漏了 `high` 和 `none`**,但这两个实测都返回 200。**以实测为准。**

**各档位实际开销**(同一个 merge_intervals 编码题,`max_output_tokens=2000`):

| 档位 | 墙钟 | 输出 tok | reasoning 字符 | 答案字符 |
|---|---|---|---|---|
| `none` | **7.9s** | 195 | 0 | 793 |
| `low` | 12.3s | 305 | 513 | 686 |
| `medium` | **13.0s** | 322 | 400 | 761 |
| `xhigh` | **36.7s** | 540 | 1554 | 723 |

**`xhigh` 花掉 4.6 倍时间,答案长度却几乎一样**(723 vs 793 字符)。
`low` 和 `medium` 实际上差不多(12.3 vs 13.0s)。

> 注意这里和 V4-Flash **不同**:那个 jasl fork 的编码器只在 `reasoning_effort == 'max'`
> 时注入前缀,所以 low/medium/high **三档完全等价**(见 `~/.codex/dgx.config.toml` 的注释)。
> Qwen3.8 走的是上游 vLLM,**各档位是真的有差别**,别把 dgx 那套结论套过来。

本 profile 默认取 **`medium`**(约 none 的 1.65 倍开销):这台引擎只有 ~25 tok/s,
服务端默认的 `xhigh` 在交互式写代码时体感很差。要更快在 `/model` 里切 `none`
(彻底关思考,最快),要更深切 `xhigh`。

> 💡 顺带修正了 §5.2 记的那个"thinking 开着却拿不到 reasoning"的问题:
> 那是 **`/v1/chat/completions` + `chat_template_kwargs` 这条路径**的现象。
> 走 **`/v1/responses`** 时 reasoning 被正确分离到 `type:"reasoning"` 的输出项里
> (codex 用的正是这条路径,所以不受影响)。

---

## 7. 恢复流程(V4-Flash 回归)

**两栈互斥** —— V4-Flash 需要两台各 ~83GB,qwen38 占着 S1 的 ~91GB。**必须先停后起。**

### 7.1 当前已做的封锁

S1 上 `k3s-agent` 已 `systemctl disable --now`,因此:

- v4flash-leader(`nodeSelector: spark-ccf3`,即 S1)**无法落地** → 不会抢内存
- 即使 S1 重启也不会自启(已 `disable`)
- 副作用:S1 上所有 k8s 负载(cilium/coredns 等)也停了 —— S2 死着时本就无意义

### 7.2 S2 回来后的步骤

```bash
# 1) 先取证:日志戛然而止=断电,有 panic 栈=软件问题
ssh admin@100.67.164.92 'last -x | head -5; sudo journalctl -b -1 -e --no-pager | tail -50'

# 2) 停掉降级栈,把 S1 的内存还回来
make qwen38-stop

# 3) 恢复 S1 的 k3s 节点
ssh admin@100.97.87.120 'sudo systemctl enable --now k3s-agent'

# 4) 等两节点 Ready 且 GPU 重新注册(约 30~50s),再拉起主栈
make v4flash-status          # 两个 node 都 Ready 再往下
make v4flash-run             # 两个 rank 一起,约 5 分钟加载
make v4flash-test

# 5) 客户端切回
./scripts/qwen-model-switch.sh v4flash
```

> ⚠️ **绝不要只重启一个 rank**(僵尸 TP 组:存活方永久卡在 collective 里,
> 但 `/health` 和 `/v1/models` 照常返回 200)。用 `make v4flash-restart`。
> 详见 CLAUDE.md「A single-rank restart creates a zombie TP group」。

> ⚠️ 步骤 3 之后 k3s 会按 `replicas: 1` 自动拉起 V4-Flash。
> 如果你想让它保持停止,先 `make v4flash-stop`(scale 到 0)再 enable k3s-agent。

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
