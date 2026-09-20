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
| **Qwen3.8-27B-Uncensored NVFP4 + SGLang + DFlash2**<br>`STACK=qwen38un` | 1 | `:8888` `qwen3.8-27b-sglang` | sglang / docker | **primary (2026-09-19 起)** |
| Qwen3.8-Flash-Next NVFP4 单机 (PLE mmap + hybrid)<br>`STACK=fndgx` | 1 | `:18300` `qwen3.8-flash-next` | vllm-ple-mmap / docker | S2 常驻 —— 与主力栈并跑 |
| GLM-5.3-Flash EXL3 4bpw<br>`STACK=glm53` | 2 | `:8888` `GLM-5.3-Flash-EXL3` | vllm-exl3 / docker | 唯一 rollback —— 850K ctx |
| Qwen3.8-27B-NVFP4 (censored, no speculator)<br>`STACK=qwen38` | 1 | `:8888` `qwen38-27b` | vllm / docker | retired-ish —— 24.9 tok/s |
<!-- END generated:stacks -->

> The table above is generated from `stacks/*/stack.env` by `make stack-table`
> and verified by `make stack-check`. **Do not hand-edit it** — edit the registry.

⚠️ **Mutual exclusion is now per-node, not registry-wide** (changed 2026-09-20).
Two stacks conflict when their **GPU node sets intersect** — `STACK_GPU_NODES` in
each `stack.env`, enforced by `stacks/_lib/preflight.sh`. So `qwen38un` (S1) and
`fndgx` (S2) run **at the same time**, which is what makes the idle box usable at
all; `glm53` still collides with both, because a TP=2 stack's **rank1 also eats
S2's GPU** and its **rank0 eats S1's**. Several stacks claim `:8888`.
`make run STACK=<id>` refuses to start against an overlapping stack, and its
preflight still walks **the whole registry**, so a newly added stack is checked by
every existing one without anyone editing a list. It prints which stacks it checked
**and which it skipped**, so "not checked" can't read as "checked and fine".
⚠️ Judging overlap by `STACK_HEAD` alone would call `glm53` (head=S1) unrelated
to an S2 stack and let both onto S2's GPU — that is gotcha #2 on a box with no BMC.
⚠️ **`glm53` is now the registry's only multi-node stack** (the two k3s TP=2 stacks
were deleted 2026-09-20), so it is the only thing keeping that code path exercised.
`scripts/test-preflight.sh` says so at the assertion that depends on it — delete
`glm53` and you must add a synthetic two-node fixture there, or the most expensive
case in gotcha #2 stops being tested.

