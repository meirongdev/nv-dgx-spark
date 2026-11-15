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

# 位置池 = 所有流的占位 + 留着的前缀缓存共用(上游 zig/patches/0008)。不设时 = CONTEXT。
# 2026-11-15 实测(POOL 未设):40 min 57 个真实请求、39 个 > 50K token(/v1/messages 的 agent
# 会话),前缀缓存命中 0%,"kept state … goes stale: a placement needed its room" 50 次 ——
# 262144 个位置只放得下 ~2 个 10 万 token 的会话,互相挤,每轮都从头 prefill(~50 s)。
# 1048576 = 4 倍;单个请求仍止于 CONTEXT。代价(上游):每 rank 每 1M 位置 ~0.9 GiB 主机内存,
# 即比 262144 多 ~0.7 GiB/台;上游 POOL=2M 时 head 空闲 6.76 → 5.71 GiB。用户选定。
# 19:20 再加到 2097152(用户定):8 路后 5 个连接里 2 个 waiting(流没满、等池位),10 min
# 14 次 client-left。1M 时启动行 "compressed planes 890 MiB a rank",2M 预计每台再 +~0.9 GiB;
# 8 路以来 S1 最低 6.09 GiB。退回条件同下:S1 MemAvailable < 3.5 GiB → 回 1048576。
POOL=2097152

# 同时处理的请求数(引擎的 stream 数,上游允许 1–16,默认 4,上游只测了 1–4 路的吞吐;
# 8 路在上游的 gpu_validate / selftest 里跑过正确性)。2026-11-15 用户定为 8:4 路时
# 长 agent 会话占满后短请求排队,20 min 里 8 个 client-left。
# 预期:排队少、每路变慢,合计吞吐涨得有限(每轮最多 16 行,8 路每路 ~2 行,草稿变浅)。
# ⚠️ 8 × (10 万 prompt + 3.2 万 max_tokens) ≈ 1.06M > POOL —— 命中率掉了就加 POOL;
#    S1 MemAvailable < 3.5 GiB 就退回 4。
PARALLEL=8

# hf CLI 装在 ~/.local/bin(huggingface_hub 1.10.1),非登录 shell 的 PATH 里没有;
# prepare.sh 没有它会直接 die(即使权重已经在本地 —— 它到不了 HF 会走 "using the
# snapshot already here" 分支,但前提是命令存在)。
export PATH="$HOME/.local/bin:$PATH"
