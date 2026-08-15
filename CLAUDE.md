# CLAUDE.md

Guidance for Claude Code (claude.ai/code) and other agents working in this repo.
`AGENTS.md` and `QWEN.md` are symlinks to this file.

**This file is an index, not the manual.** It carries what you need every session
(what runs where, how to drive it, what will bite you). Detail lives in `docs/` —
follow the pointers rather than guessing.

## Project Overview

Deployment tooling for vLLM inference across two NVIDIA DGX Spark (GB10
Blackwell) servers. Two stacks live here — one primary, one fallback:

| Stack | Nodes | Endpoint | Runtime | Status |
|---|---|---|---|---|
| **DeepSeek-V4-Flash-0731** | **2** (TP=2) | `:8000` `deepseek-v4-flash` | k3s | primary |
| **Qwen3.8-27B-NVFP4** | **1** (S1) | `:8888` `qwen38-27b` | plain docker | fallback |

⚠️ **The primary and fallback are mutually exclusive** — same GPU memory.
Always `make qwen38-stop` before `make v4flash-run`, and vice versa.

- **V4-Flash** (primary): 284B/13B-active, official FP8, 1M ctx, **DSpark**
  speculative decoding. Warm single-stream **31–84 tok/s depending on content**
  (mean 67 — see `docs/benchmarking-cn.md` before quoting any number).
  Runs as two pinned Pods since 2026-08-13; the eugr `spark-vllm-docker` +
  systemd path stays installed-but-disabled as the rollback.
- **Qwen3.8-27B** (fallback): exists because V4-Flash is TP=2 and indivisible —
  when one node dies the whole service dies (2026-08-15 S2 hardware death).
  Serves **native 262144** ctx. **Slower and weaker, not an upgrade**:
  24.9 vs 67.2 tok/s mean, ~10–12 pts below on agentic coding.

**Target hosts** (edit `HOSTS` in Makefile to change):
- `100.97.87.120` — server 1 / `spark-ccf3` (V4-Flash head + the fallback stack)
- `100.67.164.92` — server 2 / `spark-2435` (V4-Flash TP worker; k3s server)
- SSH: `admin` + `~/.ssh/vgio`
- `192.168.200.101/102` — the internal 200G CX7 link. Carries the TP=2 NCCL
  traffic (bypassing the CNI) and inter-node file copies.

## ⚠️ Current state (2026-08-15) — S2 is dead, running on the fallback

**S2 died at 08:29:40 CST 2026-08-15 and has not returned.** Power-level
whole-machine death, not a network fault. DGX Spark has **no BMC/IPMI** and
Wake-on-LAN failed — **recovery needs someone physically at the box.**

- **V4-Flash is stopped** and cannot run. `k3s-agent` on S1 is `disable --now`,
  so the leader Pod can't land and fight the fallback for memory.
  `kubectl` / `make v4flash-*` are also dead — the **k3s control plane is on S2**.
- **Qwen3.8-27B is serving on S1 `:8888`**; both CLIs default to it.

Post-mortem, evidence and the ordered recovery procedure:
`docs/qwen38-27b-fallback-cn.md` §1 and §7.

## Common Commands

### V4-Flash (primary, k3s)

kubectl runs from **this machine** — `~/.kube/dgx-spark.yaml`.

```bash
make v4flash-run        # scale both ranks to 1 (loads ~5min)
make v4flash-status     # pods + /v1/models
make v4flash-test       # coding smoke test + tok/s
make v4flash-load       # who is using the engine now (running/waiting, KV%, client IPs)
make v4flash-logs       # leader (rank0);  v4flash-logs-worker for rank1
make v4flash-restart    # recreate BOTH ranks (never restart one alone)
make v4flash-stop       # scale both to 0
```

⚠️ **Never restart a single rank** — it leaves the survivor hung in collectives
while `/health` and `/v1/models` still return 200. Gotcha #1 in
`docs/gotchas-cn.md`.

### Qwen3.8-27B (fallback, plain docker on S1)

```bash
make qwen38-run         # loads ~200s (22GB weights)
make qwen38-status      # container + /v1/models + free -h
make qwen38-test        # full benchmark: 3 warm-ups + 4 prompt shapes + acceptance
make qwen38-logs
make qwen38-stop
```

### Misc

