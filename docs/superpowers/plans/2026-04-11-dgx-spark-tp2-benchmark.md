# DGX Spark TP=2 Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible two-node TP=2 vLLM benchmark lane to this repository, run one real benchmark on the DGX Spark pair, generate a report, and rewrite the April 2026 blog post around the TP=2 experiment without sensitive details.

**Architecture:** Keep the existing single-node flow untouched and add a dedicated TP=2 path. Put the cross-node launch logic in a small shell wrapper, orchestrate it with new Ansible playbooks and Makefile targets, generate one benchmark report from measured data, then rewrite the article to match the new benchmark story.

**Tech Stack:** GNU Make, Ansible, Bash, Docker, vLLM `0.13.0+faa43dbf` from `nvcr.io/nvidia/vllm:26.01-py3`, Markdown

---

## File map

- Modify: `Makefile`
  - Add TP=2 variables and the deploy/validate/stop targets first; wire the benchmark target when the benchmark script exists
- Create: `scripts/run-vllm-tp2.sh`
  - Single responsibility: start one TP=2 participant container on a node with the correct distributed flags
- Create: `playbooks/vllm-tp2-deploy.yml`
  - Single responsibility: preflight both DGX nodes, verify model/cache readiness, copy launcher, and start TP=2
- Create: `playbooks/vllm-tp2-validate.yml`
  - Single responsibility: verify logs, health endpoint, `/v1/models`, and a smoke completion on the coordinator
- Create: `playbooks/vllm-tp2-stop.yml`
  - Single responsibility: stop and remove the TP=2 container on both nodes
- Create: `scripts/vllm-tp2-benchmark.sh`
  - Single responsibility: exercise the TP=2 API endpoint, collect per-node telemetry over SSH, and render a Markdown benchmark report
- Create: `benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md`
  - Benchmark report generated from the real TP=2 run
- Modify: `/Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md`
  - Rewrite the article around the TP=2 benchmark and remove sensitive/personal framing

## Runtime contract locked before coding

Use these confirmed vLLM flags when implementing the TP=2 path:

```text
--distributed-executor-backend
--pipeline-parallel-size
--master-addr
--master-port
--nnodes
--node-rank
--tensor-parallel-size
--data-parallel-size
```

Use these defaults unless measurements force a change:

```text
TP size: 2
PP size: 1
Nodes: 2
NCCL interface: enp1s0f0np0
Port: 8000
Master port: 29500
GPU memory utilization: 0.7
Max model len: 8192
Primary model: Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled
Coordinator: 100.97.87.120
Worker: 100.67.164.92
```

### Task 1: Add the TP=2 entrypoints and launcher

**Files:**
- Create: `scripts/run-vllm-tp2.sh`
- Modify: `Makefile`
- Test: `Makefile` targets via `make -n` and shell syntax check

- [ ] **Step 1: Confirm the TP=2 entrypoints do not exist yet**

Run:

```bash
make -n vllm-tp2-deploy
```

Expected:

```text
make: *** No rule to make target 'vllm-tp2-deploy'.  Stop.
```

- [ ] **Step 2: Confirm the exact distributed flags on the target image**

Run:

```bash
ssh -i /Users/matthew/.ssh/vgio -o StrictHostKeyChecking=no admin@100.67.164.92 \
  "docker run --rm --gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 \
   nvcr.io/nvidia/vllm:26.01-py3 bash -lc \"python3 - <<'PY'
import inspect
from vllm.engine import arg_utils
text = inspect.getsource(arg_utils.EngineArgs.add_cli_args)
for needle in ['distributed_executor_backend', 'pipeline_parallel_size', 'master_addr', 'master_port', 'nnodes', 'node_rank', 'tensor_parallel_size']:
    idx = text.find(needle)
    print(text[max(0, idx - 150):idx + 250])
PY\""
```

Expected: output contains `--distributed-executor-backend`, `--pipeline-parallel-size`, `--master-addr`, `--master-port`, `--nnodes`, `--node-rank`, and `--tensor-parallel-size`.

- [ ] **Step 3: Write the TP=2 launcher script**

