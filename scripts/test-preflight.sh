#!/usr/bin/env bash
# ============================================================
# 互斥自检回归(make preflight-test)。纯本地:探测函数打桩,不碰集群、不发 SSH。
#
# 它守的是 gotcha #2 —— 两个栈抢同一份 GPU 内存会 OOM 整机,而这两台**没有 BMC**,
# 硬重启要有人到机器跟前。
#
# ★ 最重要的一条是最后那个用例:**往注册表里塞一个全新的栈,既有的栈必须
#   立刻开始检查它,不改任何代码。** 旧实现里互斥是每个栈各自手写的一份名单
#   (O(n²)),加第五个栈时就已经不一致了 —— qwen38fn 的 preflight 查 v4flash 和
#   qwen38,却漏了 glm53。漏掉的那一格不会报错,它只是不拦。
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../stacks/_lib/common.sh"
. "$HERE/../stacks/_lib/preflight.sh"
set +o pipefail

pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
         else printf '  FAIL  %s  (期望 [%s] 实际 [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# --- 打桩:两种探测都不出网 --------------------------------------------------
K3S_SNAP=""; DOCKER_SNAP=""
_probe_k3s(){ printf '%s\n' "$K3S_SNAP"; }
_probe_docker(){ printf '%s\n' "$DOCKER_SNAP"; }

run_pf(){ preflight_exclusive "$1" >/tmp/.pf_out 2>&1; echo $?; }
said(){ grep -q "$1" /tmp/.pf_out && echo yes || echo no; }

echo "=== 全停时放行 ==="
K3S_SNAP=""; DOCKER_SNAP=""
check "没有栈在跑 → 放行" "0" "$(run_pf qwen38un)"

echo
echo "=== k3s 栈占着时拦住 ==="
K3S_SNAP="qwen38fn 2"; DOCKER_SNAP=""
check "qwen38fn 有副本 → 拦住 qwen38un" "1" "$(run_pf qwen38un)"
check "  并指名道姓" "yes" "$(said 'qwen38fn')"
check "  并给出停机命令" "yes" "$(said 'make stop STACK=qwen38fn')"
K3S_SNAP="qwen38fn 0"
check "副本数为 0 → 不算在跑" "0" "$(run_pf qwen38un)"

echo
echo "=== docker 栈占着时拦住 ==="
K3S_SNAP=""; DOCKER_SNAP="100.97.87.120 glm53-exl3-head"
check "glm53 容器在跑 → 拦住 qwen38un" "1" "$(run_pf qwen38un)"
check "  自己在跑不算冲突(拦的是别人)" "0" "$(run_pf glm53)"
DOCKER_SNAP="100.97.87.120 某个无关容器"
check "无关容器 → 不拦" "0" "$(run_pf qwen38un)"

echo
echo "=== ★ 新栈自动进入互斥,不改任何代码 ==="
NEW="$STACKS_DIR/_pftest"
mkdir -p "$NEW"
cat > "$NEW/stack.env" <<EOF
STACK_ID=_pftest
STACK_NAME="临时注册的新栈(回归用例)"
STACK_RUNTIME=docker
STACK_MODEL=pftest-model
STACK_PORT=8888
STACK_HEAD=100.97.87.120
STACK_CONTAINERS="pftest-container"
STACK_STOP_CMD="docker rm -f pftest-container"
EOF
K3S_SNAP=""; DOCKER_SNAP="100.97.87.120 pftest-container"
check "新栈在跑 → 既有的 qwen38un 必须被拦住" "1" "$(run_pf qwen38un)"
check "  报的是新栈的名字" "yes" "$(said '_pftest')"
DOCKER_SNAP="100.97.87.120 glm53-exl3-head"
check "反向:既有栈在跑 → 新栈也被拦住" "1" "$(run_pf _pftest)"
rm -rf "$NEW"
DOCKER_SNAP=""          # ← 上一条还把 glm53 摆在"在跑",不清掉这里测的是别的东西
check "清理后恢复放行" "0" "$(run_pf qwen38un)"

rm -f /tmp/.pf_out
echo
echo "============================================================"
echo "$pass/$((pass+fail)) 通过"
[ "$fail" -eq 0 ] || exit 1
