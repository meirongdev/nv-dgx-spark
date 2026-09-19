#!/usr/bin/env bash
# ============================================================
# gb10-clock-cap.sh — GB10 GPU 时钟上限(能效优化)
#
# 为什么(2026-08-25 双机 A/B 实测,见 docs/gb10-tuning-cn.md):
#   GB10 空载就把 SM 频率顶在 ~2400-2500 MHz(max 3003),而 V4-Flash 的 decode
#   受限于 LPDDR5X 带宽而非 SM 频率 —— 于是把频率上限压到 2200 MHz 几乎不要钱:
#     decode   配对差 +0.9%,95%CI [-1.9%, +3.7%] → 无法与 0 区分(n=11 交错配对)
#     prefill  -3.7%(8655 token 唯一前缀,击穿 prefix cache)
#     功耗     双机 GPU rail 86.2W → 55.2W = -36%
#   ⚠️ nvidia-smi 的 power.draw 只覆盖真实整机功耗的一小部分(论坛实测 12-27%),
#      墙插口上的实际节省远小于 36% —— 同行 wall 实测 2200 档约 -17%。
#
# ⚠️ 三个必须知道的点:
#   1. **两台必须对称**。TP=2 是锁步的,只压一台 = 全部代价 + 一半收益。
#   2. **-lgc 重启即失效**,所以有 `install` 子命令装 systemd 单元。
#   3. **nvidia-smi 没有任何字段能告诉你锁是否生效** ——
#      `Applications Clocks Setting` 恒为 Not Active、`clocks.max.sm` 恒为 3003。
#      唯一可靠的检测是**有负载时**读 `clocks.current.sm`,即本脚本的 `verify`。
#      (锁稳定一段时间后空载读数也会跟随上限,但刚加锁时仍显示旧值,不能当判据。)
#
# 用法:
#   scripts/gb10-clock-cap.sh apply [MHZ]   # 两节点加锁(默认 2200)
#   scripts/gb10-clock-cap.sh reset         # 两节点解锁(-rgc)
#   scripts/gb10-clock-cap.sh status        # systemd 单元 + 空载频率(注意:测不出锁)
#   scripts/gb10-clock-cap.sh verify        # 发真实生成,采样两节点负载期频率 ← 真正的判据
#   scripts/gb10-clock-cap.sh install [MHZ] # 装并启用 systemd 单元(重启后仍生效)
#   scripts/gb10-clock-cap.sh uninstall     # 停用并删除单元 + 解锁
# 环境变量:CAP_HOSTS / CAP_MHZ / CAP_SSH_USER / CAP_SSH_KEY / CAP_HEAD / CAP_PORT / CAP_MODEL
#   ⚠️ CAP_MODEL 必须跟随当前主力栈 —— 写错会让 verify 退化成空载采样(见下)。
# ============================================================
set -uo pipefail

# --- 主机级参数(与跑哪个栈无关)---------------------------------------------
# 时钟锁是**机器**的属性,两台都要锁且必须对称(TP=2 锁步)。
HOSTS="${CAP_HOSTS:-100.97.87.120 100.67.164.92}"
SSH_USER="${CAP_SSH_USER:-admin}"
SSH_KEY="${CAP_SSH_KEY:-$HOME/.ssh/vgio}"
MHZ="${CAP_MHZ:-2200}"
UNIT=gb10-clock-cap.service

# --- 栈级参数(verify 要发真实生成,所以它必须知道现在跑的是谁)---------------
# ⚠️ 这三样(MODEL / PORT / 思考 kwarg)**逐栈都不同**,而且写错**不报错**:
#    · 2026-09-02 切到 qwen38-flash-next 后这里仍写着 deepseek-v4-flash,
#      生成 404、`curl` 照样 rc=0 → 旧版拿**空载采样**打印判据行,读起来像"通过"。
#      时钟锁的唯一判据因此静默失效约 24 小时。
#    · 2026-09-19 一天之内切了两次,两次都是**三者同时变**。
# 所以它们不再是这个文件里的默认值,而是从 stacks/PRIMARY 推导。
# 换栈时这个脚本**不用动**;要临时对着别的栈验,给 CAP_STACK 或直接给 CAP_MODEL。
#
#   scripts/gb10-clock-cap.sh verify                  # 验当前主力栈
#   CAP_STACK=qwen38fn scripts/gb10-clock-cap.sh verify
#   CAP_MODEL=不存在的名字 scripts/gb10-clock-cap.sh verify   # 负向用例,必须非 0
_CAP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_CAP_HERE/../stacks/_lib/common.sh"
load_stack "${CAP_STACK:-}"

