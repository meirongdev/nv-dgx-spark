# DeepSeek-V4-Flash 跑 SWE-bench 评估实施方案

> ## ⚠️ 本计划已于 2026-08-01 执行完毕 —— 先读勘误再动手
>
> **结果与完整记录：[`benchmarks/swe-bench-deepseek-v4-flash-2026-08-01/`](../../../benchmarks/swe-bench-deepseek-v4-flash-2026-08-01/README.md)**
> （冒烟 20 条：resolved 2/14 可评测 = 14.3%，空 patch 率 0%，gold patch ARM64 验证通过）
>
> 计划的整体架构是对的，Phase 0 的勘察结论也准确，但**下面这些地方按原文执行会失败**。
> 服务器环境现已全部就绪（补丁已应用、全量文本数据集已建、12 个 env 镜像已缓存），
> 续跑请直接看归档 README 的「服务器当前状态（续跑起点）」一节，**不需要重做 Phase 0–2**。
>
> ### 计划中确认有误 / 不完整的地方
>
> | 计划原文 | 实际情况 |
> |---|---|
> | Step 1.2 `pip install -e ".[inference]"` | **装不上**：`flash_attn` 需 torch，aarch64 编译失败。API 推理路径应用 `.[datasets]` |
> | Step 1.3 Patch A 只改 `get_test_specs_from_dataset` | **不够**：`run_evaluation.py:306` 直接调 `make_test_spec` 绕过它，镜像仍是 x86_64。应改 `make_test_spec` 的默认 `arch` |
> | Step 1.4 Patch B「三处」 | **是四处**：还须给 `MODEL_COST_PER_INPUT/OUTPUT` 加零成本条目。`calc_cost()` 是裸字典查找且在 `@retry` 内,`KeyError` 会先耗掉 3 次重试(30–600s 退避)再崩 |
> | Step 1.3 验证片段用 `ds[:1]` | HF Dataset 切片返回列字典,`dataset[0]` 会 KeyError。应用 `[ds[0]]` |
> | Phase 0.3「外网连通 ✅(从 Mac 验证)」 | **服务器侧 `huggingface.co` 与 Docker Hub 均不通**。需 `HF_ENDPOINT=https://hf-mirror.com`,并用 daocloud 预拉 `ubuntu:22.04` 再 retag。anaconda/conda-forge/PyPI/ports.ubuntu.com/github.com 直连可达 |
> | Phase 4 所有 `run_evaluation` 命令 | **漏了 `--namespace none`**。默认 `namespace=swebench` 会去**拉** Docker Hub 的 x86_64 预编译镜像而非本地构建(ARM 根本没有这些镜像) |
> | 各处 `--report_dir` | **上游 4.1.0 的 bug**:目录会被 mkdir 但从未传给 `make_run_report`,报告始终落在 CWD,文件名是 `<model>.<run_id>.json` |
> | Step 5.1 汇总脚本读 `d["resolved"]` | 字段名不对。实际是 `resolved_instances` / `resolved_ids` 等,见归档里的 `summarize_report.py` |
> | Step 3.1 `--model_args "…,max_tokens=8192"` | `run_api` 只把 `temperature`/`top_p` 传给 API,**`max_tokens` 被静默忽略**。反而是好事:实测最大输出 16,166 tokens,8192 会截断 |
> | Step 3.3/3.4 回退 A/B(thinking 干扰) | **未发生,没用上**。部署带 `--reasoning-parser deepseek_v4`,思考走 `reasoning_content`,`content` 是干净的 `<patch>` 块 |
> | 风险表「ARM env 构建失败」 | 确实发生,但根因比预期具体,且**需要 3 个计划里没有的补丁**(见下) |
>
> ### 计划完全没有预见、但必须打的补丁
>
> 全部收在归档目录的 `apply_patches.py`(幂等,可重放),共 9 处：
>
> - **Patch C** — 内置 `environment.yml` 是 x86_64 的 `conda env export` 快照
>   (`py39h06a4308_0`、`ld_impl_linux-64`),aarch64 上 `PackagesNotFoundError`。
>   ARM 上跳过该缓存,回落到 spec 现解路径。
> - **Patch D** — **与 ARM 无关**:sympy 等上游已删除旧发布分支,
>   `git clone --branch 1.7` 直接失败。需全量 clone 回退 + base commit 存在性检查。
> - **Patch E/E2** — 4 处 `requests.get()` 无超时,从 CN 拉
>   `raw.githubusercontent.com` 偶发挂死 → **整轮评测无限等待且日志零输出**
>   (本次耗时最久的坑,最后靠 py-spy dump 栈定位)。且**裸加超时不够**——这些调用在
>   `get_test_specs_from_dataset` 里对全部实例前置执行,一次 `ReadTimeout` 就中止整轮,
>   必须带重试 + 磁盘缓存。
>
> ### 并发建议修正
>
> 计划的 `--max_workers 4` 实际用了 **3**：CLAUDE.md 记录过在 S1 并发编译把头节点
> OOM、连 vLLM 生产栈一起打掉的事故,而 ARM 上源码编译(scipy/numpy 等)更吃内存。
> 用 3 时全程可用内存维持 10–13G,vLLM 未受影响。