Create `scripts/run-vllm-tp2.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TP2_MODEL="${TP2_MODEL:?TP2_MODEL is required}"
TP2_IMAGE="${TP2_IMAGE:-nvcr.io/nvidia/vllm:26.01-py3}"
TP2_MASTER_ADDR="${TP2_MASTER_ADDR:?TP2_MASTER_ADDR is required}"
TP2_MASTER_PORT="${TP2_MASTER_PORT:-29500}"
TP2_NNODES="${TP2_NNODES:-2}"
TP2_NODE_RANK="${TP2_NODE_RANK:?TP2_NODE_RANK is required}"
TP2_TP_SIZE="${TP2_TP_SIZE:-2}"
TP2_PP_SIZE="${TP2_PP_SIZE:-1}"
TP2_PORT="${TP2_PORT:-8000}"
TP2_GPU_MEMORY_UTIL="${TP2_GPU_MEMORY_UTIL:-0.7}"
TP2_MAX_MODEL_LEN="${TP2_MAX_MODEL_LEN:-8192}"
TP2_CONTAINER_NAME="${TP2_CONTAINER_NAME:-vllm-tp2}"
TP2_NCCL_IFACE="${TP2_NCCL_IFACE:-enp1s0f0np0}"
TP2_HF_CACHE_DIR="${TP2_HF_CACHE_DIR:-/home/admin/.cache/huggingface}"

docker rm -f "${TP2_CONTAINER_NAME}" 2>/dev/null || true

docker run -d \
  --name "${TP2_CONTAINER_NAME}" \
  --restart unless-stopped \
  --gpus all \
  --network host \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -v "${TP2_HF_CACHE_DIR}:/root/.cache/huggingface" \
  -e VLLM_ATTENTION_BACKEND="${VLLM_ATTENTION_BACKEND:-FLASHINFER}" \
  -e VLLM_USE_FLASHINFER_MOE_FP8="${VLLM_USE_FLASHINFER_MOE_FP8:-1}" \
  -e VLLM_FLASHINFER_MOE_BACKEND="${VLLM_FLASHINFER_MOE_BACKEND:-latency}" \
  -e NCCL_SOCKET_IFNAME="${TP2_NCCL_IFACE}" \
  -e GLOO_SOCKET_IFNAME="${TP2_NCCL_IFACE}" \
  -e CUDA_VISIBLE_DEVICES=0 \
  "${TP2_IMAGE}" \
  vllm serve "${TP2_MODEL}" \
    --host 0.0.0.0 \
    --port "${TP2_PORT}" \
    --distributed-executor-backend ray \
    --pipeline-parallel-size "${TP2_PP_SIZE}" \
    --master-addr "${TP2_MASTER_ADDR}" \
    --master-port "${TP2_MASTER_PORT}" \
    --nnodes "${TP2_NNODES}" \
    --node-rank "${TP2_NODE_RANK}" \
    --tensor-parallel-size "${TP2_TP_SIZE}" \
    --gpu-memory-utilization "${TP2_GPU_MEMORY_UTIL}" \
    --kv-cache-dtype fp8 \
    --dtype auto \
    --max-model-len "${TP2_MAX_MODEL_LEN}" \
    --max-num-seqs 64 \
    --trust-remote-code
```

- [ ] **Step 4: Add TP=2 variables and Make targets**

Modify `Makefile`:

```make
.PHONY: venv install test ping all clean vllm-deploy vllm-test vllm-status vllm-stop vllm-benchmark vllm-monitor vllm-tp2-deploy vllm-tp2-test vllm-tp2-stop

TP2_COORDINATOR ?= 100.97.87.120
TP2_WORKER ?= 100.67.164.92
TP2_MODEL ?= Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled
TP2_IMAGE ?= $(VLLM_IMAGE)
TP2_PORT ?= 8000
TP2_MASTER_PORT ?= 29500
TP2_NCCL_IFACE ?= enp1s0f0np0
TP2_GPU_MEMORY_UTIL ?= 0.7
TP2_MAX_MODEL_LEN ?= 8192

vllm-tp2-deploy:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-deploy.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_worker=$(TP2_WORKER)" \
		-e "tp2_model=$(TP2_MODEL)" \
		-e "tp2_image=$(TP2_IMAGE)" \
		-e "tp2_port=$(TP2_PORT)" \
		-e "tp2_master_port=$(TP2_MASTER_PORT)" \
		-e "tp2_nccl_iface=$(TP2_NCCL_IFACE)" \
		-e "tp2_gpu_memory_utilization=$(TP2_GPU_MEMORY_UTIL)" \
		-e "tp2_max_model_len=$(TP2_MAX_MODEL_LEN)"

vllm-tp2-test:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-validate.yml \
		--ssh-extra-args="-i $(SSH_KEY)" \
		-e "tp2_coordinator=$(TP2_COORDINATOR)" \
		-e "tp2_model=$(TP2_MODEL)" \
		-e "tp2_port=$(TP2_PORT)"

vllm-tp2-stop:
	uv run ansible-playbook -i $(INVENTORY) playbooks/vllm-tp2-stop.yml \
		--ssh-extra-args="-i $(SSH_KEY)"

```