```bash
make ping                          # ansible ping all hosts
make cmd COMMAND="uptime"          # ad-hoc command on all hosts
```

### Monitoring (node_exporter + smartctl_exporter → homelab Prometheus/Grafana)

```bash
make node-exporter-{deploy,status,logs,stop}      # docker, :9100, both hosts
make smartctl-exporter-{deploy,status,logs,stop}  # systemd, :9633, both hosts
```

Metrics surface in the **homelab** Grafana stack (`meirongdev/homelab` repo), not
locally: Prometheus scrapes both hosts over Tailscale (jobs
`node-exporter-dgx-spark` / `smartctl-dgx-spark`, label `cluster=dgx-spark`),
dashboard **"DGX Spark / Node Exporter"**. smartctl_exporter is **not** a
container — the quay image is amd64-only, so the GitHub linux-arm64 binary is
shipped over SSH as a root systemd service. This history is queryable and was
what pinned down S2's death (temps, load, memory in the minutes before).

### tmux (SSH drop protection)

SSH rides a flaky DERP relay; wrap long remote work in tmux.

```bash
make tmux-cmd COMMAND="docker pull ..." SESSION="my-task"
make tmux-list   HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill   HOST=100.97.87.120 SESSION=vllm-deploy
```

## Architecture (V4-Flash)

```
┌─ k3s cluster "dgx-spark" (cluster.id=1, Cilium CNI) ─────────┐
│  ┌──────────────────┐  200G CX7  ┌──────────────────┐        │
│  │ S1 spark-ccf3     │ ◄────────► │ S2 spark-2435     │       │
│  │ 192.168.200.101   │ RoCE/NCCL  │ 192.168.200.102   │       │
│  │ k3s agent         │   TP=2     │ k3s server        │       │
│  │ Pod v4flash-leader│ (bypasses  │ Pod v4flash-worker│       │
│  │ rank0, vLLM :8000 │   the CNI) │ rank1 --headless  │       │
│  └──────────────────┘            └──────────────────┘        │
└──────────────────────────┬───────────────────────────────────┘
                           │ Tailscale VPN (100.x)
                  ┌────────▼──────────┐
                  │   Mac (client)    │  kubectl → S2:6443
                  │ codex --profile dgx → 100.97.87.120:8000
                  └───────────────────┘
```

The two nodes form **one** TP=2 vLLM instance; only server 1 exposes the OpenAI
API. Server 2 is a pure TP worker — there is no separate endpoint on it. Both
Pods are `hostNetwork` + `privileged`, so NCCL/RoCE and the API behave exactly as
they did under docker; the CNI carries only system traffic.

The fallback stack is a single plain-docker container on S1 `:8888`, outside k3s.

## Unified memory constraints (GB10) — read before changing any launch flag

- 128 GB LPDDR5X coherent memory shared between CPU and GPU, per node.
- **Don't over-allocate `gpu-memory-utilization`** — too high risks OOM freezes
  of sshd itself. V4-Flash uses **0.80** (0.85 caused a full head-node OOM on
  2026-06-29); the fallback stack uses **0.75**; the retired single-node
  Qwen/Gemma stack needed **0.70**.
- Swap **must** be disabled (`swapoff -a`).
- `nvidia-smi` reports `[N/A]` for per-process memory on GB10; watch `free -h`.
- **Never build on S1 without stopping the running stack first** — even the
  "lightweight" prebuilt-wheel path compiles native deps from source and OOM'd
  the head node on 2026-07-04, taking the whole tmux server down with it.

## V4-Flash engine notes

Full build/prep runbook: `docs/deepseek-v4-flash-cn.md`. DSpark specifics:
`docs/dspark-upgrade-cn.md`. Recipe: `config/deepseek-v4-flash.yaml`.

- **Why two nodes:** official FP8 weights are ~167GB / 48 shards — they don't fit
  one GB10's 128GB. TP=2 splits them (~83GB/node), leaving room for KV cache.
- **Engine = jasl/vllm `codex/ds4-sm120-min-enable`.** GB10 is `sm_121`; stock
  builds lack a kernel for V4's sparse MLA, so the fork swaps in a Triton
  implementation via `VLLM_TRITON_MLA_SPARSE=1` (the load-bearing env).
  **SGLang is a dead end here** — its V4 attention needs a FlashMLA kernel with
  no `sm_121` build. Don't retry it.
