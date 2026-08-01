#!/usr/bin/env python3
"""Summarize a SWE-bench run report + the predictions that fed it."""

import json
import sys
from collections import Counter
from pathlib import Path

report_path = sys.argv[1]
preds_path = sys.argv[2] if len(sys.argv) > 2 else None

d = json.load(open(report_path))
print(f"== {report_path} ==")
for k in (
    "total_instances",
    "submitted_instances",
    "completed_instances",
    "resolved_instances",
    "unresolved_instances",
    "empty_patch_instances",
    "error_instances",
):
    print(f"{k:24s} {d.get(k)}")

total = d.get("total_instances") or 0
resolved = d.get("resolved_instances") or 0
if total:
    print(f"{'resolve_rate':24s} {100 * resolved / total:.1f}%")

for key in ("resolved_ids", "unresolved_ids", "error_ids", "empty_patch_ids"):
    ids = d.get(key) or []
    if ids:
        print(f"\n{key} ({len(ids)}):")
        for i in sorted(ids):
            print(f"  {i}")

# per-repo breakdown over the instances actually in this run
run_ids = set()
for key in ("resolved_ids", "unresolved_ids", "error_ids", "empty_patch_ids"):
    run_ids |= set(d.get(key) or [])
if run_ids:
    res = set(d.get("resolved_ids") or [])
    per_repo = Counter()
    per_repo_res = Counter()
    for i in run_ids:
        repo = i.rsplit("-", 1)[0]
        per_repo[repo] += 1
        if i in res:
            per_repo_res[repo] += 1
    print("\nper-repo (resolved/total):")
    for repo in sorted(per_repo):
        print(f"  {repo:35s} {per_repo_res[repo]}/{per_repo[repo]}")

if preds_path and Path(preds_path).exists():
    rows = [json.loads(l) for l in open(preds_path)]
    nonempty = [r for r in rows if (r.get("model_patch") or "").strip()]
    print(f"\npredictions: {len(rows)} rows, {len(nonempty)} non-empty patches")
