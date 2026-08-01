# SWE-bench Lite — DeepSeek-V4-Flash on dual DGX Spark (2026-08-01)

冒烟运行（20 条）的完整记录。**这是一次基础设施打通 + 方法学验证的运行，不是一个
可对外引用的 SWE-bench 分数**（样本量 20，且 6 条因 ARM 环境问题没跑起来）。

## 结论先行

| 口径 | 数值 | 说明 |
|---|---|---|
| **resolved / 可评测实例** | **2 / 14 = 14.3%** | 排除 6 条基础设施失败，最能反映模型能力 |
| resolved / 全部抽样 | 2 / 20 = 10.0% | 保守口径（基础设施失败也算失败） |
| 空 patch 率 | **0 / 20 = 0%** | 20 条全部产出了非空、结构合法的 unified diff |
| gold patch 验证 | ✅ resolved | 证明 ARM64 构建/测试/判分链路可信 |

**这个数字不能和模型卡上的 SWE-bench 分数比较**，原因见下面「方法学口径」。

## 关键发现

1. **主要失败模式是 diff 格式，不是解题能力。** 7/20 是 `Patch Apply Failed` ——
   模型手写 unified diff 时 hunk 头的行数写错（声称 8 行上下文只给 4 行），
   `patch` 报 `unexpected end of file in patch`。不是被 max_tokens 截断
   （`finish_reason=stop`，且 patch 以换行结尾）。换 agentic scaffold
   （用工具编辑文件而非手写 diff）通常能基本消除这一类失败。
2. **thinking 完全没有干扰 ReAct 输出。** 计划里预留的回退 A/B 均未使用。因为部署带
   `--reasoning-parser deepseek_v4`，思考内容走 `reasoning_content` 字段，
   `content` 是干净的 `<patch>` 块，`extract_diff` 直接可解析。
3. **ARM 上没有任何预编译镜像**，base/env/instance 三层都要在 GB10 上现编，这是本次
   耗时的主要来源，也是 4 条 env 构建失败的来源。详见 `build-failures.md`。

## 运行配置

| 项 | 值 |
|---|---|
| 日期 | 2026-08-01 |
| 模型 | `deepseek-v4-flash` = DeepSeek-V4-Flash-0731 FP8，双 GB10 TP=2 + DSpark(n=5) |
| 端点 | `http://100.97.87.120:8000/v1`（vLLM jasl fork，`max_model_len=1000000`） |
| 数据集 | `princeton-nlp/SWE-bench_Lite` test（300）→ 20 条子集 |
| 抽样 | seed=42，按仓库名排序每仓库取 2 条，共 10 个仓库（清单 `smoke_instances.txt`） |
| 推理脚本 | `swebench.inference.run_api`（SWE-bench 4.1.0，commit `f7bbbb2`） |
| Prompt | `style-3` + `file_source=oracle` |
| 采样 | `temperature=0.2`（run_api 默认）、`top_p=0.95` |
| 评测 | `run_evaluation --namespace none --max_workers 3 --timeout 1800`，原生 arm64 镜像 |
| 机器 | server 1 `100.97.87.120`，aarch64，20 核，121G（vLLM 常驻，空闲 ~13G） |

### 推理开销

| 指标 | 值 |
|---|---|
| 实例数 | 20 / 20 完成 |
| 总耗时 | 44m58s（单路串行，≈135 s/实例） |
| input tokens | 总 223,310，均 11,165，最大 30,649 |
| output tokens | 总 84,645，均 4,232，**最大 16,166** |

> `run_api` 只把 `temperature`/`top_p` 传给 API，**`max_tokens` 会被静默忽略**。
> 这次反而是好事：最大输出 16,166 tokens，若计划里的 `max_tokens=8192` 真的生效，
> 会截断相当一部分回答。

## 结果明细

