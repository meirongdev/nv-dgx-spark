#!/usr/bin/env bash
# ============================================================
# glm53 专属起栈闸门:主机内存
#
# 通用 preflight(互斥 + 权重 + 镜像)对所有栈都跑,这一条只有本栈需要 ——
# 而它存在的理由是**首次启动就栽在这里**(2026-09-19):
#   S2 的 polkitd 涨到 6.27 GiB RSS,于是可用内存 103.09 GiB < gmu 0.85 要的
#   103.44 GiB —— **只差 0.35 GiB**,但要等到容器起来、权重开始加载、3 分钟后
#   才在 worker 里报出来,而且报的是 CUDA 层的 ValueError:
#     Free memory on device cuda:0 (103.09/121.69 GiB) on startup is less than
#     desired GPU memory utilization (0.85, 103.44 GiB).
# 上游 README 写明过这条("resident services 会让你差不到 1 GiB 而过不了启动
# 内存检查"),其 issue #193 也报过同一个 polkitd 膨胀(他们 3.3 GiB)。
# 上游自己的 preflight_memory() 看不住(其 #205 称之为 blind spot)。
#
# 解法(按顺序试):sudo systemctl restart polkit → drop_caches → 仍不够再降 gmu。
#
# 钩子契约:被 preflight_run 在子 shell 里 source,STACK_* 已加载,sshx 可用。
# 非 0 退出 = 拦住起栈。新栈需要自己的闸门就照这个写一份,不改任何既有文件。
# ============================================================

for h in $STACK_ASSET_NODES; do
  sshx "$h" "sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" >/dev/null \
    && echo "  $h: page cache dropped"
done

# gmu 的真相源是宿主机上的 .env,不是本仓库 —— 我们只改了 6 行,账记在 recipe.yaml。
util=$(sshx "$STACK_HEAD" "grep -E '^GPU_MEM_UTIL=' $STACK_DIR/.env | tail -1 | cut -d= -f2")
[ -n "$util" ] || { echo "ABORT: 读不到 $STACK_DIR/.env 里的 GPU_MEM_UTIL"; exit 1; }

for h in $STACK_ASSET_NODES; do
  sshx "$h" \
    "awk -v u=$util -v host=$h '/^MemTotal:/{t=\$2} /^MemAvailable:/{a=\$2} \
     END{ tg=t/1048576; ag=a/1048576; need=tg*u; \
          printf \"  %s: avail %.1f GiB / need %.1f GiB (gmu %s of %.1f)\", host, ag, need, u, tg; \
          if (ag < need) { printf \"  <-- 不足 %.2f GiB\n\", need-ag; exit 1 } print \"\" }' /proc/meminfo; \
     rc=\$?; \
     p=\$(ps -eo rss,comm | awk '/polkitd/{print \$1}'); \
     if [ -n \"\$p\" ] && [ \"\$p\" -gt 1048576 ]; then \
       echo \"  !! $h polkitd 占 \$((p/1048576)) GiB —— sudo systemctl restart polkit\"; fi; \
     exit \$rc" \
  || { echo "ABORT: $h 可用内存不足以满足 GPU_MEM_UTIL=${util}。"; \
       echo "       先试: ssh $h 'sudo systemctl restart polkit'(见本文件注释),再重跑 preflight。"; exit 1; }
done
echo "  主机内存闸门 OK"
