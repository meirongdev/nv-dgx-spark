#!/usr/bin/env python3
"""MTP `num_speculative_tokens` 扫描 —— **单个 arm** 的测量。

在 S1 上跑,打 localhost:8000(与 2026-09-03 基线同协议,避免 Tailscale RTT)。
prompt / warm-up / best-of-2 全部复用 `bench_full.py`,所以 decode 那几行数字
可以直接和 `../bench-full-qwen38fn-2026-09-03/` 对照。

## 为什么不直接用 bench_full.py 比 tok/s

`docs/gb10-tuning-cn.md` §2 实测:这台机器上**单次 decode 测量的噪声地板是
4.6%**,而本实验的预期效应量在 4-14% —— 直接比 tok/s 需要 n≥10 的**交错配对**。
但 `num_speculative_tokens` 是启动参数,**改它必须重启引擎(8-11min),
物理上无法交错**。照搬时钟上限那次的方法在这里行不通。

## 解法:把 tok/s 拆成两个量分别测

    tok/s  =  (tok/step)  ×  (step/s)
              ^^^^^^^^^^     ^^^^^^^^
              计数,无噪声    计时,有噪声

`tok/step = Δaccepted/Δdrafts + 1` 来自 /metrics 的**累计计数器**。它是数出来的
不是掐表掐出来的,所以**没有测量噪声**;而它恰好就是 k 直接作用的那个量 ——
k 变大,每次 draft 提议更多 token,接受的也更多。

`step/s` 仍受计时噪声影响,但 k 对它的作用机理明确且量级小:多一次 draft
forward(单层 MTP)+ verify 批次多一个位置。decode 是带宽受限的
(`gb10-tuning-cn.md` §2:砍频率 -26% 而 decode 无显著变化),所以 verify 多
一个位置近乎免费,主要成本是那次 draft forward。

于是即便 arm 之间无法交错,结论依然可判:**tok/step 的变化是硬的,step/s 的
回退是软的**,两者相除就是净收益。本脚本两个都报,并且交叉核对
(`step/s` 实测 vs 由 tok/s ÷ tok/step 反推),对不上就说明测量本身有问题。

## ⚠️ 三道 fail-closed 的闸

`docs/stack-switch-cn.md` §3 的规则,这里逐条落实:

1. **k 生效与否做行为验证,不读配置。** `Δdraft_tokens / Δdrafts` 必须精确等于
   目标 k。改了 ConfigMap 但忘了重启、或只重启了一个 rank —— 配置读起来都是对的,
   这个比值会当场暴露。
2. **引擎必须独占。** 测量前 running/waiting 必须为 0;测量后引擎完成的请求数
   必须等于本脚本自己发出的数。2026-09-03 有一轮基线被一个后台 codex 会话
   整体拉低 15-25%,现象和"这台机器就是慢"完全一样。
3. **任何一闸不过 → 非 0 退出,且不打印结论行。** 绝不打印一个可能被读成
   "通过"的数字。

用法:
    URL=http://localhost:8000/v1 MODEL=qwen38-flash-next \
    THINK_KEY=enable_thinking THINKING=0 K=3 python3 mtp_arm.py
"""
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_full as bf  # noqa: E402  —— prompt / warm / post 的唯一真相源

K = int(os.environ.get("K", "0"))
if K <= 0:
    raise SystemExit("必须显式传 K=<num_speculative_tokens>,用于行为验证")

BASE = bf.URL.rsplit("/v1", 1)[0]


def metrics():
    """抓一次 /metrics,返回本实验关心的累计计数器。"""
    txt = urllib.request.urlopen(BASE + "/metrics", timeout=15).read().decode()
    out = {"pos": {}, "success": 0.0}
    for line in txt.splitlines():
        if line.startswith("#"):
            continue
        try:
            val = float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            continue
        if line.startswith("vllm:spec_decode_num_drafts_total{"):
            out["drafts"] = val
        elif line.startswith("vllm:spec_decode_num_draft_tokens_total{"):
            out["draft_tokens"] = val
        elif line.startswith("vllm:spec_decode_num_accepted_tokens_total{"):
            out["accepted"] = val
        elif line.startswith("vllm:spec_decode_num_accepted_tokens_per_pos_total{"):
            pos = line.split('position="', 1)[1].split('"', 1)[0]
            out["pos"][int(pos)] = val
        elif line.startswith("vllm:iteration_tokens_total_count{"):
            out["steps"] = val
        elif line.startswith("vllm:request_success_total"):
            out["success"] += val
    return out


def delta(a, b):
    d = {k: b[k] - a[k] for k in ("drafts", "draft_tokens", "accepted", "steps", "success")}
    d["pos"] = {p: b["pos"].get(p, 0.0) - a["pos"].get(p, 0.0) for p in b["pos"]}
    return d


def fail(msg):
    print(f"\n❌ {msg}")
    print("   本 arm **没有结论**,不产出数字。")
    raise SystemExit(3)


