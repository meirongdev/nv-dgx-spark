# DGX Spark TP2 修复与跨机 120B+ 服务方案

## Context

两台 DGX Spark GB10 服务器（`100.97.87.120` + `100.67.164.92`，每台 128GB 统一内存、1× Blackwell GB10、ConnectX-7 200Gbps NIC），当前部署 vLLM TP=2 跨节点服务。已知问题：

1. **TP=2 长输出崩溃** — `benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md` 显示 160-token 测例在 ~300s 后 HTTP 500（"EngineCore encountered an issue during generation"），同时 coordinator CPU 96% / worker CPU 0%，负载严重失衡。
2. **TP 架构不适合现有链路** — `config/vllm.env:23` 设置 `NCCL_IB_DISABLE=1`，NCCL 走普通 TCP socket。TP 每层 all-reduce 在 Ethernet TCP 上延迟累加，35B 级别模型就已触发超时；`QWEN.md:124` 已承认"Cross-node TP=2 has hang risks (community-tested)"。
3. **目标**：支持 Qwen3.5-122B-A10B（MoE, 122B/10B active）跨两台机器服务，让两机共同承担负载。122B 的 NVFP4 量化虽可单节点（~75GB），但 FP8/BF16 以及更大 KV/context 预算需要跨机分片。

**方案主线**：把"TP 跨节点 over TCP"替换为 2026 年社区实践 — 先开启 RoCEv2 尝试救活 TP=2 作为快速止血，再引入 **Pipeline Parallelism (PP=2)** 作为 120B+ 模型的主路径，并保留 TP=2 路径作为回归基线。

## 关键约束与决策

- **保留 TP=2 路径不删**，与 PP=2 并存作为回归基线
- **目标模型**：Qwen3.5-122B-A10B（用户确认）— 优先跑 FP8 变体触发跨机分片需求；NVFP4 75GB 单节点版本作为 sanity check
- **Executor backend**：由实施 agent 自行判断 — 默认先试 Ray（vLLM 跨节点 PP 官方路径），失败回退 mp；在 playbook 中提供 `TP2_DIST_BACKEND` 环境变量
- 每节点显存预算 `gpu-memory-utilization=0.7` ≈ 89GB。PP=2 下 122B FP8 每 stage ~61GB，留 28GB 给 KV 和 activations
- 所有阶段都追加容器 stderr 捕获并回传到 `benchmarks/`，避免下次失败又缺诊断信息

## Phase 0 — 互联层诊断（只读，数据驱动）

先量清楚链路能力，再决定 RoCE 是否可行。

**新增文件**：`playbooks/diagnostics-interconnect.yml`（只读 shell 任务 fan-out 到两节点，输出汇总到本地 `benchmarks/dgx-spark-interconnect-<date>.md`）。

**诊断命令**：
1. **RDMA 能力**：`ibv_devices`、`ibstat`、`ethtool enp1s0f0np0`（期望 200000Mb/s, mlx5_core 驱动）、`cat /sys/class/infiniband/*/ports/1/gid_attrs/types/*`（找到 `RoCE v2` 的 GID 索引，通常是 3）、`sudo mlxconfig -d <pci> q | grep -i roce`
2. **TCP 基线**：一端 `iperf3 -s`，另一端 `iperf3 -c -t 30 -P 4` 连续 3 次取均值
3. **NCCL 基线**：复用 `vllm/vllm-openai:gemma4-cu130` 镜像内的 nccl-tests（先 `docker run --rm <image> ls /opt/nccl-tests/build` 确认存在；否则用 `nvcr.io/nvidia/pytorch:25.09-py3`）；用 `torchrun` 双节点 rendezvous 跑 `all_reduce_perf -b 8 -e 512M -f 2 -g 1`，**分别在 `NCCL_IB_DISABLE=1` 和 `NCCL_IB_DISABLE=0 NCCL_NET=IB` 两个配置下**记录 bus bandwidth。期望 TCP < 5 GB/s、RoCE 15–22 GB/s

**Gate**：若 RoCE busbw 是 TCP 的 3× 以上，Phase A 执行；若 RoCE 不可用（固件/GID 缺失）则跳 Phase A 直接进 Phase B。

## Phase A — 启用 RoCEv2（快速止血，前提 Phase 0 确认可行）

**修改文件与行号**：

1. `config/vllm.env:21-23` 重写：
   - `NCCL_IB_DISABLE=0`（原 1）
   - 新增 `NCCL_NET=IB`、`NCCL_IB_HCA=mlx5_0`（按 Phase 0 结果）、`NCCL_IB_GID_INDEX=3`、`NCCL_IB_TC=106`、`NCCL_IB_SL=3`、`NCCL_IB_QPS_PER_CONNECTION=4`、`NCCL_IB_TIMEOUT=22`、`NCCL_IB_RETRY_CNT=7`
   - 新增超时/错误处理：`NCCL_ASYNC_ERROR_HANDLING=1`、`TORCH_NCCL_ASYNC_ERROR_HANDLING=1`、`NCCL_TIMEOUT=1800`、`NCCL_DEBUG=WARN`（注释说明 `INFO` 仅调试使用）

2. `scripts/run-vllm-tp2.sh:28-44`（`docker run` 块）为上述每个新 NCCL 变量增加 `-e` 透传；不要依赖 `--env-file`，playbook 未挂载。追加 `-e NCCL_DEBUG=${NCCL_DEBUG:-WARN}` 便于一次性调试覆盖