- [ ] **Step 5: Verify the new entrypoints exist and the launcher is syntactically valid**

Run:

```bash
make -n vllm-tp2-deploy
bash -n scripts/run-vllm-tp2.sh
```

Expected:

```text
uv run ansible-playbook -i inventory.ini playbooks/vllm-tp2-deploy.yml ...
```

and no output from `bash -n`.

- [ ] **Step 6: Commit**

```bash
git add Makefile scripts/run-vllm-tp2.sh
git commit -m "feat: add TP2 launcher and make targets"
```

### Task 2: Add TP=2 deployment, validation, and stop playbooks

**Files:**
- Create: `playbooks/vllm-tp2-deploy.yml`
- Create: `playbooks/vllm-tp2-validate.yml`
- Create: `playbooks/vllm-tp2-stop.yml`
- Test: `uv run ansible-playbook --syntax-check ...`

- [ ] **Step 1: Confirm the TP=2 playbooks do not exist yet**

Run:

```bash
uv run ansible-playbook -i inventory.ini playbooks/vllm-tp2-deploy.yml --syntax-check
```

Expected:

```text
ERROR! the playbook: playbooks/vllm-tp2-deploy.yml could not be found
```

- [ ] **Step 2: Write the TP=2 deploy playbook**

Create `playbooks/vllm-tp2-deploy.yml`:

```yaml
---
- name: Deploy vLLM TP=2 on DGX Spark pair
  hosts: servers
  become: yes
  gather_facts: yes
  vars:
    tp2_coordinator: "100.97.87.120"
    tp2_worker: "100.67.164.92"
    tp2_model: "Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled"
    tp2_image: "nvcr.io/nvidia/vllm:26.01-py3"
    tp2_port: 8000
    tp2_master_port: 29500
    tp2_nccl_iface: "enp1s0f0np0"
    tp2_gpu_memory_utilization: 0.7
    tp2_max_model_len: 8192
    tp2_container_name: "vllm-tp2"
    tp2_hf_cache_dir: "/home/admin/.cache/huggingface"

  tasks:
    - name: Assert coordinator and worker are in inventory
      ansible.builtin.assert:
        that:
          - tp2_coordinator in groups['servers']
          - tp2_worker in groups['servers']

    - name: Disable swap
      ansible.builtin.command: swapoff -a
      changed_when: true
      failed_when: false

    - name: Verify docker is installed
      ansible.builtin.command: docker --version
      changed_when: false

    - name: Verify GPU is visible
      ansible.builtin.command: nvidia-smi --query-gpu=name --format=csv,noheader
      register: gpu_name
      changed_when: false

    - name: Verify NCCL interface exists
      ansible.builtin.command: ip -4 addr show "{{ tp2_nccl_iface }}"
      changed_when: false

    - name: Verify target model cache exists
      ansible.builtin.shell: |
        set -euo pipefail
        find "{{ tp2_hf_cache_dir }}" -maxdepth 3 -type d | grep -i "Qwen3.5-35B-A3B\|Opus-Reasoning-Distilled" | head -n 1
      args:
        executable: /bin/bash
      register: cache_match
      changed_when: false

    - name: Fail if model cache is missing on a node
      ansible.builtin.fail:
        msg: "Model cache for {{ tp2_model }} not found under {{ tp2_hf_cache_dir }}"
      when: cache_match.stdout == ""

    - name: Copy TP=2 launcher
      ansible.builtin.copy:
        src: ../scripts/run-vllm-tp2.sh
        dest: /usr/local/bin/run-vllm-tp2.sh
        mode: "0755"

    - name: Stop any previous TP=2 container
      ansible.builtin.command: docker rm -f {{ tp2_container_name }}
      changed_when: true
      failed_when: false

    - name: Launch TP=2 participant
      ansible.builtin.command: /usr/local/bin/run-vllm-tp2.sh
      environment:
        TP2_MODEL: "{{ tp2_model }}"
        TP2_IMAGE: "{{ tp2_image }}"
        TP2_MASTER_ADDR: "{{ tp2_coordinator }}"
        TP2_MASTER_PORT: "{{ tp2_master_port }}"
        TP2_NNODES: "2"
        TP2_NODE_RANK: "{{ '0' if inventory_hostname == tp2_coordinator else '1' }}"
        TP2_TP_SIZE: "2"
        TP2_PP_SIZE: "1"
        TP2_PORT: "{{ tp2_port }}"
        TP2_GPU_MEMORY_UTIL: "{{ tp2_gpu_memory_utilization }}"
        TP2_MAX_MODEL_LEN: "{{ tp2_max_model_len }}"
        TP2_CONTAINER_NAME: "{{ tp2_container_name }}"
        TP2_NCCL_IFACE: "{{ tp2_nccl_iface }}"
        TP2_HF_CACHE_DIR: "{{ tp2_hf_cache_dir }}"
      register: tp2_launch
      changed_when: true

    - name: Wait for coordinator port
      ansible.builtin.wait_for:
        host: "{{ tp2_coordinator }}"
        port: "{{ tp2_port }}"
        state: started
        delay: 10
        timeout: 600
      run_once: true
```

