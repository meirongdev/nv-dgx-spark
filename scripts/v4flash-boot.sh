#!/usr/bin/env bash
#
# v4flash-boot.sh — boot-time launcher/teardown for the DeepSeek-V4-Flash
# dual-node TP=2 vLLM stack (eugr spark-vllm-docker harness + jasl/vllm fork).
#
# Driven by the deepseek-v4-flash.service systemd unit on the HEAD node
# (User=admin). The head's launch-cluster.sh brings the TP worker up over SSH,
# so there is NO worker-side unit — only docker + sshd (both default-enabled)
# need to be running on the worker.
#
#   v4flash-boot.sh          # wait for worker, clean stale state, launch (blocks)
#   v4flash-boot.sh stop     # tear down vllm_node on both nodes
#
# Why a wrapper instead of a docker --restart policy: vLLM runs as a foreground
# `docker exec` INSIDE a `sleep infinity --rm` container, so a restart policy
# would only revive the sleep, not vLLM. The whole orchestration must re-run.
#
# Tunables come from the environment (set in the unit; sane defaults here so the
# script also works when run by hand):
#   DSV4_HARNESS       harness dir on the head        (/home/admin/spark-vllm-docker)
#   DSV4_WORKER        TP worker over the 200G link   (192.168.200.102)
#   DSV4_CONTAINER     container name on both nodes    (vllm_node)
#   DSV4_RECIPE        recipe name                     (deepseek-v4-flash)
#   DSV4_WAIT_TIMEOUT  seconds to wait for the worker  (900)
#
# NOTE: no `set -e` — the readiness loops below rely on commands failing.
set -uo pipefail

HARNESS="${DSV4_HARNESS:-/home/admin/spark-vllm-docker}"
WORKER="${DSV4_WORKER:-192.168.200.102}"
CONTAINER="${DSV4_CONTAINER:-vllm_node}"
RECIPE="${DSV4_RECIPE:-deepseek-v4-flash}"
WAIT_TIMEOUT="${DSV4_WAIT_TIMEOUT:-900}"

# Worker has no foreign-net proxy → keep HF/transformers fully offline.
export DOTENV_CONTAINER_HF_HUB_OFFLINE="${DOTENV_CONTAINER_HF_HUB_OFFLINE:-1}"
export DOTENV_CONTAINER_TRANSFORMERS_OFFLINE="${DOTENV_CONTAINER_TRANSFORMERS_OFFLINE:-1}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no)

log() { echo "[v4flash-boot] $*"; }

teardown() {
    log "tearing down '$CONTAINER' on head + worker $WORKER"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ssh "${SSH_OPTS[@]}" "$WORKER" "docker rm -f $CONTAINER" >/dev/null 2>&1 || true
}

# ExecStop path: just remove the containers on both nodes (kills the in-container
# vLLM that a plain SIGTERM to the docker-exec client would leave running).
if [[ "${1:-start}" == "stop" ]]; then
    teardown
    exit 0
fi

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
wait_for() {  # wait_for <label> <cmd...>
    local label="$1"; shift
    until "$@" >/dev/null 2>&1; do
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            log "FATAL: timed out waiting for ${label} after ${WAIT_TIMEOUT}s"
            exit 1
        fi
        log "waiting for ${label} ..."
        sleep 5
    done
    log "${label} ready"
}

# 1) Local docker + GPU (nvidia kernel modules may still be loading post-boot).
wait_for "local docker" docker info
wait_for "local GPU"    nvidia-smi -L

# 2) Worker reachable over the 200G link, with docker + GPU up. Reaching the
#    worker over 192.168.200.x inherently confirms the NCCL link is up on both
#    ends — launch-cluster.sh aborts if this SSH fails, so we gate on it here.
wait_for "worker ${WORKER} ssh+docker" ssh "${SSH_OPTS[@]}" "$WORKER" "docker info"
wait_for "worker ${WORKER} GPU"        ssh "${SSH_OPTS[@]}" "$WORKER" "nvidia-smi -L"

# 3) Clean slate so a (re)launch — boot OR Restart=on-failure — is idempotent.
teardown

# 4) Launch the dual-node stack in the foreground. The head's blocking
#    `docker exec ... vllm serve` keeps this PID (and the systemd unit) alive
#    for vLLM's lifetime; launch-cluster.sh starts the worker rank over SSH.
cd "$HARNESS" || { log "FATAL: harness dir '$HARNESS' missing"; exit 1; }
log "launching recipe '${RECIPE}' (--no-ray) from ${HARNESS}"
exec ./run-recipe.sh "$RECIPE" --no-ray