```
total_instances       20
completed_instances    7
resolved_instances     2      astropy__astropy-14995, django__django-14382
unresolved_instances   5      测试跑了但没通过
empty_patch_instances  0
error_instances       13      7 模型 patch 打不上 + 6 基础设施
```

分仓库（resolved / 抽样）：

```
astropy            1/2      pallets/flask       0/2
django             1/2      psf/requests        0/2
matplotlib         0/2      pydata/xarray       0/2  (env 构建失败)
mwaskom/seaborn    0/2      pylint-dev/pylint   0/2  (instance 构建失败)
pytest-dev/pytest  0/2      scikit-learn        0/2  (env 构建失败)
```

13 条 `error` 的逐条归因见 **`build-failures.md`**。

## 方法学口径（为什么不能和模型卡对比）

1. **非 agentic。** 本次是 SWE-bench 原始论文的单轮「给上下文 → 直接吐 patch」设置。
   各家模型卡上的 SWE-bench Verified 分数几乎都来自 agentic scaffold
   （SWE-agent / OpenHands / mini-swe-agent，可多轮读文件、跑测试、改错），分数天然
   高一个量级。
2. **oracle 检索。** `file_source=oracle` 直接把该改的文件喂给模型，省掉了定位问题。
   这是原论文的标准设置之一，但比真实场景宽松。
3. **样本量 20**，且只有 14 条真正评测。95% 置信区间极宽，只能当信号不能当结论。
4. **环境非原始快照。** 见下面 Patch C —— ARM 上无法复用官方 x86_64 conda 快照，
   环境是按 spec 现解的，包版本可能与参考环境有细微差异。gold patch 验证通过
   （`gold.gold-validate-arm64.json`）说明环境保真度足够，但不等于逐字节一致。

## 为跑通所打的补丁

全部在 `apply_patches.py`（幂等，可重放）。计划文档只预见了其中两个。

| 补丁 | 文件 | 问题 |
|---|---|---|
| A1/A2 | `test_spec/test_spec.py` | harness 默认 x86_64。**只补 `get_test_specs_from_dataset` 不够** —— `run_evaluation.py:306` 直接调 `make_test_spec`，绕过它。改为在 `make_test_spec` 默认值上按主机架构自动判定 |
| B | `inference/run_api.py` | 自定义模型名支持。除计划所列 3 处外，**还必须给 `MODEL_COST_PER_INPUT/OUTPUT` 加零成本条目** —— `calc_cost()` 是裸字典查找且位于 `@retry` 内，`KeyError` 会先耗掉 3 次重试（30–600s 退避）再崩 |
| C | `harness/utils.py` | 内置 `environment.yml` 是 x86_64 的 `conda env export` 快照（`py39h06a4308_0`、`ld_impl_linux-64`），aarch64 上 `PackagesNotFoundError`。ARM 上跳过缓存，回落到 spec 现解路径 |
| D | `test_spec/python.py` | **与 ARM 无关**：sympy 等上游已删除旧发布分支，`git clone --branch 1.7` 直接失败。加全量 clone 回退 + base commit 存在性检查（不削弱「无未来提交」防护，因为 `git remote remove origin` 会清掉远程跟踪引用） |
| E/E2 | `harness/utils.py`、`test_spec/python.py` | 4 处 `requests.get()` 无超时。从 CN 拉 `raw.githubusercontent.com` 偶发挂死 → 整个评测无限等待且日志无输出。改为带超时+重试+磁盘缓存（裸加超时会变成直接崩溃，因为这些调用在 `get_test_specs_from_dataset` 里对全部实例前置执行，一次 `ReadTimeout` 就会中止整轮） |

### 另外两个不在补丁里但必须知道的坑

- **`--namespace none` 必须显式传。** 默认 `namespace=swebench` 会让 harness 去
  **拉** Docker Hub 上的 x86_64 预编译镜像，而不是本地构建（ARM 根本没有这些镜像）。
