#!/usr/bin/env python3
"""Compare throughput: direct vLLM (:30000) vs FastAPI gateway (:8080).

Two interesting angles:
  1) /v1/completions through the gateway (catch-all → server1 only)
     vs direct vLLM on server1 — measures gateway proxy overhead.
  2) /v1/chat/completions through the gateway (round-robin → both servers)
     under concurrency — should scale beyond a single backend.

Runs locally from the Mac (client) over Tailscale, the way real clients hit it.
"""
import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

MODEL = "Qwen3.6-35B-A3B"
GW_HOST = "100.97.87.120:8080"
S1_HOST = "100.97.87.120:30000"   # direct server 1
S2_HOST = "100.67.164.92:30000"   # direct server 2

MEDIUM_PROMPT = "Explain unified memory architecture on the NVIDIA GB10 Grace Blackwell Superchip."
MAX_TOK = 128


def call_completions(base, prompt, max_tokens, timeout=300):
    body = json.dumps({
        "model": MODEL, "prompt": prompt,
        "max_tokens": max_tokens, "temperature": 0.0,
    }).encode()
    req = urllib.request.Request(
        f"http://{base}/v1/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read())
        return {"ok": True, "dt": time.time() - t0,
                "ct": d["usage"]["completion_tokens"],
                "pt": d["usage"]["prompt_tokens"]}
    except Exception as e:
        return {"ok": False, "dt": time.time() - t0, "err": str(e)[:200]}


def call_chat(base, prompt, max_tokens, timeout=300):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0.0,
    }).encode()
    req = urllib.request.Request(
        f"http://{base}/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read())
        return {"ok": True, "dt": time.time() - t0,
                "ct": d["usage"]["completion_tokens"],
                "pt": d["usage"]["prompt_tokens"]}
    except Exception as e:
        return {"ok": False, "dt": time.time() - t0, "err": str(e)[:200]}


def serial(name, fn, runs=3):
    print(f"\n  [{name}] serial ×{runs}")
    ok = []
    for i in range(runs):
        r = fn()
        if not r["ok"]:
            print(f"    run {i+1}: ERR {r['err']}")
            continue
        tps = r["ct"] / r["dt"] if r["dt"] else 0
        print(f"    run {i+1}: {r['dt']*1000:6.0f}ms  out={r['ct']:4d}  {tps:6.2f} tok/s")
        ok.append(r)
    if ok:
        total_s = sum(r["dt"] for r in ok)
        total_t = sum(r["ct"] for r in ok)
        tps = total_t / total_s if total_s else 0
        avg_ms = total_s / len(ok) * 1000
        print(f"    AVG  : {avg_ms:6.0f}ms  {tps:6.2f} tok/s")
        return tps
    return 0.0


def concurrent(name, fn, n):
    print(f"\n  [{name}] concurrent N={n}")
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=n) as ex:
        futs = [ex.submit(fn) for _ in range(n)]
        res = [f.result() for f in as_completed(futs)]
    wall = time.time() - t0
    ok = [r for r in res if r["ok"]]
    total_out = sum(r["ct"] for r in ok)
    agg = total_out / wall if wall else 0
    per_req = [r["ct"] / r["dt"] for r in ok if r["dt"]]
    avg_per_req = sum(per_req) / len(per_req) if per_req else 0
    print(f"    wall={wall:.1f}s total_out={total_out} aggregate={agg:.2f} tok/s "
          f"per-req avg={avg_per_req:.2f} tok/s (n_ok={len(ok)})")
    return agg


def main():
    print("=" * 74)
    print("  LATENCY & THROUGHPUT FROM CLIENT (Mac → Tailscale)")
    print("=" * 74)

    results = {}

    # --- /v1/completions path (gateway catch-all → server 1 only) ---
    print("\n### /v1/completions — gateway vs direct server1 (same backend, isolates proxy overhead)")

    fn_gw_comp = lambda: call_completions(GW_HOST, MEDIUM_PROMPT, MAX_TOK)
    fn_s1_comp = lambda: call_completions(S1_HOST, MEDIUM_PROMPT, MAX_TOK)

    results["direct_s1_serial"] = serial("direct server1 :30000", fn_s1_comp)
    results["gw_comp_serial"]   = serial("gateway :8080 /completions", fn_gw_comp)

    # --- /v1/chat/completions (gateway round-robin both servers) ---
    print("\n### /v1/chat/completions — gateway LB across both servers")

    fn_gw_chat = lambda: call_chat(GW_HOST, MEDIUM_PROMPT, MAX_TOK)
    fn_s1_chat = lambda: call_chat(S1_HOST, MEDIUM_PROMPT, MAX_TOK)

    results["direct_s1_chat"] = serial("direct server1 chat", fn_s1_chat)
    results["gw_chat_serial"] = serial("gateway chat (round-robin)", fn_gw_chat)

    # concurrency: 8 on single server via direct, 8 on gateway (should split 4+4)
    print("\n### Concurrency (medium prompt, max_tokens=128)")
    results["direct_s1_conc8"] = concurrent("direct server1 N=8", fn_s1_chat, 8)
    results["gw_conc8"]        = concurrent("gateway chat N=8 (LB)", fn_gw_chat, 8)
    results["gw_conc16"]       = concurrent("gateway chat N=16 (LB)", fn_gw_chat, 16)

    # summary
    print("\n" + "=" * 74)
    print("  SUMMARY  (tok/s)")
    print("=" * 74)
    rows = [
        ("serial /v1/completions, direct server1",  results.get("direct_s1_serial", 0)),
        ("serial /v1/completions, via gateway  ",   results.get("gw_comp_serial", 0)),
        ("serial /v1/chat, direct server1      ",   results.get("direct_s1_chat", 0)),
        ("serial /v1/chat, via gateway (RR)    ",   results.get("gw_chat_serial", 0)),
        ("concurrent N=8,  direct server1 (1 node)", results.get("direct_s1_conc8", 0)),
        ("concurrent N=8,  via gateway    (2 nodes)", results.get("gw_conc8", 0)),
        ("concurrent N=16, via gateway    (2 nodes)", results.get("gw_conc16", 0)),
    ]
    for name, v in rows:
        print(f"  {name:<44}{v:>10.2f}")
    print()


if __name__ == "__main__":
    main()
