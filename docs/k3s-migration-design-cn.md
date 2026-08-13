# DGX Spark k3s 迁移设计文档

> 状态:**已执行完成**(2026-08-13 01:18 切换,生产已跑在 k3s 上)。
> 实际执行与本文的偏差、以及演练推翻的一个关键假设,见 §4.7 和 §11。
> 范围:把生产 DeepSeek-V4-Flash-0731 双节点 TP=2 栈从 systemd + eugr harness
> 迁入单个双节点 k3s 集群(Cilium CNI),并为后续与 homelab 集群的
> Cilium ClusterMesh 对接预留全部条件。
> 相关:现状 runbook `deepseek-v4-flash-cn.md`;基线 `benchmarks/bench-full-2026-08-05/`。

## 1. 目标与非目标

**目标**
1. V4-Flash 生产服务迁入 k3s,客户端零感知(仍是 `100.97.87.120:8000`、
   模型名 `deepseek-v4-flash`,vLLM 参数一字不改)。
2. Cilium 做 CNI(kube-proxy-less),安装即 ClusterMesh-ready。
3. 后续 homelab 集群可通过 ClusterMesh 与本集群对接(全局服务互访)。
4. 保留一键回滚到 systemd 路径的能力,直到新栈稳定观察期结束。

**非目标**
- 不在两台 Spark 之间做 ClusterMesh(它们是**一个**集群的两个节点;
  ClusterMesh 连接的是集群与集群)。
- 不改推理引擎/镜像/vLLM 参数(那是独立的变更,不与平台迁移混做)。
- 不追求多副本/HPA(TP=2 是一个进程组,天然单副本)。

## 2. 参考资料评估

