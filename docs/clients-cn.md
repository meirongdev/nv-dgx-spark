# 客户端接入(codex / Qwen Code)

> 从 `CLAUDE.md` 拆出(2026-08-15)。**客户端配置文件都在各自机器的家目录里,
> 不在本 repo 内** —— 换机器需要照本文重建。

两套服务都是**无鉴权**的 vLLM;未设 `--api-key` 时 vLLM 接受任意 key
(但客户端仍然要求能解析到一个非空值,所以到处用 `dummy`)。

<!-- BEGIN generated:clients -->
| 栈 | 端点 | served name | 关思考的 kwarg | CoT 字段 | ctxWindow |
|---|---|---|---|---|---|
| **qwen38un(主)** | `100.97.87.120:8888` | `qwen3.8-27b-sglang` | `{"enable_thinking": false}` | `reasoning_content` | 262144 |
| fndgx | `100.67.164.92:18300` | `qwen3.8-flash-next` | `{"enable_thinking": false}` | `reasoning` | 262144 |
| gemma | `127.0.0.1:8000` | `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4` | `{"enable_thinking": false}` | `reasoning_content` | 262144 |
| glm53 | `100.97.87.120:8888` | `GLM-5.3-Flash-EXL3` | `{"reasoning_effort":"low"}` ⚠️ **关不掉**,这是最低档 | `reasoning` | 850000 |
| omlx | `127.0.0.1:8000` | `mlx-community__Qwen3.6-35B-A3B-nvfp4` | `{"enable_thinking": false}` | `reasoning_content` | 262144 |
| qwen38 | `100.97.87.120:8888` | `qwen38-27b` | `{"enable_thinking": false}` | `reasoning_content` | 262144 |

