#!/usr/bin/env python3
"""Prefill-at-depth, repeated, with prefix-cache isolation between repeats.

Same protocol as tonyd2wild bench_full.py bench_prefill (TTFT method, 1 output
token, 8K/32K/100K in one ascending pass — so the intra-run prefix sharing they
had is preserved), but each repeat is prefixed with a unique tag so repeat N+1
does NOT hit the prefix cache left by repeat N.
"""
import json, os, sys, time, urllib.request

URL = os.environ.get("URL", "http://localhost:8000/v1")
MODEL = os.environ.get("MODEL", "deepseek-v4-flash")
REPEATS = int(os.environ.get("REPEATS", "3"))

FILLER = ("Distributed inference on GB10 schedules prefill and decode in the same step; "
          "long prompts dominate the step budget and delay in-flight decodes. ")


def post(prompt, max_tokens, timeout=900):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "temperature": 0.0,
            "chat_template_kwargs": {"thinking": False}}
    req = urllib.request.Request(URL + "/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=timeout))
    dt = time.time() - t0
    u = r["usage"]
    return u["completion_tokens"], u.get("prompt_tokens", 0), dt


WARMUP = [
    ("Implement a binary search tree in Python with insert, search, delete and in-order "
     "traversal. Include docstrings and two usage examples.", 700),
    ("Write a 300-word explanation of how speculative decoding works.", 600),
    ("Compute the running sum of the first 40 prime numbers, showing each step.", 600),
    ('Output a JSON array of 40 objects, each {"id":N,"name":"user_N"}. JSON only.', 600),
    ("Explain tensor parallelism versus pipeline parallelism in detail.", 600),
]

print("warming up (5 long generations — required, warm state decays when idle)...", flush=True)
for p, mt in WARMUP:
    try:
        ct, _, dt = post(p, mt)
        print("  warm %4d tok %5.1fs %5.1f tok/s" % (ct, dt, ct/dt), flush=True)
    except Exception as e:
        print("  warm FAILED", str(e)[:60], flush=True)

print("\n%8s %8s %12s %8s %10s" % ("repeat", "target", "prompt tok", "sec", "tok/s"), flush=True)
res = {}
for rep in range(1, REPEATS + 1):
    # unique prefix -> repeat does not reuse the previous repeat's cached blocks
    tag = "Run identifier %s. Ignore this line. " % ("Z" * (17 + rep * 3))
    for target in (8000, 32000, 100000):
        n = max(1, int(target / 22))
        prompt = tag + (FILLER * n)[:target * 4] + "\nSummarize in one sentence."
        try:
            ct, pt, dt = post(prompt, 1)
            res.setdefault(target, []).append(pt / dt)
            print("%8d %8d %12d %8.1f %10.0f" % (rep, target, pt, dt, pt / dt), flush=True)
        except Exception as e:
            print("%8d %8d   FAILED %s" % (rep, target, str(e)[:50]), flush=True)

print("\n===== prefill summary (tok/s) =====")
for target in sorted(res):
    v = res[target]
    print("%6dK  runs=%s  median=%.0f  best=%.0f" %
          (target // 1000, " ".join("%.0f" % x for x in v), sorted(v)[len(v) // 2], max(v)))
