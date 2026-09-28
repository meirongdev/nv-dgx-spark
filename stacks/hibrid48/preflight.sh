#!/usr/bin/env bash
# hibrid48 的专属闸门(通用 preflight 之后跑,非 0 退出则起栈失败)。
# 通用层已查:权重 28 分片 / 镜像 myllmbox/...:v4 / 节点互斥。
# 这里只加"起得来但会慢得多"的主机态检查 —— 两个都只警告不拦。
set -uo pipefail

# --- 1. vm.compaction_proactiveness 必须是 0 --------------------------------
# 上游实测:默认值(20)下内核的主动页迁移器会偷引擎的页,负载下 ~每 37 s 一次
# 4-5 s 卡顿,吞吐 −10%。持久化在 /etc/sysctl.d/99-myllmbox-compaction.conf
# (tune-host.sh 2026-09-27 装过)。掉档不影响起不起,只影响快不快 → 警告不拦。
cp=$(sshx "$STACK_HEAD" "cat /proc/sys/vm/compaction_proactiveness 2>/dev/null" || echo "?")
if [ "$cp" != "0" ]; then
  echo "  ⚠️ $STACK_HEAD vm.compaction_proactiveness=$cp (应为 0) —— 预期 ~10% 吞吐损失 + 周期性 4-5 s 卡顿。"
  echo "     修复: ssh $STACK_HEAD 'cd /home/admin/hibrid48-recipe && sudo ./tune-host.sh' (持久化)"
fi

# --- 2. PLE 表 map 缓存(~31G,首次启动时构建) --------------------------------
# 丢了只是这次启动多几分钟重建,不是故障。只提示,免得把首启慢误判成启动失败。
cache_kb=$(sshx "$STACK_HEAD" "du -sk /home/admin/hibrid48-recipe/cache 2>/dev/null | cut -f1" || echo 0)
if [ "${cache_kb:-0}" -lt 10485760 ]; then
  echo "  ⚠️ 表 map 缓存缺失或太小(当前 ~$(( ${cache_kb:-0} / 1024 / 1024 ))G,预期 ~31G)—— 本次启动会多花几分钟建 map,属正常。"
fi

exit 0
