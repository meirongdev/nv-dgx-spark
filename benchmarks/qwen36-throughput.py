#!/usr/bin/env python3
"""Benchmark Qwen3.6-35B-A3B vLLM on both DGX Spark servers.

Ships a small Python client to each host via ssh-stdin so curl/JSON escaping
is not a problem, then aggregates the per-host results here.

Metrics reported:
- Serial decode throughput (tok/s) for short/medium/long completions.
- Aggregate throughput under concurrent load (N=4, N=8).
"""
import json
import subprocess
import sys
import textwrap

HOSTS = ["100.97.87.120", "100.67.164.92"]
PORT = 30000
MODEL = "Qwen3.6-35B-A3B"
SSH_KEY = "~/.ssh/vgio"


REMOTE_SCRIPT = textwrap.dedent('''
    import json, sys, time, urllib.request
    from concurrent.futures import ThreadPoolExecutor, as_completed

    PORT = %(port)d
    MODEL = %(model)r
    URL = f"http://localhost:{PORT}/v1/completions"

    def one(prompt, max_tokens):
        body = json.dumps({
            "model": MODEL, "prompt": prompt,
            "max_tokens": max_tokens, "temperature": 0.0,
        }).encode()
        req = urllib.request.Request(URL, data=body,
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                d = json.loads(r.read())
            dt = time.time() - t0
            u = d["usage"]
            return {"ok": True, "dt": dt,
                    "pt": u["prompt_tokens"], "ct": u["completion_tokens"]}
        except Exception as e:
            return {"ok": False, "err": str(e)[:200], "dt": time.time() - t0}

    PROMPTS = {
        "short":  ("Hello.", 32),
        "medium": ("Explain unified memory architecture on the NVIDIA GB10 Grace Blackwell Superchip.", 128),
        "long":   ("Write a technical overview of MoE scaling, FP8 quantization, and KV-cache paging in modern inference servers.", 512),
    }

    out = {"serial": {}, "concurrent": {}}

    for name, (p, mt) in PROMPTS.items():
        runs = []
        for i in range(3):
            runs.append(one(p, mt))
        out["serial"][name] = runs

    for n in (4, 8):
        p, mt = PROMPTS["medium"]
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=n) as ex:
            futs = [ex.submit(one, p, mt) for _ in range(n)]
            res = [f.result() for f in as_completed(futs)]
        out["concurrent"][f"N{n}"] = {"wall": time.time() - t0, "runs": res}

    print("RESULT_JSON_START")
    print(json.dumps(out))
    print("RESULT_JSON_END")
''') % {"port": PORT, "model": MODEL}


def run_remote(host):
    cmd = [
        "ssh", "-i", SSH_KEY.replace("~", __import__("os").path.expanduser("~")),
        "-o", "StrictHostKeyChecking=no",
        f"admin@{host}", "python3", "-",
    ]
    r = subprocess.run(cmd, input=REMOTE_SCRIPT, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        print(f"ssh error on {host}:\n{r.stderr}", file=sys.stderr)
        return None
    try:
        raw = r.stdout.split("RESULT_JSON_START", 1)[1].split("RESULT_JSON_END", 1)[0].strip()
        return json.loads(raw)
    except Exception as e:
        print(f"parse error on {host}: {e}\nstdout:\n{r.stdout[:500]}", file=sys.stderr)
        return None


def summarize_serial(runs):
    ok = [r for r in runs if r["ok"]]
    if not ok:
        return None
    total_tok = sum(r["ct"] for r in ok)
    total_s = sum(r["dt"] for r in ok)
    tps = total_tok / total_s if total_s else 0
    avg_ms = total_s / len(ok) * 1000
    avg_tok = total_tok / len(ok)
    return {"n": len(ok), "avg_ms": avg_ms, "avg_tok": avg_tok, "tps": tps}


def summarize_concurrent(block):
    ok = [r for r in block["runs"] if r["ok"]]
    wall = block["wall"]
    total_out = sum(r["ct"] for r in ok)
    agg = total_out / wall if wall else 0
    per_req = [r["ct"] / r["dt"] for r in ok if r["dt"]]
    avg_per_req = sum(per_req) / len(per_req) if per_req else 0
    return {"n": len(ok), "wall": wall, "total_out": total_out,
            "agg_tps": agg, "avg_per_req": avg_per_req}


def main():
    host_summaries = {}
    for host in HOSTS:
        print("=" * 74)
        print(f"  HOST {host}:{PORT}   model={MODEL}")
        print("=" * 74)
        data = run_remote(host)
        if data is None:
            continue

        # serial
        print("  serial (3 runs each):")
        serial_sum = {}
        for name, runs in data["serial"].items():
            s = summarize_serial(runs)
            serial_sum[name] = s
            if s is None:
                print(f"    {name:<7}: ALL FAILED  ({runs[0].get('err','')})")
                continue
            print(f"    {name:<7}: avg {s['avg_ms']:6.0f} ms   "
                  f"avg out {s['avg_tok']:5.1f} tok   "
                  f"decode {s['tps']:6.2f} tok/s   (n={s['n']})")

        # concurrent
        print("  concurrent (medium prompt, max_tokens=128):")
        conc_sum = {}
        for key, block in data["concurrent"].items():
            s = summarize_concurrent(block)
            conc_sum[key] = s
            print(f"    {key:<7}: wall {s['wall']:5.1f}s   "
                  f"total_out {s['total_out']:5d}   "
                  f"aggregate {s['agg_tps']:6.2f} tok/s   "
                  f"per-req avg {s['avg_per_req']:6.2f} tok/s   (n_ok={s['n']})")
        host_summaries[host] = {"serial": serial_sum, "conc": conc_sum}

    print()
    print("=" * 74)
    print("  SUMMARY  (tok/s)")
    print("=" * 74)
    cols = ["short", "medium", "long"]
    header = f"  {'host':<16}" + "".join(f"{c:>12}" for c in cols) + f"{'conc-4 agg':>14}{'conc-8 agg':>14}"
    print(header)
    for host, s in host_summaries.items():
        row = f"  {host:<16}"
        for c in cols:
            v = s["serial"].get(c)
            row += f"{(v['tps'] if v else 0):>12.2f}"
        row += f"{s['conc'].get('N4', {}).get('agg_tps', 0):>14.2f}"
        row += f"{s['conc'].get('N8', {}).get('agg_tps', 0):>14.2f}"
        print(row)
    print()


if __name__ == "__main__":
    main()
