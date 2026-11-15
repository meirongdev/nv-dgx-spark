# glm53 — GLM-5.3-Flash EXL3 4bpw TP=2: operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **GLM-5.3-Flash EXL3** (`glm53`, rollback, **TP=2 across both nodes**): 64.3 tok/s
  structured, 850K nominal ctx. ⚠️ Starting it requires stopping the primary
  (`hibrid48tp2` holds both boxes), and its host headroom (1.8–2.0%) is too low for
  `make memwatch` to run.

## Operating notes

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

## History

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
