#!/usr/bin/env bash
# Run the aider polyglot benchmark against the self-hosted deepseek-v4-flash.
#
#   run_bench.sh <run-name> <edit-format> [languages] [threads] [num-tests]
#
# edit-format:
#   diff  -- model emits SEARCH/REPLACE blocks (what Codex/qwen CLI actually
#            exercise, and what our SWE-bench run showed the model failing at)
#   whole -- model re-emits the entire file; no diff arithmetic involved
# Comparing the two separates "cannot code" from "cannot write an edit format".
set -eu

RUN_NAME="${1:?run name}"
EDIT_FORMAT="${2:?edit format: diff|whole}"
LANGS="${3:-}"
THREADS="${4:-4}"
NUM_TESTS="${5:--1}"   # -1 = all

cd /home/admin/aider-bench/aider

ARGS=(
  "$RUN_NAME"
  --model openai/deepseek-v4-flash
  --edit-format "$EDIT_FORMAT"
  --exercises-dir polyglot-benchmark
  --threads "$THREADS"
  --tries 2
  --num-tests "$NUM_TESTS"
  --new
)
[ -n "$LANGS" ] && ARGS+=(--languages "$LANGS")

# vLLM is on the host; reach it over the docker bridge gateway.
# --memory is a ceiling, not a reservation: vLLM holds ~108G of the box's 121G
# and only ~12G is free, so upstream's 12g cap would let the container grow into
# the headroom and OOM the head node (CLAUDE.md records exactly that killing the
# production stack). 8g is well clear of what compiling Exercism tests needs.
docker run --rm \
  --memory=8g --memory-swap=8g \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)":/aider \
  -v "$(pwd)/tmp.benchmarks/.":/benchmarks \
  -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= \
  -e AIDER_DOCKER=1 \
  -e AIDER_BENCHMARK_DIR=/benchmarks \
  -e OPENAI_API_BASE=http://172.17.0.1:8000/v1 \
  -e OPENAI_API_KEY=dummy \
  -e AIDER_MODEL_METADATA_FILE=/aider/.aider.model.metadata.json \
  aider-benchmark \
  ./benchmark/benchmark.py "${ARGS[@]}"
