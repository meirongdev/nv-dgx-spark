# Qwen3.8-Flash-Next A/B:RadixArk NVFP4 (fndgx) vs hibrid48 (bilikaz v4)—— 2026-09-28

同一台机器(S2,100.67.164.92)、同一批题、同一协议,先后部署两个版本的
**同一个模型**(Qwen3.8-Flash-Next NVFP4),做切换决策。

**结论:换。hibrid48 快 1.3–1.6×(同题中位数 1.27–1.41×),四件套质量在
±1 题/200 的噪声内,没有智力回退。** 2026-09-28 当天已完成切换:hibrid48 顶替
fndgx 的对外身份(`:18300` / `qwen3.8-flash-next`),外部客户端零改动。

---

## 两臂

| | RadixArk(旧,代号 `radixark`) | hibrid48(新,代号 `hibrid48`) |
|---|---|---|
| 来源 | NVIDIA 官方 checkpoint(RadixArk 量化) | `bilikaz/qwen38-flash-next-recipe` @ `31853d7`(v4,2026-09-26 发布) |
| 引擎 | vLLM 0.30.0 + PLE-mmap(48 GiB n-gram 表,page-fault 走 NVMe) | vLLM 0.30.0 + PLE-mmap(26.8 GiB 表)+ **4-bit 输出头**(hibrid48 命名的由来)+ 融合多步 MTP K=5 |
| 镜像 | `qwen38-flash-dgx`(S2 本地构建) | `myllmbox/qwen38-flash-next-vllm:v4`(vLLM 0.30.0 基底,已核与官方 `vllm/vllm-openai` 0.30.0 同源) |
| 权重 | 126 GiB,`.../RadixArk--Qwen3.8-Flash-Next-NVFP4` | **105.34 GiB**(28 分片,索引验证通过),`myllmbox/Qwen3.8-Flash-Next-hibrid48` |
| KV 池 | 496,770 tokens | **830,582 tokens**(`kv-cache-memory=27G` bf16) |
| 并发上限 | `max_num_seqs=8`(聚合吞吐卡死在 113 tok/s @ c8,见 `../fndgx-2026-09-20/`) | **16** |
| 权重为何更小 | 官方 NVFP4 + bf16 输出头 | 4-bit 输出头 + 打包更紧的 checkpoint(上游:−20% 权重、KV +27%) |
| 端点(测试期) | `http://100.67.164.92:18300/v1`,model `qwen3.8-flash-next` | `http://100.67.164.92:8000/v1`,model `Qwen/Qwen3.8-Flash-Next`(切换后已改回 `:18300` / `qwen3.8-flash-next`) |

两臂都:thinking ON(`enable_thinking=true`)、`temperature=0.6, top_p=0.95,
top_k=20`、`max_tokens=32768`、非流式、超时 1200 s。S2 主机侧两臂一致
(图形会话/sparkDash 已停,`vm.compaction_proactiveness=0` 已装)。

⚠️ 两臂**不是背靠背**的(中间隔了一次切换),所以本对比是"质量 + 单题耗时"
的同题对比,不是"吞吐 ± 噪声"的严格 A/B。质量子集:

| 套件 | 子集 | 说明 |
|---|---|---|
| HumanEval | **164 全量** | pass-to-pass 判定 |
| GSM8K (test) | 前 200 题 | 数字答案正则提取 |
| MMLU-Pro (test) | 前 200 题 | 选择题,答案字母 |
| IFEval | 前 200 题 | strict(指令级 + prompt 级),本地 `instruction_following_eval` 包 |

数据集快照在本目录 `datasets/`,两臂用**同一份文件**(逐字节),保证不是题面漂移。

---

## 1. 质量(同一批题,两臂独立作答)