- [ ] **Step 3: Write the TP=2 validation playbook**

Create `playbooks/vllm-tp2-validate.yml`:

```yaml
---
- name: Validate vLLM TP=2 deployment
  hosts: servers
  gather_facts: no
  vars:
    tp2_coordinator: "100.97.87.120"
    tp2_model: "Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled"
    tp2_port: 8000
    tp2_container_name: "vllm-tp2"

  tasks:
    - name: Read TP=2 container logs
      ansible.builtin.command: docker logs {{ tp2_container_name }} --tail 120
      register: tp2_logs
      changed_when: false
      failed_when: false

    - name: Assert distributed startup markers exist
      ansible.builtin.assert:
        that:
          - "'tensor_parallel_size' in tp2_logs.stdout or '--tensor-parallel-size' in tp2_logs.stdout or 'ray' in tp2_logs.stdout"
        fail_msg: "TP=2 markers not found in container logs on {{ inventory_hostname }}"

    - name: Check health endpoint on coordinator
      ansible.builtin.uri:
        url: "http://{{ tp2_coordinator }}:{{ tp2_port }}/health"
        method: GET
        status_code: 200
        timeout: 20
      run_once: true

    - name: Check models endpoint on coordinator
      ansible.builtin.uri:
        url: "http://{{ tp2_coordinator }}:{{ tp2_port }}/v1/models"
        method: GET
        status_code: 200
        timeout: 20
      register: models_result
      run_once: true

    - name: Assert target model is exposed
      ansible.builtin.assert:
        that:
          - tp2_model in (models_result.json.data | map(attribute='id') | list | join(' '))
      run_once: true

    - name: Run smoke completion on coordinator
      ansible.builtin.uri:
        url: "http://{{ tp2_coordinator }}:{{ tp2_port }}/v1/completions"
        method: POST
        body_format: json
        body:
          model: "{{ tp2_model }}"
          prompt: "Say hello in one sentence."
          max_tokens: 32
          temperature: 0
        status_code: 200
        timeout: 120
      register: smoke_completion
      run_once: true
```

- [ ] **Step 4: Write the TP=2 stop playbook**

Create `playbooks/vllm-tp2-stop.yml`:

```yaml
---
- name: Stop vLLM TP=2 containers
  hosts: servers
  gather_facts: no
  vars:
    tp2_container_name: "vllm-tp2"

  tasks:
    - name: Stop TP=2 container if present
      ansible.builtin.command: docker rm -f {{ tp2_container_name }}
      changed_when: true
      failed_when: false
```

- [ ] **Step 5: Verify all new playbooks parse**

Run:

```bash
uv run ansible-playbook -i inventory.ini playbooks/vllm-tp2-deploy.yml --syntax-check
uv run ansible-playbook -i inventory.ini playbooks/vllm-tp2-validate.yml --syntax-check
uv run ansible-playbook -i inventory.ini playbooks/vllm-tp2-stop.yml --syntax-check
```

