# nv-dgx-spark

Deployment tooling for vLLM inference on a two-node **NVIDIA DGX Spark (GB10
Blackwell)** cluster — 128 GB unified memory per node, joined by a 200G ConnectX-7
link, reachable over Tailscale.

Everything is driven through the `Makefile`. Detailed runbooks live in `docs/`
(Chinese prose, commands and identifiers in English).

---

## What runs here

| Stack | Nodes | Endpoint | Runtime | Status |
|---|---|---|---|---|
| **Qwen3.8-Flash-Next NVFP4** | 2 (TP=2) | `:8000` `qwen38-flash-next` | k3s | **primary** (since 2026-09-02) |
| **DeepSeek-V4-Flash-0731** | 2 (TP=2) | `:8000` `deepseek-v4-flash` | k3s | rollback target |
| **Qwen3.8-27B-NVFP4** | 1 (S1) | `:8888` `qwen38-27b` | plain docker | single-node fallback |

> ⚠️ **No two of these can run at the same time** — they want the same GPU
> memory, and the two TP=2 stacks also share `:8000`. Stop one before starting
> another.

> ⚠️ **Switching which stack is primary? Work `docs/stack-switch-cn.md`.**
> "Which stack is current" is hardcoded in ~8 places, and every one of them
> fails *silently*. Three wrong-number incidents have come from skipping it.

**Why a single-node fallback exists:** both TP=2 stacks are indivisible — the
weights don't fit one node, so when either machine dies the whole service dies.
That happened on 2026-08-15. The fallback keeps a (slower, weaker) model serving
on whichever node survives.

**Hosts** — `100.97.87.120` (S1 / `spark-ccf3`) and `100.67.164.92`
(S2 / `spark-2435`), SSH as `admin` with `~/.ssh/vgio`.

---

## Quick start

```bash
# primary stack (needs both nodes; kubectl uses ~/.kube/dgx-spark.yaml)
make qwen38fn-run         # preflight + scale both ranks to 1, loads 8-11 min
make qwen38fn-status      # pods + /v1/models
make qwen38fn-test        # smoke test + tool-call parser check

# rollback to V4-Flash (~5 min)
make qwen38fn-rollback && make v4flash-run

# single-node fallback (S1 alone)
make qwen38-run           # loads ~200 s
make qwen38-status
make qwen38-test          # full benchmark, not just a smoke test

# use it
codex --profile dgx       # or --profile qwen38
qwen                      # ./scripts/qwen-model-switch.sh flips the boot default
```

Two rules worth knowing before you touch anything:

1. **Never restart a single rank of a TP=2 stack.** The survivor hangs inside the
   collective *without exiting* — `/health` and `/v1/models` keep returning 200
   while every real generation times out. Use `make <stack>-restart` (both ranks).
2. **Don't quote a single tok/s number.** Speculative-decoding throughput is
   content-driven: on V4-Flash the same config measures 31 tok/s on prose and 84
   on count-to-300. See `docs/benchmarking-cn.md`.
3. **Assume any stack-specific default in a tool is stale until you check.**
   Model names, CoT field names and thinking kwargs all differ per stack and all
   fail silently. `docs/gotchas-cn.md` #9.

---

## Documentation map

Start with `CLAUDE.md` — it is the operational index for both agents and humans
(`AGENTS.md` and `QWEN.md` are symlinks to it). Then:

### Runbooks — how to build and operate

