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
- `make vllm-deploy`: Deploys the primary vLLM instance on all hosts.
- `make stack-deploy`: Deploys both the vLLM backends and the Bifrost gateway.
- `make vllm-status` / `make stack-status`: Checks health and GPU utilization.

## Coding Style & Naming Conventions
- **Ansible**: Follow YAML best practices; use descriptive variable names in playbooks.
- **Scripts**: Use Python for complex patching and Bash for simple system automation.
- **Naming**: Use kebab-case for file names (e.g., `vllm-tp2-deploy.yml`).
- **Environment**: Use `uv` for Python dependency management.

## Testing Guidelines
- **Connectivity**: Run `make test` to verify SSH access to all cluster nodes.
- **Deployment**: After deploying, use `make vllm-test` or `make bifrost-test` to validate API health.
- **Benchmarks**: Run scripts in `benchmarks/` to verify performance regressions after optimization.

## Commit & Pull Request Guidelines
- **Commits**: Follow Conventional Commits (e.g., `feat:`, `fix:`, `docs:`, `perf:`).
- **PRs**: 
  - Clearly describe the change and its impact on cluster performance.
  - Include logs or benchmark report snippets for `perf` or `fix` changes.
  - Ensure that `Makefile` targets are updated if new deployment workflows are added.
