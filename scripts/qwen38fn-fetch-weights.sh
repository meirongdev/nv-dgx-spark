#!/usr/bin/env bash
# 阶段 1:把 Qwen3.8-Flash-Next NVFP4 权重取到两台节点上。
#
# 路由(2026-09-02 实测):
#   - huggingface.co 从 S1 **不通**(curl 000,v2rayN 没在跑);
#   - **hf-mirror.com 通**(HTTP 200),且 RadixArk/Qwen3.8-Flash-Next-NVFP4
#     是公开仓库(gated=false),**不需要 HF token**;
#   - ModelScope 上只有 Inferact 那份**独立量化**,与本方案依赖的
#     model-plefp8-*.safetensors 分片布局未经核对 —— 不要拿它替代。
#
# 策略:只在 S1 下载一次,再走 200G 内网线(192.168.200.102)复制到 S2,
# 避免同一份 126 GiB 走两遍外网。
#
# 落盘为**普通目录**(不是 HF cache 的 symlink 布局)—— manifests 里 serve 的是
# 本地路径,且 gotcha #6 就是被 HF cache 的绝对符号链接咬的。
#
# 幂等:snapshot_download 自带断点续传,rsync 也是增量的,随时可重跑。
# 建议在 tmux 里跑(SSH 走 DERP 中继,会掉线)。
set -uo pipefail

REPO="${REPO:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
DEST="${DEST:-/home/admin/.cache/huggingface/hub/Qwen3.8-Flash-Next-NVFP4}"
PEER="${PEER:-192.168.200.102}"
WORKERS="${WORKERS:-4}"          # hf-mirror 并发越高越容易被掐,4 比 8 稳
ATTEMPTS="${ATTEMPTS:-500}"      # 断开重试轮数;每轮都在前一轮基础上续传
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

echo "=== fetch weights ==="
echo "repo=$REPO"
echo "dest=$DEST"
echo "endpoint=$HF_ENDPOINT  workers=$WORKERS  peer=$PEER"
echo "start=$(date '+%F %T')"

python3 - "$REPO" "$DEST" "$WORKERS" "$ATTEMPTS" <<'PY'
import os, pathlib, sys, time
from huggingface_hub import snapshot_download

repo, dest, workers, attempts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

# ⚠️ hf-mirror.com 在 126 GiB 这个量级上**一定**会断:2026-09-02 首次运行 8 并发
# 跑到第 11 个文件就 httpx.RemoteProtocolError("Server disconnected without
# sending a response")。它不是错误配置,是镜像站的常态。
# 所以这里必须是「断了就续、续到齐为止」的循环,而不是一次性调用 ——
# snapshot_download 本身是断点续传的,每一轮都在前一轮的基础上推进。
def done_count():
    d = pathlib.Path(dest)
    if not d.exists():
        return 0
    # .incomplete 是 hf_hub 的半截文件,不算数
    return sum(1 for f in d.rglob("*") if f.is_file() and not f.name.endswith(".incomplete"))

t0 = time.time()
for i in range(1, attempts + 1):
    before = done_count()
    try:
        p = snapshot_download(repo_id=repo, local_dir=dest, max_workers=workers)
        print(f"\n[{i}] snapshot_download OK -> {p}  (总耗时 {time.time()-t0:.0f}s)")
        sys.exit(0)
    except KeyboardInterrupt:
        raise
    except Exception as e:
        after = done_count()
        print(f"\n[{i}/{attempts}] 断开: {type(e).__name__}: {str(e)[:160]}")
        print(f"[{i}/{attempts}] 已落盘 {after} 个文件 (本轮 +{after-before}),{time.time()-t0:.0f}s,5s 后续传")
        time.sleep(5)

print(f"FAIL: {attempts} 轮后仍未取齐(已落盘 {done_count()} 个文件)。重跑本脚本继续。")
sys.exit(1)
PY
rc=$?
[ $rc -ne 0 ] && { echo "FAIL: 下载失败 rc=$rc(可直接重跑,断点续传)"; exit $rc; }

echo
echo "=== 本地校验 ==="
n_all=$(find "$DEST" -type f | wc -l)
n_st=$(find "$DEST" -name '*.safetensors' | wc -l)
n_ple=$(find "$DEST" -name 'model-plefp8-*.safetensors' | wc -l)
size=$(du -sh "$DEST" | cut -f1)
echo "files=$n_all  safetensors=$n_st  plefp8=$n_ple  size=$size"

# 期望值来自 hf-mirror 的 API 清单(2026-09-02):206 safetensors,其中
# 192 expert(NVFP4) + 10 plefp8 + 4 bf16。plefp8 缺一片 = PLE 补丁必然失效。
fail=0
[ "$n_st"  -eq 206 ] || { echo "!! safetensors 应为 206,实际 $n_st"; fail=1; }
[ "$n_ple" -eq 10 ]  || { echo "!! model-plefp8-* 应为 10,实际 $n_ple"; fail=1; }
[ -f "$DEST/config.json" ] || { echo "!! 缺 config.json"; fail=1; }
[ -f "$DEST/hf_quant_config.json" ] || { echo "!! 缺 hf_quant_config.json"; fail=1; }
[ $fail -ne 0 ] && { echo "FAIL: 清单不完整,重跑本脚本续传"; exit 1; }
echo "本地校验 PASS"

echo
echo "=== 同步到 S2 ($PEER,走 200G 内网线) ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" "mkdir -p '$DEST'" || exit 1
rsync -a --info=progress2 --partial \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$DEST/" "$PEER:$DEST/" || { echo "FAIL: rsync 失败(可重跑)"; exit 1; }

echo
echo "=== S2 校验 ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" "
  n_st=\$(find '$DEST' -name '*.safetensors' | wc -l)
  n_ple=\$(find '$DEST' -name 'model-plefp8-*.safetensors' | wc -l)
  echo \"S2: safetensors=\$n_st plefp8=\$n_ple size=\$(du -sh '$DEST' | cut -f1)\"
  [ \"\$n_st\" -eq 206 ] && [ \"\$n_ple\" -eq 10 ] || { echo '!! S2 清单不完整'; exit 1; }
" || exit 1

echo
echo "=== DONE $(date '+%F %T') ==="
echo "下一步: make qwen38fn-preflight  (会同时检查镜像是否已导入 containerd)"
