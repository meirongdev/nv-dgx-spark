# 换主力栈清单(Stack Switch Checklist)

> 建立于 2026-09-03,起因是 **同一形状的事故在三周内发生了三次**。
>
> 这不是"换栈怎么部署"的 runbook(那是各栈自己的文档),而是一份
> **触点清单** —— 枚举「当前主力栈是谁」这个事实被写死在了哪些地方。
> 每一条都带一个验证命令,因为这类问题的定义特征就是:**不验证就看不出来。**

## 0. 这类事故长什么样

**共同形状:某个工具/文档里写死了当前主力栈的标识(model 名、CoT 字段名、
kwarg 名、deploy 名)。换栈后它不报错、不崩溃 —— 它照常返回一个看起来完全
正常的结果,只是那个结果是错的。**

已经发生过三次:

| 日期 | 写死的东西 | 表现 | 代价 |
|---|---|---|---|
| 2026-08-15 | CoT 响应字段 `reasoning_content` vs `reasoning` | 读到 `None`,与"thinking 没生效"完全同形 | 误判成 "parser 不匹配、未解决",**错误结论写进了文档** |
| 2026-09-02 | `bench_full.py` 的 kwarg 名 `thinking` vs `enable_thinking` | 服务端照常 200,CoT 一个字没关掉 | 跨栈对照**整个不成立**,测到的是带 CoT 的 tok/s(c96fcf3) |
| 2026-09-03 | `gb10-clock-cap.sh` 的 model 名 | 服务端 400、`curl` 仍 rc=0 → 脚本拿**空载**采样打印判据行 | 时钟锁的**唯一判据**静默失效约 24h |

三次都不是"忘了改配置"这种会当场报错的错误。三次都是**沉默的**。

**根因不止是漏改,还有 091b6e4:那笔换栈 commit 改了 13 个文件、一份文档都
没动。** CLAUDE.md 因此在 24 小时里持续告诉每一个 agent session:主力栈是
V4-Flash。在那个前提下,clock-cap 的 model 名"看起来是对的"。

## 1. 触点清单

⚠️ **换栈时逐行走,换完再逐行验一遍。** 分四层,越靠后越沉默。

### 第 1 层:服务端(改错会当场崩,最安全的一层)

| # | 位置 | 改什么 | 验证 |
|---|---|---|---|
| 1.1 | `config/<stack>.yaml` | vLLM flags 的真相源 | 与 1.2 逐字段对照 |
| 1.2 | `k8s/<stack>/configmap-launch.yaml` | **线上真正执行的** rank0/rank1 脚本 | `make <stack>-status` |
| 1.3 | `k8s/<stack>/{leader,worker,service}.yaml` | Deployment / Service 名 | `kubectl -n <ns> get deploy,svc` |
| 1.4 | 两台节点的 containerd 镜像 | `docker save \| k3s ctr images import` + re-pin | `sudo k3s ctr -n k8s.io images ls \| grep <image>` |

> 1.1 和 1.2 **必须成对改** —— 这是本仓库的既有约定,两份文件都写了这句话。

### 第 2 层:判据工具(改错 = 得到一个看起来正常的错误结论)⚠️ 最危险

**这一层就是三次事故的全部来源。**

| # | 位置 | 变量 | 不改的后果 |
|---|---|---|---|
| 2.1 | `scripts/gb10-clock-cap.sh` | `CAP_MODEL` | verify 拿空载采样冒充"锁生效" |
| 2.2 | `benchmarks/bench-full-2026-08-05/bench_full.py` | `MODEL` + **`THINK_KEY`** | 测到**带 CoT** 的 tok/s,与基线不可比 |
| 2.3 | `benchmarks/bench-full-2026-08-05/prefill_repeat.py` | `MODEL` | 同上 |
| 2.4 | `Makefile` 的 `MEMWATCH_STACK` | 栈名 | 看门狗去 scale 一个**不存在**的 deploy,整机 OOM 时不动作 |
| 2.5 | 各栈 smoke test(`qwen38fn-test.sh` / `v4-test.sh` / `qwen38-test.sh`) | `MODEL` | 冒烟测的是旧栈(若旧栈已停,这条会响,相对安全) |

> **2.2 / 2.3 的默认值是故意留在 V4-Flash 的** —— 那样 2026-08-05 的基线才可
> 复现。代价是:直接跑它去测新栈一定是错的。跑之前先看
> `benchmarks/bench-full-qwen38fn-2026-09-03/README.md` 里的调用行。

验证(把下面这条跑通,第 2 层才算过):

```bash
make clock-cap-verify     # 必须打印 "负载:生成 300 token" + n≈20 的采样;
                          # 打印 "生成失败" = CAP_MODEL 与线上 served-model-name 不符
make memwatch             # 启动时会自检两个 deploy 是否存在,指错栈直接 exit 3
```