⚠️ **Two stacks are running right now** — `qwen38un` on S1 (primary) and `fndgx`
on S2. The primary being single-node removes the whole TP=2 failure class
(gotcha #1's zombie collectives, cross-node NCCL/RoCE, the lockstep restart rule),
but it also means **`make memwatch` alone only guards the primary** — `fndgx`
needs its own `make memwatch STACK=fndgx` instance, in its own tmux session.

⚠️ **Four different engines are in play** (vLLM / vLLM+EXL3 overlay / SGLang /
vLLM+PLE-mmap) and **six different thinking-kwarg semantics**. There is no shared
default. They live in each stack's `STACK_THINK_KWARG` / `STACK_THINK_OFF` /
`STACK_COT_FIELD`, and `docs/clients-cn.md` carries the generated cross-stack
table. Getting this wrong is silent — gotcha #9. ⚠️ **The same model can have two
different CoT fields on two different engine builds**: the now-deleted `qwen38fn`
recorded `reasoning_content`, while `fndgx` — same checkpoint family, newer preview
image — measurably returns `reasoning` and `reasoning_content` is always `None`.
The lesson outlives the stack: **never infer the CoT field from the model name.**

✅ **Switching the primary stack is `make switch TO=<id>`.** "Which stack is
current" used to be hardcoded in ~8 places that each failed *silently*; it is now
one file (`stacks/PRIMARY`) that every tool reads. What is still manual — codex's
own config files, and the prose in `## Current state` below — is printed by that
command and listed in `docs/stack-switch-cn.md`.

- **Qwen3.8-27B-Uncensored + SGLang** (`qwen38un`, primary, S1): NVFP4 + DFlash2
  speculator, single node. Code **45.4** tok/s single-stream; concurrency **472.7
  tok/s aggregate @ c12**, the best this repo has measured. Also multimodal.
- **Flash-Next single-node** (`fndgx`, S2): same model family as the retired
  `qwen38fn`, but `mmap`s the 48 GiB PLE table off NVMe so it fits one box.
  48.0 tok/s code; aggregate flatlines at **113 tok/s @ c8** because `SEQS=8`.
- **GLM-5.3-Flash EXL3** (`glm53`, rollback, **TP=2 across both nodes**): 64.3 tok/s
  structured, 850K nominal ctx. ⚠️ Starting it requires stopping **both** live
  stacks, and its host headroom (1.8–2.0%) is too low for `make memwatch` to run.
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
- `100.97.87.120` — server 1 / `spark-ccf3` (primary `qwen38un`; glm53's rank0)
- `100.67.164.92` — server 2 / `spark-2435` (`fndgx`; glm53's rank1)
- SSH: `admin` + `~/.ssh/vgio`
- `192.168.200.101/102` — the internal 200G CX7 link. Carries the TP=2 NCCL
  traffic (bypassing the CNI) and inter-node file copies.

## Current state (2026-09-20) — k3s removed; two docker stacks: qwen38un on S1, fndgx on S2

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
Full data + scripts: `benchmarks/fndgx-2026-09-20/`.
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
`--mamba-ssm-dtype bfloat16`); ⏳ **none tried** — raising it restarts the primary
and needs a re-measure, and 0.80's throughput is itself unmeasured (above), so the
two would confound. The c16 fallback to 356 tok/s is this cap's direct
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
make status  STACK=fndgx        # containers + /v1/models + free -h
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
- **fndgx** — the only stack whose head is **S2**, and the only one wrapping a
  third-party orchestrator (`./flash`, from blazux/qwen3.8-Flash-DGX).
  ⚠️ It needs its **own** watchdog: `make memwatch STACK=fndgx`.
  ⚠️ Its container carries `--restart unless-stopped`, so **it comes back by itself
  after a host reboot** — no other docker stack here does.
  ⚠️ Its Dockerfile carries a 7-line local patch (GitHub → jsDelivr); re-apply it
  after any upstream pull, or the build cannot fetch its kernel sources.
  `stacks/fndgx/runbook-cn.md` has the from-zero procedure.

⚠️ **Never restart a single rank of a TP=2 stack** — it leaves the survivor hung
in collectives while `/health` and `/v1/models` still return 200. This is a
property of TP=2, not of any one engine, and `make restart` is the only safe
path. Gotcha #1 in `docs/gotchas-cn.md`. **`glm53` is the only stack this still
applies to** — but it applies in full, so do not let the rule fade with the two
TP=2 stacks that were deleted on 2026-09-20.

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

Normal shape — two independent single-node stacks, one per box:

```
   ┌──────────────────┐   200G CX7   ┌──────────────────┐
   │ S1 spark-ccf3     │ ◄──────────► │ S2 spark-2435     │
   │ 192.168.200.101   │  RoCE/NCCL   │ 192.168.200.102   │
   │ docker            │  (idle when  │ docker            │
   │ qwen38un  :8888   │   no TP=2)   │ fndgx    :18300   │
   └──────────────────┘              └──────────────────┘
              │ Tailscale VPN (100.x)         │
              └───────────┬───────────────────┘
                 ┌────────▼──────────┐
                 │   Mac (client)    │  ssh admin@100.x
                 │ codex --profile dgx → 100.97.87.120:8888
                 └───────────────────┘
```

The TP=2 shape still exists, but **only `glm53` uses it**: one container per node,
rank0 on S1 exposing the OpenAI API and rank1 on S2 headless with no endpoint of
its own, NCCL/RoCE over the 200G link. It needs **both** boxes, so it cannot run
while `qwen38un` or `fndgx` is up. Everything gotcha #1 says about never touching
a single rank applies to it and nothing else.

## Unified memory constraints (GB10) — read before changing any launch flag

- 128 GB LPDDR5X coherent memory shared between CPU and GPU, per node.
- **Don't over-allocate `gpu-memory-utilization`** — too high risks OOM freezes
  of sshd itself. Live values: `qwen38un` **0.80** (`mem-fraction-static`; 0.85
  was tried and rejected — see the table in `## Previous state (2026-09-19)`),
  `fndgx` **0.80** (`GPU_MEM`; **never raise it**, upstream reports 0.85 drifting
  into swap and 0.875 OOM-killed), `qwen38` **0.75**.
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
- **Host memory watchdog** (`make memwatch`, run it in tmux) scales BOTH ranks to
  0 before a node OOMs — vLLM's ~100 GB pre-allocation bypasses the container
  cgroup on GB10, so node-level available memory is the only signal that sees it.
  No auto-restore; bring it back with `make run`. ✅ The watchdog reads
  `stacks/PRIMARY` — there is nothing to change when the primary moves, and it
  refuses to start (exit 3) if it cannot actually stop that stack. A k8s cgroup
  memory limit was tried and **rejected** — `docs/auto-mitigation-cn.md`.
  ⚠️ **One instance guards one stack.** With two stacks live you need two:
  `make memwatch` (primary) **and** `make memwatch STACK=fndgx`, each in its own
  tmux session. State/log files are per-stack, so they don't collide.
  ⚠️ `STACK_MEMWATCH_STOP`'s first word must be either a path under `STACK_DIR`
  (`./stop.sh`) or a bare command name — the startup self-check validates each
  form differently. Until 2026-09-20 it only understood the path form, so
  `qwen38`'s bare `docker rm -f …` made its watchdog `exit 3` — **that stack never
  had a working guard**, while `make memwatch-test` reported PASS because it only
  checked the field was non-empty. Both are fixed; the test now checks the shape.

## GB10 host tuning (clock cap adopted 2026-08-25)

Full A/B data + the do-not-touch list: `docs/gb10-tuning-cn.md`.

- 🔶 **THE CAP IS OFF ON BOTH NODES (2026-09-20, on request).** Units uninstalled,
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
  both nodes. Consistent with `lspci` — the two ports sit on *separate* x4 Gen5 links
  in separate PCIe domains, so the "two cables split one x4" mechanism doesn't apply.
  **Leave both cables in.** `docs/gb10-tuning-cn.md` §6 — that section was corrected
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
| 10 | **SGLang accepts any model name** (200 + echoes it back) — "a wrong name 404s" is a vLLM-only assumption | identity gates ⚠️ |

## Measuring throughput

**Read `docs/benchmarking-cn.md` before quoting any tok/s number.** Short version:
acceptance is content-driven, so one prompt's number describes the prompt as much
as the cluster (31→84 tok/s on the same config). Three traps have each produced
wrong numbers in this repo's own docs: streaming counts *steps/s* not tok/s;
cold **and idle** decay ≈30% silently; short replies are overhead-capped.

Current baseline: **`benchmarks/glm53-2026-09-19/`** (GLM, with the upstream
comparison and its own three scripts). Previous: `benchmarks/bench-full-qwen38fn-2026-09-03/`
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

All stacks are **unauthenticated** vLLM and serve `/v1/chat/completions` **and**
`/v1/responses`. Full setup, per-stack reasoning-effort semantics, the
`contextWindowSize` hard-limit-0 trap and how to rebuild on a new machine:
**`docs/clients-cn.md`**.

```bash
codex --profile dgx        # → :8888 qwen3.8-27b-sglang  (primary, since 2026-09-19)
codex --profile qwen38     # → :8888 qwen38-27b          (stock 27B, no speculator)
qwen                       # boot default; ./scripts/qwen-model-switch.sh sglang to flip
```

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
  `stacks/fndgx/runbook-cn.md`.
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
  `benchmarks/qwen38un-2026-09-19/` and `benchmarks/fndgx-2026-09-20/`.
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
- Images on both servers: primary `lmsysorg/sglang:nightly-cu134-…`; glm53
  `ghcr.nju.edu.cn/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3-instanttensor`;
  `qwen38` upstream `vllm/vllm-openai:nightly-aarch64`; **fndgx
  `qwen38-flash-dgx` on S2 only** — built from the
  `vllm/vllm-openai:qwen38-flash-next` digest plus blazux's 13 patch layers.
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
