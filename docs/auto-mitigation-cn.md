# 防宕机自动化：软件减载与告警（实现规格）

> **状态：2026-08-15 实现完成。**
>
> 两份改动：
> 1. **宿主机内存看门狗**（本仓库落地：`scripts/mem-watch.sh` + `make memwatch*`，见 §2）——
>    原方案是 k8s cgroup 内存上限，但**上线前实测推翻**：GB10 统一内存分配绕过容器
>    cgroup（§2.3），k8s 内存上限兜不住真正 OOM 的 100 GB，已改为读取节点级内存的看门狗。
> 2. **Prometheus 告警规则**（交给 homelab 监控栈实现，见 §3，**尚未落地**）。
>
> 先立项：**软件减载管的是「过载/OOM/卡死这类软件故障」和「事后自愈/取证」，
> 管不了电源事故本身**。2026-08-15 S2 那次是断电级事件（见
> `docs/qwen38-27b-fallback-cn.md` §1），本文所有手段都不防它；但仍值得做，
> 因为它们防住的是**真实存在、且这次差一点埋掉整栈**的软件宕机模式：
> 统一内存 OOM 冻死整机（连 sshd/tmux 一起带走）、zombie TP 组、排队饱和。
>
> 看门狗只改了仓库里的脚本 + Makefile 目标，**没有动线上 yaml、没有触碰运行中的
> 推理栈**。要真正启用守护，`make memwatch`（常驻，建议放 tmux）即可 —— §2.6。

---

## 0. 一句话定位

| 手段 | 防什么 | 归属仓库 | 状态 |
|---|---|---|---|
| 宿主机内存看门狗（`mem-watch.sh`） | 整机 OOM 冻死（真实故障） | **本仓库** `scripts/` + `make memwatch` | ✅ **已实现**（§2） |
| ~~k8s cgroup 内存上限~~ | ~~整机 OOM~~ | ~~`k8s/v4flash/`~~ | ❌ 已废弃（实测兜不住，§2.3） |
| Prometheus 告警规则 | 提前发现过载/掉线，形成前兆 | **homelab** 监控栈 | 仅规格（§3，未落地） |

---

## 1. 背景：GB10 统一内存为什么需要这两样

GB10 的 128 GB LPDDR5X 是 **CPU 与 GPU 共享的相干统一内存**。V4-Flash 用
`gpu_memory_utilization=0.80`（≈102 GB/节点），`nvidia-smi` 对每进程内存报 `[N/A]`，
只能 `free -h` 看总量。这意味着：

- 一旦推理栈把内存顶满，**OOM 优先咬的是宿主机进程**（sshd、k3s、node-exporter、
  tmux server）——正是 CLAUDE.md 里反复出现的「连 tmux 一起带走」的整机冻结。
- 现有两个 Pod 的 `resources.limits` **只有 `nvidia.com/gpu`，没有内存**（统一内存上
  只做调度记账，无隔离）。所以推理栈没有「内存护栏」。
- 对策有两层：
  1. **宿主机内存看门狗**：读节点级 available 内存，逼近红线前自动把两 rank scale 0，
     保住宿主机（§2）。k8s cgroup 上限已被实测否决——统一内存分配绕过容器 cgroup，见 §2.3。
  2. **告警**：让「快到红线」这件事在**有人/没人都能看见**，而不是事后翻曲线（§3）。

---

## 2. 改动一：宿主机内存看门狗（已实现）

### 2.1 目标

在整机 OOM **发生之前**把 V4-Flash 两个 rank **一起 scale 到 0**，保住宿主机
（sshd/k3s/监控），把「整机冻结」变成「引擎先退下、稍后手动再起」。它读 **节点级**
内存——因为真正会搞崩整机的 ~100 GB 统一内存分配，只有节点级 `free`/`/proc/meminfo`
看得见（见 §2.3 实测）。

### 2.2 实现位置

- `scripts/mem-watch.sh` —— 轮询脚本本体（部署/逻辑见下）。
- `Makefile`：
  - `make memwatch-check` —— 单次打印两节点 available%（只读）；
  - `make memwatch` —— 常驻循环（建议放 tmux，`ctrl-c` 退出）；
  - `make memwatch-reset` —— 清除已触发状态、解除保持。

### 2.3 为什么不是 k8s cgroup 内存上限（2026-08-15 上线前实测否决）

原方案在 Pod 上 `resources.limits.memory`。但实测（8 月 15 日，V4-Flash 在线时只读采集）：

