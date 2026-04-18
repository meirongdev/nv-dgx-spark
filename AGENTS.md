# Repository Guidelines

This repository manages the deployment and optimization of LLM inference stacks (vLLM and Bifrost Gateway) on the DGX Spark cluster.

## Project Structure & Module Organization
- `playbooks/`: Ansible playbooks for system unification, vLLM deployment, and gateway configuration.
- `scripts/`: Helper scripts for GPU validation, memory monitoring, and vLLM patching.
- `config/`: Environment variables and configuration files (e.g., `.env`, `.json`, `.jinja2`).
- `benchmarks/`: Performance scripts and reports for various model configurations.
- `docs/`: Deployment guides and design specifications.

## Build, Test, and Development Commands
The project uses a `Makefile` to wrap `uv` and `ansible` commands.

- `make all`: Sets up the virtual environment, generates the inventory, and tests SSH connectivity.
- `make unify-system`: Unifies kernel and NVIDIA driver versions across the cluster.
- `make vllm-qwen36-deploy`: Deploys the current primary model (Qwen3.6-35B-A3B-FP8) on all hosts. `make vllm-qwen-deploy` and `make vllm-gemma4-deploy` deploy alternate models.
- `make bifrost-deploy`: Deploys the Bifrost gateway (`maximhq/bifrost`) on server 1 using `config/bifrost-config.json`.
- `make stack-deploy`: One-shot vLLM + Bifrost deploy (model controlled by `STACK_MODEL`, default `qwen36`). Corresponding `stack-stop` / `stack-status` targets exist.
- `make vllm-qwen36-status` / `make bifrost-status`: Check health and status.

## Coding Style & Naming Conventions
- **Ansible**: Follow YAML best practices; use descriptive variable names in playbooks.
- **Scripts**: Use Python for complex patching and Bash for simple system automation.
- **Naming**: Use kebab-case for file names (e.g., `vllm-tp2-deploy.yml`).
- **Environment**: Use `uv` for Python dependency management.

## Testing Guidelines
- **Connectivity**: Run `make test` to verify SSH access to all cluster nodes.
- **Deployment**: After deploying, use `make vllm-qwen36-status` (or the equivalent for the model you deployed) and `make bifrost-test` to validate API health.
- **Benchmarks**: Run scripts in `benchmarks/` to verify performance regressions after optimization.

## Commit & Pull Request Guidelines
- **Commits**: Follow Conventional Commits (e.g., `feat:`, `fix:`, `docs:`, `perf:`).
- **PRs**: 
  - Clearly describe the change and its impact on cluster performance.
  - Include logs or benchmark report snippets for `perf` or `fix` changes.
  - Ensure that `Makefile` targets are updated if new deployment workflows are added.
