# GB10 主机级调优 —— 实测结论与不要动的东西

> **状态：2026-08-25 落地完成。** GPU 时钟上限 2200 MHz 已在**两台**生效，
> `gb10-clock-cap.service` 已安装并 enabled，重启路径已验证。
> §6 的第二根 QSFP 线已实测**否决**：对 prefill 无影响（+0.17%），论坛的 2.2× 不复现。

## 0. 一句话

GB10 几乎不给主机级调优留余地：功耗上限、ECC、风扇、Jetson 式电源模式**全部不存在**，
CPU governor / MTU / RoCE MTU / NUMA / swap 早已是最优。**唯一真实有效的旋钮是 GPU 时钟上限**
（`nvidia-smi -lgc`），因为 V4-Flash 的 decode 受限于 LPDDR5X 带宽而非 SM 频率 ——
于是砍频率几乎不要钱，却能大幅降功耗。

## 1. 实测：时钟上限扫描（双机对称加锁）

方法：两节点同时 `nvidia-smi -i 0 -lgc 0,<MHZ>`；prefill 用 **8655 token 唯一前缀**
提示词（每次换 run-id → 击穿 prefix cache，`max_tokens=1` 使 wall≈prefill）；
频率/功耗/温度由两台各自的 `nvidia-smi -lms 500` 采样，按 arm 时间戳切片。
档位对齐论坛帖 379389 便于交叉验证。

| 上限 | prefill tok/s | Δprefill | S1 clk mean | S2 clk mean | 双机 GPU rail 功耗 | ΔPower | S1/S2 温度 |
|---|---|---|---|---|---|---|---|
| uncap | 1794 | — | 2474 | 2499 | 84.1 W | — | 70/68 °C |
| 2400 | 1774 | −1.3% | 2382 | 2386 | 69.7 W | −19% | 70/70 |
| **2200** | **1731** | **−3.7%** | **2172** | **2183** | **55.2 W** | **−36%** | **68/68** |
| 1900 | 1632 | −9.2% | 1891 | 1866 | 42.9 W | −50% | 65/65 |
| 1700 | 1552 | −13.7% | 1690 | 1664 | 36.5 W | −58% | 63/64 |
| 1400 | 1383 | −23.0% | 1369 | 1366 | 31.0 W | −64% | 61/62 |
| uncap（复测） | 1800 | — | 2467 | 2479 | 88.2 W | — | 73/76 |

**锁确实生效**：`clk mean` 精确跟随上限，两台一致。GB10 **按离散档位吸附** ——
设 2200 实测落在 2172–2190。

## 2. 实测：decode 专项（这才是关键，且第一次测错了）

扫描表里的 decode 列**不可用**：两个相同的 `uncap` arm 之间差了 5.2%，而且最后那个最快
（升温趋势），中间的 arm 被系统性压低，看起来像 −5%~−11% 的"代价"，实际是排序伪影。

重测方法：`uncap / 2200 / 1700` **交错轮转 12 轮**（抵消漂移）+ `min_tokens=300`
强制固定输出长度（消除短回复的开销偏差 —— 见 `benchmarking-cn.md`），**配对**统计。
第 12 轮被外部请求污染（uncap=2.45 tok/s），已剔除，n=11。

| 档位 | mean tok/s | SEM | 配对差 vs uncap | 95% CI | 结论 |
|---|---|---|---|---|---|
| uncap | 41.46 | ±0.58 | — | — | 基线 |
| **2200** | **41.83** | ±0.68 | **+0.9%** | [−1.9%, +3.7%] | **无法与 0 区分** |
| 1700 | 40.74 | ±0.64 | −1.7% | [−5.2%, +1.7%] | 无法与 0 区分 |

单次测量的噪声地板（uncap 组内 σ）= **4.6%**。所以任何 n≤3 的 decode 对比在这台机器上
都说明不了问题 —— 这条比结论本身更值得记住。

## 3. 结论与落地

**采用 2200 MHz**：decode 无显著变化、prefill −3.7%、双机 GPU rail −36%。它是这条曲线
对我们负载的拐点。

