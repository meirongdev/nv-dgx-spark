# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Deployment tooling for vLLM inference across two NVIDIA DGX Spark (GB10
Blackwell) servers. Two stacks live in this repo:

- **Current primary — DeepSeek-V4-Flash-0731** (official release, upgraded
  2026-07-31 from the preview build; 284B/13B-active, official FP8) across
  **both** servers: dual-node TP=2 vLLM (jasl/vllm fork) + **DSpark** speculative
  decoding (upgraded 2026-07-03 from MTP), warm single-stream **31–84 tok/s
  depending on content** (mean 67, see [Measuring throughput](#measuring-throughput-read-this-before-quoting-a-toks-number)),
  **1M ctx**, served on server 1 `:8000` as `deepseek-v4-flash`.
  This stack is **NOT** Ansible-driven — it uses the eugr `spark-vllm-docker`
  harness. Deploy/run via `make v4flash-*`; full runbook
  `docs/deepseek-v4-flash-cn.md`; DSpark upgrade details `docs/dspark-upgrade-cn.md`.
- **Retired (revivable) — Qwen/Gemma + Bifrost gateway**, Ansible-driven through
  the Makefile (`make stack-deploy`, `make bifrost-*`). Torn down to free both
  GPUs for V4-Flash; the playbooks/targets/config still work to bring it back.
  See [Retired stack](#retired-stack-revivable) below.

**Target hosts** (edit `HOSTS` in Makefile to change):
- `100.97.87.120` — server 1 (V4-Flash head, serves the API on `:8000`)
- `100.67.164.92` — server 2 (V4-Flash TP worker; no separate endpoint)
- SSH: `admin` + `~/.ssh/vgio`
- 200-subnet (`192.168.200.101/102`) is the internal low-latency link — carries
  the TP=2 NCCL traffic between the two V4-Flash nodes (and, in the retired
  stack, the gateway→backend hops).

## Common Commands

### Current stack — DeepSeek-V4-Flash (eugr harness, not Ansible)

```bash
make v4flash-run        # launch dual-node TP=2 (systemd if autostart installed, else tmux)
make v4flash-status     # /v1/models + container state
make v4flash-test       # coding smoke test + tok/s
make v4flash-load       # who is using the engine now (running/waiting reqs, KV%, client IPs)
make v4flash-logs       # tail head-node log
make v4flash-stop       # stop both nodes (via systemd if the unit is active)

# Boot autostart (systemd unit on the head; survives reboot)
make v4flash-autostart          # install + enable the unit (one-time)
make v4flash-autostart-start    # start it now (= sudo systemctl restart)
make v4flash-autostart-status   # systemctl status + recent journal
make v4flash-autostart-remove   # disable + delete the unit
```

### Misc

```bash
make ping                          # ansible ping all hosts
make cmd COMMAND="uptime"          # ad-hoc command on all hosts
```

### Monitoring (node_exporter + smartctl_exporter → homelab Prometheus/Grafana)

```bash
make node-exporter-deploy          # deploy node_exporter (docker) on BOTH hosts
make node-exporter-status          # docker ps + /metrics probe per host
make node-exporter-logs            # tail logs (NODE_EXPORTER_LOG_HOST=<ip> to pick a host)
make node-exporter-stop            # remove the container on both hosts

make smartctl-exporter-deploy      # deploy smartctl_exporter (systemd, :9633) on BOTH hosts
make smartctl-exporter-status      # service state + /metrics probe per host
make smartctl-exporter-logs        # journal (SMARTCTL_EXPORTER_LOG_HOST=<ip> to pick a host)
make smartctl-exporter-stop        # disable the service on both hosts
```

Host metrics are surfaced in the **homelab** Grafana stack (the `meirongdev/homelab`
repo), not locally:
- node_exporter runs as a docker container on each server (`--net=host --pid=host`,
  `--restart unless-stopped`, rootfs mounted at `/host`), listening on `:9100`.
- homelab Prometheus scrapes both hosts over **Tailscale** (job
  `node-exporter-dgx-spark`, label `cluster=dgx-spark`). The tailnet ACL already
  allows `tag:homelab → *:*`, so no ACL change is needed.
- Grafana dashboard **"DGX Spark / Node Exporter"** (CPU/load, unified-memory usage,
  a swap-must-be-0 guard, disk, network incl. the 200G CX7 link, temps).
- The image is pulled via the **daocloud** mirror (`quay.m.daocloud.io/...`) then
  retagged — quay.io/github reset from mainland China.
- smartctl_exporter (NVMe SMART disk health) is **not** a container — the quay
  image is amd64-only, so the GitHub linux-arm64 binary is downloaded on the
  control machine (DGX can't reach github.com) and shipped over SSH as a root
  systemd service on `:9633` (Prometheus job `smartctl-dgx-spark`).

(Retired-stack commands — `stack-deploy`, `vllm-<model>-*`, `bifrost-*` — are in
the [Retired stack](#retired-stack-revivable) section.)

## Architecture (current — V4-Flash)

```
┌─────────────────────────────────────────────────────────────┐
│                   DGX Spark Cluster                          │
│  ┌──────────────────┐  200G CX7  ┌──────────────────┐        │
│  │ Server 1 (head)   │ ◄────────► │ Server 2 (worker) │       │
│  │ 192.168.200.101   │ RoCE/NCCL  │ 192.168.200.102   │       │
│  │ vLLM :8000        │   TP=2     │  (TP rank 1)      │       │
│  │ deepseek-v4-flash │            │                   │       │
│  └──────────────────┘            └──────────────────┘        │
└──────────────────────────┬───────────────────────────────────┘
                           │ Tailscale VPN (100.x)
                  ┌────────▼──────────┐
                  │   Mac (client)    │
                  │ codex --profile dgx → 100.97.87.120:8000
                  └───────────────────┘
```

The two nodes form **one** TP=2 vLLM instance; only server 1 exposes the OpenAI
API (`:8000`, both `/v1/chat/completions` and `/v1/responses`). Server 2 is a
pure TP worker reached over the 200G link — there is no separate endpoint on it.

## DeepSeek-V4-Flash deploy notes (GB10 → vLLM jasl fork)

Full deploy: `docs/deepseek-v4-flash-cn.md`; recipe `config/deepseek-v4-flash.yaml`;
ops `make v4flash-{run,status,test,load,logs,stop}`.

- **Why two nodes:** the official FP8 weights don't fit one GB10's 128GB — the
  serving checkpoint `DeepSeek-V4-Flash-0731` is ~167GB / 48 shards (the pre-0731
  base without the DSpark module was ~149GB / 46 shards). TP=2 splits them
  (~83GB/node), leaving room for KV cache.
- **Engine = jasl/vllm `codex/ds4-sm120-min-enable`**, built via the eugr
  `spark-vllm-docker` harness. GB10 is `sm_121`; stock builds lack a kernel for
  V4's sparse MLA, so the fork swaps in a Triton implementation via
  `VLLM_TRITON_MLA_SPARSE=1` (the load-bearing env). SGLang is a dead end here
  (its V4 attention needs a FlashMLA kernel that has no `sm_121` build) — don't
  retry it; use this vLLM fork.
- **torch-CPU build trap:** the from-source build leaves the runner image with
  **torch CPU** (the vllm wheel + ray/fastsafetensors deps clobber the cu130
  torch) → `vllm._C: libtorch_cuda.so missing`. Fix: reinstall cu130 torch +
  `docker commit` (`scripts/vllm-fix-torch.sh`).
- **Serve from the local model PATH** (`/root/.cache/huggingface/hub/DeepSeek-V4-Flash-0731`),
  not the HF repo id — the worker node has no proxy, and HF-cache symlinks must
  be relative to resolve inside the container.
- **MTP** (`deepseek_mtp`, `num_speculative_tokens=2`) roughly doubles single-stream
  throughput (~25 → ~42 tok/s). `cudagraph_mode=FULL_AND_PIECEWISE`, `--max-model-len 1000000`.
- **DSpark** (spec-decode successor to MTP, live since 2026-07-03): serves a
  checkpoint with the DSpark module attached +
  `--speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"greedy"}'`.
  Since 2026-07-31 that checkpoint is `DeepSeek-V4-Flash-0731` (166.9GB,
  ModelScope) — the official release ships the module built in, same structure
  and byte-identical config.json as the preview-era `DeepSeek-V4-Flash-DSpark`
  combo it replaced, so it was a pure weight swap (no engine/recipe changes
  beyond the model path). `num_speculative_tokens=5` is the GB10-tuned value
  (2026-07-31 sweep on 0731: n=3 ≈ 53.9 tok/s, n=5 ≈ 56.6, n=7 ≈ 52.4 —
  acceptance craters past draft position 4 (4.7%/0.3% at pos 5/6) because
  `dspark_block_size` is 5, so DeepSeek's recommended n=7 just wastes two draft
  passes per step; 6-way concurrency re-validated clean at n=5).
  `served_model_name` unchanged so clients need no reconfiguration.
  `max_num_seqs=6` / `max_num_batched_tokens=8192` is the validated concurrency
  ceiling (real 6-way concurrency confirmed, no garbling/crash, **186 tok/s
  aggregate / 33.5 per stream** — re-measured 2026-08-05; the "~50 aggregate" in
  older notes was a streaming-chunk-counting artifact) — **`max_num_seqs=16`
  fails outright** (KV-cache preflight check
  rejects the config; `Restart=on-failure` will then loop on the bad config
  until you revert). Full runbook + gotchas in `docs/dspark-upgrade-cn.md`.
  Rebuilds need `--build-only --force-build` (`--build-only` alone is a no-op
  when the image exists). First request after a (re)start pays a one-time
  Triton JIT-compile spike for the DSpark Markov-sampler kernels — ignore that
  measurement, retest. **jasl fork is now needed for DSpark only** — 2026-07-04
  testing showed stock upstream vLLM *can* serve plain V4-Flash TP=2 on GB10
  (sm121) fine, given `DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=...` (missing
  these looks like an architecture-support failure but isn't). **The "wait for
  PR #41834" plan is obsolete** — #41834 is still open (checked 2026-08-05), but
  eugr shipped DSpark anyway: the `b12x` branch merged into main on 2026-08-04
  with a `deepseek-v4-flash-0731` recipe (DSpark k=5, fp8 KV, full B12X backends)
  and **prebuilt images on Docker Hub** (`./build-and-copy.sh --exp-b12x -c`, no
  compile). That is the realistic path off the jasl fork now — but it is a
  **watch item, not a to-do**: the last comment on
  [eugr#331](https://github.com/eugr/spark-vllm-docker/issues/331) reports b12x
  crashing after 1–2 h with higher memory use (unanswered before close), eugr
  quotes "~50 t/s average" (below our measured mean 67.2), the recipe runs
  `gpu_memory_utilization: 0.85` (the value that OOM'd this head node on
  2026-06-29), and the image is an obscure Docker Hub org that daocloud probably
  won't mirror.
- **Never build/`docker build` on S1 without stopping the production stack
  first** — even the "lightweight" prebuilt-wheel path still compiles native
  deps (DeepGEMM/QuTLASS) from source in the runner-image stage, and doing this
  concurrently with the live stack OOM'd the head node on 2026-07-04 (killed
  `VLLM::Worker_TP`, took the whole tmux server down with it including any
  running v2rayN proxy session — re-verify the proxy after any OOM).
- The build needs foreign net (github) → revive the S1 v2rayN proxy first
  (`scripts/v2rayn-launch.sh`; `XRAY_NODE=<ip>` picks the SS node — the default
  node has died before; always verify `curl -x http://172.17.0.1:10809
  https://github.com` → 200 before building).

## Measuring throughput (read this before quoting a tok/s number)

DSpark decode speed is `steps/s × accepted-tokens-per-step`, and acceptance is
**content-driven** — so a single-prompt tok/s figure describes the prompt as much
as the cluster. One config, one server, measured 2026-08-05: **31 tok/s (prose)
→ 84 tok/s (count-to-300)**, mean 67. Quote a range and say what the prompt was.

Current baseline (`benchmarks/bench-full-2026-08-05/`, warm, temp 0,
`stream:false`, thinking off):

| axis | measured |
|---|---|
| decode peak / mean | 84.3 / 67.2 tok/s |
| aggregate c1 / c2 / c4 / c6 | 67 / 113 / 143 / 186 tok/s (33.5 per stream at c6) |
| prefill 8K / 32K / 100K | 1760 / 2203 / 2084 tok/s (median of 3, ±2%) |
| DSpark acceptance | 75.8%, 4.79 tok/step (p0..p4 = .90/.81/.74/.68/.65) |

Three traps, all of which produced wrong numbers in this repo's own docs:

1. **Streaming under-reports by the acceptance length.** Under spec decode vLLM
   emits at most one SSE chunk per decode *step*, carrying every token accepted
   in that step — counting stream deltas measures **steps/s** (~14 vs ~60 on the
   same request). Read `usage.completion_tokens` over wall time with
   `stream:false`, as `scripts/v4-test.sh` does, or divide the server's
   `vllm:generation_tokens_total` by wall time.
2. **Cold *and idle* decay ≈30%.** The first requests after a (re)start — or
   after ~30 min idle — run ~30% slow, and nothing in the log says so (this is on
   top of the one-time Triton JIT spike). Short calls don't clear it; it takes
   several 500+-token generations. Never benchmark straight after a lull.
3. **Short replies are overhead-capped.** ~0.5 s fixed per-request cost means a
   130-token reply can't post a high tok/s however predictable it is. Use
   500–1400-token generations.

Acceptance is observable live — no instrumentation needed:
`curl -s localhost:8000/metrics | grep spec_decode` (diff two snapshots around a
request; `accept_diff.py` in the benchmark dir does the arithmetic).

### Ruled out: the "0731 DSpark 1M NVFP4 KV" forum recipe (2026-08-05)

The NVIDIA-forum recipe
([thread](https://forums.developer.nvidia.com/t/deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark/378824),
repo `tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark`) was
benchmarked head-to-head with its own harness: **our stack matches or beats it on
every axis except 100K prefill.** Don't rebuild on it — full write-up and the
per-claim analysis in `benchmarks/bench-full-2026-08-05/README.md`. Short version:
its Stage C `nvfp4_ds_mla` keeps DeepSeek's 584-byte cache envelope, so 4-bit KV
saves **zero** memory vs our `fp8_ds_mla` — measured from both sides' boot logs at
the same `--block-size 256`: **7,606 B/tok theirs vs 7,424 ours** (a real 416-byte
layout would be ~5,288); its "B12X ≈ 2×" is 2× against its own base image's
fallback, not against this build; and its Patch 4 draft-loader bug (halves 0731
acceptance) doesn't apply to the jasl fork. Adopting it would mean moving back to a
frozen vLLM 0.21.1 + ~15 hand-maintained overlay files.

**NVFP4 KV itself stays a watch item** — the verdict is against *this* recipe, not
against 4-bit sparse-MLA KV (a real layout would cut ~29% of B/tok). Revisit when a
416-byte `nvfp4_ds_mla` store/decode kernel survives past ~411 real prompt tokens
**and** runs on a runtime no older than ours. Judge it by the boot-log B/tok, not
the README wording: **below ~6,000 is real, 7,4xx–7,6xx is the padded fake.**
Not urgent — at 1.34M tok / 1.39x concurrency @1M ctx with `max_num_seqs=6` we have
no use for the freed memory. Trigger conditions in `benchmarks/bench-full-2026-08-05/README.md`.

Its one real lead is **100K prefill, 2639 vs our 2084 tok/s (+27%)** — and there
is **no free lever to close it**. `--async-scheduling` (in its launcher, absent
from our recipe) is a **no-op here**: this build treats `async_scheduling=None`
as auto-enable-unless-incompatible and `dspark` is whitelisted
(`config/vllm.py:981-1060`), so every boot already logs *"Asynchronous scheduling
is enabled"* — don't add the flag expecting a win. Its
`VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256` is *tighter* than our 512 default, and
flashinfer autotune is already on. The remaining likely cause is its B12X MXFP4
MoE kernel (deep prefill = large-M MoE GEMM), which is welded to that frozen
runtime. Untested and not free: `--max-num-batched-tokens` 8192 → 16384, which
trades in-flight decode latency and KV pool for prefill chunk size.

## Boot autostart (systemd, survives reboot)

A reboot wipes the stack (`--rm` containers, no restart policy) — the cluster
does **not** come back on its own unless the unit below is installed. One-time:
`make v4flash-autostart` (installs `scripts/v4flash-boot.sh` →
`/home/admin/v4flash-boot.sh` + `config/deepseek-v4-flash.service` →
`/etc/systemd/system/`, `daemon-reload`, `enable`).

- **One unit, on the head only** (`User=admin`). The head's `launch-cluster.sh`
  drives the TP worker over SSH, so the worker needs no unit — just docker +
  sshd (both default-enabled).
- **A docker `--restart` policy can't do this**: vLLM runs as a foreground
  `docker exec` *inside* a `sleep infinity --rm` container, so a restart policy
  would only revive the sleep. The whole orchestration (`run-recipe.sh
  --no-ray`) must re-run — which is what the unit's `ExecStart` does.
- **Boot-race handling:** `v4flash-boot.sh` waits (≤15 min, `DSV4_WAIT_TIMEOUT`)
  for the worker's ssh+docker+GPU over the 200G link before launching, so a
  simultaneous reboot of both nodes doesn't make `launch-cluster.sh` abort.
  `Restart=on-failure` is the backstop (and gives free crash-recovery).
- **Once installed, `make v4flash-run`/`v4flash-stop` route through systemd**
  (`systemctl restart`/`stop`) so the manual and boot paths are identical and a
  manual `docker rm` can't trigger a `Restart=on-failure` fight. The tmux launch
  is the fallback only when the unit isn't installed (e.g. during a rebuild).
  Logs move from `/tmp/dsv4-run.log` to `journalctl -u deepseek-v4-flash`.

## Unified memory constraints (DGX Spark GB10)

- 128 GB LPDDR5X coherent memory shared between CPU and GPU, per node.
- **Don't over-allocate `gpu-memory-utilization`** — too high risks OOM freezes of
  sshd itself. V4-Flash uses **0.80** (0.85 caused a full head-node OOM on
  2026-06-29 — lowered and kept there since); the retired single-node-full-model
  Qwen/Gemma stack needed **0.70**.
- Swap **must** be disabled (`swapoff -a`).
- `nvidia-smi` reports `[N/A]` for per-process memory on GB10; watch `free -h`.

## Connecting from clients

The current stack is **unauthenticated** vLLM on `100.97.87.120:8000` (model
`deepseek-v4-flash`); vLLM accepts any API key when `--api-key` is not set.

```bash
export DGX_SPARK_API_KEY=dummy

# codex (Profile V2 — overlay files in ~/.codex/<name>.config.toml)
codex --profile dgx          # → 100.97.87.120:8000, model deepseek-v4-flash
codex --profile dgx-direct   # same endpoint (Bifrost retired; kept for habit)

# Qwen Code CLI (.qwen/.env in this repo, gitignored):
#   OPENAI_BASE_URL=http://100.97.87.120:8000/v1
#   OPENAI_MODEL=deepseek-v4-flash
#   OPENAI_API_KEY=dummy
qwen
```

`:8000` serves both `/v1/chat/completions` and `/v1/responses`. Thinking is **on
by default**, toggled via `chat_template_kwargs.thinking`. Note: codex/qwen
built-in `reasoning:false` only reaches `api.deepseek.com`, **not** a self-hosted
vLLM — to force thinking off, inject `chat_template_kwargs:{"thinking":false}`
via the client's extra-body.

**`reasoning_effort` — on this engine only `"max"` does anything** (verified
2026-08-05). The 0731 checkpoint's own encoder defines three levels (`low`
default / `high` / `max`), but we serve through the engine's bundled
`vllm/tokenizers/deepseek_v4_encoding.py`, which is the preview-era copy: it
injects a prefix **only** for `reasoning_effort == "max"`, and its `assert`
doesn't fire, so every other value — including `"high"` and typos — is a
**silent no-op**. Measured with `/tokenize` (same message, thinking on):

| `chat_template_kwargs` | prompt tokens |
|---|---|
| `{"thinking":true}` / `+"low"` / `+"high"` / `+"bogus"` | 10 |
| `{"thinking":true,"reasoning_effort":"max"}` | **89** (+79-token prefix) |

So: to make it deliberate more, send `"max"` — copying eugr's
`reasoning_effort=high` gets you nothing here. Our `"max"` injects the text that
0731's own table calls `high`; 0731's real `max` prefix is unreachable until the
engine ships an encoder updated for 0731.

> To use the retired Bifrost gateway instead, revive that stack — see below.

## Known Gotchas

### `docker build` on S1 is silently forced through the xray proxy
`~/.docker/config.json` sets `proxies.default` → `http://172.17.0.1:10809`, so the
docker **client** injects `HTTP(S)_PROXY` into every build and `docker run`. For
domestic mirrors that tunnels the traffic abroad and back: measured **18 KB/s via
the proxy vs 1.6 MB/s direct to the same Tsinghua mirror** (~90x), which looks
exactly like "the mirror is slow" and wastes hours.

- `--build-arg http_proxy=` only fixes plain-HTTP fetches (apt); HTTPS clients
  (`uv`/`pip`) still pick up `HTTPS_PROXY`. `ENV http_proxy=""` in the Dockerfile
  is also unreliable.
- **Fix:** move `~/.docker/config.json` aside for the duration of the build. It is
  a *client-side* config — the daemon is not restarted, so the running vLLM
  container is untouched. Working script with a `trap ... EXIT` restore:
  `benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/build_noproxy.sh`.
- Keep the proxy for anything that genuinely needs foreign net (github clones).
  Registry *pulls* use the daemon, not this file, so they are unaffected —
  daocloud being slow for a given image (e.g. `buildpack-deps:jammy` at 39 KB/s)
  is a separate problem; prefer a base image already present locally.

### Uplink DHCP provides no DNS — static DNS is load-bearing
The lab DHCP (10.14.20.1) hands out **no DNS servers**. Working DNS on the DGX
nodes comes from static config only; without it every non-tailnet lookup
SERVFAILs (MagicDNS on `tailscale0` only covers tailnet names) — this is what a
"ModelScope/github unreachable, Tailscale fine" symptom looks like. Fixed
2026-07-31: `223.5.5.5 119.29.29.29` persisted on **both** nodes via
`nmcli con mod "Wired connection 3" ipv4.dns ...` (before that, S1 had only a
transient `resolvectl` fix that a reboot would wipe, and S2 had nothing).

### ModelScope / HF-cache symlinks must be relative
`snapshot_download` (and HF cache) can write **absolute** symlinks. Inside the
vLLM container the cache is mounted at a different path, so an absolute link does
not resolve — vLLM then treats the name as an HF repo id and crashes
(`HFValidationError`). Fix: replace with a relative symlink, e.g.
```bash
cd /home/admin/.cache/modelscope/Qwen
ln -snf Qwen3___6-35B-A3B-FP8 Qwen3.6-35B-A3B-FP8
```
(Same root cause as "serve from the local PATH" for V4-Flash.)

### Ansible 2.20 + Docker `--format 'table {{.Names}}…'`
Ansible's Jinja2 eats `{{.Names}}` and errors with `Syntax error in template`.
Don't pass `--format 'table {{.X}}'` through `ansible -a`; drop `--format` or
Jinja-escape with `{{ '{{' }}.Names{{ '}}' }}`.

### Pulling Docker images / models from mainland China
The DGX servers are in mainland China; most foreign registries are blocked or
crawl. Each DGX pulls fine over its own fast domestic link — no proxy/VPN/relay.
- **Docker images** → pull official/popular images via the **daocloud** prefix,
  then retag to the original name:
  ```bash
  docker pull docker.m.daocloud.io/vllm/vllm-openai:latest
  docker tag  docker.m.daocloud.io/vllm/vllm-openai:latest vllm/vllm-openai:latest
  ```
  daocloud serves popular official orgs but allowlist-rejects obscure ones. The
  mirrors in `/etc/docker/daemon.json` often don't kick in (docker falls back to
  the blocked `registry-1.docker.io`) — use the explicit `docker.m.daocloud.io/…`
  prefix. Pulling on a non-DGX (x86) box needs `--platform linux/arm64` (GB10 is aarch64).
- **Models** → ModelScope (`modelscope download --model <id> --local_dir …`);
  hf-mirror resets on large `*.safetensors`. **Python** → Tsinghua PyPI.
- **Avoid**: Cloudflare-fronted proxies (`agsv.top`/`hub.rat.dev`/`1ms.run` blobs
  reset in CN), NGC `nvcr.io` (intermittent reset), Mac-relay over Tailscale
  (DERP relay ≈ 0.15 MB/s). Inter-node copy → 200G link (`192.168.200.x`),
  `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts` first.
- Full runbook: `docs/china-network-mirrors-cn.md`.

## Key file map

- `Makefile` — single user-facing interface (`v4flash-*` for the current stack;
  `stack-*`/`vllm-*`/`bifrost-*` for the retired one), plus per-model defaults.
- `config/deepseek-v4-flash.yaml` — V4-Flash recipe (mirror of the live one in
  the eugr harness on server 1).
- `scripts/vllm-fix-torch.sh` — reinstalls cu130 torch in the built image +
  `docker commit` + copies to S2 (fixes the torch-CPU build trap).
- `scripts/v2rayn-launch.sh` — revives the S1 v2rayN proxy headless (needed for
  the github clone during the V4-Flash build).
- `scripts/v4-test.sh` — coding smoke test against `:8000`, prints tok/s (one
  short prompt — a smoke test, not a benchmark; see [Measuring throughput](#measuring-throughput-read-this-before-quoting-a-toks-number)).
- `benchmarks/bench-full-2026-08-05/` — decode-by-content + c1..c6 + prefill-at-depth
  baseline, and the head-to-head that ruled out the forum NVFP4-KV recipe.
- `scripts/v4flash-boot.sh` — boot launcher: waits for the worker (ssh+docker+GPU
  over the 200G link), tears down stale containers, then `exec`s the recipe in
  the foreground. Copied to `/home/admin/v4flash-boot.sh` by `make v4flash-autostart`.
- `config/deepseek-v4-flash.service` — systemd unit (head node) that runs the
  boot launcher; installed to `/etc/systemd/system/` + enabled by the same target.
- `docs/deepseek-v4-flash-cn.md` — full V4-Flash deploy runbook (Chinese).
- `docs/dspark-upgrade-cn.md` — DSpark upgrade runbook: version landscape, fastest
  paths, step-by-step + gotchas (Chinese).
- `docs/china-network-mirrors-cn.md` — daocloud/ModelScope/Tsinghua mirror runbook.
- `scripts/modelscope-download.sh` — downloads a model from ModelScope into
  `/home/admin/.cache/modelscope` (via `make modelscope-download MS_MODEL=...`).
- `playbooks/node-exporter-deploy.yml` — deploys Prometheus node_exporter (docker,
  `--net=host --pid=host`) on both hosts for homelab Grafana monitoring
  (`make node-exporter-deploy`).
- `playbooks/smartctl-exporter-deploy.yml` — installs smartctl_exporter as a host
  systemd service (linux-arm64 binary shipped over SSH) on both hosts
  (`make smartctl-exporter-deploy`).
- _Retired stack:_ `playbooks/vllm-model-deploy.yml`, `playbooks/bifrost-deploy.yml`,
  `config/bifrost-config.json`, `scripts/run-vllm-qwen.sh`,
  `scripts/vllm-entrypoint.sh` + `scripts/patch-vllm-*.py`.

## tmux integration (SSH drop protection)

SSH rides a flaky DERP relay; wrap long remote work in tmux so a drop doesn't
kill it.

```bash
make tmux-cmd COMMAND="docker pull ..." SESSION="my-task"
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```

## Conventions

- The current image on both servers is `vllm-node-dsv4:latest` (jasl fork build,
  driver 580.142 / CUDA 13.0). The old `vllm-node-tf5` and per-model images were
  removed during cleanup.
- SSH strict host key checking is disabled (automation).
- For the retired (Ansible) stack: Ansible always runs via `uv run ansible` /
  `uv run ansible-playbook`; to add/remove hosts edit `HOSTS` in Makefile then
  `make inventory`.

---

## Retired stack (revivable)

The Qwen3.6-35B-A3B / Gemma-4 / Qwen3.5-122B per-node vLLM split + Bifrost
gateway. Torn down to free both GPUs for V4-Flash; everything below still works
to bring it back. (Note: those model weights were deleted during cleanup —
re-download via ModelScope before redeploying.)

### Commands

```bash
make all                           # bootstrap: venv + inventory + SSH test
make stack-deploy                  # vLLM on both servers + gateway; primary = qwen36
make stack-deploy STACK_MODEL=gemma4
make stack-status | stack-stop

make vllm-qwen36-deploy            # Qwen3.6-35B-A3B-FP8 (was default primary)
make vllm-gemma4-deploy            # Gemma-4-31B-IT-NVFP4
make vllm-qwen-deploy              # Qwen3.5-122B-A10B-NVFP4
make vllm-qwen36-{status,stop,logs}    # HOST=... for logs
make vllm-status VLLM_CONTAINER=vllm-xyz VLLM_PORT=30000   # generic variants
make bifrost-deploy | bifrost-status | bifrost-test | bifrost-stop
```

### Adding a new model (Ansible stack)

1. Add a `VLLM_<NAME>_*` variable block near the top of the Makefile (copy the
   Qwen3.6 block: model path, served name, port, etc.).
2. Add `vllm-<name>-{deploy,status,stop,logs}` targets at the bottom of the
   "Per-model vLLM Deployments" section (copy the Qwen3.6 targets; update the
   `-e` vars and container name). Add the names to `.PHONY`.
3. Deploy with `make vllm-<name>-deploy`; make it the stack default with
   `make stack-deploy STACK_MODEL=<name>`.

The single playbook `playbooks/vllm-model-deploy.yml` handles all models.
Optional per-model knobs are `-e` variables: `vllm_chat_template_src`,
`vllm_patch_script_src`, `ms_cache_dir`, `vllm_model_validate_path`,
`vllm_cleanup_containers`.

### Bifrost routing (`config/bifrost-config.json`)

Bifrost is OpenAI-compatible but requires the `model` field to be
`<provider>/<model>`. Providers:

| Provider       | Upstream                       | `/v1/responses*` | `/v1/chat/completions` |
|----------------|--------------------------------|------------------|-------------------------|
| `vllm-server1` | `http://192.168.200.101:30000` | ✅ enabled       | ✅ enabled              |
| `vllm-server2` | `http://192.168.200.102:30000` | ❌ disabled      | ✅ enabled              |

Stateful Responses API must pin to `vllm-server1` (`previous_response_id` is an
in-memory store on one node). `/v1/models` on :8080 returns `{"data": []}` —
Bifrost does not proxy upstream model lists; `curl …:30000/v1/models` to see what
vLLM actually loaded.

### Bifrost authentication (virtual keys)

`governance.virtual_keys[]` in the config; clients send the VK as a Bearer token.
- VK value: `sk-bf-dgx-spark-cluster-2026` (id `dgx-spark-cluster`)
- Allowed models: explicit list (the `["*"]` wildcard did not work in testing).
- **Caveat:** Bifrost only enforces VK restrictions when the Bearer matches a
  defined VK; unknown/missing Bearers fall through unrestricted. Treat :8080 as
  "authenticated when on Tailscale", not a hardened public API.

### Legacy model gotchas

- **Qwen3-family** — tool parser `qwen3_coder`, reasoning parser `qwen3` (CoT in
  `.choices[0].message.reasoning`, answer in `.content`). `max_tokens=10` smoke
  tests show empty content — reasoning eats the budget; use ≥256.
- **Qwen3.5 chat_utils** — multi-turn tool-call history with `qwen3_coder` can
  emit a trailing byte that breaks `json.loads()` in
  `chat_utils._postprocess_messages`. Fix: `scripts/patch-vllm-chat-utils.py`
  (`JSONDecoder.raw_decode()`), applied by the entrypoint wrapper.
- **Gemma-4 `skip_special_tokens`** — `ResponsesRequest` defaults
  `skip_special_tokens=True`, stripping the `<|tool_call>` delimiters Gemma-4
  emits. Fix: `scripts/patch-vllm-gemma4-parser.py`, applied at container start.
