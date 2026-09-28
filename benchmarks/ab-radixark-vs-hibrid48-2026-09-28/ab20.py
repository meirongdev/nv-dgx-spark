#!/usr/bin/env python3
"""A/B: first-20 GSM8K with thinking OFF vs already-recorded thinking ON (detail_radixark.jsonl)."""
import json, re, time, urllib.request
import pyarrow.parquet as pq

ENDPOINT = "http://100.67.164.92:18300/v1/chat/completions"
MODEL = "qwen3.8-flash-next"
N = 20

rows = pq.read_table("/tmp/bench_data/gsm8k_test.parquet").to_pylist()[:N]

def norm_num(s):
    if s is None: return None
    s = s.replace(",", "")
    try:
        f = float(s)
        return str(int(f)) if f == int(f) else str(f)
    except ValueError:
        return s

def last_number(s):
    nums = re.findall(r"-?\d[\d,]*(?:\.\d+)?", s)
    return nums[-1] if nums else None

def parse_gold(ans):
    tail = ans.split("####")[-1] if "####" in ans else ans
    return norm_num(last_number(tail))

def chat_off(question):
    payload = {"model": MODEL,
               "messages": [{"role": "system", "content": "You are a careful math tutor."},
                            {"role": "user", "content": question + "\nSolve it step by step, and put the final numeric answer on the last line after '####'."}],
               "temperature": 0.6, "top_p": 0.95, "top_k": 20,
               "max_tokens": 32768, "enable_thinking": False}
    t0 = time.time()
    req = urllib.request.Request(ENDPOINT, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1200) as r:
        d = json.loads(r.read())
    m = d["choices"][0]["message"]
    u = d.get("usage", {})
    cd = u.get("completion_tokens_details") or {}
    return (m.get("content") or "").strip(), time.time() - t0, cd.get("reasoning_tokens", 0)

# load thinking-ON results for same 20 questions
on = {}
with open("/tmp/bench_data/detail_radixark.jsonl") as f:
    for line in f:
        rec = json.loads(line)
        if rec["suite"] == "gsm8k" and rec["idx"] < N:
            on[rec["idx"]] = rec

correct_on = correct_off = 0
dts_on, dts_off = [], []
print(f"{'#':>3} {'on_ok':>5} {'off_ok':>6} {'on_s':>6} {'off_s':>6} {'off_reasoning_tok':>7}  gold")
for i, row in enumerate(rows):
    q = row["question"]
    gold = parse_gold(row["answer"])
    rec_on = on.get(i)
    ok_on = bool(rec_on.get("ok")) if rec_on else None
    if ok_on is None:
        print(f"{i:>3}  MISSING thinking-on record for idx {i}")
    # thinking off
    try:
        content_off, dt_off, rtok = chat_off(q)
    except Exception as e:
        print(f"{i:>3}  thinking-off error: {e}")
        content_off, dt_off, rtok = "", 0.0, 0
    pred_off = None
    if content_off:
        m = re.search(r"####\s*(-?[\d,]+(?:\.\d+)?)", content_off)
        pred_off = norm_num(m.group(1)) if m else norm_num(last_number(content_off))
    ok_off = pred_off is not None and gold is not None and pred_off == gold
    correct_on += 1 if ok_on else 0
    correct_off += 1 if ok_off else 0
    dts_on.append(rec_on.get("dt", 0) if rec_on else 0)
    dts_off.append(dt_off)
    print(f"{i:>3} {str(bool(ok_on)):>5} {str(bool(ok_off)):>6} {rec_on.get('dt',0) if rec_on else 0:>6} {dt_off:>6.1f} {rtok:>7}  {gold}")

print()
print(f"thinking ON : acc={correct_on}/{N} ({correct_on/N:.1%}), mean {sum(dts_on)/len(dts_on):.1f}s/q")
print(f"thinking OFF: acc={correct_off}/{N} ({correct_off/N:.1%}), mean {sum(dts_off)/len(dts_off):.1f}s/q")
with open("/tmp/bench_data/detail_ab_gsm8k20_off.jsonl", "w") as f:
    pass  # content kept in stdout only; details logged above