| 资料 | 结论 |
|---|---|
| [collabnix: Building AI Agents on DGX Spark with Kubernetes](https://collabnix.com/building-ai-agents-on-dgx-spark-with-kubernetes-a-complete-tutorial/) | **可参考,不可作设计依据。** 有效信息:GB10 上 NVIDIA device plugin **必须 ≥ v0.17.4**(旧版在统一内存上崩:`error getting device memory: Not Supported`,NVIDIA/gpu-operator#1794);k3s 基本安装与 `nvidia.com/gpu` 资源请求方式与我们一致。未覆盖:多节点 TP、RDMA/NCCL、hostNetwork、CNI 选型(默认 Flannel)、国内网络、本地构建镜像(它假设镜像可直接拉取)。 |
| [Cilium ClusterMesh 官方文档](https://docs.cilium.io/en/stable/network/clustermesh/) | 对接 homelab 的依据(前提条件见 §6)。 |
| LeaderWorkerSet (LWS) | 可选的后续增强(组重启语义),初版不引入,见 §5.5。 |

## 3. 现状(2026-08-12 从生产环境抓取的 ground truth)

- 每节点一个容器 `vllm_node`(镜像 `vllm-node-dsv4:latest`,仅存在于两台机器的
  docker 本地),运行参数:`--privileged --ipc=host --network host --gpus all`,
  挂载 `~/.cache/{huggingface,vllm,flashinfer}`、`~/.triton` → 容器内 `/root/...`。
- 两个 rank 执行**同一条** `vllm serve` 命令(recipe 渲染产物
  `/workspace/exec-script.sh`),差异仅在尾部:
  - rank0(S1):`--nnodes 2 --node-rank 0 --master-addr 192.168.200.101 --master-port 29501`
  - rank1(S2):同上 + `--node-rank 1 --headless`
- rendezvous 由 torch 在 29501 完成;eugr harness 的 SSH 只负责复制脚本,
  **没有需要移植的编排逻辑**。
- 关键 env(每节点):`VLLM_HOST_IP=<本节点 200G IP>`、
  `NCCL/GLOO/TP_SOCKET_IFNAME=enp1s0f0np0`、`NCCL_IB_HCA=rocep1s0f0,roceP2p1s0f0`、
  `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`(完全离线,不依赖代理)。
- NCCL 流量走 RoCE 内核旁路,**不经过任何 CNI**;API 流量走 hostNetwork。
  → CNI 数据面上只有系统组件和未来的轻量负载,这是本设计里多个取舍的依据。

## 4. 目标架构

```
                 Tailscale(管理平面 + 未来跨集群平面)
   Mac(kubectl/helm) ──────────────┐
                                   │
┌──────────────────────────────────▼───────────────────────────┐
│ k3s cluster "dgx-spark"  (cluster.id=1)                       │
│ 集群内部流量走 200G 链路 192.168.200.0/24                       │
│                                                               │
│  S2 192.168.200.102             S1 192.168.200.101            │
│  k3s server(sqlite)             k3s agent                     │
│  cilium + device-plugin         cilium + device-plugin        │
│  ┌───────────────────┐          ┌────────────────────┐        │
│  │ v4flash-worker    │◄─RoCE───►│ v4flash-leader     │        │
│  │ rank1 --headless  │  NCCL    │ rank0  :8000 API   │        │
│  │ hostNet/priv/GPU×1│ (旁路CNI)│ hostNet/priv/GPU×1 │        │
│  └───────────────────┘          └────────────────────┘        │
└───────────────────────────────────────────────────────────────┘
        客户端不变:100.97.87.120:8000 / deepseek-v4-flash
未来:homelab cluster (cluster.id=2, Cilium) ⇄ ClusterMesh over Tailscale
```

### 4.1 拓扑与角色

- **k3s server 放 S2,agent 放 S1**。head(S1)曾在 gpu-util 0.85 时整机 OOM,
  让它背 agent(~0.4GB)而不是 server(~1.2GB)。单 server + 内嵌 sqlite 足够
  (控制面挂掉只影响调度,不影响已运行 Pod)。
- **节点 IP 用 200G 链路**(`--node-ip 192.168.200.x`):控制面与 CNI 流量走
  背靠背直连,不依赖 Tailscale(DERP 抖动不会引发 NotReady 抖动)。
- kubectl/helm/cilium CLI 一律从 **Mac 上执行**(经 Tailscale 访问
  `https://100.67.164.92:6443`;S2 证书加 tls-san)。同时规避了国内拉
  helm chart(GitHub Pages)的问题——chart 在 Mac 下好后 `helm install ./chart.tgz`。

### 4.2 CIDR 规划(为 ClusterMesh 预留,**装完不可改**)

| | dgx-spark(本集群) | homelab(假设 k3s 默认) |
|---|---|---|
| cluster.id / name | 1 / `dgx-spark` | 2 / `homelab` |
| Pod CIDR | **10.44.0.0/16** | 10.42.0.0/16 |
| Service CIDR | **10.45.0.0/16** | 10.43.0.0/16 |

刻意避开 k3s 默认值,保证与 homelab **不重叠**(ClusterMesh 硬性前提)。
homelab 实际 CIDR 在 Phase 1 前确认(见 §9 待决问题)。

### 4.3 k3s 安装参数

S2(server):

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | \
  INSTALL_K3S_MIRROR=cn sh -s - server \
  --node-ip 192.168.200.102 \
  --cluster-cidr 10.44.0.0/16 --service-cidr 10.45.0.0/16 \
  --flannel-backend=none --disable-network-policy --disable-kube-proxy \
  --disable traefik --disable servicelb \
  --tls-san 100.67.164.92 \
  --kubelet-arg=image-gc-high-threshold=98 --kubelet-arg=image-gc-low-threshold=96
```

S1(agent):

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | \
  INSTALL_K3S_MIRROR=cn K3S_URL=https://192.168.200.102:6443 K3S_TOKEN=<token> \
  sh -s - agent --node-ip 192.168.200.101 \
  --kubelet-arg=image-gc-high-threshold=98 --kubelet-arg=image-gc-low-threshold=96
```

两节点先放 `/etc/rancher/k3s/registries.yaml`(daocloud 重写,解决 quay/nvcr/
registry.k8s.io 均不可直连的问题):

```yaml
mirrors:
  docker.io:        {endpoint: ["https://docker.m.daocloud.io"]}
  quay.io:          {endpoint: ["https://quay.m.daocloud.io"]}
  nvcr.io:          {endpoint: ["https://nvcr.m.daocloud.io"]}
  registry.k8s.io:  {endpoint: ["https://k8s.m.daocloud.io"]}
  ghcr.io:          {endpoint: ["https://ghcr.m.daocloud.io"]}
```

注:`image-gc-*-threshold` 调高是为了保护本地导入、无处可重拉的
`vllm-node-dsv4` 镜像(另有 pin,见 §4.6)。

### 4.4 Cilium(helm values 核心)

```yaml
cluster: {name: dgx-spark, id: 1}        # ClusterMesh-ready,装完不可改
kubeProxyReplacement: true               # kube-proxy-less(k3s 已 --disable-kube-proxy)
k8sServiceHost: 192.168.200.102
k8sServicePort: 6443
routingMode: tunnel                      # vxlan;见下方取舍说明
ipam: {mode: kubernetes}                 # 沿用 k3s 分配的 node PodCIDR
mtu: 1200                                # 预留 Tailscale(1280)+vxlan 开销,跨集群不炸 PMTU
hubble:
  relay: {enabled: true}
  ui: {enabled: true}                    # 学习/排障用,只在集群内暴露
operator: {replicas: 1}
```

**routingMode: tunnel 的取舍**:两节点背靠背本可用 native routing +
autoDirectNodeRoutes 省掉封装开销,但 (a) CNI 平面上没有重流量(§3),vxlan
开销无感;(b) 跨集群走 tunnel 时只要求**节点 IP 互通**,不必把 Pod CIDR 注入
Tailscale 路由表,homelab 对接的前提大幅简化;(c) 两侧路由模式一致,少一类
排障变量。**MTU 1200** 同理:统一按最窄路径(Tailscale 1280)预留,避免跨集群
PMTU 黑洞;仅影响 CNI 流量,vLLM 的 hostNetwork/RoCE 不受影响。

### 4.5 GPU 栈

1. **RuntimeClass**:两节点已装 nvidia-container-toolkit(docker 在用),
   k3s 启动时会自动探测并写入 containerd 配置;若未自动创建 RuntimeClass
   对象则手动 apply(`handler: nvidia`)。
2. **NVIDIA device plugin ≥ v0.17.4**(GB10 统一内存硬性要求,collabnix
   教程验证的坑,NVIDIA/gpu-operator#1794)。manifest vendor 进本仓库
   `k8s/gpu/`(GitHub raw 不可直连),镜像 `nvcr.io/nvidia/k8s-device-plugin:v0.17.4`
   经 registries.yaml 自动走 daocloud;DaemonSet 需加 `runtimeClassName: nvidia`。
3. **不用 GPU Operator**:驱动/toolkit 均已在宿主机就位且被生产验证,
   Operator 的驱动管理在 DGX OS 上是风险不是便利。
4. GB10 已知边界(设计上不依赖这些能力):无 MIG;`nvidia.com/gpu` 在统一内存
   上**不提供内存隔离**,只做调度记账;nvidia-smi 无 per-process 显存;
   dcgm-exporter 在 GB10 的指标覆盖未验证(Phase 7 实验项)。

### 4.6 镜像分发

`vllm-node-dsv4:latest` 只存在于两台机器的 docker 存储中(jasl fork 本地构建
+ `docker commit`,无 registry 副本)。

- 两节点各自执行 `docker save vllm-node-dsv4:latest | k3s ctr images import -`
  (镜像大,挑空闲时段;操作在各自节点本地完成,不走网络)。
- Pod 侧 `imagePullPolicy: Never`。
- 防 kubelet 镜像 GC:`k3s ctr -n k8s.io images label docker.io/library/vllm-node-dsv4:latest io.cri-containerd.pinned=pinned`
  + §4.3 的 GC 阈值。
- **rebuild 流程从此多一步**:`docker build` →(`scripts/vllm-fix-torch.sh` 如需)
  → `docker save | k3s ctr images import`(两节点)→ `kubectl rollout restart`。
  构建纪律不变:**S1 上 build 前必须先停生产栈**(含 k3s 里的 vLLM Pod)。

### 4.7 vLLM 工作负载

`k8s/v4flash/`:1 个 Namespace + 1 个 ConfigMap(rank0.sh / rank1.sh,内容
即现网 `/workspace/exec-script.sh` 原文)+ 2 个单副本 Deployment
(`strategy: Recreate`)。leader 骨架(worker 同构,差异见后):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: v4flash-leader, namespace: v4flash}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: v4flash-leader}}
  template:
    metadata: {labels: {app: v4flash-leader}}
    spec:
      nodeSelector: {kubernetes.io/hostname: <S1-hostname>}   # Phase 1 后回填
      hostNetwork: true
      hostIPC: true                                # ⇔ --ipc=host
      runtimeClassName: nvidia
      terminationGracePeriodSeconds: 60
      containers:
      - name: vllm
        image: docker.io/library/vllm-node-dsv4:latest
        imagePullPolicy: Never
        command: ["/bin/bash", "/scripts/rank0.sh"]
        securityContext: {privileged: true}        # ⇔ --privileged(RoCE 设备访问)
        resources: {limits: {nvidia.com/gpu: 1}}   # 调度记账:占住本节点唯一 GPU
        env:
        - {name: VLLM_HOST_IP,       value: "192.168.200.101"}
        - {name: NCCL_SOCKET_IFNAME, value: "enp1s0f0np0"}
        - {name: GLOO_SOCKET_IFNAME, value: "enp1s0f0np0"}
        - {name: TP_SOCKET_IFNAME,   value: "enp1s0f0np0"}
        - {name: UCX_NET_DEVICES,    value: "enp1s0f0np0"}
        - {name: NCCL_IB_HCA,        value: "rocep1s0f0,roceP2p1s0f0"}
        - {name: NCCL_IB_DISABLE,    value: "0"}
        - {name: HF_HUB_OFFLINE,     value: "1"}
        - {name: TRANSFORMERS_OFFLINE, value: "1"}
        - {name: NCCL_IGNORE_CPU_AFFINITY, value: "1"}
        volumeMounts:
        - {name: hf-cache,        mountPath: /root/.cache/huggingface}
        - {name: vllm-cache,      mountPath: /root/.cache/vllm}
        - {name: flashinfer-cache, mountPath: /root/.cache/flashinfer}
        - {name: triton-cache,    mountPath: /root/.triton}
        - {name: scripts,         mountPath: /scripts}
        startupProbe:                              # 167GB 权重加载,给足 30min
          httpGet: {path: /health, port: 8000}
          periodSeconds: 15
          failureThreshold: 120
        readinessProbe:
          httpGet: {path: /health, port: 8000}
          periodSeconds: 10
      volumes:
      - {name: hf-cache,         hostPath: {path: /home/admin/.cache/huggingface}}
      - {name: vllm-cache,       hostPath: {path: /home/admin/.cache/vllm}}
      - {name: flashinfer-cache, hostPath: {path: /home/admin/.cache/flashinfer}}
      - {name: triton-cache,     hostPath: {path: /home/admin/.triton}}
      - {name: scripts, configMap: {name: v4flash-launch, defaultMode: 0755}}
