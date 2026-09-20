# nv-dgx-spark

Deployment tooling for vLLM inference on a two-node **NVIDIA DGX Spark (GB10
Blackwell)** cluster — 128 GB unified memory per node, joined by a 200G ConnectX-7
link, reachable over Tailscale.

Everything is driven through the `Makefile`. Detailed runbooks live in `docs/`
(Chinese prose, commands and identifiers in English).

---

## What runs here

Every model is a **stack** in the `stacks/` registry. This table is generated
from it by `make stack-table` — don't hand-edit it.

<!-- BEGIN generated:stacks -->
| 栈 | 节点 | 端点 | 引擎 / 运行时 | 状态 |
|---|---|---|---|---|
| **Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2**<br>`STACK=qwen38un` | 1 | `:8888` `qwen3.8-27b-sglang` | sglang / docker | **primary (2026-09-19 起)** |
| Qwen3.8-Flash-Next NVFP4 单机 (PLE mmap + hybrid)<br>`STACK=fndgx` | 1 | `:18300` `qwen3.8-flash-next` | vllm-ple-mmap / docker | S2 常驻 —— 与主力栈并跑 |
| GLM-5.3-Flash EXL3 4bpw<br>`STACK=glm53` | 2 | `:8888` `GLM-5.3-Flash-EXL3` | vllm-exl3 / docker | 唯一 rollback —— 850K ctx |
| Qwen3.8-27B-NVFP4 (censored, no speculator)<br>`STACK=qwen38` | 1 | `:8888` `qwen38-27b` | vllm / docker | retired-ish —— 24.9 tok/s |
<!-- END generated:stacks -->

> ⚠️ **No two of these can run at the same time** — they want the same GPU
> memory, and several share a port. `make run` refuses to start while another
> stack is up; its preflight walks the whole registry.

> **Switching which stack is primary?** `make switch TO=<id>`. "Which stack is
> current" used to be hardcoded in ~8 places that each failed *silently* — three
> wrong-number incidents came from that. It is now one file, `stacks/PRIMARY`,
> and `make stack-check` fails when the docs drift from it.
> `docs/stack-switch-cn.md` covers what is still manual.

**Why a single-node fallback exists:** the TP=2 stacks are indivisible — the
weights don't fit one node, so when either machine dies the whole service dies.
That happened on 2026-08-15 (`docs/s2-outage-2026-08-15-cn.md`). The fallback
keeps a slower, weaker model serving on whichever node survives.

**Hosts** — `100.97.87.120` (S1 / `spark-ccf3`) and `100.67.164.92`
(S2 / `spark-2435`), SSH as `admin` with `~/.ssh/vgio`.

---

## Quick start

One set of verbs drives every stack; `STACK=` picks the target, and leaving it
off means whatever `stacks/PRIMARY` says.

```bash
make stacks                    # the registry: who's primary, ports, served names
make info                      # current primary in detail

make run                       # preflight (mutual exclusion) + start the primary
make status                    # containers + /v1/models + free -h
make test                      # smoke test, gated on the served name matching
make logs   STACK=glm53 WORKER=1   # rank1 — glm53 is the only multi-node stack left

make switch TO=glm53           # change the primary stack, with acceptance checks
make stack-check               # registry self-consistent + doc tables current

# use it
codex --profile dgx
qwen                           # ./scripts/qwen-model-switch.sh flips the boot default
```

**Adding a model?** `stacks/README.md` — create `stacks/<id>/`, fill one
`stack.env`, change nothing else.

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

### Per-stack — lives with the stack, not in `docs/`

| Where | What's in it |
|---|---|
| **[`stacks/README.md`](stacks/README.md)** | **The contract: what adding a model requires (one `stack.env`, no edits elsewhere)** |
| `stacks/<id>/recipe.yaml` | Why this stack's parameters are what they are, with the measurements. Every stack has one |
| [`stacks/qwen38/runbook-cn.md`](stacks/qwen38/runbook-cn.md) | Single-node fallback: deploy from scratch, the traps |
| [`stacks/fndgx/runbook-cn.md`](stacks/fndgx/runbook-cn.md) | Flash-Next single-node on S2: from-zero procedure |
| ⚠️ *(gap)* | `glm53` / `qwen38un` have no runbook — only `recipe.yaml` comments |

### Runbooks — shared across stacks

| Doc | What's in it |
|---|---|
| **[`docs/stack-switch-cn.md`](docs/stack-switch-cn.md)** | **What `make switch` can't do for you — plus the three silent incidents that explain why the registry exists** |
| [`docs/s2-outage-2026-08-15-cn.md`](docs/s2-outage-2026-08-15-cn.md) | S2's hardware death, why WoL failed (**no BMC on these boxes**), TP=2 recovery |
| [`docs/host-maintenance-cn.md`](docs/host-maintenance-cn.md) | Host OS: apt / NVIDIA driver / kernel / DKMS — **read before any `apt upgrade`** |
| [`docs/gb10-tuning-cn.md`](docs/gb10-tuning-cn.md) | GB10 host-level tuning: the GPU clock cap A/B (adopted), the knobs that don't exist, and what not to touch |
| [`docs/china-network-mirrors-cn.md`](docs/china-network-mirrors-cn.md) | daocloud / ModelScope / Tsinghua mirrors from mainland China |

### Reference — read before you need it

| Doc | What's in it |
|---|---|
| [`docs/gotchas-cn.md`](docs/gotchas-cn.md) | **10 traps, each paid for in downtime.** Scan the headings before debugging anything |
| [`docs/benchmarking-cn.md`](docs/benchmarking-cn.md) | How to measure throughput correctly + the current baseline |
| [`docs/clients-cn.md`](docs/clients-cn.md) | codex / Qwen Code setup, reasoning-effort semantics, rebuilding on a new machine |
| [`docs/auto-mitigation-cn.md`](docs/auto-mitigation-cn.md) | Crash-hardening spec: cgroup memory limit (this repo) + Prometheus alerting rules (homelab) |

### Design decisions

| Doc | Decision |
|---|---|
| [`docs/k3s-migration-design-cn.md`](docs/k3s-migration-design-cn.md) | Why k3s + Cilium, and the migration record. ⚠️ **History only — the cluster was uninstalled 2026-09-20**; §6 (ClusterMesh) was already **rejected 2026-08-13** |
| [`benchmarks/bench-full-2026-08-05/README.md`](benchmarks/bench-full-2026-08-05/README.md) | Performance baseline, and why the forum "NVFP4 KV" recipe was **rejected** |

## Repository layout

```
Makefile              generic verbs (run/stop/status/logs/test/switch); knows no stack names
CLAUDE.md             operational index (AGENTS.md, QWEN.md → symlinks)
stacks/               THE REGISTRY — one directory per model
  PRIMARY               one line: which stack is primary
  _lib/                 stackctl + the docker adapter + whole-registry preflight
  <id>/                 stack.env (identity) + recipe.yaml (why) + optional hooks
scripts/              cross-stack tools — none hardcodes a stack identity
playbooks/            Ansible: the two metrics exporters
docs/                 only what is SHARED across stacks (per-stack docs live in stacks/<id>/)
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
