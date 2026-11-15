# hibrid48 — Qwen3.8-Flash-Next single-node (bilikaz hibrid48, S2): operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **Flash-Next single-node** (`hibrid48`, rollback since 2026-09-30, S2, bilikaz v4 recipe): 4-bit output
  head + fused K=5 MTP, 105 GiB checkpoint, 830K-token KV pool, `max-num-seqs=16`.
  Same-question A/B (2026-09-28): **1.3–1.6× faster per question at
  equal-or-better four-suite quality** → replaced `fndgx` (RadixArk, 48 GiB PLE
  table, 48.0 tok/s code, 113 tok/s @ c8), which is retired to
  `stacks/fndgx/stack.env.retired-2026-09-28` and still restorable. Data:
  `benchmarks/ab-radixark-vs-hibrid48-2026-09-28/`.

## Operating notes

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

## History

### Previous state (2026-09-28) — S2 switched to hibrid48; fndgx retired

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
