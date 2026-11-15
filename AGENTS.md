# AGENTS.md

Operating guide for AI agents (and humans) working in this repo. `CLAUDE.md`,
`QWEN.md` and `.github/copilot-instructions.md` are symlinks to this file.

This file carries only what every session needs: what runs where, the rules that
prevent outages, and where the detail lives. **Follow the pointers instead of
guessing.** Dated narrative belongs in `stacks/<id>/notes.md` or `docs/`, not here.

## What this repo is

Deployment tooling for LLM inference on two NVIDIA DGX Spark boxes (GB10 Blackwell,
128 GB unified CPU+GPU memory each) in mainland China. Every model is a **stack** in
the `stacks/` registry; one is primary, the rest are rollbacks. The `Makefile`
drives all of them over SSH with plain `docker run` — there is no orchestrator
(k3s was uninstalled 2026-09-20).

| Host | Name | Role |
|---|---|---|
| `100.97.87.120` | S1 / `spark-ccf3` | head + API of the TP=2 stacks; NFS server |
| `100.67.164.92` | S2 / `spark-2435` | rank1 of the TP=2 stacks |

- SSH: `admin@<host>` with `~/.ssh/vgio`, over Tailscale (a flaky DERP relay).
  Strict host-key checking is off for automation.
- `192.168.200.101/102` is the 200G CX7 link between the boxes (second rail:
  `192.168.201.0/24`). It carries TP=2 traffic and large file copies.
- **No BMC / IPMI, and Wake-on-LAN does not work.** A box that OOMs or loses
  power needs a person at it (`docs/s2-outage-2026-08-15-cn.md`).

## Hard rules

Each rule has already cost an outage or a wrong conclusion. `#n` = entry in
`docs/gotchas-cn.md`.