> **For agentic workers:** 执行本计划时,建议用 superpowers:executing-plans(或 subagent-driven-development)按任务逐条执行。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 对当前 Codex 正在使用的模型(`deepseek-v4-flash`,即 DeepSeek-V4-Flash-0731 FP8,双 GB10 TP=2 vLLM)在 SWE-bench 上跑出可复现的通过率,并把报告归档到 `benchmarks/`。

**Architecture:** 推理复用现有 vLLM OpenAI 兼容端点(`http://100.97.87.120:8000/v1`),用 SWE-bench 官方 `run_api.py` 的 ReAct 推理逐条生成 patch;评测在 DGX 服务器上用官方 harness 原生构建 ARM64(`linux/arm64/v8`)评测镜像并跑测试。推理/评测两阶段,所有中间产物(数据集缓存、文本数据集、预测 jsonl、Docker 镜像、日志)都留在服务器 `/home/admin/swebench-eval/`,仓库只归档最终报告与样本清单。

**Tech Stack:** SWE-bench(princeton-nlp,main 分支)、Python 3.10+ / venv(服务器有 uv 则优先)、HuggingFace `datasets`、Docker(aarch64)、vLLM(jasl fork,已部署)。

---

## 1. 背景与已验证事实(2026-08-01 勘察)

以下结论已在 2026-08-01 实际验证,执行时无需重复勘察(只需做 Phase 0 的运行时健康检查)。

| 项目 | 状态 | 说明 |
|---|---|---|
| 模型服务 | ✅ 在线 | `deepseek-v4-flash`,`max_model_len=1000000`,`http://100.97.87.120:8000/v1` |
| 函数调用能力 | ✅ 冒烟通过 | 实测返回合法 `tool_calls`(OpenAI 兼容格式) |
| 推理/评测节点 | aarch64 | `100.97.87.120`:20 核、121G 内存(空闲约 14G)、3.1T 磁盘、有 Docker |
| SWE-bench ARM 支持 | ✅ 原生支持 | `TestSpec` 支持 `arch="arm64"` → platform `linux/arm64/v8`,base 镜像 = `ubuntu` + Miniconda3-aarch64 |
| 现成 ARM 镜像 | ❌ 无 | Docker Hub 仅发布 `sweb.eval.x86_64.*`;ARM 必须本地构建(base → env → instance) |
| 外网连通 | ✅ 从 Mac 验证 | HuggingFace / GitHub / Docker Hub 均 HTTP 200(服务器侧需在 Phase 0 复验) |
| 本机 swebench | ❌ 未安装 | 需在服务器新建环境 |
| run_api 对自定义模型 | ❌ 需小补丁 | 见 Phase 1 Patch B(模型名白名单 + tokenizer + 分发三处) |
| harness 架构自动检测 | ❌ 默认 x86_64 | `get_test_specs_from_dataset` 不传 arch,需补丁(见 Phase 1 Patch A) |

**关键结论**:完全可行。主路径 = `run_api` ReAct 推理 + `run_evaluation`(带 arch=arm64 补丁)。所有必改补丁与风险缓解都已写在计划内。

## 2. 关键决策与默认值

