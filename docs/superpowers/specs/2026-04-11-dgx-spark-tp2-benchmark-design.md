# DGX Spark TP=2 benchmark design

## Problem

The repository currently supports only single-node vLLM deployment on DGX Spark. The user wants to add a real two-node TP=2 benchmarking path, generate a reproducible benchmark report, and revise the related blog post so it reflects an April 2026 test context without exposing personal or sensitive details.

## Goals

1. Add a dedicated two-node TP=2 deployment and validation flow without breaking the existing single-node workflow.
2. Run a real benchmark against one primary model chosen for cache availability and likelihood of success.
3. Generate a benchmark report that captures environment, deployment path, runtime metrics, issues, and conclusions.
4. Rewrite the blog post around the TP=2 benchmark narrative, removing sensitive details and tightening claims to match measured results.

## Non-goals

1. Generalize the repository into a full multi-model benchmark platform in this iteration.
2. Replace the existing single-node deployment flow.
3. Benchmark every cached model on the two DGX Spark nodes.

## Current state

### Repository

- `Makefile` is the primary operator interface.
- `playbooks/vllm-deploy.yml` deploys a single `vllm-server` container per host.
- `playbooks/vllm-test.yml` validates the single-node HTTP API and basic GPU state.
- `config/vllm.env` hard-codes `VLLM_TENSOR_PARALLEL_SIZE=1`.
- `config/vllm.service` is also single-node oriented.
- `scripts/vllm-benchmark.sh` is a single-host benchmark helper and does not support TP=2 orchestration.

### Hosts

Both DGX Spark nodes are reachable and expose:

- 1x NVIDIA GB10 GPU per host
- 119 GiB unified memory per host
- `enp1s0f0np0` on `192.168.200.101` and `192.168.200.102`, which is the best candidate for NCCL traffic
- Hugging Face caches that overlap on very large models and at least one prior-success path around a Qwen 35B A3B distilled variant

### Content draft

The current blog post is broad and useful as raw material, but it mixes:

- multiple unrelated model results
- direct host details
- personal framing that should be removed
- broad recommendations that are stronger than the evidence provided

## Recommended implementation approach

Use a dedicated **TP=2 benchmark lane** built on top of the current Makefile + Ansible workflow:

1. keep the existing single-node commands unchanged
2. add explicit TP=2 variables, targets, and playbooks for a single primary model
3. deploy a real two-node vLLM topology with one API/coordinator node and one worker node
4. add TP=2-specific validation and benchmark collection
5. write the report from measured results
6. revise the blog post to focus on the TP=2 experiment

This is preferred over either a generic multi-node framework or a one-off manual deployment because it keeps the change set focused while preserving reproducibility.

## Primary model strategy

Pick the primary model based on **cache overlap and known success probability**, not on parameter count alone.

Initial target:

- `Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled` or the exact corresponding local cache path available on both machines

Reasoning:

- both machines already show related cached artifacts
- the existing article indicates this family has already produced a successful single-node run
- it is more realistic for first TP=2 success than the 235B or 397B cached models

Fallback rule:

- if the exact model artifact layout differs between nodes enough to block TP=2 startup, inspect the shared cache set and pivot once to the next best overlap candidate with the highest success probability

## Design

### 1. Repository changes

Add a separate TP=2 path instead of stretching the single-node files with too many conditional branches.

Planned surfaces:

- `Makefile`
  - add dedicated TP=2 targets
  - expose TP=2 variables such as model, coordinator host, worker host, NCCL interface, port, and benchmark parameters
- `playbooks/`
  - add a TP=2 deployment playbook
  - add a TP=2 validation playbook
  - optionally add a TP=2 teardown playbook if stop logic becomes materially different from the single-node path
- `scripts/`
  - extend or replace the benchmark helper so it can target the TP=2 API endpoint and record node-level telemetry
- `benchmarks/`
  - store the generated benchmark report and any raw benchmark output needed for traceability

The single-node files remain intact unless a small shared helper extraction meaningfully reduces duplication.

### 2. Deployment topology

Topology:

- Node A: coordinator + OpenAI-compatible API endpoint
- Node B: worker participant in the TP=2 execution group

Required deployment behavior:

