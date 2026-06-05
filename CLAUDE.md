# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Deployment tooling for vLLM inference across two NVIDIA DGX Spark (GB10
Blackwell) servers. Two stacks live in this repo:

- **Current primary — DeepSeek-V4-Flash** (284B/13B-active, official FP8) across
  **both** servers: dual-node TP=2 vLLM (jasl/vllm fork) + MTP, ~42 tok/s warm,
  **1M ctx**, served on server 1 `:8000` as `deepseek-v4-flash`. This stack is
  **NOT** Ansible-driven — it uses the eugr `spark-vllm-docker` harness. Deploy/run
  via `make v4flash-*`; full runbook `docs/deepseek-v4-flash-cn.md`.
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
ops `make v4flash-{run,status,test,logs,stop}`.

- **Why two nodes:** the official FP8 weights are ~149GB (46 shards) — more than
  one GB10's 128GB. TP=2 splits them (~74GB/node), leaving room for KV cache.
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
- **Serve from the local model PATH** (`/root/.cache/huggingface/hub/DeepSeek-V4-Flash`),
  not the HF repo id — the worker node has no proxy, and HF-cache symlinks must
  be relative to resolve inside the container.
- **MTP** (`deepseek_mtp`, `num_speculative_tokens=2`) roughly doubles single-stream
  throughput (~25 → ~42 tok/s). `cudagraph_mode=FULL_AND_PIECEWISE`, `--max-model-len 1000000`.
- The build needs foreign net (github) → revive the S1 v2rayN proxy first
  (`scripts/v2rayn-launch.sh`).

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
  sshd itself. V4-Flash uses **0.85** (weights split TP=2, ~74GB/node → headroom);
  the retired single-node-full-model Qwen/Gemma stack needed **0.70**.
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
by default** and is a **binary toggle** via `chat_template_kwargs.thinking` (no
graduated effort level). Note: codex/qwen built-in `reasoning:false` only reaches
`api.deepseek.com`, **not** a self-hosted vLLM — to force thinking off, inject
`chat_template_kwargs:{"thinking":false}` via the client's extra-body.

> To use the retired Bifrost gateway instead, revive that stack — see below.

## Known Gotchas

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
- `scripts/v4-test.sh` — coding smoke test against `:8000`, prints tok/s.
- `scripts/v4flash-boot.sh` — boot launcher: waits for the worker (ssh+docker+GPU
  over the 200G link), tears down stale containers, then `exec`s the recipe in
  the foreground. Copied to `/home/admin/v4flash-boot.sh` by `make v4flash-autostart`.
- `config/deepseek-v4-flash.service` — systemd unit (head node) that runs the
  boot launcher; installed to `/etc/systemd/system/` + enabled by the same target.
- `docs/deepseek-v4-flash-cn.md` — full V4-Flash deploy runbook (Chinese).
- `docs/china-network-mirrors-cn.md` — daocloud/ModelScope/Tsinghua mirror runbook.
- `scripts/modelscope-download.sh` — downloads a model from ModelScope into
  `/home/admin/.cache/modelscope` (via `make modelscope-download MS_MODEL=...`).
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