| 决策点 | 默认值 | 理由 |
|---|---|---|
| 评测位置 | 服务器 `100.97.87.120` | 原生 ARM Docker、磁盘充足;备选:Mac 的 OrbStack(同为 arm64) |
| 数据集/子集 | 冒烟 20 条 → 全量 `princeton-nlp/SWE-bench_Lite`(300) | 先验证 ARM 构建成功率再放量;备选 Verified(500) |
| 推理路径 | `run_api` ReAct(`style-3` + `file_source=oracle`) | 官方脚本、轻量;thinking 模式风险与回退见 Phase 3 |
| 推理并发 | 单路串行 | vLLM 只留 ~14G 内存,单路最稳;需要加速用 `--shard_id/--num_shards` 横向扩展 |
| 评测并发 | `--max_workers 4` | 20 核 + 内存约束下的保守值 |
| 冒烟采样 | seed=42,每仓库最多 2 条,共 20 条 | 跨仓库覆盖,样本清单落盘可复现 |
| 采样参数 | `top_p=0.95`,`max_tokens=8192` | 与模型卡(0731)agentic 建议一致 |
| 产物目录(服务器) | `/home/admin/swebench-eval/` | 所有中间产物集中管理 |

## Phase 0 — 前置检查(执行前一次性,约 10 分钟)

- [ ] **Step 0.1:确认 vLLM 服务健康**

```bash
curl -s -m 10 http://100.97.87.120:8000/v1/models
```

期望输出:返回 `"id":"deepseek-v4-flash"` 且 `"max_model_len":1000000`。

- [ ] **Step 0.2:确认服务器资源与 Docker**

```bash
ssh -i /Users/matthew/.ssh/vgio -o StrictHostKeyChecking=no admin@100.97.87.120 \
  'uname -m; nproc; free -g | head -2; df -h / | tail -1; docker info --format "server={{.ServerVersion}} arch={{.Architecture}}"; docker ps --format "{{.Names}} {{.Ports}}"'
```

期望:架构 `aarch64`;可用内存 ≥ 8G;磁盘 ≥ 100G;Docker 正常;能看到 vLLM 容器(名字含 `vllm-node-dsv4`)。**Gate**:任何一项不满足 → 停手,先解决资源问题(或改用 Mac OrbStack 执行)。

- [ ] **Step 0.3:确认服务器到外网可达(HF/GitHub)**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 \
  'curl -s -o /dev/null -w "hf:%{http_code} " -m 15 https://huggingface.co; curl -s -o /dev/null -w "gh:%{http_code}\n" -m 15 https://github.com'
```

期望:两个 200。若不通:参考 `docs/china-network-mirrors-cn.md` 与 `docs/deepseek-v4-flash-cn.md` 的 v2rayn 代理段,在服务器上 `git config --global http.proxy http://172.17.0.1:10809` 并给 docker 配 proxy,再重试。

## Phase 1 — 环境准备(服务器,约 20–30 分钟)

- [ ] **Step 1.1:建目录并 clone SWE-bench**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 \
  'mkdir -p /home/admin/swebench-eval && cd /home/admin/swebench-eval && \
   git clone https://github.com/princeton-nlp/SWE-bench.git .'
```

- [ ] **Step 1.2:创建虚拟环境并安装(含 inference 依赖)**

优先 uv(与仓库 Makefile 一致);服务器没有 uv 就用 venv:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && \
  (command -v uv >/dev/null && uv venv .venv && uv pip install -e ".[inference]") || \
  (python3 -m venv .venv && .venv/bin/pip install -e ".[inference]")'
```

期望:安装结束无报错;`export PATH=/home/admin/swebench-eval/.venv/bin:$PATH` 后 `python -c "import swebench; print(swebench.__version__)"` 有输出。

- [ ] **Step 1.3:Patch A — harness 自动检测 ARM64 架构**

修改 `swebench/harness/test_spec/test_spec.py`:

1) 文件顶部 imports 区(约第 1–20 行)加入 `import platform`。
2) 把 `get_test_specs_from_dataset`(约第 155–169 行)改为:

```python
def get_test_specs_from_dataset(
    dataset: Union[list[SWEbenchInstance], list[TestSpec]],
    namespace: Optional[str] = None,
    instance_image_tag: str = LATEST,
    env_image_tag: str = LATEST,
) -> list[TestSpec]:
    """
    Idempotent function that converts a list of SWEbenchInstance objects to a list of TestSpec objects.
    """
    if isinstance(dataset[0], TestSpec):
        return cast(list[TestSpec], dataset)
    # local patch: build arm64 images natively on ARM hosts (2026-08-01)
    host_machine = platform.machine().lower()
    arch = "arm64" if host_machine in ("aarch64", "arm64") else "x86_64"
    return list(
        map(
            lambda x: make_test_spec(
                x, namespace, instance_image_tag, env_image_tag, arch=arch
            ),
            cast(list[SWEbenchInstance], dataset),
        )
    )
```

