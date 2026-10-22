# hibrid48tp2:kit v4.1 vs v5.2 同权重 A/B(2026-10-22)

同一份 hibrid48 checkpoint、同两台机器、同一晚、同一套测法,只换上游双机 kit 的版本:
**v4.1**(`hibrid48tp2`,当前主力)对 **v5.2**(`hibrid48tp2v52`,候选)。

**一句话结论:v5.2 在中高并发上 +14~27%(c64 600.6 → 753.1),开 thinking 单流 +14~15%,
关 thinking 单流 +4%,冷 prefill 持平(±1%);KV 池小 15% 但仍是 262K 窗口的 7.9 倍。
跑完整套之后 S1 余量 10.0%(v4.1 同一套跑完是 5.4%,但那一臂混进了一个真实的 16 万 token 请求,见 §3)。**
本次测完已切回 v4.1;是否升主力是另一个决定。

---

## 被测配置

| | v4.1(对照) | v5.2(候选) |
|---|---|---|
| 上游 kit | `myllmbox/qwen38-flash-next-cluster-recipe` @ `4e4747b` | @ `v5.2`(`d2721ec`) |
| 镜像 | `…-cluster-vllm:v6`,`sha256:4d03fc80…` | `…-cluster-vllm:v5.2`,image ID `sha256:4210dc4b…`(= registry config digest;manifest `697d4364…` = 上游 README) |
| 引擎 | vLLM 0.30.0 + 补丁,K=5 MTP | vLLM 0.30.0 + RecoverSSM、K≤7 动态草稿深度(full CUDA graph)、one-shot RoCE all-reduce、GB10 skinny-GEMM |
| 权重 | hibrid48 28 分片 | **同一份**(两台 `cp -al` hardlink) |
| KV | `kv-cache-memory 41G`/box → 2,450,356 tokens | 33G/box(上游给 hibrid48 的那行)→ **2,079,675** tokens,7.93× 262K |
| 互联 | 单轨 `rocep1s0f0` | 单轨 —— `ib_links: 2` 自动退回:第二个半口 `roceP2p1s0f0` ACTIVE 但 `enP2p1s0f0np0` 无 IPv4。**上游 v5.2 的数是双轨测的,本表不是** |

本地偏离各三处,见 `stacks/hibrid48tp2/recipe.yaml` 与 `stacks/hibrid48tp2v52/recipe.yaml` 头注释。

## 启动

| | v4.1 | v5.2 |
|---|---|---|
| 每 rank 权重 | 51.03 GiB | 51.03 GiB |
| graph capture | — | 42 s,7.80 GiB |
| `make run` → `/health` 200 | ~4 min | ~5.5 min(22:57 → 23:02,带 cache/ 冷编译) |
| 开机余量 MemAvailable S1 / S2 | 11.74 GiB (9.6%) / 15.40 (12.7%) | **13.71 GiB (11.3%) / 16.90 (13.9%)** |
| `make test` | 全过 | 全过 —— thinking 语义、CoT 字段、RDMA 与 v4.1 完全相同 |
| `/v1/responses` effort | none/low/medium/xhigh 200;minimal/high/max 400 | **同** |

## 1. 并发梯子(关 thinking,`ladder.py`,09-28/09-30 的请求体逐字相同,在 head 上打 localhost)

| c | v4.1 | v5.2 | Δ |
|---|---|---|---|
| 1 | 106.9 | **111.6** | +4% |
| 2 | 154.4 | 158.7 | +3% |
| 4 | 149.6 | 175.6 | +17% |
| 6 | 201.3 | 197.7 | −2% |
| 8 | 235.8 | 242.2 | +3% |
| 12 | 278.7 | 322.4 | +16% |
| 16 | 331.3 | 377.1 | +14% |
| 20 | 361.4 | 427.9 | +18% |
| 24 | 401.5(复测 386.3) | 467.9 | +17~21% |
| 32 | ~~144.0~~ → 复测 **447.1** | 554.0 | +24% |
| 48 | 536.4(复测 554.7) | 680.4 | +23~27% |
| 64 | 600.6 | **753.1** | +25% |

