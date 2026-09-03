# MTP `num_speculative_tokens` 扫描 —— Qwen3.8-Flash-Next NVFP4（2026-09-03）

迁移主力栈时 `num_speculative_tokens` 直接沿用了 **3**（`config/qwen38-flash-next.yaml:121`），
没在本机扫过。V4-Flash 那边 DSpark 的教训正是"卡片给的更大值在 GB10 上更慢"
（n=7 反而白费两次 draft，见 `docs/dspark-upgrade-cn.md`），所以这个参数在这里
也不能默认"越大越好"。

**结论：k=4 比现役的 k=3 快 +12.2%（decode 均值），五个 prompt 全部正向。
k=5~8 在这台机器上根本起不来 —— 不是慢，是启动即崩。**
是否把现役配置从 3 抬到 4 **还没决定**，本目录只有测量，没有落地。

## 方法：为什么不直接比 tok/s

`num_speculative_tokens` 是**启动参数**，改它必须重启引擎（8-11min），**物理上无法
交错配对**；而本机单次 decode 测量的噪声地板是 4.6%（`docs/gb10-tuning-cn.md` §2），
预期效应量刚好压在噪声上。时钟上限那次靠交错配对解决，这里行不通。

解法是把 tok/s 拆成两个量（完整推导在 `mtp_arm.py` 的 docstring）：

    tok/s  =  (tok/step)  ×  (step/s)
              ^^^^^^^^^^     ^^^^^^^^
              计数，无噪声    计时，有噪声

`tok/step = Δaccepted/Δdrafts + 1` 取自 `/metrics` 的**累计计数器**，是数出来的不是
掐表掐出来的 —— 而它恰好就是 k 直接作用的那个量。prompt / warm-up / best-of-2 全部
复用 `../bench-full-2026-08-05/bench_full.py`，所以 decode 那几行可以直接和
`../bench-full-qwen38fn-2026-09-03/` 对照。

三道 fail-closed 的闸（`docs/stack-switch-cn.md` §3）：k 生效与否做**行为验证**
（`Δdraft_tokens/Δdrafts` 必须精确等于 k，不读配置）、开测前要 90s 静默窗口、
测量期间引擎完成的请求数必须等于脚本自己发出的数。任一不过 → 非 0 退出**且不打印
结论行**。两个 arm 都是 `独占 OK (10 reqs, 0 foreign)`。

## Decode（按内容，tok/s）

| prompt | k=3（现役） | k=4 | Δ |
|---|---:|---:|---:|
| count300（数数） | 63.7 | **72.9** | +14.4% |
| mult12（乘法表） | 63.4 | **71.7** | +13.1% |
| json60（JSON） | 63.4 | **71.4** | +12.6% |
| **bst（真实代码）** | 60.2 | **67.1** | **+11.5%** |
| story（散文） | 32.0 | **33.7** | +5.3% |
| **mean** | 56.5 | **63.4** | **+12.2%** |

### 拆开看：收益从哪来

| | k=3 | k=4 | Δ |
|---|---:|---:|---:|
| tok/step（计数，无噪声） | 3.672 | **4.498** | **+22.5%** |
| step/s（计时） | 15.94 | 14.49 | −9.1% |
| 净 | | | 分量算出 **+11.4%** |

**分量算出的 +11.4% 与实测的 +12.2% 对上了** —— 这是本实验唯一能信的理由：k 换来
的 tok/step 是硬数字，代价（多一次 draft forward + verify 多一个位置）是软的，
decode 带宽受限所以近乎免费（`gb10-tuning-cn.md` §2：砍频 26% 而 decode 无显著变化）。

**为什么 Flash-Next 吃得下更大的 k，而 V4-Flash 吃不下：接受率不随 draft 深度衰减。**

| draft 位置 | k=3 条件接受率 | k=4 条件接受率 |
|---|---:|---:|
| pos0 | 93.4% | 93.5% |
| pos1 | 94.5% | 94.7% |
| pos2 | 96.9% | 95.9% |
| pos3 | — | **97.7%** |

DSpark 是在 draft 位置 4 之后接受率**骤降**，所以 n=5 就是天花板；MTP 这里条件接受率
甚至**随深度上升**（前几位都过了，第 4 位才容易过），于是 k 继续付钱。k=4 的 4.498
已经吃到理论上限 5.00 的 **90%**，往上边际空间不大。

> ⚠️ **两条自我限制，别把这张表读得太实。**
> 1. 每个 arm 只有 n=1（重启无法交错）。同样是 k=3 的现役配置，本目录测到 56.5，
>    `../bench-full-qwen38fn-2026-09-03/` 测到 58.6 —— 跨运行的散布 3.6%，在 4.6%
>    噪声地板内。**所以判据是 +22.5% 那个计数分量，不是 +12.2% 这个计时分量。**
>    后者的支撑是 5/5 个 prompt 全正向，且与分量预测一致。
> 2. 每个 arm 的 step/s 实测 vs 反推差 2.8%（k=4）/ 3.4%（k=3）—— 交叉核对通过，
>    说明没有测量事故。

## k≥5：不是慢，是起不来（`k5-failure-evidence.txt`）

k=5 在**权重装完之后**才失败（exitCode 1，起来到死 3m23s）：

```
vllm/models/qwen3_8_flash_next/common/qsa_cache.py:781 get_kv_cache_spec()
AssertionError: QSA ring capacity 12 must divide the attention block size 1616
```

`capacity = compress_ratio * cdiv(compress_ratio + k, compress_ratio)`，checkpoint 里
`indexer_compress_ratio = 4`，而 **block_size 1616 不是可调参数** —— 引擎自己按
"attention page size 必须 ≥ mamba page size" 算出来的（`interface.py:915`，
`1616 = 2⁴ × 101`）。于是 k 的可行域是断开的：

| k | capacity | 1616 % capacity | |
|---:|---:|---:|---|
| 1–4 | 8 | 0 | ✅ |
| 5–8 | 12 | 8 | ❌ **BLOCKED** |
| 9–12 | 16 | 0 | ✅（未测） |
| 13–16 | 20 | 16 | ❌ BLOCKED |

**这意味着"k 调大一点"不是旋钮。** 4 以下连续可行，5~8 一个都起不来，下一个可行段
跳到 9 —— 而 k=9 是完全不同的工作区（draft 数翻倍不止），本扫描**没有**测过它，
也不建议顺手试。真要打通 5~8 得改 block_size 或上游改 QSA 的 capacity 取整，
那是镜像/上游的事，不是这里的配置改动。

## 落地状态：未落地

现役仍是 **k=3**（`config/qwen38-flash-next.yaml` 与 `k8s/qwen38fn/configmap-launch.yaml`
两个 rank 一致）。抬到 4 要付的账：

- 两个文件**一起改**（recipe 是 flags 的唯一真相源，ConfigMap 是渲染结果），
  然后 `make qwen38fn-restart` **同时重建两个 rank**（gotcha #1：单 rank 重启留下
  僵尸 TP 组，`/health` 照样 200）。
- 更深的 draft 会动 KV / 激活内存的账 —— 动之前按约定先跑 `scripts/mem-floor.sh`。
- 单流 +12.2% 是否值得重启，取决于当时的优先级；本目录只交测量，不代做这个决定。

原始输出：`arm-k3-baseline.log`、`arm-k4.log`、`k5-failure-evidence.txt`。
工装：`set-k.sh`（换 k 并起来）+ `run-arm.sh`（只测，测废了能单独重测）+
`chain-next.sh`（上一个 arm **判废就停**，不往下走 —— 扫描的全部意义是几格之间可比）。