验证:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python - <<"PY"
from datasets import load_dataset
from swebench.harness.test_spec.test_spec import get_test_specs_from_dataset
ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
specs = get_test_specs_from_dataset(ds[:1], None, "latest", "latest")
print("arch =", specs[0].arch)
print("platform =", specs[0].platform)
assert specs[0].arch == "arm64"
PY'
```

期望输出:`arch = arm64`、`platform = linux/arm64/v8`。

- [ ] **Step 1.4:Patch B — run_api 支持自定义模型名**

修改 `swebench/inference/run_api.py` 三处:

1) `MODEL_LIMITS` 字典(第 32 行起)追加:

```python
    "deepseek-v4-flash": 200_000,
```

2) 第 193 行(`openai_inference` 内):

```python
    encoding = tiktoken.get_encoding("cl100k_base")  # local patch: custom model
```

(原代码 `tiktoken.encoding_for_model(model_name_or_path)` 不认识自定义模型名会抛错;cl100k_base 仅用于长度过滤的近似,无碍。)

3) 第 502–504 行分发逻辑:

```python
    if model_name_or_path.startswith("claude"):
        anthropic_inference(**inference_args)
    elif model_name_or_path.startswith("gpt") or model_name_or_path == "deepseek-v4-flash":
        openai_inference(**inference_args)
```

验证:`python -c "import ast; ast.parse(open('swebench/inference/run_api.py').read())"` 无语法错误。

- [ ] **Step 1.5:配置 `.env`(run_api 用 dotenv 读取)**

新建 `/home/admin/swebench-eval/.env`:

```bash
OPENAI_API_KEY=dummy
OPENAI_BASE_URL=http://100.97.87.120:8000/v1
```

(vLLM 未设 `--api-key` 时忽略 key;`OPENAI_BASE_URL` 让 openai SDK 指向集群端点。)

## Phase 2 — 数据准备(约 10 分钟 + 首次拉取时间)

- [ ] **Step 2.1:确认 Lite 数据集可取并看规模**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python -c "from datasets import load_dataset; ds=load_dataset(\"princeton-nlp/SWE-bench_Lite\", split=\"test\"); print(len(ds))"'
```

期望输出:`300`。

- [ ] **Step 2.2:生成 20 条冒烟样本清单(可复现)**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python - <<"PY"
import random
from datasets import load_dataset
ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
random.seed(42)
by_repo = {}
for x in ds:
    by_repo.setdefault(x["repo"], []).append(x["instance_id"])
picked = []
for repo in sorted(by_repo):
    ids = by_repo[repo][:]
    random.shuffle(ids)
    picked.extend(ids[:2])
    if len(picked) >= 20:
        break
picked = picked[:20]
open("/home/admin/swebench-eval/smoke_instances.txt", "w").write("\n".join(picked) + "\n")
print(len(picked))
print("\n".join(picked))
PY'
```

期望:打印 20 个 `repo__name-issue` 形式的 id,并落盘 `smoke_instances.txt`。

- [ ] **Step 2.3:构建 Lite 全量 ReAct 文本数据集(style-3 + oracle 文件检索)**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python -m swebench.inference.make_datasets.create_text_dataset \
    --dataset_name_or_path princeton-nlp/SWE-bench_Lite \
    --splits test \
    --output_dir /home/admin/swebench-eval/text_datasets \
    --prompt_style style-3 \
    --file_source oracle'
```

产出目录:`/home/admin/swebench-eval/text_datasets/SWE-bench_Lite__style-3__fs-oracle/`(含 `test` split)。执行时如遇单条实例超长,可加 `--max_context_len 200000 --tokenizer_name deepseek`(若选项不支持则忽略,1M 上下文一般够用)。

- [ ] **Step 2.4:从文本数据集切出 20 条冒烟子集**

新建 `/home/admin/swebench-eval/scripts/filter_text_dataset.py`:

