# dgx-spark k3s 集群 — manifests 与版本记录

设计文档:`docs/k3s-migration-design-cn.md`。搭建日期 2026-08-12。

## 版本

| 组件 | 版本 | 备注 |
|---|---|---|
| k3s | v1.36.3+k3s1 | `INSTALL_K3S_MIRROR=cn`;server=S2(spark-2435),agent=S1(spark-ccf3) |
| Cilium | 1.19.6 (helm chart = app) | tunnel/vxlan,MTU 1200,kube-proxy-less,cluster.id=1 `dgx-spark` |
| NVIDIA device plugin | v0.17.4 | GB10 统一内存要求 ≥0.17.4(gpu-operator#1794) |
| vllm-node-dsv4 | :latest (4d024a16e7a5) | 本地镜像,docker→containerd 导入,pinned |

## 布局

```
registries.yaml          → 两节点 /etc/rancher/k3s/registries.yaml(daocloud 重写)
cilium-values.yaml       → helm install/upgrade -f 用
gpu/runtimeclass.yaml    → RuntimeClass nvidia
gpu/nvidia-device-plugin.yaml → vendored v0.17.4 + runtimeClassName
v4flash/                 → namespace / configmap-launch / leader / worker / service
```

## 常用操作(Mac,`export KUBECONFIG=~/.kube/dgx-spark.yaml`)

优先用 `make v4flash-*`(已切到 kubectl 路径);等价的裸命令:

```bash
kubectl get nodes -o wide                     # 集群状态
kubectl -n v4flash get pods -o wide           # v4flash 状态
kubectl -n v4flash logs -f deploy/v4flash-leader   # 相当于旧 v4flash-logs
kubectl -n v4flash scale deploy --all --replicas=1 # 启动
kubectl -n v4flash scale deploy --all --replicas=0 # 停止
kubectl -n v4flash delete pod --all                # 重启(必须两侧一起)
```

⚠️ **两个必须知道的坑**

1. **绝不单独重启一个 rank。** 单 rank 重建会让另一侧永久卡在集合通信里,
   Pod 仍 `1/1 Running`、`/health` 照常 200,但真实生成永久超时(2026-08-13
   演练实测)。已有探针兜底,但恢复要 ~10 分钟。一律成对操作:`make v4flash-restart`。

   探针判据是**「有活但零进展」**(`v4flash/configmap-launch.yaml` 里的
   `liveness.py`):读不排队的 `/metrics`,只有 `running+waiting > 0` **且**
   `vllm:iteration_tokens_total_count` 相比上次没推进才判失败;指标缺失一律放行。
   **改探针前先读那段注释**——初版发真实生成请求,被满载流量排队拖垮,误杀过一次
   健康 leader(~10 分钟中断)。
2. **`kubectl apply` 会把副本数收敛回 manifest 里的值**(现为 `replicas: 1`)。
   停机期间不要 apply,否则服务会被拉起来。反之亦然:曾因 manifest 里遗留
   `replicas: 0` 导致一次 apply 把生产缩到零。

日志里 `NCCL WARN ... GID table changed` 是**既有噪声**,与 k3s 无关
(老 systemd 日志里出现过 19 万次,最早可追到 2026-06-05),忽略即可。

## 回滚到 systemd 路径(观察期内保留)

```bash
kubectl -n v4flash scale deploy --all --replicas=0
ssh admin@100.97.87.120 'sudo systemctl enable --now deepseek-v4-flash'
```

## 镜像 rebuild 之后

```bash
# 在两节点各自执行(docker 侧构建产物导入 containerd 并 pin):
docker save vllm-node-dsv4:latest | sudo k3s ctr -n k8s.io images import -
sudo k3s ctr -n k8s.io images tag vllm-node-dsv4:latest docker.io/library/vllm-node-dsv4:latest
sudo k3s ctr -n k8s.io images label docker.io/library/vllm-node-dsv4:latest io.cri-containerd.pinned=pinned
# 然后:
kubectl -n v4flash rollout restart deploy   # 注意:重启付 167GB 加载 + JIT + 热身
```

## ClusterMesh —— ❌ 不做(2026-08-13 否决)

☠️ **下面这三条命令不要跑。** 与 homelab 对接经实测否决,原"本集群侧已就绪"的说法
**不成立**:

- 本集群 `cluster.id=1` **与 homelab 相同**(homelab 也是 1,oracle-k3s 是 2)——撞 id
  是身份空间重叠,不是性能问题;
- `MTU 1200` **从未生效**:chart 的键是 `MTU`(全大写),`k8s/cilium-values.yaml` 里
  写的是小写 `mtu`,helm 静默忽略未知键,实际设备停在自动探测的 1280。
  **别去"修正"大小写**——homelab 2026-07-07 因显式 MTU=1200 踩过静默黑洞;
- 最关键的:**"节点 IP 经 Tailscale subnet route 互通"做不到**。两台 Spark 是
  **外部 tailnet 的共享节点**,节点共享不携带 subnet route,而 `192.168.200.101/102`
  正是 VXLAN 要发往的地址 → 跨集群节点平面无法存在。

实测数据、替代方案(homelab 侧 Service + 手写 Endpoints)与重评条件:
设计文档 [§6](../docs/k3s-migration-design-cn.md) 与 homelab 仓库
`docs/decisions/dgx-clustermesh-not-adopted.md`。

<details>
<summary>原始步骤(已作废,仅存档)</summary>

```bash
# ❌ 不要执行:前提不成立,cilium clustermesh enable 会在本集群装出一个
#    永远等不到对端的 clustermesh-apiserver
cilium clustermesh enable --service-type NodePort
cilium clustermesh connect --destination-context <homelab-context>
cilium connectivity test --multi-cluster <homelab-context>
```

</details>
