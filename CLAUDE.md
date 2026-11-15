# CLAUDE.md

Guidance for Claude Code (claude.ai/code) and other agents working in this repo.
`AGENTS.md` and `QWEN.md` are symlinks to this file.

**This file is an index, not the manual.** It carries what you need every session
(what runs where, how to drive it, what will bite you). Detail lives in `docs/` —
follow the pointers rather than guessing.

## Project Overview

Deployment tooling for vLLM inference across two NVIDIA DGX Spark (GB10
Blackwell) servers. Every model is a **stack** in the `stacks/` registry —
one is primary, the rest are ways back:

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

> The table above is generated from `stacks/*/stack.env` by `make stack-table`
> and verified by `make stack-check`. **Do not hand-edit it** — edit the registry.

⚠️ **Mutual exclusion is now per-node, not registry-wide** (changed 2026-09-20).
Two stacks conflict when their **GPU node sets intersect** — `STACK_GPU_NODES` in
each `stack.env`, enforced by `stacks/_lib/preflight.sh`. So the single-node
`qwen38un` (S1) and `hibrid48` (S2) *can* run at the same time (they did,
2026-09-20 → 09-30); the TP=2 stacks — `hibrid48tp2` (primary since 2026-09-30)
and `glm53` — collide with every other stack, because a TP=2 stack's **rank1 eats
the other box's GPU** too. Several stacks claim `:8888`, two claim `:18300`.
`make run STACK=<id>` refuses to start against an overlapping stack, and its
preflight still walks **the whole registry**, so a newly added stack is checked by
every existing one without anyone editing a list. It prints which stacks it checked
**and which it skipped**, so "not checked" can't read as "checked and fine".
⚠️ Judging overlap by `STACK_HEAD` alone would call `glm53` (head=S1) unrelated
to an S2 stack and let both onto S2's GPU — that is gotcha #2 on a box with no BMC.
⚠️ **Two multi-node stacks exist again**: `glm53` was the only one from 2026-09-20
(the two k3s TP=2 stacks were deleted) until `hibrid48tp2` was added 2026-09-30.
`scripts/test-preflight.sh` still names `glm53` at the assertion that depends on a
two-node fixture — delete it and check that `hibrid48tp2` (or a synthetic fixture)
keeps the most expensive case in gotcha #2 tested.