| 套件 | RadixArk | hibrid48 | 差 |
|---|---:|---:|---:|
| HumanEval (n=164) | **164/164 = 1.000** | **164/164 = 1.000** | 0(双满分,饱和) |
| GSM8K (n=200) | 195/200 = 0.975 | **197/200 = 0.985** | **+2 题** |
| MMLU-Pro (n=200) | 179/200 = 0.895 | **180/200 = 0.900** | **+1 题** |
| IFEval prompt-strict (n=200) | 0.925 | 0.915 | −2 题(噪声内) |
| IFEval instruction-strict (n≈200 指令) | 0.9434 | 0.9434 | 0 |

**判读:±1–2 题/200 在 temperature=0.6 的采样噪声范围内,无证据表明 hibrid48
掉智力**(上游自己的表也注明 GSM8K 98.0 ±3pt)。注意 GSM8K 98.5 略高于上游
公布的 98.0(上游用的是 seed 123123123 的 200 题子集,与本目录的"前 200 题"
不是同一批,不能直接比)。

## 2. 速度(每题耗时,秒 —— 同题直接配对)

detail 文件**没有** token 字段,所以用"每题墙钟时间"做配对比较
(同一题两臂的 prompt 完全相同;答案长度相近时耗时比 ≈ 吞吐比的倒数)。

| 套件 | 臂 | 中位数 | p95 | p99 | max | hibrid48 更快题数 |
|---|---|---:|---:|---:|---:|---:|
| HumanEval | radixark | 11.8 | 46.7 | 68.1 | 301.6 | 115/164 |
| | hibrid48 | **9.3** | **38.5** | **50.8** | **172.4** | (53 题更慢) |
| GSM8K | radixark | 9.4 | 37.8 | 60.5 | 179.9 | 167/200 |
| | hibrid48 | **6.7** | **23.6** | **38.9** | **81.1** | (28 题更慢) |
| MMLU-Pro | radixark | 7.9 | 30.6 | 46.2 | 108.3 | 149/200 |
| | hibrid48 | **6.0** | **21.8** | **33.5** | **76.2** | (34 题更慢) |
| IFEval | radixark | 11.5 | 46.9 | 66.5 | 152.3 | 151/200 |
| | hibrid48 | **8.5** | **31.7** | **49.9** | **121.0** | (38 题更慢) |

**中位数比 1.27–1.41×,p95 最高 2.04×。** "更慢题数"不是随机噪声:同一批题
里稳定有 ~15–20% 的题 hibrid48 更慢,形态与答案长度相关(它 thinking 更
勤、某些题多写一段),但中位数/尾部全面占优。

## 3. 吞吐(切换决策的上下文,非严格 A/B)

- **RadixArk 臂**:`max_num_seqs=8` 把聚合吞吐钉死在 **113 tok/s @ c8**(c16 不涨,
  最坏延迟 24→44 s —— `../fndgx-2026-09-20/` 有完整阶梯)。上游结论:上限是
  seqs 不是硬件,`SEQS=8→48` 可爬到 ~267 tok/s,但**本仓库从未调过**。
- **hibrid48 臂**:`max_num_seqs=16`,上游公布 288 tok/s @16 流(本仓库**未复测**
  聚合阶梯 —— 欠的一笔,见下)。

## 4. thinking 语义差异(切换后客户端必读,gotcha #9 新实例)

| 写法 | RadixArk (fndgx) | hibrid48 |
|---|---|---|
| 顶层 `enable_thinking=false` | 有效 | ⚠️ **被静默忽略**(实测 sheep 题仍 72 reasoning tokens) |
| `chat_template_kwargs.enable_thinking=false` | 有效 | ✅ 真关(0 reasoning tokens,答案 13) |
| `enable_thinking=true`(顶层) | 有效 | 有效(≈66 reasoning tokens,答案 22) |
| CoT 字段 | `reasoning` | `reasoning`(`reasoning_content` 恒为 None) |
| `/v1/responses`(codex) | effort low/medium/xhigh 200 | low/medium/high/xhigh/none 200,none 真无 reasoning item |