Expected:

```text
playbook: playbooks/vllm-tp2-deploy.yml
playbook: playbooks/vllm-tp2-validate.yml
playbook: playbooks/vllm-tp2-stop.yml
```

- [ ] **Step 6: Commit**

```bash
git add playbooks/vllm-tp2-deploy.yml playbooks/vllm-tp2-validate.yml playbooks/vllm-tp2-stop.yml
git commit -m "feat: add TP2 ansible playbooks"
```

### Task 3: Add TP=2 benchmark collection and report rendering

**Files:**
- Modify: `Makefile`
- Create: `scripts/vllm-tp2-benchmark.sh`
- Test: `bash -n scripts/vllm-tp2-benchmark.sh`

- [ ] **Step 1: Confirm the TP=2 benchmark script does not exist yet**

Run:

```bash
bash scripts/vllm-tp2-benchmark.sh
```

Expected:

```text
bash: scripts/vllm-tp2-benchmark.sh: No such file or directory
```

- [ ] **Step 2: Write the TP=2 benchmark script**

Create `scripts/vllm-tp2-benchmark.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

COORDINATOR_HOST="${1:?coordinator host required}"
WORKER_HOST="${2:?worker host required}"
MODEL_NAME="${3:?model required}"
PORT="${4:-8000}"
SSH_KEY="${5:-/Users/matthew/.ssh/vgio}"
SSH_USER="${6:-admin}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="benchmarks"
REPORT_FILE="${REPORT_DIR}/dgx-spark-tp2-qwen35a3b-2026-04-11.md"

mkdir -p "${REPORT_DIR}"

ssh_cmd() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
}

collect_node_snapshot() {
  local host="$1"
  ssh_cmd "${host}" "printf 'host=%s\n' \"$(hostname)\" && free -h | sed -n '1,2p' && nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader"
}

run_case() {
  local label="$1"
  local prompt="$2"
  local max_tokens="$3"
  local start_ns end_ns elapsed_ms
  start_ns="$(date +%s%N)"
  response="$(curl -sS -w '\n%{http_code}' "http://${COORDINATOR_HOST}:${PORT}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"${prompt}\",\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}")"
  end_ns="$(date +%s%N)"
  elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"
  http_code="$(printf '%s' "${response}" | tail -n1)"
  body="$(printf '%s' "${response}" | sed '$d')"
  completion_tokens="$(printf '%s' "${body}" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data.get("usage",{}).get("completion_tokens",0))')"
  first_text="$(printf '%s' "${body}" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data["choices"][0]["text"][:80].replace("\n"," "))')"
  tokens_per_sec="$(python3 - <<PY
elapsed_ms = ${elapsed_ms}
tokens = ${completion_tokens}
print(round((tokens * 1000 / elapsed_ms), 2) if elapsed_ms else 0)
PY
)"
  printf '| %s | %s | %s | %s | %s | %s |\n' "${label}" "${http_code}" "${completion_tokens}" "${elapsed_ms}" "${tokens_per_sec}" "${first_text}"
}

{
  echo '# DGX Spark TP=2 Benchmark Report'
  echo
  echo '## Environment'
  echo
  echo "| Field | Value |"
  echo "|------|-------|"
  echo "| Date | 2026-04-11 |"
  echo "| Coordinator | ${COORDINATOR_HOST} |"
  echo "| Worker | ${WORKER_HOST} |"
  echo "| Model | ${MODEL_NAME} |"
  echo "| TP Size | 2 |"
  echo "| Port | ${PORT} |"
  echo
  echo '## Pre-run snapshots'
  echo
  echo '```text'
  collect_node_snapshot "${COORDINATOR_HOST}"
  echo '---'
  collect_node_snapshot "${WORKER_HOST}"
  echo '```'
  echo
  echo '## Benchmark results'
  echo
  echo '| Case | HTTP | Completion Tokens | Latency (ms) | Tokens/s | Preview |'
  echo '|------|------|-------------------|--------------|----------|---------|'
  run_case "short-greeting" "Say hello in one sentence." 32
  run_case "memory-summary" "Explain unified memory on DGX Spark in under 80 words." 96
  run_case "code-snippet" "Write a Python function that computes Fibonacci with memoization." 160
  echo
  echo '## Post-run snapshots'
  echo
  echo '```text'
  collect_node_snapshot "${COORDINATOR_HOST}"
  echo '---'
  collect_node_snapshot "${WORKER_HOST}"
  echo '```'
} > "${REPORT_FILE}"

