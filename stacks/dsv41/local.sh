# 上游 MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks 的 scripts/local.sh —— 本仓库的副本是事实源,
# stacks/dsv41/preflight.sh 比对它与 S1:/home/admin/dsv41-recipe/scripts/local.sh。
# 上游 scripts/config.sh 以 bash source 它;环境变量优先于这里。
#
# 与上游默认值的偏离,只有下面这几条:

# worker = S2,走 200G 内网线(head→worker 免密 ssh 已在;路由 enp1s0f0np0)。
# FABRIC_PEER 不用设:WORKER 本身就在线缆那一侧。
WORKER=admin@192.168.200.102

# :8000 —— 2026-11-14 用户选定:沿用旧主力的端口,客户端 URL 不变,只改模型名 +
# thinking 参数。上游默认 8888(与 glm53 / qwen38 / qwen38un 重号,这里避开)。
# SERVED_NAME 保持上游默认 DeepSeek-V4.1-Flash-1017。
PORT=8000

# 上游 README:"on a head that carries other software, 524288 is the practical limit"。
# S1 带着桌面(gnome-shell/Xorg)、spark-dashboard、node-exporter、8 个登录会话。
# KV 本身很小(上游:262K ≈ 0.5 GiB,1M ≈ 1.8 GiB / rank),这一档买的是 head 的余量。
# 2026-11-15 用户定为 262144(原 524288):
#   · 与网关兜底 Ornith 的 262k 对齐 —— 超过 262k 的请求 DGX 一出错兜底也接不住;
#   · prefill 工作区从 MemAvailable 里出,而 S1 加载后只剩 ~7 GiB、memguard 线 2.5 GiB,
#     满窗 prefill 的内存低点没测过;实测 ~2,300 tok/s,262k 满窗 prefill ≈ 2 min,
#     512k ≈ 4 min 会撞客户端 300 s 超时。
#   · Qwen Code 0.27.0 在 262144 下实测正常(没有旧版那种 ctxWin-384000 钳成 0 的问题)。
CONTEXT=262144

# hf CLI 装在 ~/.local/bin(huggingface_hub 1.10.1),非登录 shell 的 PATH 里没有;
# prepare.sh 没有它会直接 die(即使权重已经在本地 —— 它到不了 HF 会走 "using the
# snapshot already here" 分支,但前提是命令存在)。
export PATH="$HOME/.local/bin:$PATH"