⚠️ **One stack is running right now, and it spans both boxes** — `dsv41`
(primary since 2026-11-14: **DeepSeek-V4.1-Flash-1017** EXL3 2.9 bpw on MiaAI-Lab's
two-Spark recipe, TensorFold's native Zig engine; head/API on **S1** `:8000`, rank1
on S2). **The served name changed** to `DeepSeek-V4.1-Flash-1017` — and ⚠️ TensorFold
**accepts any model name** (200, rewrites it to its own in the response), so every
client still asking for `qwen3.8-flash-next-tp2` is now **silently** served by
DeepSeek (gotcha #10). `hibrid48tp2v52` (Qwen3.8-Flash-Next, kit v5.2) is now a
stopped rollback that still owns the name `qwen3.8-flash-next-tp2`; `hibrid48tp2`,
`qwen38un` and `hibrid48` are stopped rollbacks too. **The TP=2 failure class
applies**: never restart one rank — the upstream `./start.sh restart` / `./stop.sh`
and `make restart` move both. Two memory guards: upstream's `scripts/memguard.sh`
on **both** boxes (kills the rank's container at MemAvailable < 2.5 GiB for 4 s,
or < 1 GiB at once), and this repo's systemd `dgx-memwatch@dsv41` resident on S1
(warn 5% / crit 2% ×10, S2 over the 200G link) — `make memwatch-status`.

⚠️ **Five different engines are in play** (vLLM / vLLM+EXL3 overlay / SGLang /
vLLM+PLE-mmap / TensorFold Zig) and **six different thinking-kwarg semantics**. There is no shared
default. They live in each stack's `STACK_THINK_KWARG` / `STACK_THINK_OFF` /
`STACK_COT_FIELD`, and `docs/clients-cn.md` carries the generated cross-stack
table. Getting this wrong is silent — gotcha #9. ⚠️ **The same model can have two
different CoT fields on two different engine builds**: the now-deleted `qwen38fn`
recorded `reasoning_content`, while `fndgx` / `hibrid48` — same checkpoint
family, newer preview images — measurably return `reasoning` and
`reasoning_content` is always `None`.
The lesson outlives the stack: **never infer the CoT field from the model name.**

✅ **Switching the primary stack is `make switch TO=<id>`.** "Which stack is
current" used to be hardcoded in ~8 places that each failed *silently*; it is now
one file (`stacks/PRIMARY`) that every tool reads. What is still manual — codex's
own config files, and the prose in `## Current state` below — is printed by that
command and listed in `docs/stack-switch-cn.md`.

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
- **Flash-Next TP=2, kit v5.2** (`hibrid48tp2v52`, rollback since 2026-11-14, was
  primary 2026-10-22 → 11-14, S1+S2): same hibrid48 checkpoint (hardlinks), vLLM 0.30 + RecoverSSM, dynamic
  K≤7 MTP in full CUDA graphs, one-shot RoCE all-reduce; 64 seats, 2.08M-token KV
  pool. Same-night A/B vs kit v4.1 (`benchmarks/hibrid48tp2v52-2026-10-22/`):
  **thinking-on c1 87–91 vs 77–79 (+14–15%)**, thinking-off c1 111.6 vs 106.9,
  **c64 753 vs 601**, cold prefill unchanged (~3,350 tok/s at 128K).
- **Flash-Next TP=2, kit v4.1** (`hibrid48tp2`, rollback since 2026-10-22, served
  name now `qwen3.8-flash-next-tp2-v41`): 2.45M-token KV pool.
  Same-harness ladder (`benchmarks/hibrid48tp2-2026-09-30/`): **~98.9 tok/s
  single-stream, 562 tok/s @ c64** — vs hibrid48 72.3 / 200.1 and qwen38un
  42.1 / 216.9 on the identical request set.
- **Qwen3.8-27B-Uncensored + SGLang** (`qwen38un`, rollback since 2026-09-30, S1):
  NVFP4 + DFlash2 speculator, single node. Code **45.4** tok/s single-stream;
  **472.7 tok/s aggregate @ c12** on its own harness (**216.9 peak** on the
  09-28 ladder harness). Also multimodal — the only uncensored stack.
- **Flash-Next single-node** (`hibrid48`, rollback since 2026-09-30, S2, bilikaz v4 recipe): 4-bit output
  head + fused K=5 MTP, 105 GiB checkpoint, 830K-token KV pool, `max-num-seqs=16`.
  Same-question A/B (2026-09-28): **1.3–1.6× faster per question at
  equal-or-better four-suite quality** → replaced `fndgx` (RadixArk, 48 GiB PLE
  table, 48.0 tok/s code, 113 tok/s @ c8), which is retired to
  `stacks/fndgx/stack.env.retired-2026-09-28` and still restorable. Data:
  `benchmarks/ab-radixark-vs-hibrid48-2026-09-28/`.
- **GLM-5.3-Flash EXL3** (`glm53`, rollback, **TP=2 across both nodes**): 64.3 tok/s
  structured, 850K nominal ctx. ⚠️ Starting it requires stopping the primary
  (`hibrid48tp2` holds both boxes), and its host headroom (1.8–2.0%) is too low for
  `make memwatch` to run.
- **Qwen3.8-27B stock** (`qwen38`, S1): no speculator, 24.9 tok/s.
  **Slower and weaker, not an upgrade** — it exists as a single-node floor.

⚠️ **Two stacks were deleted on 2026-09-20 together with k3s**: `qwen38fn`
(TP=2 Flash-Next, the repo's fastest single-stream code stack at **62.1 tok/s**)
and `v4flash` (DeepSeek-V4-Flash, the **only** stack with a measured quality
baseline — aider-polyglot 82.4%). Their recipes and manifests are in git history,
not in the tree; their benchmark records are kept under `benchmarks/`. Nothing in
the registry can run them any more, and rebuilding either means rebuilding a
cluster. **Numbers below that compare against them are history, not options.**

**Target hosts** (edit `HOSTS` in Makefile to change):
- `100.97.87.120` — server 1 / `spark-ccf3` (`dsv41`'s head/API + NFS server; rollback `qwen38un`; glm53's / hibrid48tp2*'s rank0)
- `100.67.164.92` — server 2 / `spark-2435` (`dsv41`'s rank1; rollback `hibrid48`; glm53's / hibrid48tp2*'s rank1)
- SSH: `admin` + `~/.ssh/vgio`
- `192.168.200.101/102` — the internal 200G CX7 link. Carries the TP=2 NCCL
  traffic (bypassing the CNI) and inter-node file copies.

## Current state (2026-11-14) — primary is `dsv41` (DeepSeek-V4.1-Flash-1017, TensorFold, TP=2)

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

## Previous state (2026-10-22) — primary was `hibrid48tp2v52` (kit v5.2), same weights

⚠️ *Superseded 2026-11-14: `hibrid48tp2v52` is now a stopped rollback (still named
`qwen3.8-flash-next-tp2`); its watchdog `dgx-memwatch@hibrid48tp2v52` was
uninstalled. The primary is `dsv41` (above).*

**Same model, same boxes, same endpoint and name — newer upstream kit.**
`hibrid48tp2v52` serves the hibrid48 checkpoint (hardlinks of `hibrid48tp2`'s, zero
download) with `myllmbox/qwen38-flash-next-cluster-recipe` @ `v5.2` and image
`myllmbox/qwen38-flash-next-cluster-vllm:v5.2` (image ID `4210dc4b…` = registry
config digest). It took over `qwen3.8-flash-next-tp2` / `fntp2`, so codex `dgx`,
Qwen Code, the LiteLLM gateway and calibre-metadata needed **no change**; the
homelab `dgx-inference` scrape (`:8000`, `vllm:*`) is unaffected too.
Full account: `benchmarks/hibrid48tp2v52-2026-10-22/README.md`.

- ✅ **Same-night A/B, same weights, run on the head** (kit v4.1 vs v5.2):
  thinking-on c1 77–79 → **87–91 tok/s**; thinking-off c1 106.9 → 111.6;
  c12–c24 +14–18%; c32 447 → 554; **c64 601 → 753**; cold prefill flat
  (3,355 → 3,336 at 137K). KV pool 2.45M → **2.08M tokens** (33G/box; still 7.9×
  the window; last week's KV peak would be 54% of it).
- ✅ Thinking semantics, CoT field, `/v1/responses` effort set
  (none/low/medium/xhigh 200; minimal/high/max 400) and RDMA all **identical** to
  v4.1 — `make test` asserts them.
- ⚠️ **Single rail, not upstream's dual rail.** `ib_links: 2` falls back because
  the second ConnectX half (`roceP2p1s0f0`, ACTIVE) has no IPv4 on either box.
  Upstream's v5.2 numbers are dual-rail + INT4-AutoRound; ours are neither.
- **Memory**: boot S1 13.71 GiB (11.3%) / S2 16.90 (13.9%) — 1.5–2 GiB more than
  v4.1's boot; after the full ladder + 128K prefill S1 still 10.0%. ⚠️ v4.1 fell to
  5.4% after the same suite, but that arm also absorbed a real ~160K-token request,
  so "v5.2 doesn't creep" is **not established** — read the Prometheus trend.
  Context: under v4.1, S1 MemAvailable drifted −0.13 GiB/day from the 09-30 boot
  (AnonPages, i.e. engine RSS), reaching 4.4–4.7% daily minimum by 10-21; a both-rank
  `make restart` on 10-22 reset it.
- **Usage last week** (homelab Prometheus, 10-15 → 10-22): ~8.3K requests
  (~1,180/day, rising), 88K-token average prompt at 95% prefix-cache hit, engine
  busy 12% of the time, max 10 concurrent of 64 seats, busiest 00–04 CST. One
  ~160K-token prompt stalls everyone's decode for ~50 s (chunked prefill) — v5.2
  does not change that.
- ⏳ Unmeasured on v5.2: INT4-AutoRound (upstream default, needs ~122 GB),
  dual rail, multimodal.
- **Day-scale memory, first read (10-27, Prometheus daily min)**: after a ~0.9 GiB
  drop on day 2, S1 loses ~0.1 GiB/day (10.90 → 9.80 GiB over 10-24 → 10-27); S2
  13.95 → 13.40. So v5.2 **does** creep, at about v4.1's rate — roughly a month to the
  5% warn line. Three points only.
- **Watchdog moved onto S1 (10-27)**: `dgx-memwatch@hibrid48tp2v52` (systemd). The
  same night Mac → S2 over Tailscale was down 40+ min (S2 and the 200G link fine) and
  the Mac-side watchdog had logged S2 `unreachable (skip)` since 22:41 — i.e. S2 was
  unguarded. Verified: banner shows `100.67.164.92→192.168.200.102 100.97.87.120→local`;
  a drill (own state/log, stop action `echo`, crit 99%) fired after 2 ticks, ran the
  stop locally, held; the live stack was untouched.
- ⏳ **Upstream kit v5.3 (10-21) / v5.3.1 (10-23) not adopted.** v5.3.1's prefill
  checkpoints (64-token cache hits) target what this workload pays most: ~6.5K tokens
  recomputed per request, TTFT p50 1.6 s / p90 4.6 s (5-day Prometheus). Not a drop-in:
  vLLM 0.32, NVIDIA FP4-Local default checkpoint (HF-only), hibrid48 unmeasured upstream
  on v5.3, gmu 0.75 + fp8 KV. Needs its own same-weights A/B.

## Previous state (2026-09-30) — primary was `hibrid48tp2`, TP=2 across both boxes

⚠️ *Superseded 2026-10-22: `hibrid48tp2` (kit v4.1) is now a stopped rollback with
served name `qwen3.8-flash-next-tp2-v41`; the primary is `hibrid48tp2v52` (above),
which carries the name `qwen3.8-flash-next-tp2` and the watchdog session
`memwatch-hibrid48tp2v52`.*

**One stack now holds both GPUs**: `hibrid48tp2` — the same hibrid48 checkpoint
(byte-identical, HF rev `e316057d`) served by myllmbox's two-box kit
(`myllmbox/qwen38-flash-next-cluster-recipe` @ `4e4747b`, v4.1): vLLM 0.30,
TP=2 over RoCE, K=5 MTP, 64 seats, 2.45M-token KV pool. Head/API on **S1**
`:8000` `qwen3.8-flash-next-tp2`, rank1 (`--headless`) on S2. `qwen38un` and
`hibrid48` are **stopped** rollbacks. Account: `stacks/hibrid48tp2/` +
`benchmarks/hibrid48tp2-2026-09-30/README.md`.

- ✅ **Same-harness numbers** (the 09-28 ladder's request body, verbatim):
  single-stream **~98.9 tok/s** (upstream says 99 — reproduced) vs hibrid48
  72.3 / qwen38un 42.1; c24 **380.7** vs 200.1 / 212.6; peak **562.2 @ c64**,
  still rising. Both boxes on one model ≥ the *sum* of the two single-node stacks
  (c48 508.6 vs 200.1 + 212.6). The price: only one model is online —
  qwen38un's uncensored 27B is not.
- ✅ Boot invariants identical to upstream: KV pool 2,450,356 tokens (9.35× the
  262K window), 51.03 GiB of weights per rank, `/health` in ~4 min.
- ✅ **Upstream's own headline numbers reproduce, measured their way**
  (README §7): steady-window c64 **783.9** vs their 793; cold prefill (on the head,
  localhost) **3,308–3,431 tok/s from 8K to 128K** vs their 3,222–3,313. c1–c32 run
  8–15% below their tok/s at an **equal-or-faster engine step rate** — the gap is
  draft acceptance (4.0–4.1 vs 4.7–4.9 tok/step), i.e. prompt content (inference;
  their harness is private). ⚠️ A 128K prefill takes S2 down to **8.0 GiB (~6.6%)**;
  256K was not tried.
- ✅ `make test STACK=hibrid48tp2`: only `chat_template_kwargs.enable_thinking`
  toggles thinking (top-level is silently ignored); CoT in `reasoning`; and
  **NCCL really is on RDMA** (843 MB on the HCA counter vs 0 MB TCP during one
  generation — the kit's own warning is that TCP fallback is silent and ~2× slower).
- ⚠️ **`/v1/responses` effort set differs from hibrid48 single-node**:
  none / low / medium / xhigh → 200, **minimal / high / max → 400** here, where
  hibrid48 recorded `high` as 200. Same checkpoint, different engine build —
  gotcha #9 again. The codex catalog lists only the four that pass.
- **Memory (MemAvailable)**: boot S2 10.5% / S1 12.0%; after the c1→c64 ladder
  9.7% / 11.1%. That is a ~15-minute steady, **not a 2-hour one** (qwen38un's
  0.85 lesson). One watchdog, both nodes, in a tmux on the Mac:
  `WATCH_WARN_PCT=5 WATCH_CRIT_PCT=2 WATCH_CRIT_CONSEC=10 make memwatch
  STACK=hibrid48tp2` (session `memwatch-hibrid48tp2`, banner read).
  ⚠️ **Before this, no watchdog was running anywhere findable** — no tmux server
  on `mbpm5.local`, only `xrayfix*` sessions on the nodes. The `memwatch` /
  `memwatch-hibrid48` sessions described below were either on the other Mac or
  gone; assume nothing guards a stack until you have read its banner.
- **The image could not come from a mirror.** `docker.1ms.run` serves the
  manifest but its blobs redirect to Cloudflare and get reset; daocloud
  allowlist-denies `myllmbox/*`. 37 of its 40 layers are a byte-identical prefix
  of S2's single-node `:v4` image, so only 3 new layers (36 MB) were fetched —
  through S1's xray proxy (`--socks5-hostname 127.0.0.1:10808`) — into a partial
  `docker load` archive on S2, then `docker save | docker load` to S1 over the 200G
  link. Image ID `4d03fc80…` = the registry's arm64 config digest.
- **Clients** (this Mac is `mbpm5.local` = "machine B" below): `codex --profile
  dgx` → `100.97.87.120:8000` `qwen3.8-flash-next-tp2`, plus the Qwen Code boot
  default and a `/model` entry — both verified with real requests. Two drifts on
  this machine were fixed on the way: the dgx profile had **regressed** to the
  deleted `qwen38-flash-next` slug in a write at 09-21 05:02 (its 09-19 23:30
  backup was correct; cause unknown — and SGLang answered any name, so nothing
  complained for nine days), and qwen's load-bearing `security.auth.baseUrl`
  pointed at S1 while `model.baseUrl` pointed at S2. The same day B's dead
  profiles (`fndgx` / `qwen38` / `litellm`) and all config `.bak`s were archived and
  removed — see `## Connecting from clients`. ⚠️ Still pointing at a stopped stack:
  the litellm gateway's DGX routes (`custom_dgx/qwen3.8-27b-sglang`; config lives
  in the homelab repo) and machine A's `fndgx` profile — A was not touched.
- ⏳ Unmeasured here: prefill / long context, quality (same checkpoint as
  hibrid48, whose A/B stands; not re-run on TP=2), multimodal, 2-hour memory.

## Previous state (2026-09-28) — S2 switched to hibrid48; fndgx retired

⚠️ *Superseded 2026-09-30: `hibrid48` is now a stopped rollback; the primary is
`hibrid48tp2` (above). The memwatch sessions described here were not found running
on 2026-09-30.*

**The S2 Flash-Next endpoint now serves bilikaz's `hibrid48`** — the same model
as fndgx (Qwen3.8-Flash-Next NVFP4), a different engine build: 4-bit output
head, 105 GiB checkpoint, 830K-token KV pool, fused K=5 MTP,
`max-num-seqs=16`. The switch was decided by a same-question A/B
(`benchmarks/ab-radixark-vs-hibrid48-2026-09-28/`): **1.3–1.6× faster per
question (median 1.27–1.41×) at equal-or-better four-suite quality (Δ ≤ 2/200,
sampling noise) — no intelligence regression.**

- **External clients unchanged.** hibrid48 took over fndgx's whole external
  identity: `:18300` / served name `qwen3.8-flash-next` / client alias `fndgx`.
  S2's `recipe.yaml` carries exactly two local deviations from upstream (port
  8000→18300, served name). Verified with real requests: `/v1/models`,
  `/v1/chat/completions`, `/v1/responses` (effort xhigh / none). So
  `codex --profile fndgx`, the qwen settings and the litellm gateway all keep
  working with **zero changes** — the profile is still *named* `fndgx`, it just
  reaches hibrid48 now.
- **Registry**: `stacks/hibrid48` added (stack.env / launch.sh / preflight.sh /
  test.sh / recipe.yaml); `stacks/fndgx/stack.env` renamed to
  `stack.env.retired-2026-09-28` — fndgx is out of the registry but restorable
  (recipe + runbook + the 126 GiB RadixArk weights all remain on S2; the two
  weight sets hardlink-share disk). `make stack-table / stack-check /
  preflight-test / memwatch-test` all green after the change.
- ⚠️ **Thinking semantics differ from fndgx** (gotcha #9, new instance):
  top-level `enable_thinking` is **silently ignored** on hibrid48 (measured:
  72 reasoning tokens with `false`); only `chat_template_kwargs.enable_thinking`
  really toggles it. CoT still comes back in `reasoning` (`reasoning_content`
  always None). `/v1/responses` accepts low/medium/high/xhigh + none.
  `stacks/hibrid48/stack.env` carries the measured values; `make test
  STACK=hibrid48` asserts them.
- **Watchdog handover**: `memwatch-fndgx` killed (it had been holding "fired"
  since 09-27 21:12, during the 105 GiB weight download — its crit line was
  tuned for a stack that no longer exists). `memwatch-hibrid48` runs with
  `WATCH_WARN_PCT=3 WATCH_CRIT_PCT=1 WATCH_CRIT_CONSEC=10` — the stack idles at
  ~2.4% available **by design** (bilikaz's recipe leaves ~2G), so the stock
  crit=5% fires on startup. ⚠️ The first run proved it: at 09-28 09:57 a
  page-cache reclamation dip to 1% (2 consecutive ticks) stopped a healthy
  engine. It was restarted and the watchdog re-armed with a 100 s crit debounce
  (`WATCH_CRIT_CONSEC=10`) so only sustained ≤1% pressure kills it. If it fires
  again at idle, investigate the actual memory drain before just re-arming.
- ⏳ **Unverified on this stack**: long context (262K configured, ~52K
  longest prompt sent), multimodal (fndgx's image path was tested; this one's
  isn't).
- ✅ **Verified on this stack**: aggregate concurrency ladder was re-measured on 2026-09-28. Scaled smoothly up to `max_num_seqs=16`, peaking at ~200.1 tok/s aggregate. This decisively broke through the previous `fndgx` ceiling of 113 tok/s.

## Previous state (2026-09-20) — k3s removed; two docker stacks: qwen38un on S1, fndgx on S2

⚠️ *Superseded as of 2026-09-28 for S2: `fndgx` was replaced by `hibrid48` (see
the Current state section above). Everything below about S2/fndgx is history;
the fndgx stack files remain on S2 and can be restored if needed.*

### k3s is gone from both nodes (2026-09-20)

✅ **The cluster is uninstalled, not stopped.** Both stacks that lived on it
(`qwen38fn`, `v4flash`) are deleted from the registry; `adapter-k3s.sh`, `k8s/` and
the per-stack manifests are gone with them. **`docker` is now the only runtime.**
What that bought, measured before and after: **80 GB of disk per node**
(`/var/lib/rancher`, a pure duplicate — every image was still in docker on both
nodes) and **~0.5 GiB host RSS on S1 / ~1.0 GiB on S2**. On S2 that is ~0.8 points
of the headroom that `fndgx` only has 2.7 points of.

⚠️ **The dangerous part was not k3s, it was Cilium.** `k3s-killall.sh` strips only
`KUBE-`/`CNI-`/flannel iptables rules (docker's chains survive — that part is safe),
but it does **not** touch Cilium: tcx BPF programs (`cil_from_netdev`/`cil_to_netdev`)
were attached to both physical NICs **and to `tailscale0`, the only remote path into
these boxes**, pinned in bpffs so they outlive the agent by design. Uninstalling k3s
and walking away would have left them attached with no agent behind them.
The removal therefore ran, per node, as one detached script: uninstall k3s → detach
tcx → `rm -rf /sys/fs/bpf/cilium /sys/fs/bpf/tc` → delete `cilium_*`/`lxc*` links →
strip `CILIUM_*` iptables → self-test with an automatic `tailscaled` restart on
failure. **Order matters**: Cilium's datapath keeps working correctly after its agent
dies, so removing k3s first is safe, while detaching BPF first just makes the live
agent re-attach it.
Verified after, on both nodes: `bpftool net show` empty, bpffs down to `snap`,
`iptables-save | grep -c CILIUM` = 0 while the DOCKER chains are intact (S1 18 /
S2 20), no k3s units or binaries, routes clean — and **both endpoints answered a
real generation**, not just `/v1/models` (gotcha #1's lesson).

⚠️ **What was given up, deliberately:** `qwen38fn` was the fastest single-stream
code stack this repo ever measured (62.1 tok/s) and `v4flash` held its only quality
baseline (aider-polyglot 82.4%). `glm53` is now the **only** rollback, and starting
it requires stopping both live stacks.

### fndgx on S2

**S2 is no longer idle.** `stacks/fndgx` — Qwen3.8-Flash-Next NVFP4 served from
**one** node via blazux/qwen3.8-Flash-DGX, which `mmap`s the 48 GiB PLE n-gram
table off NVMe instead of holding it in GPU memory. That is the whole trick: same
model as the retired `qwen38fn`, one box instead of two. `:18300`
`qwen3.8-flash-next`. Full account: `stacks/fndgx/recipe.yaml` + `runbook-cn.md`.

✅ **Zero download.** S2 already had the 126 GiB RadixArk checkpoint (fetched for
`qwen38fn`, 2026-09-02) and the exact base image digest the Dockerfile pins. The
HF-cache layout upstream expects is a view built out of **relative** symlinks over
the existing flat directory — which is also why deleting `qwen38fn` cost no weights.
⚠️ **NVIDIA's checkpoint was not a choice**: `huggingface.co` is unreachable from
the nodes, so RadixArk is forced (upstream's own numbers: −2.7 quality points,
+2.6 tok/s, −15-22% KV).

⚖️ **Single-stream: 48.0 tok/s code / 46.6 structured / 35.3 prose** (warm median
of 3, non-streaming, thinking off, `native` profile, clock cap off). That is ~77%
of the retired `qwen38fn`'s 62.1 on half the hardware, and nominally above the primary's 45.4
— ⚠️ **but those were measured by different harnesses; the same-harness comparison
has not been run**, so treat it as an order of magnitude, not a ranking.

✅ **It hits upstream's published RadixArk numbers on every axis they publish.**
Full data + scripts: `benchmarks/fndgx-2026-09-20/`, plus
`benchmarks/fndgx-seqs-2026-09-20/` for the rejected `SEQS` run and the PLE
counters.
Numbers below are **after the 2026-09-20 clock-cap removal** (capped values in
parentheses):
- **Single stream, prose: 35.3** (34.7) vs upstream's RadixArk **37.1** → −4.9%.
- **c4, per stream: 23.0** (21.0) vs upstream's RadixArk **21.6** → **+6.5%, ahead**.
- **Prefill, warm, cache-defeating prompts: 2,385 @ ~13.0K** (2,297) **and 3,050 @
  ~51.7K** (2,810) — upstream reports 2,400–2,900 at 8K and 2,500–3,000 at 32K, so
  the 51.7K figure is now **above** its band at a 60% *longer* prompt.
- `./flash setup` reports all four stages already satisfied — the manual install
  landed in exactly the state upstream's own installer produces.

⚠️ **Aggregate throughput flatlines at c8 = 113 tok/s, and `SEQS=8` is what caps
it — not the hardware, and not the clock.** c8 112.4 → c12 111.1 → c16 113.1,
while worst-case latency goes 24.0 s → 43.8 s: the shape of requests queueing
behind `max_num_seqs`. Removing the clock cap moved this peak by **+1.2%**
(111.1 → 112.4) while it moved c4 by +9.5% — further evidence the ceiling is the
sequence limit, not the silicon. Upstream states this trap outright ("a low `--max-num-seqs` is
indistinguishable from saturation if you only look at tok/s") and the sweep it
cites keeps scaling to **c48 = 266.8 tok/s** with page-fault cost per token
*falling* 4.4× — the paged table is an argument *for* concurrency. ⏳ **`SEQS` has
never been tuned here**; the KV pool (496,770 tokens) is nowhere near binding for
short requests. Raising it should buy a lot, at the cost of upstream's other
finding (decode starves during concurrent prefills; mitigation
`--long-prefill-token-threshold 1024`), and needs a re-measure.
⚠️ The retired `qwen38fn` — same model, TP=2, same `max_num_seqs=8` — was recorded
at **~304 tok/s @ c8** against our 112.4. Two nodes → one explains 2×, not 2.7×; the
rest is unexplained (likely the mmap'd PLE table's page-fault cost under batch).
**But the two numbers come from different harnesses — not a ranking, and now not
re-runnable either: that stack was deleted with k3s on 2026-09-20.**
⚠️ **The KV pool is ~15% below upstream's own RadixArk figure, and that part is
still unexplained.** Upstream publishes a RadixArk-vs-NVIDIA table: RadixArk
**589K tokens** @ `GPU_MEM=0.80`, ctx 500K, weights 77.3 GiB; NVIDIA 679K (+15%).
We get **500,000 tokens**, consumed 81.85 GiB. Two separate deltas, do not
conflate them:
- **679K → 589K is RadixArk's own documented cost**, and the boot log names it:
  `modelopt block-moe: experts mtp.layers.48.mlp.experts -> checkpoint algo None`
  — RadixArk leaves the MTP draft experts in bf16 where NVIDIA quantizes them
  ("~3.4 GB less on the card", "+22% KV"). Both fixes need `huggingface.co`,
  which the nodes cannot reach.
- **589K → 500K is ours and is not accounted for.** Likeliest mechanism, untested:
  `GPU_MEM` is a fraction of **total** device memory, not free memory — upstream's
  own words — and S2 had only 113.24/121.69 GiB free at startup (k3s server,
  Cilium, desktop, node-exporter). ⚠️ Don't assume it was k3s: stopping k3s
  entirely once bought glm53 just **+0.11 GiB**.
  ✅ **The experiment got cheaper on 2026-09-20** — k3s is now uninstalled, worth a
  measured **~1.0 GiB** of S2 host RSS. So the next `fndgx` restart reads
  `Available KV cache memory` under strictly more free memory, for free, with no
  setup. ⏳ **Not yet done** — the stack has not been restarted since. If the pool
  is still 500,000 tokens, k3s was never the mechanism and the delta is elsewhere.
⚠️ **Lowering the context does not buy KV pool** (tested 2026-09-20): 500K+YaRN →
13.54 GiB / 500,000 tokens / 1.00x, versus 262144 native → 14.03 GiB / **496,770
tokens / 1.90x**. The pool is set by what is left after weights and activations,
**not** by `max-model-len`; only the concurrency ratio moves. Decode is unchanged
within noise. The stack now runs the `native` profile — `STACK_CTXWIN=262144`.
⚠️ **Do not take vLLM's `--kv-cache-memory=…29.29 GiB "to fully utilize gpu
memory"` at face value on GB10.** GPU and host memory are one pool, and the
leftover is the page cache the mmap'd 48 GiB PLE table runs on; upstream's own
words are "claiming it trades prefill for KV". Host headroom is ~13%.
⚠️ **A wrong conclusion was published here for about an hour**: "prefill 1,482
tok/s, gap to upstream unexplained". That was a **cold, first-of-its-shape**
request compared against upstream's warm table — the exact trap
`docs/benchmarking-cn.md` documents ("first request at a new prompt shape is ~43%
slow"; 1,482 × 1.43 ≈ 2,120). **Upstream perf tables are warm; quoting a cold
number against one compares two different things.**

⚠️ **Host headroom on S2 is 10.7% steady, against memwatch warn=8% / crit=5%.**
Only 2.7 points of margin — and this repo learned on `qwen38un` that **boot
headroom is not steady headroom** (0.85 there looked fine at 9.4% and decayed to
5.0% in two hours). fndgx has only been watched for tens of minutes. Part of the
low figure is by design: the mmap'd PLE table *wants* page cache.
**Never raise `GPU_MEM` above 0.80** — upstream reports 0.85 drifting into swap
after a day and 0.875 OOM-killed on a 300K prefill; swap is off here and there is
no BMC. To buy margin, lower it.

✅ **Its own watchdog is resident** (tmux `memwatch-fndgx`, `nodes=[100.67.164.92]`,
startup banner read). Two watchdog instances now run, one per stack; state and log
files are per-stack so they don't collide.

⚠️ **The rollback is now one stack, and it is blocked by both live ones.** `glm53`
is TP=2 across both nodes, so `make run STACK=glm53` aborts naming `qwen38un` *and*
`fndgx`; both have to stop first. Until 2026-09-20 there were three rollback
targets and the S2 one could be freed with a single `make stop STACK=fndgx` —
deleting `qwen38fn` and `v4flash` with k3s spent that margin. **`qwen38` (S1,
24.9 tok/s, no speculator) is the only thing that can come up without stopping
`fndgx`.**

🔧 **One local deviation from upstream**, and only one: 7 `ADD` lines in the
Dockerfile fetch from `raw.githubusercontent.com`, which times out from the nodes;
they now point at `cdn.jsdelivr.net/gh/…@<same commit>`. The `--checksum=sha256:`
pins are untouched and all 7 files were verified byte-identical first, so BuildKit
still validates exactly what upstream intended. Re-apply after any upstream pull.

⏳ **Still unmeasured on this stack:** quality (aider-polyglot is now **four
stacks** behind — and with `v4flash` deleted, the 82.4% baseline it was measured
against can no longer be re-run, only read out of
`benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/`), long context (262K
configured, ~52K is the longest prompt actually sent), a `SEQS` sweep, MTP=3,
hybrid-mtp, and fp8-KV 1M. ❌ The same-harness concurrency comparison against
`qwen38fn` is **no longer possible** — that stack is deleted.

### Previous state (2026-09-19) — Qwen3.8-27B-Uncensored + SGLang primary, single-node

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
Flash-Next was, at the time, the fastest single-stream code stack in the repo.
⚠️ **It was deleted with k3s on 2026-09-20; 45.4 is now the best measured.**
Also **−17% vs upstream's own 54.6** for the same recipe; partially explained
(compressed-tensors −3%, acceptance 6.12 vs upstream 6.71), plausibly the rest is
the DFlash2 draft being trained against the *stock* target while ours is
abliterated — **hypothesis, not verified.**

✅ **Uncensored verified** (`stacks/qwen38un/test.sh`): 3/3 benign-over-refusal
probes answered. The vendor's 64–99% → 0–6% harmful-refusal claim is **not**
independently verified here, and capability regression was not measured.

✅ **It is multimodal — and this repo had never noticed.**
`Qwen3_5ForConditionalGeneration` with a 27-layer ViT inside the weights (333
`visual.*` tensors, **left in bf16**: they sit in `quantization_config.ignore`, so
NVFP4 never touched them). SGLang turns it on from `config.json` by itself —
**we pass no flag for it**, which is exactly why nobody saw it. Verified live
2026-09-20: four-quadrant colors and their order correct, `image_tokens=64`, and
**DFlash2 keeps accepting on image requests** (accept len 2.70–3.24) — images do
not cost you the speculator. `make test STACK=qwen38un` now covers it, gated on
`image_tokens > 0` rather than on the answer looking right (a dropped image still
produces a confident description — gotcha #9's shape).
⚠️ base64 data URIs only (no outbound net from the nodes); **video is untested and
likely broken** (the image has no `torchcodec`, though the weights ship a video
preprocessor — *a config file existing is not a working path*); and **visual
quality is entirely unmeasured** — naming four colored squares is not reading a
chart or a screenshot. `docs/clients-cn.md` §发图.

✅ **`mem-fraction-static` is 0.80**, not upstream's 0.90 — and **0.85 is a tried
and rejected middle step, not a safer-looking alternative.** Both lower values
were adopted to buy back the OOM guard, because these boxes have **no BMC**:

| fraction | headroom at boot | steady (after ~2 h) | memwatch | KV pool |
|---|---|---|---|---|
| 0.90 (upstream) | 6.10 GiB (5.0%) | — | ❌ fires on its first tick | — |
| 0.85 (rejected) | 11.4 GiB (9.4%) | **7.4 → 5.0%** | ❌ **fired at 2 h 10 m; stack stopped** | 1,368,663 |
| **0.80 (live)** | **17.4 GiB (14.3%)** | ~11% | ✅ stable | 1,220,951 |

⚠️ **Boot headroom is not steady headroom.** At 0.85, 9.4% at boot looked safe and
decayed to 5.0% after two hours of serving + benchmarking. What drifts is the
engine's own host RSS (`sglang::scheduler` 4.4 GiB + detokenizer 1.4 + python3
1.7), growing with request history / radix-cache metadata — `drop_caches`
reclaimed only 137 MiB. **Tune this against the steady value, never the boot one.**

⚠️ **"Use the higher value and let it self-recover" does not work here** — the
watchdog is *deliberately* no-auto-restore (anti-thrash; `scripts/mem-watch.sh`
header + `docs/auto-mitigation-cn.md`). At 0.85 the measured outcome is the stack
**stopped and staying stopped** until someone runs `make memwatch-reset`.

✅ **memwatch verified resident, one instance** (2026-09-19 20:40, tmux session
`memwatch`, `nodes=[100.97.87.120]`, startup self-check passed). Still: this is a
claim about host state, which no file can keep current. `make memwatch-check` is
read-only and answers it in a second — **assume nothing is guarding until you
have looked.**

⚠️ **A fixed bug stays alive in an already-running process.** That check found
**three** watchdogs, started 19:40 / 19:43 / 19:46 during the stack switch. Two
predated 9e4dc2f and were still running its bug: `nodes=[both]` on a single-node
primary, while `tick()` acts when **any** node drops — so anything memory-heavy on
the idle S2 would have stopped the primary on S1, two unrelated things. They were
quiet only because S2 happened to be empty. Generalize it: **`git log` says the
bug is fixed; it says nothing about the daemon you started before the fix.** After
patching anything long-running (memwatch, a tmux loop, a sidecar), restart it and
re-read its startup banner — that banner is what it is *actually* guarding.

`max_running_requests` is 12 at **both** 0.85 and 0.80, so that penalty is not
0.80's. ⚠️ **What caps it is the mamba state cache, not KV** — the boot log says so
outright (read 2026-09-20, after months of the docs saying only "12"):
`64 // 5 = 12`, where 64 is solved from free memory and 5 is the per-request state
slot ratio that radix caching costs. The KV pool is **4.7× the context**, so
*staring at KV can never explain 12* — which is why it stayed a bare number.
Three knobs exist (`--mamba-full-memory-ratio`, `--max-mamba-cache-size`,
`--mamba-ssm-dtype bfloat16`). ✅ **One has now been tried** (2026-09-28, in
`launch.sh` and in the live boot args) — and **it bought nothing**: the boot still
prints `max_mamba_cache_size=64, 5 state slots per request` →
**`max_running_requests` stays 12**, `ssm_state` still 4.57 GB, i.e. the promised
"halve the state size" never happened. The cap moves with the **other two** knobs
(more memory), not with the dtype. 0.80's throughput is still unmeasured (above). The c16 fallback to 356 tok/s is this cap's direct
consequence — **an owned to-do, not a mystery.**
**Never 0.95** — upstream hard-rebooted a box on it. Override chain:
start.sh 0.95 → start-dflash.sh 0.90 → our `DF_EXTRA` 0.80, argparse last-wins.

⏳ **Throughput at 0.80 has not been re-measured.** The headline numbers below
(472.7 tok/s @ c12; decode 58.5 / 45.4 / 24.0) were taken at **0.85**
(`benchmarks/qwen38un-2026-09-19/README.md` §throughput says so). KV went
1.37M → 1.22M tokens while `max_running_requests` stayed 12, so the expectation
is "no change" — **but that is an expectation, not a measurement.**

✅ **The TP=2 failure class is gone** with a single-node primary: no zombie
collectives (gotcha #1), no cross-node NCCL/RoCE, no lockstep restart rule. S2 was
idle at 116 GiB, and k3s ran with all four k3s deployments at 0 replicas, so
`make run STACK=qwen38fn` was a one-command rollback to the 62.1 tok/s stack.
⚠️ **Superseded twice:** S2 got `fndgx` on 2026-09-20, and later the same day k3s
was uninstalled and `qwen38fn` deleted — **that rollback no longer exists.**
⚠️ **Superseded 2026-09-20:** S2 now runs `fndgx`, so that rollback first needs
`make stop STACK=fndgx`. See `## Current state`.

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
⚠️ **2026-09-20: one drift survived that verification.** `dgx.config.toml`'s comment
has read "default to medium" since 2026-09-03 while the value stayed `xhigh` —
across two stack switches. Nothing caught it because **both values return 200**.
Now `medium`, replayed → 200. Generalize it: sending a real request proves the
endpoint works, **not that the value you sent is the one you decided on.**
⚠️ **2026-09-20, a second drift of the same family, found the same way.** The
client-cleanup section of `docs/clients-cn.md` described a `~/.codex` that did
not exist: it claimed `bifrost.config.toml` was deleted (it was not), that
`[model_providers.bifrost]` was gone from every config (it was in `config.toml`),
and it named four per-profile catalogs that were nowhere on disk. The actual
cleanup then ran: two dead slugs out of the catalog (A's shared `models.json`,
B's `dgx-models.json` — two machines, see `## Connecting from clients`), the `deepseek` and
`bifrost` profiles deleted, the dead `:8000` entry out of `~/.qwen/settings.json`,
`BIFROST_VK` and `alias codex-dgx` out of `~/.zshrc`. Generalize it: **`~/.codex`
is not in git, so writing "cleaned up" in a doc is the only record there is —
and nothing will ever tell you it was never true.** Paste measured output, not
intent.

✅ **`scripts/gb10-clock-cap.sh` is on the new stack and re-verified** — cap is
live (rank0 2183 MHz under load, n=29). Three things had to change beyond the
model name, each found by testing rather than reading:
- **SGLang ignores `min_tokens`** (vLLM honors it): the old load prompt returned
  **2 tokens**. Swapped to a counting prompt that generates 300+ on its own.
- **SGLang accepts any model name** → the "wrong `CAP_MODEL` gets 404'd" gate was
  silently dead here. Now it compares `/v1/models` first (gotcha #10).
- **Single-node stack ⇒ `peer/rank1` samples an idle S2** (207 MHz). The script
  now labels that line as not-a-verdict instead of printing a bare number that
  reads like a failure.

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
⚠️ **Re-check before trusting these figures**: k3s was *uninstalled* on 2026-09-20
(worth ~0.5 GiB RSS on S1, ~1.0 on S2 — more than the +0.11 GiB that merely
*stopping* it bought), so glm53's headroom numbers above are all pre-removal.

⏳ **Quality is unverified — and this debt is now two stacks deep.** EXL3 4bpw's
KLD 0.0246 (≈ official FP8) is malaiwah's independent panel, not ours.
aider-polyglot has been run against *neither* GLM nor Flash-Next. V4-Flash
baseline: `benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/` (82.4%).

🔧 **Transient host state (restore when done):** k3s was **stopped on both nodes**,
so the two k3s rollback stacks could not start. Graphical session and `sparkDash`
also stopped. **Clients had NOT been switched** — codex/qwen still pointed at
`:8000` `qwen38-flash-next`, which was down.
⚠️ **Both halves are now moot, in opposite directions:** clients were switched and
verified on 2026-09-19 (see above), and k3s was **uninstalled** on 2026-09-20 —
there is nothing left to restart, and `sudo systemctl start k3s` will simply fail.

Earlier state (S2's 2026-08-15 power death and the 6.5 h recovery — no BMC/IPMI,
WoL failed, needed someone at the box) is post-mortem'd in
`docs/s2-outage-2026-08-15-cn.md`.

## Common Commands

**One set of verbs drives every stack.** `STACK=` picks the target; leaving it
off means the current primary (`stacks/PRIMARY`). The Makefile does not know any
stack's name — see `stacks/README.md`.

```bash
make stacks                     # the registry: who's primary, ports, served names
make info                       # the current primary in detail (thinking kwarg, CoT field…)

make run                        # preflight (whole-registry mutual exclusion) then start
make run     STACK=glm53        # …a specific stack
make status  STACK=hibrid48     # containers + /v1/models + free -h
make test    STACK=qwen38un     # smoke test — gated on /v1/models matching the registry
make logs    STACK=glm53 WORKER=1      # rank1 (dual-node stacks only — glm53 is the last one)
make boot-log STACK=glm53       # this boot's launcher output (not the engine log)
make load                       # who is using the engine right now
make stop / make restart        # restart always moves BOTH ranks (gotcha #1)

make switch  TO=glm53           # change the primary stack, with acceptance checks
make stack-check                # registry self-consistent + doc tables not stale
```

Per-stack notes that the verbs don't carry:

- **glm53** — runs the *upstream* `start.sh`. ⚠️ Never run it by hand: without
  `SKIP_BUILD=1` the launcher decides the image recipe stamp is stale and
  **rebuilds the image on S1**, which is what OOM'd the head on 2026-07-04. That
  stamp can *never* match (`overlay_recipe_hash()` feeds absolute paths to
  `sha256sum`), so its `stamp X != repo Y` warning is permanent noise, not a
  signal. `make run STACK=glm53` passes `SKIP_BUILD=1` for you.
  It also carries an extra host-memory gate (`stacks/glm53/preflight.sh`) because
  the first boot failed on it: S2's `polkitd` had grown to 6.27 GiB RSS, leaving
  103.09 GiB free vs the 103.44 GiB `gpu-memory-utilization` wanted — short by
  0.35 GiB, surfacing only 3 minutes in as a CUDA-layer `ValueError`.
  Fix: `sudo systemctl restart polkit`. Upstream hit the same growth (their #193).
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
- **hibrid48tp2v52** (rollback since 2026-11-14) — the same two-box kit at **v5.2**,
  under `/home/admin/hibrid48tp2v52-recipe/` on the head (**S1**), `cluster.env`
  copied from `hibrid48tp2`'s, weights hardlinked at that dir's `models/` on both
  boxes. Same container name (`qwen38-flash-next-cluster`) as `hibrid48tp2`, so the
  two exclude each other and either one's `./stop.sh` stops whichever is running.
  `run.sh` waits for ≥100 GB available on both boxes **before** it creates the
  container — "no container yet" right after `make run` is not a failed boot.
  The v5.2 image could not be pulled by the nodes: its 30 new layers (44 MB, the
  first 37 are shared with `:v6`) were fetched through S1's xray proxy into a
  partial `docker load` archive. ⚠️ Docker Hub tokens expire in ~5 min — refresh
  per blob and use `curl -f`, or a 401 body gets written into the blob and a
  resumed download can never pass its sha256.
- **hibrid48tp2** (rollback since 2026-10-22, kit v4.1, served name
  `qwen3.8-flash-next-tp2-v41`) — the upstream myllmbox **two-box** kit, laid out
  as-is under `/home/admin/hibrid48tp2-recipe/` on the head (S1). `run.sh` reads
  `recipe.yaml` (model side, three local deviations) and a **hand-written**
  `cluster.env` (box side — interactive `setup.sh` would offer the 10.14.20.x LAN
  as a second "interconnect" and stop to ask), then ssh's to S1 itself to start
  rank1. `./stop.sh` removes both containers. Weights must sit at the **same
  absolute path** on both boxes (S2's are hardlinks of hibrid48's; S1's a
  sha256-verified copy). `stacks/hibrid48tp2/preflight.sh` blocks on a missing
  `cluster.env`, broken head→worker ssh, or a box without `/dev/infiniband`
  (NCCL would silently fall back to TCP at ~2× slower).
- **hibrid48** — single-node, head **S2**. Serves bilikaz's
  `myllmbox/qwen38-flash-next-vllm:v4` image; `run.sh` reads everything from
  `recipe.yaml` (upstream kit layout under `/home/admin/hibrid48-recipe/`).
  ⚠️ It needs its **own** watchdog: `make memwatch STACK=hibrid48`, and the stock
  thresholds are **too high for this stack** (it idles at ~2.4% available by
  design) — run it with `WATCH_WARN_PCT=3 WATCH_CRIT_PCT=1`, or it fires at boot
  exactly the way `glm53` does at the default crit=5%.
  ⚠️ `vm.compaction_proactiveness=0` must stay set on S2 (persisted in
  `/etc/sysctl.d/99-myllmbox-compaction.conf` by the recipe's `tune-host.sh`);
  upstream measured ~10% throughput loss without it. `stacks/hibrid48/preflight.sh`
  warns (does not block) if it has drifted back to the kernel default 20.
  ⚠️ Thinking kwarg differs from fndgx: top-level `enable_thinking` is silently
  ignored here — only `chat_template_kwargs.enable_thinking` works (measured
  2026-09-28, see `make test STACK=hibrid48`).
  No runbook yet — its `recipe.yaml` (upstream copy) + the A/B account in
  `benchmarks/ab-radixark-vs-hibrid48-2026-09-28/README.md` carry the reasoning.

⚠️ **Never restart a single rank of a TP=2 stack** — it leaves the survivor hung
in collectives while `/health` and `/v1/models` still return 200. This is a
property of TP=2, not of any one engine, and `make restart` is the only safe
path. Gotcha #1 in `docs/gotchas-cn.md`. **It applies to the primary again**
(`hibrid48tp2`, since 2026-09-30) as well as to `glm53`.

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

## Architecture (plain docker on both nodes since 2026-09-20)

**There is no orchestrator.** Every stack is `docker run` on one or both hosts,
driven from this machine over SSH. k3s and Cilium were uninstalled on 2026-09-20.

Current shape (since 2026-09-30) — one TP=2 stack across both boxes:

```
   ┌──────────────────┐   200G CX7   ┌──────────────────┐
   │ S1 spark-ccf3     │ ◄──────────► │ S2 spark-2435     │
   │ 192.168.200.101   │  RoCE/NCCL   │ 192.168.200.102   │
   │ docker            │  rocep1s0f0  │ docker            │
   │ hibrid48tp2 rank0 │              │ hibrid48tp2 rank1 │
   │ API :8000         │              │ (--headless)      │
   └───────────────────┘              └───────────────────┘
              │ Tailscale VPN (100.x)         │
              └───────────┬───────────────────┘
                 ┌────────▼──────────┐
                 │   Mac (client)    │  ssh admin@100.x
                 │ codex --profile dgx → 100.97.87.120:8000
                 └───────────────────┘
```

Two TP=2 stacks exist — `hibrid48tp2` (head **S1**) and `glm53` (head S1): one
container per node, the head exposing the OpenAI API and the other rank headless
with no endpoint of its own, NCCL/RoCE over the 200G link. Each needs **both**
boxes. The single-node shape (`qwen38un` on S1 + `hibrid48` on S2, side by side)
is what ran 2026-09-20 → 09-30 and is the rollback.

## Unified memory constraints (GB10) — read before changing any launch flag

- 128 GB LPDDR5X coherent memory shared between CPU and GPU, per node.
- **Don't over-allocate `gpu-memory-utilization`** — too high risks OOM freezes
  of sshd itself. Live values: `qwen38un` **0.80** (`mem-fraction-static`; 0.85
  was tried and rejected — see the table in `## Previous state (2026-09-19)`),
  `hibrid48` **0.70** (`gpu-memory-utilization`; its KV pool is pinned
  separately with `--kv-cache-memory 27G`, so this fraction does not size the
  pool), `hibrid48tp2` **0.70** with `kv-cache-memory 41G` **per box** (same
  mechanism; the half-table-per-box split is what pays for it), `qwen38` **0.75**. (Retired `fndgx` ran `GPU_MEM` **0.80** with the
  never-raise-it warning — upstream reports 0.85 drifting into swap, 0.875
  OOM-killed.)
  Retired but still instructive: V4-Flash ran **0.80** because 0.85 caused a full
  head-node OOM on 2026-06-29, and Flash-Next went 0.80 → 0.75 on 2026-09-02
  because `scripts/mem-floor.sh` measured 8-way × 8K prompt leaving only 5 GiB
  host available (4.1%, below the memwatch CRIT line) at 0.80 — and the KV it
  bought could not be used anyway under `max_num_seqs=8`.
  **Re-run mem-floor before raising any of these, and keep both nodes symmetric.**
- Swap **must** be disabled (`swapoff -a`).
- `nvidia-smi` reports `[N/A]` for per-process memory on GB10; watch `free -h`.
- **Never build on S1 without stopping the running stack first** — even the
  "lightweight" prebuilt-wheel path compiles native deps from source and OOM'd
  the head node on 2026-07-04, taking the whole tmux server down with it.
- **Host memory watchdog** scales BOTH ranks to
  0 before a node OOMs — vLLM's ~100 GB pre-allocation bypasses the container
  cgroup on GB10, so node-level available memory is the only signal that sees it.
  No auto-restore; bring it back with `make run`. It refuses to start (exit 3) if
  it cannot actually stop that stack. A k8s cgroup
  memory limit was tried and **rejected** — `docs/auto-mitigation-cn.md`.
  ✅ **Preferred form since 2026-10-27: node-resident** — `make memwatch-install
  [STACK=]` installs systemd `dgx-memwatch@<stack>` on the stack's head: it reads
  its own `/proc/meminfo`, runs the stop action locally and reaches the peer over
  the 200G link (`STACK_NODE_IC_MAP` in `stacks/_lib/common.sh`) — **no
  Tailscale, no Mac**. `make memwatch-status` shows it, says whether the deployed
  copy has fallen behind the repo, and reads available% from the node's side.
  Why: the old form (`make memwatch` in a tmux on the Mac) sees the boxes through
  Tailscale DERP; on 2026-10-27 Mac → S2 was down 40+ min while S2 and the 200G
  link were fine, and it logged S2 as `unreachable (skip)` the whole time.
  ⚠️ The node runs a **copy** — after editing `scripts/mem-watch.sh` or a
  `stack.env`, re-run `make memwatch-install`. `make switch` does **not** move it:
  `memwatch-uninstall STACK=<old>` + `memwatch-install STACK=<new>` are on its
  printed checklist (not automatic, so glm53 — 1.8% headroom — can't be killed by a
  switch; install itself refuses when a node is already ≤ crit, `FORCE=1` overrides).
  Thresholds are registry fields now (`STACK_MEMWATCH_{WARN_PCT,CRIT_PCT,CRIT_CONSEC}`;
  `WATCH_*` env still wins) — before, they lived only in comments and tmux command lines.
  ⚠️ **One instance guards one stack** (all of its nodes). Two single-node stacks
  live = two instances (`dgx-memwatch@qwen38un` on S1, `dgx-memwatch@hibrid48` on
  S2). State/log files are per-stack, so they don't collide.
  ⚠️ `hibrid48` idles at ~2.4% host available **by design** (bilikaz's recipe
  leaves ~2G), so at the stock crit=5% its watchdog fires on startup — exactly
  the glm53 situation.
  ⚠️ `STACK_MEMWATCH_STOP`'s first word must be either a path under `STACK_DIR`
  (`./stop.sh`) or a bare command name — the startup self-check validates each
  form differently. Until 2026-09-20 it only understood the path form, so
  `qwen38`'s bare `docker rm -f …` made its watchdog `exit 3` — **that stack never
  had a working guard**, while `make memwatch-test` reported PASS because it only
  checked the field was non-empty. Both are fixed; the test now checks the shape.

## GB10 host tuning (clock cap adopted 2026-08-25)

Full A/B data + the do-not-touch list: `docs/gb10-tuning-cn.md`.

- ✅ **THE CAP IS BACK ON BOTH NODES (2026-11-15)** — `make clock-cap-install`, verified
  under a real `dsv41` generation: rank0 mean 2175 / rank1 2186 MHz. Why: **S2 lost power
  twice in 13 h under `dsv41` load** (03:52 and 16:50; journal cut off mid-line, no panic,
  S1's 200G carrier dropped; MemAvailable 10+ GiB, 96 °C on both boxes, S1 fine on the same
  load). S2 had run 74 days uncapped on the Qwen stacks before that. Suspected S2 power
  delivery under sustained load — a hypothesis; the cap buys ~30 W of GPU rail back.
- 🗄️ *History:* **the cap was off on both nodes 2026-09-20 → 11-15 (on request).** Units uninstalled,
  clocks reset, **verified under load**: S1 mean 2471 / max 2476 MHz, S2 mean 2490
  / max 2528 MHz — against ~2183/2184 while capped, so about **+14%**. The two
  nodes **match**, so TP=2 lockstep is satisfied. Idle readings now sit ~2470–2509.
  ⚠️ Whoever re-caps must do **both** nodes: `make clock-cap-install`.
  A one-node cap silently drags a TP=2 pair to the slower rank — nothing warns you.
  ⚠️ Power goes back up: the 2026-08-25 A/B measured dual-node GPU rail
  86.2 W → 55.2 W *from* the cap, so removing it gives that back (wall-socket
  effect is much smaller — `nvidia-smi` sees only 12–27% of real draw).
- **The cap itself** (2200 MHz via `gb10-clock-cap.service`, adopted 2026-08-25;
  the unlock → `systemctl restart` → re-locked path is verified). Decode paired
  diff +0.9%, 95% CI [-1.9%, +3.7%] (n=11 interleaved, `min_tokens` fixed) →
  indistinguishable from zero; prefill -3.7%; dual-node GPU-rail power 86.2 W →
  55.2 W (wall-socket saving is much smaller: `nvidia-smi` sees only 12-27% of
  real draw). Drive it with
  `make clock-cap-{apply,verify,status,install,reset,uninstall}`; scope it to one
  box with `CAP_HOSTS=<ip>`, since every verb walks **both** nodes by default.
- ⚠️ **`reset` is not "remove the cap".** It runs `-rgc` only; the systemd unit
  stays `enabled` and re-applies the cap on the next reboot. `uninstall` is the
  one that disables the unit, deletes it and unlocks. `install` puts it back.
- ⚠️ **`-lgc` dies on reboot** (hence `clock-cap-install`), and **no nvidia-smi
  field reports an active lock** (`Applications Clocks Setting` stays
  `Not Active`, `clocks.max.sm` stays 3003) — the only check is
  `clocks.current.sm` *under load* = `make clock-cap-verify`. Idle readings lie in
  both directions: S2 idled at 2190 while capped and 2398 the moment it was not.
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
  both nodes. ⚠️ *Reason corrected 2026-11-15:* the two separate x4 Gen5 links (PCIe
  domains 0000 and 0002) are the two **twins of one port** (`enp1s0f0np0` /
  `enP2p1s0f0np0`); port 2 (`…f1np1`) is a second function on the **same** two links, so a
  second cable can add no bandwidth. The lever is addressing the twin (dual rail, done
  2026-11-15 — see `## Current state`). As of 11-15 both f1 ports read carrier 0. `docs/gb10-tuning-cn.md` §6 — that section was corrected
  three times, and the standing lesson is: someone else's GB10 perf result is a
  hypothesis until it reproduces on these boxes.

## Retired 2026-09-20: the k3s runtime and the V4-Flash engine

Both are **gone from the tree and from the hosts**, not merely stopped. Read this
section before proposing either of them again.

- **k3s + Cilium are uninstalled on both nodes.** `docker` is the only runtime;
  `adapter-k3s.sh`, `k8s/`, and the per-stack manifests were deleted with the two
  stacks that used them. The removal procedure — and specifically why Cilium's
  BPF on `tailscale0` is the part that can strand a box with no BMC — is in
  `## Current state`. Design/execution history: `docs/k3s-migration-design-cn.md`
  (kept as a record; ⚠️ its §6 was already superseded before any of this).
- **Bringing k8s back is a project, not a flag.** The old cluster was k3s v1.36.3
  + Cilium 1.19.6 kube-proxy-less with the NVIDIA device plugin ≥ v0.17.4 (older
  ones crash on GB10's unified memory), images side-loaded with
  `k3s ctr images import` because nothing could pull them. None of that survives.
- ⚠️ **ClusterMesh with homelab was evaluated and REJECTED 2026-08-13**, and that
  verdict outlives the cluster: the Sparks are *shared* nodes from another
  tailnet, so subnet routes and a cross-cluster node plane cannot exist. Don't
  re-open it on the assumption that a fresh cluster would behave differently.
- **V4-Flash's hard-won engine facts, so they are not rediscovered the hard way:**
  its official FP8 weights are ~167 GB / 48 shards and **do not fit one GB10**, so
  it was always TP=2; it needed the jasl/vllm fork only for DSpark (stock vLLM can
  serve it given `DG_JIT_USE_NVRTC=0` + `DG_JIT_NVCC_COMPILER=…`, whose absence
  looks like an architecture-support failure but isn't); and **SGLang is a dead
  end for it** — its V4 attention wants a FlashMLA kernel with no `sm_121` build.
  Full detail is in git history (`stacks/v4flash/`), and the measurements stay in
  `benchmarks/`.
- **Still live and still useful:** `scripts/vllm-fix-torch.sh` fixes the
  from-source build trap that leaves a runner image on torch-CPU
  (`vllm._C: libtorch_cuda.so missing`). That is a vLLM-build problem, not a
  V4-Flash one — keep it.

## Known gotchas — index

Full detail with reproductions and dates: **`docs/gotchas-cn.md`**.

| # | Symptom | Where it bites |
|---|---|---|
| 1 | Single-rank restart → zombie TP group; `/health` still 200, all generations time out | `glm53` (the last TP=2 stack) ⚠️ most expensive |
| 2 | Two stacks both want the GPU → OOMs the whole node. Overlap is judged by **node set**, and a TP=2 stack's rank1 counts | switching stacks ⚠️ |
| 3 | `NCCL WARN ... GID table changed` every ~45 s | reading logs (harmless) |
| 4 | Domestic mirror "is slow" — actually `docker build`/`run` forced through the xray proxy (90×) | building images |
| 5 | ModelScope/github unreachable while Tailscale is fine → DHCP hands out no DNS | networking |
| 6 | `HFValidationError` in-container → absolute HF-cache symlinks | downloading models |
| 7 | `Syntax error in template` → Ansible eats `--format 'table {{.Names}}'` | any ansible + docker `--format` |
| 8 | Foreign registries blocked/slow → daocloud + ModelScope + Tsinghua | all downloads |
| 9 | Stack identity hardcoded (CoT field / kwarg / model name) fails **silently** | any cross-stack tool ⚠️ |
| 10 | **SGLang and TensorFold accept any model name** (200; SGLang echoes it back, TensorFold rewrites it to its own) — "a wrong name 404s" is a vLLM-only assumption | identity gates, gateway routes after a switch ⚠️ |

## Measuring throughput

**Read `docs/benchmarking-cn.md` before quoting any tok/s number.** Short version:
acceptance is content-driven, so one prompt's number describes the prompt as much
as the cluster (31→84 tok/s on the same config). Three traps have each produced
wrong numbers in this repo's own docs: streaming counts *steps/s* not tok/s;
cold **and idle** decay ≈30% silently; short replies are overhead-capped.

⏳ **The primary `dsv41` has no benchmark of its own yet.** Upstream's harness is
`tools/bench.py` in the recipe (prefill, decode, multi-stream, needle → JSON,
`--compare A.json B.json`); its published numbers were taken at a 2,200 MHz cap and
`CONTEXT=524288`; ours ran uncapped (~2,470 MHz) until 2026-11-15 and are capped at
2,200 again since (S2 power deaths). Don't quote theirs as ours.

Last measured baseline (now a rollback): **`benchmarks/hibrid48tp2v52-2026-10-22/`** — `run-ab.sh` runs
the same `ladder.py` (thinking off and on) + `prefill.py` on the head against
localhost; kit v4.1 vs v5.2 on the same weights, same night.
Before that: **`benchmarks/hibrid48tp2-2026-09-30/`** — `ladder.py`, the 09-28
ladder with an identical request body, run against hibrid48tp2 **and** qwen38un
(before it stopped), so the three Flash-Next/27B numbers share one harness.
GLM's own scripts: `benchmarks/glm53-2026-09-19/`. Previous: `benchmarks/bench-full-qwen38fn-2026-09-03/`
(Flash-Next vs V4). Harness + V4 baseline: `benchmarks/bench-full-2026-08-05/`.

⚠️ **`bench_full.py` does not work on GLM at all** — it hardcodes the deleted
V4-Flash's model name *and* a `thinking` kwarg, while GLM is a **third** semantics:
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

Every stack is **unauthenticated** and serves `/v1/chat/completions` **and**
`/v1/responses` — but they are **not all vLLM** (the primary is vLLM 0.30 again
since 2026-09-30; the rollback qwen38un is SGLang; four engines are in play, see
the top of this file). Full setup, per-stack
reasoning-effort semantics, the `contextWindowSize` hard-limit-0 trap and how to
rebuild on a new machine: **`docs/clients-cn.md`**.

```bash
codex --profile dgx        # → 100.97.87.120:8000 DeepSeek-V4.1-Flash-1017 (primary dsv41 since 2026-11-14; B only; namespace/web_search/tool_search tools turned off — see Current state)
codex --profile mac        # → llm.meirong.dev gateway, pinned to the Mac fallback (mac/ornith)
codex --profile local      # → 127.0.0.1:8000 Mac-local omlx
codex --profile m2         # → 100.89.15.120:8000 the M2 box's omlx (⚠️ on B its model is gpt-5.5 — see docs/clients-cn.md)
qwen                       # boot default → dsv41 (DeepSeek-V4.1-Flash-1017, direct :8000) since 2026-11-14; ./scripts/qwen-model-switch.sh fntp2 to roll back
# codex-dgx (alias in B's ~/.zshrc) = `codex --profile dgx` since 2026-09-30 (was: --profile litellm)
```

🧹 **2026-09-30 client cleanup on B (`mbpm5.local`) — measured, not intended.**
Removed: the `fndgx` / `qwen38` / `litellm` profiles and their catalogs (their
targets — hibrid48, qwen38, the gateway's qwen38un route — are all stopped), every
`*.bak*` of codex/qwen model config (20 files incl. two `models_cache.json.bak`),
and the qwen `/model` entries `qwen3.8-27b-sglang` / `qwen3.8-flash-next` /
`qwen38-27b`. Stale comments rewritten in `~/.codex/config.toml`, the repo's
`.qwen/.env` and `~/.zshrc`. **Everything removed or edited is in
`~/dgx-client-config-backup-20260930.tar.gz`** (35 paths, relative to `$HOME`;
restore with `tar -C ~ -xzf ~/dgx-client-config-backup-20260930.tar.gz <path>`).
`ls ~/.codex` afterwards: `config.toml`, `dgx.config.toml` + `dgx-models.json`,
`local.config.toml`, `m2.config.toml`, `mac.config.toml`, `models_cache.json`
(plus the untouched `config-backup-20260617-113755.tar.gz` and `hooks.json.bak`).
Machine A was not touched — it still has `fndgx`.
⚠️ **A removed profile does not error** (codex 0.157.1, measured): `codex exec
--profile fndgx` silently fell back to the base config — `openai` / `gpt-6-luna` —
and answered. Typing an old local-profile name sends the request to the cloud
model with no warning; a "tombstone" profile pointing at an unreachable
`base_url` would make it fail loudly instead (not done — see `docs/clients-cn.md`).

⚠️ **There are at least two `~/.codex` trees, on two client Macs, and they differ**
(found while merging on 2026-09-26). A = `Matthews-MacBook-Pro`, B = the machine
ce00239 was measured on — **`mbpm5.local`** (identified 2026-09-30 by its
per-profile `*-models.json` layout; that day's client switch was done on B only).
This section and
`docs/clients-cn.md` flip-flopped for a week because each machine "corrected" the
doc to match **its own** disk — both `stat`s were right, "本机" was the bug:
- **A** has four overlays (`dgx` / `fndgx` / `local` / `m2`) and **one shared**
  `~/.codex/models.json`. `find ~ -maxdepth 4` finds none of B's
  `qwen38` / `litellm` / `mac` overlays or any `*-models.json` (re-run 2026-09-26).
- **B** has seven overlays — `--profile qwen38` / `litellm` / `mac` exist there,
  born 2026-08-15 / 09-09 / 08-16 — and **per-profile** catalogs: `dgx` / `fndgx` /
  `qwen38` / `litellm` each set `model_catalog_json` to their own
  `<name>-models.json`, and B has no `models.json`.
`codex --help` (0.155.1) states the mechanism both share: `-p/--profile <name>`
layers `$CODEX_HOME/<name>.config.toml` on the base config — **a file is a
profile**, there is no `[profiles.*]` table anywhere.

⚠️ **On A, codex 0.155.1 never loaded `~/.codex/models.json` at all (found
2026-09-21).** It ships a bundled catalog and reads a custom one only when a
profile sets `model_catalog_json = "<path>"`, which none on A did (B's already
did). The live symptom was
`Model metadata for qwen3.8-27b-sglang not found. Defaulting to fallback
metadata` plus `Reasoning shortcuts are unavailable for <model>` — i.e. **the
`/model` effort picker and ctrl-up/ctrl-down did nothing**, and the catalog's
`context_window = 262144` never reached the compaction threshold either.
A's `dgx` and `fndgx` now set it (schema also had to change: `supported_reasoning_levels`
must be `[{effort, description}]`, not bare strings, or the **whole** catalog
fails to load). ⚠️ It **replaces** the bundled catalog rather than merging, so it
belongs in a profile, never in `config.toml`. On A the file is shared, so a profile
that loads it sees all three slugs in `/model`, where picking another one silently
retargets the current provider's `base_url` (`:8888` is SGLang: any model name
returns 200 — gotcha #10). ❌ `model_max_output_tokens` is an unknown field in
0.155.1 (silently ignored; `--strict-config` names it) and was deleted from A's
`dgx` / `fndgx`. Full account + measured ladders: `docs/clients-cn.md`.
⚠️ True on both machines: **`dgx` and `qwen38` point at the same S1 `:8888`**,
where only one stack can be live — so picking the wrong one is silent.
⚠️ Generalized: `~/.codex` is not in git, so a sentence here is the only record —
a "verified" with no pasted `ls`/`stat` output behind it is worth nothing, and
**one with no hostname behind it is only true of one machine.**

⚠️ Thinking kwargs **and** the CoT response field differ per stack
(`thinking`/`enable_thinking`, `reasoning_content`/`reasoning`) — both fail
*silently*, see gotcha #9. And
codex/qwen's built-in `reasoning:false` does **not** reach a self-hosted vLLM.

## Key file map

**Entry points**
- `README.md` — human entry point and doc map.
- `Makefile` — the single user-facing interface for every stack.

**The stack registry — `stacks/`**
- `stacks/README.md` — **the contract: what adding a model requires.** Short
  version: create `stacks/<id>/`, fill one `stack.env`, change nothing else.
- `stacks/PRIMARY` — one line: the current primary stack's id. **The only place
  that fact lives.** Every tool derives from it; `make switch TO=<id>` edits it.
- `stacks/_lib/` — `stackctl.sh` (all make verbs), `common.sh` (registry reads +
  required-field validation), `preflight.sh` (whole-registry mutual exclusion +
  asset checks), `adapter-docker.sh` (one file per runtime — **docker is the only
  one left**; `adapter-k3s.sh` was deleted 2026-09-20 with the cluster).
- `stacks/<id>/stack.env` — the machine-readable identity: served name, port,
  host, runtime, **thinking kwarg / CoT field**, watchdog stop action, assets.
- `stacks/<id>/recipe.yaml` — *why* those parameters, with the measurements.
- `stacks/<id>/{launch,test,preflight}.sh`, `Makefile.mk`, `runbook-cn.md`
  — all optional hooks, picked up automatically when present.

**Shared scripts** — these are cross-stack tools. ✅ **None of them hardcodes a
stack identity any more**; they all read the registry (that used to be the single
largest source of silent breakage — gotcha #9).
- `scripts/stack-table.py` — renders the registry into the doc tables and
  validates the registry itself (`make stack-table` / `make stack-check`).
- `scripts/stack-switch.sh` — `make switch TO=<id>`: stop → PRIMARY → start →
  regenerate tables → flip clients → print what only a human can do.
- `scripts/mem-watch.sh` — host memory watchdog (`make memwatch*`). Reads
  `stacks/PRIMARY`; refuses to start (exit 3) if it cannot actually stop that stack.
  `scripts/mem-watch.sh --config [id]` prints what it would guard.
- `scripts/memwatch-node.sh` — `make memwatch-{install,status,reset,uninstall}`:
  deploys that same script as systemd `dgx-memwatch@<id>` on the stack's head
  (node-resident, no Tailscale in the loop) and reads back its startup banner.
- `scripts/gb10-clock-cap.sh` — GPU clock cap apply/verify/install. `verify`
  drives a real generation, so it takes model/port/thinking-kwarg from the
  registry; `CAP_STACK=<id>` aims it elsewhere.
- `scripts/qwen-model-switch.sh` — flips the Qwen Code **boot default**; targets
  are the registry (`--help` lists them live).
- `scripts/mem-floor.sh` — host-memory floor stress test; the evidence behind
  `gpu_memory_utilization 0.75`. **Re-run it before raising gmu or max_num_seqs.**
- `scripts/test-mem-watch.sh` / `scripts/test-preflight.sh` — the two regressions,
  and both are **registry-wide**, so a newly added stack is covered without anyone
  editing them: `test-mem-watch.sh` asserts the watchdog can really stop **every**
  registered stack (a new stack that forgets its stop action fails there, not
  during an OOM), and `test-preflight.sh` (`make preflight-test`) asserts every
  stack excludes every other one.
  ⚠️ Three stack-specific regressions were deleted 2026-09-20 with the stacks they
  tested (`test-liveness-probe.py`, `repro-issue55.py`, `test-ple-patch.sh` — all
  three read files under `stacks/v4flash/` or `stacks/qwen38fn/`).
- `scripts/vllm-fix-torch.sh` — fixes the torch-CPU build trap (a vLLM-build
  problem, not tied to any one stack).
- `scripts/v2rayn-launch.sh` — revives the S1 v2rayN proxy (needed for github
  clones during an image build).
- `scripts/modelscope-download.sh` — model download via `make modelscope-download`.

**Docs** (see `README.md` for the full map)
- `docs/gotchas-cn.md`, `docs/benchmarking-cn.md`, `docs/clients-cn.md` —
  the three split out of this file.
- **`docs/stack-switch-cn.md` — what `make switch` cannot do for you.** Most of
  the old 4-layer checklist is now mechanized; this doc is the residue plus the
  three incidents that explain why any of it exists.
- `docs/s2-outage-2026-08-15-cn.md` — S2's hardware death, why WoL failed
  (**no BMC/IPMI on these boxes**), and the TP=2 recovery procedure.
- Per-stack runbooks live with their stack: `stacks/qwen38/runbook-cn.md`,
  `stacks/fndgx/runbook-cn.md` (fndgx retired 2026-09-28). `hibrid48` has no
  runbook — its `recipe.yaml` (upstream copy) + the A/B account in
  `benchmarks/ab-radixark-vs-hibrid48-2026-09-28/README.md` carry the reasoning.
- ⚠️ **glm53 and qwen38un have no runbook** — their reasoning lives in
  `stacks/<id>/recipe.yaml` comments. Known gap, and it got sharper on 2026-09-20:
  `glm53` is now the only rollback, and it is the one with no runbook.
- `docs/k3s-migration-design-cn.md` — ⚠️ **history only.** The cluster it designs
  was uninstalled 2026-09-20 (§6 was already superseded before that).
- `docs/host-maintenance-cn.md` — apt / driver / kernel / DKMS runbook.
- `docs/gb10-tuning-cn.md` — GB10 host tuning: GPU clock cap (adopted 2026-08-25), non-existent knobs, do-not-touch list.
- `docs/auto-mitigation-cn.md` — memory watchdog + alerting spec.
- `docs/china-network-mirrors-cn.md` — mirror runbook.
- `benchmarks/bench-full-qwen38fn-2026-09-03/` — Flash-Next + the V4 comparison.
  `benchmarks/bench-full-2026-08-05/` — the harness itself and the V4 baseline.
  ⚠️ **Both stacks were deleted 2026-09-20**, so these are records, not baselines
  anyone can reproduce. The reproducible ones are `benchmarks/glm53-2026-09-19/`,
  `benchmarks/qwen38un-2026-09-19/`, `benchmarks/fndgx-2026-09-20/` and
  `benchmarks/ab-radixark-vs-hibrid48-2026-09-28/` (RadixArk fndgx vs bilikaz
  hibrid48 A/B — drove the 2026-09-28 S2 switch) and
  `benchmarks/hibrid48tp2-2026-09-30/` (the same-harness three-stack ladder behind
  the 2026-09-30 switch to TP=2).
- `benchmarks/mtp-k-sweep-2026-09-03/` — MTP `k` sweep: why `tok/step` (counted) is
  the load-bearing number when a knob needs an engine restart, and the QSA assert
  that caps `k` at 4. Its harness (`mtp_arm.py`) is the reusable pattern for any
  **restart-required** knob, where interleaved pairing is physically impossible.

**Monitoring**
- `playbooks/node-exporter-deploy.yml`, `playbooks/smartctl-exporter-deploy.yml`.

## Conventions

- Docs in `docs/` are Chinese (`-cn.md`) with all commands, error strings and
  identifiers verbatim in English. This file stays English. **`docs/` holds only
  what is shared across stacks** — anything true of exactly one model belongs in
  `stacks/<id>/`, so adding a model adds files instead of editing them.
- Images on both servers: primary **`tensorfold-dsv41:exl3-tp2-8a98ae503d85`** on both
  nodes (built locally on S1, base `nvcr.io/nvidia/pytorch:26.07-py3` via
  `nvcr.nju.edu.cn` — that mirror is the working NGC route); rollback `hibrid48tp2v52`
  on `myllmbox/qwen38-flash-next-cluster-vllm:v5.2` (image ID `4210dc4b…`), rollback `hibrid48tp2` on `:v6` (image ID
  `4d03fc80…`) — neither is pullable through the domestic mirrors; see the
  `hibrid48tp2v52` note under `## Common Commands` for the partial-archive route; qwen38un
  `lmsysorg/sglang:nightly-cu134-…`; glm53
  `ghcr.nju.edu.cn/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3-instanttensor`;
  `qwen38` upstream `vllm/vllm-openai:nightly-aarch64`; **hibrid48
  `myllmbox/qwen38-flash-next-vllm:v4` on S2 only** (vLLM 0.30.0 base + bilikaz
  patches, public pinned tag) — the retired fndgx image `qwen38-flash-dgx`
  (built from the `vllm/vllm-openai:qwen38-flash-next` digest plus blazux's 13
  patch layers) is still on S2 for rollback.
  Driver 580.173.02 / CUDA 13.0, verified on both nodes 2026-09-02.
  ⚠️ The two deleted stacks' images (`vllm-qwen38fn:latest`,
  `vllm-node-dsv4:latest` + 2 older tags, ~100 GB across both nodes) are **still
  in docker** — nothing references them any more. They are the obvious thing to
  `docker rmi` if disk gets tight; until then they are the only copy left of
  either engine, so deleting them is a one-way door.
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
- **Adding a model must not modify existing files.** New stack = new
  `stacks/<id>/` directory. If you find yourself editing the Makefile, a shared
  script or a doc table to make a new model work, that is a bug in the registry —
  fix the registry instead. `stacks/README.md` is the contract.
  ⚠️ **Removing one is not symmetric, and 2026-09-20 is the worked example.**
  Deleting `stacks/<id>/` is necessary but not sufficient: the last stack of a
  runtime also takes its adapter, the shared scripts' branches for that runtime,
  and any regression that reads files under the deleted directory. Grep for the
  id and the runtime name across `scripts/`, `stacks/_lib/` and the Makefile, then
  run `make stack-check preflight-test memwatch-test` — the two registry-wide
  regressions are what actually prove nothing dangling is left.
- **Any change that moves which stack is primary runs `make switch TO=<id>`**,
  which rewrites `stacks/PRIMARY` and regenerates the doc tables. `make stack-check`
  fails the build if they drift, so this is no longer a thing to remember.
  ⚠️ What is *still* manual: the `## Current state` prose above, and codex's own
  config files. 091b6e4 switched the primary stack and touched no docs at all;
  CLAUDE.md then told every agent session the wrong primary for 24 h, which is how
  the clock-cap check came to be silently broken. The table can no longer go
  stale that way — the prose still can.
