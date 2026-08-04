# DSpark 升级 runbook(DeepSeek-V4-Flash → DSpark 投机解码)

> 状态:**已上线**(2026-07-03,jasl fork tip `444fe3ac` + DSpark checkpoint)。
> 实测单流 warm **~51-53 tok/s**(此前 MTP ~42);**并发上限是 `max_num_seqs=6`**(2026-07-04
> 验证稳定,聚合 ~50 tok/s,接受率随并发下降到 16-33%);**`max_num_seqs=16` 会导致启动失败**
> (KV 显存不够,详见下方"并发上限实测"一节),已回滚。
>
> **📌 2026-07-31 更新(当前生产状态)**:checkpoint 换成**官方正式版
> `DeepSeek-V4-Flash-0731`**(166.9GB,ModelScope,DSpark 模块内置,结构/config.json 与
> preview 组合逐字节一致 → 纯换权重,引擎/recipe 只改 model 路径);同日扫描把
> `num_speculative_tokens` 从 3 调到 **5**(n=3 ≈ 53.9、n=5 ≈ 56.6、n=7 ≈ 52.4 tok/s——
> `dspark_block_size=5`,draft 位置 4 之后接受率骤降到 4.7%/0.3%,官方建议的 n=7 白费两次
> draft;6 路并发在 n=5 复验干净),另按官方模型卡对齐 `top_p=0.95`。单流 warm **~56 tok/s**。
> 下文步骤/数值是 07-03 升级当时的记录,按史料读。
> 本文记录**为什么这么做、怎么做最快、以及所有踩过的坑**,供任何机器/会话复现。
> 基础栈背景见 `docs/deepseek-v4-flash-cn.md`。
>
> **⚠️ 2026-07-04 重大更正**:此前认为"官方 vLLM 在 GB10(sm121)上稀疏 MLA 完全跑不起来"
> 是错的——直接实测官方 vLLM(eugr 预编译 wheel,`ec0ffaacc`)在双机 TP=2 上**成功跑通**
> DeepSeek-V4-Flash(非 DSpark,普通 dense decode ~24 tok/s,和 jasl fork 不开 MTP 的基线
> 几乎一致)。关键是要带上 `DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=...` 这两个环境变量,
> 否则 DeepGEMM JIT 会报一个看起来像"架构不支持"、实际只是 NVRTC 头文件找不到的报错。
> **也就是说 jasl fork 现在唯一不可替代的价值就是 DSpark 本身**,不是 GB10 基础支持。
> 详见下方"官方 vLLM 能否替代 jasl fork"一节。

## DSpark 是什么(先纠正两个常见误解)

- **DSpark 不是独立引擎,不"替换"vLLM** —— 它是 DeepSeek(+北大)2026-06-28 开源的
  **投机解码框架**(γ 步 draft + Markov head),作为 vLLM 内部的一种
  `--speculative-config` method 运行,是现有 MTP(`deepseek_mtp`)的升级版。
- **需要单独的 checkpoint**:`deepseek-ai/DeepSeek-V4-Flash-DSpark`
  (**166.9 GB / 48 shards**,ModelScope 有,国内直连可下)。base 权重同 V4-Flash,
  多了 draft/Markov 头(`config.json` 里 `dspark_target_layer_ids: [40,41,42]`)。
  (**2026-07-31 起已不需要单独 checkpoint**——官方正式版 `DeepSeek-V4-Flash-0731`
  直接内置 DSpark 模块,当前生产用的就是它。)
- 收益(2×DGX Spark 实测报告):单流编码 ~42 → **~52-67 tok/s**,并发聚合 ~200-300 tok/s。
  **代价:满 1M 上下文可能掉到 <10 tok/s**(收益集中在中短上下文、高接受率场景)。

## 版本格局(2026-07-03 查证,决定了升级路线)

| 事实 | 证据 |
|---|---|
| vLLM 官方 main **没有** DSpark | wheel commit `ec0ffaacc`(07-02)的 `spec_decode/` 只有 `dflash.py`(父类),无 `dspark.py`;2026-07-04 直接实测复核仍然成立 |
| ~~官方 main 在 GB10(sm_121)上 sparse MLA 仍不可用~~ **⚠️ 已被 2026-07-04 实测推翻** | issue #45317/#46055 至今 open,但**直接跑通了**官方 wheel 在双机 TP=2 上的 V4-Flash 服务(带对的 DeepGEMM JIT 环境变量)。issue open 不等于当前 commit 真的跑不了,细节见下方"官方 vLLM 能否替代 jasl fork"一节 |
| **jasl fork tip 独有**:DSpark | `jasl/vllm@codex/ds4-sm120-min-enable` 含 `vllm/v1/spec_decode/dspark.py` + `dspark_sampling.py`——**sm121 基础支持官方主线其实也有,只是 DSpark 没有** |
| eugr 上游 harness 的 prebuilt wheel = 官方 main | `prebuilt-vllm-current` release,每隔几天重建,**暂无 DSpark**,但**基础 V4-Flash 服务能力已确认可用** |
| jasl 入主线的 PR | **#41834**(open)——这是唯一要盯的信号 |

