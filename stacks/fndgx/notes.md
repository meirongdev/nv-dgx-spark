# fndgx — Qwen3.8-Flash-Next single-node via PLE-mmap (retired 2026-09-28): operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## History

### Previous state (2026-09-20) — k3s removed; two docker stacks: qwen38un on S1, fndgx on S2

⚠️ *Superseded as of 2026-09-28 for S2: `fndgx` was replaced by `hibrid48` (see
the Current state section above). Everything below about S2/fndgx is history;
the fndgx stack files remain on S2 and can be restored if needed.*

#### fndgx on S2

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
