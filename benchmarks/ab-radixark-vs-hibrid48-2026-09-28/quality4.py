#!/usr/bin/env python3
"""
quality4.py — 四件套质量评测 (HumanEval / GSM8K / IFEval / MMLU-Pro)
对 OpenAI 兼容端点 (/v1/chat/completions)。

协议（对齐 bilikaz repo 的质量表）:
  thinking ON (enable_thinking=true), temperature 0.6, top_p 0.95, top_k 20,
  max_tokens 32768
子集（确定性，保证两个 checkpoint 同题对照）:
  HumanEval 164 全量; GSM8K / MMLU-Pro / IFEval 各取官方 test split 前 200 题
输出:
  /tmp/bench_data/detail_<tag>.jsonl   每题原始回答，可离线重打分
  /tmp/bench_data/results_<tag>.json   最终分数
"""
import json
import os
import re
import sys
import time
import gzip
import subprocess
import urllib.request
from pathlib import Path

sys.path.insert(0, "/tmp/bench_data")

ENDPOINT = os.environ.get("ENDPOINT", "http://100.67.164.92:18300/v1/chat/completions")
MODEL = os.environ.get("MODEL", "qwen3.8-flash-next")
TAG = sys.argv[1] if len(sys.argv) > 1 else "run"
DATA = Path("/tmp/bench_data")
DETAIL = DATA / f"detail_{TAG}.jsonl"
RESULT = DATA / f"results_{TAG}.json"

TEMP, TOP_P, TOP_K, MAX_TOKENS = 0.6, 0.95, 20, 32768
THINKING = True


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def chat(messages, tag="", max_tokens=MAX_TOKENS):
    payload = json.dumps({
        "model": MODEL,
        "messages": messages,
        "temperature": TEMP,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "max_tokens": max_tokens,
        "enable_thinking": THINKING,
    }).encode()
    for attempt in range(1, 5):
        t0 = time.time()
        try:
            req = urllib.request.Request(
                ENDPOINT, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=1200) as r:
                data = json.loads(r.read())
            msg = data["choices"][0]["message"]
            content = (msg.get("content") or "").strip()
            return content, time.time() - t0, data.get("usage", {})
        except Exception as e:
            if attempt == 4:
                log(f"!! {tag} failed after 4 tries: {e}")
                return None, time.time() - t0, {}
            log(f"  {tag} retry {attempt}: {e}")
            time.sleep(5 * attempt)


