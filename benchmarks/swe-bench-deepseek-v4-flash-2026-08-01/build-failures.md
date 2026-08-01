# 构建 / 执行失败清单（dsv4flash-smoke-20，2026-08-01）

20 条冒烟样本中 13 条被 harness 记为 `error`。**这 13 条不是同一类问题**，必须分开看:
7 条是模型自己生成的 patch 打不上（属于模型能力，SWE-bench 语义里就该算失败），
6 条是 ARM 基础设施没跑起来（不该算到模型头上）。

## 分类汇总

| 类别 | 数量 | 归属 | 说明 |
|---|---|---|---|
| `Patch Apply Failed` | 7 | **模型** | 生成的 unified diff 格式不合法，`git apply` / `patch` 全部失败 |
| env 镜像构建失败 | 4 | 基础设施(ARM) | conda 在 linux-aarch64 上装不出依赖 |
| instance 镜像构建失败 | 2 | 基础设施(补丁副作用) | `pip install -e .` 的 `build_editable` 钩子缺失 |

## 1. Patch Apply Failed（7 条，模型问题）

```
astropy__astropy-14182
mwaskom__seaborn-3010
mwaskom__seaborn-3407
pallets__flask-4045
pallets__flask-4992
psf__requests-2674
pytest-dev__pytest-5227
```

典型报错 `patch: **** unexpected end of file in patch`。

**根因不是截断，也不是缺尾换行**（已核对：`model_patch` 以 `\n` 结尾，且
`finish_reason=stop`，不是被 max_tokens 截断）。真正原因是**模型手写 diff 时
hunk 头的行数写错了**。以 `pallets__flask-4045` 为例:

```diff
@@ -189,8 +189,9 @@        <- 声称原文 8 行 / 新文 9 行
         )
         self.name = name
+        assert "." not in name, "Blueprint names should not contain dots"
         self.url_prefix = url_prefix
         self.subdomain = subdomain
                                    <- 实际只给了 4 行上下文 + 1 行新增
```

`patch` 按 header 期望读满 8 行，读到文件尾就报 "unexpected end of file"。
这是 LLM 直接手写 unified diff 的典型失效模式（行号/行数算不准、上下文给太少）。

> 注：改用 agentic scaffold（SWE-agent / OpenHands，用工具直接编辑文件而不是手写
> diff）通常能基本消除这一类失败——这也是各家模型卡上 agentic 分数远高于本设置的
> 主要原因之一。

## 2. env 镜像构建失败（4 条，ARM 生态限制）

| 实例 | env 镜像 hash | 原因 |
|---|---|---|
| `pydata__xarray-4248`、`pydata__xarray-5131` | `502d8fc6…` | `PackagesNotFoundError: cdms2` —— conda-forge 没有 `linux-aarch64` 构建 |
| `scikit-learn__scikit-learn-10297`、`scikit-learn__scikit-learn-11040` | `aa928800…` | `scipy` 源码编译失败: `library mach has Fortran sources but no Fortran compiler found` |

- **cdms2**：上游就没出 aarch64 包，短期无解（除非换 conda 频道或跳过该依赖）。
- **scipy / gfortran**：**可修**。SWE-bench base 镜像只装了 `build-essential`
  （gcc/g++），没装 `gfortran`。x86_64 上从来不暴露，因为旧版 scipy 有预编译
  manylinux wheel；aarch64 上没有对应 wheel，pip 只能源码编译，就缺了 Fortran
  编译器。修法是在 base Dockerfile 的 apt 列表里加 `gfortran`
  （`swebench/harness/dockerfiles/python.py` 的 `_DOCKERFILE_BASE_PY`），
  然后重建 base + 所有 env 镜像（约 1–2 小时）。**跑全量前建议先做掉这一项。**

## 3. instance 镜像构建失败（2 条，Patch C 的副作用）

```
pylint-dev__pylint-7114
pylint-dev__pylint-7993
```

```
ERROR: Project file:///testbed uses a build backend that is missing the
'build_editable' hook, so it cannot be installed in editable mode
```

`setup_repo.sh` 里的 `python -m pip install -e .` 失败。原因是 Patch C 让环境改由
spec 现解（`conda create python=3.x` + 新版 pip），装进来的 pip 比当年 x86_64 快照
里锁定的版本新；新 pip 对老项目的 build backend 要求 `build_editable` 钩子，老
backend 没有。

修法（任选其一，跑全量前建议验证）：
- 在该 repo 的 env 里把 pip 降级到支持老式 editable 安装的版本（如 `pip<21.3`）；
- 或把安装命令改成 `pip install -e . --no-use-pep517`。

## 复现

失败详情在服务器上:

```
/home/admin/swebench-eval/logs/build_images/env/<hash>/build_image.log
/home/admin/swebench-eval/logs/build_images/instances/<instance>/build_image.log
/home/admin/swebench-eval/logs/run_evaluation/dsv4flash-smoke-20/deepseek-v4-flash/<instance>/run_instance.log
```
