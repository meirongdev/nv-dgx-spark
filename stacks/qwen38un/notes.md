# qwen38un — Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2 (S1): operating notes and history

> Moved verbatim from the root `CLAUDE.md` on 2026-11-15, when that file became a
> short `AGENTS.md`. **Why** this stack's parameters are what they are lives in
> `recipe.yaml`; this file holds how to operate it and what happened while it ran.
> Dated statements were true on that date — check the live box before acting on one.
> Phrases like "Current state", "above" or "below" refer to the old `CLAUDE.md` layout.

## At a glance

- **Qwen3.8-27B-Uncensored + SGLang** (`qwen38un`, rollback since 2026-09-30, S1):
  NVFP4 + DFlash2 speculator, single node. Code **45.4** tok/s single-stream;
  **472.7 tok/s aggregate @ c12** on its own harness (**216.9 peak** on the
  09-28 ladder harness). Also multimodal — the only uncensored stack.

## History

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
