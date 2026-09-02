#!/usr/bin/env bash
# mem-watch 去抖逻辑回归测试(make memwatch-test)。纯本地,不碰集群、不发 SSH。
#
# 为什么有这个文件:2026-09-02 发现 tick() 的「每节点各自连续 CRIT_CONSEC 次才
# 动手」从一开始就没生效 —— macOS 自带 bash 3.2 不支持 `declare -A`,两个节点的
# 下标塌到同一个 0。真正的后果不是"计数不准",而是**健康的那个节点每轮都把共享
# 计数清零**,于是危险节点永远攒不满 → 看门狗根本不会触发。它守的是整机 OOM,
# 而节点 OOM 一台一台来,所以这道防线在本机上等于不存在。修完必须有东西钉住它。
#
# 钉住它的是下面 "A 连续危险 + B 健康 → 必须动手" 这一条:把 _key 换回会塌的
# 实现,它会 FAIL(已验证)。
#
# ⚠️ 直接 source 真脚本(MEMWATCH_LIB_ONLY=1),测的是**线上那份**逻辑,
# 不是复制品 —— 与 scripts/test-liveness-probe.py 同思路。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MEMWATCH_LIB_ONLY=1
export WATCH_LOG="${TMPDIR:-/tmp}/memwatch-test.log"
export WATCH_STATE="${TMPDIR:-/tmp}/.memwatch-test-fired"
export WATCH_NODES="nodeA nodeB"
export WATCH_CRIT_PCT=5 WATCH_WARN_PCT=8 WATCH_CRIT_CONSEC=2
rm -f "$WATCH_STATE" "$WATCH_LOG"

# shellcheck source=/dev/null
. "$HERE/mem-watch.sh"

# ⚠️ 没有这道自检的话,source 失败时所有断言都会「因为什么都没发生」而假通过 ——
# 本文件第一版就踩了这个,记在这里。
for fn in tick kv_get kv_set node_avail_pct; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: mem-watch.sh 没加载成功($fn 缺失)"; exit 2; }
done

# --- 打桩:节点读数与 scale 动作都不出网 -------------------------------------
PCT_A=50 PCT_B=50
node_avail_pct(){ case "$1" in nodeA) echo "$PCT_A";; nodeB) echo "$PCT_B";; *) echo N/A;; esac; }
SCALED=""
scale_down(){ SCALED="$SCALED $1"; printf 'fired\n' > "$WATCH_STATE"; }

pass=0; fail=0
check(){ # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s  (期望 [%s] 实际 [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
reset(){ SCALED=""; rm -f "$WATCH_STATE"; kv_set crit nodeA 0; kv_set crit nodeB 0; }

echo "=== 每节点独立去抖(CRIT_CONSEC=2) ==="

# 1. 交替危险不该累积成一次触发(防过敏)。
#    注:这一条在旧 bug 下也是 PASS 的 —— 它守的是另一个方向,不是本次修的那个。
reset; PCT_A=3 PCT_B=50; tick >/dev/null
PCT_A=50 PCT_B=3; tick >/dev/null
check "A 危险1次 + B 危险1次(交替) → 不动手" "" "$SCALED"

# 2. ★ 本次修复的核心用例:同一节点连续危险,**而另一台健康**,必须照样动手。
#    旧实现里 B 健康会把共享计数清零,这条会 FAIL(= 看门狗永不触发)。
reset; PCT_A=3 PCT_B=50
tick >/dev/null; check "A 第1次危险(B 健康) → 不动手" "" "$SCALED"
tick >/dev/null; check "★ A 第2次危险(B 健康) → 必须动手" " nodeA" "$SCALED"

# 3. 中间恢复一次要清零,不能记账。
reset; PCT_A=3; tick >/dev/null
PCT_A=50; tick >/dev/null
PCT_A=3;  tick >/dev/null
check "危险→恢复→危险 → 计数清零,不动手" "" "$SCALED"

# 4. 探不到 = fail-open,不累计(遵循仓库探针哲学:误杀比晚发现贵)。
reset; PCT_A=3; tick >/dev/null
PCT_A=N/A; tick >/dev/null
PCT_A=3;   tick >/dev/null
check "危险→探不到→危险 → 不动手" "" "$SCALED"

# 5. 已触发过就保持,不重复动手(state 文件在)。
reset; PCT_A=3; tick >/dev/null; tick >/dev/null
SCALED=""; tick >/dev/null
check "已触发后保持,不重复 scale" "" "$SCALED"

echo
echo "=== 阈值边界 ==="
reset; PCT_A=5 PCT_B=50; tick >/dev/null; tick >/dev/null
check "available 恰好等于 CRIT_PCT(5) → 视为危险" " nodeA" "$SCALED"
reset; PCT_A=6 PCT_B=50; tick >/dev/null; tick >/dev/null
check "available=6 高于临界 → 不动手(仅 warn 区)" "" "$SCALED"

echo
echo "=== 栈自检:必须认得当前主力栈 ==="
check "默认 DEPLOYS 与 STACK 一致" "v4flash-worker v4flash-leader" "$DEPLOYS"
check "NS 跟随 STACK" "v4flash" "$NS"

rm -f "$WATCH_STATE" "$WATCH_LOG"
echo
echo "============================================================"
echo "$pass/$((pass+fail)) 通过"
[ "$fail" -eq 0 ] || exit 1