- **`pip install -e ".[inference]"` 装不上**：`flash_attn` 需要 torch 且在 aarch64
  上编译失败。API 推理路径只需 `.[datasets]`（含 openai/tiktoken/transformers）。
- **`--report_dir` 是坏的**（上游 4.1.0）：目录会被 mkdir 但从未传给
  `make_run_report`，报告始终落在 CWD。
- 网络：服务器直连 `huggingface.co` 与 Docker Hub **不通**，需
  `HF_ENDPOINT=https://hf-mirror.com`，并用 daocloud 预拉 `ubuntu:22.04` 再 retag。
  anaconda / conda-forge / PyPI / ports.ubuntu.com / github.com 均直连可达。

## 是否上全量 Lite（300）？

**先修基础设施，再上量。** 依据：

- 当前 20 条里有 **6 条（30%）** 因环境问题没跑起来。直接跑 300 条会把这个比例原样
  放大，得到一个 30% 缺失的结果，没有参考价值。
- 上量前应先做掉（详见 `build-failures.md`）：
  1. base 镜像 apt 列表加 **`gfortran`**（修 scipy 源码编译，预计能救回 scikit-learn 一类）；
  2. 处理 pylint 的 `build_editable`（pip 降级或 `--no-use-pep517`）；
  3. `cdms2`（xarray）在 aarch64 上无解，接受其失败并在报告里标注。
- 成本预估：推理 300 条单路串行约 **11 小时**（按 135 s/实例）；评测因需为
  ~12 个仓库 × 多版本构建环境镜像，另需数小时。建议推理用 `--shard_id/--num_shards`
  切 2–4 路（注意 `max_num_seqs=6` 的并发上限）。
- **若目标是拿一个能对外比较的数字**，更应该换成 agentic scaffold（SWE-agent）跑
  SWE-bench Verified，而不是把这个单轮 oracle 设置放大到 300 条 —— 后者放大的是一个
  和业界口径对不上的数字。

## 服务器当前状态（续跑起点）

**2026-08-01 停在这里。环境已完全就绪，未来续跑不必重做 Phase 0–2。**

服务器 `100.97.87.120`，工作区 `/home/admin/swebench-eval/`（673M）：

| 已就绪 | 说明 |
|---|---|
| `.venv/` | swebench 4.1.0（commit `f7bbbb2`）+ `.[datasets]` extra，**9 处补丁已应用** |
| `scripts/apply_patches.py` | 幂等，`git checkout` 某文件后重跑即可恢复补丁 |
| `scripts/verify_patches.py` | 一条命令确认 9 处补丁都在 |
| `text_datasets/SWE-bench_Lite__style-3__fs-oracle` | **全量 300 条**文本数据集（已建好，跑全量直接用） |
| `text_datasets/mini20` | 20 条冒烟子集 |
| `predictions/deepseek-v4-flash__mini20__test.jsonl` | 20 条预测 |
| Docker 镜像 | `sweb.base.py.arm64` + **12 个 env 镜像**（约 30GB，`--cache_level env` 保留） |
| `~/.cache/swebench-reqs/` | 13 个 requirements 文件的磁盘缓存（Patch E2），离线可用 |
| `~/.cache/huggingface/` | SWE-bench_Lite 数据集已缓存 |

磁盘 3.1T 可用，充裕。

### 续跑前必做（按优先级）

1. **确认补丁还在**（若期间动过 SWE-bench 源码）：
   ```bash
   ssh -i ~/.ssh/vgio admin@100.97.87.120 \
     'cd /home/admin/swebench-eval && .venv/bin/python scripts/verify_patches.py'
   ```
   预期 9 行全是 `OK`。任何 `MISSING` → 重跑 `scripts/apply_patches.py`。
2. **确认 vLLM 在线**：`curl -s http://100.97.87.120:8000/v1/models`
3. **每次新 shell 都要 `export HF_ENDPOINT=https://hf-mirror.com`**（服务器直连
   huggingface.co 不通）。
