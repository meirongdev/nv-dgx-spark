# nv-dgx-spark

## Project Overview

Deployment tooling for vLLM inference on a two-node NVIDIA DGX Spark (GB10)
cluster. Two stacks live in this repo:

- **Current primary — DeepSeek-V4-Flash-0731** (284B/13B-active, official FP8):
  **one** dual-node TP=2 vLLM instance across both servers (jasl/vllm fork via
  the eugr `spark-vllm-docker` harness — **not** Ansible) + **DSpark**
  speculative decoding (`num_speculative_tokens=5`), warm single-stream
  **31–84 tok/s depending on content** (mean 67; acceptance is content-driven —
  baseline and measurement traps in `benchmarks/bench-full-2026-08-05/`), 1M
  context. Served on server 1 `:8000` as `deepseek-v4-flash`.
- **Retired (revivable) — Qwen/Gemma per-node vLLM + Bifrost gateway**,
  Ansible-driven (`make stack-deploy`, `make bifrost-*`). Torn down to free both
  GPUs for V4-Flash; playbooks/targets/config still work, but model weights and
  the `vllm-node-tf5` image were deleted — re-download/rebuild before reviving.

**Target Infrastructure:**
- `100.97.87.120` — server 1 (V4-Flash head; serves the OpenAI API on `:8000`)
- `100.67.164.92` — server 2 (V4-Flash TP worker; no separate endpoint)
- SSH: user `admin`, key `~/.ssh/vgio`
- `192.168.200.101/102` — 200G CX7 link (RoCE/NCCL TP traffic between the nodes)

## Hardware

**NVIDIA DGX Spark (GB10 Grace Blackwell Superchip), per node:**
- GPU GB10 Blackwell (`sm_121`, CUDA 13.0), 20-core ARM CPU, 4TB NVMe
- 128GB LPDDR5X **unified coherent memory** (CPU+GPU share one pool)
- Constraints: swap **must** stay off; don't over-allocate
  `--gpu-memory-utilization` (V4-Flash uses **0.80** — 0.85 OOM'd the head node
  on 2026-06-29; the retired single-node stack needed 0.70). `nvidia-smi` shows
  `[N/A]` per-process memory on GB10 — watch `free -h`.

## Common Commands

### Current stack — DeepSeek-V4-Flash (eugr harness, not Ansible)

```bash
make v4flash-run        # launch dual-node TP=2 (systemd if autostart installed, else tmux)
make v4flash-status     # /v1/models + container state
make v4flash-test       # coding smoke test + tok/s
make v4flash-load       # who is using the engine now (running/waiting reqs, KV%, client IPs)
make v4flash-logs       # tail head-node log
make v4flash-stop       # stop both nodes

# Boot autostart (systemd unit on the head; survives reboot)
make v4flash-autostart | v4flash-autostart-start | v4flash-autostart-status | v4flash-autostart-remove
```

Recipe: `config/deepseek-v4-flash.yaml` (mirror of the live one on server 1).
Full runbook: `docs/deepseek-v4-flash-cn.md`; DSpark details: `docs/dspark-upgrade-cn.md`.

### Misc / monitoring

```bash
make ping                          # ansible ping all hosts
make cmd COMMAND="uptime"          # ad-hoc command on all hosts
make node-exporter-deploy          # node_exporter (docker, :9100) on both hosts
make smartctl-exporter-deploy      # smartctl_exporter (systemd, :9633) on both hosts
make modelscope-download MS_MODEL=<id>   # download a model via ModelScope
```

Metrics are scraped over Tailscale by the homelab Prometheus/Grafana
(`meirongdev/homelab` repo), dashboard "DGX Spark / Node Exporter".

### tmux resilient sessions (SSH rides a flaky DERP relay)

```bash
make tmux-cmd COMMAND="..." SESSION="my-task"
make tmux-list HOST=100.97.87.120
make tmux-attach HOST=100.97.87.120 SESSION=vllm-deploy
make tmux-kill HOST=100.97.87.120 SESSION=vllm-deploy
```

### Retired stack (only when reviving it)

```bash
make all                           # bootstrap: venv + inventory + SSH test
make stack-deploy                  # vLLM on both servers + Bifrost; STACK_MODEL=qwen36|qwen|gemma4
make vllm-qwen36-{deploy,status,stop,logs}
make bifrost-{deploy,test,status,stop}
```

## Using the endpoint from this Mac

Unauthenticated vLLM at `http://100.97.87.120:8000/v1` (any API key accepted),
model `deepseek-v4-flash`; serves `/v1/chat/completions` and `/v1/responses`.
Qwen Code reads `.qwen/.env` in this repo (gitignored):

```
OPENAI_BASE_URL=http://100.97.87.120:8000/v1
OPENAI_MODEL=deepseek-v4-flash
OPENAI_API_KEY=dummy
```

Thinking is on by default, toggled via `chat_template_kwargs.thinking` — Qwen
Code's built-in `reasoning:false` is a no-op against self-hosted vLLM; inject
`chat_template_kwargs:{"thinking":false}` via extra-body to turn it off.

`reasoning_effort` also works, but **only the value `"max"`** — the engine's
bundled (preview-era) encoder injects a prefix for `"max"` and silently ignores
everything else, including `"high"`. Details + measurements in CLAUDE.md.

## Key Gotchas (details in CLAUDE.md and docs/)

- **Never build/`docker build` on S1 without stopping the production stack
  first** — even "lightweight" builds compile native deps and have OOM'd the
  head node (2026-07-04).
- `docker build` on S1 is silently forced through the xray proxy by
  `~/.docker/config.json` `proxies.default` — move the file aside for
  domestic-mirror builds (18 KB/s proxied vs 1.6 MB/s direct).
- Serve models from the **local container path**, never an HF repo-id; HF-cache
  symlinks must be **relative**.
- Mainland-China networking: Docker images via `docker.m.daocloud.io/...` +
  retag; models via ModelScope; Python via Tsinghua PyPI. Runbook:
  `docs/china-network-mirrors-cn.md`.
- Lab DHCP hands out **no DNS** — static `nmcli ipv4.dns` config on both nodes
  is load-bearing.
- Ansible runs via `uv run ansible` / `uv run ansible-playbook`; hosts are edited
  via `HOSTS` in the Makefile, then `make inventory`.

## Conventions

- Current image on both servers: `vllm-node-dsv4:latest` (jasl fork build,
  driver 580.142 / CUDA 13.0).
- kebab-case file names; Python for complex patching, Bash for automation.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `perf:`).
