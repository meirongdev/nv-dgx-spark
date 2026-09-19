#!/usr/bin/env bash
# ============================================================
# stacks/_lib/preflight.sh —— 通用起栈前自检
#
# 解决的是一个 O(n²) 问题:在此之前,每加一个栈,都要去**改其它每一个栈的
# preflight**,把新栈加进互斥名单。五个栈的时候已经是四份手写的 ssh 链条,
# 彼此还不一致(qwen38fn 只查 v4flash + qwen38,漏了 glm53)。
#
# 现在互斥是**遍历注册表**得出的:新栈一落地,所有既有栈自动开始检查它,
# 一行既有代码都不用改。
#
# 两段:
#   1. 互斥(gotcha #2:两个栈抢同一份 GPU 内存 → 整机 OOM,而这两台没有 BMC)
#   2. 资产就位(权重分片数 / 镜像),由 stack.env 的字段驱动
# 栈自己还可以放一个 stacks/<id>/preflight.sh 做额外闸门(如 glm53 的主机内存)。
#
# ⚠️ 批量探测:所有 k3s 栈**一次** kubectl,每台 docker 宿主机**一次** docker ps。
#    不是为了好看 —— 旧版每栈一条 ssh,走 DERP 中继时 preflight 本身要跑十几秒。
# ============================================================

# 返回:每行 "<ns> <replicas-sum>"
_probe_k3s(){
  $K8S get deploy -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | awk '{s[$1]+=$2} END{for(n in s) print n, s[n]}'
}

# 返回:每行 "<host> <container-name>"
_probe_docker(){
  local h
  for h in "$@"; do
    sshx "$h" "docker ps --format '{{.Names}}'" 2>/dev/null | sed "s|^|$h |"
  done
}

preflight_exclusive(){
  local target="$1" id busy=0
  local k3s_snap docker_snap hosts=""

  # 需要探测哪些宿主机 / 要不要问 k3s,由注册表自己说了算
  local need_k3s=0
  for id in $(stack_ids_active); do
    [ "$id" = "$target" ] && continue
    case "$(stack_field "$id" STACK_RUNTIME)" in
      k3s)    need_k3s=1 ;;
      docker) hosts="$hosts $(stack_field "$id" STACK_HEAD)" ;;
    esac
  done
  hosts=$(echo "$hosts" | tr ' ' '\n' | sort -u | tr '\n' ' ')

  [ "$need_k3s" = 1 ] && k3s_snap=$(_probe_k3s)
  [ -n "${hosts// /}" ] && docker_snap=$(_probe_docker $hosts)

  for id in $(stack_ids_active); do
    [ "$id" = "$target" ] && continue
    local rt ns conts head hit=""
    rt=$(stack_field "$id" STACK_RUNTIME)
    case "$rt" in
      k3s)
        ns=$(stack_field "$id" STACK_NS)
        local n; n=$(echo "$k3s_snap" | awk -v ns="$ns" '$1==ns{print $2+0}')
        [ "${n:-0}" -gt 0 ] && hit="$n 个副本在跑"
        ;;
      docker)
        head=$(stack_field "$id" STACK_HEAD)
        conts=$(stack_field "$id" STACK_CONTAINERS)
        local c
        for c in $conts; do
          echo "$docker_snap" | grep -qE "^$head +$c\$" && { hit="容器 $c 在跑"; break; }
        done
        ;;
    esac
    if [ -n "$hit" ]; then
      echo "ABORT: 栈 '$id' $hit —— 会与 '$target' 抢同一份 GPU 内存(gotcha #2)。"
      echo "       先执行: make stop STACK=$id"
      busy=1
    fi
  done
  [ "$busy" = 0 ] || return 1
  echo "  互斥 OK($(stack_ids_active | grep -vc "^$target\$") 个其它栈全部停止)"
}

# --- 资产就位(权重分片 + 镜像),纯字段驱动 ---------------------------------
preflight_assets(){
  local nodes="${STACK_ASSET_NODES:-$STACK_HEAD}" h rc=0
  for h in $nodes; do
    if [ -n "${STACK_WEIGHTS:-}" ] && [ -n "${STACK_WEIGHTS_SHARDS:-}" ]; then
      # 数分片:比「目录在不在」强得多 —— 半个 checkpoint 的目录是存在的,
      # 而它会在加载到一半时才炸,那时候已经等了几分钟。
      sshx "$h" "n=\$(find $STACK_WEIGHTS -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l); \
                 [ \"\$n\" -eq $STACK_WEIGHTS_SHARDS ] \
                 || { echo \"ABORT: $h 权重只有 \$n/$STACK_WEIGHTS_SHARDS 分片\"; exit 1; }" || rc=1
    elif [ -n "${STACK_WEIGHTS:-}" ]; then
      sshx "$h" "test -d $STACK_WEIGHTS \
                 || { echo 'ABORT: $h 上没有权重目录 $STACK_WEIGHTS'; exit 1; }" || rc=1
    fi
    if [ -n "${STACK_IMAGE:-}" ]; then
      case "$STACK_RUNTIME" in
        k3s)    sshx "$h" "sudo k3s ctr -n k8s.io images ls -q | grep -q '$STACK_IMAGE' \
                           || { echo 'ABORT: $h 的 containerd 里没有镜像 $STACK_IMAGE'; exit 1; }" || rc=1 ;;
        docker) sshx "$h" "docker image inspect $STACK_IMAGE >/dev/null 2>&1 \
                           || { echo 'ABORT: $h 上没有镜像 $STACK_IMAGE'; exit 1; }" || rc=1 ;;
      esac
    fi
  done
  [ "$rc" = 0 ] || return 1
  echo "  权重/镜像 OK($nodes)"
}

preflight_run(){
  local target="$1"
  echo "=== preflight: $target ==="
  preflight_exclusive "$target" || return 1
  preflight_assets || return 1
  # 栈自己的额外闸门(可选)。glm53 的主机内存闸门就住在这里。
  if [ -x "$STACK_SELF_DIR/preflight.sh" ]; then
    echo "  --- stacks/$target/preflight.sh ---"
    ( . "$STACK_SELF_DIR/preflight.sh" ) || return 1
  fi
  echo "preflight OK"
}
