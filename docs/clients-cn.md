# 客户端接入(codex / Qwen Code)

> 从 `CLAUDE.md` 拆出(2026-08-15)。**客户端配置文件都在各自机器的家目录里,
> 不在本 repo 内** —— 换机器需要照本文重建。

两套服务都是**无鉴权**的 vLLM;未设 `--api-key` 时 vLLM 接受任意 key
(但客户端仍然要求能解析到一个非空值,所以到处用 `dummy`)。

| 栈 | 端点 | served name | 状态 |
|---|---|---|---|
| V4-Flash(主) | `100.97.87.120:8000` | `deepseek-v4-flash` | 双节点,需两台都在 |
| Qwen3.8-27B(降级) | `100.97.87.120:8888` | `qwen38-27b` | S1 单机 |

两者都提供 `/v1/chat/completions` **和** `/v1/responses`。

---

## codex CLI

```bash
codex --profile dgx          # → :8000  deepseek-v4-flash
codex --profile qwen38       # → :8888  qwen38-27b(降级栈)
codex --profile dgx-direct   # 同 :8000(Bifrost 已退役,保留是习惯问题)
codex                        # 默认不变:ChatGPT 免费额度 gpt-5.5
```

⚠️ **codex 的 `/model` 不能跨 provider 切换**(只能在当前 provider 内换模型和档位),
换后端必须**重启**并带 `--profile`。这点和 Qwen Code 不同。

### 配置结构:让 catalog 说话

Profile V2 的 overlay 文件是 `~/.codex/<name>.config.toml`,每个自带
`[model_providers.<name>]`。**不要用 `model_context_window`** —— 那个键对压缩阈值
不起作用;窗口要交给 `model_catalog_json`。

三个必须写对的 provider 字段:

```toml
[model_providers.qwen38]
base_url = "http://100.97.87.120:8888/v1"
env_key  = "LOCAL_LLM_API_KEY"   # dummy,~/.zshrc 导出;所有本地服务共用一个
wire_api = "responses"           # codex 0.142 删掉了 "chat",必须用 responses
```

> `wire_api` 的前提是服务端真的提供 `/v1/responses`。**不是所有推理服务都开这个 API**
> —— 接入任何新后端前先 `curl` 验证(:8000 和 :8888 都已验证 200)。

catalog 的作用是消除 `Model metadata for <slug> not found. Defaulting to fallback
metadata` 警告 —— 否则 codex 会拿 GPT-5 的 `272000×95%=258400` 当窗口,
可能超出服务端上限。qwen38 的 catalog 直接从 dgx 的派生(保留其 17,730 字符
base_instructions),生成方法见 `docs/qwen38-27b-fallback-cn.md` §6.3。

### reasoning effort:两套栈的档位语义完全不同

**V4-Flash(jasl fork)——只有最高档有效:**

编码器 `vllm/tokenizers/deepseek_v4_encoding.py` 是 preview 时期的副本,
它**只在 `reasoning_effort == "max"` 时注入前缀**,而且它的 `assert` 不触发,
所以其它所有值——包括 `"high"` 和拼错的值——都是**静默空操作**。

用 `/tokenize` 实测(同一条消息,thinking 开启):

| `chat_template_kwargs` | prompt tokens |
|---|---|
| `{"thinking":true}` / `+"low"` / `+"high"` / `+"bogus"` | 10 |
| `{"thinking":true,"reasoning_effort":"max"}` | **89**(+79 token 前缀) |

所以想让它多想就发 `"max"`;照抄 eugr 的 `reasoning_effort=high` 在这里等于没开。
我们的 `"max"` 注入的正是 0731 官方表里叫 `high` 的那段文本;0731 真正的 `max`
前缀在引擎更新编码器之前拿不到。

> codex 侧对应写 `model_reasoning_effort = "xhigh"`(`/v1/responses` 的枚举只到
> xhigh,发 `max`/`ultra` 会被 400 拒掉)。详见 `~/.codex/dgx.config.toml` 注释。

**Qwen3.8-27B(上游 vLLM)——各档位是真的有差别:**

| 档位 | 结果 | 墙钟(同一编码题) |
|---|---|---|
| `none` | ✅ thinking **完全关闭** | **7.9s** |
| `low` | ✅ | 12.3s |
| `medium` | ✅(本 profile 默认) | **13.0s** |
| `high` | ✅ | — |
| `xhigh` | ✅(服务端默认) | **36.7s** |
| `minimal` / `max` | ❌ 400 拒绝 | — |

