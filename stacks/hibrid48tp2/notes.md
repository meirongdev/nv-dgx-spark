# hibrid48tp2 — Qwen3.8-Flash-Next TP=2, myllmbox kit v4.1: operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **Flash-Next TP=2, kit v4.1** (`hibrid48tp2`, rollback since 2026-10-22, served
  name now `qwen3.8-flash-next-tp2-v41`): 2.45M-token KV pool.
  Same-harness ladder (`benchmarks/hibrid48tp2-2026-09-30/`): **~98.9 tok/s
  single-stream, 562 tok/s @ c64** — vs hibrid48 72.3 / 200.1 and qwen38un
  42.1 / 216.9 on the identical request set.

## Operating notes

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

## History

### Previous state (2026-09-30) — primary was `hibrid48tp2`, TP=2 across both boxes

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