| 位置 | 实测值 |
|---|---|
| 节点 `free -h`（S1） | 107 Gi used / **13 Gi available**（total 121 Gi） |
| `kubectl top` 容器 | leader ~6 GiB / worker ~5 GiB |
| leader **pod cgroup** `memory.current` | **18.5 GiB**（peak 38 GiB） |
| `kubepods.slice` `memory.current` | **19.4 GiB**（max 才是全节点 121 GiB） |

结论：约 **100 GB 的权重+KV 统一内存分配不记入任何 pod/container/kubepods cgroup**，
记在**系统根级**。所以给容器设 `memory.max`：
- 设 104 Gi → 容器自身峰值才 38 Gi，**对真正风险纯空转**；
- 设 <40 Gi → 正常负载就把容器**误杀**（peak 已到 38 Gi）。

→ **k8s 内存上限在这台 GB10 / CUDA 驱动上达不到目标，废弃。** 只有节点级 available
内存（本看门狗读取的指标）能看见并守住那个 100 GB。

### 2.4 阈值与基线（贴地板，别套通用值）

关键现实：**稳态可用就只剩 ~11%（13 Gi / 121 Gi）**，因为 ~100 GB 已被预占。
所以：

| 阈值 | 默认 | 说明 |
|---|---|---|
| `WARN_PCT` | 8 | 低于 8%（≈10 GiB）持续 `CRIT_CONSEC` 次 → 记日志/可选通知 |
| `CRIT_PCT` | 5 | 低于 5%（≈6 GiB）持续 `CRIT_CONSEC` 次 → 自动 scale 0 |
| `CRIT_CONSEC` | 2 | 连续采样次数（默认 `INTERVAL=10s`，≈20s 稳定低于临界才动手） |
| `INTERVAL` | 10 | 轮询间隔（秒） |

> 阈值靠环境变量可调（`WATCH_WARN_PCT` / `WATCH_CRIT_PCT` / `WATCH_CRIT_CONSEC` /
> `WATCH_INTERVAL`）。首周按实况回校准：稳态 ~11%，8% 警告不会误报；
> 若发现某些重负载会瞬时把 available 打到一个很低的位置，再据此微调。

### 2.5 行为模型

- 轮询两台节点（S1 `100.97.87.120`、S2 `100.67.164.92`，tailnet SSH `admin`@`~/.ssh/vgio`）；
- 探不到节点 = **不算数**（fail-open，沿用仓库探针哲学：数据缺失必须放行，不误杀）；
- 触发后写 state 文件 `/tmp/.v4flash-memwatch-fired` 并**保持**——
  **不自动恢复**，引擎只在你 `make v4flash-run` 时回来，避免「scale 0 → 内存松 →
  自拉起 → 又掉」抖动（与「两栈手工控制、qwen38 不设 --restart」的仓库哲学一致）；
- 动作是 `kubectl scale deploy v4flash-worker v4flash-leader --replicas=0`——
  **两个 rank 一起**，不产生 zombie TP 组（gotcha #1）。

### 2.6 使用与验证

```bash
make memwatch-check     # 只读:两节点 available%(实测 S1/S2 均 ~11%)
make memwatch           # 常驻守护(建议 tmux;观察 /tmp/v4flash-memwatch.log)
tail -f ${TMPDIR:-/tmp}/v4flash-memwatch.log
make memwatch-reset     # 触发 scale 0 后,先复位再 make v4flash-run 拉起
```

> **局限**：守护挂在操作机（Mac）上，操作机要在线才有效；节点自身不自保。
> 若要节点自保，需在 S2（k3s server）放一份本地 kubectl + kubeconfig 的等价守护，
> 见 §4 展望。已实测：`make memwatch-check` 两节点返回 11%，`WARN_PCT=8` 当前不误报；
> `make memwatch` 已在守护时两 rank 均在跑（replicas=2），逻辑就绪。

---

## 3. 改动二：Prometheus 告警规则（交给 homelab 监控栈实现）

目标：把「内存/KV/排队/掉线/磁盘」这些**前兆**变成主动告警，而不是事后翻曲线。
现在 node_exporter / smartctl_exporter 已在采，但**没有任何告警规则**。
下面的规则按优先级排列；落地在 **homelab**（`meirongdev/homelab`）的
Prometheus/Alertmanager，`cluster="dgx-spark"` 标签区分。

### 3.1 需要先补的采集（前置条件）

| 采集 | 现状 | 要补什么 |
|---|---|---|
| node_exporter (`:9100`) | ✅ 已采 | 无 |
| smartctl_exporter (`:9633`) | ✅ 已采 | 无 |
| **vLLM `/metrics`** | ❌ 未纳入 Prometheus | 新增一个 scrape job，target `100.97.87.120:8000`，`metric_path=/metrics`，labels `cluster=dgx-spark`（vLLM 默认与 API 同端口暴露；若本 build 走专用 metrics 端口则以实测为准） |

