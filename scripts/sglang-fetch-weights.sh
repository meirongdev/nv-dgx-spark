#!/usr/bin/env bash
# 取 Qwen3.8-27B-Uncensored NVFP4(主)+ DFlash2(草稿)到 S1。
#
# 两份权重**落盘布局不同**,是有原因的:
#
#   草稿 → HF cache 布局 (${SGLANG_DIR}/.cache/huggingface/hub/models--…/snapshots/<rev>)
#          因为上游 start-dflash.sh 的 snapshot_present() 就是按这个路径查的,
#          放别处它会以为没缓存、再去容器里下一遍(而容器没有 hf-mirror 配置)。
#   主模型 → **普通目录** /home/admin/models/…
#          上游默认把 TARGET_PATH 当 HF repo id 传给 SGLang,由容器现下。
#          本仓库不走那条路(gotcha #6:HF cache 的绝对符号链接会在容器里炸),
#          改成预下到普通目录 + DF_EXTRA="--model-path <本地目录>" 覆盖。
#          覆盖能生效是因为 EXTRA_ARGS 里 DF_EXTRA 追加在最后,argparse last-wins。
#
# 源:**hf-mirror + token**。HF 直连在 DGX 上不通;主权重是 gated(auto),
# 需要账号先在模型页点过 "Agree and access repository",再配 HF_TOKEN。
# ⚠️ hf-mirror 在 20 GiB 量级上**一定会断**(docs/china-network-mirrors-cn.md),
#    所以这里是「断了就续、续到齐为止」的循环,不是一次性调用。
#
# 幂等:snapshot_download 自带断点续传,随时可重跑。建议放 tmux。
set -uo pipefail

SGLANG_DIR="${SGLANG_DIR:-/home/admin/qwen38-sglang}"
HF_CACHE="${HF_CACHE:-$SGLANG_DIR/.cache/huggingface/hub}"
MODELS_DIR="${MODELS_DIR:-/home/admin/models}"

MAIN_REPO="${MAIN_REPO:-orcarouter/Qwen3.8-27B-Uncensored-NVFP4}"
MAIN_REV="${MAIN_REV:-96d4d0b66d943149}"        # 见 scripts/sglang-manifest-*.json
MAIN_DEST="${MAIN_DEST:-$MODELS_DIR/Qwen3.8-27B-Uncensored-NVFP4}"

DRAFT_REPO="${DRAFT_REPO:-z-lab/Qwen3.8-27B-DFlash2}"
DRAFT_REV="${DRAFT_REV:-50307d4c4cde6860d4eee73e2547cd786fe8e8a4}"

MANIFEST_DIR="${MANIFEST_DIR:-/home/admin}"
ATTEMPTS="${ATTEMPTS:-500}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
[ -z "${HF_TOKEN:-}" ] && [ -f /home/admin/.hf_token ] && HF_TOKEN="$(cat /home/admin/.hf_token)"
export HF_TOKEN

echo "=== SGLang 权重获取 ==="
echo "main   = $MAIN_REPO  -> $MAIN_DEST  (普通目录)"
echo "draft  = $DRAFT_REPO @ ${DRAFT_REV:0:12}  -> $HF_CACHE  (HF cache 布局)"
echo "源     = $HF_ENDPOINT   token=$([ -n "${HF_TOKEN:-}" ] && echo 已配置 || echo 缺失)"
echo "start  = $(date '+%F %T')"
[ -n "${HF_TOKEN:-}" ] || { echo "FAIL: 没有 HF_TOKEN,gated 仓库下不了"; exit 1; }

mkdir -p "$HF_CACHE" "$MODELS_DIR"

# $1=repo $2=revision $3=mode(local_dir|cache) $4=dest
fetch() {
  HF_HUB_ENABLE_HF_TRANSFER=0 python3 - "$1" "$2" "$3" "$4" "$ATTEMPTS" <<'PY'
import os, pathlib, sys, time
from huggingface_hub import snapshot_download

repo, rev, mode, dest, attempts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])

def done():
    d = pathlib.Path(dest)
    if not d.exists():
        return 0
    return sum(1 for f in d.rglob("*") if f.is_file() and not f.name.endswith(".incomplete"))

kw = dict(repo_id=repo, max_workers=4)
if rev:
    kw["revision"] = rev
if mode == "local_dir":
    kw["local_dir"] = dest