echo "Report written to ${REPORT_FILE}"
```

- [ ] **Step 3: Wire the benchmark target into Makefile**

Modify `Makefile`:

```make
.PHONY: venv install test ping all clean vllm-deploy vllm-test vllm-status vllm-stop vllm-benchmark vllm-monitor vllm-tp2-deploy vllm-tp2-test vllm-tp2-stop vllm-tp2-benchmark

vllm-tp2-benchmark:
	bash scripts/vllm-tp2-benchmark.sh "$(TP2_COORDINATOR)" "$(TP2_WORKER)" "$(TP2_MODEL)" "$(TP2_PORT)" "$(SSH_KEY)" "$(SSH_USER)"
```

- [ ] **Step 4: Verify the benchmark script parses**

Run:

```bash
bash -n scripts/vllm-tp2-benchmark.sh
```

Expected: no output.

- [ ] **Step 5: Verify the benchmark target expands correctly**

Run:

```bash
make -n vllm-tp2-benchmark
```

Expected:

```text
bash scripts/vllm-tp2-benchmark.sh "100.97.87.120" "100.67.164.92" ...
```

- [ ] **Step 6: Commit**

```bash
git add Makefile scripts/vllm-tp2-benchmark.sh
git commit -m "feat: add TP2 benchmark script"
```

### Task 4: Run the real TP=2 deployment, validate it, and persist the benchmark report

**Files:**
- Modify: `benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md` (generated output)
- Test: live commands against the two DGX Spark nodes

- [ ] **Step 1: Prove the deployment is not already healthy**

Run:

```bash
curl -fsS http://100.97.87.120:8000/health
```

Expected: connection failure or non-200 before the TP=2 deployment starts.

- [ ] **Step 2: Deploy TP=2**

Run:

```bash
make vllm-tp2-deploy \
  TP2_MODEL=Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled \
  TP2_COORDINATOR=100.97.87.120 \
  TP2_WORKER=100.67.164.92 \
  TP2_NCCL_IFACE=enp1s0f0np0 \
  TP2_GPU_MEMORY_UTIL=0.7 \
  TP2_MAX_MODEL_LEN=8192
```

Expected: both nodes report successful preflight and the coordinator port opens.

- [ ] **Step 3: Validate the live TP=2 service**

Run:

```bash
make vllm-tp2-test \
  TP2_MODEL=Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled \
  TP2_COORDINATOR=100.97.87.120
```

Expected:

```text
TASK [Assert distributed startup markers exist] ********************************
ok: [100.97.87.120]
ok: [100.67.164.92]
TASK [Run smoke completion on coordinator] *************************************
ok: [100.97.87.120]
```

- [ ] **Step 4: Generate the benchmark report from the live run**

Run:

```bash
make vllm-tp2-benchmark \
  TP2_MODEL=Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled \
  TP2_COORDINATOR=100.97.87.120 \
  TP2_WORKER=100.67.164.92
```

Expected:

```text
Report written to benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md
```

- [ ] **Step 5: Sanity-check the generated report**

Run:

```bash
rg -n "DGX Spark TP=2 Benchmark Report|Benchmark results|Coordinator|Worker" benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md
```

Expected: four matches, proving the report rendered the top-level sections.

- [ ] **Step 6: Stop the TP=2 containers after the benchmark**

Run:

```bash
make vllm-tp2-stop
```

Expected: both nodes remove `vllm-tp2` without failing the playbook.

- [ ] **Step 7: Commit**

```bash
git add benchmarks/dgx-spark-tp2-qwen35a3b-2026-04-11.md
git commit -m "docs: add TP2 benchmark report"
```

### Task 5: Rewrite the blog post around the TP=2 experiment

**Files:**
- Modify: `/Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md`
- Test: `rg` content checks against the rewritten article

- [ ] **Step 1: Confirm the current draft still contains sensitive or off-target framing**

Run:

```bash
rg -n "100\\.67\\.164\\.92|我手头刚好有两台|个人 AI 超级计算机|本项目 GitHub" /Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md
```

Expected: matches found.

- [ ] **Step 2: Replace the frontmatter and opening with a TP=2-focused framing**

Update the frontmatter and opening section to this shape:

```markdown
---
title: "DGX Spark TP=2 实测：两台 GB10 能把 35B MoE 跑到什么程度？"
date: 2026-04-11T18:30:00+08:00
draft: false
tags: ["AI", "LLM", "NVIDIA", "DGX Spark", "vLLM", "benchmark", "Tensor Parallel"]
categories: ["AI/ML", "Hardware"]
description: "一次基于两台 DGX Spark 的 TP=2 实测：部署路径、踩坑、吞吐与延迟表现，以及它到底适不适合 35B 级别模型。"
keywords: ["DGX Spark", "GB10", "Blackwell", "vLLM", "Tensor Parallel", "TP=2", "Qwen3.5", "benchmark"]
---