⚠️ 服务端的 400 报错文本写的是 *"Supported types are xhigh (default), medium, and low"*,
**漏了 `high` 和 `none`**,但这两个实测都返回 200。**以实测为准。**

`xhigh` 花 4.6 倍时间、答案长度却几乎一样,在这台 ~25 tok/s 的引擎上不划算。

---

## Qwen Code CLI

```bash
qwen                                        # 用当前启动默认
./scripts/qwen-model-switch.sh qwen38       # 切启动默认 → :8888
./scripts/qwen-model-switch.sh v4flash      # 切启动默认 → :8000
./scripts/qwen-model-switch.sh status       # 看各文件现在指向哪
```

**会话内切换不用脚本** —— 两个模型都在 `modelProviders` 里,`/model` 可实时跳
provider(这点比 codex 强)。

### 为什么切换必须用脚本

启动路径**根本不读 `modelProviders`**(那只在交互式 `/model` 里可达),
启动默认散落在四个地方且必须一致:

| 文件 | 字段 | 备注 |
|---|---|---|
| `~/.qwen/settings.json` | `security.auth.baseUrl` | ⚠️ **这个才是真正生效的端点** |
| `~/.qwen/settings.json` | `model.name`、`model.baseUrl` | `model.baseUrl` 只是选择器元数据,**不是连接设置** |
| `~/.qwen/settings.json` | `model.generationConfig.contextWindowSize` | ⚠️ 必须随模型切,见下 |
| `<repo>/.qwen/settings.json` | `model.name`、`...contextWindowSize` | repo 级**覆盖**全局 |
| `<repo>/.qwen/.env` | `OPENAI_MODEL`、`OPENAI_BASE_URL` | gitignored,兜底 |

只改 `model.baseUrl` 而漏掉 `security.auth.baseUrl`,CLI 会 fallback 到
阿里 DashScope 然后 401。

### `contextWindowSize` 的 hard-limit-0 陷阱

CLI 会按模型名匹配并**预留输出 token**:`contextLimit = max(0, contextWindowSize - reserve)`。

| 模型 | 必须写 | 原因 |
|---|---|---|
| `deepseek-v4-flash` | **1000000** | 匹配 `deepseek-v4*` → 预留 **384000**。任何小于约 384k 的值(含未设置时的 131072 默认)都会把硬阈值夹到 **0**,导致**每个请求**都报 `hard limit: 0; compression NOOP`——**哪怕只有 4k 提示词** |
| `qwen38-27b` | **262144** | 服务端只接受 262144。实测**不**命中 384k 预留(repo 内/外两条路径都验证过) |

写死 1000000 然后切到 qwen38 → CLI 会发出服务端拒收的超长请求;
写死 262144 然后切回 V4-Flash → 触发 hard-limit-0,**全部请求失败**。
`scripts/qwen-model-switch.sh` 会把这个字段和模型一起翻转(全局 + repo 两处)。

### thinking 开关

两套栈的 kwarg 名**不一样**,照抄会静默失效:

| 栈 | 关闭 thinking |
|---|---|
| V4-Flash | `chat_template_kwargs: {"thinking": false}` |
| Qwen3.8-27B | `chat_template_kwargs: {"enable_thinking": false}` |

⚠️ codex/qwen 内置的 `reasoning:false` **只对 `api.deepseek.com` 生效**,
对自建 vLLM 无效——必须通过客户端的 extra-body 注入上面的 `chat_template_kwargs`。

> Qwen3.8 走 `/v1/chat/completions` 时,即使 `enable_thinking:true` 也拿不到
> `reasoning_content`(疑似 `--reasoning-parser qwen3` 不匹配 3.8 的格式)。
> 走 **`/v1/responses`** 则正常分离到 `type:"reasoning"` 输出项——codex 用的是后者,
> **不受影响**。

---

## 换机器时重建

两个 CLI 的配置都在家目录,**不随 repo 走**:

- **codex**:`~/.codex/<name>.config.toml` + `~/.codex/<name>-models.json`,
  外加 `~/.zshrc` 里 `export LOCAL_LLM_API_KEY=dummy`。
  qwen38 的完整重建步骤(含生成 catalog 的 python)见
  `docs/qwen38-27b-fallback-cn.md` §6.3。
- **Qwen Code**:`~/.qwen/settings.json`,最小可用骨架见
  `docs/qwen38-27b-fallback-cn.md` §6.2。repo 内的 `.qwen/.env` 是 gitignored 的。
