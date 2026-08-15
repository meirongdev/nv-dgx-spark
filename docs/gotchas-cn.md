# 踩坑合集(Known Gotchas)

> 本文从 `CLAUDE.md` 拆出(2026-08-15),因为这些内容长期稳定、但每 session 全量载入
> 太占上下文。**`CLAUDE.md` 保留一份一行索引**,遇到对应症状再回来读细节。
>
> 每一条都是在这套集群上真实付出代价换来的,带日期和实测数字。**动手前先扫一遍标题**。

## 目录

| # | 症状/主题 | 影响面 |
|---|---|---|
| [1](#1-单-rank-重启会制造僵尸-tp-组) | 单 rank 重启 → 僵尸 TP 组,`/health` 骗人 | V4-Flash 运维 ⚠️ 最贵 |
| [2](#2-两套栈互斥抢显存) | V4-Flash 和 qwen38 抢显存 → OOM 整机 | 切换模型 ⚠️ |
| [3](#3-nccl-warn--gid-table-changed-是既有噪声) | `NCCL WARN ... GID table changed` 刷屏 | 读日志(无害) |
| [4](#4-s1-上的-docker-build-被静默强制走-xray-代理) | 国内镜像源"很慢"(实为代理绕道,90 倍差距) | 构建镜像 |
| [5](#5-上联-dhcp-不发-dns静态-dns-是承重的) | ModelScope/github 不通但 Tailscale 正常 | 网络 |
| [6](#6-modelscope--hf-cache-的符号链接必须是相对路径) | 容器内 `HFValidationError` | 下载模型 |
| [7](#7-ansible-220--docker---format-table-names) | `Syntax error in template` | 退役栈(Ansible) |
| [8](#8-从中国大陆拉镜像和模型) | 外网 registry 被墙/极慢 | 所有下载 |

---

## 1. 单 rank 重启会制造僵尸 TP 组

**重启/删除其中一个 rank,存活的那个会永久卡在 collective 里但不退出**:Pod 保持
`1/1 Running`、`restartCount=0`,`/health` 和 `/v1/models` **照常返回 200**,
而每一次真实生成都超时(2026-08-13 实测)。

任何单 rank 事件都会触发:进程 OOM、CUDA 错误、一个节点重启、一次误手的
`kubectl delete pod`。旧的 systemd 方案对此免疫,因为重启它会**同时**拆掉两台的容器。

**所以永远用 `make v4flash-restart`(两个 rank 一起),恢复代价约 10 分钟。**

现在有 liveness 探针能兜住:leader 的探针(`liveness.py`,在
`k8s/v4flash/configmap-launch.yaml` 里)检测的是**"有活干但零进展"**——读 `/metrics`,
仅当 `num_requests_running+waiting > 0` **且** `vllm:iteration_tokens_total_count`
自上次检查以来没有前进时才判失败。worker 的探针盯着 leader 的 `/health`,共同命运。

### 三条探针设计铁律(每条都是这里踩出来的)

1. **多节点 TP/PP 推理场景下,静态 HTTP 端点不是健康信号。**
2. **发真实请求的探针分不清"卡死"和"忙"。** v1 版本发 `max_tokens:1` 的生成请求,
   结果它排在饱和引擎后面(`Running: 6/Waiting: 2`,全都健康),把一个好好的 leader
   SIGKILL 了,造成约 10 分钟停服。**没有哪个超时值是够宽的**——排队延迟无上界。
   要从**不排队的旁路**读健康状态,并且判据要落在**进展**上。
3. **只在有正面证据时才杀;数据缺失必须放行。** v2 版本把指标缺失当成 `0`,
   而 vLLM 的 histogram 在第一次引擎迭代完成前根本不存在——于是
   "刚 ready、第一个请求在飞"被读成了卡死。**误杀一次的代价是完整重载;
   晚一分钟发现真卡死几乎没有代价。**

---

## 2. 两套栈互斥(抢显存)

V4-Flash 需要**两台各约 83GB**,Qwen3.8-27B 降级栈占 S1 约 91GB。
**两者不能同时跑**,否则 OOM 整台机器——就是那种会连 tmux server 一起带走的故障。

```bash
make qwen38-stop     # 必须先停
make v4flash-run     # 再起
```

反向同理。qwen38 容器**故意不设 `--restart`**,就是为了避免开机自启后和 k3s
拉起的 V4-Flash 撞车。详见 `docs/qwen38-27b-fallback-cn.md` §5.4、§7。

---

## 3. `NCCL WARN ... GID table changed` 是既有噪声

每约 45 秒在 `roceP2p1s0f0` 上出现一次。**与 k3s 无关**——在旧的 systemd journal 里
出现过约 19.4 万次,可回溯到 2026-06-05。**忽略它**,读日志时过滤掉。

---

## 4. S1 上的 `docker build` 被静默强制走 xray 代理

`~/.docker/config.json` 里设了 `proxies.default` → `http://172.17.0.1:10809`,
于是 docker **客户端**会往每一次 build 和 `docker run` 注入 `HTTP(S)_PROXY`。
对国内镜像源来说,这等于把流量绕到国外再绕回来:实测
**经代理 18 KB/s vs 直连同一个清华源 1.6 MB/s(约 90 倍)**。
症状看起来**完全就像"这个镜像源很慢"**,能白白浪费几个小时。

- `--build-arg http_proxy=` 只能修好纯 HTTP 的抓取(apt);HTTPS 客户端
  (`uv`/`pip`)照样会捡起 `HTTPS_PROXY`。Dockerfile 里写 `ENV http_proxy=""` 也不可靠。
- **正确修法:构建期间把 `~/.docker/config.json` 移开。** 它是*客户端*配置——
  daemon 不需要重启,所以正在跑的 vLLM 容器不受影响。
  带 `trap ... EXIT` 自动恢复的可用脚本:
  `benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/build_noproxy.sh`。
- 真正需要外网的场景(github clone)要保留代理。
- **`docker run` 同样被注入** —— 起 qwen38 容器时已显式清空这些变量
  (见 `scripts/qwen38-start.sh`)。
- registry **pull** 走的是 daemon 而不是这个文件,所以不受影响——
  daocloud 对某个镜像慢(如 `buildpack-deps:jammy` 39 KB/s)是另一回事,
  优先选本地已有的 base image。

---

## 5. 上联 DHCP 不发 DNS,静态 DNS 是承重的

实验室 DHCP(10.14.20.1)**不下发任何 DNS 服务器**。DGX 节点上能用的 DNS
完全来自静态配置;没有它,所有非 tailnet 的解析都 SERVFAIL
(`tailscale0` 上的 MagicDNS 只覆盖 tailnet 名字)。

**这就是"ModelScope/github 不通、但 Tailscale 一切正常"这种症状的成因。**

2026-07-31 修复:在**两台**上用
`nmcli con mod "Wired connection 3" ipv4.dns ...` 持久化了 `223.5.5.5 119.29.29.29`
(在那之前 S1 只有一个重启就没的 `resolvectl` 临时修复,S2 则什么都没有)。

诊断:`nslookup <域名> 223.5.5.5` 能通、而裸 `nslookup <域名>` 不通 → 就是这个问题。

---

## 6. ModelScope / HF-cache 的符号链接必须是相对路径

`snapshot_download`(以及 HF cache)可能写出**绝对**符号链接。在 vLLM 容器里
这个 cache 挂载在另一个路径上,绝对链接无法解析——vLLM 于是把这个名字当成
HF repo id,然后崩溃(`HFValidationError`)。

修法:换成相对符号链接,例如

```bash
cd /home/admin/.cache/modelscope/Qwen
ln -snf Qwen3___6-35B-A3B-FP8 Qwen3.6-35B-A3B-FP8
```

**更省事的预防措施**:`snapshot_download` 用 `local_dir=` 而不是 `cache_dir=`,
直接落真实文件(qwen38 就是这么下的)。下完可用 `find <dir> -type l` 确认无链接。

(和 V4-Flash 那条"必须从本地 PATH 启动、不要用 HF repo id"是同一个根因。)

---

## 7. Ansible 2.20 + Docker `--format 'table {{.Names}}…'`

Ansible 的 Jinja2 会吃掉 `{{.Names}}`,报 `Syntax error in template`。
不要把 `--format 'table {{.X}}'` 透过 `ansible -a` 传;要么去掉 `--format`,
要么按 Jinja 转义写成 `{{ '{{' }}.Names{{ '}}' }}`。

---

## 8. 从中国大陆拉镜像和模型

DGX 服务器在中国大陆,多数国外 registry 要么被墙要么极慢。
**每台 DGX 用自己的国内高速链路拉都很快——不需要代理/VPN/中转。**

- **Docker 镜像** → 用 **daocloud** 前缀拉官方/热门镜像,然后重打回原名:
  ```bash
  docker pull docker.m.daocloud.io/vllm/vllm-openai:latest
  docker tag  docker.m.daocloud.io/vllm/vllm-openai:latest vllm/vllm-openai:latest
  ```
  daocloud 覆盖热门官方组织,但对冷门组织会按 allowlist 拒绝。
  `/etc/docker/daemon.json` 里配的 mirror 经常不生效(docker 会回落到被墙的
  `registry-1.docker.io`)——**用显式的 `docker.m.daocloud.io/…` 前缀**。
  在非 DGX 的 x86 机器上拉要加 `--platform linux/arm64`(GB10 是 aarch64)。
- **模型** → ModelScope(`modelscope download --model <id> --local_dir …`);
  hf-mirror 在大的 `*.safetensors` 上会 reset。**Python 包** → 清华 PyPI。
- **要避开的**:Cloudflare 前置的代理(`agsv.top`/`hub.rat.dev`/`1ms.run` 的 blob
  在国内 reset)、NGC `nvcr.io`(间歇性 reset)、经 Tailscale 从 Mac 中转
  (DERP 中继约 0.15 MB/s)。**节点间拷贝走 200G 链路**(`192.168.200.x`),
  先 `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts`。
- 完整 runbook:`docs/china-network-mirrors-cn.md`。
