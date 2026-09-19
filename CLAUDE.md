# CLAUDE.md

Guidance for Claude Code (claude.ai/code) and other agents working in this repo.
`AGENTS.md` and `QWEN.md` are symlinks to this file.

**This file is an index, not the manual.** It carries what you need every session
(what runs where, how to drive it, what will bite you). Detail lives in `docs/` —
follow the pointers rather than guessing.

## Project Overview

Deployment tooling for vLLM inference across two NVIDIA DGX Spark (GB10
Blackwell) servers. Three stacks live here — one primary, two ways back:

| Stack | Nodes | Endpoint | Runtime | Status |
|---|---|---|---|---|
| **Qwen3.8-27B-Uncensored NVFP4** | **1** (S1) | `:8888` `qwen3.8-27b-sglang` | **SGLang** + DFlash2, docker | **primary** (since 2026-09-19) |
| Qwen3.8-Flash-Next NVFP4 | 2 (TP=2) | `:8000` `qwen38-flash-next` | k3s (vLLM) | rollback #1 — **fastest on code (62.1)** |
| GLM-5.3-Flash EXL3 4bpw | 2 (TP=2) | `:8888` `GLM-5.3-Flash-EXL3` | docker (upstream `start.sh`) | rollback #2 — 850K ctx |
| DeepSeek-V4-Flash-0731 | 2 (TP=2) | `:8000` `deepseek-v4-flash` | k3s (vLLM) | rollback #3 |
| Qwen3.8-27B-NVFP4 (censored) | 1 (S1) | `:8888` `qwen38-27b` | docker (vLLM, no speculator) | retired-ish — 24.9 tok/s |

⚠️ **All five are mutually exclusive** — same GPU memory. Even the single-node
ones: the TP=2 stacks' **rank0 also lives on S1**. Three of them claim `:8888`.
Stop the running one first; `make qwen38un-preflight` checks all of the others.

⚠️ **The primary is now single-node.** S2 sits idle, which removes the whole
TP=2 failure class (gotcha #1's zombie collectives, cross-node NCCL/RoCE, the
lockstep restart rule). It also means **`make memwatch` must be in docker mode**
(`MEMWATCH_STACK=qwen38un`) — `kubectl scale` cannot stop a docker container.

⚠️ **Three different engines are now in play** (vLLM / vLLM+EXL3 overlay /
SGLang) and **five different thinking-kwarg semantics**. There is no shared
default: see the table in `config/qwen38-uncensored-sglang.yaml`. Getting this
wrong is silent — `docs/stack-switch-cn.md` §0.

⚠️ **When you switch the primary stack, work `docs/stack-switch-cn.md`** — the
identity of "the current stack" is hardcoded in ~8 places across scripts, the
Makefile and client configs, and **every one of them fails silently**, not loudly.
Three separate wrong-number/wrong-verdict incidents have come from skipping this.

- **Flash-Next** (primary): NVFP4, native 262144 ctx, **MTP** speculative decoding
  (`num_speculative_tokens=3`), official vLLM image (no fork). Warm single-stream
  **35–66 tok/s depending on content** (mean 58.6, real code 62.1); concurrency
  peaks at **~304 tok/s aggregate at c8** (`max_num_seqs=8` is the binding limit,
  not KV). See `docs/benchmarking-cn.md` before quoting any number.
  ⚠️ **MTP `k` is not a free knob here:** k=4 measured **+12.2%** over the live k=3
  (adoption undecided), but **k=5–8 cannot start at all** — an upstream QSA assert
  demands `capacity | block_size 1616`, and block_size is engine-chosen, not tunable.
  Next feasible segment jumps to 9–12. `benchmarks/mtp-k-sweep-2026-09-03/`.
- **V4-Flash** (rollback target): 284B/13B-active, official FP8, 1M ctx, **DSpark**
  speculative decoding, jasl fork image. Mean 67.2 tok/s but **2.7× spread across
  content** (31–84) because DSpark acceptance is content-driven; Flash-Next beats
  it on concurrency (+29% at c6) and prefill (+100% at 100K). `make qwen38fn-rollback`.
- **Qwen3.8-27B** (single-node fallback): exists because both TP=2 stacks are
  indivisible — when one node dies the whole service dies (2026-08-15 S2 hardware
  death). **Slower and weaker, not an upgrade**: 24.9 tok/s mean.