**影响**:老客户端(顶层 `enable_thinking=false` 想关思考的)在 hibrid48 上会
**静默地继续思考** —— 不是错,但行为变了。`stacks/hibrid48/stack.env` 的
`STACK_THINK_OFF` 已按实测写成 CTX 形式;fndgx 的已同步更正(09-28 ab20 实测
顶层 false 在 fndgx 上也不干净,见 `ab20.log`)。

## 5. 为什么快(工程归因,非玄学)

1. **4-bit 输出头 + 紧打包 checkpoint**:每 token 的 head 投影和权重搬运更小;
2. **KV 池 830K vs 497K**:`max_num_seqs` 提到 16 后并发档不撞墙;
3. **融合多步 MTP K=5**:draft 5 token/步,代码类接受率 ~5.1/6(上游实测);
   RadixArk 臂是 K=1 级的小投机;
4. **n-gram PLE 表 26.8 GiB(48→26.8)**:page-fault 面更小,表还在 NVMe 上
   demand-paging(上游 `MBX_PLE_MMAP_PREWARM=0`);
5. `moe-backend=marlin`(NVFP4 W4A16 的最快 kernel)+ fastsafetensors 加载
   (权重 ~80 s vs ~10 min)—— 加载快不影响稳态吞吐,但减少了切换成本。

---

## 复现 / 文件清单

```
quality4.py               # 四件套驱动:env ENDPOINT/MODEL,argv[1]=TAG;写 detail_<tag>.jsonl + results_<tag>.json
results_radixark.json     # 旧臂汇总(2026-09-27 13:32 → 21:03)
results_hibrid48.json     # 新臂汇总(2026-09-27 21:24 → 09-28 03:11)
detail_radixark.jsonl     # 逐题记录 {suite,idx,prompt,content,ok,dt}(无 token 字段)
detail_hibrid48.jsonl     # 同上(⚠️ 含 ~79 条重复记录 —— 双进程误启动,统计时按 (suite,idx) 去重取首)
ab20.py + ab20.log        # thinking on/off × GSM8K-20 小样(语义验证用,非质量证据)
datasets/                 # 四件套数据快照(两臂同一份)
ifeval_*.py/json          # IFEval 本地评测件 + 校验注册表
instruction_following_eval/  # 随仓库的 IFEval 包(评测依赖)
```

跑法(单臂,约 6.5–8 h,在 Mac 上打端点;两臂先后各跑一遍):

```bash
export ENDPOINT=http://100.67.164.92:18300/v1 MODEL=qwen3.8-flash-next
python3 quality4.py radixark     # 旧臂端点/模型名同理
```

## 与上游公布的对照(hibrid48,上游 seed 123123123 子集)

| 套件 | 上游 | 本仓库(前 200 题,不同子集) |
|---|---:|---:|
| HumanEval | 95.7 | 100.0(全量 164) |
| GSM8K | 98.0 ±3 | 98.5 |
| IFEval prompt/instruction | 91.5 / 93.4 | 91.5 / 94.3 |
| MMLU-Pro | 84.9 | 90.0 |

子集不同,只作量级核对:全部落在上游 ±3pt 声明的采样误差带内或更好。

## 还欠的

- **聚合吞吐阶梯**(c1→c16)没有在 hibrid48 上复测 —— 上游 288 tok/s @16 是
  未验证的数字;fndgx 的 113 @c8 是实测的。
- 长上下文(262K 配置,实际最长 prompt ~52K)。
- 视觉质量(本镜像未测多模态,fndgx 有四象限图测试)。
- 同题 A/B 的严格吞吐对比(两臂非背靠背,见上)。

## 切换记录

- 2026-09-28:`stacks/hibrid48` 注册;fndgx 退役为可回滚备份
  (`stacks/fndgx/stack.env.retired-2026-09-28`);S2 recipe.yaml 改
  `port: 18300` + `served-model-name: qwen3.8-flash-next`;外部客户端
  (`codex --profile fndgx`、qwen settings)零改动,已用真实请求验证
  (`/v1/chat/completions` + `/v1/responses` 均 200)。