| Doc | What's in it |
|---|---|
| ⚠️ *(no runbook yet)* | **Primary stack (Flash-Next) has no `docs/` runbook.** Its reasoning lives in `config/qwen38-flash-next.yaml` comments + `k8s/qwen38fn/`. Known gap |
| **[`docs/stack-switch-cn.md`](docs/stack-switch-cn.md)** | **Primary-stack switch checklist — the ~8 places that hardcode "which stack is current", each of which fails silently. Read before and after any switch** |
| [`docs/deepseek-v4-flash-cn.md`](docs/deepseek-v4-flash-cn.md) | Rollback stack (V4-Flash): engine build/prep, one-time setup |
| [`docs/dspark-upgrade-cn.md`](docs/dspark-upgrade-cn.md) | DSpark speculative decoding: version landscape, tuning, gotchas |
| [`docs/qwen38-27b-fallback-cn.md`](docs/qwen38-27b-fallback-cn.md) | Single-node fallback: S2 post-mortem, deploy from scratch, recovery procedure |
| [`docs/host-maintenance-cn.md`](docs/host-maintenance-cn.md) | Host OS: apt / NVIDIA driver / kernel / DKMS — **read before any `apt upgrade`** |
| [`docs/gb10-tuning-cn.md`](docs/gb10-tuning-cn.md) | GB10 host-level tuning: the GPU clock cap A/B (adopted), the knobs that don't exist, and what not to touch |
| [`docs/china-network-mirrors-cn.md`](docs/china-network-mirrors-cn.md) | daocloud / ModelScope / Tsinghua mirrors from mainland China |
| [`k8s/README.md`](k8s/README.md) | Live cluster manifests, versions, ops |

### Reference — read before you need it

| Doc | What's in it |
|---|---|
| [`docs/gotchas-cn.md`](docs/gotchas-cn.md) | **9 traps, each paid for in downtime.** Scan the headings before debugging anything |
| [`docs/benchmarking-cn.md`](docs/benchmarking-cn.md) | How to measure throughput correctly + the current baseline |
| [`docs/clients-cn.md`](docs/clients-cn.md) | codex / Qwen Code setup, reasoning-effort semantics, rebuilding on a new machine |
| [`docs/auto-mitigation-cn.md`](docs/auto-mitigation-cn.md) | Crash-hardening spec: cgroup memory limit (this repo) + Prometheus alerting rules (homelab) |

### Design decisions

| Doc | Decision |
|---|---|
| [`docs/k3s-migration-design-cn.md`](docs/k3s-migration-design-cn.md) | Why k3s + Cilium, and the migration record. ⚠️ §6 (ClusterMesh) is **superseded — rejected 2026-08-13** |
| [`benchmarks/bench-full-2026-08-05/README.md`](benchmarks/bench-full-2026-08-05/README.md) | Performance baseline, and why the forum "NVFP4 KV" recipe was **rejected** |

## Repository layout

```
Makefile              single user-facing interface for every stack
CLAUDE.md             operational index (AGENTS.md, QWEN.md → symlinks)
k8s/                  live cluster: Cilium values, GPU plugin, v4flash manifests
config/               stack recipes (vLLM flags; rendered into k8s/v4flash/)
scripts/              launch / test / switch / repair helpers
playbooks/            Ansible: the two metrics exporters
docs/                 runbooks, reference, decisions
benchmarks/           measurement harnesses and dated reports
```

## Monitoring

Host metrics land in the **homelab** Grafana stack (`meirongdev/homelab`), not
here — Prometheus scrapes both nodes over Tailscale into the dashboard
*"DGX Spark / Node Exporter"*.

```bash
make node-exporter-deploy       # docker, :9100, both hosts
make smartctl-exporter-deploy   # systemd, :9633, both hosts (NVMe SMART)
```

That history is not decorative: it is what pinned down S2's death — temperatures,
load and free memory in the minutes before it stopped responding.

## Notes on the environment

- The servers are in **mainland China**. Foreign registries are blocked or crawl;
  pull images via the `docker.m.daocloud.io/…` prefix and models via ModelScope.
  See `docs/china-network-mirrors-cn.md`.
- SSH rides a flaky Tailscale DERP relay — wrap long remote work in tmux
  (`make tmux-cmd COMMAND="..." SESSION="..."`).
- Swap must stay disabled, and `gpu-memory-utilization` is deliberately
  conservative: 0.85 once OOM'd the head node hard enough to kill sshd.