**Target hosts** (edit `HOSTS` in Makefile to change):
- `100.97.87.120` — server 1 / `spark-ccf3` (TP=2 head / rank0 + the single-node fallback)
- `100.67.164.92` — server 2 / `spark-2435` (TP=2 worker / rank1; k3s server)
- SSH: `admin` + `~/.ssh/vgio`
- `192.168.200.101/102` — the internal 200G CX7 link. Carries the TP=2 NCCL
  traffic (bypassing the CNI) and inter-node file copies.

## Current state (2026-09-19) — Qwen3.8-27B-Uncensored + SGLang primary, single-node

**Two stack switches happened on 2026-09-19.** Flash-Next → GLM-5.3-Flash EXL3
(memory-tight, slower on code than the stack it replaced), then GLM → **Qwen3.8-27B
-Uncensored NVFP4 on SGLang + DFlash2, on one node**. Full numbers:
`benchmarks/qwen38un-2026-09-19/README.md`.

✅ **Concurrency is the best this repo has ever measured — on half the hardware.**
Peak **472.7 tok/s aggregate @ c12, single node** (Flash-Next 304 @ c8 on two
nodes; GLM 179.8 @ c4 on two). Host memory does not move across the whole ladder.
c16 falls back to 356 — that is `max_running_requests=12` making ragged batches
(12 + 4 stragglers), not a knee; same shape as Flash-Next's c10 artifact.

⚖️ **Single-stream is a mixed result.** Code **45.4** tok/s: +17% vs GLM's 38.8,
but **−27% vs Flash-Next's 62.1**. So "GLM is too slow" is only partly fixed —
**Flash-Next remains the fastest single-stream code stack in the repo.**
Also **−17% vs upstream's own 54.6** for the same recipe; partially explained
(compressed-tensors −3%, acceptance 6.12 vs upstream 6.71), plausibly the rest is
the DFlash2 draft being trained against the *stock* target while ours is
abliterated — **hypothesis, not verified.**

✅ **Uncensored verified** (`scripts/qwen38un-test.sh`): 3/3 benign-over-refusal
probes answered. The vendor's 64–99% → 0–6% harmful-refusal claim is **not**
independently verified here, and capability regression was not measured.

✅ **`make memwatch` can run again** (verified 40 s, no trigger, `available=9% (ok)`)
— but it is **not currently running**; start it in tmux to actually be guarded.
`mem-fraction-static` is **0.85**, not upstream's 0.90: at 0.90 S1 idled at
exactly **5.0%** and memwatch fired on its first tick (measured), i.e. no guard
at all. 0.85 gives **11.4 GiB (9.4%)** and cost **nothing measurable** — decode
is bit-identical (58.5 / 45.4 / 24.0) and matched concurrency levels are within
noise. The KV pool is still 1,368,663 tokens, 5.2× the 262144 context; 0.90 was
handing SGLang ~112 GiB when the weights are 24 GB. **Never 0.95** — upstream
hard-rebooted a box on it. Override chain: start.sh 0.95 → start-dflash.sh 0.90
→ our `DF_EXTRA` 0.85, argparse last-wins.

✅ **The TP=2 failure class is gone** with a single-node primary: no zombie
collectives (gotcha #1), no cross-node NCCL/RoCE, no lockstep restart rule. S2 is
idle at 116 GiB. k3s is running with all four k3s deployments at 0 replicas, so
`make qwen38fn-run` is a one-command rollback to the 62.1 tok/s stack.

⏳ **Quality debt is now three stacks deep** — aider-polyglot has been run against
V4-Flash only (`benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/`, 82.4%).
Flash-Next, GLM and this stack are all unmeasured.

✅ **Clients are switched and verified** (stack-switch layer 3 closed).
`codex --profile dgx` and `qwen` both point at `:8888` `qwen3.8-27b-sglang`.
Verified by **actually sending requests**, not just by reading the config:
qwen replied and the engine logged the hits (no `hard limit: 0` — the dotted
served name does *not* trip Qwen Code's 384k output reservation, which was the
open question); for codex the CLI's own `--version` hangs (pre-existing, it
never reads the profile), so the profile+catalog were parsed and the exact
request codex would send was replayed against `/v1/responses` → 200.

🔧 **Still open:** `CAP_MODEL`/port/kwargs in `scripts/gb10-clock-cap.sh` still
point at GLM.

### Previous state (earlier on 2026-09-19) — GLM-5.3-Flash EXL3