```

worker 与 leader 的差异:钉 S2、跑 `rank1.sh`(`--node-rank 1 --headless`)、
`VLLM_HOST_IP=192.168.200.102`、**无 HTTP 探针**(headless 不开 API;vLLM 是
容器 PID 1,进程退出即容器重启,这就是它的健康语义)。

另建一个 ClusterIP Service `deepseek-v4-flash`(selector 指向 leader,端口
8000)。客户端仍直连 `100.97.87.120:8000`(hostNetwork),这个 Service 是给
**集群内消费者和未来 ClusterMesh 全局服务**用的入口(§6.3)。

**崩溃/重启语义(2026-08-13 演练推翻了原假设,已修正)**

原假设是"任一 rank 挂 → NCCL watchdog 把另一侧带崩 → 两侧各自重启"。**实测不成立**:
删掉 worker Pod 后,leader **无限卡在集合通信里且不退出**——Pod 仍 `1/1 Running`、
`restartCount=0`,`/health` 与 `/v1/models` 照常 200,而任何真实生成请求永久超时。
k8s 完全看不见这个僵尸状态。

这不是演练特有的边角情况:**任何单 rank 事件**(进程 OOM、CUDA 错误、单节点重启、
kubectl delete pod)都会走到同一状态。老 systemd 方案没有这个问题,因为整个编排是
一个单元,重启时 `teardown()` 会把两个节点的容器一起拆掉重来。

修正后的机制 = **进度探针 + 共同命运**(无需引入 LWS/新镜像):

- **leader `livenessProbe` 判「有活但零进展」**(`k8s/v4flash/configmap-launch.yaml`
  里的 `liveness.py`):读 `/metrics`,
  `demand = num_requests_running + num_requests_waiting`,
  `steps = vllm:iteration_tokens_total_count`(每个 engine iteration +1,分块
  prefill 保证超长提示也持续推进);**demand=0 或 steps 有推进 → 健康;
  只有「demand>0 且 steps 冻结」才判失败**。`3×60s`。
- **worker `livenessProbe` 盯 leader 的 `/health`**(worker 是 `--headless`,没有自己的
  端点可探)。leader 一旦重启/消失,worker 也自杀,两侧一起重来。
  `initialDelaySeconds: 900` 覆盖 leader 的 167GB 加载窗口,否则启动期就自杀。

> **⚠️ 第一版探针误杀事故(2026-08-13 19:32,已修)**
> 初版 leader 探针发一个 `max_tokens:1` 的**真实生成请求**。当天引擎被真实流量打满
> (`Running: 6 / Waiting: 2`,吞吐 78–106 tok/s,一切正常),探针请求排在队尾,连续
> 5 次超过 30s 超时 → kubelet `SIGKILL`(exitCode 137)掉一个**完全健康**的 leader,
> worker 5 分钟后按共同命运跟着重启 = **~10 分钟无谓中断**。
> **教训:任何会进入请求队列的探针都无法区分「卡死」和「忙」**,阈值调多宽都不行——
> 满载时排队时间没有上界。健康信号必须来自**不排队的旁路**(`/metrics` 由 API server
> 直接应答)且判据是**进度**而非**响应**。
>
> **第二版的 fail-open 修正(同日)**:进度探针的初版把「指标不存在」当成 0,而
> vLLM 的直方图 `iteration_tokens_total_count` 在第一次 engine iteration 完成前
> 根本不出现 → 「刚就绪 + 首个请求在飞行中」被判成卡死(实际触发过一次,连续 3 次
> 就会杀掉健康 leader)。现在指标缺失直接放行。
> **通用原则:探针只在有正面证据时判死,缺数据一律 fail-open**——探针误杀的代价
> (这里是 ~10 分钟重载)通常远高于晚几分钟发现真故障。

三种故障的收敛路径:

| 故障 | 收敛 |
|---|---|
| worker 死 | 新 worker 起来等 rendezvous;leader 僵死 → 真实探针失败 → leader 重启 → 两侧握手 |
| leader 死/重启 | leader `/health` 消失 → worker 探针失败 → worker 重启 → 两侧一起重来 |
| 坏配置(如 `max_num_seqs=16` 过不了 KV preflight) | 持续 CrashLoopBackOff,比 systemd 无限重启更可观测,处置仍是改回配置 |

注意收敛需要一轮"等对方也重启"的时间(最坏 ~5 分钟探针阈值 + ~5 分钟加载)。
若这个恢复时长在实践中不可接受,再上 LeaderWorkerSet 的
`RecreateGroupOnPodRestart` 做真正的成组重启(代价:引入 LWS controller 镜像)。

**教训(适用于任何多节点推理上 k8s)**:`/health`、`/v1/models` 这类静态端点不能
作为分布式推理的健康信号——它们只证明 API server 进程活着,不证明 TP 组还能算。

**开机自启**:k3s systemd 服务开机拉起 → 节点 Ready、device plugin 注册 GPU
之前 Pod 保持 Pending → 就绪即启动。`v4flash-boot.sh` 的等待逻辑由调度器天然
替代,双节点同时断电重启无竞态。

### 4.5b 后续增强(非初版):LeaderWorkerSet

若 CrashLoop 对齐在实践中造成可感的恢复延迟,引入 LWS(`RecreateGroupOnPodRestart`
组重启)。两节点静态场景收益有限,列为观察触发项而不是初版依赖。

## 5. 迁移执行(2026-08-12 → 08-13,已完成)

分 7 阶段,前 4 阶段(装 k3s → 装 Cilium → GPU 栈 → 镜像导入 + manifests 预置
`replicas: 0`)**完全不动生产**,只在第 5 阶段进切换窗口。实际耗时与偏差见 §11。
后续可选项:dcgm-exporter 实验、Hubble 观测、LWS 评估、§6 的 homelab 对接。

**回滚**(仍然可用,两条命令):
`make v4flash-stop` → `ssh <head> sudo systemctl enable --now deepseek-v4-flash`。
观察期结束前不删 systemd unit、不删 eugr harness。

## 6. ClusterMesh 对接设计(homelab ⇄ dgx-spark)

### 6.1 homelab 侧前提(不满足则对接不成立)

1. CNI 必须是 **Cilium**(两侧版本同一 minor 为佳),`cluster.id=2`、
   `cluster.name=homelab`,同样建议 `routingMode: tunnel` + `mtu: 1200`。
2. Pod/Service CIDR 与本集群(10.44/10.45)**不重叠**(§4.2)。
3. 若 homelab 现在不是 Cilium:对接前需先完成 homelab 的 CNI 迁移,
   那是 homelab 仓库的独立变更,本文档只锁定接口(id/name/CIDR/MTU)。

### 6.2 跨集群连通性:Tailscale subnet router

ClusterMesh(tunnel 模式)要求两侧**节点 IP 互通** + 双方 clustermesh-apiserver
可达。两侧节点 IP 都在各自内网,方案:

- DGX 侧:任一节点(建议 S2)`tailscale up --advertise-routes=192.168.200.0/24`;
- homelab 侧:其 subnet router 通告 homelab 节点网段;
- 双方节点开启路由接受,tailnet ACL 放行两网段互访;
- `cilium clustermesh enable --service-type NodePort`(NodePort 落在节点 IP 上,
  经 subnet route 可达),然后在 Mac 上用双方 kubeconfig 执行
  `cilium clustermesh connect`(自动完成 CA/证书交换);
- 验收:`cilium connectivity test --multi-cluster`(重点看大包用例,验证
  MTU 1200 的余量足够)。

### 6.3 对接后的用例

- **homelab 侧消费 GB10 推理**:把 §4.7 的 `deepseek-v4-flash` Service 标注
  `service.cilium.io/global: "true"`,homelab 侧建同名 namespace/Service,
  homelab 的 Pod 即可用集群内 DNS 名调用 V4-Flash——AI agent 等轻负载跑在
  homelab,重推理留在 GB10。
- **观测融合**:homelab Prometheus 可改为经 mesh 抓集群内 exporter;
  现有 Tailscale 抓取路径(node_exporter/smartctl)**迁移期间保持不动**,
  mesh 稳定后再评估切换,避免一次动两条链路。

## 7. 验证清单(任何重大变更后复用)

先热身(冷启动/闲置衰减 ~30%,先跑几条 500+ token 生成),再依次:

1. **必须用真实生成请求判活,不能用 `/v1/models` 或 `/health`**(它们在 TP 组
   挂死时照常 200,见 §4.7 的僵尸状态);
2. `make v4flash-test` 通过;
3. `/metrics` 两次快照差分算接受率——**注意指标名要精确匹配 `..._total{`**,
   用前缀匹配会把 `..._created`(unix 时间戳)也算进去,得出荒谬的数;
4. 解码速度**按内容分档比**,别拿不同内容的数对比:
   count-to-N ≈ 84 / 混合 ≈ 60 / 散文 ≈ 32 tok/s;
5. 并发比**放大比**而不是绝对值(基线 c1→c6 为 2.78x);
6. 重启演练:`make v4flash-restart` → 服务恢复(**单 rank 演练见 §4.7,
   会造成僵尸组**)。

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 控制面 ~1.6GB 常驻内存挤占统一内存(head 有 0.85 OOM 前科) | server 放 S2;Phase 1 后 `free -h` 实测把关;swap 保持关闭(与 kubelet 要求一致) |
| kubelet 镜像 GC 清掉无处重拉的本地镜像 | pinned label + GC 阈值 98/96 + `imagePullPolicy: Never` |
| 双 rank 重启节奏不齐 → CrashLoop 数轮 | backoff 会收敛;若成为实际痛点上 LWS(§4.5b) |
| Pod 重建成本高(167GB 加载 + JIT + 热身) | 纪律:`rollout restart` 不当便宜操作;探针阈值给足 30min |
| helm chart / GitHub raw 不可直连 | helm/cilium CLI 全部在 Mac 执行;device plugin manifest vendor 进仓库 |
| device plugin 旧版在 GB10 崩溃 | 钉 ≥ v0.17.4(§4.5) |
| Tailscale 故障影响面 | 集群内部(node-ip、NCCL、API)零依赖 Tailscale;只影响 Mac 管理入口与未来 mesh |
| k3s 版本升级引入变量 | 升级视同维护窗口操作,先停 vLLM Pod;不开启自动升级 |

## 9. 待决问题(ClusterMesh 对接前确认)

迁移期的问题已全部解决(hostname `spark-ccf3`/`spark-2435`、Cilium 1.19.6,
均已落到 `k8s/`)。剩下的都属于 §6 的 homelab 对接:

1. **homelab 集群现状**:发行版、CNI(是否已是 Cilium 及版本)、Pod/Service
   CIDR——决定 §6.1 是否需要 homelab 侧先行改造。
2. tailnet ACL 是否允许 homelab ⇄ DGX 子网互访(现有 `tag:homelab → *:*`
   只覆盖单向)。

## 10. 交付物

均已落库,见 `k8s/README.md`(版本记录 + 操作速查)。目录结构:
`k8s/{registries,cilium-values}.yaml`、`k8s/gpu/{runtimeclass,nvidia-device-plugin}.yaml`、
`k8s/v4flash/{namespace,configmap-launch,leader,worker,service}.yaml`;
`Makefile` 的 `v4flash-*` 已改指 kubectl。ClusterMesh 的执行手册待对接时再写。

---

## 11. 执行记录(2026-08-12 夜 → 08-13 01:18)

### 实际结果

| 项 | 结果 |
|---|---|
| k3s | v1.36.3+k3s1;server=S2 `spark-2435`,agent=S1 `spark-ccf3`,node-ip 走 200G |
| Cilium | 1.19.6,kube-proxy-less,tunnel/vxlan,MTU 1200,`cluster.id=1` — `ClusterMesh: 0/0 remote clusters ready`(等对端) |
| GPU | 两节点各 `nvidia.com/gpu: 1`;device plugin v0.17.4 日志确认 GB10 名场面被正确容忍:`Ignoring error getting device memory: Not Supported` |
| 切换 | 01:09 停 systemd → 01:18 k3s 上真实推理通过 |
| 内存 | 每节点 104Gi used / **16–17Gi 可用**(docker 时代是 14Gi,反而更宽松);swap=0 |
| 性能 | 与基线一致,见下表 |

切换后实测(热身后,`stream:false`,temp 0,thinking off):

| 内容类 | 解码 | 接受率 / tok每步 | 基线对照 |
|---|---|---|---|
| count-to-300 | 83.8–86.4 tok/s | 99.8% / 5.99 | 峰值 84.3 ✅ |
| 混合 | 55–61 tok/s | 62.4% / 4.12 | 均值 67 区间内 ✅ |
| 散文 | 32–34 tok/s | 23.4% / 2.17 | 低端 31 ✅ |

并发(count-to-200):c1 86.4 / c4 234 / c6 302 tok/s 聚合,6 路全部内容完整无乱码。
散文同内容对照 c1 31.9 → c6 84.8,**放大比 2.66x vs 基线 2.78x**(基线的
143/186 是在不同内容上测的,不能直接比数值,只能比放大比)。

三类内容的接受率把基线均值 75.8% 夹在中间,与"接受率由内容决定"一致,无回归。

### 与设计的偏差

1. **§4.4 的 `routingMode` 实际用了 tunnel**(设计已写明),但 `autoDirectNodeRoutes`
   未启用——与设计一致,记录在此以免日后误以为漏配。
2. **§4.7 的崩溃语义假设被演练推翻**,已改为真实探针 + 共同命运(见 §4.7)。
3. manifests 的 `replicas` 从预置的 0 改为稳态 1(否则 `kubectl apply` 会把生产
   缩到零——迁移当晚真实踩到)。

### 国内网络实况(执行当晚)

- **daocloud 的 blob 后端 `image-mirror.r2.daocloud.vip` TLS 证书 2026-08-02 过期**,
  导致 quay/nvcr 镜像要么极慢(cilium-envoy 70MB 拉了 13 分钟),要么直接
  `ImagePullBackOff`(device plugin 在 S1)。
- 绕过方式:**Mac 直连拉取 → `docker save` → scp → `k3s ctr -n k8s.io images import`**。
  214MB 经 Tailscale DERP 约 14 分钟。与 vLLM 镜像的分发路径相同(§4.6)。
- 结论:daocloud 不可作为唯一依赖。新增镜像时优先考虑 Mac 中转导入。

### 遗留 / 下一步

- **未演练整机重启**(会打断服务,留到下次计划窗口)。理论上 k3s 的 systemd
  服务 + Pod `replicas: 1` 已覆盖,但**未经证实**。
- coredns/hubble 起来后未复测集群 DNS(vLLM 走 hostNetwork 不依赖它)。
- ClusterMesh 对接待 homelab 侧就绪(§6),本集群侧已 ready。
- 观察期结束前保留 S1 上已 disable 的 `deepseek-v4-flash.service` 与 eugr harness。
