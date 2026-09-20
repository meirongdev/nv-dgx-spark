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

# --- 打桩:探测不出网 --------------------------------------------------------
DOCKER_SNAP=""
_probe_docker(){ printf '%s\n' "$DOCKER_SNAP"; }

run_pf(){ preflight_exclusive "$1" >/tmp/.pf_out 2>&1; echo $?; }
said(){ grep -q "$1" /tmp/.pf_out && echo yes || echo no; }

echo "=== 全停时放行 ==="
DOCKER_SNAP=""
check "没有栈在跑 → 放行" "0" "$(run_pf qwen38un)"

echo
echo "=== 栈占着时拦住 ==="
DOCKER_SNAP="100.97.87.120 glm53-exl3-head"
check "glm53 容器在跑 → 拦住 qwen38un" "1" "$(run_pf qwen38un)"
check "  并指名道姓" "yes" "$(said 'glm53')"
check "  并给出停机命令" "yes" "$(said 'make stop STACK=glm53')"
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
DOCKER_SNAP="100.97.87.120 pftest-container"
check "新栈在跑 → 既有的 qwen38un 必须被拦住" "1" "$(run_pf qwen38un)"
check "  报的是新栈的名字" "yes" "$(said '_pftest')"
DOCKER_SNAP="100.97.87.120 glm53-exl3-head"
check "反向:既有栈在跑 → 新栈也被拦住" "1" "$(run_pf _pftest)"
rm -rf "$NEW"
DOCKER_SNAP=""          # ← 上一条还把 glm53 摆在"在跑",不清掉这里测的是别的东西
check "清理后恢复放行" "0" "$(run_pf qwen38un)"

echo
echo "=== ★ 按节点互斥:不共用节点的栈不互相拦(2026-09-20 S2 常驻第二个栈)==="
S2="$STACKS_DIR/_pfs2"
mkdir -p "$S2"
cat > "$S2/stack.env" <<EOF
STACK_ID=_pfs2
STACK_NAME="只在 S2 上的单机栈(回归用例)"
STACK_RUNTIME=docker
STACK_MODEL=pfs2-model
STACK_PORT=18300
STACK_HEAD=100.67.164.92
STACK_GPU_NODES=100.67.164.92
STACK_CONTAINERS="pfs2-container"
STACK_STOP_CMD="docker rm -f pfs2-container"
EOF

# qwen38un 只占 S1,_pfs2 只占 S2 —— 两者可以并存,这是本次改动的目的。
DOCKER_SNAP="100.67.164.92 pfs2-container"
check "S2 的栈在跑 → 不拦 S1 上的 qwen38un" "0" "$(run_pf qwen38un)"
check "  且明说了它是被跳过的,不是验过的" "yes" "$(said '未检查')"
DOCKER_SNAP="100.97.87.120 qwen3.8-27b-sglang"
check "反向:S1 的 qwen38un 在跑 → 不拦 S2 上的 _pfs2" "0" "$(run_pf _pfs2)"

# ★ 最要命的一格:TP=2 栈的 rank1 也吃 S2 的 GPU 内存。
#   只比 STACK_HEAD 的话 glm53(head=S1)会被判成与 _pfs2 无关 —— 而它们
#   会在 S2 上抢同一块 GPU,OOM 掉一台没有 BMC 的机器(gotcha #2)。
#   ⚠️ 2026-09-20 两个 k3s 栈删除后,glm53 是注册表里**唯一**的双节点栈,
#      这一格的覆盖全靠它;再删它就必须在这里补一个合成的双节点夹具。
DOCKER_SNAP="100.97.87.120 glm53-exl3-head"
check "★ 双节点栈在跑(worker 在 S2)→ 必须拦住 S2 的 _pfs2" "1" "$(run_pf _pfs2)"
check "  并指名道姓" "yes" "$(said 'glm53')"
check "反向:_pfs2 在跑 → 拦住双节点的 glm53" "1" "$(DOCKER_SNAP='100.67.164.92 pfs2-container'; run_pf glm53)"

# 负向:一个栈忘了声明节点足迹 → 退回 STACK_HEAD,绝不退化成「谁都不拦」。
cat > "$S2/stack.env" <<EOF
STACK_ID=_pfs2
STACK_NAME="忘了写 STACK_GPU_NODES 的栈(回归用例)"
STACK_RUNTIME=docker
STACK_MODEL=pfs2-model
STACK_PORT=18300
STACK_HEAD=100.97.87.120
STACK_CONTAINERS="pfs2-container"
STACK_STOP_CMD="docker rm -f pfs2-container"
EOF
DOCKER_SNAP="100.97.87.120 pfs2-container"
check "没写 STACK_GPU_NODES → 退回 STACK_HEAD,仍然拦得住" "1" "$(run_pf qwen38un)"
rm -rf "$S2"
DOCKER_SNAP=""
check "清理后恢复放行" "0" "$(run_pf qwen38un)"

rm -f /tmp/.pf_out
echo
echo "============================================================"
echo "$pass/$((pass+fail)) 通过"
[ "$fail" -eq 0 ] || exit 1