## 前言

最近刚好有机会同时测试两台 DGX Spark，于是把目标收窄到一个更具体的问题：**如果把两台 GB10 通过 TP=2 组起来，能否把 35B 级别的 MoE 模型跑得更稳、更像一套可复现的实验？**

这篇文章不做“所有模型横评”，也不讨论购买建议，而是围绕一次真实的 TP=2 部署与 benchmark 展开：环境怎么搭、为什么选这个模型、实际遇到了哪些问题、最后跑出了什么结果，以及这些结果对 DGX Spark 的意义到底有多大。
```

- [ ] **Step 3: Replace the body structure so the article follows the benchmark story**

Use these section headings and keep every conclusion tied to measured results:

```markdown
## 为什么要测 TP=2，而不是继续做单机 benchmark？
## 测试环境与约束
## 选型：为什么先测 Qwen3.5-35B-A3B-Claude-Distilled
## TP=2 部署过程
## Benchmark 方法
## Benchmark 结果
## 这次实测说明了什么？
## 结论
```

Inside `## 测试环境与约束`, keep this wording pattern:

```markdown
- **测试对象**：两台 NVIDIA DGX Spark（GB10，128GB 统一内存）
- **运行方式**：vLLM + TP=2
- **镜像基线**：`nvcr.io/nvidia/vllm:26.01-py3`
- **核心参数**：`--distributed-executor-backend ray`、`--tensor-parallel-size 2`、`--nnodes 2`
- **网络接口**：`enp1s0f0np0`
- **注意事项**：swap 关闭、GPU memory utilization 保持在 0.7、只围绕一个主模型做深测
```

- [ ] **Step 4: Remove unsupported claims and personal framing**

Apply these exact rewrites:

```markdown
- 把“我手头刚好有两台 DGX Spark”改成“最近刚好有机会同时测试两台 DGX Spark”
- 删除具体 IP、具体主机编号和任何能直接定位设备的信息
- 删除“选购建议”“适合谁/不适合谁”“最终评分”整段
- 把“低于社区预期”改成“低于这次测试前的经验预期”或“低于常见公开讨论里的区间”
- 把“根本不可能”改成“在这次 128GB 统一内存 + 当前运行参数的条件下不可行”
```

- [ ] **Step 5: Verify the article no longer leaks sensitive details and now mentions TP=2 explicitly**

Run:

```bash
rg -n "100\\.|我手头刚好有两台|最终评分|选购建议" /Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md
rg -n "TP=2|tensor-parallel-size 2|distributed-executor-backend ray|最近刚好有机会同时测试两台 DGX Spark" /Users/matthew/projects/meirongdev/blog/content/posts/dgx-spark-benchmark-2026.md
```

Expected:

```text
first rg: no matches
second rg: matches found
```

- [ ] **Step 6: Commit**

```bash
git -C /Users/matthew/projects/meirongdev/blog add content/posts/dgx-spark-benchmark-2026.md
git -C /Users/matthew/projects/meirongdev/blog commit -m "docs: rewrite DGX Spark TP2 benchmark article"
```

## Self-review checklist

- Spec coverage:
  - TP=2 workflow: Tasks 1-2
  - Real benchmark run: Task 4
  - Generated report: Tasks 3-4
  - Blog rewrite and de-sensitization: Task 5
- Placeholder scan:
  - No unfinished placeholders or deferred-work markers remain
- Type and naming consistency:
  - `TP2_*` variable family is consistent across Makefile, playbooks, and scripts
  - `vllm-tp2` is the single container name used across deploy/validate/stop