else:
    kw["cache_dir"] = dest

t0 = time.time()
for i in range(1, attempts + 1):
    before = done()
    try:
        p = snapshot_download(**kw)
        print(f"[{i}] OK -> {p}  ({time.time()-t0:.0f}s)")
        sys.exit(0)
    except KeyboardInterrupt:
        raise
    except Exception as e:
        after = done()
        print(f"[{i}/{attempts}] 断开 {type(e).__name__}: {str(e)[:140]}")
        print(f"[{i}/{attempts}] 已落盘 {after} 个文件(本轮 +{after-before}),{time.time()-t0:.0f}s,5s 后续传")
        time.sleep(5)
print(f"FAIL: {attempts} 轮后仍未取齐")
sys.exit(1)
PY
}

echo
echo "--- 1/2 草稿模型(HF cache 布局) ---"
fetch "$DRAFT_REPO" "$DRAFT_REV" cache "$HF_CACHE" || exit 1

echo
echo "--- 2/2 主模型 ${MAIN_REPO}(普通目录,23 GiB)---"
fetch "$MAIN_REPO" "" local_dir "$MAIN_DEST" || exit 1

# --- 逐文件字节级校验 -------------------------------------------------------
verify() {
  local manifest="$1" root="$2" label="$3"
  [ -f "$manifest" ] || { echo "跳过 $label 校验(缺清单 $manifest)"; return 0; }
  python3 - "$manifest" "$root" "$label" <<'PY'
import json, os, sys
manifest, root, label = sys.argv[1], sys.argv[2], sys.argv[3]
want = json.load(open(manifest))["files"]
crit = {k: v for k, v in want.items()
        if k.endswith((".safetensors", ".json")) or k in ("merges.txt", "vocab.json", "recipe.yaml")}
bad, missing, aux = [], [], []
for name, size in sorted(want.items()):
    p = os.path.join(root, name)
    if not os.path.isfile(p):
        (missing if name in crit else aux).append(name); continue
    if name in crit and os.path.getsize(p) != size:
        bad.append((name, size, os.path.getsize(p)))
print(f"{label}: 关键文件 {len(crit)},缺 {len(missing)},大小不符 {len(bad)}"
      + (f",辅助缺 {len(aux)}(不致命)" if aux else ""))
for n, w, g in bad[:8]: print(f"  !! {n}: 期望 {w} 实际 {g}")
for n in missing[:8]: print(f"  !! 缺 {n}")
sys.exit(1 if (missing or bad) else 0)
PY
}

# refs/main:snapshot_download 按 **commit SHA** 下载时**不会**写 refs/,而离线模式
# (HF_HUB_OFFLINE=1)下 transformers 解析的是 `main` → 找不到 → 报
# "couldn't connect to huggingface.co ... and couldn't find them in the cached files",
# 错误信息完全不提缺的是 refs/main。2026-09-19 实测栽在这里。
DRAFT_BASE="$HF_CACHE/models--${DRAFT_REPO//\//--}"
if [ -d "$DRAFT_BASE/snapshots/$DRAFT_REV" ]; then
  mkdir -p "$DRAFT_BASE/refs"
  printf '%s' "$DRAFT_REV" > "$DRAFT_BASE/refs/main"
  echo "wrote refs/main -> ${DRAFT_REV:0:12}"
fi

echo
echo "=== 校验 ==="
verify "$MANIFEST_DIR/sglang-manifest-orcarouter_Qwen3.8-27B-Uncensored-NVFP4.json" "$MAIN_DEST" main || exit 1
DRAFT_SNAP="$HF_CACHE/models--${DRAFT_REPO//\//--}/snapshots/$DRAFT_REV"
[ -d "$DRAFT_SNAP" ] || { echo "FAIL: 草稿 snapshot 不在 $DRAFT_SNAP —— start-dflash.sh 会以为没缓存"; exit 1; }
verify "$MANIFEST_DIR/sglang-manifest-z-lab_Qwen3.8-27B-DFlash2.json" "$DRAFT_SNAP" draft || exit 1

echo
echo "=== DONE $(date '+%F %T') ==="
echo "main  : $MAIN_DEST  ($(du -sh "$MAIN_DEST" | cut -f1))"
echo "draft : $DRAFT_SNAP  ($(du -sh "$DRAFT_SNAP" | cut -f1))"
echo
echo "下一步: make glm53-stop && make qwen38un-run"
