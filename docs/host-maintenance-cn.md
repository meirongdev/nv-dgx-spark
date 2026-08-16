# 宿主机维护(apt / 驱动 / 内核 / DKMS)

两台 DGX Spark 的 OS 层维护手册。**跑 `apt upgrade`、动 NVIDIA 驱动、删内核之前
先读这一篇** —— 这里每条都是 2026-08-08 ~ 08-11 那轮升级实际踩出来的。

| 铁律 | 为什么 |
|---|---|
| 先 `sudo apt-get -s upgrade`,逐行看 `Inst` | CUDA 源和 Ubuntu 官方源**同优先级 500**,能赢驱动决策 |
| 动 apt 前先 `make v4flash-stop` | `network-manager` 的 postinst 重启 NM,会抖断 200G 的 NCCL 链路 |
| 升级放进 tmux,带 `--force-confold` | Tailscale 骑在 NM 托管的上联口上,SSH 一断 `dpkg` 就吃 SIGHUP;静态 DNS 也靠它保住 |
| 删任何 nvidia 包前看 `apt-mark showmanual \| grep nvidia` | 一个 `auto` 的驱动栈,离 `autoremove` 掉整块 GPU 只差一步 |
| `dkms` 一律显式 `-a arm64` | 裸 `dkms` 默认 `aarch64`,会**静默空转** |
| 重启前确认 `/boot/initrd.img-<kernel>` 存在 | 铁律 —— 2026-08-08 差点变砖 |

**已知良好基线(2026-08-11,两台一致)**:kernel `6.17.0-1029-nvidia`
(保留 `6.17.0-1014-nvidia` 作回退)、driver `580.173.02`、`dkms status` 每内核
一条且全 `arm64`、待升级/autoremove 均为 0、`dpkg --audit` 干净、swap 0。

---

## 1. 栈在跑的时候绝不能 `apt upgrade`

200G CX7 链路 `enp1s0f0np0`(192.168.200.x,TP=2 的 NCCL 路径)是
**NetworkManager 托管**的(connection `netplan-enp1s0f0np0`,两台都是)。
`network-manager` 常驻待升级列表,其 postinst 会重启 NM —— 链路一抖 NCCL 就崩,
vLLM 跟着死。

而 `tailscale0` 是 `connected (externally)`,**不归 NM 管,SSH 不会断** ——
所以这个故障极易被误判成「vLLM 自己崩了」而不是「我升了 NetworkManager」。

```bash
make v4flash-stop
ssh … 'tmux new-session -d -s aptup "sudo DEBIAN_FRONTEND=noninteractive \
  apt-get upgrade -y -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef > /tmp/aptup.log 2>&1; echo EXIT=\$? >> /tmp/aptup.log"'
```