结论(2026-07-04 更新):**继续用 jasl fork 的唯一理由是 DSpark**,不再是"sm121 支持"——
那部分官方主线本来就有。如果不需要 DSpark,eugr 默认路线(官方 main + prebuilt wheel)现在
是**可行**选项,不再是死路。

## 怎么做最快(按时机三档)

| 时机 | 做法 | 耗时 |
|---|---|---|
| 已完成本次升级后 | 镜像已含 DSpark,无需动作 | 0 |
| 升级到更新的 jasl tip | `./run-recipe.sh deepseek-v4-flash --build-only --force-build`(docker 层已缓存,只重编 vLLM 层)+ `vllm-fix-torch.sh` | **~1h** |
| **#41834 合入 main 后** | eugr prebuilt wheel 将自带 DSpark:recipe 删掉 `build_args` 的 jasl 源,harness 下 wheel 组装镜像,零编译。代理慢可在 Mac 下好 wheel 丢进 S1 `spark-vllm-docker/wheels/`(带 `.vllm-commit` 标记) | **~15min** |

## 升级步骤(2026-07-03 实操验证)

前提:S1 代理可用(见下方坑 #2/#3)、两台各 >200GB 空闲盘。

```bash
# 0) 回滚保险(两台都做)+ 备份 recipe
docker tag vllm-node-dsv4:latest vllm-node-dsv4:pre-dspark-<commit>
cp recipes/deepseek-v4-flash.yaml recipes/deepseek-v4-flash.yaml.bak-pre-dspark

# 1) 下 DSpark checkpoint(在线,167GB,~20-40min,tmux 内跑;栈可以不停)
#    flat 目录,绝不产生绝对软链(HF-cache 坑)
/home/admin/modelscope-venv/bin/python3 -c "
from modelscope import snapshot_download
snapshot_download('deepseek-ai/DeepSeek-V4-Flash-DSpark',
    local_dir='/home/admin/.cache/huggingface/hub/DeepSeek-V4-Flash-DSpark')"

# 2) 拷权重到 S2(200G 内网,~400MB/s,~7min;可与 3) 并行)
rsync -a --info=progress2 ~/.cache/huggingface/hub/DeepSeek-V4-Flash-DSpark/ \
    192.168.200.102:/home/admin/.cache/huggingface/hub/DeepSeek-V4-Flash-DSpark/

# 3) 停栈(编译要 RAM;S1 平时只剩 ~1GB 空闲)→ 停机窗口开始
sudo systemctl stop deepseek-v4-flash

# 4) 重编到 fork tip(tmux!)。注意 --force-build,见坑 #1
cd /home/admin/spark-vllm-docker
./run-recipe.sh deepseek-v4-flash --build-only --force-build
#    冷缓存 ~4h(apt/NCCL 全走代理);热缓存 ~40-60min(只编 vLLM 层)
#    自动 docker save | load 拷 S2

# 5) torch-CPU 修复(构建后 runner 里 torch 被覆盖成 CPU 版,必做)
bash scripts/vllm-fix-torch.sh   # 重装 cu130 torch → commit → 拷 S2

# 6) 改 recipe(S1 recipes/deepseek-v4-flash.yaml + 本仓库 config/ 镜像)
#    model: /root/.cache/huggingface/hub/DeepSeek-V4-Flash-DSpark
#    --speculative-config '{"method":"dspark","num_speculative_tokens":3}'
#    其余不动:VLLM_TRITON_MLA_SPARSE=1、--kv-cache-dtype fp8、served_model_name 不变

# 7) 起服务 + 验证 → 停机窗口结束
make v4flash-run && make v4flash-status && make v4flash-test
```

### jasl fork 的 DSpark 配置要点(读 `dspark.py` 源码确认,勿照抄他人 recipe)

- method 名就是 `"dspark"`(源码 assert);`num_speculative_tokens: 3`
  (checkpoint 有 3 个 draft 层 `[40,41,42]`)。
  **2026-07-31 更新:生产值已调到 5**——draft 层数不是 n 的上限,起决定作用的是
  `dspark_block_size=5`(见文首更新);当前 recipe 还加了 `draft_sample_method: greedy`
  (官方卡建议,本 build 里本来就是默认值,写显式不影响 tok/s)。
- `dspark_fused_markov_sampler` 默认 **True**,不用设。
- **不需要** `VLLM_USE_V2_MODEL_RUNNER`、不需要改 KV dtype、attention backend 无额外要求
  —— 网上 tonyd2wild/rafaelcaricio recipe 的一大堆 `VLLM_DSPARK_*` env 和
  `nvfp4_ds_mla` KV 是**另一条 base(官方 v0.24 + 第三方补丁)的东西,对 jasl fork 无效**。
- 可选:`VLLM_DSPARK_FORWARD_CUDAGRAPH`(默认关,实验性)。

### 验证清单(2026-07-03 实测结果)

- `/v1/models` 正常、模型名仍 `deepseek-v4-flash`(客户端零改动)—— ✅。
- `make v4flash-test`:单流编码 tok/s —— **第一次请求 ~41 tok/s(看起来没提速),
  第二次 ~51-53 tok/s**。第一次慢是因为 DSpark 的 Markov-sampler Triton kernel
  (`_dspark_markov_probs_*`、`_dspark_context_kv_store_kernel`)在**首个请求中**
  才触发 JIT 编译("causes a latency spike"),之后就有真实的稳态提速。
  **每次(re)start 后第一次测速都别信,重测一次。**
  journal 里 `SpecDecoding metrics` 会报 `Avg Draft acceptance rate`(实测按内容
  波动 40-85%)和 `Mean acceptance length`(实测 2.2-3.6,满分 3)。
- 并发 2-4 路:检查**乱码/garble**(DSpark 在 GB10 的已知病,社区 07-03 还在修)
  和 journal 里的 `illegal memory access` —— ✅ 4 路并发无乱码无报错,聚合 ~52 tok/s
  (受 recipe `max_num_seqs: 2` 限制,4 路会分两批跑,想要更高聚合吞吐可以调大
  `max_num_seqs` + 对应调大 `max_num_batched_tokens`,但会增加显存压力,谨慎测试)。
- `free -h` 两台:swap=0、RAM 有余量 —— ✅(两台均 swap=0,~17-18Gi available)。
- 长上下文抽查:DSpark 满 1M ctx 可能 <10 tok/s(未实测,社区报告),重长文场景考虑回退 MTP。

### 并发上限实测(2026-07-04,`max_num_seqs` 分级测试)

当前 KV 池在 1M ctx 下官方标注 `Maximum concurrency: 2.04x`,但那是"每个请求都顶到 1M"的极端
情况;真实短 prompt 场景下 KV 显存远够用,`max_num_seqs` 才是真正的并发上限开关。分级验证结果:

| `max_num_seqs` | `max_num_batched_tokens` | 结果 |
|---|---|---|
| 2(原始) | 4192 | ✅ 稳定(3周+) |
| **6** | **8192** | **✅ 稳定,当前生产值**——4/6 路并发无乱码无 crash,聚合 ~50 tok/s,`journal` 确认 `Running: 6 reqs, Waiting: 0 reqs`(真并发,非排队) |
| 16 | 16384 | ❌ **启动失败**——`ValueError: ... 10.84 GiB KV cache is needed ... available KV cache memory (6.44 GiB)`。原因:`max_num_batched_tokens` 翻倍后 CUDA graph/prefill 显存开销跟着涨,挤压 KV 池到连"1 个请求跑满 1M ctx"都保证不了。**已回滚到 6**。 |

**并发下接受率会掉**:单流 DSpark 接受率 63-85%,6 路并发时掉到 **16-33%**(`Mean acceptance
length` 从 2.9-3.6 掉到 1.5-2.0)。这不是配置错误,是 DSpark 在没打"并发正确性补丁"的 fork 上
的已知特性(参考 [MiaAI-Lab 项目](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)
专门带了 `drowzeys/Keys-Concurrency-Patch`,大概率就是修这个的——但那是另一个 fork/checkpoint,
细节见文末"MiaAI-Lab 方案"待办)。

**想再冲更高并发**,两条路径都要取舍,不要在生产 endpoint 上直接试 16:
1. 降 `max_model_len`(比如 100K-200K)换出 KV 显存空间给更大的 `max_num_seqs`——放弃 1M 长上下文。
2. 调高 `gpu_memory_utilization`(当前 0.80)——但这正是 2026-06-29 那次整机 OOM 事故调低后的
   安全线,回调有重演风险,只在充分测试后再动。

**⚠️ 任何 `max_num_seqs`/`max_num_batched_tokens` 实验都要先套 2 分钟回滚**(见下方),失败是
`ValueError` 干净拒绝启动、不会伤宿主机,但 `Restart=on-failure` 会用同一个坏配置反复重试,
必须手动改回好配置再重启才能打断循环。

### 官方 vLLM 能否替代 jasl fork(2026-07-04 实测,推翻此前判断)

此前一直认为"官方 vLLM 在 GB10(sm121)上稀疏 MLA attention backend 选型直接失败"(基于
GitHub issue #45317/#46055 描述,两者至今仍是 open)。**直接拿 eugr 默认预编译 wheel
(`ec0ffaacc`,2026-07-02,纯官方 vllm-project 主线)在真实两台 GB10 上跑了一次双机 TP=2,
结果是——完全跑通**,含真实生成验证(`finish_reason: stop`,代码输出正确,~24 tok/s 纯 dense
decode,和 jasl fork 不开投机解码的基线 ~25 tok/s 几乎一致)。日志证据:

```
Using DeepSeek's fp8_ds_mla KV cache format
Using FP8 indexer cache for Lightning Indexer
FlashInfer SM120 sparse MLA DSv4 decode autotune cache loaded
```

**关键坑(踩了两次才找到)**:官方 vLLM 的 DeepGEMM JIT 编译**必须**带上
`DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc`(生产 recipe 里
一直都有这两个变量,但容易被当成"jasl 专属配置"误删)。没有这两个变量时,NVRTC 会报
`catastrophic error: cannot open source file "cuda/std/cstdint"` → `CUDA_ERROR_INVALID_IMAGE`,
**看起来像是架构不支持,实际只是 JIT 工具链配置缺失**,和 sm121/GB10 本身无关。

**结论**:jasl fork 现在**唯一不可替代的价值是 DSpark**。如果哪天不需要 DSpark 了(比如
DSpark 稳定性问题变严重、或想要更简单的维护),完全可以切回 eugr 默认(官方 vLLM + 预编译
wheel + `deepseek_mtp` 投机解码),不用再管 jasl fork 的源码编译、代理、torch-CPU 陷阱这些
事。这也是"版本格局"一节判断的重要更新——之前认为需要 jasl fork 是因为"两个理由"(sm121
支持 + DSpark),现在只剩一个(DSpark)。

### 回滚(~2min)

```bash
cp recipes/deepseek-v4-flash.yaml.bak-pre-dspark recipes/deepseek-v4-flash.yaml
docker tag vllm-node-dsv4:pre-dspark-a03c87c93 vllm-node-dsv4:latest   # 两台(2026-07-03 那次的 tag)
make v4flash-run
```

## 踩坑记录(2026-07-03,都验证过)

1. **`--build-only` 单用是 no-op**:镜像已存在时 run-recipe 直接跳过构建
   ("Container already exists"),`build_args` 里的 `--rebuild-vllm` 根本不会被看到。
   **必须加 `--force-build`**。
2. **S1 的 DNS 可能整体坏死**:系统 DNS 全权交给 Tailscale MagicDNS(100.100.100.100),
   其公网上游挂了就全挂("No appropriate name servers")。SSH 走 IP 不受影响,容易被忽略。
   运行时修复(可逆,重启失效):
   ```bash
   sudo resolvectl dns enP7s7 223.5.5.5 119.29.29.29
   sudo resolvectl domain enP7s7 '~.'
   ```
3. **SS 代理节点会死**:`v2rayn-launch.sh` 原来硬编码优先 `104.224.156.253`(已死过一次),
   换 `156.238.229.145` 恢复。现在脚本支持 `XRAY_NODE=<ip>` 指定;起完必须
   `curl -x http://172.17.0.1:10809 https://github.com` 验证 200,再开编译。
4. **docker build 的代理来自 `~/.docker/config.json` 的 `proxies.default`**
   (Dockerfile/DAEMON 都没配代理)。动手前可用一个 alpine 小构建验证
   "构建内 curl github = 200",省得编译半小时后死在 git clone。
5. **构建时长两极**:docker 层缓存失效 = 全量重来(apt/NCCL 全走慢代理,~4h);
   缓存命中 = 只编 vLLM 层(~40-60min)。别轻易 `docker system prune`。
6. 老坑依旧:**torch-CPU 陷阱**(步骤 5 必做)、**权重用容器内本地 PATH 不用 repo-id**、
   **软链必须相对路径**、**大文件下载/编译全部进 tmux**。
7. **⚠️ 任何 `build-and-copy.sh`/`docker build` 之前必须先停生产栈**(2026-07-04 事故):
   下 eugr 官方预编译 wheel 看似"轻量、不用编译",实际 runner 镜像组装阶段仍会**从源码
   编译 DeepGEMM/QuTLASS 等原生依赖**(能看到 `Cloning into 'deepgemm-src'`、
   `Building CUDA object ...`),吃的 CPU/内存和源码编译 vLLM 本身没差多少。在生产栈
   (~103GiB 占用)还跑着的时候起了这么一个"以为很轻"的构建,直接触发了 host OOM,
   内核杀掉了生产的 `VLLM::Worker_TP` 进程,服务中断到手动 `systemctl restart` 恢复。
   **不管构建看起来多"轻",动手前一律 `sudo systemctl stop deepseek-v4-flash`。**
8. 想强制重新下载官方/别的上游 wheel(而不是复用本地已编译好的 jasl wheel)时,
   `try_download_wheels` 会因为本地文件更新而跳过下载——得先把 `wheels/*.whl` 和
   隐藏的 `.vllm-commit`/`.flashinfer-commit` 都挪开。**`mv backup/* .` 不会带上以 `.`
   开头的隐藏文件**,得单独 `mv backup/.vllm-commit .`,否则会留下残缺/过期的 commit 标记。
9. **OOM 炸的不只是 vLLM 进程,tmux server 也会被一起干掉**:2026-07-04 那次事故后,
   连带杀死了跑 v2rayN 代理(`xrayfix` session)的整个 tmux server。后续重新构建时在
   `uv pip install` 阶段因为代理已死而报 `pypi.org ... tunnel error`,排查了一阵才发现。
   **OOM 之后不要只查你在盯的那个进程,顺手 `curl -x http://172.17.0.1:10809
   https://github.com` 确认代理还活着。**
10. **官方 vLLM 撞到"看起来像架构不支持"的报错时,先怀疑 DeepGEMM JIT 环境变量缺失**,
    不要立刻断定是 sm121/GB10 硬件不兼容——`DG_JIT_USE_NVRTC=0` +
    `DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc` 这两个变量在生产 recipe 里一直都有,
    简化测试配置时容易被当成"jasl 专属"误删,漏掉就会看到
    `CUDA_ERROR_INVALID_IMAGE`,和真正的架构缺陷长得几乎一样。

## 待办:MiaAI-Lab 方案(暂不做,下次有完整时间窗口再评估)

[MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)
声称在 2×DGX Spark 上用**另一条技术栈**(rafaelcaricio/vllm fork 的
`codex/dspark-harness-integration` 分支 + `drowzeys/Keys-Concurrency-Patch` 并发补丁 +
`nvfp4_ds_mla` KV 量化 + 第三方 `fraserprice/DeepSeek-V4-Flash-DSpark` "C12" checkpoint)
实现了并发下 230-315 tok/s(相比我们当前 6 路 ~50 tok/s)。真实项目(76 star,活跃 commit),
但和我们现在这套完全不共用组件,是一次新的构建+验证投入,不是配置调整。

2026-07-04 的"官方 vLLM 能在 GB10 跑通"发现,只验证了 `fp8_ds_mla`(标准路径),**没有**验证
`nvfp4_ds_mla`、rafaelcaricio 的 DSpark 实现、或 Keys 补丁——这几项风险敞口都还是未知数,
不能因为前者能跑就假设这套也行。真要评估,需要单独排一个不那么赶的时间窗口,按以下顺序来:
1. 确认 rafaelcaricio/vllm 是否发布预编译 wheel(如果只能源码编译,工作量参考本文档的
   jasl fork 构建流程);
2. 单独验证 `nvfp4_ds_mla` 能否在 GB10 初始化(参考本文档"官方 vLLM 能否替代 jasl fork"
   一节的验证方法:先单机排除内存因素,再双机真跑);
3. 确认 `gpu_memory_utilization=0.85`(该项目文档值)在我们的 host 上是否安全——**不要直接
   套用**,这个值曾在我们自己的机器上触发过 OOM(2026-06-29 事故)。

## 参考

- jasl PR(入主线追踪):https://github.com/vllm-project/vllm/pull/41834
- SM120 支持合并(2026-06-22):https://github.com/vllm-project/vllm/pull/43477
- sm121 sparse MLA gap issue(open,但 2026-07-04 实测已不完全适用):#45317 / #46055;
  DeepGEMM 覆盖缺口:#41063
- eugr prebuilt wheels:https://github.com/eugr/spark-vllm-docker/releases
- 2×Spark DSpark 实测(NVIDIA 论坛):forums.developer.nvidia.com/t/374846
- MiaAI-Lab DSpark 方案(待评估,见上):https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