```python
#!/usr/bin/env python3
"""Filter a SWE-bench text dataset to a subset of instance ids."""
import argparse
from datasets import load_from_disk

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--text-dataset", required=True)
    p.add_argument("--ids", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--split", default="test")
    args = p.parse_args()

    ds = load_from_disk(args.text_dataset)
    wanted = set(x.strip() for x in open(args.ids) if x.strip())
    subset = ds[args.split].filter(lambda x: x["instance_id"] in wanted)
    print(f"kept {len(subset)} / {len(ds[args.split])} from split {args.split}")
    subset.save_to_disk(args.output)

if __name__ == "__main__":
    main()
```

运行:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python scripts/filter_text_dataset.py \
    --text-dataset /home/admin/swebench-eval/text_datasets/SWE-bench_Lite__style-3__fs-oracle \
    --ids /home/admin/swebench-eval/smoke_instances.txt \
    --output /home/admin/swebench-eval/text_datasets/mini20'
```

期望输出:`kept 20 / 300 from split test`。
## Phase 3 — 推理生成 patch(核心;冒烟 20 条约 0.5–1.5h,全量 300 条单路约 1–2 天)

- [ ] **Step 3.1:冒烟推理(20 条)**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'mkdir -p /home/admin/swebench-eval/logs && cd /home/admin/swebench-eval && nohup .venv/bin/python -m swebench.inference.run_api \
    --dataset_name_or_path /home/admin/swebench-eval/text_datasets/mini20 \
    --split test \
    --model_name_or_path deepseek-v4-flash \
    --output_dir /home/admin/swebench-eval/predictions \
    --model_args "top_p=0.95,max_tokens=8192" \
    > /home/admin/swebench-eval/logs/run_api_smoke.log 2>&1 &'
```

产出文件:`/home/admin/swebench-eval/predictions/deepseek-v4-flash__mini20__test.jsonl`(每行一个 `instance_id` + `full_output` + `model_patch`,脚本可断点续跑)。

- [ ] **Step 3.2:检查输出质量**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python - <<"PY"
import json
rows=[json.loads(l) for l in open("predictions/deepseek-v4-flash__mini20__test.jsonl")]
n=len(rows)
patched=sum(1 for r in rows if (r.get("model_patch") or "").strip())
empty=sum(1 for r in rows if not (r.get("model_patch") or "").strip())
avg=sum(len(r.get("full_output") or "") for r in rows)//max(n,1)
print(f"instances={n} with_patch={patched} empty_patch={empty} avg_full_output_len={avg}")
PY'
```

**Gate:** `with_patch >= 60%` 且不是系统性失败(例如所有输出只有 thinking 块、没有 diff)。不满足 → 走回退 A;回退 A 仍不行 → 走回退 B。

- [ ] **Step 3.3(回退 A):关闭 thinking 再试**

原因:部署用了 `--default-chat-template-kwargs '{"thinking":true}'`,ReAct 的显式 `Thought:` 与模型原生思考可能互相干扰。

首选在 `--model_args` 里追加每请求参数:

```bash
--model_args "top_p=0.95,max_tokens=8192,chat_template_kwargs={'thinking': false}"
```

若 vLLM 拒绝该参数(BadRequest),则按 `docs/deepseek-v4-flash-cn.md` / `make v4flash-run` 的 runbook 再起一个 vLLM 实例,端口 `8001`,命令行加 `--default-chat-template-kwargs '{"thinking":false}'`,然后把 `.env` 的 `OPENAI_BASE_URL` 指向 `http://100.97.87.120:8001/v1` 重跑 3.1。

- [ ] **Step 3.4(回退 B):SWE-agent 工具调用路径**

若 ReAct 两条路都不稳定,改用已验证可用的函数调用接口跑 SWE-agent(服务器装 `pip install sweagent`,配置 `openai` 后端 + `base_url=http://100.97.87.120:8000/v1` + 模型 `deepseek-v4-flash`)。SWE-agent 具体参数以其官方 README 为准(本计划撰写时其 CLI 变动频繁,执行时按当时版本填写);产出的预测仍写成与 Step 3.1 相同的 jsonl 格式(`instance_id` / `model_name_or_path` / `model_patch`),供 Phase 4 直接消费。

- [ ] **Step 3.5:全量 Lite(300 条)推理**

