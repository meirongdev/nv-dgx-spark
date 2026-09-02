#!/bin/bash
# PLE FP8 补丁 + 预检的端到端回归(make ple-test)。**在 S1 上的容器里跑**,
# 挂真实镜像与真实 checkpoint,按 rank 脚本的真实顺序。
#
# 为什么必须有:这两条守的是**静默降级** —— PLE embedding 少乘一个全局 scale,
# 模型照跑照出词,只是质量悄悄变差。所以重点不是证明它会放行,而是证明它
# **会挡**:A 和 D 两条(未打补丁 / 缺 env)期望的都是"挡住启动"。
# 一个只会 PASS 的守卫等于没有守卫。
#
# 由 Makefile 的 ple-test 目标从 ConfigMap 抽出线上那两份脚本后调用 ——
# 测的是线上那份,不是副本。
export QWEN38FN_MODEL=/model
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
       else echo "  FAIL  $1 (期望 rc=$2, 实际 rc=$3)"; fail=$((fail+1)); fi; }

echo "===== A. 未打补丁 + 已设 env → 预检必须 FAIL(挡住启动)====="
export PLE_QUANT_OVERRIDE=fp8
python3 /scripts/ple-preflight.py; rc=$?
chk "未打补丁 → 挡住" 1 $rc

echo
echo "===== B. 打补丁 ====="
python3 /scripts/patch-ple-fp8.py; chk "补丁应用成功" 0 $?

echo
echo "===== C. 打了补丁 + 已设 env → 预检必须 PASS ====="
python3 /scripts/ple-preflight.py; rc=$?
chk "打完补丁 → 放行" 0 $rc

echo
echo "===== D. 打了补丁但 env 没设 → 仍必须 FAIL(两个条件缺一不可)====="
unset PLE_QUANT_OVERRIDE
python3 /scripts/ple-preflight.py >/dev/null 2>&1; rc=$?
chk "缺 env → 挡住" 1 $rc

echo
echo "===== E. 逃生口 PLE_PREFLIGHT_ENFORCE=0 → 告警但放行 ====="
PLE_PREFLIGHT_ENFORCE=0 python3 /scripts/ple-preflight.py >/dev/null 2>&1; rc=$?
chk "逃生口生效" 0 $rc

echo
echo "============================================================"
echo "$pass/$((pass+fail)) 通过"
[ "$fail" -eq 0 ] || exit 1
