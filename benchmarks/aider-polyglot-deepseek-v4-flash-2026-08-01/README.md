# Aider polyglot (Python subset) — DeepSeek-V4-Flash on dual DGX Spark (2026-08-01)

34 道 Python 练习 × 两种 edit format 的对照跑分。**这不是 aider polyglot 榜单分数**
（榜单是 225 题 × 6 语言），是为了回答一个具体问题：

> SWE-bench 跑出 14.3%，且 19/20 条预测的 unified diff hunk 头行数算错。
> 这到底是「模型不会做结构化编辑」，还是「模型不会手写 diff 的行号」？

**答案：是后者。** 换成不需要算行号的编辑格式后，格式合规率 100%、通过率 82–88%。

## 结果

| | **diff** | **whole** |
|---|---|---|
| 题数 | 34 | 34 |
| pass_rate_1（首轮） | **35.3%** (12/34) | 26.5% (9/34) |
| pass_rate_2（带测试输出重试后） | 82.4% (28/34) | **88.2%** (30/34) |
| **percent_cases_well_formed** | **100.0%** | **100.0%** |
| num_malformed_responses | **0** | **0** |
| syntax / indentation errors | 0 / 0 | 0 / 0 |
| lazy_comments | 2 | 0 |
| prompt / completion tokens | 227,954 / 314,086 | 169,984 / 352,907 |
| seconds_per_case | 1225.6 s | 1381.5 s |

逐题对照（同一批 34 题）：

```
两种格式都失败 : 3   dot-dsl, go-counting, react     <- 真正难的题
只有 diff 失败 : 3   bowling, connect, hangman
只有 whole 失败: 1   paasio
```

## 结论

### 1. 模型没有编辑格式问题

两种格式都是 100% well-formed、0 条 malformed。SWE-bench 那边的失败测的是
**手写 unified diff 时自己算 hunk 头行数**的能力（`@@ -189,8 +189,9 @@` 声称 8 行
却只给 4 行上下文）。aider 的 SEARCH/REPLACE 用精确匹配锚点，不需要任何行号算术，
模型就完全没问题。这是两种不同的能力，SWE-bench 的单轮设置把它们混在了一起。

### 2. diff 与 whole 的差异不显著

28/34 vs 30/34 只差 2 题，不一致的仅 4 题（diff-only 失败 3，whole-only 失败 1）。

- **McNemar 精确检验 p = 0.625** —— 完全不显著
- 95% CI：diff 70–95%，whole 77–99%，大幅重叠

**实践含义：没有理由把 Codex/qwen 切成整文件重写模式。** diff 的 completion token
更省（314k vs 353k），首轮正确率还更高。

### 3. 真正的杠杆是迭代，不是格式

首轮 26–35% → 第二轮 82–88%（2.5–3 倍）。这一条比编辑格式的选择重要一个数量级，
也解释了为什么各家模型卡的 agentic 分数远高于 SWE-bench 的单轮 oracle 设置。

## 口径限制

- **不可与 aider polyglot 榜单对比**：榜单 225 题 / 6 语言，这里只有 Python 34 题。
- n = 34，置信区间很宽。
- 采样即模型服务默认（`temperature` 由 aider 决定，服务端 `top_p=0.95`，thinking 默认开）。
- 未跑其余 5 种语言，原因见下面「Java 的已知障碍」。

## 运行配置

| 项 | 值 |
|---|---|
| 日期 | 2026-08-01 22:40 → 2026-08-02 03:08（两个跑分并行，共 4.5 小时） |
| 模型 | `deepseek-v4-flash` = DeepSeek-V4-Flash-0731 FP8，双 GB10 TP=2 + DSpark(n=5) |
| 端点 | `http://172.17.0.1:8000/v1`（容器经 docker bridge 访问宿主 vLLM） |
| harness | aider `0.86.3.dev`（codeload tarball，commit `b202737` 为本地快照） |
| 题库 | `Aider-AI/polyglot-benchmark` main，Python 34 题 |
| 并发 | 每个跑分 3 threads，两个并行 = 6，正好是 `max_num_seqs=6` 上限 |
| tries | 2（首轮 + 带测试输出重试，polyglot 标准协议） |