冒烟通过后,对全量文本数据集跑:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && nohup .venv/bin/python -m swebench.inference.run_api \
    --dataset_name_or_path /home/admin/swebench-eval/text_datasets/SWE-bench_Lite__style-3__fs-oracle \
    --split test \
    --model_name_or_path deepseek-v4-flash \
    --output_dir /home/admin/swebench-eval/predictions \
    --model_args "top_p=0.95,max_tokens=8192" \
    > /home/admin/swebench-eval/logs/run_api_lite.log 2>&1 &'
```

需要加速时按 4 路切分并行(每路独立 jsonl,评测前合并):

```bash
for s in 0 1 2 3; do
  ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 "cd /home/admin/swebench-eval && nohup .venv/bin/python -m swebench.inference.run_api \
    --dataset_name_or_path /home/admin/swebench-eval/text_datasets/SWE-bench_Lite__style-3__fs-oracle \
    --split test --model_name_or_path deepseek-v4-flash \
    --output_dir /home/admin/swebench-eval/predictions \
    --model_args 'top_p=0.95,max_tokens=8192' \
    --shard_id $s --num_shards 4 \
    > /home/admin/swebench-eval/logs/run_api_lite_shard$s.log 2>&1 &"
done
```

监控(容器名以 `docker ps` 为准):

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'docker logs vllm-node-dsv4 --tail 30'
```

## Phase 4 — 评测(构建 ARM 镜像 + 跑测试;冒烟 20 条约 1–3h)

- [ ] **Step 4.1:用 gold patch 验证整个 ARM 构建/评测链路(单条)**

这是最快验证 harness 在 arm64 上能否跑通的方式:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --split test \
    --predictions_path gold \
    --instance_ids sympy__sympy-20590 \
    --max_workers 1 \
    --timeout 1800 \
    --run_id gold-validate-arm64 \
    --report_dir /home/admin/swebench-eval/reports'
```

期望:自动构建 `sweb.base.python.arm64` → env → instance 镜像(构建日志在 `logs/build_images/`),跑完测试,`reports/gold-validate-arm64.json` 里该实例 resolved。**Gate**:这条失败 → 不要放量,先修 ARM 构建问题(见风险表)。

- [ ] **Step 4.2:评测 20 条冒烟**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && \
  .venv/bin/python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --split test \
    --predictions_path /home/admin/swebench-eval/predictions/deepseek-v4-flash__mini20__test.jsonl \
    --instance_ids $(cat /home/admin/swebench-eval/smoke_instances.txt) \
    --max_workers 4 \
    --timeout 1800 \
    --run_id dsv4flash-smoke-20 \
    --report_dir /home/admin/swebench-eval/reports'
```

构建与测试日志在 `/home/admin/swebench-eval/logs/` 与 `logs/build_images/`。**记录**:哪些实例镜像构建失败、哪些测试超时,失败原因写入 `benchmarks/swe-bench-deepseek-v4-flash-<date>/build-failures.md`。

- [ ] **Step 4.3:评测全量 Lite**

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && \
  .venv/bin/python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --split test \
    --predictions_path /home/admin/swebench-eval/predictions/deepseek-v4-flash__SWE-bench_Lite__style-3__fs-oracle__test.jsonl \
    --max_workers 4 \
    --timeout 1800 \
    --cache_level env \
    --run_id dsv4flash-lite \
    --report_dir /home/admin/swebench-eval/reports'
```

提示:`--cache_level env` 保留 base/env 镜像、仅清理 instance 镜像,换子集重跑时省掉最贵的构建;预测文件名若因 shard 合并不同,以实际文件名替换。

## Phase 5 — 汇总报告与归档(约 10 分钟)

- [ ] **Step 5.1:从评测报告提取结果**

`reports/dsv4flash-smoke-20.json` 等文件包含每实例状态(`resolved` / `failed` / `error` / `empty patch`)。汇总:

```bash
ssh -i /Users/matthew/.ssh/vgio admin@100.97.87.120 'cd /home/admin/swebench-eval && .venv/bin/python - <<"PY"
import json
for path in ["reports/dsv4flash-smoke-20.json"]:
    d = json.load(open(path))
    stats = {}
    for v in d.get("resolved", {}).values():
        if isinstance(v, dict):
            stats[v.get("status", "unknown")] = stats.get(v.get("status", "unknown"), 0) + 1
    print(path, stats)
