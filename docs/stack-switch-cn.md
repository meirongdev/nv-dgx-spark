# 换主力栈:机器做什么,人做什么

> 建立于 2026-09-03,起因是 **同一形状的事故在三周内发生了三次**。
> 2026-09-19 重写:那份清单列的 8 个触点里,**6 个已经不存在了** —— 它们被
> `stacks/` 注册表消掉了。本文现在只剩两件事:**机器接管了哪些**(这样你知道
> 不用再查),以及**剩下哪些还得人来**(这才是需要一份清单的部分)。
>
> 「怎么部署某个栈」不在这里,在 `stacks/<id>/`。
> 「怎么新增一个栈」也不在这里,在 `stacks/README.md`。

## 0. 这类事故长什么样

**共同形状:某个工具/文档里写死了当前主力栈的标识(model 名、CoT 字段名、
kwarg 名、deploy 名)。换栈后它不报错、不崩溃 —— 它照常返回一个看起来完全
正常的结果,只是那个结果是错的。**

| 日期 | 写死的东西 | 表现 | 代价 |
|---|---|---|---|
| 2026-08-15 | CoT 响应字段 `reasoning_content` vs `reasoning` | 读到 `None`,与"thinking 没生效"完全同形 | 误判成 "parser 不匹配、未解决",**错误结论写进了文档** |
| 2026-09-02 | `bench_full.py` 的 kwarg 名 `thinking` vs `enable_thinking` | 服务端照常 200,CoT 一个字没关掉 | 跨栈对照**整个不成立**,测到的是带 CoT 的 tok/s(c96fcf3) |
| 2026-09-03 | `gb10-clock-cap.sh` 的 model 名 | 服务端 400、`curl` 仍 rc=0 → 脚本拿**空载**采样打印判据行 | 时钟锁的**唯一判据**静默失效约 24h |

三次都不是"忘了改配置"这种会当场报错的错误。三次都是**沉默的**。

**根因不止是漏改,还有 091b6e4:那笔换栈 commit 改了 13 个文件、一份文档都
没动。** CLAUDE.md 因此在 24 小时里持续告诉每一个 agent session:主力栈是
V4-Flash。在那个前提下,clock-cap 的 model 名"看起来是对的"。

**结论不是"下次更仔细",而是:这些标识不该存在于工具里。** 于是有了 `stacks/`。

---

## 1. 换栈

```bash
make switch TO=<stack-id>
```

它按顺序做:停旧栈 → 改 `stacks/PRIMARY` → **起新栈失败就把 PRIMARY 回滚** →
重新生成文档表格 → 切 Qwen Code 启动默认 → 打印下面第 3 节。

## 2. 机器已经接管的(不用再逐个查)

| 以前的触点 | 现在 |
|---|---|
| `Makefile` 的 `MEMWATCH_STACK` + 一段 `ifeq` 阶梯 | 没了。`mem-watch.sh` 读 `stacks/PRIMARY` |
| `scripts/gb10-clock-cap.sh` 的 `CAP_MODEL` / `PORT` / `CHAT_KWARGS` | 没了。从注册表推导;`CAP_STACK=<id>` 可临时改指 |
| `scripts/qwen-model-switch.sh` 的 case 分支表 | 没了。目标就是注册表,`--help` 现场列出来 |
| 各栈 preflight 里手写的互斥名单(O(n²)) | 没了。`preflight.sh` **遍历注册表**,新栈一落地所有既有栈自动检查它 |
| 各栈 smoke test 里的 `MODEL` 默认值 | 没了。由 stackctl 注入;手跑不给身份会**硬失败**而不是测错栈 |
| `CLAUDE.md` / `README.md` / `docs/clients-cn.md` 的栈表格 | `make stack-table` 生成,`make stack-check` 校验,不一致就非 0 |

还白拿了两道以前没有的闸门:

- **身份闸门**:`make test` 先比对 `/v1/models` 报的 served name 与注册表是否一致。
  ⚠️ 这条不能用"请求成功了吗"代替 —— **SGLang 接受任意 model 名**并原样回显
  (gotcha #10),vLLM 才会 404。
- **看门狗覆盖**:`make memwatch-test` 对**每一个**注册的栈验一遍"真要动手时动得了",
  漏填停机动作会在这里当场响,而不是等到整机 OOM 那天。

## 3. 还得人来做的

**这一节就是这份文档存在的全部理由。**

### 3.1 codex 的配置(不在本仓库里,脚本够不着)

| 文件 | 字段 |
|---|---|
| `~/.codex/<profile>.config.toml` | provider 的 model 名 |
| `~/.codex/models.json` | catalog 条目的 `context_window`(**不是** `model_context_window`) |

⚠️ 这两处静默不一致过:旧的 `deepseek-v4-flash` catalog 写 65536、config 写
1000000,于是一直按 64K 在跑,没有任何提示。细节见 `docs/clients-cn.md`。

### 3.2 实际发一个请求

**不要只看配置文件写对没有。** 2026-09-19 那次切换是这么验的:qwen 真的发了
请求、引擎日志里看到了命中;codex 的 CLI `--version` 会 hang(既有问题,它根本
不读 profile),所以是把 codex 会发的那个请求**原样重放**到 `/v1/responses` → 200。

### 3.3 `CLAUDE.md` 的 `## Current state`

表格是生成的,**那一段散文不是**。通读它,问自己:

> 一个只读过这一段的人,会不会据此得出错误结论?

### 3.4 基准数字

新栈的 tok/s 在 `stacks/<id>/recipe.yaml` 和 `benchmarks/` 里。别把上一个栈的
数字继续挂在文档上 —— 而且**引用任何 tok/s 之前先读 `docs/benchmarking-cn.md`**,
同一份配置在不同内容上能差 2.7 倍。

## 4. 验收

```bash
make status                # 起来了,且 /v1/models 报新的 served name
make test                  # 冒烟 + 身份闸门
make clock-cap-verify      # ← 哨兵:必须打印"负载:生成 300 token"
make memwatch              # 启动自检:停不掉当前栈就 exit 3
make stack-check           # 注册表自洽 + 文档表格没过期
./scripts/qwen-model-switch.sh status
```

⚠️ **`make memwatch-check` 不能用来验看门狗** —— `--once` 只打印各节点
available%,在自检之前就 `exit 0` 了。绑定自检只在常驻模式启动时跑。

## 5. 写新工具时的规则

见 `stacks/README.md` 末节。一句话:**不要在工具里写栈的默认值**,判据必须
验证它真的跑了,没跑成就硬失败,负向用例和正向用例一样重要。

## 6. 相关

- `stacks/README.md` —— 新增一个模型的契约
- `docs/gotchas-cn.md` #9 / #10 —— 跨栈标识静默失效的实例与判据
- `CLAUDE.md` —— 栈表格(生成)+ Current state(人写)
