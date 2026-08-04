# Repository Guidelines

This repository manages LLM inference deployment on a two-node NVIDIA DGX Spark
(GB10) cluster. Two stacks live here: the **current primary** (DeepSeek-V4-Flash,
dual-node TP=2 vLLM via the eugr `spark-vllm-docker` harness — **not** Ansible)
and a **retired but revivable** Ansible stack (Qwen/Gemma per-node vLLM + Bifrost
gateway). See `CLAUDE.md` for the full operational picture.

## Project Structure & Module Organization
- `playbooks/`: Ansible playbooks (retired vLLM/Bifrost stack, node/smartctl exporters).
- `scripts/`: Helper scripts (V4-Flash boot/test/torch-fix, proxy revival, patching).
- `config/`: V4-Flash recipe + systemd unit, Bifrost config, Qwen3.5 chat template.
- `benchmarks/`: Performance scripts and reports for various model configurations.
- `docs/`: Deployment runbooks (mostly Chinese): V4-Flash, DSpark upgrade, CN mirrors.

## Build, Test, and Development Commands
The `Makefile` is the single user-facing interface.

- **Current stack (V4-Flash)**: `make v4flash-run | v4flash-status | v4flash-test |
  v4flash-load | v4flash-logs | v4flash-stop`; boot autostart via
  `make v4flash-autostart*`. Runbook: `docs/deepseek-v4-flash-cn.md`.
- **Retired stack (revivable)**: `make all` (venv + inventory + SSH test), then
  `make stack-deploy` (model via `STACK_MODEL=qwen36|qwen|gemma4`),
  `make vllm-<model>-{deploy,status,stop,logs}`, `make bifrost-{deploy,test,status,stop}`.
- **Monitoring**: `make node-exporter-*` and `make smartctl-exporter-*` feed the
  homelab Prometheus/Grafana over Tailscale.

## Coding Style & Naming Conventions
- **Ansible**: Follow YAML best practices; use descriptive variable names in playbooks.
- **Scripts**: Use Python for complex patching and Bash for simple system automation.
- **Naming**: Use kebab-case for file names (e.g., `vllm-model-deploy.yml`).
- **Environment**: Use `uv` for Python dependency management (`uv run ansible-playbook ...`).

## Testing Guidelines
- **Connectivity**: Run `make test` to verify SSH access to all cluster nodes.
- **Current stack**: `make v4flash-status` (API + containers) and `make v4flash-test`
  (coding smoke test + tok/s). First request after a (re)start pays a one-time
  Triton JIT spike — ignore that measurement and retest.
- **Benchmarks**: Run scripts in `benchmarks/` to verify performance regressions after optimization.

## Commit & Pull Request Guidelines
- **Commits**: Follow Conventional Commits (e.g., `feat:`, `fix:`, `docs:`, `perf:`).
- **PRs**:
  - Clearly describe the change and its impact on cluster performance.
  - Include logs or benchmark report snippets for `perf` or `fix` changes.
  - Ensure that `Makefile` targets are updated if new deployment workflows are added.