PY'
```

- [ ] **Step 5.2:归档到仓库 `benchmarks/`**

```bash
DEST=benchmarks/swe-bench-deepseek-v4-flash-2026-08-01
mkdir -p "$DEST"
scp -i /Users/matthew/.ssh/vgio admin@100.97.87.120:/home/admin/swebench-eval/reports/dsv4flash-smoke-20.json "$DEST/"
scp -i /Users/matthew/.ssh/vgio admin@100.97.87.120:/home/admin/swebench-eval/predictions/deepseek-v4-flash__mini20__test.jsonl "$DEST/"
scp -i /Users/matthew/.ssh/vgio admin@100.97.87.120:/home/admin/swebench-eval/smoke_instances.txt "$DEST/"
```

在 `$DEST/README.md` 写运行元数据:日期、模型名/版本、数据集与实例数、推理参数、评测参数、结果统计、构建失败清单、机器与内存占用、结论(是否值得上全量)。

## 风险与回退

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| ARM 上部分实例 conda/env 镜像构建失败(锁旧版 C 依赖) | 中 | 单条失败,可跳过 | Step 4.1 先验一条;失败实例记录并统计占比,不阻塞其余 |
| thinking 模式干扰 ReAct 输出 | 中 | 空 patch 率高 | Step 3.2 Gate → 回退 A(thinking=false)→ 回退 B(SWE-agent) |
| 服务器内存不足(空闲 ~14G)导致并行构建 OOM | 中 | 构建失败/慢 | `--max_workers 4`;构建阶段可降到 1–2;避开 vLLM 高峰 |
| 服务器外网不通(HF/pip/miniconda) | 低(已从 Mac 验证) | 无法拉数据/依赖 | Phase 0 Step 0.3 复验;走 v2rayn 代理;或 Mac 拉好后 scp |
| vLLM 并发高时 tok/s 下降 | 中 | 推理变慢 | 单路串行;必要时加 shard 但监控内存 |
| `run_api` 对长上下文(>200k tokens)实例的过滤误伤 | 低 | 少量实例被跳过 | `MODEL_LIMITS` 已设 200k;记录被过滤实例数,必要时提高 |

## 验收标准

1. Phase 1 两个补丁验证通过(arch=arm64、run_api 可跑)。
2. 冒烟 20 条完整跑通:推理 → 评测 → 报告,`benchmarks/swe-bench-deepseek-v4-flash-2026-08-01/` 下报告、预测 jsonl、样本清单、README 齐全。
3. 报告包含:总实例数、resolved / failed / error / empty-patch 统计、镜像构建失败实例清单。
4. 记录"是否上全量 Lite(或 Verified)"的决策与依据,留档在 README。

## 附录 A:命令速查表

| 用途 | 命令 |
|---|---|
| 模型健康 | `curl -s http://100.97.87.120:8000/v1/models` |
| 服务器资源 | `ssh -i ~/.ssh/vgio admin@100.97.87.120 'free -g \| head -2; df -h / \| tail -1; docker ps'` |
| 推理(20 条) | `python -m swebench.inference.run_api --dataset_name_or_path .../mini20 --split test --model_name_or_path deepseek-v4-flash --output_dir .../predictions --model_args "top_p=0.95,max_tokens=8192"` |
| 评测(20 条) | `python -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Lite --predictions_path ...jsonl --instance_ids $(cat smoke_instances.txt) --max_workers 4 --run_id dsv4flash-smoke-20 --report_dir .../reports` |
| gold 链路验证 | `python -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Lite --predictions_path gold --instance_ids sympy__sympy-20590 --max_workers 1 --run_id gold-validate-arm64 --report_dir .../reports` |

## 附录 B:路径与文件约定

- 服务器工作区:`/home/admin/swebench-eval/`(`.env`、`.venv/`、`predictions/`、`text_datasets/`、`reports/`、`logs/`、`scripts/`、`smoke_instances.txt`)
- 仓库归档:`benchmarks/swe-bench-deepseek-v4-flash-<date>/`(报告 + 预测 + 样本 + README)
- 本计划:本文件(`docs/superpowers/plans/2026-08-01-swebench-deepseek-v4-flash.md`)
- 相关既有文档:`docs/deepseek-v4-flash-cn.md`(部署/runbook)、`docs/china-network-mirrors-cn.md`(代理)
