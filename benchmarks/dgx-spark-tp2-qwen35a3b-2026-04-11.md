# DGX Spark TP=2 Benchmark Report

## Environment

| Field | Value |
|------|-------|
| Date | 2026-04-11 |
| Coordinator | 100.97.87.120 |
| Worker | 100.67.164.92 |
| Model | Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled |
| TP Size | 2 |
| Port | 8000 |

## Pre-run snapshots

```text
host=spark-ccf3
               total        used        free      shared  buff/cache   available
Mem:           119Gi        98Gi       4.5Gi       838Mi        17Gi        21Gi
0 %, 0 %, [N/A], [N/A], 52
---
host=spark-2435
               total        used        free      shared  buff/cache   available
Mem:           119Gi        90Gi       886Mi       707Mi        29Gi        28Gi
0 %, 0 %, [N/A], [N/A], 47
```

## Benchmark results

| Case | HTTP | Completion Tokens | Latency (ms) | Tokens/s | Preview |
|------|------|-------------------|--------------|----------|---------|
| short-greeting | 200 | 32 | 1534 | 20.86 |   <think> Thinking Process:  1.  **Analyze the Request:**     *   Task: Say hell |
| memory-summary | 200 | 96 | 3088 | 31.09 |   <think> Thinking Process:  1.  **Analyze the Request:**     *   Topic: Unified |
| code-snippet | 500 | 0 | 300791 | 0.0 | API error: EngineCore encountered an issue. See stack trace (above) for the root |

## Post-run snapshots

```text
host=spark-ccf3
               total        used        free      shared  buff/cache   available
Mem:           119Gi        97Gi       5.5Gi       838Mi        17Gi        21Gi
96 %, 0 %, [N/A], [N/A], 59
---
host=spark-2435
               total        used        free      shared  buff/cache   available
Mem:           119Gi        90Gi       901Mi       707Mi        29Gi        28Gi
0 %, 0 %, [N/A], [N/A], 50
```
