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

## 重建 kubeconfig(换机器 / 文件丢了)

`~/.kube/dgx-spark.yaml` 不在仓库里(含客户端证书私钥),丢了就重新从 server 节点取。
2026-08-16 实际重建过一次 —— 当时 `make v4flash-*` 全部报
`stat ~/.kube/dgx-spark.yaml: no such file or directory`:

```bash
umask 077
ssh -i ~/.ssh/vgio admin@100.67.164.92 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed -e 's|https://127.0.0.1:6443|https://100.67.164.92:6443|' \
        -e 's|\bdefault\b|dgx-spark|g' > ~/.kube/dgx-spark.yaml
chmod 600 ~/.kube/dgx-spark.yaml
kubectl --kubeconfig ~/.kube/dgx-spark.yaml get nodes   # 验证
```

- 必须走 **Tailscale IP `100.67.164.92`**:k3s.yaml 里默认是 `127.0.0.1`,而节点的
  `INTERNAL-IP` 是 `192.168.200.102`(内部 200G CX7 链路),Mac 上都不通。
- 证书 SAN 已包含 `100.67.164.92`,不需要 `insecure-skip-tls-verify`。
- 只有 **server 节点(S2)** 有 `/etc/rancher/k3s/k3s.yaml`;S1 是 agent,没有这个文件。

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

   探针判据是**「有活但*持续*零进展」**(`v4flash/configmap-launch.yaml` 里的
   `liveness.py`):读不排队的 `/metrics`,只有 `running+waiting > 0` **且**
   `vllm:iteration_tokens_total_count` **连续停滞超过 `STALL_S`(默认 600s)**
   才判失败;指标缺失、引擎空闲、有 nvcc/ptxas 在编译,一律放行。
   **改探针前先读那段注释**——两代探针一共误杀过三次健康 leader:初版发真实生成
   请求被满载队列拖垮一次(2026-08-13);二版只比较相邻两次探测的 steps,
   2026-08-16 一天内误杀两次(`steps stuck at 76166` 杀掉一个 6 秒前还在出 token
   的 leader,~11 分钟中断;`steps stuck at 0` 命中重启后从未迭代过的冷引擎)。
   教训写在脚本注释里:「有活但这一分钟没推进」是常态(空闲后第一个请求、超长
   prefill、DG_JIT 首次编译新 shape),不等于卡死。

   ```bash
   make probe-test     # 本地跑回归(含上面三次误杀的复现场景),改探针前必跑
   make probe-apply    # 推到线上;ConfigMap 是普通卷挂载 → 不重启 Pod、零中断
   make probe-verify   # 在两个运行中的 Pod 里手工跑一遍线上脚本,rc=0 即健康
   ```

   ⚠️ 只有**脚本**能热更;`leader.yaml`/`worker.yaml` 里的探针**字段**
   (periodSeconds / failureThreshold 等)要重建 Pod 才生效。所以判死时长放在
   脚本的 `STALL_S` 里,调它不用停服务。
2. **`kubectl apply` 会把副本数收敛回 manifest 里的值**(现为 `replicas: 1`)。
   停机期间不要 apply,否则服务会被拉起来。反之亦然:曾因 manifest 里遗留
   `replicas: 0` 导致一次 apply 把生产缩到零。

   ⚠️ 由此推论:**单独 apply `leader.yaml` 或 `worker.yaml` 都很危险** —— 只要动到
   Pod spec(探针字段、env、镜像…)就会只重建那一侧,直接触发第 1 条的僵尸 TP 组。
   改 spec 的正确落地方式是先停再 apply:

   ```bash
   make v4flash-stop && kubectl apply -f k8s/v4flash/   # apply 把 replicas 收敛回 1
   ```

   2026-08-16 用这条落地了 worker 探针改动,两侧同时加载,4m20s 恢复。

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
