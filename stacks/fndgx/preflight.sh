#!/usr/bin/env bash
# fndgx 专属闸门(通用 preflight 之后跑,非 0 退出即拦住起栈)。
#
# 通用那层已经数过 -fp8hybrid 目录里的 206 个 *.safetensors 了。这里补三件
# 它数不出来的事,每一件都对应一个「失败要等好几分钟才现形」的路径。
set -uo pipefail
rc=0

HYBRID="$STACK_WEIGHTS"
BASE="${HYBRID%-fp8hybrid}"

# --- 1. hybrid 布局真的准备完了 ----------------------------------------------
# 分片数对不代表准备完:prepare-hybrid.sh 是先 cp -a 符号链接、再转 4 个分片、
# 最后才 touch .prepared。中途被打断的目录分片数是齐的,但侧层还是 bf16 ——
# 模型照常起得来,只是慢 20%,而且没有任何一行日志会说这件事。
sshx "$STACK_HEAD" "test -f '$HYBRID/.prepared'" || {
  echo "ABORT: $HYBRID 没有 .prepared 标记 —— hybrid 布局没准备完。"
  echo "       修: ssh $STACK_HEAD 'cd $STACK_DIR && MODEL=RadixArk/Qwen3.8-Flash-Next-NVFP4 ./scripts/prepare-hybrid.sh'"
  rc=1
}

# --- 2. 指回原快照的相对符号链接没断 ------------------------------------------
# ⚠️ 本栈的权重布局是**我们自己搭的**:原始权重是 2026-09-02 下载的扁平目录
#    (qwen38fn 也在用同一份),HF cache 布局由 418 个相对符号链接呈现出来。
#    删掉/搬走扁平目录,这里全部变成悬空链接 —— 而 vLLM 要加载到一半才炸。
dangling=$(sshx "$STACK_HEAD" "find '$BASE/' -maxdepth 1 -xtype l 2>/dev/null | wc -l")
if [ "${dangling:-1}" -gt 0 ]; then
  echo "ABORT: $BASE 里有 $dangling 个悬空符号链接 —— 原始扁平权重目录被移走了?"
  echo "       它们指向 ../../../Qwen3.8-Flash-Next-NVFP4/(与 qwen38fn 共用同一份)。"
  rc=1
else
  echo "  符号链接布局 OK(无悬空)"
fi

# --- 3. 主机内存够不够**起得来** ----------------------------------------------
# GPU_MEM 是总内存的一个比例,不够的话失败发生在 CUDA 层、启动三分钟之后,报的
# 还是个看不出是内存问题的 ValueError(glm53 踩过同一个坑:S2 的 polkitd 涨到
# 6.27 GiB,只差 0.35 GiB,等了三分钟才知道)。
#
# ⚠️ 这条闸门守的是「能不能**启动**」。本栈已经在跑的时候,那 ~100 GiB 正被它
#    自己占着,再量一次必然不足 —— 那是误报。所以先问在不在跑,并且**把跳过的
#    理由打出来**,而不是让它读起来像验过了。
if sshx "$STACK_HEAD" "docker ps --filter name=${STACK_CONTAINERS%% *} --format '{{.Names}}' | grep -q ."; then
  echo "  本栈已在运行 —— 跳过主机内存闸门(它守的是启动,那 ~100 GiB 正被它自己占着)"
else
  # GPU_MEM 的真相源是上游脚本,不是这里:profile 里写了就用 profile 的,
  # 否则取 serve.sh 的默认值。写死一个 0.80 在这里,上游改了配方就会静默失配。
  gm=$(sshx "$STACK_HEAD" \
       "grep -hE '^GPU_MEM=' $STACK_DIR/profiles/default.env 2>/dev/null | tail -1 | cut -d= -f2; \
        sed -n 's/^GPU_MEM=\"\${GPU_MEM:-\([0-9.]*\)}\"/\1/p' $STACK_DIR/scripts/serve.sh" \
       | grep -E '^[0-9.]+$' | head -1)
  [ -n "$gm" ] || { echo "ABORT: 读不到 GPU_MEM(profiles/default.env 和 scripts/serve.sh 都没解析出来)"; exit 1; }
  sshx "$STACK_HEAD" \
    "awk -v u=$gm '/^MemTotal:/{t=\$2} /^MemAvailable:/{a=\$2} \
     END{ tg=t/1048576; ag=a/1048576; need=tg*u; \
          printf \"  可用 %.1f GiB / 需要 %.1f GiB (GPU_MEM=%s of %.1f)\", ag, need, u, tg; \
          if (ag < need) { printf \"  <-- 差 %.2f GiB\n\", need-ag; exit 1 } print \"  OK\" }' /proc/meminfo" \
    || { echo "ABORT: $STACK_HEAD 可用内存不足以按 GPU_MEM=$gm 启动。"
         echo "       查大头: ssh $STACK_HEAD 'ps aux --sort=-rss | head -8'"
         echo "       (2026-09-20 起 S2 上不再有 k3s server —— 那约 1.0 GiB 已经还回来了)"
         echo "       另见 glm53 那栈的 polkitd 膨胀,处理是 sudo systemctl restart polkit。"
         rc=1; }
fi

exit "$rc"