放 tmux 里是因为 Tailscale 仍骑在 NM 托管的**上联口** `enP7s7` 上,NM 抖那条 SSH
就断。`--force-confold` 是刻意的:它保留现有配置文件,而**静态 DNS 是承重的**
(成因见 [gotchas-cn.md](gotchas-cn.md) #5)。升完 NM 复验:

```bash
nmcli -g ipv4.dns con show "Wired connection 3"   # → 223.5.5.5,119.29.29.29
getent hosts modelscope.cn
```

> apt 源必须是清华镜像,否则升级会 stall(`ports.ubuntu.com` 实测 33 KB/s 且会
> 彻底卡死)。两台均已切换,见
> [china-network-mirrors-cn.md](china-network-mirrors-cn.md)。

---

## 2. CUDA 源会装进第二套 NVIDIA 驱动

**CUDA sbsa 源**(`developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa`)
在两台上都启用,**优先级 500,和 Ubuntu 官方源同级**,所以它能赢升级决策。
一次普通的 `apt upgrade` 就可能在跑着的 580 旁边叠出另一个分支的完整驱动 +
第二个 DKMS 模块 —— 用户态/内核态版本不匹配**当场打死 TP worker**,同时给下面
第 3 节那条「DKMS 冲突 → initramfs 不生成 → 重启变砖」铺好路。2026-08-10 S2
上就查出过这么一颗雷(`nvidia-driver-550` 空壳,候选版本是 CUDA 源的真驱动元包)。

NVIDIA 自带的 pin `/etc/apt/preferences.d/cuda-compute-repo-lowpri2` **按分支名
硬编码**(`nvidia-*580`),每出一个新分支(590、600…)这个洞就重开一次。
2026-08-11 已在两台加通用防护
`/etc/apt/preferences.d/99-local-nvidia-driver-branch-guard`:同样
`Pin: release l=NVIDIA CUDA` / `Pin-Priority: -1`,但匹配
`nvidia-driver-*`、`nvidia-dkms-*`、`nvidia-kernel-*`、`libnvidia-compute-*`。

> ⚠️ **刻意不写成 `nvidia-*`** —— `nvidia-container-toolkit` 和
> `libnvidia-container*` 同源,且是容器访问 GPU 所必需,泛化会误伤。
> **有了 pin 也仍然要看 `-s upgrade` 的 `Inst` 行**,别假设"列表里没 nvidia 就安全"。

### 删 nvidia 包之前:先查 `auto` 标记

S2 上 580 整条链曾**全部是 auto-installed**,而这些包**只互相依赖**形成闭环 ——
真正拴住它的手动包竟是那个 32KB 的 550 文档空壳。S1 上同样这几个则全是 `MANUAL`。
`apt-get -s purge --auto-remove` 只清扫本次删除**直接孤立**的包,而事后单独跑
`apt autoremove` 是全局 mark-and-sweep,对孤立环的判定可能不同。别赌这个语义差异:

```bash
apt-mark showmanual | grep nvidia   # 先看清楚
sudo apt-mark manual nvidia-driver-580 nvidia-utils-580 nvidia-dkms-580 \
  nvidia-kernel-common-580 nvidia-kernel-source-580 libnvidia-compute-580 \
  nvidia-compute-utils-580
sudo apt-get -s autoremove          # 必须报 0 个可删,才继续
```

---

## 3. DKMS 默认 arch 是错的 —— 一律 `-a arm64`

**这是 2026-08-08 那次 `Error! Installation aborted.` → initramfs 不生成的真正
根因,而且一点都不显然。**

这两台上所有 DKMS 记录都存在 **`arm64`**(dpkg arch)下,但 `dkms` 不带 `-a` 时
默认用 **`aarch64`**(`uname -m`)。裸命令会「看起来成功、实际什么都没做」:

```console
$ sudo dkms remove nvidia/580.173.02 -k 6.11.0-1014-nvidia
Module nvidia/580.173.02 is not installed for kernel 6.11.0-1014-nvidia (aarch64). Skipping...
$ dkms status        # 记录纹丝不动
```

`/etc/dkms/framework.conf` 里没有 arch 覆盖。当初那条重复记录,正是手工救场时
跑的 `dkms install --force … -a aarch64` 造出来的 —— 两条记录别名同一个模块路径。

### 清理流程(2026-08-11 两台验证过)

删多余的 `aarch64` 记录**是安全的**:DKMS 会就地
`Restoring archived original module`,模块数始终保持 5,不存在无驱动窗口。
停机窗口内做,一台一台来:

```bash
# 1. 先清死内核 —— 注意显式 -a arm64
sudo dkms remove nvidia/<ver> -k <dead-kernel> -a arm64
sudo apt-get purge -y linux-{headers,image,modules,modules-extra}-<dead-kernel>

# 2. 再删运行内核上那条重复记录
sudo dkms remove nvidia/<ver> -k <running-kernel> -a aarch64
ls /lib/modules/<running-kernel>/updates/dkms/     # 必须仍是 5 个模块
dkms status                                        # 每内核一条,全 arm64

# 3. 模块自检 —— 五个都必须报出驱动版本
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
  modinfo /lib/modules/<running-kernel>/updates/dkms/$m.ko.zst | awk '/^version:/{print $2}'
done

# 4. 铁律 —— 重启前重新生成并确认
sudo update-initramfs -u -k <running-kernel>
ls -la /boot/initrd.img-*

# 5. 重启后确认 GPU 真的回来了
uname -r; nvidia-smi --query-gpu=driver_version --format=csv,noheader
modinfo -n nvidia          # → /lib/modules/<k>/updates/dkms/nvidia.ko.zst
```

**别试图删掉 DKMS 改用预编译模块**:`nvidia-driver-580` 硬依赖
`nvidia-dkms-580` 且无替代。两者路径也不冲突(`updates/` 对 modprobe 就是压过
`kernel/`),共存是 NVIDIA 的设计。

---

## 4. 其他会复发的

- **`swapoff -a` 从来不是持久的。** S2 的 `/etc/fstab` 有过
  `/swap.img none swap sw 0 0`,升级后 swap 自己回来了 15Gi(已注释)。S1 没有。
- **snap 播种会堵死 `dist-upgrade`。** `nvidia-desktop-default-snaps` 的 postinst
  会下 350MB GNOME 运行时(实测 5.25 kB/s、ETA 28 小时)。它把播种包在 `if` 里、
  失败只是 `exit 0`,所以**跳过是官方支持路径**:`snap abort <id>` +
  kill `seed-default-snaps.sh`,dpkg 立刻继续。
- **不存在驱动被自动升级的风险**:`unattended-upgrades` 未安装,
  `nvidia-spark-run-apt-upgrade-once` 是一次性服务且两台的 `done` 标记都在。

> **S2 历来是被漏掉持久化配置的那台** —— 静态 DNS、`swapoff` 的 fstab 条目、
> 驱动栈被标 `auto`,三次都是 S2 独有的缺口。改宿主机配置时,**显式检查 S2**。