> 6 路并发几乎不提升总吞吐（CLAUDE.md 已记录：6 并发聚合 ~50 tok/s vs 单流 56），
> 所以 4.5 小时基本等于串行时间。要加速只能减少 thinking 或降低题量。

## 为在 aarch64 + 国内网络跑通所做的改动

全部在 `Dockerfile.cn-arm`（上游 `benchmark/Dockerfile` 的改写版）与 `build_noproxy.sh`。

| # | 问题 | 处理 |
|---|---|---|
| 1 | daocloud 拉 `buildpack-deps:jammy` 仅 **39 KB/s**（2GB 要 14h） | 改用本地已有的 `ubuntu:22.04`，自装 buildpack-deps 提供的构建工具 |
| 2 | 裸 `ubuntu:22.04` 无 ca-certificates，`https://` apt 源握手失败 → 所有包 "Unable to locate" | apt 源用 `http://`（apt 本就用 GPG 验包，与传输层无关） |
| 3 | **`~/.docker/config.json` 强制所有构建走 xray 代理**：实测经代理 18 KB/s vs 直连同一清华源 1.6 MB/s（慢 90 倍） | 构建期间把该文件挪开（**客户端**配置，不需重启 daemon，运行中的 vLLM 容器不受影响），`trap ... EXIT` 保证还原 |
| 4 | `setuptools_scm` 取不到版本（下的是 tarball，无 `.git`） | `ENV SETUPTOOLS_SCM_PRETEND_VERSION_FOR_AIDER_CHAT=0.86.3.dev0` |
| 5 | `-e /aider[dev]` 依赖不可解 | `[dev]` 约束 pin `numpy==2.4.3`（需 py≥3.11），而 base aider 在 py<3.11 时要求 `numpy<2`。**上游装 deadsnakes/python3.11 正是为了绕开这个**；deadsnakes 从国内不可达且 arm64 覆盖不确定，改为装 base aider + benchmark 实际 import 的包 |
| 6 | `imgcat` / `pytest` 缺失 | 原属 `[dev]`，显式补上（`pytest` 是 `.py` 的 test runner） |
| 7 | `git.Repo(search_parent_directories=True)` 抛 `InvalidGitRepositoryError` | 同样因 tarball 无 `.git` → 在 aider 目录 `git init` + 一次 commit |

Go/Rust/Node 全部改走国内镜像（aliyun / 清华 rustup+crates / 清华 nodejs-release /
npmmirror）。上游 Dockerfile 本身已有 `aarch64 → GOARCH=arm64` 分支，ARM 支持不是问题。

### Java 的已知障碍（若要上全量 225）

47 道 Java 题走 `./gradlew test`，gradle wrapper 首次运行会从 `services.gradle.org`
下载 Gradle 发行包，从国内大概率卡住。上全量前需预置 Gradle 或配国内镜像。
其余语言的 runner（`cargo` / `go` / `jest` / `cmake`）镜像里都已就绪。

## 文件清单

| 文件 | 内容 |
|---|---|
| `README.md` | 本文件 |
| `results-py34-diff.txt` / `results-py34-whole.txt` | 两次跑分的官方 summary 输出 |
| `per-exercise.json` | 逐题结果（try1 / final / malformed / duration） |
| `Dockerfile.cn-arm` | aarch64 + 国内网络适配的基准镜像 |
| `build_noproxy.sh` | 绕开 docker 客户端代理注入的构建脚本（含还原保证） |
| `run_bench.sh` | 跑分入口：`run_bench.sh <name> <diff\|whole> [langs] [threads] [num-tests]` |

服务器工作区：`/home/admin/aider-bench/`（`aider/` 源码 + `polyglot-benchmark/` 题库 +
`aider/tmp.benchmarks/` 各次运行产物）。镜像 `aider-benchmark:latest`（4.35GB）。

## 复现

```bash
ssh -i ~/.ssh/vgio admin@100.97.87.120
cd /home/admin/aider-bench

# 建镜像（必须用这个脚本，否则构建会被代理拖成 18 KB/s）
bash build_noproxy.sh

# 跑分
./run_bench.sh py34-diff  diff  python 3
./run_bench.sh py34-whole whole python 3
```