3. `playbooks/vllm-tp2-deploy.yml:81-100`（Launch TP=2 participant 任务）在 `environment:` 块中透传同样变量

4. `Makefile:16-24` 新增变量 `TP2_NCCL_IB_HCA`、`TP2_NCCL_IB_GID_INDEX`、`TP2_NCCL_DEBUG`；`Makefile:148-163` 对应 `-e` 传参

**验收**：`make vllm-tp2-deploy` → `make vllm-tp2-test` → `make vllm-tp2-benchmark`。容器日志需有 `NCCL INFO NET/IB`（证明走 IB/RoCE 路径）。重跑失败的 `code-snippet` 160-token 测例 **必须通过**；若仍 hang，Phase A 仅作为环境变量改进合入，TP=2 不宣告稳定，交由 Phase B。

## Phase B — Pipeline Parallelism 主路径（120B+ 跨机服务核心）

**新增文件**：

1. **`scripts/run-vllm-pp2.sh`** — 基于 `run-vllm-tp2.sh` 克隆，差异：
   - 默认 `TP2_TP_SIZE=1`、`TP2_PP_SIZE=2`
   - 容器名默认 `vllm-pp2`
   - 新增 `TP2_DIST_BACKEND` 环境变量（默认 `ray`），脚本里换掉 `run-vllm-tp2.sh:48` 硬编码的 `--distributed-executor-backend mp`
   - 新增 `TP2_KV_CACHE_DTYPE`（默认 `auto`，PP 路径先用 fp16 KV 跑稳再换 fp8）
   - `--max-num-seqs ${TP2_MAX_NUM_SEQS:-16}`（降低默认，64 是触发 TP=2 hang 的值）
   - 新增 `--max-num-batched-tokens ${TP2_MAX_BATCHED_TOKENS:-4096}`
   - FlashInfer 相关 `-e`（`run-vllm-tp2.sh:38-40`）保留不动

2. **`playbooks/vllm-pp2-deploy.yml`** — 基于 `vllm-tp2-deploy.yml` 克隆：
   - `vars:` 改 `tp2_container_name: vllm-pp2`、`tp2_launcher_path: /home/admin/run-vllm-pp2.sh`
   - 新增 Ray 引导任务（在 `Launch` 任务之前）：coordinator 执行 `docker run ... ray start --head --port=6379 --node-ip-address={{ tp2_coordinator }}`，worker 执行 `ray start --address={{ tp2_coordinator }}:6379`；均复用 `TP2_IMAGE` + `--network host`
   - 若镜像内存在 `/opt/vllm/examples/run_cluster.sh`（Phase 0 `docker run --rm ${TP2_IMAGE} ls /opt/vllm/examples` 验证），**优先调用它替代手搓 Ray**
   - 环境块（`vllm-tp2-deploy.yml:83-99` 克隆）设 `TP2_TP_SIZE: "1"`、`TP2_PP_SIZE: "2"`、`TP2_CONTAINER_NAME: "vllm-pp2"`、`TP2_DIST_BACKEND: "{{ tp2_dist_backend | default('ray') }}"`
   - `vllm-tp2-deploy.yml:47-61` 的模型缓存 glob 改为接受 `tp2_model_glob` 变量，便于 122B 模型复用

3. **`playbooks/vllm-pp2-validate.yml`** — 克隆 `vllm-tp2-validate.yml`，容器名改 `vllm-pp2`，断言追加 `pipeline_parallel_size=2` 和 `Worker_PP` 启动标记；smoke completion 追加 `max_tokens=256` 的第二条请求（600s 超时）

4. **`playbooks/vllm-pp2-stop.yml`** — 克隆 `vllm-tp2-stop.yml`，容器名 `vllm-pp2`，追加 `ray stop` 任务

**Makefile 新增**（`Makefile:186` 之后）：
- 变量 `PP2_MODEL`（默认 `Qwen3.5-122B-A10B-FP8`）、`PP2_CONTAINER`、`PP2_MAX_NUM_SEQS`、`PP2_MAX_BATCHED_TOKENS`、`PP2_DIST_BACKEND`，host/port/iface 复用 `TP2_*`
- 目标 `vllm-pp2-deploy`、`vllm-pp2-test`、`vllm-pp2-stop`、`vllm-pp2-benchmark`，结构镜像 `Makefile:148-185`
- `Makefile:1` 的 `.PHONY` 列表追加这 4 个

**目标模型与显存核算**（`gpu-memory-utilization=0.7` 每节点约 89GB 可用）：

| 模型 | 量化 | 权重总大小 | PP=2 每 stage | 结论 |
|---|---|---|---|---|
| Qwen3.5-122B-A10B | NVFP4 | ~75GB | 单节点即可 | sanity 基线，作为 TP1 单节点回归 |
| Qwen3.5-122B-A10B | FP8 | ~122GB | ~61GB | **Phase B 主目标**，留 28GB 给 KV/activations |
| Qwen3.5-122B-A10B | BF16 | ~245GB | ~122GB | 需要 `gpu-memory-utilization=0.9`，边缘可行 |
| Llama-3.3-70B-Instruct-FP8 | FP8 | ~70GB | 单节点 | TP1 对照组 |

**实施 agent 自行决策点**：先用 `TP2_DIST_BACKEND=ray` 试跑 Phase B；若 Ray 集群启动失败或 vLLM 在 PP 下不能识别两个 worker，回退 `mp` 并在 `benchmarks/` 的报告中记录失败原因与日志片段。

