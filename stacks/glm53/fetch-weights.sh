#!/usr/bin/env bash
# 取 GLM-5.3-Flash EXL3 (4bpw) 权重 + DFlash2 草稿模型到两台节点。
#
# 与 qwen38fn-fetch-weights.sh 的两点关键差异:
#
# 1. **落盘必须是 HF cache 布局**,不是普通目录。
#    上游 start.sh 用 `$MODEL_PATH/refs/main` → `snapshots/<hash>` 解析模型路径
#    (resolve_model_dir / require_model_snapshot),给它一个平铺目录它会 die。
#    但 **snapshots/<hash>/ 下放的是真实文件,不是指向 blobs/ 的符号链接** ——
#    gotcha #6 就是被 HF cache 的绝对符号链接咬的,而 count_shards 用的是
#    `find -L ... -type f`,真实文件同样通过。
#
# 2. **源是 ModelScope,不是 HF/hf-mirror。**
#    两台节点都**没有装 hf CLI**(2026-09-19 实测),所以 start.sh 自己的
#    download_weights() 走不通;docs/china-network-mirrors-cn.md 也明确写了
#    hf-mirror 对大 safetensors 会 connection reset,不要用它下大权重。
#
# ⚠️ **ModelScope 是镜像,不携带 HF 的 commit SHA。**
#    我们是靠「把目录命名成 25a44fdb…」来满足 start.sh 的 MODEL_REVISION 钉子的
#    —— 这一步本身是**断言**,不是证明。所以本脚本用 glm53-weights-manifest.json
#    (2026-09-19 从 HF API 取的该 revision 逐文件字节数)对 120 个分片做
#    **逐文件大小核对**,把断言变成检查。任何一片对不上就硬失败。
#    这是本仓库反复吃亏的那一类静默错配 —— 详见 docs/stack-switch-cn.md §3。
#
# 幂等:modelscope download 自带续传,rsync 增量,随时可重跑。
# 建议在 tmux 里跑(SSH 走 DERP 中继,会掉线)。
set -uo pipefail

MS_BIN="${MS_BIN:-/home/admin/modelscope-venv/bin/modelscope}"
HF_HUB="${HF_HUB:-/home/admin/.cache/huggingface/hub}"

MODEL_REPO="${MODEL_REPO:-Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw}"
MODEL_REV="${MODEL_REV:-25a44fdbf16862a46b7cc9921142c6c81350af2f}"
MODEL_CACHE="models--Mia-AiLab--GLM-5.3-Flash-EXL3-TR3-4bpw"

DFLASH_REPO="${DFLASH_REPO:-incoai/GLM-5.3-Flash-DFlash2}"
DFLASH_REV="${DFLASH_REV:-dc77ff1c99eeb2df044ee3d4f0094eb033fee410}"
DFLASH_CACHE="models--incoai--GLM-5.3-Flash-DFlash2"

MANIFEST="${MANIFEST:-/home/admin/glm53-weights-manifest.json}"
PEER="${PEER:-192.168.200.102}"
ATTEMPTS="${ATTEMPTS:-500}"
EXPECTED_SHARDS=120

MODEL_PATH="$HF_HUB/$MODEL_CACHE"
MODEL_SNAP="$MODEL_PATH/snapshots/$MODEL_REV"
DFLASH_PATH="$HF_HUB/$DFLASH_CACHE"
DFLASH_SNAP="$DFLASH_PATH/snapshots/$DFLASH_REV"

echo "=== GLM-5.3-Flash EXL3 权重获取 ==="
echo "model   = $MODEL_REPO @ $MODEL_REV"
echo "dflash  = $DFLASH_REPO @ $DFLASH_REV"
echo "dest    = $MODEL_SNAP"
echo "peer    = $PEER"
echo "start   = $(date '+%F %T')"