1. verify both nodes have the same image and a usable copy of the target model
2. use the dedicated high-speed interface for NCCL
3. ensure swap stays disabled and memory headroom is preserved
4. make TP=2 parameters explicit in the startup command
5. wait for full readiness before benchmarking

The implementation should prefer the deployment mode that vLLM 26.01 officially supports for cross-node execution in this environment. The code should surface the chosen executor mode directly in commands and logs so the benchmark report can describe what was actually used.

### 3. Validation flow

Validation should fail loudly and point to the likely layer of failure.

Checks to include:

1. host reachability and role mapping
2. NCCL interface visibility and node-to-node reachability
3. container start success on each node
4. logs that confirm distributed initialization rather than a silent single-node fallback
5. API readiness on the coordinator node
6. a short completion request before the real benchmark

If validation fails, the failure output should distinguish among:

- model/cache mismatch
- distributed initialization failure
- NCCL or interface issues
- memory pressure / OOM
- API not ready despite container start

### 4. Benchmark flow

The benchmark should be a deep single-case run, not a wide matrix.

Collected data:

- model identifier and artifact source used
- image and runtime parameters
- TP size, node mapping, interface choice
- model load time
- first-token latency
- completion throughput
- generated token count
- request success rate
- per-node memory and GPU state during the run
- any notable warnings in logs

At minimum, the benchmark should include:

1. one smoke request for correctness
2. a small set of prompts that differ enough to expose latency and throughput behavior
3. stable enough repetitions to avoid reporting a single noisy datapoint as the headline result

### 5. Report output

Generate a benchmark report in the repository that reads like an experiment record, not just a score sheet.

Recommended sections:

1. test objective
2. hardware and software environment
3. deployment topology and key parameters
4. benchmark methodology
5. measured results
6. issues encountered and fixes
7. interpretation and limits
8. practical recommendations for DGX Spark users considering TP=2

The report should clearly separate:

- measured facts
- informed interpretation
- tentative hypotheses

### 6. Blog rewrite

Rewrite `/Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md` around the TP=2 story.

Required changes:

1. remove direct host identifiers and any framing that implies personal ownership or access details
2. use language such as “recently had a chance to test two DGX Spark systems”
3. update the perspective consistently to April 2026
4. make the TP=2 benchmark the primary narrative
5. demote prior single-node model notes to supporting context unless they remain directly relevant
6. remove claims that are not supported by the new benchmark evidence
7. make it explicit when a statement is based on this test setup versus broader ecosystem expectations

Suggested article structure:

1. why TP=2 on DGX Spark is worth testing
2. hardware and software context
3. deployment path and constraints
4. benchmark methodology
5. results
6. what TP=2 does and does not change on DGX Spark
7. final takeaways

## Error handling and operational stance

- Prefer explicit failures over silent fallbacks.
- Do not let a TP=2 command succeed if the system actually came up in a single-node mode.
- Preserve the current conservative defaults around unified memory management.
- Log enough distributed startup detail to make post-run analysis possible.

## Testing and verification

Use existing project commands where possible, then add TP=2-specific commands around them.

Validation targets should cover:

1. connectivity and node readiness
2. TP=2 deployment success
3. TP=2 API smoke test
4. benchmark execution
5. report generation

The final article revision should be checked for:

- no direct host addresses
- no sensitive personal framing
- consistency with the measured benchmark data

## Risks and mitigations

### Risk: vLLM cross-node execution path differs from the current assumptions

Mitigation:

- inspect the exact runtime in the chosen image before hard-coding the orchestration flow
- encode the supported executor mode explicitly in the playbook and report

### Risk: model cache mismatch between nodes

Mitigation:

- detect the exact artifact names on both machines before deployment
- choose the most reliable overlap candidate first

### Risk: NCCL instability on the wrong interface

Mitigation:

- prefer `enp1s0f0np0`
- emit interface choice in logs and benchmark metadata

### Risk: unified memory pressure still causes instability

Mitigation:

- keep conservative memory utilization defaults
- collect node-level memory telemetry during runs

## Success criteria

This work is successful when all of the following are true:

1. the repository has a dedicated, reproducible TP=2 workflow
2. a real TP=2 benchmark has been run on the two DGX Spark nodes for one primary model
3. a benchmark report has been generated from that run
4. the blog post has been revised to match the TP=2 benchmark story and removes sensitive details