**验收**：
- `make vllm-pp2-deploy PP2_MODEL=Qwen3.5-122B-A10B-FP8`
- 两节点 `docker logs vllm-pp2` 都输出 `pipeline_parallel_size=2`，coordinator 显示 `PP rank 0`、worker 显示 `PP rank 1`
- `curl http://100.97.87.120:8000/v1/models` 返回模型 ID
- 跑扩展后的 benchmark（Phase D），**worker 节点 GPU util 必须持续 >30%**（不再是 TP=2 下的 0%），1024-token 长输出测例通过

## Phase C — 稳定性加固（TP2 与 PP2 通用）

1. `scripts/run-vllm-tp2.sh:59` 把 `--max-num-seqs` 改成 env 驱动，默认 16
2. `scripts/run-vllm-tp2.sh:58` 之后新增 `--max-num-batched-tokens ${TP2_MAX_NUM_BATCHED_TOKENS:-4096}`
3. `playbooks/vllm-tp2-deploy.yml:100` 之后追加 `Capture container logs on failure` 任务：`always` 运行 `docker logs vllm-tp2 > /tmp/vllm-tp2.log`，用 `ansible.builtin.fetch` 回传到本机 `benchmarks/logs/`；`vllm-pp2-deploy.yml` 镜像此任务
4. `playbooks/vllm-tp2-validate.yml:53-66` smoke completion 追加 `max_tokens=256` 的请求（600s 超时），提前捕获长输出失败类
5. **新增 `scripts/monitor-node-load.sh`**：每秒采集 `nvidia-smi dmon -c 1`、`mpstat 1 1`、`nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader`，输出 CSV。供 Phase D sidecar 使用

## Phase D — Benchmark 升级

修改 `scripts/vllm-tp2-benchmark.sh`：

1. `scripts/vllm-tp2-benchmark.sh:76-78` 附近追加测例：
   - `run_case "long-output" "Write a 1000-word essay on unified memory." 1024`
   - `run_case "long-context" "<4k-token context>" 256`（上下文文本 heredoc 内联）
2. `scripts/vllm-tp2-benchmark.sh:66-70` 和 `:82-86` 的 pre/post 快照改为**连续采样**：测例开始前启动 `scripts/monitor-node-load.sh` 后台循环，结束后 kill，写 per-second CSV 到 `benchmarks/telemetry-<label>-<host>.csv`，并在报告末尾嵌入每节点 GPU util p50/p95 摘要（这正是原报告漏掉 96/0 失衡的原因）
3. `scripts/vllm-tp2-benchmark.sh:10-11` 的 `REPORT_FILE` 参数化 `$(date +%Y-%m-%d)-${MODE:-tp2}`，`MODE` ∈ `tp2|pp2|tp2-roce`
4. 新增 `scripts/vllm-pp2-benchmark.sh` 瘦封装：`export MODE=pp2` 后 `exec scripts/vllm-tp2-benchmark.sh "$@"`
5. Makefile `vllm-pp2-benchmark` 目标调用之

## Phase E —（可选）Disaggregated Prefill/Decode

**不在本次实施范围内**，仅预留为 stretch。Phase A+B 稳定后再启动。vLLM v1 内置 P/D disagg 通过 `--kv-transfer-config` JSON 配合 `PyNcclConnector` 或 NIXL 实现；先验证 `docker run --rm vllm/vllm-openai:gemma4-cu130 python -c 'import nixl'` 是否可用，否则需要新镜像。实施 agent 可在 Phase B 收尾时把这段验证结果写入 `benchmarks/` 作为后续决策依据。

## 关键文件清单

**新增**：
- `playbooks/diagnostics-interconnect.yml`
- `scripts/run-vllm-pp2.sh`
- `scripts/monitor-node-load.sh`
- `scripts/vllm-pp2-benchmark.sh`
- `playbooks/vllm-pp2-deploy.yml`
- `playbooks/vllm-pp2-validate.yml`
- `playbooks/vllm-pp2-stop.yml`
- `benchmarks/dgx-spark-interconnect-<date>.md`（Phase 0 产出）
- `benchmarks/dgx-spark-pp2-qwen122b-<date>.md`（Phase B 产出）

**修改**：
- `config/vllm.env:21-23`（Phase A）
- `scripts/run-vllm-tp2.sh:28-44, 58-59`（Phase A + C）
- `scripts/vllm-tp2-benchmark.sh:10-11, 66-86`（Phase D）
- `playbooks/vllm-tp2-deploy.yml:81-100`（Phase A），末尾追加日志捕获（Phase C）
- `playbooks/vllm-tp2-validate.yml:53-66`（Phase C）
- `Makefile:1, 16-24, 148-186`（Phase A + B）

## 合入顺序与 gate

1. **PR 1 — Phase 0 诊断**：新 playbook + 报告产出，Gate：`benchmarks/dgx-spark-interconnect-<date>.md` 入库
2. **PR 2 — Phase A RoCE**：env/脚本/playbook/Makefile 环境变量透传；Gate：`code-snippet` 160-token 测例通过（或明确记录仍 hang，转 PR 4）
3. **PR 3 — Phase C 稳定性**：`max-num-seqs` 降默认 + 日志捕获；可与 PR 2 并行
4. **PR 4 — Phase B PP=2 路径**：新脚本/playbook/Makefile 目标 + Ray 引导；Gate：Qwen3.5-122B-A10B-FP8 长输出测例通过、worker GPU util >30%
5. **PR 5 — Phase D benchmark 升级**：与 PR 4 绑定，作为 PR 4 的验证工具同步合入