def detail(suite, idx, prompt, content, extra=None):
    rec = {"suite": suite, "idx": idx, "prompt": prompt, "content": content}
    if extra:
        rec.update(extra)
    with open(DETAIL, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ---------------- resume support: skip (suite, idx) already in detail file ----------------
def load_done():
    done = {}
    if DETAIL.exists():
        with open(DETAIL) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    done[(rec["suite"], rec["idx"])] = rec
                except (json.JSONDecodeError, KeyError):
                    continue
    return done

DONE = load_done()


# ---------------- HumanEval ----------------
def strip_fences(s):
    s = s.strip()
    if s.startswith("```"):
        s = re.sub(r"^```[a-zA-Z0-9]*\s*\n?", "", s)
        s = re.sub(r"\n?```\s*$", "", s)
    return s


def run_humaneval():
    problems = [json.loads(l) for l in gzip.open(DATA / "HumanEval.jsonl.gz", "rt")]
    n = len(problems)
    passed = 0
    for i, p in enumerate(problems):
        rec = DONE.get(("humaneval", i))
        if rec is not None:
            passed += 1 if rec.get("ok") else 0
            if (i + 1) % 20 == 0:
                log(f"  humaneval {i+1}/{n} pass_rate={passed/(i+1):.3f} (incl. resumed)")
            continue
        prompt, test = p["prompt"], p["test"]
        content, dt, _ = chat([
            {"role": "system",
             "content": "You are an expert Python programmer. Complete the function below so that it works correctly. Output only the code, without any explanation."},
            {"role": "user", "content": prompt},
        ], tag=f"humaneval[{i}]")
        ok = False
        if content is not None:
            code = strip_fences(content)
            full = code if code.lstrip().startswith("def ") else prompt + code
            full_code = full + "\n\n" + test
            try:
                proc = subprocess.run([sys.executable, "-c", full_code],
                                      capture_output=True, text=True, timeout=20)
                ok = proc.returncode == 0
            except subprocess.TimeoutExpired:
                ok = False
            except Exception:
                ok = False
        passed += ok
        detail("humaneval", i, prompt, content, {"ok": ok, "dt": round(dt, 1)})
        if (i + 1) % 20 == 0:
            log(f"  humaneval {i+1}/{n} pass_rate={passed/(i+1):.3f}")
    return {"n": n, "passed": passed, "pass_at_1": round(passed / n, 4)}


# ---------------- GSM8K ----------------
def norm_num(s):
    if s is None:
        return None
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


def run_gsm8k(n=200):
    import pyarrow.parquet as pq
    rows = pq.read_table(str(DATA / "gsm8k_test.parquet")).to_pylist()[:n]
    correct = 0
    for i, row in enumerate(rows):
        rec = DONE.get(("gsm8k", i))
        if rec is not None:
            correct += 1 if rec.get("ok") else 0
            if (i + 1) % 20 == 0:
                log(f"  gsm8k {i+1}/{n} acc={correct/(i+1):.3f} (incl. resumed)")
            continue
        q = row["question"]
        gold = parse_gold(row["answer"])
        content, dt, _ = chat([
            {"role": "system", "content": "You are a careful math tutor."},
            {"role": "user",
             "content": q + "\nSolve it step by step, and put the final numeric answer on the last line after '####'."},
        ], tag=f"gsm8k[{i}]")
        pred = None
        if content:
            m = re.search(r"####\s*(-?[\d,]+(?:\.\d+)?)", content)
            pred = norm_num(m.group(1)) if m else norm_num(last_number(content))
        ok = pred is not None and gold is not None and pred == gold
        correct += ok
        detail("gsm8k", i, q, content, {"gold": gold, "pred": pred, "ok": ok, "dt": round(dt, 1)})
        if (i + 1) % 20 == 0:
            log(f"  gsm8k {i+1}/{n} acc={correct/(i+1):.3f}")
    return {"n": len(rows), "correct": correct, "accuracy": round(correct / len(rows), 4)}


# ---------------- MMLU-Pro ----------------
def run_mmlupro(n=200):
    import pyarrow.parquet as pq
    rows = pq.read_table(str(DATA / "mmlu_pro_test.parquet")).to_pylist()[:n]
    correct = 0
    for i, row in enumerate(rows):
        rec = DONE.get(("mmlupro", i))
        if rec is not None:
            correct += 1 if rec.get("ok") else 0
            if (i + 1) % 20 == 0:
                log(f"  mmlupro {i+1}/{n} acc={correct/(i+1):.3f} (incl. resumed)")
            continue
        opts = "\n".join(f"{chr(65+j)}. {o}" for j, o in enumerate(row["options"]))
        prompt = (f"{row['question']}\n\n{opts}\n\n"
                  "Answer with only the letter of the correct option.")
        content, dt, _ = chat([
            {"role": "system", "content": "You are an expert exam taker."},
            {"role": "user", "content": prompt},
        ], tag=f"mmlupro[{i}]")
        pred = None
        if content:
            letters = re.findall(r"\b([A-J])\b", content)
            if letters:
                pred = letters[-1]
            else:
                for ch in reversed(content):
                    if ch in "ABCDEFGHIJ":
                        pred = ch
                        break
        gold = str(row["answer"]).strip().upper()
        ok = pred is not None and pred == gold
        correct += ok
        detail("mmlupro", i, row["question"], content,
               {"gold": gold, "pred": pred, "ok": ok, "dt": round(dt, 1)})
        if (i + 1) % 20 == 0:
            log(f"  mmlupro {i+1}/{n} acc={correct/(i+1):.3f}")
    return {"n": len(rows), "correct": correct, "accuracy": round(correct / len(rows), 4)}


# ---------------- IFEval ----------------
def run_ifeval(n=200):
    from instruction_following_eval.evaluation_lib import (
        InputExample, test_instruction_following_strict, OutputExample)
    inputs = []
    with open(DATA / "ifeval_input_data.jsonl") as f:
        for l in f:
            e = json.loads(l)
            inputs.append(InputExample(
                key=e["key"],
                instruction_id_list=e["instruction_id_list"],
                prompt=e["prompt"],
                kwargs=e["kwargs"]))
            if len(inputs) >= n:
                break
    outputs = []
    failed = 0
    for i, inp in enumerate(inputs):
        rec = DONE.get(("ifeval", i))
        if rec is not None:
            follow = rec.get("follow")
            if follow is None:
                failed += 1
                outputs.append(OutputExample(
                    instruction_id_list=inp.instruction_id_list, prompt=inp.prompt,
                    response="", follow_all_instructions=False,
                    follow_instruction_list=[False] * len(inp.instruction_id_list)))
            else:
                outputs.append(OutputExample(
                    instruction_id_list=inp.instruction_id_list, prompt=inp.prompt,
                    response="", follow_all_instructions=all(follow),
                    follow_instruction_list=follow))
            if (i + 1) % 20 == 0:
                log(f"  ifeval {i+1}/{n} (incl. resumed)")
            continue
        content, dt, _ = chat([{"role": "user", "content": inp.prompt}],
                              tag=f"ifeval[{i}]")
        if content is None:
            failed += 1
            outputs.append(OutputExample(
                instruction_id_list=inp.instruction_id_list, prompt=inp.prompt,
                response="", follow_all_instructions=False,
                follow_instruction_list=[False] * len(inp.instruction_id_list)))
            detail("ifeval", i, inp.prompt, None, {"dt": round(dt, 1)})
            continue
        out = test_instruction_following_strict(inp, {inp.prompt: content})
        outputs.append(out)
        detail("ifeval", i, inp.prompt, content,
               {"follow": out.follow_instruction_list, "dt": round(dt, 1)})
        if (i + 1) % 20 == 0:
            log(f"  ifeval {i+1}/{n}")
    prompt_total = len(outputs)
    prompt_correct = sum(1 for o in outputs if o.follow_all_instructions)
    inst_total = sum(len(o.follow_instruction_list) for o in outputs)
    inst_correct = sum(sum(o.follow_instruction_list) for o in outputs)
    return {
        "n": n, "api_failed": failed,
        "prompt_level_strict": round(prompt_correct / prompt_total, 4),
        "instruction_level_strict": round(inst_correct / inst_total, 4),
    }


def main():
    log(f"=== quality4 start tag={TAG} model={MODEL} endpoint={ENDPOINT} "
        f"thinking={THINKING} temp={TEMP} top_p={TOP_P} top_k={TOP_K} max_tokens={MAX_TOKENS} ===")
    if DONE:
        log(f"resume: {len(DONE)} questions already in {DETAIL.name}, skipping them")
    c, dt, usage = chat([{"role": "user", "content": "1+1等于几？只回答数字。"}],
                        tag="sanity", max_tokens=512)
    log(f"sanity: content={c!r} dt={dt:.1f}s usage={usage}")
    results = {
        "tag": TAG, "model": MODEL, "endpoint": ENDPOINT,
        "protocol": {"thinking": THINKING, "temperature": TEMP, "top_p": TOP_P,
                     "top_k": TOP_K, "max_tokens": MAX_TOKENS},
        "started": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    results["humaneval"] = run_humaneval()
    results["gsm8k"] = run_gsm8k(200)
    results["mmlu_pro"] = run_mmlupro(200)
    results["ifeval"] = run_ifeval(200)
    results["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    RESULT.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    log("=== done ===")
    log(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
