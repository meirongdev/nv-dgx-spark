#!/usr/bin/env bash
# 取 DeepSeek-V4.1-Flash-1017 的两份输入到**本节点**的 HF cache 布局里:
#   1. Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw @ 45ee5d0f  (39 片,196 GiB)
#   2. deepseek-ai/DeepSeek-V4.1-Flash-1017 @ 1bae0e10 的 Engram 两张表
#      (model-00047/00048 + config.json + index,189 GiB)
# 这两个 revision 就是上游 scripts/config.sh 钉的那两个。
#
# 为什么不让上游 prepare.sh 自己下:
#   - 节点到不了 huggingface.co(gotcha #8);hf-mirror 对大 LFS 会 reset
#     (docs/china-network-mirrors-cn.md)。大文件只能走 ModelScope。
#   - ModelScope 不带 HF 的 commit SHA,所以「把目录命名成 45ee5d0f…」只是**断言**。
#     本脚本用 weights-manifest.json(2026-11-14 从 HF API 取的那两个 revision 的逐文件
#     size + LFS sha256 + git blob oid)把断言变成检查:**每一片都做 sha256**,
#     小文件做 git blob sha1。对不上就硬失败。
#   - 小文件(config / tokenizer / index / chat_template …)从 hf-mirror 取 ——
#     小文件它不 reset,而且 ModelScope 的 LICENSE/.gitattributes 与 HF 不同字节。
#
# 落盘形态:snapshots/<rev>/ 下是**真实文件**,不是指向 blobs/ 的符号链接(gotcha #6;
# 上游 prepare.sh 一律用 find -L / stat -L,真实文件同样通过)。refs/main 显式写死。
# 之后上游 prepare.sh 里的 `hf download` 到不了 HF,会走它自己的
# "could not reach Hugging Face; using the snapshot already here" 分支。
#
# 幂等:modelscope 自带续传;已校验过的文件不重算 sha256(戳在 $STAGING/<key>/.verified/,
# 不放进 snapshot —— 上游 prepare.sh 用 find -L 清点 snapshot 里的每个文件)。
# 在 tmux 里跑(SSH 走 DERP 中继,会掉线)。
set -uo pipefail

MS_BIN="${MS_BIN:-/home/admin/modelscope-venv/bin/modelscope}"
HF_HUB="${HF_HUB:-/home/admin/.cache/huggingface/hub}"
MANIFEST="${MANIFEST:-/home/admin/dsv41-weights-manifest.json}"
HF_SMALL_ENDPOINT="${HF_SMALL_ENDPOINT:-https://hf-mirror.com}"
STAGING="${STAGING:-/home/admin/.cache/dsv41-staging}"
ATTEMPTS="${ATTEMPTS:-500}"
WORKERS="${WORKERS:-8}"
ONLY="${ONLY:-model engram}"     # 只取其中一份:ONLY=engram