## 端到端验证命令

```bash
# Phase 0
uv run ansible-playbook -i inventory.ini playbooks/diagnostics-interconnect.yml \
  --ssh-extra-args="-i /Users/matthew/.ssh/vgio"

# Phase A (TP2 + RoCE)
make vllm-tp2-deploy && make vllm-tp2-test && make vllm-tp2-benchmark
# 期望: code-snippet 测例 HTTP 200, 非 500

# Phase B (PP2 + 122B)
make vllm-pp2-deploy PP2_MODEL=Qwen3.5-122B-A10B-FP8
make vllm-pp2-test
make vllm-pp2-benchmark PP2_MODEL=Qwen3.5-122B-A10B-FP8
# 期望: 4 个测例全部 200, worker GPU util p50 >30%, telemetry CSV 产出

# 回归: TP2 路径仍可用
make vllm-tp2-stop && make vllm-tp2-deploy && make vllm-tp2-test
```

## 风险与注意事项

- **Ray vs mp 的选择**由实施 agent 根据 Phase B 首轮结果决定，两条分支都在脚本/playbook 里预留 env 变量
- **122B FP8 在 `gpu-memory-utilization=0.7` 下余量紧**：若 OOM，先降 `--max-model-len` 至 4096 再逐步上调；**不要**突破 0.7 以上（`QWEN.md:113` 说明统一内存必须留头）
- **Ray 跨节点端口**：6379（Ray GCS）+ 10001（Ray client）+ 若干 object manager 端口，需确认两节点防火墙放行；`--network host` 下通常直通，Phase 0 可用 `nc -zv` 快速验证
- **Phase A 若 mlxconfig 需要 sudo** 而 `admin` 无免密 sudo，则诊断降级为 `ibv_devices` + `ibstat` 只读输出，足以判断 RoCE 可行性

---

## 附录 A：实施模板（可直接复制落地）

下面的代码片段是为实施 agent 准备的可复制骨架。行号参考现有文件，所有路径都相对 `/Users/matthew/projects/meirongdev/nv-dgx-spark`。

### A.1 Phase 0 — `playbooks/diagnostics-interconnect.yml`（新增）

```yaml
---
- name: DGX Spark interconnect diagnostics (read-only)
  hosts: servers
  become: no
  gather_facts: no
  vars:
    nccl_iface: "enp1s0f0np0"
    diag_image: "vllm/vllm-openai:gemma4-cu130"
    out_dir: "/tmp/dgx-diag"
  tasks:
    - name: Ensure output dir exists on each node
      ansible.builtin.file:
        path: "{{ out_dir }}"
        state: directory
        mode: "0755"

    - name: Collect ibv_devices
      ansible.builtin.shell: "ibv_devices 2>&1 || echo 'NO_IBV_DEVICES'"
      register: ibv_out
      changed_when: false

    - name: Collect ibstat
      ansible.builtin.shell: "ibstat 2>&1 || echo 'NO_IBSTAT'"
      register: ibstat_out
      changed_when: false

    - name: Collect ethtool link info
      ansible.builtin.shell: "ethtool {{ nccl_iface }} 2>&1 || echo 'NO_ETHTOOL'"
      register: ethtool_out
      changed_when: false

    - name: Dump RoCE GID types
      ansible.builtin.shell: |
        for f in /sys/class/infiniband/*/ports/1/gid_attrs/types/*; do
          [ -f "$f" ] && printf '%s\t%s\n' "$f" "$(cat "$f" 2>/dev/null)"
        done 2>&1 || echo 'NO_GID_ATTRS'
      register: gid_out
      changed_when: false

    - name: Write per-node diagnostic report
      ansible.builtin.copy:
        dest: "{{ out_dir }}/interconnect.txt"
        content: |
          === host: {{ inventory_hostname }} ===
          --- ibv_devices ---
          {{ ibv_out.stdout }}
          --- ibstat ---
          {{ ibstat_out.stdout }}
          --- ethtool {{ nccl_iface }} ---
          {{ ethtool_out.stdout }}
          --- GID attrs ---
          {{ gid_out.stdout }}

    - name: Fetch per-node reports to control host
      ansible.builtin.fetch:
        src: "{{ out_dir }}/interconnect.txt"
        dest: "benchmarks/interconnect/{{ inventory_hostname }}.txt"
        flat: yes

- name: iperf3 + NCCL baselines (run once, driven from coordinator)
  hosts: "{{ groups['servers'][0] }}"
  become: no
  gather_facts: no
  vars:
    worker_ip: "{{ groups['servers'][1] }}"
    diag_image: "vllm/vllm-openai:gemma4-cu130"
  tasks:
    - name: Start iperf3 server on worker
      delegate_to: "{{ worker_ip }}"
      ansible.builtin.shell: |
        pkill iperf3 2>/dev/null || true
        nohup iperf3 -s -D >/tmp/iperf3.log 2>&1
      changed_when: true

    - name: Run iperf3 client from coordinator
      ansible.builtin.shell: "iperf3 -c {{ worker_ip }} -t 30 -P 4 -J"
      register: iperf_json
      changed_when: false

    - name: Stop iperf3 server on worker
      delegate_to: "{{ worker_ip }}"
      ansible.builtin.shell: "pkill iperf3 || true"
      changed_when: true

    - name: Save iperf3 result
      ansible.builtin.copy:
        dest: "benchmarks/interconnect/iperf3.json"
        content: "{{ iperf_json.stdout }}"
      delegate_to: localhost
      become: no

    # NCCL all_reduce_perf: 在两节点各启一个容器, torchrun 两进程 rendezvous.
    # 细节由实施 agent 根据镜像内实际路径落地; 下面给出关键命令:
    #   docker run --rm --gpus all --network host --ipc=host \
    #     -e NCCL_SOCKET_IFNAME=enp1s0f0np0 \
    #     -e NCCL_IB_DISABLE={0 或 1} -e NCCL_NET=IB \
    #     -e NCCL_IB_HCA=mlx5_0 -e NCCL_IB_GID_INDEX=3 \
    #     {{ diag_image }} \
    #     /opt/nccl-tests/build/all_reduce_perf -b 8 -e 512M -f 2 -g 1
    # 若镜像内无 nccl-tests, 则 pull nvcr.io/nvidia/pytorch:25.09-py3 作为后备.
```