> ⚠️ **关思考的 kwarg 和 CoT 字段逐栈都不同,而且写错都是静默的**(gotcha #9)。
> 上表由 `make stack-table` 从 `stacks/*/stack.env` 生成 —— 不要手改这里,改注册表。
<!-- END generated:clients -->

⚠️ **端口已经区分不了后端** —— `:8888` 有三个栈共用,`:8000` 两个。
**只能看 served name。** `make info STACK=<id>` 打印某个栈的完整身份,
`make stacks` 打印全表。

⚠️ **历史上最容易搞混的一对是 `fndgx` 和 `qwen38fn`**(后者已于 2026-09-20 随 k3s
删除,所以不再出现在上表里 —— 但它的 served name 可能还留在别人的旧配置里):

| | `qwen38fn` | `fndgx` |
|---|---|---|
| served name | `qwen38-flash-next` | `qwen3.8-flash-next` ← 只差一个点 |
| 端点 | `100.97.87.120:8000` | `100.67.164.92:18300` |
| CoT 字段 | `reasoning_content` | **`reasoning`** |

它们是**同一个模型的两种装法**(TP=2 两台 / 单机 PLE-mmap),但 CoT 字段不同 ——
差别来自引擎构建,不是模型。读错字段的表现是「一个字都没有」,与「思考没生效」
完全同形(gotcha #9)。`fndgx` 那一格是 2026-09-20 对着活端点实测的:
`reasoning_content` 恒为 `None`。
⚠️ **`qwen38fn` 已于 2026-09-20 随 k3s 一起删除**,那一格再也无法复验,只能当作
历史记录。留着它是因为教训比栈活得久:**同一个模型换个引擎构建,CoT 字段就可能
变,而且不会报错。**

✅ `fndgx` 另有一个**本表没有**的旋钮:`reasoning_effort`(模板档位 `low`/`medium`/
`xhigh`,不传即 `xhigh`)。它同时接受顶层 `reasoning_effort` —— 包括 codex /
Claude Code 发的 `high` 和 `max` —— 因为上游 `serve.sh` 的 `EFFORT_ALIAS=1` 会把
它们改写成 `xhigh`。**没有这层改写,那些请求会 400**,而它只是启动期一行 warning。
`make test STACK=fndgx` 第 3 项专门守这条。

> ⚠️ **端口 8000 在两处都用**:`100.97.87.120:8000` 是 DGX,`127.0.0.1:8000` 是 Mac
> 本地的 omlx。2026-09-02 发现全局 qwen 配置曾处于
> `security.auth.baseUrl=127.0.0.1:8000`(omlx)+ `model.name=deepseek-v4-flash`(DGX 模型)
> 的自相矛盾状态 —— omlx 不提供那个模型,启动即 404。**改端点时先看主机名。**

两者都提供 `/v1/chat/completions` **和** `/v1/responses`。

---

## codex CLI

```bash
codex --profile dgx          # → :8888  qwen3.8-27b-sglang(2026-09-19 起,主力,S1)
codex --profile fndgx        # → :18300 qwen3.8-flash-next(2026-09-20 起,单机,S2)
codex --profile qwen38       # → :8888  qwen38-27b(⚠️ 与 dgx 抢同一个端口,见下)
codex --profile litellm      # → llm.meirong.dev 网关 → custom_dgx/qwen3.8-27b-sglang
codex --profile mac          # → 同一个网关,但点名 Mac 兜底模型 mac/ornith
codex --profile local        # → 127.0.0.1:8000  Mac 本地 omlx(gemma-4 26B QAT)
codex --profile m2           # → 100.89.15.120:8000  M2 那台的 omlx(不经 DGX)
codex                        # 默认:ChatGPT 额度;A 的 config.toml 写 gpt-5.5,B 的写 gpt-5.4-mini
```

⚠️ **订正(2026-09-20 23:15,在机器 B 上):这一节原先写的"`qwen38` / `litellm` / `mac`
三个 profile 在本机并不存在",在 B 上是错的 —— 三个文件都在 B 的盘上,而且都早于那句"复核"。**
(那句"复核"是在机器 A 上做的,在 A 上它**是对的** —— 见下面的「两套 `~/.codex`」。)
`stat` 出生时间:`qwen38.config.toml` **2026-08-15**、`mac.config.toml` **2026-08-16**、
`litellm.config.toml` **2026-09-09**。也就是说,写下"复核发现不存在"的那一刻,
它们已经躺在 `~/.codex` 里一到五周了。
**这是本节第三次同型事故,教训因此再收紧一格:不要写"复核发现 X 不存在",
贴 `ls -la` / `stat` 的原文。** 一句没有输出撑着的"复核"和没复核完全等价。

⚠️ **其中 qwen38 那条教训适用于任何指向 `:8888` 的 profile,而且失败是静默的。**
`qwen38` 和主力 `qwen38un` 都占 S1 的 `:8888`(互斥),当前跑的是 `qwen38un`;
而 SGLang **什么模型名都收**(gotcha #10)—— 2026-09-20 实测往 `:8888` 发
`model="qwen38-27b"` 拿到 **200 并原样回显该名字**,实际回答的是 uncensored 那个栈。
用它之前必须先 `make run STACK=qwen38` 并 `curl :8888/v1/models` 核对真身。

🧹 **2026-09-20 客户端清理**(`~/.codex` 不进 git,记在这里免得再漂)

⚠️ **先说一条元教训:这一节的上一版记的清理,磁盘上并没有发生。**
2026-09-20 22:49 在机器 A 上逐个文件复核,发现本节当时声称的状态里有五处与 A 的磁盘不符
(其中 `*-models.json` 那几处,后来查明是 B 上的真实布局 —— 见下面「两套 `~/.codex`」):
它说"已删除"的 `bifrost.config.toml` **还在**,说"早就不在任何配置文件里"的
`[model_providers.bifrost]` **还在 `config.toml` 里**,而它点名的
`dgx-models.json` / `qwen38-models.json` / `fndgx-models.json` / `litellm-models.json`
在 A 上**全盘不存在**(`find ~ -maxdepth 4` 查过,`CODEX_HOME` 也确认未设置)。
**写下"已清理"和"确实清理了"是两件事;`~/.codex` 不进 git,没有任何东西会
替你发现二者不一致。** 下次改完请贴实测输出,别贴意图。

⚠️ **`~/.codex` 至少有两套,分属两台客户端 Mac —— 这一节反复"订正"的根因就在这里
(2026-09-26 合并时查明)。** A = `Matthews-MacBook-Pro`(09-20 清理与 09-21 catalog
修复都在这台做);B = 另一台(ce00239 / 8c04ba5 在那台实测,主机名未记录)。两边各自
`stat`、各自"复核",**各自都对,错的只是把"本机"当成了"所有机器"**:A 上
`find ~ -maxdepth 4` 找不到 B 的 `qwen38` / `litellm` / `mac` 三个 overlay 和任何
`*-models.json`(2026-09-26 重跑,仍为空);B 上则没有 A 那份共用的 `models.json`。
**以后写这一节,先写清是哪台机器。**

**A(`Matthews-MacBook-Pro`)的实测布局**(2026-09-26 `ls -la` + `grep`):
- overlay 四个:`dgx` / `fndgx` / `local` / `m2`。`m2` 的 `model` 是
  `mlx-community__Qwen3.6-35B-A3B-nvfp4`,默认 `codex` 是 `gpt-5.5`。
- catalog 是**一份共用的** `~/.codex/models.json`(三条:`qwen3.8-27b-sglang`、
  `qwen3.8-flash-next`、`mlx-community__Qwen3.6-35B-A3B-nvfp4`)。
- ⚠️ **(2026-09-21 推翻)** 09-20 这里写的是"没有任何 profile 写 `model_catalog_json`,
  四个 profile 共用 `~/.codex/models.json`"。前半句是事实,后半句是**错的推论**:
  codex 0.155.1 **根本不会自动读** `~/.codex/models.json`(它自带 bundled catalog),
  所以那份文件当时对**任何** profile 都没有生效 —— 不是"共用",是"都没用上"。
  现状:`dgx` / `fndgx` 两个 profile 各写一行 `model_catalog_json` 指向它;
  `local` / `m2` 仍然没有,它们至今在吃 fallback 元数据。详见下面「调思考深度」一节。

**B 的实测布局**(2026-09-20 23:15 重测:逐个 `tomllib.load` + `stat`,不是凭印象):

| overlay | `model` | `model_provider` → `base_url` | `model_catalog_json` | effort |
|---|---|---|---|---|
| `dgx.config.toml` | `qwen3.8-27b-sglang` | `dgx` → `100.97.87.120:8888/v1` | `dgx-models.json` | `none` |
| `fndgx.config.toml` | `qwen3.8-flash-next` | `fndgx` → `100.67.164.92:18300/v1` | `fndgx-models.json` | `medium` |
| `qwen38.config.toml` | `qwen38-27b` | `qwen38` → `100.97.87.120:8888/v1` | `qwen38-models.json` | `medium` |
| `litellm.config.toml` | `custom_dgx/qwen3.8-27b-sglang` | `litellm`(provider 定义在 `config.toml`) | `litellm-models.json` | `medium` |
| `mac.config.toml` | `mac/ornith` | `litellm`(同上) | (无) | `high` |
| `local.config.toml` | `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4` | `local-omlx` → `127.0.0.1:8000/v1` | (无) | (未设) |
| `m2.config.toml` | `gpt-5.5` | `m2` → `100.89.15.120:8000/v1` | (无) | `high` |

- **B 上是七个 overlay。**`-p/--profile` 的官方语义(`codex --help`,0.155.1)是
  "Layer `$CODEX_HOME/<name>.config.toml` on top of the base user config" ——
  **建个文件就是建个 profile**,`config.toml` 里不需要也没有任何 `[profiles.*]` 段。
- B 上**没有** `~/.codex/models.json`,四个 profile 各写各的 `model_catalog_json`
  (上表第四列),所以 B 的 `/model` 选单是**按 profile 隔离**的:`dgx` 里只有
  `qwen3.8-27b-sglang`,`fndgx` 里只有 `qwen3.8-flash-next`。
  `local` / `m2` / `mac` 没有 catalog,走 codex 的 fallback 元数据。
  ⚠️ 这正是 A 上 09-21 那个 bug 的解法 —— B 早就是这么配的。
- ⚠️ 两台机器上,`dgx` 和 `qwen38`(B 有)**都指向同一个 `100.97.87.120:8888`**,而那个端口
  同一时刻只有一个栈在跑(当前是 `qwen38un`)。加上 gotcha #10(SGLang 什么模型名都收),
  **选错的表现是 200 + 原样回显,不是报错。** 见上面那条警告。

**本次实际删掉的东西(都指向 2026-09-20 随 k3s 删除的 `qwen38fn` / `v4flash`):**
- 两台机器各删了一次 `qwen38-flash-next` 和 `deepseek-v4-flash` 两条:A 删在共用的
  `~/.codex/models.json`(现存三条,2026-09-26 复核),B 删在 `~/.codex/dgx-models.json`
  (删前的三条留在 B 的 `dgx-models.json.bak-20260920-223027` 里)。
  ⚠️ ce00239 在这里写过"`models.json` 从来不存在" —— 那是 B 的事实,A 上它一直在。
  后者尤其危险:它的 `context_window` 写着 65536 而 `bifrost.config.toml` 里写
  1000000,两处从来没对齐过;而 `:8888` 是 SGLang(收任何模型名),在 `/model` 里
  选中它不会报错,只会拿一个错的压缩阈值去打一个 262144 的服务端。
  现在 B 的 `dgx-models.json` 只剩 `qwen3.8-27b-sglang` 一条,四份 catalog 各只有一条
  (见 B 的表);A 的 `models.json` 剩上面列的三条。
- `~/.codex/deepseek.config.toml` 整个删除:模型是已删的 `deepseek-v4-flash`,
  而且它声明的 `model_provider = "deepseek-local"` **全盘没有任何地方定义过** ——
  这个 profile 无论集群侧是什么状态都起不来。
- `~/.codex/bifrost.config.toml` 整个删除,并从 `config.toml` 里移除
  `[model_providers.bifrost]`:网关 2026-08-08 退役,模型 `custom_dgx/deepseek-v4-flash`
  所在的栈也已删除。`~/.zshrc` 里的 `export BIFROST_VK=…` 与
  `alias codex-dgx='codex --profile bifrost'`(该 alias 已因上面这步而失效)
  也已于同日**一并删除** —— 打 DGX 直接用 `codex --profile dgx` / `--profile fndgx`,
  不再留中间别名。
  ⚠️ 删 env 不等于吊销 key:`sk-bf-…` 这个值仍留在 `~/.zshrc.bak-*` 等备份里,
  要彻底清除得连备份一起处理(网关已退役,故未处理)。
- `~/.qwen/settings.json` 的 `modelProviders` 删掉 `qwen38-flash-next`
  @ `100.97.87.120:8000`。**这条是最值得删的一条**:它与在跑的 `qwen3.8-flash-next`
  只差一个点(见下面 fndgx 一节),而 `:8000` 已实测不可达 —— 选错只会连到一个死端点。
- `~/.codex/dgx.config.toml` 的回滚注释:原文教人回滚到 `qwen38fn`(`:8000` +
  `make qwen38fn-run`),那个栈已删除,那种 make 动词形式也已不存在。改成现存的
  两条路径(`glm53` 要停两个栈;`qwen38` 不用停 `fndgx`)。

**删完的实测验证**(不是只看配置 —— 这是本仓库的规矩):
- `:8888/v1/models` → 200 `qwen3.8-27b-sglang`;`:18300/v1/models` → 200
  `qwen3.8-flash-next`;`127.0.0.1:8000` → 200(omlx 在跑,gemma / Qwen3.6 两条都在)。
- 已删的 `100.97.87.120:8000` → **不可达**,证实那条 catalog 确实是死的。
- 重放 `--profile dgx` 会发的真实请求(`POST /v1/responses`,effort=medium)→
  **HTTP 200**,`model` 原样回显,`output` 是规矩的 `reasoning` + `message` 两段。
- 四个 `*.config.toml` 全部 `tomllib` 解析通过;`scripts/qwen-model-switch.sh status`
  三处启动字段一致。
- 改动前的每个文件都留了 `*.bak-20260920-224938`,整体删除的两个 profile 留了
  `*.removed-20260920-224938`。

- ℹ️ 一条仍然有效、但**在 A 上无法复核**的观察(它来自 litellm 网关路径,而那个
  profile 只在 B 上有):补 catalog 前 codex 会把思考过程当正文打在终端上,
  看起来像「网关把 CoT 塞进了正文」。抓原始响应看**不是** —— 网关返回的是规矩的
  `type:"reasoning"` + `type:"message"` 两个 output item,和直连同构;是没有 catalog
  时 codex 按 fallback metadata 去**渲染**了 reasoning item。
  **终端上看到 CoT,说明的是客户端元数据,不是服务端返回格式。**

> **2026-09-19 实测 effort 枚举(27B-Uncensored / SGLang)** —— 与 Flash-Next
> **相同**,但仍是实测,不是照抄(这几个栈的枚举互不相同过):
>
> | 值 | 结果 |
> |---|---|
> | `none` `low` `medium` `xhigh` | ✅ 200 |
> | `minimal` `high` `max` | ❌ 400 |
>
> 服务端原话:`Supported types are xhigh (default), medium, and low`。
> 同一道编码题(LRU cache + 三个单测,n=1):
> `none` 9.7s/正文1767字符、`low` 19.2s/2295、`medium` 24.5s/**2513**、
> `xhigh` 35.3s/1581(**67% 预算花在思考,正文最短**)。故默认 `medium`。
>
> ⚠️ **本栈 catalog 的 slug 是 `qwen3.8-27b-sglang`(带点)**,与 `qwen38-*`
> 不同形。Qwen Code 的 384k 输出预留是按模型名匹配的,**2026-09-19 实测本名
> 不命中**(真发请求验过,不是只看配置)—— 见下面「Qwen Code」一节。

> **2026-09-02 实测的 reasoning effort 枚举(本栈)** —— 与 V4-Flash、也与下面
> qwen38-27b 那张表**都不同**,别跨栈照抄:
>
> | 值 | 结果 |
> |---|---|
> | `none` `low` `medium` `xhigh` | ✅ 200 |
> | `minimal` `high` `max` | ❌ 400 |
>
> ⚠️ `high` 在本栈是**被拒**的(qwen38-27b 上却是 200)。同一道编码题的实测
> (n=1,内容驱动方差大):`none` 5.3s/正文1101字符、`low` 14.5s/2081、
> `medium` 18.6s/2574、`xhigh` 15.8s/**仅782**(72% 的 token 花在思考上)。
> 故 `dgx.config.toml` 默认 `medium`。
>
> ⚠️ 窗口靠 **catalog 条目的 `context_window`**,**不是** `model_context_window`
> (后者对压缩阈值不起作用)。每条 DGX 条目都写 262144 = 服务端 `--max-model-len`。
> ⚠️ **但"写了就生效"要求 profile 里有 `model_catalog_json`**,codex 0.155.1 不会自动读
> `~/.codex/models.json`。B 上四个 profile 早就各指各的 `<name>-models.json`;
> A 上在 2026-09-21 之前没有任何 profile 指路 —— 262144 一直没落地,压缩阈值吃的是
> fallback,现在 `dgx`/`fndgx` 都指向共用的 `models.json`。
> (历史:旧的 `deepseek-v4-flash` catalog 写 65536 而 config 写 1000000 —— 一直按
> 64K 在跑,两处从未对齐。该条目已于 2026-09-20 连同 `qwen38-flash-next`
> **实际**从 catalog 删除,并有实测记录,见上面的清理一节。)

⚠️ **codex 的 `/model` 不能跨 provider 切换**(只能在当前 provider 内换模型和档位),
换后端必须**重启**并带 `--profile`。这点和 Qwen Code 不同。

### 配置结构:让 catalog 说话

Profile V2 的 overlay 文件是 `~/.codex/<name>.config.toml`,每个自带
`[model_providers.<name>]`。**不要用 `model_context_window`** —— 那个键对压缩阈值
不起作用;窗口要交给 catalog。⚠️ 但 catalog **必须显式指路**:
`model_catalog_json = "<绝对路径>"`(值是路径),否则 codex 0.155.1 只用自带的
bundled catalog。两台机器的指法不同(见上面的两份布局):
- **A**:`dgx` / `fndgx` 都指向同一份 `/Users/matthew/.codex/models.json`,`local` / `m2`
  还没有。一份文件被多个 profile 指向,加一条就是给这些 profile 都加。
- **B**:每个 profile 一份 `~/.codex/<name>-models.json`,加一条只影响那一个 profile 的
  `/model` 选单 —— 换句话说,**换栈时每份 catalog 都要各改各的**。
⚠️ **它是整体替换,不是合并**:写了它的 profile,`/model` 选单里就只剩这份文件里的
条目(gpt-5.5 之类会消失)。所以**不要写进 `~/.codex/config.toml`** —— 那会让默认的
`codex` 也丢掉自己的元数据。
❌ 同时:`model_max_output_tokens` 在 0.155.1 是 **unknown configuration field**
(`--strict-config` 会报,平时静默忽略),catalog schema 里也没有对应字段。
2026-09-21 已从 A 的 `dgx` / `fndgx` 两个 overlay 删除,别再加回来
(A 的 `local` / `m2` 里还留着,同样不生效)。

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
可能超出服务端上限。新条目的做法是从现有条目派生(保留其 base_instructions),
生成方法见 `stacks/qwen38/runbook-cn.md` §6.3。

### 调思考深度:三条路径(2026-09-21 起前两条才真正可用)

**结论先行**:`dgx` / `fndgx` 两个 profile 现在有三条调档路径,都已实测:

| 路径 | 怎么用 | 生效范围 |
|---|---|---|
| `/model` | 两级选单:模型 → 档位,会标出 `(default)` / `(current)` | 会话内,立刻 |
| `ctrl-up` / `ctrl-down` | 状态栏即时显示当前档 | 会话内,立刻 |
| `-c model_reasoning_effort=<档>` | `codex --profile dgx -c model_reasoning_effort=none` | 本次启动 |

⚠️ **`-c` 不受 catalog 约束**:传 `max` 会**原样发到服务端**,在 `dgx` 上被 400
(`Supported types are xhigh (default), medium, and low`);而在 `fndgx` 上**任何值
都是 200**(见下面的别名表),拼错不会有任何提示。选单和快捷键则只在 catalog 列出的
四档里走。

#### 为什么前两条以前用不了:catalog 根本没被加载

2026-09-21 在 tmux 里跑真实 TUI 抓到的原文:

```
⚠ Model metadata for `qwen3.8-27b-sglang` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
• Reasoning shortcuts are unavailable for qwen3.8-27b-sglang.
```

第二行是按 `ctrl-up` 的回应 —— **按键有反应,但不干活**。根因有两层,都在 codex 侧:

1. **codex 0.155.1 不会自动读 `~/.codex/models.json`。** 它自带一份 bundled
   catalog,自定义那份必须用 `model_catalog_json = "<路径>"` 显式指路。
   ⚠️ 指了路之后它是**整体替换**,不是合并 —— 所以只能写在 profile 里。
2. **catalog 的 schema 变了。** `supported_reasoning_levels` 必须是对象数组:

   ```json
   "default_reasoning_level": "medium",
   "supported_reasoning_levels": [
     { "effort": "none",   "description": "关思考 —— 最快" },
     { "effort": "medium", "description": "默认 —— 速度与正文完整度的平衡点" }
   ]
   ```

   A 上原来写的是裸字符串数组 `["none","low","medium","xhigh"]`,指路之后**整份
   catalog 加载失败**,报 `invalid type: string "none", expected struct
   ReasoningEffortPreset`。两层都修完,警告消失、选单出现四档、`ctrl-up` 生效。

✅ **顺带修好的两件事**(都是同一个根因的副作用):catalog 里的
`context_window = 262144` 终于落地(在此之前压缩阈值一直吃 fallback);
codex 不再发 `reasoning.summary = "auto"` —— 它现在读得到
`supports_reasoning_summaries: false` 了。

#### 全链路抓包:改档到底发出去了什么

本地起一个记录代理(codex → 127.0.0.1 → `:8888`),TUI 里 `ctrl-up` 后再发一条:

```
effort=medium  input_types=['message','message','message']
effort=xhigh   input_types=['message','message','message','reasoning','message','message']   ← ctrl-up 之后
```

✅ 走的是**请求级 `reasoning.effort`**,不是 `configuration_update` input item。
这点必须验:SGLang 对未知 input item 是**硬 400**
(`Unsupported Responses API input item type: 'configuration_update'`),
真走那条路会当场炸掉会话。

⚠️ **`local` / `m2` 两个 profile 至今没有 catalog**,所以它们仍然是
"metadata not found + shortcuts unavailable" 的状态。其中 `m2` 指的
Qwen3.6-35B-A3B 另有一层:2026-09-21 实测 omlx 对 `reasoning.effort`
的 7 个值**全部 200、全部 `reasoning_tokens=0`**,思考过程被当正文吐出来 ——
那一栈的开关是 `chat_template_kwargs.enable_thinking`,不是 effort。

⚠️ **(机器 A)选单里的另外两条是陷阱。** A 的 catalog 是一份共用文件,写了它的 profile 在
`/model` 里会看到全部三条;而 codex 不能跨 provider 切换,选中别的条目只会把那个
**模型名**发给当前 provider 的 `base_url` —— `:8888` 是 SGLang,**什么名字都收**
(gotcha #10),于是静默串台。要根治就给每个 profile 单独一份 catalog 文件 —— 机器 B 就是这么配的。

### reasoning effort:三套栈的档位语义完全不同

**qwen38un / SGLang(当前主力)—— `high` 被拒、`none` 可用:**

2026-09-19 对活的 `:8888` `/v1/responses` 每档实发一次(看 HTTP 码):

| 档位 | 结果 | 墙钟 / 正文长度(同一编码题,n=1) |
|---|---|---|
| `none` | ✅ 200 | 9.7s / 1767 字符 |
| `low` | ✅ 200 | 19.2s / 2295 |
| `medium` | ✅ 200(**codex 侧采用值**) | 24.5s / **2513** |
| `xhigh` | ✅ 200(服务端默认) | 35.3s / **仅 1581** |
| `minimal` / `high` / `max` | ❌ 400 | — |

> **2026-09-21 复测,换了一道题、并且这次数的是 `reasoning_tokens`**
> (反转链表,非流式,n=1,`max_output_tokens=1200`)。枚举与 2026-09-19 完全一致:
>
> | 档位 | HTTP | 墙钟 | `reasoning_tokens` | 正文字符 |
> |---|---|---|---|---|
> | `none` | 200 | 1.9s | **0**(返回里没有 `reasoning` 项) | 355 |
> | `low` | 200 | 4.2s | 68 | 301 |
> | `medium` | 200 | 5.9s | 116 | 301 |
> | `xhigh` | 200 | 11.7s | **353** | **210** |
> | `minimal` / `high` / `max` | 400 | — | — | — |
>
> "思考变多、正文反而变短"在两道完全不同的题上都复现了 —— 这是本栈选 `medium`
> 的实测依据,不是口味。

⚠️ **`high` 在这一栈是被拒的**,在下面那套 qwen38 vLLM 上却是 200 —— 档位枚举
**逐栈不同,不能跨栈照抄**(gotcha #9 的同一类)。服务端 400 的文本
*"Supported types are xhigh (default), medium, and low"* 自己漏了 `none`,
但 `none` 实测 200,**以实测为准**。

⚠️ **2026-09-20 修掉的一处漂移**:`~/.codex/dgx.config.toml` 的注释从 2026-09-03
起就写着"默认取 medium",值却一直是 `xhigh` —— 跨两次换栈没人发现,因为
**两个值都返回 200**,没有任何报错会提示注释和值不一致。现已改为 `medium`
并实发 `/v1/responses` 验过。教训与 gotcha #9 同源:*结论写在注释里、没落到值上,
是一种不会报错的错误*。

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
> xhigh,发 `max`/`ultra` 会被 400 拒掉)。⚠️ **这条只在 `dgx` profile 指向
> V4-Flash 时成立**;该 profile 现已指向 qwen38un,档位见上表。回滚到 V4-Flash
> 时要连档位一起改回来 —— 历史备份在 `~/.codex/dgx.config.toml.bak-*`。

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

### `--profile fndgx` —— 单机 Flash-Next(S2 `:18300`)

⚠️⚠️ **它和 `qwen38-flash-next` 是同一个模型,不是同一个栈。** served name 只差
一个点,base_url 完全不同。抄错一边不报错,只是连到另一个(当前停着的)端点:

| | `qwen38-flash-next` | `qwen3.8-flash-next` |
|---|---|---|
| 机器 | S1+S2,TP=2,k3s(**已删除**) | **只有 S2**,docker |
| base_url | `100.97.87.120:8000` | **`100.67.164.92:18300`** |
| codex profile | (无) | `--profile fndgx` |

**2026-09-20 实测 effort 枚举(vLLM + EFFORT_ALIAS=1)—— 七个值全是 200:**

| 值 | 结果 | 思考长度(n=1,琐碎题) |
|---|---|---|
| `none` | ✅ 200 | **0 字**,输出 4 token |
| `minimal` `low` `medium` `high` `xhigh` `max` | ✅ 200 | 70 / 82 / 126 / 116 / 122 字 |

⚠️ **这一栈没有「错值会被拒」这道闸门。** 服务端 `EFFORT_ALIAS=1` 把
`high`/`max`→`xhigh`、`minimal`→`low` 改写进了模板副本,所以什么都收 ——
**与 qwen38un 正相反**(那边 `high`/`max`/`minimal` 是 400)。后果是
gotcha #10 的形状:**状态码验不出你发的档位是不是生效的档位**。
唯一能从响应里分辨出来的是 `none`(思考 0 字);其余六个在琐碎题上落在
70–126 字,n=1 分不开。

**2026-09-21 复测:换成一道编码题 + 数 `reasoning_tokens`,别名就分得开了。**
(反转链表,非流式,n=1,`max_output_tokens=1200`)

| 档位 | HTTP | 墙钟 | `reasoning_tokens` | 实际落在哪一档 |
|---|---|---|---|---|
| `none` | 200 | 2.4s | **0** | 关思考 |
| `minimal` | 200 | 3.8s | 45 | ≈ `low` |
| `low` | 200 | 3.6s | 22 | `low` |
| `medium` | 200 | 3.3s | 37 | `medium` |
| `high` | 200 | 13.8s | **403** | ≈ `xhigh` |
| `xhigh` | 200 | 14.4s | **419**(正文仅 216 字符) | `xhigh` |
| `max` | 200 | 10.8s | 282 | ≈ `xhigh` |

⚠️ 琐碎题上分不开的六个档,在编码题上分成了清清楚楚的三组 —— 印证 `EFFORT_ALIAS`
的改写。**数思考 token、用够重的题**,是这一栈唯一能看出档位是否生效的办法。

`fndgx.config.toml` 取 `medium`,现在**有本栈自己的实测支撑**:xhigh 的思考量是
medium 的 11 倍、墙钟 4.4 倍,而正文反而从 301 掉到 216 字符 —— 与 `dgx` 同形。
catalog 只列原生四档(`none`/`low`/`medium`/`xhigh`),正是为了挡住 `high`→`xhigh`
这种静默改写。

catalog 条目 `qwen3.8-flash-next` 的 `context_window` = **262144**
= 服务端 `--max-model-len`(`native` profile,不是 YaRN 的 500k)。

✅ **端到端跑通,2026-09-20 23:12** —— 不是"配置看着对",是真的跑了一次 codex:

```
$ codex exec --profile fndgx --sandbox read-only "Reply with exactly: PROFILE_OK"
model: qwen3.8-flash-next
provider: fndgx
reasoning effort: medium
...
PROFILE_OK      (tokens used 2,843)
```

这一条比重放 `curl` 强一档:它证明的是 **codex 自己**把 overlay、provider、
catalog、`LOCAL_LLM_API_KEY` 四样东西串起来了 —— 而重放 `curl` 只证明端点活着。
`--profile dgx` 当年就是靠重放验的,结果放过了 `xhigh`/`medium` 那处漂移
(两个值都回 200)。**能跑 `codex exec` 就别只 `curl`。**

---

## Qwen Code CLI

```bash
qwen                                     # 用当前启动默认
./scripts/qwen-model-switch.sh --help    # 列出所有可选目标(现读 stacks/ 注册表)
./scripts/qwen-model-switch.sh <target>  # 切启动默认(别名 = STACK_CLIENT_ALIAS)
./scripts/qwen-model-switch.sh status    # 三处启动字段 + modelProviders 各指向哪
```

> ⚠️ **这里不再手抄目标名单。** 名单住在 `stacks/*/stack.env` 的 `STACK_CLIENT_ALIAS`,
> `--help` 现场生成。本文上一版手抄了 6 个,而注册表当时已有 7 个 —— 漏掉的
> `glm53` 在文档上等于不存在。同理下面也不列 `modelProviders` 里有哪几条。

会话内 `/model` **可以实时跳 provider**(这点比 codex 强,不用脚本、不用重启),
前提是那个栈在 `modelProviders` 里**有一条**。脚本只管**启动默认**(那条路径根本
不读 `modelProviders`)。

⚠️ **`qwen-model-switch.sh` 不写 `modelProviders`,所以这两条路径会各切各的。**
2026-09-19 实例:三处启动字段全部指向 `qwen3.8-27b-sglang`,而 `modelProviders`
里压根没有这一条 —— 启动能用,会话内 `/model` 跳不过去,且当时的 `status`
**看不出来**。现在 `status` 会把这一块一起印出来,切换路径在目标缺条目时也会告警。
手工补一条要写全四项:`id` / `baseUrl` / `envKey` /
`generationConfig.contextWindowSize`(ctx 取该栈的 `STACK_CTXWIN`)。

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
| `deepseek-v4-flash`(⚠️ 栈已于 2026-09-20 删除,本行是教训不是配置) | **1000000** | 匹配 `deepseek-v4*` → 预留 **384000**。任何小于约 384k 的值(含未设置时的 131072 默认)都会把硬阈值夹到 **0**,导致**每个请求**都报 `hard limit: 0; compression NOOP`——**哪怕只有 4k 提示词** |
| `qwen38-27b` | **262144** | 服务端只接受 262144。实测**不**命中 384k 预留(repo 内/外两条路径都验证过) |

写死 1000000 然后切到 qwen38 → CLI 会发出服务端拒收的超长请求;
写死 262144 然后切回 V4-Flash → 触发 hard-limit-0,**全部请求失败**。
`scripts/qwen-model-switch.sh` 会把这个字段和模型一起翻转(全局 + repo 两处)。

> ⚠️ **2026-09-19:新主力的 served name 是 `qwen3.8-27b-sglang` —— 带点。**
> 384k 输出预留是按模型名匹配的,已知 `deepseek-v4*` 命中、`qwen38-*` 不命中,
> 而带点的这个属于**未知形状**。切换后**实际跑了一次 `qwen -p` 并确认引擎侧
> 收到请求、CLI 正常回话**(没有 "hard limit: 0"),所以 262144 是安全的。
> 加新栈时照此办理:**光看配置写对了不算验证。**
>
> ✅ **2026-09-20 对 `qwen3.8-flash-next`(fndgx,同样带点)照此验过**:
> `modelProviders` 里补了这一条(`100.67.164.92:18300`,ctx 262144),并用一个
> 项目级 `.qwen/settings.json` 真发了一次 —— CLI 正常回话、**没有 "hard limit: 0"**,
> 引擎侧 `POST /v1/chat/completions 200`。所以 262144 对它也是安全的。
> ⚠️ 第一次探测是**假的**:只导出 `OPENAI_BASE_URL`/`OPENAI_MODEL` 环境变量、在
> 一个没有 `.qwen/` 的目录里跑,qwen **忽略了它们**,照旧走全局启动默认(远端
> omlx),却一样回了正确答案 —— 服务端日志里根本没有那条请求。
> **"回答对了"不是端点验证,要么看引擎日志,要么看 CLI 自己打印的模型名。**

### thinking 开关

两套栈的 kwarg 名**不一样**,照抄会静默失效:

| 栈 | 关闭 thinking |
|---|---|
| **Flash-Next** | `chat_template_kwargs: {"enable_thinking": false}` |
| V4-Flash | `chat_template_kwargs: {"thinking": false}` |
| Qwen3.8-27B | `chat_template_kwargs: {"enable_thinking": false}` |

⚠️ Flash-Next 实测 **88% 的输出 token 是 thinking**(483/548),关掉能显著提速。

⚠️ codex/qwen 内置的 `reasoning:false` **只对 `api.deepseek.com` 生效**,
对自建 vLLM 无效——必须通过客户端的 extra-body 注入上面的 `chat_template_kwargs`。

**CoT 落在哪个字段,两栈也不同**(`/v1/chat/completions` 响应):

| 栈 | reasoning parser | CoT 字段 |
|---|---|---|
| **Flash-Next** | `qwen3` | **`.choices[0].message.reasoning`** |
| V4-Flash | `deepseek_v4` | `.choices[0].message.reasoning_content` |
| Qwen3.8-27B | `qwen3` | **`.choices[0].message.reasoning`** |

读错字段会拿到 `None`,**看起来像"thinking 开了却没输出"**。判据:thinking 开启时
`content` 会短得反常(只剩最终答案),说明 CoT 已被正确分离走了。

`/v1/responses` 两栈一致——CoT 走 `type:"reasoning"` 输出项,codex 用的是这条路径。

---

## 发图:多模态(**只有 qwen38un 这一栈有**)

当前主力栈是 `Qwen3_5ForConditionalGeneration`,权重自带 27 层 ViT,**无需任何
启动参数**(SGLang 读 config.json 自动开)。2026-09-20 实测可用 —— 在此之前
repo 里**一个字都没提过**这个能力。

```bash
# content 用数组,图在前文字在后;data URI 即可,不需要先上传
curl -s http://100.97.87.120:8888/v1/chat/completions \
  -H 'Content-Type: application/json' -d '{
    "model": "qwen3.8-27b-sglang",
    "messages": [{"role":"user","content":[
      {"type":"image_url","image_url":{"url":"data:image/png;base64,<BASE64>"}},
      {"type":"text","text":"这张图里是什么?"}]}],
    "chat_template_kwargs": {"enable_thinking": false}}'
```

⚠️ **判据是 `usage.prompt_tokens_details.image_tokens > 0`,不是"答案看起来对"。**
图被静默丢掉时,模型照样会编一段像模像样的描述。`make test STACK=qwen38un`
第 3 节就是按这个判据做的回归。

⚠️ **用 base64 data URI,不要用 http(s) 图片 URL** —— 节点没有外网直连
(服务端 `allowed_media_domains=[]`,单文件上限 64 MB)。

⚠️ **视频未验证,且大概率不通**:权重带 `video_preprocessor_config.json`,但镜像缺
`torchcodec`。**配置文件存在不等于这条路通。**

其余各栈都是纯文本 —— 发图给它们不会报你想要的错,只会得到一个把图当没看见的回答。

---

## 换机器时重建

两个 CLI 的配置都在家目录,**不随 repo 走**:

- **codex**:`~/.codex/<name>.config.toml`,外加 profile 的 `model_catalog_json` 指向的
  catalog。两台客户端 Mac 的布局不同(见上面「两套 `~/.codex`」):A 是**一份共用的**
  `~/.codex/models.json`,被多个 profile 指向;B 是**每个 profile 自己那份**
  `~/.codex/<name>-models.json`,没有 `models.json`。哪种都能用,换机器时先看清是哪台。
  ⚠️ **profile 里那行 `model_catalog_json = "<绝对路径>"` 是重建时最容易漏的一笔**:
  codex 0.155.1 不会自动读任何 catalog 文件,少了它,档位选单、快捷键和 `context_window`
  全都在吃 fallback,而**照常能用、不报错**。A 的四个 profile 曾全部缺这一行
  (2026-09-21 才给 `dgx` / `fndgx` 补上),根因见上面「调思考深度」一节。
  再加 `~/.zshrc` 里 `export LOCAL_LLM_API_KEY=dummy`。
  qwen38 的完整重建步骤(含生成 catalog 的 python)见
  `stacks/qwen38/runbook-cn.md` §6.3。
- **Qwen Code**:`~/.qwen/settings.json`,最小可用骨架见
  `stacks/qwen38/runbook-cn.md` §6.2。repo 内的 `.qwen/.env` 是 gitignored 的。
