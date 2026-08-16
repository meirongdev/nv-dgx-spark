#!/usr/bin/env python3
"""v4flash 探针回归测试(`make probe-test`)。

脚本本体只有一份 —— 直接从 k8s/v4flash/configmap-launch.yaml 里抽出来跑,
不在这里复制粘贴,避免改了 ConfigMap 而测试还在测旧逻辑。

覆盖的是**两代探针误杀健康 leader 的真实场景**(见 ConfigMap 里的注释):
  2026-08-13  探针请求排在满载队列里超时
  2026-08-16  `steps stuck at 76166` / `steps stuck at 0`
只用标准库,不需要 uv/venv:`python3 scripts/test-liveness-probe.py`。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIGMAP = os.path.join(REPO, "k8s", "v4flash", "configmap-launch.yaml")
PORT, DEAD_PORT = 18321, 18322
STALL_S, MISS = 3, 3          # 测试用的小阈值;生产默认见 ConfigMap(600s / 5)
WORKER_MISS = 2               # 与生产默认一致


def extract(name):
    """从 ConfigMap 的块标量里抽一个 .py 出来(缩进 4 空格,到下一个顶层键为止)。"""
    out, grabbing = [], False
    for line in open(CONFIGMAP, encoding="utf-8").read().splitlines():
        if re.match(rf"^  {re.escape(name)}: \|\s*$", line):
            grabbing = True
            continue
        if grabbing:
            if line.strip() and not line.startswith("    "):
                break
            out.append(line[4:])
    if not out:
        sys.exit(f"没能从 {CONFIGMAP} 抽出 {name}")
    return "\n".join(out) + "\n"


BODY = {"text": ""}


def metrics(steps=None, running=0.0, waiting=0.0, start=1.78686916435e09):
    """复刻真实 /metrics 里相关的几行(含 num_requests_waiting_by_reason 这个
    容易被前缀匹配误伤的邻居)。"""
    lines = []
    if steps is not None:
        lines.append(f'vllm:iteration_tokens_total_count{{model_name="v4"}} {steps}')
    lines += [
        f'vllm:num_requests_running{{model_name="v4"}} {running}',
        f'vllm:num_requests_waiting{{model_name="v4"}} {waiting}',
        'vllm:num_requests_waiting_by_reason{model_name="v4",reason="x"} 0.0',
        f"process_start_time_seconds {start}",
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = BODY["text"].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


TMP = tempfile.mkdtemp(prefix="v4flash-probe-")
LEADER_PY = os.path.join(TMP, "liveness.py")
WORKER_PY = os.path.join(TMP, "worker_liveness.py")
open(LEADER_PY, "w", encoding="utf-8").write(extract("liveness.py"))
open(WORKER_PY, "w", encoding="utf-8").write(extract("worker_liveness.py"))

srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{PORT}/metrics"
DEAD = f"http://127.0.0.1:{DEAD_PORT}/metrics"     # 没人监听 = 抓不到

RESULTS = []


def leader(state):
    env = dict(os.environ, V4FLASH_METRICS=URL, V4FLASH_STATE=state,
               V4FLASH_STALL_S=str(STALL_S), V4FLASH_MISS_LIMIT=str(MISS))
    return env


def run(script, env):
    p = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True)
    return p.returncode, p.stderr.strip()


def probe(state, url=URL):
    env = leader(state)
    env["V4FLASH_METRICS"] = url
    return run(LEADER_PY, env)


def wprobe(state, url=URL):
    env = dict(os.environ, V4FLASH_LEADER_METRICS=url, V4FLASH_WORKER_STATE=state,
               V4FLASH_WORKER_MISS=str(WORKER_MISS))
    return run(WORKER_PY, env)


def check(name, got, want, msg=""):
    ok = got == want
    RESULTS.append((ok, name))
    print(f"  {'PASS' if ok else 'FAIL':4}  {name}" + (f"  [{msg}]" if msg else ""))


def state(tag):
    return os.path.join(TMP, f"state-{tag}.json")


print("\n=== 稳态:首次探测 / 引擎在推进 ===")
BODY["text"] = metrics(steps=100, running=1)
s = state("ok")
check("首次探测只记基线", probe(s)[0], 0)
BODY["text"] = metrics(steps=101, running=1)
check("steps 推进 → 放行", probe(s)[0], 0)

print("\n=== 回归 2026-08-16 17:08:冷引擎 steps=0,首个请求在飞 ===")
BODY["text"] = metrics(steps=0, running=1)
s = state("cold")
for i in (1, 2, 3):
    check(f"第 {i} 次探测放行(旧版第 2 次就判死)", probe(s)[0], 0)

print("\n=== 回归 2026-08-16 16:32:空闲很久之后来第一个请求 ===")
s = state("idle")
BODY["text"] = metrics(steps=76166, running=0)          # 空闲,steps 长时间不动
for _ in range(3):
    probe(s)
    time.sleep(STALL_S / 2)                             # 累计时长已超过 STALL_S
BODY["text"] = metrics(steps=76166, running=1)          # 请求到达,首个 iteration 未完成
check("空闲期不攒停滞账 → 放行(旧版当场判死)", probe(s)[0], 0)

print("\n=== 真卡死:有活且持续零进展 ===")
s = state("hung")
BODY["text"] = metrics(steps=500, running=2, waiting=1)
check("停滞 0s → 放行", probe(s)[0], 0)
time.sleep(STALL_S * 0.6)
check(f"停滞 <{STALL_S}s → 放行", probe(s)[0], 0)
time.sleep(STALL_S * 0.6)
rc, msg = probe(s)
check(f"停滞 >{STALL_S}s → 判死", rc, 1, msg)

print("\n=== fail-open:指标缺失 ===")
s = state("nometric")
BODY["text"] = metrics(steps=None, running=1)
check("第 1 次放行", probe(s)[0], 0)
time.sleep(STALL_S * 1.1)
check("超过停滞阈值仍放行", probe(s)[0], 0)

print("\n=== /metrics 抓不到:连续才算数 ===")
s = state("miss")
check("miss 1 → 放行", probe(s, url=DEAD)[0], 0)
check("miss 2 → 放行", probe(s, url=DEAD)[0], 0)
rc, msg = probe(s, url=DEAD)
check(f"miss {MISS} → 判死", rc, 1, msg)
BODY["text"] = metrics(steps=900, running=0)
check("恢复后放行", probe(s)[0], 0)
check("miss 计数已清零", json.load(open(s))["miss"], 0)
check("恢复后再断一次不判死", probe(s, url=DEAD)[0], 0)

print("\n=== worker:判据是「leader 还是不是同一个进程」 ===")
BODY["text"] = metrics(steps=1, start=1000.0)
s = state("w-cold")
check("没见过 leader + 抓不到 → 放行(冷启动窗口)", wprobe(s, url=DEAD)[0], 0)
check("没见过 leader,再抓不到仍放行", wprobe(s, url=DEAD)[0], 0)
s = state("w-gone")
check("首次见到 leader", wprobe(s)[0], 0)
check("leader 稳定 → 放行", wprobe(s)[0], 0)
check("leader 掉线 1 次 → 放行", wprobe(s, url=DEAD)[0], 0)
rc, msg = wprobe(s, url=DEAD)
check(f"leader 掉线 {WORKER_MISS} 次 → 自杀", rc, 1, msg)
s = state("w-restart")
wprobe(s)
BODY["text"] = metrics(steps=1, start=2000.0)           # leader 换了进程
rc, msg = wprobe(s)
check("leader 重启 → 立刻自杀,不必等它掉线", rc, 1, msg)

srv.shutdown()
shutil.rmtree(TMP, ignore_errors=True)
failed = [n for ok, n in RESULTS if not ok]
print(f"\n{'=' * 60}\n{len(RESULTS) - len(failed)}/{len(RESULTS)} 通过")
for n in failed:
    print("  !!", n)
sys.exit(1 if failed else 0)
