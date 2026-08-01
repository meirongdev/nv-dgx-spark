#!/usr/bin/env python3
"""Check whether model patches have arithmetically-consistent hunk headers.

The smoke run lost 7/14 evaluable instances to `Patch Apply Failed`. The
archived analysis attributes that to wrong hunk-header line counts. This
verifies that claim mechanically across all 20 predictions.
"""
import json
import re
import sys

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")

FAILED = {
    "astropy__astropy-14182",
    "mwaskom__seaborn-3010",
    "mwaskom__seaborn-3407",
    "pallets__flask-4045",
    "pallets__flask-4992",
    "psf__requests-2674",
    "pytest-dev__pytest-5227",
}


def check(patch):
    """Return (n_hunks, n_bad) — bad = header count != actual line count."""
    lines = patch.split("\n")
    n_hunks = n_bad = 0
    i = 0
    while i < len(lines):
        m = HUNK.match(lines[i])
        if not m:
            i += 1
            continue
        n_hunks += 1
        want_old = int(m.group(2)) if m.group(2) is not None else 1
        want_new = int(m.group(4)) if m.group(4) is not None else 1
        got_old = got_new = 0
        i += 1
        while i < len(lines):
            ln = lines[i]
            if ln.startswith("@@") or ln.startswith("diff --git") or ln.startswith("--- "):
                break
            if ln.startswith("-"):
                got_old += 1
            elif ln.startswith("+"):
                got_new += 1
            elif ln.startswith(" ") or ln == "":
                got_old += 1
                got_new += 1
            else:
                break
            i += 1
        if (got_old, got_new) != (want_old, want_new):
            n_bad += 1
    return n_hunks, n_bad


rows = []
with open(sys.argv[1]) as f:
    for line in f:
        d = json.loads(line)
        iid = d["instance_id"]
        p = d.get("model_patch") or ""
        h, b = check(p)
        rows.append((iid, h, b, iid in FAILED))

print(f"{'instance':<38} {'hunks':>5} {'bad':>4}  {'applyfail':>9}")
print("-" * 62)
bad_and_failed = bad_only = failed_only = clean_ok = 0
for iid, h, b, failed in sorted(rows, key=lambda r: (not r[3], r[0])):
    print(f"{iid:<38} {h:>5} {b:>4}  {'YES' if failed else '-':>9}")
    if b and failed:
        bad_and_failed += 1
    elif b:
        bad_only += 1
    elif failed:
        failed_only += 1
    else:
        clean_ok += 1

print()
print(f"bad headers AND apply-failed : {bad_and_failed}")
print(f"bad headers, applied fine    : {bad_only}")
print(f"clean headers, apply-failed  : {failed_only}")
print(f"clean headers, no fail       : {clean_ok}")