vLLM 侧真正有用的三个指标：`vllm:kv_cache_usage_perc`、`vllm:num_requests_running`、
`vllm:num_requests_waiting`。`make v4flash-load` 现在只能手动查，纳入 Prometheus 后
才有曲线和告警。

### 3.2 告警规则清单

> 所有表达式均以 `cluster="dgx-spark"` 过滤。阈值是起始建议，首月按实测回校准。

| # | 告警名 | 表达式（PromQL 要点） | 触发 | 严重度 | 防什么 |
|---|---|---|---|---|---|
| A1 | `DgxSparkMemPressure` | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100` | `< 12` 持续 5m | warning | 内存逼近红线（整机 OOM 前兆，S2 事件后最该盯的指标） |
| A2 | `DgxSparkMemCritical` | 同上 | `< 5` 持续 2m | critical | 即将整机冻结，应及时人工 `v4flash-stop` |
| A3 | `DgxSparkKVCacheHigh` | `vllm:kv_cache_usage_perc` | `> 0.90` 持续 5m | warning | KV 打满 = 排队/吞吐骤降前兆 |
| A4 | `DgxSparkRequestsQueued` | `vllm:num_requests_waiting` | `> 4` 持续 2m | warning | `max_num_seqs=6` 饱和，有人在排队挨饿（2026-08-02 事故类型） |
| A5 | `DgxSparkNodeDown` | `up{job="node-exporter-dgx-spark"}` | `== 0` 持续 1m | critical | 节点掉线/断电瞬间告警（**S2 那次就是这类**，能第一时间触发恢复流程） |
| A6 | `DgxSparkSmartsFail` | 磁盘 SMART 健康指标（smartctl_exporter） | 任一盘非 OK | critical | 磁盘老化预警，先行换盘 |
| A7 | `DgxSparkLoadSpike` | `node_load1` | `> 8` 持续 10m | info | 负载尖峰，供调查（GB10 load 探针噪音注意过滤） |

### 3.3 说明与注意事项

- **A5 最重要**：S2 的判死当时是靠四条路径**人工**拼出来的。一条 `up==0` 的告警，
  能让你在断电那一刻就被叫醒，而不是几小时后发现服务凉了。它也是将来接
  「告警 → 自动动作」（如通知 / 触发恢复）的入口。
- **vLLM `waiting` 会排大数**：heavy 批处理时 `num_requests_waiting` 可上百，
  阈值按本集群实际（`max_num_seqs=6`）校准，勿直接抄通用值。
- **A1/A2 的 `MemAvailable` 已含页缓存**，比裸 `MemFree` 准确，直接用它。
- 这些规则**只是告警不带执行器**。若要「逼近红线自动 scale 0」，执行器已由
  看门狗承担（§2，本仓库已实现）；homelab 若想接自动动作，可用 Alertmanager
  webhook 触发 `make v4flash-stop` —— 但注意别和 §2 看门狗重复/冲突。

---

## 4. 概要与后续

|项|是否本次|说明|
|---|---|---|
| 宿主机看门狗 + 自动 scale 0（§2） | ✅ **已实现** | `scripts/mem-watch.sh` + `make memwatch*` |
| ~~k8s cgroup 内存上限~~ | ❌ 已废弃 | 实测统一内存绕过 cgroup，兜不住（§2.3） |
| Prometheus 告警（§3） | 仅规格 | homelab 落地，需补 vLLM scrape + 规则 |
| 节点自保版看门狗（§2.6 展望） | 后续 | 在 S2（k3s server）放本地 kubectl 的等价守护，脱离操作机也能自保 |
| 智能 PDU（电源侧） | 后续（硬件） | S2 那次真正适用的手段，见 fallback §1.1 |

> **检查清单（落地判据）**：
> - ✅ `scripts/mem-watch.sh` 语法通过；`make memwatch-check` 两节点返回 11%
>   （S1 `100.97.87.120` / S2 `100.67.164.92`），`WARN_PCT=8` 当前不误报；
> - ✅ 看门狗执行条件已验证：`replicas=2`（两 rank 在跑），`--once` 不落 state 文件；
> - ✅ 动作 = `kubectl scale deploy v4flash-worker v4flash-leader --replicas=0`（两 rank
>   一起，无 zombie TP 组）；触发后写 state 保持，`make memwatch-reset` 解除；
> - ⏳ 常驻守护尚未在后台运行（会在你 `make memwatch`（tmux）时启动）；
> - ⏳ §3 homelab 里 vLLM `/metrics` 抓到 + A1–A7 至少 A1/A5 挂上并出过一条测试告警。