**实施 agent 需要补齐**：NCCL all_reduce_perf 的双节点 launcher（建议先 `docker run --rm <image> ls /opt/nccl-tests/build` 确认二进制，然后用 `torchrun --nnodes=2 --nproc-per-node=1 --rdzv-backend=c10d --rdzv-endpoint=<coord>:29500` 启动 pytorch 版，或直接 MPI 版）。跑两轮：`NCCL_IB_DISABLE=1` 基线 + `NCCL_IB_DISABLE=0` RoCE。把两轮 busbw 写入 `benchmarks/interconnect/nccl-allreduce.txt`。

**最终产出**：`benchmarks/dgx-spark-interconnect-YYYY-MM-DD.md`，手写 Markdown 聚合上述所有结果，至少包含：
- 每节点 RoCE 支持结论（是/否/受限）
- iperf3 TCP Gbps
- NCCL busbw TCP vs RoCE 对比
- 结论：Phase A 走/不走

### A.2 Phase A — `config/vllm.env:18-23` 目标内容

```ini
# ========================================
# NCCL (Multi-node RoCEv2 over ConnectX-7)
# ========================================
NCCL_P2P_DISABLE=0
NCCL_SOCKET_IFNAME=enp1s0f0np0
GLOO_SOCKET_IFNAME=enp1s0f0np0
NCCL_IB_DISABLE=0
NCCL_NET=IB
NCCL_IB_HCA=mlx5_0                # Phase 0 若显示不同设备名需调整
NCCL_IB_GID_INDEX=3               # Phase 0 从 gid_attrs/types 找 "RoCE v2" 行
NCCL_IB_TC=106
NCCL_IB_SL=3
NCCL_IB_QPS_PER_CONNECTION=4
NCCL_IB_TIMEOUT=22
NCCL_IB_RETRY_CNT=7
# Stability / error handling
NCCL_ASYNC_ERROR_HANDLING=1
TORCH_NCCL_ASYNC_ERROR_HANDLING=1
NCCL_TIMEOUT=1800
NCCL_DEBUG=WARN                   # 调试临时覆盖为 INFO, 勿在生产常开
```

`scripts/run-vllm-tp2.sh:28-44` 的 `docker run` 追加（插在现有 `-e NCCL_SOCKET_IFNAME` 之后）：

```sh
  -e NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}" \
  -e NCCL_NET="${NCCL_NET:-IB}" \
  -e NCCL_IB_HCA="${NCCL_IB_HCA:-mlx5_0}" \
  -e NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX:-3}" \
  -e NCCL_IB_TC="${NCCL_IB_TC:-106}" \
  -e NCCL_IB_SL="${NCCL_IB_SL:-3}" \
  -e NCCL_IB_QPS_PER_CONNECTION="${NCCL_IB_QPS_PER_CONNECTION:-4}" \
  -e NCCL_IB_TIMEOUT="${NCCL_IB_TIMEOUT:-22}" \
  -e NCCL_IB_RETRY_CNT="${NCCL_IB_RETRY_CNT:-7}" \
  -e NCCL_ASYNC_ERROR_HANDLING="${NCCL_ASYNC_ERROR_HANDLING:-1}" \
  -e TORCH_NCCL_ASYNC_ERROR_HANDLING="${TORCH_NCCL_ASYNC_ERROR_HANDLING:-1}" \
  -e NCCL_TIMEOUT="${NCCL_TIMEOUT:-1800}" \
  -e NCCL_DEBUG="${NCCL_DEBUG:-WARN}" \
```

`playbooks/vllm-tp2-deploy.yml:83` 的 `environment:` 块镜像追加相同键（用 `{{ tp2_* | default(...) }}` 变量形式），然后在 `vars:` 里补默认值。Makefile 相应追加 `-e "tp2_nccl_ib_hca=$(TP2_NCCL_IB_HCA)"` 等透传。

### A.3 Phase B — `scripts/run-vllm-pp2.sh`（新增）

完整克隆 `run-vllm-tp2.sh` 后应用以下 diff（用相对于原脚本行号描述）：