**Primary stack switched Flash-Next → GLM-5.3-Flash EXL3 4bpw on 2026-09-19**,
running the upstream MiaAI-Lab `start.sh` under plain docker. Speed is a clear
win; the open problem is host memory, not throughput.

✅ **Speed: meets or beats upstream on all three axes**
(`benchmarks/glm53-2026-09-19/README.md`):
decode structured **64.3** tok/s (upstream lab 62.9), concurrency **179.8** agg
at c4 (upstream 146.5, **+22.7%**), prefill flat at **1627–1653** tok/s from 22K
to 178K (above upstream at every comparable point). Boot invariants match
upstream *exactly* — weights 82.05 GiB, KV pool 883,552 tokens, 1.04×.
Our kit does **not** reproduce upstream issue #163's 2× decode slowdown, even
though it is on the same `PYNCCL` cross-node all-reduce path.

⚠️ **Host headroom is 2.1–2.5 GiB (1.8–2.0%) — upstream reports ~5 GiB for the
same config, and calls this band "not enough margin on this UMA".**
Consequences, both live:
- **`make memwatch` cannot run** (1.8% < CRIT 5%, it fires on startup) → there
  is currently **no OOM guard**, and these boxes have no BMC.
- **`MAX_MODEL_LEN=850000` is nominal, not reachable.** Prefill host memory is
  superlinear (89K ≈ 0.2 GiB, 178K ≈ 1.4 GiB); one cold prompt tops out around
  **180–220K**. 256K was deliberately not attempted.
Context trades 1:1 against headroom via `--kv-cache-memory-bytes`: 850K→2.1 GiB,
700K→~5.0, 600K→~6.6 (the first point where memwatch works). **Not yet decided.**
The gap vs upstream is *not* docker-vs-k3s — stopping k3s entirely was measured
at **+0.11 GiB** on the head. It is `zcode` (~1.07 GiB) + desktop (~0.4) on S1,
plus the head being 1.71 GiB heavier than the worker by nature.

⏳ **Quality is unverified — and this debt is now two stacks deep.** EXL3 4bpw's
KLD 0.0246 (≈ official FP8) is malaiwah's independent panel, not ours.
aider-polyglot has been run against *neither* GLM nor Flash-Next. V4-Flash
baseline: `benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/` (82.4%).

🔧 **Transient host state (restore when done):** k3s is **stopped on both nodes**
(`sudo systemctl start k3s` on S2, `k3s-agent` on S1) — until then the two k3s
rollback stacks cannot start. Graphical session and `sparkDash` also stopped.
**Clients have NOT been switched** — codex/qwen still point at `:8000`
`qwen38-flash-next`, which is down. `docs/stack-switch-cn.md` layer 3 is open.

Earlier state (S2's 2026-08-15 power death and the 6.5 h recovery — no BMC/IPMI,
WoL failed, needed someone at the box) is post-mortem'd in
`docs/qwen38-27b-fallback-cn.md` §1 and §7.

## Common Commands

### GLM-5.3-Flash EXL3 (primary, plain docker — NOT k3s)

Runs the upstream `start.sh` on S1 at `/home/admin/glm53-exl3` (pinned to
commit `8f29c6dd`, which matches the shipped image). `.env` there is the live
parameter source; `config/glm53-flash-exl3.yaml` records our 6-line delta and why.

```bash
make glm53-run        # preflight (4-way mutual exclusion + weights + image +
                      #   HOST MEMORY GATE) then start.sh inside tmux. ~5 min.
make glm53-status     # containers + /v1/models + free -h
make glm53-boot-log   # this boot's start.sh output (glm53-logs is the engine)
make glm53-logs       # head;  glm53-logs-worker for rank1 (over the 200G link)
make glm53-stop       # ./start.sh stop — stops BOTH ranks
make glm53-restart    # stop + run
```

⚠️ **Never run `./start.sh` by hand — always `make glm53-run`.** Without
`SKIP_BUILD=1` the launcher decides the image recipe stamp is stale and
**rebuilds the image on S1**, which is the thing that OOM'd the head on
2026-07-04. And that stamp can *never* match: `overlay_recipe_hash()` feeds
absolute paths to `sha256sum`, so it depends on where the repo is checked out
(measured: same content at two paths → two different hashes). Its
`stamp X != repo Y` warning is permanent noise, not a signal.