[ -x "$MS_BIN" ]   || { echo "FAIL: 找不到 modelscope CLI: $MS_BIN"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: 缺少校验清单 $MANIFEST(从控制机 scp stacks/dsv41/weights-manifest.json)"; exit 1; }

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$MANIFEST" "$1" "$2"; }

echo "=== DeepSeek-V4.1-Flash-1017 权重获取 @ $(hostname) $(date '+%F %T') ==="

for key in $ONLY; do
    repo=$(field "$key" repo); rev=$(field "$key" revision)
    cache="$HF_HUB/models--${repo//\//--}"
    snap="$cache/snapshots/$rev"
    stage="$STAGING/$key"
    echo; echo "--- [$key] $repo @ ${rev:0:8} → $snap"
    mkdir -p "$snap" "$stage" "$cache/refs" || exit 1
    printf '%s' "$rev" > "$cache/refs/main"

    # 大文件:清单里有 sha256 的(LFS)
    mapfile -t big < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))[sys.argv[2]]["files"]; [print(k) for k,v in sorted(d.items()) if v["sha256"]]' "$MANIFEST" "$key")
    todo=()
    for f in "${big[@]}"; do [ -f "$snap/$f" ] || todo+=("$f"); done
    echo "[$key] LFS 文件 ${#big[@]} 个,已就位 $(( ${#big[@]} - ${#todo[@]} )),待下 ${#todo[@]}"
    if (( ${#todo[@]} )); then
        for ((i = 1; i <= ATTEMPTS; i++)); do
            if "$MS_BIN" download --model "$repo" --local_dir "$stage" --max-workers "$WORKERS" --include "${todo[@]}"; then
                echo "[$key][$i] modelscope download OK"; break
            fi
            echo "[$key][$i/$ATTEMPTS] 断开,$(du -sh "$stage" 2>/dev/null | cut -f1) 已落盘,5s 后续传"; sleep 5
        done
        (( i <= ATTEMPTS )) || { echo "FAIL: [$key] $ATTEMPTS 轮后仍未取齐"; exit 1; }
    fi

    # 校验:size + sha256,并行;过了才 mv 进 snapshot(同一文件系统,rename)
    python3 -I - "$MANIFEST" "$key" "$stage" "$snap" "$WORKERS" <<'PY' || exit 1
import hashlib, json, os, sys
from concurrent.futures import ThreadPoolExecutor
manifest, key, stage, snap, workers = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
files = {k: v for k, v in json.load(open(manifest))[key]["files"].items() if v["sha256"]}
def check(name):
    want = files[name]
    dst = os.path.join(snap, name)
    stamp = os.path.join(stage, ".verified", name + ".sha256")
    if os.path.isfile(dst) and os.path.isfile(stamp) and open(stamp).read().strip() == want["sha256"]:
        return name, "ok (cached)"
    src = dst if os.path.isfile(dst) else os.path.join(stage, name)
    if not os.path.isfile(src):
        return name, "MISSING"
    size = os.path.getsize(src)
    if size != want["size"]:
        return name, f"SIZE {size} != {want['size']}"
    h = hashlib.sha256()
    with open(src, "rb") as fh:
        for chunk in iter(lambda: fh.read(64 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != want["sha256"]:
        return name, f"SHA256 {h.hexdigest()[:16]} != {want['sha256'][:16]}"
    if src != dst:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(src, dst)
    os.makedirs(os.path.dirname(stamp), exist_ok=True)
    open(stamp, "w").write(want["sha256"] + "\n")
    return name, "ok"
bad = 0
with ThreadPoolExecutor(workers) as ex:
    for name, res in ex.map(check, sorted(files)):
        if not res.startswith("ok"):
            bad += 1
            print(f"  !! {name}: {res}")
print(f"[{key}] LFS 校验: {len(files) - bad}/{len(files)} 通过 (size + sha256)")
sys.exit(1 if bad else 0)
PY

    # 小文件:hf-mirror,按 git blob sha1 校验
    python3 -I - "$MANIFEST" "$key" "$snap" "$HF_SMALL_ENDPOINT" <<'PY' || exit 1
import hashlib, json, os, sys, urllib.request, urllib.parse
manifest, key, snap, endpoint = sys.argv[1:5]
d = json.load(open(manifest))[key]
files = {k: v for k, v in d["files"].items() if not v["sha256"]}
def git_oid(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
bad = 0
for name, want in sorted(files.items()):
    dst = os.path.join(snap, name)
    if os.path.isfile(dst) and git_oid(open(dst, "rb").read()) == want["oid"]:
        continue
    # hf-mirror 按钉住的 revision 取;它很慢(tokenizer.json 6.4 MB 卡了 5 分钟+)时退到 ModelScope 的
    # master —— 两者都按 HF 的 git blob oid 校验,所以来源不影响正确性,只有字节对才收。
    urls = [f"{endpoint}/{d['repo']}/resolve/{d['revision']}/{urllib.parse.quote(name)}",
            f"https://modelscope.cn/models/{d['repo']}/resolve/master/{urllib.parse.quote(name)}"]
    data, err = None, None
    for url in urls:
        for _ in range(3):
            try:
                # hf-mirror 对 UA "Python-urllib/x" 一律 403(2026-11-14 实测;curl 的 UA 则 200)
                rq = urllib.request.Request(url, headers={"User-Agent": "dsv41-fetch/1.0"})
                data = urllib.request.urlopen(rq, timeout=120).read()
                if git_oid(data) == want["oid"]:
                    break
                err, data = f"git oid mismatch from {url}", None
            except Exception as e:
                err = e
        if data is not None:
            break
    if data is None:
        bad += 1
        print(f"  !! {name}: {err}")
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst + ".part", "wb") as fh:
        fh.write(data)
    os.replace(dst + ".part", dst)
print(f"[{key}] 小文件: {len(files) - bad}/{len(files)} 通过 (git blob sha1)")
sys.exit(1 if bad else 0)
PY
    echo "[$key] DONE: $(du -shL "$snap" | cut -f1) in $snap"
done

echo; echo "=== 全部通过 $(date '+%F %T') ==="