不采用 1700（虽然 GPU-rail 每 token 能耗更低：249 vs 367 Wh/1M）—— prefill −13.7% 是
真实的长上下文延迟代价，而 100K prefill 本来就是本栈唯一被同行打平/打败过的项目
（见 `deepseek-v4-flash-cn.md` §已否决的 NVFP4-KV 配方）。

```bash
make clock-cap-apply      # 两节点加锁 2200(运行时,重启失效)
make clock-cap-verify     # ← 唯一可靠判据,见下
make clock-cap-install    # 装 systemd 单元,重启后仍生效
make clock-cap-reset      # 解锁(单元若仍 enabled,下次重启会再加锁)
make clock-cap-uninstall  # 彻底移除单元并解锁
```

### 落地记录(2026-08-25)

| 步骤 | 结果 |
|---|---|
| `make clock-cap-apply` | 两台 `GPU clocks set to (gpuClkMin 0, gpuClkMax 2200)` |
| `make clock-cap-verify`(带负载) | S1 mean **2177** / S2 mean **2185**(n≈20)→ 生效 |
| `make clock-cap-install` | 两台单元 installed+enabled+active,`ExecMainStatus=0` |
| **重启路径验证** | 手动 `-rgc` 解锁 → `systemctl restart gb10-clock-cap` → 再次带负载验证,锁自动回到 2177/2185 ✅ |
| 引擎影响 | v4flash-leader/worker 全程 `1/1 Running`、0 重启(全部操作不需要重启引擎) |

### ⚠️ 三个必须知道的点

1. **两台必须对称。** TP=2 是锁步的，只压一台 = 拿全部代价、只拿一半收益。
2. **`-lgc` 重启即失效。** 靠 `gb10-clock-cap.service`（`After=nvidia-persistenced`）。
3. **`nvidia-smi` 没有任何字段能告诉你锁是否生效。** 加锁期间
   `Applications Clocks Setting` 恒为 `Not Active`、`clocks.max.sm` 恒为 `3003`，
   而且**刚加锁时空载读数仍显示旧值**（2392 MHz）——这就是为什么第一次 2 秒探测
   看起来像空操作。锁稳定一段时间后空载读数确实会跟随上限（实测 2177/2190），
   但它不能当判据，因为没有任何显式的"已加锁"标志位。
   **唯一判据 = 有负载时读 `clocks.current.sm`**，即 `make clock-cap-verify`。
   这一点直接影响可运维性：写不出幂等的"锁还在吗"探针。

## 4. GB10 上**不存在**的旋钮（别再找了）

| 想调的东西 | 实测结果 |
|---|---|
| 功耗上限 `-pl` / 应用时钟 `-ac` | `Current/Default/Min/Max Power Limit` **全 N/A** |
| Jetson 式电源模式 | 无 `nvpmodel` / `jetson_clocks`（两台都探过） |
| ECC 开关 | `ecc.mode.current = [N/A]`，无法关掉换内存 |
| 显存用量 | `FB Memory Total/Used/Free` 全 N/A（只能看 `free -h`） |
| 风扇曲线 | 无 hwmon fan input、无 lm-sensors，cooling device 只有 `Processor 0/3` |

## 5. 已经是最优 / 不要动

- **CPU governor = `performance`**（20 个 policy 全部），跑在 `cpuinfo_max_freq` 2.808 GHz。
  论坛实测切 `powersave` 对省电几乎无效。
- **200G 链路 MTU 9000**；在用那条 RoCE 设备 `rocep1s0f0` `active_mtu=4096`（= `max_mtu`）。
- **NUMA 单节点**（10× Cortex-X925 + 10× A725），无绑核/interleave 可做。
- **swap off**。论坛实测：开 swap = 硬锁必须物理重启；关掉只是变慢。
- **THP 保持 `madvise`**。改 `always` 是通用建议，但那 ~100 GB 是驱动管的
  （`Committed_AS` 只有 20.6 GB 完全没记它），而可回收余量只有 ~12 GiB，
  `always` 反而招 compaction 停顿。
- **不要开 `irqbalance`**（现状 inactive）。mlx5 completion queue 由驱动自己做亲和，
  中断量很低；big.LITTLE 上 irqbalance 可能把网卡中断挪到 A725 小核。