⚠️ **The host-memory gate exists because the first boot failed on it.** S2's
`polkitd` had grown to 6.27 GiB RSS, leaving 103.09 GiB free vs the 103.44 GiB
that `gpu-memory-utilization` wanted — short by 0.35 GiB, and it only surfaced
3 minutes in as a CUDA-layer `ValueError`. Fix: `sudo systemctl restart polkit`.
Upstream hit the same polkitd growth (their issue #193).

### Qwen3.8-Flash-Next (rollback target #1, k3s)

kubectl runs from **this machine** — `~/.kube/dgx-spark.yaml`.

```bash
make qwen38fn-run       # preflight (mutual-exclusion self-check + drop_caches) then
                        #   scale both ranks to 1 — loads 8-11 min (126 GiB NVFP4)
make qwen38fn-status    # pods + /v1/models
make qwen38fn-test      # smoke test + tool-call parser check (NOT a benchmark)
make qwen38fn-load      # who is using the engine now (running/waiting, KV%, client IPs)
make qwen38fn-logs      # leader (rank0);  qwen38fn-logs-worker for rank1
make qwen38fn-restart   # recreate BOTH ranks (never restart one alone)
make qwen38fn-stop      # scale both to 0
make qwen38fn-rollback  # stop Flash-Next, then `make v4flash-run` (~5 min)

make ple-test           # end-to-end regression for the PLE FP8 patch + preflight
                        #   ⚠️ MUST run before touching patch-ple-fp8.py /
                        #   ple-preflight.py — they guard a SILENT quality
                        #   degradation (51 GiB PLE table upcast to bf16 with no
                        #   scale: model still serves, quality quietly drops)
```

### V4-Flash (rollback target, k3s)

Kept runnable during the Flash-Next observation window — do not delete its weights
or image.

```bash
make v4flash-run        # scale both ranks to 1 (loads ~5min)
make v4flash-status     # pods + /v1/models
make v4flash-test       # coding smoke test + tok/s
make v4flash-load       # who is using the engine now
make v4flash-logs       # leader (rank0);  v4flash-logs-worker for rank1
make v4flash-restart    # recreate BOTH ranks (never restart one alone)
make v4flash-stop       # scale both to 0

make probe-test         # unit-test the liveness probes locally
make probe-apply        # push probe scripts via ConfigMap — no pod restart
make probe-verify       # run the live probes by hand inside both pods
```

⚠️ **Never restart a single rank, on either TP=2 stack** — it leaves the survivor
hung in collectives while `/health` and `/v1/models` still return 200. This is a
property of TP=2, not of any one engine. Gotcha #1 in `docs/gotchas-cn.md`.

### Qwen3.8-27B (single-node fallback, plain docker on S1)

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

## Host OS maintenance (apt / driver / kernel / DKMS)

⚠️ **Read `docs/host-maintenance-cn.md` before any `apt upgrade` on these hosts.**
Four rules, each already paid for: stop the stack first (`network-manager`
restarts NM → blips the 200G NCCL link, but SSH survives, so it misreads as "vLLM
crashed"); upgrade inside tmux with `--force-confold`; `apt-get -s upgrade` first
and read every `Inst` line (the CUDA repo sits at Ubuntu's priority and can win a
driver decision); `dkms` always with `-a arm64` (bare `dkms` silently no-ops —
this nearly bricked a node on 2026-08-08).

## Architecture (both TP=2 stacks)

```
┌─ k3s cluster "dgx-spark" (cluster.id=1, Cilium CNI) ─────────┐
│  ┌──────────────────┐  200G CX7  ┌──────────────────┐        │
│  │ S1 spark-ccf3     │ ◄────────► │ S2 spark-2435     │       │
│  │ 192.168.200.101   │ RoCE/NCCL  │ 192.168.200.102   │       │
│  │ k3s agent         │   TP=2     │ k3s server        │       │
│  │ Pod <stack>-leader│ (bypasses  │ Pod <stack>-worker│       │
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

Both TP=2 stacks have this exact shape — only the namespace and Pod prefix differ
(`qwen38fn-*` in ns `qwen38fn`, `v4flash-*` in ns `v4flash`). The single-node
fallback is a plain-docker container on S1 `:8888`, outside k3s.

## Unified memory constraints (GB10) — read before changing any launch flag

- 128 GB LPDDR5X coherent memory shared between CPU and GPU, per node.
- **Don't over-allocate `gpu-memory-utilization`** — too high risks OOM freezes
  of sshd itself. **Flash-Next uses 0.75**, V4-Flash **0.80** (0.85 caused a full
  head-node OOM on 2026-06-29), the single-node fallback **0.75**, the retired
  Qwen/Gemma stack **0.70**. Flash-Next went 0.80 → 0.75 on 2026-09-02 because
  `scripts/mem-floor.sh` measured 8-way × 8K prompt leaving only 5 GiB host
  available (4.1%, below the memwatch CRIT line) at 0.80 — and the KV it bought
  cannot be used anyway under `max_num_seqs=8`. **Re-run mem-floor before raising
  it, and keep both nodes symmetric.**
- Swap **must** be disabled (`swapoff -a`).
- `nvidia-smi` reports `[N/A]` for per-process memory on GB10; watch `free -h`.
- **Never build on S1 without stopping the running stack first** — even the
  "lightweight" prebuilt-wheel path compiles native deps from source and OOM'd
  the head node on 2026-07-04, taking the whole tmux server down with it.
- **Host memory watchdog** (`make memwatch`, run it in tmux) scales BOTH ranks to
  0 before a node OOMs — vLLM's ~100 GB pre-allocation bypasses the container
  cgroup on GB10, so node-level available memory is the only signal that sees it.
  No auto-restore; bring it back with `make qwen38fn-run`. ⚠️ The watchdog
  targets one stack by name — `MEMWATCH_STACK` in the Makefile (now `qwen38fn`). A k8s cgroup memory
  limit was tried and **rejected** — `docs/auto-mitigation-cn.md`.

## GB10 host tuning (clock cap adopted 2026-08-25)

Full A/B data + the do-not-touch list: `docs/gb10-tuning-cn.md`.

- **GPU clock cap 2200 MHz is live on both nodes** via `gb10-clock-cap.service`
  (installed + enabled 2026-08-25; the unlock → `systemctl restart` → re-locked
  path is verified). Decode paired diff +0.9%, 95% CI [-1.9%, +3.7%] (n=11
  interleaved, `min_tokens` fixed) → indistinguishable from zero; prefill -3.7%;
  dual-node GPU-rail power 86.2 W → 55.2 W (wall-socket saving is much smaller:
  `nvidia-smi` sees only 12-27% of real draw). Drive it with
  `make clock-cap-{apply,verify,status,install,reset,uninstall}`.
- ⚠️ **Both nodes must match** (TP=2 is lockstep), **`-lgc` dies on reboot**
  (hence `clock-cap-install`), and **no nvidia-smi field reports an active lock**
  (`Applications Clocks Setting` stays `Not Active`, `clocks.max.sm` stays 3003) —
  the only check is `clocks.current.sm` *under load* = `make clock-cap-verify`.
- ⚠️ **That check itself was silently broken from 2026-09-02 to 2026-09-03** — it
  had the old stack's model name hardcoded, so its generation 400'd, `curl` still
  exited 0, and it printed a verdict line computed from **idle** samples (which
  look identical to a working lock). Fixed: model name is `CAP_MODEL`, and the
  script now hard-fails unless it really generated ≥50 tokens. Lesson, generalized
  in gotcha #9: a checker that cannot tell "pass" from "never ran" is worse than
  no checker.
- **What GB10 does not expose at all:** power limits (`-pl`/`-ac` → all N/A),
  ECC toggle, FB memory usage, fan control, Jetson-style `nvpmodel`. Don't hunt.
- ❌ **Second QSFP cable: tested and dismissed 2026-08-25.** Both ports are cabled;
  the community reports unplugging one takes NCCL 10.25 → 22.1 GB/s. It does **not**
  reproduce here: prefill 1731 → 1734 tok/s (**+0.17%**) with the second port down on
  both nodes. Consistent with `lspci` — the two ports sit on *separate* x4 Gen5 links
  in separate PCIe domains, so the "two cables split one x4" mechanism doesn't apply.
  **Leave both cables in.** `docs/gb10-tuning-cn.md` §6 — that section was corrected
  three times, and the standing lesson is: someone else's GB10 perf result is a
  hypothesis until it reproduces on these boxes.

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

Current baseline: **`benchmarks/glm53-2026-09-19/`** (GLM, with the upstream
comparison and its own three scripts). Previous: `benchmarks/bench-full-qwen38fn-2026-09-03/`
(Flash-Next vs V4). Harness + V4 baseline: `benchmarks/bench-full-2026-08-05/`.

⚠️ **`bench_full.py` does not work on GLM at all** — it hardcodes V4-Flash's
model name *and* a `thinking` kwarg, while GLM is a **third** semantics:
`chat_template_kwargs.reasoning_effort` (`low`/`high`/`max`; `medium` rejected),
**no way to turn thinking off**, unset renders **Max**, and the CoT comes back
in `reasoning`, not `reasoning_content`. Use the scripts in
`benchmarks/glm53-2026-09-19/`. See `docs/stack-switch-cn.md` layer 2.

Two traps this stack added to the pile, both measured on 2026-09-19:
- **First request at a new prompt shape is ~43% slow** *and* costs one-time host
  memory (22K prefill: 1141 tok/s first, 1630 warm). Always say which you quote.
- **Prefill host memory is superlinear** (89K ≈ 0.2 GiB, 178K ≈ 1.4 GiB) while
  throughput stays flat — so a prefill ladder must guard memory *in flight*,
  not just between levels.

## Connecting from clients

All stacks are **unauthenticated** vLLM and serve `/v1/chat/completions` **and**
`/v1/responses`. Full setup, per-stack reasoning-effort semantics, the
`contextWindowSize` hard-limit-0 trap and how to rebuild on a new machine:
**`docs/clients-cn.md`**.

```bash
codex --profile dgx        # → :8888 qwen3.8-27b-sglang  (primary, since 2026-09-19)
codex --profile qwen38     # → :8888 qwen38-27b          (stock 27B, no speculator)
qwen                       # boot default; ./scripts/qwen-model-switch.sh sglang to flip
```

⚠️ Thinking kwargs **and** the CoT response field differ per stack
(`thinking`/`enable_thinking`, `reasoning_content`/`reasoning`) — both fail
*silently*, see gotcha #9. And
codex/qwen's built-in `reasoning:false` does **not** reach a self-hosted vLLM.

## Key file map

**Entry points**
- `README.md` — human entry point and doc map.
- `Makefile` — the single user-facing interface for every stack.

**Live cluster**
- `k8s/` — `README.md` (versions + ops + traps), `registries.yaml`,
  `cilium-values.yaml`, `gpu/` (RuntimeClass + vendored device plugin),
  `qwen38fn/` (**primary**) and `v4flash/` (rollback) — each a ConfigMap with the
  per-rank launch scripts, two Deployments and a Service.
- `config/qwen38-flash-next.yaml` — **primary** recipe: the source of truth for the
  **vLLM flags only**. Live launch commands are `k8s/qwen38fn/configmap-launch.yaml`
  (rendered from it). **Change both together.**
- `config/deepseek-v4-flash.yaml` — same relationship to `k8s/v4flash/`.

**Scripts** (⚠️ those marked **[stack-bound]** hardcode a default stack identity —
`docs/stack-switch-cn.md` is the complete list)
- `scripts/qwen38fn-test.sh` — **primary** smoke test + tool-call parser check
  (`make qwen38fn-test`). A smoke test, *not* a benchmark. **[stack-bound]**
- `scripts/qwen38fn-fetch-weights.sh` / `qwen38fn-import-image.sh` — one-time
  126 GiB checkpoint fetch and the two-node image import.
- `scripts/mem-floor.sh` — host-memory floor stress test; the evidence behind
  `gpu_memory_utilization 0.75`. **Re-run it before raising gmu or max_num_seqs.**
- `scripts/v4-test.sh` — coding smoke test for the rollback stack (one short
  prompt — a smoke test, *not* a benchmark). **[stack-bound]**
- `scripts/qwen38-start.sh` / `qwen38-test.sh` — fallback stack launch + benchmark
  (`make qwen38-run` / `qwen38-test` rsync these to S1).
- `scripts/qwen-model-switch.sh` — flips the Qwen Code **boot default** between
  stacks (four fields across three files must agree — see `docs/clients-cn.md`).
- `scripts/mem-watch.sh` — host memory watchdog (`make memwatch*`); the stack it
  guards is `MEMWATCH_STACK` in the Makefile. **[stack-bound]**
- `scripts/gb10-clock-cap.sh` — GPU clock cap apply/verify/install. Its `verify`
  drives a real generation, so it carries `CAP_MODEL`. **[stack-bound]**
- `scripts/test-liveness-probe.py` — probe unit tests (`make probe-test`); the
  live probes themselves ship in each stack's `configmap-launch.yaml`.
- `scripts/vllm-fix-torch.sh` — fixes the torch-CPU build trap.
- `scripts/v2rayn-launch.sh` — revives the S1 v2rayN proxy (needed for github
  clones during a V4-Flash build).
- `scripts/modelscope-download.sh` — model download via `make modelscope-download`.

**Docs** (see `README.md` for the full map)
- `docs/gotchas-cn.md`, `docs/benchmarking-cn.md`, `docs/clients-cn.md` —
  the three split out of this file.
- **`docs/stack-switch-cn.md` — the primary-stack switch checklist. Read it
  before and after any switch; it is the anti-recurrence mechanism for the
  silent-staleness class of bug.**
- `docs/deepseek-v4-flash-cn.md`, `docs/dspark-upgrade-cn.md` — the rollback stack.
- `docs/qwen38-27b-fallback-cn.md` — single-node fallback + the S2 post-mortem.
- ⚠️ **Flash-Next has no runbook doc yet** — the primary stack's reasoning lives in
  `config/qwen38-flash-next.yaml`'s comments and `k8s/qwen38fn/`. Known gap.
- `docs/k3s-migration-design-cn.md` — cluster design (⚠️ §6 superseded).
- `docs/host-maintenance-cn.md` — apt / driver / kernel / DKMS runbook.
- `docs/gb10-tuning-cn.md` — GB10 host tuning: GPU clock cap (adopted 2026-08-25), non-existent knobs, do-not-touch list.
- `docs/auto-mitigation-cn.md` — memory watchdog + alerting spec.
- `docs/china-network-mirrors-cn.md` — mirror runbook.
- `benchmarks/bench-full-qwen38fn-2026-09-03/` — **current** baseline (Flash-Next
  + the V4 comparison). `benchmarks/bench-full-2026-08-05/` — the harness itself
  and the V4 baseline.
- `benchmarks/mtp-k-sweep-2026-09-03/` — MTP `k` sweep: why `tok/step` (counted) is
  the load-bearing number when a knob needs an engine restart, and the QSA assert
  that caps `k` at 4. Its harness (`mtp_arm.py`) is the reusable pattern for any
  **restart-required** knob, where interleaved pairing is physically impossible.

**Monitoring**
- `playbooks/node-exporter-deploy.yml`, `playbooks/smartctl-exporter-deploy.yml`.

## Conventions

- Docs in `docs/` are Chinese (`-cn.md`) with all commands, error strings and
  identifiers verbatim in English. This file stays English.
- Images on both servers: **Flash-Next `vllm-qwen38fn:latest`** (official
  `vllm/vllm-openai:qwen38-flash-next`, pinned by RepoDigest in the recipe — the
  PLE patch is tied to a specific image version, so tag drift makes it silently
  mismatch); V4-Flash `vllm-node-dsv4:latest` (jasl fork build); single-node
  fallback upstream `vllm/vllm-openai:nightly-aarch64`. Driver 580.173.02 /
  CUDA 13.0, verified on both nodes 2026-09-02.
- Host baseline (both nodes, verified 2026-09-02): kernel `6.17.0-1031-nvidia`
  (`1029` + `1014` kept as fallback), driver `580.173.02`, swap 0, clock cap
  active. S2 was brought from `1029` to `1031` on 2026-09-02 — the narrow path
  (`apt-get install linux-nvidia-hwe-24.04 linux-modules-nvidia-580-open-nvidia-hwe-24.04`,
  14 `linux-*` packages, 0 removals) rather than a full `apt upgrade`, which would
  have pulled **NCCL 2.30.7 → 2.31.2** from the CUDA repo onto one node only.
  ⚠️ The nvidia branch-guard pin does **not** cover `libnccl*` or
  `nvidia-container-toolkit` — always read every `Inst` line.
- SSH strict host key checking is disabled (automation).
- Ansible (the two monitoring exporter playbooks): always `uv run ansible` / `uv run ansible-playbook`;
  to add/remove hosts edit `HOSTS` in the Makefile then `make inventory`.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `perf:`).
- **Any change that moves which stack is primary must update this file's stack
  table and `## Current state` in the same commit.** 091b6e4 switched the primary
  stack and touched no docs at all; CLAUDE.md then told every agent session the
  wrong primary for 24 h, which is how the clock-cap check came to be silently
  broken. `docs/stack-switch-cn.md` is the checklist.