⚠️ **`make memwatch-check` 不能用来验这条** —— `--once` 只打印两节点
available%,在自检之前就 `exit 0` 了。deploy 绑定的自检只在 `make memwatch`
(常驻模式)启动时跑。

### 第 3 层:客户端(改错 = CLI 连到已经停掉的栈,会响)

| # | 位置 | 改什么 |
|---|---|---|
| 3.1 | `~/.codex/<profile>.config.toml` | provider 的 model 名 |
| 3.2 | `~/.codex/models.json` | catalog 条目的 `context_window`(**不是** `model_context_window`) |
| 3.3 | `~/.qwen/settings.json` + `<repo>/.qwen/settings.json` + `<repo>/.qwen/.env` | 四个字段跨三个文件必须一致 |

3.3 有工具代劳,别手改:

```bash
./scripts/qwen-model-switch.sh flashnext   # 或 v4flash / qwen38
./scripts/qwen-model-switch.sh status      # 并排打印两个 settings.json 的
                                           # model / ctx / auth.baseUrl(.env 存在时附带)
```

⚠️ 3.2 有过一次静默不一致:旧的 `deepseek-v4-flash` catalog 写 65536、config 写
1000000,于是一直按 64K 在跑,没有任何提示。细节见 `docs/clients-cn.md`。

### 第 4 层:文档(改错 = 下一个 session 在错误前提下工作)

**这一层最容易跳过,而它是 2026-09-03 那次事故的根因。**

| # | 位置 | 改什么 |
|---|---|---|
| 4.1 | **`CLAUDE.md` 的栈表格 + `## Current state`** | 谁是主力、日期、当前实测数字 |
| 4.2 | `README.md` 的文档地图 | 哪份文档描述"主力栈" |
| 4.3 | `docs/clients-cn.md` | 端点表 + reasoning effort 枚举(**逐栈不同,别照抄**) |
| 4.4 | `docs/benchmarking-cn.md` + `benchmarks/` | 当前基线指向哪一份 |

> **约定:任何移动主力栈的 commit,必须在同一笔里更新 4.1。**
> CLAUDE.md 是每个 session 全量载入的索引 —— 它错一天,就有一天所有判断建立在
> 错误前提上。

## 2. 换完之后的验收

```bash
make <stack>-status        # 两个 rank 都 1/1,/v1/models 报出新的 served name
make <stack>-test          # 冒烟 + tool-call parser
make clock-cap-verify      # ← 第 2 层的哨兵:它一响就说明还有工具没跟上
make memwatch-check        # 看门狗认得当前栈
./scripts/qwen-model-switch.sh status   # 客户端三文件一致
```

再加一条**人工**检查,没有命令能替代:

> 通读 `CLAUDE.md` 开头的栈表格和 `## Current state`,问自己:
> **一个只读过这两段的人,会不会据此得出错误结论?**

## 3. 写新工具时的规则

这三次事故换来的规则,加任何**跨栈**工具时适用:

1. **栈标识一律提成环境变量**,默认值写当前主力栈,并在旁边注释"换栈时改这里"。
   不要散落在函数体里。
2. **判据必须验证它真的跑了。** `curl` 的退出码**不算** —— model 名写错时服务端
   返回 400 而 `curl` 照样 rc=0。要认真实的产物(生成了多少 token、采到多少个点)。
3. **没跑成就硬失败(非 0 退出),不要打印一个可能被读成"通过"的数字。**
   `gb10-clock-cap.sh` 旧版在生成失败时仍打印 n=2 的空载采样 + 判据行 ——
   而空载频率本来就贴住上限,和锁生效时长得一模一样。
   ⚠️ 这个洞往往有**两层**:内层判据补好之后,外层调用方可能仍在无条件打印结论。
   修完务必跑一次负向用例。
4. **负向用例和正向用例一样重要。** 这类 bug 的全部危害就是「失败路径看起来像
   成功」—— 只测正向路径永远发现不了。故意传一个错的栈标识,确认它**响**:

   ```bash
   CAP_MODEL=不存在的名字 bash scripts/gb10-clock-cap.sh verify; echo $?   # 必须非 0
   ```
5. **一个分不清"通过"和"根本没运行"的检查器,比没有检查器更糟** —— 后者你知道
   自己没验,前者让你以为验过了。

**正面样板:`scripts/mem-watch.sh`。** 它在进入巡检循环前逐个 `kubectl get
deploy`,任一个不存在就 `exit 3` 并直接告诉你去改 `MEMWATCH_STACK` —— 宁可
根本不启动,也不当一道静默失效的防线。新工具照这个写。

## 4. 相关

- `docs/gotchas-cn.md` #9 —— 跨栈标识不一致的三个实例与判据
- `benchmarks/bench-full-qwen38fn-2026-09-03/README.md` —— 换栈基准闸门
- `CLAUDE.md` —— 栈表格 + Current state(4.1)