```diff
@@ 4-19 默认值段
-TP2_TP_SIZE="${TP2_TP_SIZE:-2}"
-TP2_PP_SIZE="${TP2_PP_SIZE:-1}"
+TP2_TP_SIZE="${TP2_TP_SIZE:-1}"
+TP2_PP_SIZE="${TP2_PP_SIZE:-2}"
+TP2_DIST_BACKEND="${TP2_DIST_BACKEND:-ray}"
+TP2_KV_CACHE_DTYPE="${TP2_KV_CACHE_DTYPE:-auto}"
+TP2_MAX_NUM_SEQS="${TP2_MAX_NUM_SEQS:-16}"
+TP2_MAX_NUM_BATCHED_TOKENS="${TP2_MAX_NUM_BATCHED_TOKENS:-4096}"
-TP2_CONTAINER_NAME="${TP2_CONTAINER_NAME:-vllm-tp2}"
+TP2_CONTAINER_NAME="${TP2_CONTAINER_NAME:-vllm-pp2}"

@@ 48 serve 参数段
-    --distributed-executor-backend mp \
+    --distributed-executor-backend "${TP2_DIST_BACKEND}" \
@@ 56
-    --kv-cache-dtype fp8 \
+    --kv-cache-dtype "${TP2_KV_CACHE_DTYPE}" \
@@ 59
-    --max-num-seqs 64 \
+    --max-num-seqs "${TP2_MAX_NUM_SEQS}" \
+    --max-num-batched-tokens "${TP2_MAX_NUM_BATCHED_TOKENS}" \
```

### A.4 Phase B — `playbooks/vllm-pp2-deploy.yml` Ray 引导任务片段

在 `Launch TP=2 participant` 任务（原 `vllm-tp2-deploy.yml:81`）**之前**插入：

```yaml
    - name: Stop any previous Ray cluster
      ansible.builtin.command: docker rm -f ray-{{ tp2_container_name }}
      changed_when: true
      failed_when: false

    - name: Start Ray head on coordinator
      when: inventory_hostname == tp2_coordinator
      ansible.builtin.shell: |
        docker run -d --name ray-{{ tp2_container_name }} \
          --network host --gpus all --ipc=host \
          --entrypoint bash \
          {{ tp2_image }} -c \
          "ray start --head --port=6379 \
            --node-ip-address={{ tp2_coordinator }} \
            --block"
      changed_when: true

    - name: Wait for Ray GCS port
      when: inventory_hostname == tp2_coordinator
      ansible.builtin.wait_for:
        host: "{{ tp2_coordinator }}"
        port: 6379
        timeout: 60

    - name: Join Ray worker
      when: inventory_hostname == tp2_worker
      ansible.builtin.shell: |
        docker run -d --name ray-{{ tp2_container_name }} \
          --network host --gpus all --ipc=host \
          --entrypoint bash \
          {{ tp2_image }} -c \
          "ray start --address={{ tp2_coordinator }}:6379 \
            --node-ip-address={{ tp2_worker }} \
            --block"
      changed_when: true
```

**优化路径**：若 `docker run --rm {{ tp2_image }} test -x /opt/vllm/examples/run_cluster.sh` 返回 0，用它代替上面两个 Ray 任务（vLLM 官方 helper，已处理所有端口和 env 细节）。

`Launch TP=2 participant` 任务本身改名为 `Launch PP=2 participant`，`environment:` 增加：

```yaml
        TP2_TP_SIZE: "1"
        TP2_PP_SIZE: "2"
        TP2_DIST_BACKEND: "{{ tp2_dist_backend | default('ray') }}"
        TP2_KV_CACHE_DTYPE: "{{ tp2_kv_cache_dtype | default('auto') }}"
        TP2_MAX_NUM_SEQS: "{{ tp2_max_num_seqs | default(16) }}"
        TP2_MAX_NUM_BATCHED_TOKENS: "{{ tp2_max_num_batched_tokens | default(4096) }}"
        TP2_CONTAINER_NAME: "vllm-pp2"
```

### A.5 Phase C — 失败日志捕获任务片段

在 `vllm-tp2-deploy.yml`（和新的 `vllm-pp2-deploy.yml`）末尾追加：

```yaml
    - name: Capture container logs (always)
      ansible.builtin.shell: |
        docker logs {{ tp2_container_name }} > /tmp/{{ tp2_container_name }}.log 2>&1 || true
      changed_when: false
      failed_when: false

    - name: Fetch container logs back to control host
      ansible.builtin.fetch:
        src: "/tmp/{{ tp2_container_name }}.log"
        dest: "benchmarks/logs/{{ tp2_container_name }}-{{ inventory_hostname }}.log"
        flat: yes
        fail_on_missing: false
```

挂在 playbook `tasks:` 最后即可；若希望失败也能触发，把它们放在独立的 `post_tasks:` 或用 block/rescue 包起来。最简单的方式：保留上面的 always 语义（`failed_when: false`），部署任务自己失败时 ansible 仍会跳进这里。

`vllm-tp2-validate.yml:53-66` 的 smoke completion 追加第二条：

```yaml
    - name: Long-output smoke (max_tokens=256)
      ansible.builtin.uri:
        url: "http://{{ tp2_coordinator }}:{{ tp2_port }}/v1/completions"
        method: POST
        body_format: json
        body:
          model: "{{ tp2_model }}"
          prompt: "Explain unified memory in two paragraphs."
          max_tokens: 256
          temperature: 0.2
        timeout: 600
        status_code: 200
      register: smoke_long
      retries: 0
```

### A.6 Phase C — `scripts/monitor-node-load.sh`（新增）