4. **修 3 个已知基础设施缺陷**（详见 `build-failures.md`）——不修就上全量会有约 30%
   实例跑不起来：
   - base 镜像 apt 加 `gfortran`（改
     `swebench/harness/dockerfiles/python.py` 的 `_DOCKERFILE_BASE_PY`），
     **注意：改 base 会使全部 12 个 env 镜像失效需重建，约 1–2 小时**；
   - pylint 的 `pip install -e .` → 降级 pip 或 `--no-use-pep517`；
   - `cdms2`（xarray）在 aarch64 无解，接受失败并标注。

### 两条路线，先想清楚要哪个

- **路线 A：把当前设置放大到全量 Lite（300）。** 推理单路约 11 小时
  （135 s/实例，可用 `--shard_id/--num_shards` 切 2–4 路，注意 `max_num_seqs=6`
  的并发上限），评测另需数小时。得到的是一个**和业界口径对不上**的数字。
- **路线 B（推荐）：换 agentic scaffold（SWE-agent / mini-swe-agent）跑 SWE-bench
  Verified。** 本次已验证模型的函数调用与长上下文都正常，且最大失败模式
  （手写 diff 的 hunk 行数算错，7/20）正是 agentic scaffold 能消除的。
  评测侧的全部 ARM 补丁可以直接复用。

> 无论走哪条，**Phase 4.1 的 gold patch 验证要重跑一次**（尤其在改过 base 镜像之后），
> 确认环境仍然保真：
> ```bash
> .venv/bin/python -m swebench.harness.run_evaluation \
>   --dataset_name princeton-nlp/SWE-bench_Lite --split test \
>   --predictions_path gold --instance_ids sympy__sympy-20590 \
>   --namespace none --max_workers 1 --cache_level instance \
>   --run_id gold-validate-arm64
> ```

## 文件清单

| 文件 | 内容 |
|---|---|
| `README.md` | 本文件 |
| `build-failures.md` | 13 条 error 的逐条归因 |
| `deepseek-v4-flash.dsv4flash-smoke-20.json` | 评测报告（官方格式） |
| `gold.gold-validate-arm64.json` | gold patch 的 ARM64 链路验证报告 |
| `deepseek-v4-flash__mini20__test.jsonl` | 20 条预测（含 `full_output` 与 `model_patch`） |
| `smoke_instances.txt` | 可复现的 20 条实例清单（seed=42） |
| `apply_patches.py` | 全部 9 处补丁，幂等 |
| `filter_text_dataset.py` | 从全量文本数据集切子集 |
| `summarize_report.py` | 报告汇总/分仓库统计 |

服务器工作区：`/home/admin/swebench-eval/`（venv、text_datasets、predictions、logs）。

## 复现

```bash
ssh -i ~/.ssh/vgio admin@100.97.87.120
cd /home/admin/swebench-eval && export HF_ENDPOINT=https://hf-mirror.com

# 推理
.venv/bin/python -m swebench.inference.run_api \
  --dataset_name_or_path text_datasets/mini20 --split test \
  --model_name_or_path deepseek-v4-flash \
  --output_dir predictions --model_args "top_p=0.95"

# 评测（--namespace none 是必须的）
.venv/bin/python -m swebench.harness.run_evaluation \
  --dataset_name princeton-nlp/SWE-bench_Lite --split test \
  --predictions_path predictions/deepseek-v4-flash__mini20__test.jsonl \
  --instance_ids $(cat smoke_instances.txt | tr '\n' ' ') \
  --namespace none --max_workers 3 --timeout 1800 \
  --cache_level env --run_id dsv4flash-smoke-20
```

> `max_workers` 压到 3（计划里是 4）：CLAUDE.md 记录过在 S1 并发编译把头节点 OOM、
> 连 vLLM 生产栈一起打掉的事故，而 ARM 上源码编译更吃内存。本次全程可用内存维持在
> 10–13G，vLLM 未受影响。