- **The fork is needed for DSpark only.** Stock upstream vLLM can serve plain
  V4-Flash TP=2 on GB10 given `DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=...`
  (missing these looks like an architecture-support failure but isn't).
- **Serve from the local model PATH**, not the HF repo id — the worker node has
  no proxy, and HF-cache symlinks must be relative (gotcha #6).
- **DSpark tuning:** `num_speculative_tokens=5` is the GB10-tuned value
  (`dspark_block_size` is 5, so acceptance craters past draft position 4;
  n=3 ≈ 53.9, n=5 ≈ 56.6, n=7 ≈ 52.4 on the same prompt).
  **`max_num_seqs=6` / `max_num_batched_tokens=8192` is the validated ceiling** —
  `max_num_seqs=16` fails the KV preflight and CrashLoops until reverted.
- **torch-CPU build trap:** the from-source build leaves the runner image with
  torch CPU → `vllm._C: libtorch_cuda.so missing`. Fix: `scripts/vllm-fix-torch.sh`.
- **Watch item, not a to-do:** eugr's `b12x` ships DSpark with prebuilt images,
  but [eugr#331](https://github.com/eugr/spark-vllm-docker/issues/331) reports it
  crashing after 1–2 h, it quotes ~50 t/s (below our mean 67.2), and its recipe
  uses the `gpu_memory_utilization: 0.85` that OOM'd this head node.

## k3s runtime

Design + execution record: `docs/k3s-migration-design-cn.md`. Manifests + ops:
`k8s/README.md`.

- **Cluster:** k3s v1.36.3, server on **S2** / agent on **S1** (the head OOM'd
  once, so it carries the lighter role), node IPs on the 200G link. Cilium 1.19.6
  kube-proxy-less, tunnel/vxlan, Pod/Svc CIDR `10.44`/`10.45`.
- ⚠️ **ClusterMesh with homelab was evaluated and REJECTED 2026-08-13** — the
  Sparks are *shared* nodes from another tailnet, so subnet routes (and the
  cross-cluster node plane) cannot exist. Also: `cluster.id=1` **collides** with
  homelab's, and the `mtu: 1200` in `k8s/cilium-values.yaml` **never took effect**
  (the chart key is `MTU` — do **NOT** "fix" the casing). Design doc §6 is
  superseded; §6.4 has the adopted alternative.
- **Boot autostart is k3s's own service** — Pods stay Pending until the node is
  Ready and the device plugin has registered the GPU. Verified 2026-08-13 by
  rebooting both nodes at once: Ready +34 s, Pods scheduled +47 s, real inference
  **+5 m29 s**, no intervention. NVIDIA device plugin must be **≥ v0.17.4** on
  GB10 (older ones crash on unified memory).
- **The image is local-only.** After any rebuild, on **both** nodes:
  `docker save vllm-node-dsv4:latest | sudo k3s ctr -n k8s.io images import -`,
  then re-pin (`io.cri-containerd.pinned=pinned`) — Pods use
  `imagePullPolicy: Never` and nothing can re-pull it. Skipping this looks like
  "I rebuilt and nothing changed".
- **`kubectl apply` converges replicas to the manifest value (1)** — don't apply
  while you mean to stay stopped.
- **Rollback** to docker/systemd: `make v4flash-stop`, then
  `ssh <head> sudo systemctl enable --now deepseek-v4-flash`.

## Known gotchas — index

Full detail with reproductions and dates: **`docs/gotchas-cn.md`**.

| # | Symptom | Where it bites |
|---|---|---|
| 1 | Single-rank restart → zombie TP group; `/health` still 200, all generations time out | V4-Flash ops ⚠️ most expensive |
| 2 | Primary and fallback both want the GPU → OOMs the whole node | switching stacks ⚠️ |
| 3 | `NCCL WARN ... GID table changed` every ~45 s | reading logs (harmless) |
| 4 | Domestic mirror "is slow" — actually `docker build`/`run` forced through the xray proxy (90×) | building images |
| 5 | ModelScope/github unreachable while Tailscale is fine → DHCP hands out no DNS | networking |
| 6 | `HFValidationError` in-container → absolute HF-cache symlinks | downloading models |
| 7 | `Syntax error in template` → Ansible eats `--format 'table {{.Names}}'` | any ansible + docker `--format` |
| 8 | Foreign registries blocked/slow → daocloud + ModelScope + Tsinghua | all downloads |

## Measuring throughput

**Read `docs/benchmarking-cn.md` before quoting any tok/s number.** Short version:
acceptance is content-driven, so one prompt's number describes the prompt as much
as the cluster (31→84 tok/s on the same config). Three traps have each produced
wrong numbers in this repo's own docs: streaming counts *steps/s* not tok/s;
cold **and idle** decay ≈30% silently; short replies are overhead-capped.
Baseline: `benchmarks/bench-full-2026-08-05/`.

## Connecting from clients

Both stacks are **unauthenticated** vLLM and serve `/v1/chat/completions` **and**
`/v1/responses`. Full setup, per-stack reasoning-effort semantics, the
`contextWindowSize` hard-limit-0 trap and how to rebuild on a new machine:
**`docs/clients-cn.md`**.

```bash
codex --profile dgx        # → :8000 deepseek-v4-flash
codex --profile qwen38     # → :8888 qwen38-27b
qwen                       # boot default; ./scripts/qwen-model-switch.sh to flip
```

⚠️ Thinking kwargs differ per stack (`thinking` vs `enable_thinking`) and
codex/qwen's built-in `reasoning:false` does **not** reach a self-hosted vLLM.

## Key file map

**Entry points**
- `README.md` — human entry point and doc map.
- `Makefile` — the single user-facing interface for every stack.

**Live cluster**
- `k8s/` — `README.md` (versions + ops + traps), `registries.yaml`,
  `cilium-values.yaml`, `gpu/` (RuntimeClass + vendored device plugin),
  `v4flash/` (ConfigMap with per-rank launch scripts, Deployments, Service).
- `config/deepseek-v4-flash.yaml` — V4-Flash recipe; now the source of the **vLLM
  flags only**. Live launch commands are `k8s/v4flash/configmap-launch.yaml`
  (rendered from it). **Change both together.**

**Scripts**
- `scripts/v4-test.sh` — coding smoke test against `:8000` (one short prompt — a
  smoke test, *not* a benchmark).
- `scripts/qwen38-start.sh` / `qwen38-test.sh` — fallback stack launch + benchmark
  (`make qwen38-run` / `qwen38-test` rsync these to S1).
- `scripts/qwen-model-switch.sh` — flips the Qwen Code **boot default** between
  stacks (four fields across three files must agree — see `docs/clients-cn.md`).
- `scripts/vllm-fix-torch.sh` — fixes the torch-CPU build trap.
- `scripts/v2rayn-launch.sh` — revives the S1 v2rayN proxy (needed for github
  clones during a V4-Flash build).
- `scripts/modelscope-download.sh` — model download via `make modelscope-download`.
- `scripts/v4flash-boot.sh` + `config/deepseek-v4-flash.service` — the retired
  docker/systemd launch path, **kept as the rollback** (installed but disabled).

**Docs** (see `README.md` for the full map)
- `docs/gotchas-cn.md`, `docs/benchmarking-cn.md`, `docs/clients-cn.md` —
  the three split out of this file.
- `docs/deepseek-v4-flash-cn.md`, `docs/dspark-upgrade-cn.md` — primary stack.
- `docs/qwen38-27b-fallback-cn.md` — fallback stack + the S2 post-mortem.
- `docs/k3s-migration-design-cn.md` — cluster design (⚠️ §6 superseded).
- `docs/china-network-mirrors-cn.md` — mirror runbook.
- `benchmarks/bench-full-2026-08-05/` — the current performance baseline.

**Monitoring**
- `playbooks/node-exporter-deploy.yml`, `playbooks/smartctl-exporter-deploy.yml`.

## Conventions

- Docs in `docs/` are Chinese (`-cn.md`) with all commands, error strings and
  identifiers verbatim in English. This file stays English.
- The V4-Flash image on both servers is `vllm-node-dsv4:latest` (jasl fork build,
  driver 580.142 / CUDA 13.0); the fallback uses upstream
  `vllm/vllm-openai:nightly-aarch64`.
- SSH strict host key checking is disabled (automation).
- Ansible (the two monitoring exporter playbooks): always `uv run ansible` / `uv run ansible-playbook`;
  to add/remove hosts edit `HOSTS` in the Makefile then `make inventory`.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `perf:`).
