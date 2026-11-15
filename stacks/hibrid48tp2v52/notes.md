# hibrid48tp2v52 — Qwen3.8-Flash-Next TP=2, myllmbox kit v5.2: operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **Flash-Next TP=2, kit v5.2** (`hibrid48tp2v52`, rollback since 2026-11-14, was
  primary 2026-10-22 → 11-14, S1+S2): same hibrid48 checkpoint (hardlinks), vLLM 0.30 + RecoverSSM, dynamic
  K≤7 MTP in full CUDA graphs, one-shot RoCE all-reduce; 64 seats, 2.08M-token KV
  pool. Same-night A/B vs kit v4.1 (`benchmarks/hibrid48tp2v52-2026-10-22/`):
  **thinking-on c1 87–91 vs 77–79 (+14–15%)**, thinking-off c1 111.6 vs 106.9,
  **c64 753 vs 601**, cold prefill unchanged (~3,350 tok/s at 128K).

## Operating notes

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

## History

### Previous state (2026-10-22) — primary was `hibrid48tp2v52` (kit v5.2), same weights

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