1. **Never restart one rank of a TP=2 stack.** The survivor hangs in collectives
   while `/health` and `/v1/models` keep returning 200. Use `make restart`, which
   moves both ranks. (#1)
2. **Never start a stack that shares a GPU node with a running one.** Use
   `make run`: its preflight checks node-set overlap (`STACK_GPU_NODES`) across the
   whole registry. A TP=2 stack occupies both boxes. (#2)
3. **Never build images or copy large files onto S1 while a stack serves.** A build
   OOM'd the head on 2026-07-04; a 5.8 GB copy trips upstream memguard. Stop first.
4. **Don't raise memory knobs** (`gpu-memory-utilization`, `mem-fraction-static`,
   KV/pool size, seats) without `scripts/mem-floor.sh` and a *steady-state*
   MemAvailable reading — boot headroom decays. Swap stays off. Keep nodes symmetric.
5. **Read `docs/host-maintenance-cn.md` before any `apt upgrade`.** Stop the stack;
   run in tmux with `--force-confold`; read every `Inst` line of `apt-get -s upgrade`;
   always `dkms … -a arm64` (bare `dkms` silently no-ops).
6. **Wrap long remote commands in tmux** (`make tmux-cmd`); SSH drops.
7. **GPU clock cap: both nodes or neither.** A one-node cap silently drags a TP=2
   pair to the slower rank. (`make clock-cap-install`)
8. **Never hardcode a stack identity** (served name, thinking kwarg, CoT field,
   port) in a tool — read the registry. SGLang and TensorFold answer *any* model
   name with 200, so a wrong name does not fail. (#9, #10)
9. **Prove it with real output.** A real generation (count the tokens), not just
   `/v1/models` or an exit code. A check that cannot tell "passed" from "never ran"
   is worse than none. When recording a change, paste the measured output.
10. **After patching a long-running process** (watchdog, tmux loop, sidecar),
    restart it and read its startup banner. The node-resident watchdog runs a copy:
    re-run `make memwatch-install` after editing `scripts/mem-watch.sh` or a `stack.env`.
11. **The primary is production.** Homelab services and coding agents depend on it;
    stopping or restarting it is an outage.

## Stacks

<!-- BEGIN generated:stacks -->
| 栈 | 节点 | 端点 | 引擎 / 运行时 | 状态 |
|---|---|---|---|---|
| **DeepSeek-V4.1-Flash-1017 EXL3 2.9bpw 双机 TP=2 (MiaAI-Lab recipe, TensorFold Zig, DSpark 草稿)**<br>`STACK=dsv41` | 2 | `:8000` `DeepSeek-V4.1-Flash-1017` | tensorfold-zig / docker | **primary (2026-11-14 起) —— 占两台 TP=2** |
| GLM-5.3-Flash EXL3 4bpw<br>`STACK=glm53` | 2 | `:8888` `GLM-5.3-Flash-EXL3` | vllm-exl3 / docker | rollback (TP=2, GLM) —— 850K ctx |
| Qwen3.8-Flash-Next NVFP4 单机 (bilikaz hibrid48, K=5 MTP)<br>`STACK=hibrid48` | 1 | `:18300` `qwen3.8-flash-next` | vllm-hibrid48 / docker | rollback (S2 单机) —— 2026-09-30 让位给 hibrid48tp2 |
| Qwen3.8-Flash-Next NVFP4 双机 TP=2 (myllmbox cluster hibrid48, K=5 MTP)<br>`STACK=hibrid48tp2` | 2 | `:8000` `qwen3.8-flash-next-tp2-v41` | vllm-hibrid48-cluster / docker | rollback (kit v4.1) —— 2026-10-22 让位给 hibrid48tp2v52 |
| Qwen3.8-Flash-Next hibrid48 双机 TP=2 (myllmbox cluster kit v5.2, K≤7 动态 MTP)<br>`STACK=hibrid48tp2v52` | 2 | `:8000` `qwen3.8-flash-next-tp2` | vllm-hibrid48-cluster-v52 / docker | rollback (kit v5.2) —— 2026-11-14 让位给 dsv41 |
| Qwen3.8-27B-NVFP4 (censored, no speculator)<br>`STACK=qwen38` | 1 | `:8888` `qwen38-27b` | vllm / docker | retired-ish —— 24.9 tok/s |
| Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2<br>`STACK=qwen38un` | 1 | `:8888` `qwen3.8-27b-sglang` | sglang / docker | rollback (S1 单机) —— 2026-09-30 让位给 hibrid48tp2 |
<!-- END generated:stacks -->

The table is generated from `stacks/*/stack.env` by `make stack-table`, and
`make stack-check` fails when it drifts. Don't hand-edit it.

- `stacks/PRIMARY` is the **only** place that says which stack is primary. Change it
  with `make switch TO=<id>`, never by hand.
- Ports are shared (`:8000`, `:8888`, `:18300`); only the served name identifies a
  backend.
- Five engines (vLLM, vLLM+EXL3, SGLang, vLLM+PLE-mmap, TensorFold Zig) with
  different thinking kwargs and CoT response fields. Read `STACK_THINK_KWARG` /
  `STACK_THINK_OFF` / `STACK_COT_FIELD` (`make info STACK=<id>`). **Never infer them
  from the model name** — the same checkpoint has returned different CoT fields on
  two engine builds.
- Per-stack detail: `stacks/<id>/recipe.yaml` (why the parameters are what they are),
  `stacks/<id>/notes.md` (how to operate it + dated history), `runbook-cn.md` where
  present.
- `qwen38fn` and `v4flash` were deleted with k3s on 2026-09-20; they exist only in
  git history (`docs/k3s-migration-design-cn.md` §12).

Rollback traps worth knowing before you start one:

- `glm53` — only via `make run STACK=glm53`. The raw upstream `start.sh` without
  `SKIP_BUILD=1` rebuilds the image on S1 (OOM). Host headroom 1.8–2.0%: the
  watchdog cannot run on it.
- `hibrid48tp2` / `hibrid48tp2v52` — same container name, so they exclude each
  other; `run.sh` waits for ≥100 GB free on both boxes before creating it.
- `hibrid48` — needs `vm.compaction_proactiveness=0` on S2; idles at ~2.4%
  available by design (watchdog thresholds 3/1%).

## Current state (2026-11-15)

**Primary: `dsv41`** — DeepSeek-V4.1-Flash-1017 (EXL3 2.9 bpw + Engram tables) on
the TensorFold Zig engine, TP=2. API on S1 `:8000`, served name
`DeepSeek-V4.1-Flash-1017`; rank1 on S2. Upstream recipe
`MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks` @ `c7f2b85` runs as-is from
`/home/admin/dsv41-recipe` on S1; our only deviations are in
`stacks/dsv41/local.sh`. Full account: `stacks/dsv41/notes.md` + `recipe.yaml`.

- Config: `CONTEXT=262144`, `POOL=2097152`, `PARALLEL=8`. **8 streams is on trial**
  (at POOL 1M it was worse than 4). Rollback trigger: S1 MemAvailable < 3.5 GiB. If
  2M + 8 streams does not beat 4, go to `PARALLEL=4` and keep POOL at 2M.
- Thinking is **on** by default. Only `chat_template_kwargs.enable_thinking`
  toggles it; CoT comes back in `reasoning_content`.
- ⚠️ TensorFold accepts any model name, so homelab clients still asking for
  `qwen3.8-flash-next-tp2` are **silently** served by DeepSeek. Homelab follow-up is
  not done: `~/projects/homelab/docs/runbooks/dgx-model-swap-homelab-followup.md`.
  Homelab's `vllm:*` scrape and alerts see nothing (TensorFold exports `tensorfold:*`).
- codex needed profile changes beyond the model name (TensorFold's `/v1/responses`
  accepts function tools only): `docs/clients-cn.md` § dsv41.
- Memory guards: the upstream recipe's own `scripts/memguard.sh` on both boxes + systemd
  `dgx-memwatch@dsv41` on S1 (`make memwatch-status`). S1 MemAvailable under load
  is ~5.8 GiB, below the 5% warn line.
- S2 lost power twice under load on 2026-11-15. The 2,200 MHz clock cap is back on
  both nodes; S2 power delivery is the suspect (`docs/gb10-tuning-cn.md` §3.2).
- Rebuilding the image needs GitHub, which the boxes reach at ~25 KB/s: run
  `stacks/dsv41/build-image-local-git.sh` first.

All other stacks are stopped. `hibrid48tp2v52` (the previous primary) still owns the
name `qwen3.8-flash-next-tp2`. `qwen38un` is the only uncensored and the only
image-capable stack.

Open items:

- ⏳ No throughput or quality numbers of our own for `dsv41` (upstream's were taken
  at a different clock and context — don't quote them as ours). No aider-polyglot
  run on any stack since V4-Flash (82.4%).
- ⏳ Measure `PARALLEL=8` + `POOL=2M` against 4 streams.
- ⏳ Swap the S1/S2 power adapters to see whether S2's fault follows the adapter.
- ⏳ Homelab follow-up (above).
- `scripts/test-preflight.sh` uses `glm53` as its two-node fixture; if `glm53` is
  ever deleted, keep that case covered with another stack or a synthetic fixture.
- `glm53` and `qwen38un` have no runbook — only `recipe.yaml` + `notes.md`.
- ~100 GB of images from the deleted stacks (`vllm-qwen38fn:latest`,
  `vllm-node-dsv4:*`) are still in docker. First to go if disk gets tight, but they
  are the last copies.

## Commands

`STACK=` defaults to `stacks/PRIMARY`. The Makefile knows no stack names;
per-stack targets come from `stacks/<id>/Makefile.mk`.

```bash
make stacks                          # registry: primary, ports, served names
make info      [STACK=<id>]          # one stack's identity (thinking kwarg, CoT field, …)
make preflight [STACK=<id>]          # mutual exclusion + weights + image
make run       [STACK=<id>]          # preflight, then start
make status    [STACK=<id>]          # containers + /v1/models + free -h
make test      [STACK=<id>]          # smoke test, gated on /v1/models matching the registry
make logs      [STACK=<id>] [WORKER=1]   # WORKER=1 = rank1 of a TP=2 stack
make boot-log  [STACK=<id>]          # this boot's launcher output
make load                            # who is using the engine right now
make stop / make restart             # restart moves BOTH ranks

make switch TO=<id>                  # change primary: stop → PRIMARY → start → tables → clients → checklist
make stack-check                     # registry consistent + generated tables current
make preflight-test memwatch-test    # registry-wide regressions; run after touching stacks/ or scripts/

make memwatch-{install,status,reset,uninstall} [STACK=<id>]   # node-resident OOM watchdog
make clock-cap-{apply,verify,status,install,reset,uninstall}  # both nodes; CAP_HOSTS=<ip> for one
make tmux-cmd COMMAND="…" SESSION=<name>    # run on the hosts inside tmux (also tmux-list/attach/kill)
make ping / make cmd COMMAND="uptime"       # ansible ad-hoc
make node-exporter-deploy / make smartctl-exporter-deploy   # metrics → homelab Prometheus
```

`dsv41` upstream self-check, on S1 in `/home/admin/dsv41-recipe`:
`python3 tools/validate.py http://localhost:8000 --model DeepSeek-V4.1-Flash-1017`.

## Memory and GB10

- CPU and GPU share 128 GB per node. Engine pre-allocation bypasses container
  cgroups, so host MemAvailable is the only signal; `nvidia-smi` shows `[N/A]` per
  process — use `free -h`.
- OOM guard: `scripts/mem-watch.sh`, installed as systemd `dgx-memwatch@<stack>` on
  the stack's head (`make memwatch-install`). It stops every rank of its stack at the
  crit line, never auto-restarts (bring it back with `make run`), and refuses to
  start if it could not stop the stack. Thresholds are registry fields
  (`STACK_MEMWATCH_*`). `make switch` does not move it — uninstall/install is on the
  switch checklist. Spec: `docs/auto-mitigation-cn.md`.
- `polkitd` leaks ~0.3–0.4 GiB/week and has blocked a boot (6.27 GiB on S2):
  `sudo systemctl restart polkit` when headroom is short.
- Each stack's memory settings and their reasons are in its `recipe.yaml`; what
  failed before (0.85 decayed into the watchdog after 2 h; 0.95 hard-rebooted an
  upstream box) is in `stacks/qwen38un/notes.md`.
- The clock cap is the only useful GB10 host knob; power limits, ECC, fans and
  `nvpmodel` do not exist. A second QSFP cable adds nothing; dual rail is configured
  but measured no gain. `docs/gb10-tuning-cn.md`.

## Clients

Every stack is unauthenticated and serves `/v1/chat/completions` and `/v1/responses`.

```bash
codex --profile dgx   # → 100.97.87.120:8000 DeepSeek-V4.1-Flash-1017 (machine B only)
qwen                  # boot default → dsv41; ./scripts/qwen-model-switch.sh <id> to change
```

- `~/.codex` and `~/.qwen` are **not in git** and differ between two client Macs:
  **A** = `Matthews-MacBook-Pro`, **B** = `mbpm5.local` (the one switched on
  2026-11-14). Name the host whenever you record a client change.
- codex: a profile is a file, `~/.codex/<name>.config.toml`; a custom catalog loads
  only through `model_catalog_json`; a removed profile silently falls back to the
  cloud model.
- codex's / Qwen Code's own `reasoning:false` does not reach a self-hosted engine —
  send the stack's `STACK_THINK_OFF`.
- Full setup, reasoning-effort semantics, the Qwen Code hard-limit-0 trap, rebuilding
  on a new machine: `docs/clients-cn.md`.

## Measuring throughput

Read `docs/benchmarking-cn.md` before quoting any tok/s. Speculative decoding makes
throughput content-dependent (31 → 84 tok/s on one config); streaming counts steps,
not tokens; cold or idle engines run ~30% slow; the first request of a new prompt
shape is ~43% slow. Quote ranges, name the prompt, say warm or cold.

## Network (mainland China)

- `huggingface.co` is unreachable from the nodes: download from ModelScope and
  verify against the HF revision (pattern: `stacks/dsv41/fetch-weights.sh`).
- Images: daocloud, `ghcr.nju.edu.cn`, `nvcr.nju.edu.cn`. GitHub bulk is ~25 KB/s —
  fetch on the Mac. S1 runs an xray proxy (`scripts/v2rayn-launch.sh`, socks5
  `127.0.0.1:10808`). `docs/china-network-mirrors-cn.md`.
- Lab DHCP hands out no DNS; the static DNS on both nodes is load-bearing (#5).

## Gotchas index

Full detail and reproductions: `docs/gotchas-cn.md`.

| # | Symptom | Where it bites |
|---|---|---|
| 1 | Single-rank restart → zombie TP group; `/health` 200, every generation times out | any TP=2 stack ⚠️ |
| 2 | Two stacks on one GPU → OOMs the node. Overlap is by node set; rank1 counts | starting stacks ⚠️ |
| 3 | `NCCL WARN ... GID table changed` every ~45 s | logs (harmless) |
| 4 | Mirror "is slow" — actually `docker build`/`run` forced through the xray proxy | building images |
| 5 | ModelScope/GitHub unreachable while Tailscale works → DHCP gave no DNS | networking |
| 6 | `HFValidationError` in-container → absolute HF-cache symlinks | downloading models |
| 7 | `Syntax error in template` → Ansible eats `--format 'table {{.Names}}'` | ansible + docker `--format` |
| 8 | Foreign registries blocked/slow → daocloud + ModelScope + Tsinghua | all downloads |
| 9 | Hardcoded stack identity (CoT field / kwarg / model name) fails silently | cross-stack tools ⚠️ |
| 10 | SGLang and TensorFold accept any model name (200) | identity checks, gateway routes ⚠️ |

## Where things live

- `Makefile` — the single entry point.
- `stacks/README.md` — the contract for adding a stack: a new `stacks/<id>/` with one
  `stack.env`, nothing else edited.
- `stacks/PRIMARY`; `stacks/_lib/` — `stackctl.sh` (all verbs), `common.sh`
  (registry reads), `preflight.sh` (mutual exclusion), `adapter-docker.sh`.
- `stacks/<id>/` — `stack.env` (identity), `recipe.yaml` (why), `notes.md`
  (operations + history); optional `launch.sh`, `test.sh`, `preflight.sh`,
  `Makefile.mk`, `runbook-cn.md`.
- `scripts/` — cross-stack tools; all read the registry, none hardcodes a stack:
  `stack-table.py`, `stack-switch.sh`, `mem-watch.sh`, `memwatch-node.sh`,
  `gb10-clock-cap.sh`, `qwen-model-switch.sh`, `mem-floor.sh`, `test-mem-watch.sh`,
  `test-preflight.sh`, `vllm-fix-torch.sh`, `v2rayn-launch.sh`, `modelscope-download.sh`.
- `docs/` — shared runbooks: `gotchas`, `benchmarking`, `clients`, `stack-switch`,
  `host-maintenance`, `gb10-tuning`, `auto-mitigation`, `china-network-mirrors`,
  `s2-outage-2026-08-15`, `k3s-migration-design` (history only). All `-cn.md`.
- `benchmarks/<name>-<date>/` — harnesses and dated reports. Latest measured
  baseline: `benchmarks/hibrid48tp2v52-2026-10-22/`.
- `playbooks/` — Ansible for the node_exporter / smartctl_exporter that feed the
  homelab Grafana ("DGX Spark / Node Exporter").

## Conventions

- `docs/*-cn.md` are Chinese, with commands, error strings and identifiers verbatim
  in English. This file stays English.
- `docs/` holds only cross-stack material; anything true of one stack goes in
  `stacks/<id>/`.
- Adding a stack must not modify existing files — if it seems to, fix the registry.
  Removing one: delete `stacks/<id>/`, grep its id and runtime across `scripts/`,
  `stacks/_lib/` and the `Makefile`, then `make stack-check preflight-test memwatch-test`.
- Switching primary: `make switch TO=<id>`, then work through its printed manual list
  (`docs/stack-switch-cn.md`) and rewrite **Current state** above.
- **Keep this file short.** Replace stale facts instead of appending "previous
  state" sections; move narrative to `stacks/<id>/notes.md`.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `perf:`).
- Ansible: `uv run ansible …`; hosts come from `HOSTS` in the Makefile (`make inventory`).
- Host baseline (both nodes): kernel `6.17.0-1031-nvidia`, driver `580.173.02` /
  CUDA 13.0, swap off. The driver pin does not cover `libnccl*` or
  `nvidia-container-toolkit`.