⚠️ v4.1 第一次的 c32 作废:22:28 homelab(`100.94.186.7`)一个约 16 万 token 的真实请求
正在 prefill,decode 被挤到 25~90 tok/s 长达 ~50 s(引擎日志 `Avg prompt throughput: 16341.7`
落在那一窗)。复测(`ladder-v41-recheck.json`,23:15 刚重启后、无外部请求)c32 = 447.1。
v4.1 的 c1 106.9 / c64 600.6 高于 09-30 同测法的 96.5 / 562.2。

## 2. 开 thinking(`ladder.py` 以 `enable_thinking: true` 发同一请求体)

| | v4.1 | v5.2 | Δ |
|---|---|---|---|
| c1(两次) | 76.5 / 79.4 | **87.0 / 91.4** | +14~15% |
| c2 | 132.4 | 141.8 | +7% |
| c4 | 140.3 | 152.0 | +8% |

这比关 thinking 的 c1(+4%)更接近客户端的真实用法(上周 8.3K 请求几乎都是开 thinking 的
agent 长上下文)。reasoning token 数两边不完全一样(temperature 0,但草稿采样/数值路径不同),
tok/s 按实际产出计,不受影响。

## 3. 冷 prefill(`prefill.py`,唯一 uuid 前缀,cached 0)

| | v4.1 首发 / 暖 | v5.2 首发 / 暖 |
|---|---|---|
| ~8K | 3,404 / 3,393 | 3,434 / 3,372 |
| ~32K | 3,454 / 3,451 | 3,419 / 3,427 |
| ~128K(137K) | 3,355 / 3,345 | 3,336 / 3,333 |

**持平。** 上游 v5.2 的 "128k prefill 3,939" 是 INT4-AutoRound + 双轨,不是 hibrid48 单轨 —— 不可比。

**主机内存**(每臂整套跑完后,MemAvailable):

| | 开跑前 | 梯子后 | prefill 后 | 128K 期间 S1 最低 |
|---|---|---|---|---|
| v4.1 | S1 9.8% / S2 12.6% | 6.0% / 8.4% | **5.4% / 8.0%** | 6.59 GiB |
| v5.2 | S1 10.9% / S2 13.5% | 10.5% / 13.0% | **10.0% / 12.6%** | 12.16 GiB |

⚠️ 不是干净的对照:v4.1 那一臂混进了上面那个 16 万 token 的真实请求,API server RSS 在那之后
是 3.9 GB(重启前 2.6 GB)。v4.1 只跑 c24/c32/c48 复测之后是 9.4%,所以它的 5.4% 至少一部分
是那个请求 + c64 + 128K 叠出来的。**v5.2 余量更大是事实(开机就多 1.5~2 GiB),"负载后不涨"
需要几天的 Prometheus 曲线才能下结论。**

## 复现

```bash
# 在 S1 上(head),run-ab.sh 与 ../hibrid48tp2-2026-09-30/{ladder,prefill}.py 同目录
MODEL=qwen3.8-flash-next-tp2     TAG=v41 bash run-ab.sh   # 测试当时的名字
MODEL=qwen3.8-flash-next-tp2-v52 TAG=v52 bash run-ab.sh   # 测试当时的名字
```

⚠️ 上面是**测试当时**的 served 名。同日 23:40 v5.2 升主力时两者对调:现在 v5.2
(`hibrid48tp2v52`)叫 `qwen3.8-flash-next-tp2`,v4.1(`hibrid48tp2`)叫
`qwen3.8-flash-next-tp2-v41`。JSON 里的 `model` 字段记录的是测试当时的名字。

## 未测

- INT4-AutoRound(上游 v5.2 默认,"~10% 快于 hibrid48",~122G 需下载;质量 HumanEval 93.3 vs 95.7、MMLU-Pro 82.9 vs 84.9,±3 噪声内)
- 双轨(需要给两台 `enP2p1s0f0np0` 配 IPv4 —— 主机网络改动)
- 多模态、长时间(天级)内存 steady、真实 agent 长上下文(88K、95% 前缀命中)下的 TTFT