HEAD="${CAP_HEAD:-$STACK_HEAD}"            # 只有 head 暴露 OpenAI API
PORT="${CAP_PORT:-$STACK_PORT}"
MODEL="${CAP_MODEL:-$STACK_MODEL}"
# 关思考的 kwarg;本栈关不掉时注册表给的是"最低档"。空 = 不发这个字段。
CHAT_KWARGS="${CAP_CHAT_KWARGS-${STACK_THINK_OFF:-}}"
# ⚠️ 单节点栈(STACK_NODES=1)下 peer/rank1 采到的是**空闲的 S2**,不是判据。
#    传给远端脚本,让它据此标注而不是甩一个读起来像失败的裸数字。
CAP_NODES="${STACK_NODES:-2}"


sshx(){ ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SSH_USER@$1" "${@:2}"; }

cmd_apply(){
  local mhz="${1:-$MHZ}"
  for h in $HOSTS; do
    printf '%-16s ' "$h"
    sshx "$h" "sudo nvidia-smi -i 0 -lgc 0,$mhz 2>&1 | head -1"
  done
  echo "→ 已加锁 ${mhz} MHz。这是运行时设置,重启失效;要持久化用 install。"
  echo "→ 立刻验证:scripts/gb10-clock-cap.sh verify"
}

cmd_reset(){
  for h in $HOSTS; do
    printf '%-16s ' "$h"
    sshx "$h" 'sudo nvidia-smi -i 0 -rgc 2>&1 | head -1'
  done
  echo "→ 已解锁。注意:若 systemd 单元还 enabled,下次重启会再加锁(用 uninstall 彻底移除)。"
}

cmd_status(){
  for h in $HOSTS; do
    echo "=== $h ==="
    sshx "$h" "systemctl is-enabled $UNIT 2>/dev/null | sed 's/^/  unit enabled: /' || echo '  unit: 未安装'
      systemctl is-active $UNIT 2>/dev/null | sed 's/^/  unit active : /'
      nvidia-smi --query-gpu=clocks.current.sm,clocks.max.sm,power.draw --format=csv,noheader | sed 's/^/  idle clk|max|pw: /'"
  done
  echo "⚠️ 上面不是可靠判据:没有任何显式'已加锁'标志位(clocks.max.sm 恒 3003、"
  echo "   Applications Clocks Setting 恒 Not Active),且刚加锁时空载读数仍显示旧值。用 verify。"
}

cmd_verify(){
  local script=/tmp/.gb10_cap_verify.sh
  # 采样必须在两节点同时进行,且要有真实负载 —— 所以让 head 自己去驱动 S2。
  cat > /tmp/.gb10_cap_verify.local <<'SH'
#!/bin/bash
set +e
PEER="${PEER:-192.168.200.102}"; PORT="${PORT:?}"; MODEL="${MODEL:?}"
CHAT_KWARGS="${CHAT_KWARGS:-}"
# 由调用方从 stacks/ 注入。⚠️ 这里**故意不给默认值**(`:?` 缺了就硬失败)——
# 一个自带旧栈默认值的检查器,正是 2026-09-02 事故的形状。
export NODES="${NODES:-2}" STACK_ID="${STACK_ID:-?}"
nvidia-smi --query-gpu=clocks.current.sm --format=csv,noheader,nounits -lms 400 > /tmp/.cap_v1 2>/dev/null &
P=$!
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER" \
  'nohup nvidia-smi --query-gpu=clocks.current.sm --format=csv,noheader,nounits -lms 400 > /tmp/.cap_v2 2>/dev/null & echo $! > /tmp/.cap_v2.pid'
# ⚠️ **先用 /v1/models 核对身份,别指望生成请求会因 model 名错而失败。**
# 2026-09-19 实测:**SGLang 接受任意 model 名** —— 发 "totally-bogus-model-xyz"
# 照样 200、照样生成 100 token,还把假名字原样回显。也就是说在 SGLang 栈上,
# 「CAP_MODEL 写错 → 服务端 404 → 闸门拦住」这条**完全不成立**:陈旧的
# CAP_MODEL 会静默通过,而这正是本脚本 2026-09-02 事故要防的东西。
# (vLLM 会 404,所以这个洞只在 SGLang 上;但检查放这里对两者都对。)
SERVED=$(curl -s -m 20 "http://localhost:$PORT/v1/models" \
  | python3 -c "import json,sys
try: print(json.load(sys.stdin)['data'][0]['id'])
except Exception: print('')" 2>/dev/null)
if [ "$SERVED" != "$MODEL" ]; then
  echo "  !! /v1/models 报的是 '${SERVED:-<无响应>}',而 CAP_MODEL='$MODEL'。"
  echo "  !! 线上跑的不是这个栈,或 stacks/$STACK_ID/stack.env 的 STACK_MODEL 过期了。"
  echo "     **不要**据此判断锁是否生效(SGLang 会接受任意 model 名,生成请求不会替你报错)。"
  echo "     换主力栈:改 stacks/PRIMARY;临时对别的栈验:CAP_STACK=<id> 重跑。"
  exit 3
fi
python3 - <<PY_PL > /tmp/.cap_pl.json || { echo "  !! payload 构造失败"; exit 3; }
import json, os
payload = {'model': "$MODEL",
           # ⚠️ 计数题,不是开放问答 —— 它**天然**产出 300+ token,不依赖 min_tokens
           #    (SGLang 忽略 min_tokens,实测只回 2 个 token)。换 prompt 前先确认
           #    新 prompt 在**所有**要支持的栈上都能产出 >=50 token。
           'messages': [{'role': 'user',
                         'content': 'Count from 1 to 300, one number per line. '
                                    'Output only the numbers.'}],
           'max_tokens': 300, 'min_tokens': 300, 'temperature': 0}
# 逐栈不同的思考 kwarg。空 = 不发(k3s 两栈)。
ck = r'''$CHAT_KWARGS'''.strip()
if ck:
    payload['chat_template_kwargs'] = json.loads(ck)
print(json.dumps(payload))
PY_PL
curl -s -m 120 "http://localhost:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
  -d @/tmp/.cap_pl.json > /tmp/.cap_resp.json
# 判据只认"真的生成了 token"。curl 的退出码不行 —— model 名写错时服务端返回
# 400 而 curl 照样 rc=0,旧版就是这样把空载采样打印成了"通过"。
GEN_TOK=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/.cap_resp.json'))['usage']['completion_tokens'])
except Exception:
    print(0)")
echo "  负载:生成 $GEN_TOK token"
kill $P 2>/dev/null
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER" 'kill $(cat /tmp/.cap_v2.pid) 2>/dev/null'
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$PEER:/tmp/.cap_v2" /tmp/.cap_v2 2>/dev/null
# ⚠️ 没有负载 = 没有判据。空载采样看起来完全正常(会贴住上限),所以这里必须
# 硬失败,而不是打印一行读起来像"通过"的数字。
if [ "${GEN_TOK:-0}" -lt 50 ] || ! grep -q . /tmp/.cap_v1 2>/dev/null; then
  echo "  !! 生成失败($GEN_TOK token)—— 引擎没在跑,或 CAP_MODEL($MODEL) 与线上 served-model-name 不符。"
  head -c 200 /tmp/.cap_resp.json 2>/dev/null; echo
  echo "  !! 本次采样是空载的,**不能作为锁生效的判据**。先修好再测。"
  exit 3
fi
python3 - <<'PY'
# ⚠️ **单节点栈下 peer 那行不是判据。** 2026-09-19 切到 SGLang(只用 S1)后
#    实测 peer 采到 209 MHz —— 那是 S2 真正空闲的频率,不是"锁没生效"。
#    空闲读数和判据长得完全不像,但它打印在"判据"字样下面就会被误读,
#    所以这里显式标注,而不是甩一个裸数字出去。
#    (S2 上的锁在它空闲时无法用本方法验证 —— 要验就得让它真的有负载。)
loads = {}
for tag, f in (("head/rank0", "/tmp/.cap_v1"), ("peer/rank1", "/tmp/.cap_v2")):
    try: v = [int(x) for x in open(f).read().split() if x.strip().isdigit()]
    except OSError: v = []
    loads[tag] = v
    if not v:
        print(f"  {tag}: 无采样"); continue
    mean = sum(v) / len(v)
    note = ""
    if mean < 800:
        note = "   ← 该节点空闲,**本行不构成判据**(单节点栈时属正常)"
    print(f"  {tag}: max={max(v)} mean={mean:.0f} n={len(v)}{note}")
import os
h = loads.get("head/rank0") or []
p_ = loads.get("peer/rank1") or []
if h and p_ and sum(p_)/len(p_) < 800:
    if os.environ.get("NODES") == "1":
        print(f"  注:只有 head 参与了负载 —— 栈 '{os.environ.get('STACK_ID','?')}' 是单节点,S2 本就空闲。")
        print("     要验 S2 的锁,得先在 S2 上跑起有负载的东西(如 make run STACK=qwen38fn)。")
    else:
        print("  ⚠️ 本栈声明是双节点,peer 却是空载 —— 这不正常:rank1 可能没起来,")
        print("     或者两台的锁不对称(TP=2 锁步,只压一台 = 全部代价 + 一半收益)。")
PY
SH
  scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/.gb10_cap_verify.local "$SSH_USER@$HEAD:$script"
  # ⚠️ 判据行只在远端**真的采到负载期样本**时才打印。远端失败(exit 3)时若照常
  # 打印,读者就会把上面那两行空载数字当成结论 —— 那正是本脚本 2026-09-02 犯的错。
  if sshx "$HEAD" "PORT=$PORT MODEL=$MODEL CHAT_KWARGS='$CHAT_KWARGS' \
                   NODES=$CAP_NODES STACK_ID=$STACK_ID bash $script"; then
    echo "→ 判据:负载期 mean/max 若明显低于 ~2400 且贴住你设的上限,锁生效。"
    echo "  (GB10 按离散档位吸附,设 2200 实测约落在 2177-2190。)"
  else
    echo "→ ❌ 本次 verify **没有结论**(见上)。锁是否生效仍然未知。"
    return 3
  fi
}

cmd_install(){
  local mhz="${1:-$MHZ}" tmp=/tmp/.gb10-clock-cap.service
  cat > "$tmp" <<EOF
[Unit]
# GB10 GPU 时钟上限 —— 能效优化。依据与实测数据:docs/gb10-tuning-cn.md
# ⚠️ 两台必须对称(TP=2 锁步);⚠️ nvidia-smi 无字段可报告锁是否生效,
#    验证只能用 \`make clock-cap-verify\`(有负载时读 clocks.current.sm)。
Description=GB10 GPU clock cap (${mhz} MHz) for energy efficiency
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -i 0 -lgc 0,${mhz}
ExecStop=/usr/bin/nvidia-smi -i 0 -rgc

[Install]
WantedBy=multi-user.target
EOF
  for h in $HOSTS; do
    echo "=== $h ==="
    scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no "$tmp" "$SSH_USER@$h:$tmp"
    sshx "$h" "sudo install -m 0644 $tmp /etc/systemd/system/$UNIT \
      && sudo systemctl daemon-reload \
      && sudo systemctl enable --now $UNIT \
      && echo '  installed+enabled' \
      && systemctl is-active $UNIT | sed 's/^/  active: /'"
  done
  echo "→ 装好了。重启后仍生效。验证:scripts/gb10-clock-cap.sh verify"
}

cmd_uninstall(){
  for h in $HOSTS; do
    echo "=== $h ==="
    sshx "$h" "sudo systemctl disable --now $UNIT 2>/dev/null | tail -1
      sudo rm -f /etc/systemd/system/$UNIT && sudo systemctl daemon-reload
      sudo nvidia-smi -i 0 -rgc 2>&1 | head -1 | sed 's/^/  /'"
  done
  echo "→ 单元已移除、时钟已解锁。"
}

case "${1:-status}" in
  apply)     cmd_apply     "${2:-}" ;;
  reset)     cmd_reset ;;
  status)    cmd_status ;;
  verify)    cmd_verify ;;
  install)   cmd_install   "${2:-}" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