- **不要刷 ConnectX-7 固件**。`fwupdmgr` 实测两台都是 28.45.4028、**无可用更新**；
  而论坛有一帖「双 Spark 升网卡固件后 NCCL all_gather 性能腰斩，靠降级解决」。
  没有 BMC/IPMI，刷砖的代价是一次机房往返（2026-08-15 那次是 6.5 小时）。
- **关深度 CPU idle 状态**：能减小抖动但会多发热，净负收益。
- **网卡 ring buffer 1024/8192**：RoCE 绕过以太网 ring，只影响这条链路上的 TCP（rsync）。

## 6. ❌ 已否决：第二根 QSFP 线对本机没有影响（2026-08-25 实测）

**现状**：两台的**两个 QSFP 口都接着线且都 link-up 200000 Mb/s**。
`enp1s0f0np0`（`rocep1s0f0`，有 IP `192.168.200.101/102`，RoCE MTU 4096）在用；
`enP2p1s0f0np0`（`roceP2p1s0f0`）**link-up 但无 IP、无路由、无 NM/netplan profile**，
GID 表只有 `fe80::`（无 IPv4 GID → RoCE v2 用不了），RX 全是组播噪声。

**论坛证据**（帖 350077）：两个口都接线时 NCCL bus bandwidth 只有 **10.25 GB/s**，
**拔掉一根 → 22.1 GB/s（2.2×）**，零软件调优。原帖给的架构解释（帖 373628）是
*每个物理口共享同一对 PCIe5 x4 连接*，接两根不是加带宽而是**劈开**它。

**⚠️ 但我们本机的 PCIe 拓扑与这个解释不符（2026-08-25 `lspci -vv` 实测）**：

```
0000:01:00.0 / 0000:01:00.1   LnkCap+LnkSta: Speed 32GT/s, Width x4   ← enp1s0f0np0(在用)
0002:01:00.0 / 0002:01:00.1   LnkCap+LnkSta: Speed 32GT/s, Width x4   ← enP2p1s0f0np0(空转)
```

两个物理口挂在**两个不同的 PCIe 域、各自独立的 x4 Gen5 链路**上，不是共享一对。
所以"接两根线劈开 PCIe 带宽"这个机制在我们这台上**不成立**。顺带一个有用的数字：
单条 PCIe5 x4 ≈ **15.75 GB/s**，本身就低于 200G 线速的 25 GB/s —— **瓶颈在 PCIe，不在网线**。

**因此对"关掉第二口能提速"的预期要下调。** 仍值得测一次（便宜、可逆），但可能的机制
只剩下 NCCL 层面（例如 `NCCL_IB_HCA` 同时列了两个 HCA，而 `roceP2p1s0f0` 的
`active_mtu` 只有 1024 且无 IPv4 GID —— 一条不可用/低效的 rail 是否拖累了 NCCL 的
rail 选择）。**注意这一节两次修正了方向**：先是"把第二条 rail 配上以提升 prefill"（错，
方向相反），再是"第二根线在腰斩带宽"（本机 PCIe 证据不支持其机制）。测出来再说。

**实测结果（2026-08-25，两节点同时 `ip link set enP2p1s0f0np0 down`，时钟上限保持 2200）**：

| 第二口 | prefill (8655 tok 唯一前缀) |
|---|---|
| UP（原状） | 1731 tok/s |
| **DOWN** | 1736 / 1734 / 1732 / 1735 → mean **1734 tok/s** |

**差异 +0.17%，即零效应。** prefill 这个测法的复现性极好（4 次跨度 0.23%），
所以论坛那个 **2.2×** 的效应若存在绝不可能测不到。decode 同步测了 3 次
（37.3 / 42.4 / 46.4）——落在一贯的 4.6% 噪声里，无信号。
测试期间链路状态确认有效：两台 `enP2p1s0f0np0` = DOWN / `Link detected: no`，
port0 仍 200000 Mb/s，在用的 `rocep1s0f0` `active_mtu=4096` 不变。

**结论：保持原状（两根线都插着），不要动。** 与 §6 上面的 `lspci` 证据自洽 ——
两个口在独立 PCIe 域各自 x4，本机不存在"接两根线劈开带宽"的机制。论坛那个结论
应该绑定在他们的具体拓扑/固件上，**不要跨机器照搬**。

