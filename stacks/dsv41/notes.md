# dsv41 — DeepSeek-V4.1-Flash-1017 TP=2 (TensorFold): operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **DeepSeek-V4.1-Flash-1017 TP=2** (`dsv41`, **primary** since 2026-11-14, S1+S2):
  Mia EAQ v1 EXL3 2.9 bpw (196 GiB) + Engram's two unquantized tables (189 GiB),
  TensorFold Zig engine (BertholomusAI fork + upstream patches 0001–0068), DSpark
  drafts, RoCE exchanges over **two rails**, **8 streams** (`PARALLEL=8` since 2026-11-15
  19:07, was upstream's 4 — upstream only measured throughput to 4), **262,144-token window**
  (was 524,288; upstream default 1M), **`POOL=2097152`** positions (since 19:19; 1,048,576
  from 18:54) shared by all streams and kept prompts (each request reserves prompt +
  `max_tokens`, default 32,768; an extra request queues, `/health` `live.waiting`).
  ⚠️ 8 streams is on trial: at POOL 1M it measured **worse** than 4 (below); rollback
  trigger S1 MemAvailable < 3.5 GiB, and the plan if 2M + 8 doesn't beat 4 streams is
  `PARALLEL=4` with POOL kept at 2M. Thinking **on** by default.
  Images, tool calls, 21.9K-token prompt all pass upstream's `validate.py`.
  ⏳ **No throughput or quality numbers of our own yet** (upstream's, at 2,200 MHz:
  80.7 tok/s prose / 118.1 code single-stream, ~2,100 tok/s prefill flat to 256K).

## Operating notes

- **dsv41** (primary since 2026-11-14) — upstream MiaAI-Lab recipe as-is under
  `/home/admin/dsv41-recipe/` on S1; `make run/stop/restart STACK=dsv41` wrap its
  `./start.sh` / `./stop.sh`, which move **both** ranks and start/stop memguard on
  both boxes. `./start.sh` re-runs `scripts/prepare.sh` whenever its prepared marker
  changes (image, pins, `local.sh` paths, chat template) — ⚠️ that means a rebuild
  needs GitHub, which these boxes reach at ~25 KB/s: use
  `stacks/dsv41/build-image-local-git.sh` first, then prepare finds the image built.
  Rank logs: `make logs STACK=dsv41 [WORKER=1]`; upstream checks:
  `python3 tools/validate.py http://localhost:8000 --model DeepSeek-V4.1-Flash-1017`
  on S1. ⚠️ Never copy large files onto S1 while it serves — upstream measured a
  5.8 GB copy pushing MemAvailable under memguard's floor (their #117).

## History

### 2026-11-14 → 11-15 — switch to primary and first two days (was CLAUDE.md "Current state")

**New model, new engine, same boxes and same port — different served name.**
`dsv41` runs `MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks` @ `c7f2b85` as-is
under `/home/admin/dsv41-recipe` on S1; the only local deviations are in its
`scripts/local.sh` (= `stacks/dsv41/local.sh`): `WORKER=admin@192.168.200.102`,
`PORT=8000` (user's choice, keeps client URLs), `CONTEXT=262144` (524288 until
2026-11-15: aligned with the gateway's 262K Ornith fallback, less prefill memory), PATH for `hf`.
Why each number: `stacks/dsv41/recipe.yaml`. Switched 2026-11-14: old primary
stopped 23:11, `DeepSeek-V4.1-Flash-1017 is now LIVE` 23:53 (**~42 min outage**).

- ✅ **Inputs are byte-checked against HF's pinned revisions** although they came from
  ModelScope (nodes can't reach HF): `stacks/dsv41/fetch-weights.sh` +
  `weights-manifest.json` — 41/41 LFS sha256 + 23/23 small-file git oids for the
  checkpoint (`45ee5d0f`), 2/2 + 2/2 for Engram (`1bae0e10`). Downloaded on S2
  (~220 MB/s), copied to S1 over 200G after the stop (387 GiB in 241 s).
- ✅ **Image built locally** (`tensorfold-dsv41:exl3-tp2-8a98ae503d85`, the upstream
  `image_hash()`; ghcr only has an older pin). Base `nvcr.io/nvidia/pytorch:26.07-py3`
  came from **`nvcr.nju.edu.cn`** (direct nvcr.io resets; image ID `15b8de8b…` = NGC's
  arm64 config digest). ⚠️ **GitHub was 13–47 KB/s from both nodes on every path**
  (direct / xray socks / privoxy) and reset the build's `git fetch` at 90 s →
  `stacks/dsv41/build-image-local-git.sh`: the two pinned TensorFold commits fetched
  on the Mac, served to the build from a `git daemon` on the docker bridge; tag/label
  unchanged and the Dockerfile asserts the commit, so it is upstream's image.
- ✅ `make test STACK=dsv41` all green, measured on the live endpoint:
  only `chat_template_kwargs.enable_thinking` toggles thinking (top-level ignored);
  CoT in **`reasoning_content`** (`reasoning` always empty — the **opposite** of the
  Qwen primaries); `/v1/responses` accepts every effort none…max, and at temperature 0
  low/medium/high/xhigh are **token-identical** (only `none` and `max` differ);
  RDMA really carries the exchanges (1.2 GB on the HCA in one generation); upstream
  `tools/validate.py`: text, thinking, tool call + result, **image**, 21.9K-token
  prompt (9.5 s), concurrent == solo — all pass.
- ⚠️ **TensorFold accepts any model name** (gotcha #10 now covers it too): a request
  for `qwen3.8-flash-next-tp2` gets 200 from DeepSeek, with `"model":
  "DeepSeek-V4.1-Flash-1017"` in the reply. So the homelab consumers that hardcode the
  old name (LiteLLM routes, jobs-sg, Open Notebook) did **not** fail over — they are
  being served by a different model with thinking on. ⏳ Homelab follow-up not done:
  `~/projects/homelab/docs/runbooks/dgx-model-swap-homelab-followup.md`; also the
  `dgx-inference` scrape/alerts expect `vllm:*` metrics, which TensorFold doesn't emit.
- ⚠️ **codex needed more than a model-name change**: TensorFold's `/v1/responses`
  accepts **function tools only** (hard-coded, golden-tested) and codex 0.167 also
  sends `namespace` (sub-agents, codex_apps MCP), `tool_search` and `web_search`
  tools → 400. Fixed in B's dgx profile only: catalog `multi_agent_version =
  "disabled"` (setting `features.multi_agent=false` is **not** enough) +
  `supports_search_tool = false`, profile `web_search = "disabled"` +
  `[features] apps = false`. Verified with a real request and an exec tool round
  trip. Any MCP server that connects later brings namespace tools back → 400 again.
- **Memory (MemAvailable)**: after load S1 8.2 → **6.96 GiB idle (5.7%)**, S2 10.3
  GiB (8.4%); the S1 watchdog logs `warn` at idle. Before the switch the cleanup that
  made room: `polkitd` restarted on both (2.85 / **4.15 GiB** → ~9 MiB — the leak
  glm53 hit; it regrows ~0.3–0.4 GiB/week), 6 orphaned 56-day-old `nvidia-smi`
  killed, stale `psm_*` in `/dev/shm` removed (0.6 / 0.2 GiB), S2's 2-month-old xrdp
  desktop session ended. S1's xrdp desktop was left alone (user's call).
- Clients on B (`mbpm5.local`): codex `dgx` and Qwen Code (boot default + a
  `/model` entry) point at `DeepSeek-V4.1-Flash-1017` — both verified with real
  requests. Pre-switch copies: `~/dgx-client-config-backup-20261114.tar.gz`.
  Window on both clients is **262144** since 2026-11-15 (server `CONTEXT` lowered from
  524288). The old "Qwen Code reserves 384K for `deepseek-v4*`" trap does not apply to
  Qwen Code **0.27.0** (measured: hard limit derives from `contextWindowSize`, real
  requests at 262144 work) — older CLIs may still hit it (`scripts/qwen-model-switch.sh`).
- ⚠️ **2026-11-15: S2 lost power twice under `dsv41` load** (03:52 → powered on 16:23 →
  stack restarted 16:29 → dead again 16:50; no BMC, someone had to be at the box both times).
  Not OOM (S2 MemAvailable 10.1 / 10.7 GiB at the last samples), not a software hang (journal
  ends mid-stream, S1's 200G carrier drops = the peer NIC lost power), not a logged thermal trip
  (96 °C on **both** boxes, ACPI critical is 104.8). Same signature as 2026-08-15
  (`docs/s2-outage-2026-08-15-cn.md`). Response: GPU clock cap re-installed on both (2,200 MHz,
  verified), stack restarted 17:32, `make test` green. ⏳ Open: swap S1/S2 power adapters to
  see whether the fault follows the adapter; whether the cap alone holds.
- **2026-11-15 18:52 restart: dual rail + `POOL=1048576`.** Real traffic before it: 57
  requests in 40 min, 39 of them > 50K-token agent sessions (`/v1/messages`), **prefix-cache
  hit 0%**, 50 kept-state evictions — the 262,144-position pool (= `CONTEXT` when `POOL` is
  unset) holds ~2 such sessions. After: first 8 min 48.1% hit, 0 evictions; S1 MemAvailable
  under load 7.0 → **5.79 GiB (below the 5% warn line)**. Dual rail: the CX7 port's PCIe
  twin `enP2p1s0f0np0` now addressed (`/etc/netplan/60-cx7-twin.yaml`, 192.168.201.0/24,
  MTU 9000) → boot shows `rail 0` + `rail 1`, both carry equal traffic; speed-up unmeasured.
  ⚠️ The 08-25 "second cable dismissed" verdict stands, but its reason was wrong: the two
  separate x4 links are the **twins** of one port; the second port shares them.
- **What each change bought** (real traffic, homelab Prometheus `tensorfold:*`; details in
  `stacks/dsv41/recipe.yaml` `measured.config_windows`):
  single rail / pool 262K / 4 streams → **cache hit 18.9%, TTFT mean 36.9 s, p90 150 s**;
  dual rail / 1M / 4 → **75.2%, 13.4 s, 44 s**; dual rail / 1M / **8** → 46.0%, 21.2 s,
  61 s, per-request decode 25.4 → **10.9 tok/s**, aggregate unchanged (pool-bound) → 2M at
  19:19, not yet measured. **The pool did all of it; dual rail measurably nothing** — the
  link peaks at 7.3 Gb/s per rail (~6% of one x4) under live load; TP=2 exchanges here
  are latency-bound, not bandwidth-bound.
- Host changes: `nfs-kernel-server` installed on S1, `/etc/exports` exports
  `~/.cache/huggingface` read-only to `192.168.200.102` (upstream's NFS mode).
- ⏳ Unmeasured: our own throughput ladder / prefill, quality (no aider run on any
  stack since V4-Flash), cold-load time, day-scale memory, prompts > 22K tokens.