[ -x "$MS_BIN" ] || { echo "FAIL: 找不到 modelscope CLI: $MS_BIN"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: 缺少校验清单 $MANIFEST(用 scp 从控制机送过来)"; exit 1; }

# --- 下载(断了就续,续到齐为止) -------------------------------------------
fetch() {
    local repo="$1" dest="$2" label="$3" i before after
    mkdir -p "$dest" || return 1
    for ((i = 1; i <= ATTEMPTS; i++)); do
        before=$(find "$dest" -type f ! -name '*.incomplete' 2>/dev/null | wc -l)
        if "$MS_BIN" download --model "$repo" --local_dir "$dest"; then
            echo "[$label][$i] download OK"
            return 0
        fi
        after=$(find "$dest" -type f ! -name '*.incomplete' 2>/dev/null | wc -l)
        echo "[$label][$i/$ATTEMPTS] 断开,已落盘 $after 个文件(本轮 +$((after - before))),5s 后续传"
        sleep 5
    done
    echo "FAIL: [$label] $ATTEMPTS 轮后仍未取齐"
    return 1
}

fetch "$MODEL_REPO"  "$MODEL_SNAP"  model  || exit 1
fetch "$DFLASH_REPO" "$DFLASH_SNAP" dflash || exit 1

# refs/main:start.sh 的 ensure_refs_main 会在缺失时自己补,但它挑的是
# `ls -1t` 最新的那个 snapshot —— 目录只有一个时没问题,多一个就会挑错。
# 显式写死,不留给它猜。
mkdir -p "$MODEL_PATH/refs" "$DFLASH_PATH/refs"
printf '%s' "$MODEL_REV"  > "$MODEL_PATH/refs/main"
printf '%s' "$DFLASH_REV" > "$DFLASH_PATH/refs/main"

# --- 逐文件字节级校验(这一步是本脚本存在的理由) ---------------------------
echo
echo "=== 校验:ModelScope 落盘 vs HF revision $MODEL_REV ==="
python3 - "$MANIFEST" "$MODEL_SNAP" "$EXPECTED_SHARDS" <<'PY'
import json, os, sys

manifest, snap, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
want = json.load(open(manifest))["files"]

# 只有分片 + 两个 loader 必需的 sidecar 是致命项。aux 文件(LICENSE/.gitattributes
# /MIRROR.json 之类)ModelScope 镜像不一定带,缺了不影响加载,只告警。
critical = {k: v for k, v in want.items()
            if k.endswith(".safetensors")
            or k in ("config.json", "model.safetensors.index.json")}

bad, missing, aux_missing = [], [], []
for name, size in sorted(want.items()):
    p = os.path.join(snap, name)
    if not os.path.isfile(p):
        (missing if name in critical else aux_missing).append(name)
        continue
    got = os.path.getsize(p)
    if name in critical and got != size:
        bad.append((name, size, got))

shards = sum(1 for n in os.listdir(snap) if n.endswith(".safetensors"))

print(f"分片      : {shards} (期望 {expected})")
print(f"关键文件  : {len(critical)} 项,缺 {len(missing)},大小不符 {len(bad)}")
if aux_missing:
    print(f"辅助文件  : 缺 {len(aux_missing)} 项(不致命): {', '.join(aux_missing[:6])}")

for name, w, g in bad[:10]:
    print(f"  !! 大小不符 {name}: 期望 {w} 实际 {g}")
for name in missing[:10]:
    print(f"  !! 缺失 {name}")

if shards != expected or missing or bad:
    print("\nFAIL: ModelScope 这份与 HF revision 对不上。")
    print("      不要继续 —— 权重不是钉住的那一份,而 start.sh 不会再替你查一遍。")
    sys.exit(1)
print("\n逐文件校验 PASS")
PY
[ $? -ne 0 ] && exit 1

[ -f "$DFLASH_SNAP/config.json" ]       || { echo "FAIL: DFlash2 缺 config.json"; exit 1; }
[ -f "$DFLASH_SNAP/model.safetensors" ] || { echo "FAIL: DFlash2 缺 model.safetensors"; exit 1; }
echo "DFlash2 sidecar PASS  ($(du -sh "$DFLASH_SNAP" | cut -f1))"

# --- 同步到 S2 -------------------------------------------------------------
echo
echo "=== 同步到 S2 ($PEER,走 200G 内网线) ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" \
    "mkdir -p '$MODEL_PATH/refs' '$DFLASH_PATH/refs'" || exit 1
for src in "$MODEL_PATH" "$DFLASH_PATH"; do
    rsync -a --info=progress2 --partial \
        -e "ssh -o StrictHostKeyChecking=no" \
        "$src/" "$PEER:$src/" || { echo "FAIL: rsync $src 失败(可重跑)"; exit 1; }
done

echo
echo "=== S2 校验 ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" "
  n=\$(find '$MODEL_SNAP' -maxdepth 1 -name '*.safetensors' | wc -l)
  echo \"S2: shards=\$n size=\$(du -sh '$MODEL_SNAP' | cut -f1) refs=\$(cat '$MODEL_PATH/refs/main')\"
  [ \"\$n\" -eq $EXPECTED_SHARDS ] || { echo '!! S2 分片不全'; exit 1; }
  [ -f '$DFLASH_SNAP/model.safetensors' ] || { echo '!! S2 缺 DFlash2'; exit 1; }
" || exit 1

echo
echo "=== DONE $(date '+%F %T') ==="
echo "下一步: 拉镜像 (ghcr.m.daocloud.io) + 写 .env,再 ./start.sh"