> **这一节的价值在于它被修正了三次**：①"把第二条 rail 配上以提升 prefill"（错，
> 方向相反）→ ②"第二根线在腰斩带宽"（照搬论坛，本机 PCIe 证据不支持其机制）→
> ③ 实测 +0.17%，零效应。教训是同一条：**GB10 上任何来自别人机器的性能结论，
> 在自己机器上复现之前都只是假设。**

## 7. 交叉验证：同行的数字对得上

论坛帖 379389 的测试对象**和本栈同构**（DeepSeek-V4-Flash-0731 FP8 + vLLM +
spec decoding + prefix caching + 双机 TP=2），17 个采样点：

| | 他们（wall 功耗） | 我们（nvidia-smi GPU rail） |
|---|---|---|
| 2200 档 decode | 51.43 vs 51.34（持平） | 配对差 +0.9%，不显著 ✅ 一致 |
| 2200 档功耗 | 330 W → 274 W = **−17%** | 86.2 W → 55.2 W = **−36%** |
| 能效最优档 | 1700（1350 Wh/1M） | 1700（GPU rail 249 Wh/1M） ✅ 一致 |
| 1400 档 prefill | −14% | −23%（我们更敏感） |
| 温度 | "capping barely cools the GPU"，Grace SoC 恒 90–96 °C | GPU 68→63 °C，acpitz 抖动大 |

**功耗百分比差异的原因**：`nvidia-smi` 的 `power.draw` 只覆盖真实整机功耗的
**12–27%**（论坛实测，需墙插口表才准）。所以**我们的 −36% 不等于电费降 36%**，
按同行的 wall 实测，2200 档大致是 **−17%** 量级。

**用户转述的那条说法**（"温度降 8–12 °C、GPU rail 功耗降 36%、decode 在噪声内、
冷 prefill 慢 3.9%、整体代价 1.34%"）：功耗 −36%、decode 噪声内、prefill −3.7%
三项在我们这里**几乎精确复现**；**温度那条不成立** —— 2200 档只降 0–2 °C，
要降 8–12 °C 得压到 1400–1700，而论坛也明确说时钟上限"几乎不降 GPU 温度"、
Grace SoC 在任何频率下都是 90–96 °C。

## 8. 参考

- [论坛 379389 — 再也不觉得把 Spark 跑在 1400–1700 MHz 以上有意义](https://forums.developer.nvidia.com/t/it-makes-no-sense-to-me-anymore-to-run-my-sparks-above-a-1400-1700-mhz-gpu-clock/379389)（同构双机 V4-Flash，17 点扫描 + systemd 持久化写法）
- [论坛 350077 — NCCL 实测 10GB/s 而非 25 GB/s](https://forums.developer.nvidia.com/t/dgx-spark-nccl-test-10gb-s-not-200-gbps-25-gb-s/350077)（两口都接线 → 带宽减半）
- [论坛 373628 — Multiple DGX, QSFP, RDMA/NCCL](https://forums.developer.nvidia.com/t/multiple-dgx-qsfp-rdma-nccl/373628)（每个物理口共享同一对 PCIe5 x4）
- [论坛 368025 — 升网卡固件后 NCCL all_gather 腰斩，降级解决](https://forums.developer.nvidia.com/t/nccl-all-gather-performance-halved-on-dual-spark-setup-connectx-7-after-msi-firmware-update-solved-via-downgrade/368025)
- [论坛 348562 — 降低空载功耗](https://forums.developer.nvidia.com/t/suggestions-for-reducing-idle-power-consumption/348562)（ConnectX-7 LVFS 固件 40W→24W；governor/Wi-Fi 几乎无效）
- [论坛 364886 — 128 GB 到底去哪了](https://forums.developer.nvidia.com/t/memory-creep-on-dgx-spark-where-your-128-gb-actually-goes-and-how-to-stop-it/364886)（初始化后内存持平，无运行期漂移）
- [论坛 352339 — 内存满时整机崩](https://forums.developer.nvidia.com/t/system-crashes-when-memory-is-full/352339)（earlyoom 是社区公认解；swap 必须关）
- 复现脚本：`scripts/gb10-clock-cap.sh`；一次性测量脚本见提交历史（tmux 驱动，双机对称）。