```sh
#!/usr/bin/env bash
# Usage: monitor-node-load.sh <out.csv> [interval_sec=1]
set -euo pipefail
OUT="${1:?out.csv required}"
INTERVAL="${2:-1}"
HOST="$(hostname -s)"
printf 'ts,host,cpu_pct,mem_used_mb,gpu_util,gpu_mem_used_mib\n' > "$OUT"
while true; do
  ts=$(date +%s)
  cpu=$(mpstat 1 1 2>/dev/null | awk '/Average/ {print 100-$NF; exit}')
  mem=$(free -m | awk '/Mem:/ {print $3}')
  read gpu_util gpu_mem < <(nvidia-smi --query-gpu=utilization.gpu,memory.used \
      --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ',' | awk '{print $1, $2}')
  printf '%s,%s,%s,%s,%s,%s\n' "$ts" "$HOST" "${cpu:-NA}" "${mem:-NA}" "${gpu_util:-NA}" "${gpu_mem:-NA}" >> "$OUT"
  sleep "$INTERVAL"
done
```

Benchmark 脚本里用法：

```sh
ssh "$SSH_USER@$coord" "bash -s -- /tmp/tele-$label-$coord.csv 1" < scripts/monitor-node-load.sh &
MONPID_C=$!
ssh "$SSH_USER@$worker" "bash -s -- /tmp/tele-$label-$worker.csv 1" < scripts/monitor-node-load.sh &
MONPID_W=$!
run_case "$label" "$prompt" "$max_tokens"
kill "$MONPID_C" "$MONPID_W" 2>/dev/null || true
scp "$SSH_USER@$coord:/tmp/tele-$label-$coord.csv" "benchmarks/"
scp "$SSH_USER@$worker:/tmp/tele-$label-$worker.csv" "benchmarks/"
```

### A.7 Phase D — 长测例与 MODE 参数化

`scripts/vllm-tp2-benchmark.sh` 顶部追加：

```sh
MODE="${MODE:-tp2}"
REPORT_FILE="${REPORT_FILE:-benchmarks/dgx-spark-${MODE}-$(date +%Y-%m-%d).md}"
```

测例列表追加：

```sh
run_case "long-output"  "Write a 1000-word essay on unified memory architecture." 1024
run_case "long-context" "$(cat scripts/fixtures/long-context-4k.txt)" 256
```

（`scripts/fixtures/long-context-4k.txt` 可由实施 agent 生成，内容为 ~4k token 的技术文档样本，例如 `yes "The quick brown fox" | head -c 16000`。）

报告末尾追加 telemetry 摘要段：

```sh
python3 - <<'PY' >> "$REPORT_FILE"
import csv, glob, statistics
print("\n## Telemetry summary (per case, per host)\n")
print("| label | host | gpu_util p50 | gpu_util p95 | cpu p50 |")
print("|---|---|---|---|---|")
for f in sorted(glob.glob("benchmarks/tele-*.csv")):
    with open(f) as fh:
        rows = list(csv.DictReader(fh))
    if not rows: continue
    label = f.split("tele-")[1].split("-")[0]
    host  = rows[0]["host"]
    util  = [float(r["gpu_util"]) for r in rows if r["gpu_util"].replace('.','',1).isdigit()]
    cpu   = [float(r["cpu_pct"])  for r in rows if r["cpu_pct"].replace('.','',1).isdigit()]
    if not util: continue
    print(f"| {label} | {host} | {statistics.median(util):.0f} | {sorted(util)[int(len(util)*0.95)-1]:.0f} | {statistics.median(cpu) if cpu else 'NA':.0f} |")
PY
```

### A.8 `scripts/vllm-pp2-benchmark.sh`（新增 5 行瘦封装）

```sh
#!/usr/bin/env bash
set -euo pipefail
export MODE=pp2
exec "$(dirname "$0")/vllm-tp2-benchmark.sh" "$@"
```

### A.9 Makefile 新增块（追加到 `Makefile:186` 之后）

```make
# ========================================
# PP=2 multi-node (primary 120B+ path)
# ========================================
PP2_MODEL ?= Qwen3.5-122B-A10B-FP8
PP2_MAX_MODEL_LEN ?= 4096
PP2_MAX_NUM_SEQS ?= 16
PP2_MAX_NUM_BATCHED_TOKENS ?= 4096
PP2_DIST_BACKEND ?= ray
PP2_KV_CACHE_DTYPE ?= auto

vllm-pp2-deploy:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-pp2-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_worker=$(TP2_WORKER)" \
		-e "tp2_model=$(PP2_MODEL)" \
		-e "tp2_image=$(TP2_IMAGE)" \
		-e "tp2_port=$(TP2_PORT)" \
		-e "tp2_master_port=$(TP2_MASTER_PORT)" \
		-e "tp2_nccl_iface=$(TP2_NCCL_IFACE)" \
		-e "tp2_gpu_memory_utilization=$(TP2_GPU_MEMORY_UTIL)" \
		-e "tp2_max_model_len=$(PP2_MAX_MODEL_LEN)" \
		-e "tp2_max_num_seqs=$(PP2_MAX_NUM_SEQS)" \
		-e "tp2_max_num_batched_tokens=$(PP2_MAX_NUM_BATCHED_TOKENS)" \
		-e "tp2_dist_backend=$(PP2_DIST_BACKEND)" \
		-e "tp2_kv_cache_dtype=$(PP2_KV_CACHE_DTYPE)"

vllm-pp2-test:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-pp2-validate.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_model=$(PP2_MODEL)" \
		-e "tp2_port=$(TP2_PORT)"

vllm-pp2-stop:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-pp2-stop.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

vllm-pp2-benchmark:
	bash scripts/vllm-pp2-benchmark.sh "$(TP2_COORDINATOR)" "$(TP2_WORKER)" "$(PP2_MODEL)" "$(TP2_PORT)" "$(SSH_KEY)" "$(SSH_USER)"
```