# ---- 闸 1:引擎必须空闲 ----------------------------------------------------
# QUIET_S:开测前要求引擎连续这么多秒**一条请求都没完成**。
# 这台上有个断续客户端(每 ~2 分钟一条短请求),只看"此刻 running==0" 会正好
# 卡在两条请求的间隙里开测,然后被闸 2 判废、白跑 4 分钟。等一个静默窗口更省时间。
QUIET_S = float(os.environ.get("QUIET_S", "90"))
QUIET_TIMEOUT = float(os.environ.get("QUIET_TIMEOUT", "1800"))

run0, wait0, _ = bf.engine_counters()
if run0 is None:
    fail("读不到 /metrics —— 无法确认引擎独占。")

deadline = time.time() + QUIET_TIMEOUT
quiet_since = None
last_success = metrics()["success"]
while True:
    time.sleep(10)
    m = metrics()
    busy = m["success"] != last_success
    last_success = m["success"]
    run, wait, _ = bf.engine_counters()
    if busy or (run or 0) > 0 or (wait or 0) > 0:
        quiet_since = None
        print(f"  引擎仍有外部流量,继续等…(已等 "
              f"{QUIET_TIMEOUT - (deadline - time.time()):.0f}s)", flush=True)
    else:
        quiet_since = quiet_since or time.time()
        if time.time() - quiet_since >= QUIET_S:
            break
    if time.time() > deadline:
        fail(f"{QUIET_TIMEOUT:.0f}s 内没等到 {QUIET_S:.0f}s 的静默窗口 —— "
             f"外部流量太密,先停掉客户端。")
print(f"  ✅ 引擎已静默 {QUIET_S:.0f}s,开测")

print(f"=== MTP arm k={K} @ {bf.URL} ===")
print(f"warm-up({len(bf.WARMUP)} 条长生成 + 4 条短)…", flush=True)
bf.warm()

# ---- 测量窗口:warm 之后才开始计数 -----------------------------------------
m0 = metrics()
sent0 = bf.REQ_SENT
t_busy = 0.0
rows = []

print(f"\n--- decode by content (temp 0, warm, best-of-2) ---")
print(f"{'prompt':<10}{'tok':>6}{'sec':>7}{'tok/s':>9}")
for label, prompt, mt in bf.PEAK:
    a = bf.post(prompt, mt)
    b = bf.post(prompt, mt)
    t_busy += a[2] + b[2]
    ct, _, dt = a if a[0] / a[2] > b[0] / b[2] else b
    rows.append((label, ct / dt))
    print(f"{label:<10}{ct:>6}{dt:>7.2f}{ct / dt:>9.1f}", flush=True)

m1 = metrics()
d = delta(m0, m1)

# ---- 闸 2:测量期间不能有外部流量 ------------------------------------------
own = bf.REQ_SENT - sent0
foreign = d["success"] - own
if foreign > 0:
    fail(f"测量期间引擎多完成了 {foreign:.0f} 条本脚本之外的请求"
         f"(引擎 {d['success']:.0f} vs 本脚本 {own})—— 有别的客户端在抢引擎。")

# ---- 闸 3:k 必须真的生效(行为验证,不读配置)------------------------------
if d["drafts"] <= 0:
    fail("测量窗口内 drafts 增量为 0 —— 投机解码没有在跑?")
k_observed = d["draft_tokens"] / d["drafts"]
if abs(k_observed - K) > 0.01:
    fail(f"引擎实际每次 draft 提议 {k_observed:.2f} tok,但本 arm 声称 k={K}。"
         f"\n   ConfigMap 改了没重启?或只有一个 rank 生效?"
         f"\n   —— 配置读起来会是对的,只有这个比值能看出来。")

# ---- 结论 -------------------------------------------------------------------
tok_per_step = d["accepted"] / d["drafts"] + 1.0
steps_per_s = d["steps"] / t_busy
tps = [r[1] for r in rows]
mean_tps = sum(tps) / len(tps)
derived = mean_tps / tok_per_step  # 反推的 step/s,与实测互为交叉核对

print(f"\n--- k={K} 的投机解码剖面(计数,非计时)---")
print(f"  每次 draft 提议      {k_observed:.2f} tok   ← 行为验证通过 (声称 k={K})")
print(f"  总接受率             {d['accepted'] / d['draft_tokens'] * 100:.1f}%")
print(f"  **每步产出**         {tok_per_step:.3f} tok/step   (理论上限 {K + 1}.00)")
print(f"  引擎步数             {d['steps']:.0f} steps / {t_busy:.1f}s busy")
print(f"  step/s               {steps_per_s:.2f} 实测   vs {derived:.2f} 反推"
      f"   (差 {abs(steps_per_s - derived) / steps_per_s * 100:.1f}%)")

print(f"\n  按 draft 位置:")
prev = d["drafts"]
for p in sorted(d["pos"]):
    v = d["pos"][p]
    print(f"    pos{p}: 无条件 {v / d['drafts'] * 100:5.1f}%   条件 {v / prev * 100:5.1f}%")
    prev = v if v > 0 else prev

print(f"\n===== ARM k={K} =====")
print(f"decode mean {mean_tps:.1f} tok/s  |  " + "  ".join(f"{l}={t:.1f}" for l, t in rows))
print(f"tok/step {tok_per_step:.3f}  |  step/s {steps_per_s:.2f}  |  "
      f"独占 OK ({own:.0f} reqs, 0 foreign)")
