#!/usr/bin/env bash
# fndgx 启动包装 —— 由 adapter-docker.sh scp 到 S2 的 /home/admin/fndgx-launch.sh。
#
# ⚠️ 所有定制**固定在这个脚本里**,不穿 make → ssh → tmux → bash 四层引号。
#    2026-09-19 实测:带空格的变量会在中途断掉,而失败信息完全不提这件事。
#    这里尤其重要 —— 上游 serve.sh 的 EXTRA/-cc.splitting_ops 本来就全是方括号
#    和逗号,再套一层引号必断。
#
# 它只是调上游的 ./flash serve,不重写上游的任何逻辑:上游改了配方,我们跟着走。
set -euo pipefail

REPO=/home/admin/qwen38-flash-dgx
# native = hybrid + **原生 262144**(不开 YaRN)+ MTP=2 + 确定性 top-k。
# 2026-09-20 从 default(YaRN 500k)换过来:降上下文**不会**换来更大的 KV 池,
# 但 maximum concurrency 从 1.00x 变成 1.90x。详见 recipe.yaml。
PROFILE=native

# ⚠️ MODEL 必须显式给。上游 2026-09-14 起默认 nvidia/...,而 S2 上只有 RadixArk
#    那一份(huggingface.co 从节点上连不通,换不了)。不给的话 serve.sh 会去找
#    一个不存在的目录然后退出 —— 这一条倒是会响,不是静默的。
MODEL=RadixArk/Qwen3.8-Flash-Next-NVFP4

# vLLM 编译图 + FlashInfer JIT 跨重启复用(省约 80 秒启动)。容器每次重建,
# 不落盘的话每次都重编。
COMPILE_CACHE=$REPO/.compile-cache

# --- SEQS:32 试过,实测无收益,已退回上游默认 8(2026-09-20)-----------------
# ⚠️ **这是一个试过并否决的值,不是一个待办。** 记在这里是为了别人不再试一遍。
#
# 当初的假设:并发聚合在 c8 封顶 113 tok/s,而封顶的是 SEQS=8 —— 依据是上游
# README 引的 @jschmied 梯子一路涨到 c48=266.8。**那是外推,不是预期**:
# 那条梯子是**另一套配置**(无投机解码、用 vLLM 原生 PLE CPU offload、8k 上下文),
# 上游自己在表头标注了。上游对本配方(hybrid + MTP=2 + RadixArk)真正发布过的
# 并发数据**只有一个点**:c4 每流 21.6 tok/s。
#
# 实测(SEQS=32,同一套 concurrency.py,请求形状逐字相同):
#   c1 +0.1%   c2 +0.1%   c4 +1.9%   c6 -2.7%   c8 -7.0%
#   (基线 44.5 / 67.8 / 92.1 / 93.8 / 112.4,benchmarks/fndgx-2026-09-20)
#   c1/c2 复现到 +0.1% 说明 harness 在低并发是稳的,c8 的 -7% 大于该噪声,未解释。
# 启动期:KV 池 498,218 vs 496,770 tokens —— **SEQS 不吃 KV 池**,这条是确定的。
#
# ⚠️ **只测到 c8**(按要求封顶)。所以结论的准确说法是「c8 及以下无收益」,
#    **不是**「SEQS 对更高并发无用」—— c8 及以下两种配置都不排队,本来就该一样。
#    c12 以上仍然没测过。数据:benchmarks/fndgx-seqs-2026-09-20/。
SEQS=8
# PLE mmap 的 gather/缺页计数器默认不导出(上游 PR #19 的 opt-in)。**保留打开**:
# 它不动任何配方参数,只多导出 8 条 vllm:ple_mmap_* —— 而在打开它之前,
# 「页缓存是不是瓶颈」这个问题本仓库没有任何指标能回答。
# 第一组数就推翻了我们自己的猜测:PLE 查表只占引擎墙钟的 9-12%。
PROM_MULTIPROC=1
# ⚠️ **仍然没动** --long-prefill-token-threshold:它是 TTFT/响应性的滑块
#    (上游测 1024 会让单流 8k prefill -36%),与吞吐是两件事,要单独评估。

cd "$REPO"
mkdir -p "$COMPILE_CACHE/vllm" "$COMPILE_CACHE/flashinfer"

echo "=== fndgx: ./flash serve $PROFILE (MODEL=$MODEL SEQS=$SEQS PROM_MULTIPROC=$PROM_MULTIPROC) ==="
./flash serve "$PROFILE" "MODEL=$MODEL" "COMPILE_CACHE=$COMPILE_CACHE" "SEQS=$SEQS" "PROM_MULTIPROC=$PROM_MULTIPROC"

# serve.sh 自己已经在 8 秒后验过容器没有立刻死掉。这里再等一次真正就绪,
# 让 `make run STACK=fndgx` 的 tmux 日志能停在一个确定的结论上,而不是
# 停在「容器 Up」这种和「正在 OOM 退出」同形的状态。
echo "=== 等待 API 就绪(首启约 5 分钟)==="
./flash wait
echo "=== fndgx 就绪 ==="
curl -s "http://localhost:18300/v1/models" | python3 -m json.tool | head -8
free -h | head -2