同时把 `Makefile:1` 的 `.PHONY` 列表追加：`vllm-pp2-deploy vllm-pp2-test vllm-pp2-stop vllm-pp2-benchmark diagnostics-interconnect`。

并新增 diagnostics 目标：

```make
diagnostics-interconnect:
	uv run ansible-playbook -i $(INVENTORY) playbooks/diagnostics-interconnect.yml \
		--ssh-extra-args="-i $(SSH_KEY)"
```

---

## 附录 B：实施任务清单（供子 agent 逐项执行）

按 PR 顺序展开，每项都是一次原子性改动 + 验证。

### PR 1 — Phase 0 诊断
- [ ] 新建 `playbooks/diagnostics-interconnect.yml`（A.1 骨架）
- [ ] 补齐 NCCL all_reduce_perf 双节点 launcher（TCP + RoCE 两轮）
- [ ] Makefile 新增 `diagnostics-interconnect` 目标
- [ ] 执行 `make diagnostics-interconnect`，产物落到 `benchmarks/interconnect/`
- [ ] 手写聚合报告 `benchmarks/dgx-spark-interconnect-YYYY-MM-DD.md`，明确 Phase A 走/不走

### PR 2 — Phase A RoCE 环境变量
- [ ] 按 A.2 改写 `config/vllm.env:18-23`
- [ ] 按 A.2 在 `scripts/run-vllm-tp2.sh:28-44` 追加 `-e` 透传
- [ ] `playbooks/vllm-tp2-deploy.yml:83` environment 块镜像追加
- [ ] `Makefile:16-24` 新增 3 个 `TP2_NCCL_*` 变量，`:148-163` 透传
- [ ] 重跑 `make vllm-tp2-deploy && make vllm-tp2-test && make vllm-tp2-benchmark`
- [ ] 校验容器日志出现 `NCCL INFO NET/IB`
- [ ] **Gate**：`code-snippet` 160-token 测例 HTTP 200

### PR 3 — Phase C 稳定性（可与 PR 2 并行）
- [ ] `scripts/run-vllm-tp2.sh:59` 把 `--max-num-seqs 64` 改成 env 驱动默认 16
- [ ] 同文件追加 `--max-num-batched-tokens` 参数
- [ ] 按 A.5 在 `vllm-tp2-deploy.yml` 末尾追加日志捕获 + fetch
- [ ] 按 A.5 在 `vllm-tp2-validate.yml` 追加 long-output smoke
- [ ] 新建 `scripts/monitor-node-load.sh`（A.6）
- [ ] `bash -n` 过语法，`shellcheck` 过静态检查
- [ ] `make vllm-tp2-test` 验证新 smoke 通过

### PR 4 — Phase B PP=2 路径
- [ ] 新建 `scripts/run-vllm-pp2.sh`（A.3 diff）
- [ ] 新建 `playbooks/vllm-pp2-deploy.yml`（克隆 tp2 版 + A.4 Ray 任务）
- [ ] 新建 `playbooks/vllm-pp2-validate.yml`（克隆 + 断言 PP 标记）
- [ ] 新建 `playbooks/vllm-pp2-stop.yml`（克隆 + `ray stop`）
- [ ] 按 A.9 追加 Makefile 块
- [ ] 下载 Qwen3.5-122B-A10B-FP8 到两节点 HF cache，playbook 缓存检查通过
- [ ] `make vllm-pp2-deploy PP2_MODEL=Qwen3.5-122B-A10B-FP8`
- [ ] `make vllm-pp2-test`、`curl /v1/models`
- [ ] **Gate**：长输出测例通过 + worker GPU util p50 >30%
- [ ] 产出 `benchmarks/dgx-spark-pp2-qwen122b-YYYY-MM-DD.md`
- [ ] 回归：`make vllm-pp2-stop && make vllm-tp2-deploy && make vllm-tp2-test` 仍通过

### PR 5 — Phase D Benchmark 升级（与 PR 4 绑定）
- [ ] 按 A.7 改 `scripts/vllm-tp2-benchmark.sh` 追加两个长测例 + MODE 参数化
- [ ] pre/post 快照替换为 A.6 的 sidecar 连续采样
- [ ] 报告末尾追加 telemetry 摘要段
- [ ] 新建 `scripts/fixtures/long-context-4k.txt`
- [ ] 新建 `scripts/vllm-pp2-benchmark.sh`（A.8）
- [ ] 跑 `make vllm-tp2-benchmark MODE=tp2-roce` 与 `make vllm-pp2-benchmark`，对比两份报告

### 跨 PR 通用
- [ ] 每个 PR 都通过 `make ping` 确认两节点在线
- [ ] 所有新脚本 `chmod +x` 并 `bash -n` 语法检查
- [ ] 所有新 playbook 过 `ansible-playbook --syntax-check`
- [ ] 任何失败 run 都要把 `benchmarks/logs/*.log` 一起入库
