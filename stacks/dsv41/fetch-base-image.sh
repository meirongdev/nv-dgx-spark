#!/usr/bin/env bash
# 把 NGC 的 nvcr.io/nvidia/pytorch:26.07-py3 (arm64) 弄进本节点的 docker —— 上游 zig/Dockerfile 的 FROM。
#
# 为什么不 `docker pull`:节点直连 nvcr.io 被 reset(2026-11-14 S2 实测:
# `read tcp …->52.88.77.63:443: connection reset by peer`,连 token 都拿不到),
# 而 docker daemon 的 registry-mirrors 只管 docker.io;给 dockerd 配代理要重启它,
# 会弹掉正在跑的模型容器。所以走节点上 xray 的 SOCKS(127.0.0.1:10808)按 blob 拉,
# 每个 blob 校验 sha256,拼成 docker-archive 喂给 `docker load`,最后核对
# image ID == registry 的 config digest。路线同 memory「china-docker-registry-blocked」。
#
# 幂等:已校验的 blob 不重下;.part 断点续传(curl -C -);每次重试都重新取 token。
# 用法(节点上,tmux 里):  ./fetch-base-image.sh   →  docker images | grep pytorch
set -uo pipefail

REPO="${REPO:-nvidia/pytorch}"
TAG="${TAG:-26.07-py3}"
ARCH="${ARCH:-arm64}"
PROXY="${PROXY:---socks5-hostname 127.0.0.1:10808}"
OUT="${OUT:-/home/admin/.cache/dsv41-staging/ngc-${REPO//\//-}-$TAG}"
JOBS="${JOBS:-6}"
REG=https://nvcr.io

mkdir -p "$OUT/blobs"
cd "$OUT" || exit 1

token() { curl -s $PROXY -m 30 "$REG/proxy_auth?scope=repository:$REPO:pull" |
          python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])'; }
get() {  # get <path> <accept> <out>
    local i
    for i in 1 2 3 4 5 6 7 8; do
        curl -sfL $PROXY -m 60 -H "Authorization: Bearer $(token)" -H "Accept: $2" "$REG/v2/$REPO/$1" -o "$3" && return 0
        sleep 3
    done
    return 1
}

get "manifests/$TAG" "application/vnd.oci.image.index.v1+json" index.json || { echo "FAIL: index"; exit 1; }
mdig=$(python3 -I -c 'import json,sys; print([m["digest"] for m in json.load(open("index.json"))["manifests"] if m["platform"]["architecture"]==sys.argv[1]][0])' "$ARCH")
get "manifests/$mdig" "application/vnd.oci.image.manifest.v1+json" manifest.oci.json || { echo "FAIL: manifest"; exit 1; }
cdig=$(python3 -I -c 'import json; print(json.load(open("manifest.oci.json"))["config"]["digest"])')
get "blobs/$cdig" "*/*" config.json || { echo "FAIL: config"; exit 1; }
[ "sha256:$(sha256sum config.json | cut -d' ' -f1)" = "$cdig" ] || { echo "FAIL: config digest mismatch"; exit 1; }
echo "$REPO:$TAG $ARCH manifest $mdig config $cdig"

# 已在本机?直接结束
if [ "$(docker image inspect -f '{{.Id}}' "nvcr.io/$REPO:$TAG" 2>/dev/null)" = "$cdig" ]; then
    echo "already loaded: nvcr.io/$REPO:$TAG = $cdig"; exit 0
fi

python3 -I -c 'import json; [print(l["digest"], l["size"]) for l in json.load(open("manifest.oci.json"))["layers"]]' > layers.txt
total=$(awk '{s+=$2} END {printf "%.2f", s/2^30}' layers.txt)
echo "$(wc -l < layers.txt) layers, $total GiB compressed → $OUT/blobs (jobs=$JOBS)"

fetch_one() {  # <sha256:hex> <size>
    local dig=$1 size=$2 hex=${1#sha256:} i
    local f="blobs/$hex" tok
    [ -f "$f" ] && return 0
    for i in $(seq 1 60); do
        tok=$(token) || { sleep 5; continue; }
        curl -sfL $PROXY --connect-timeout 30 --speed-limit 20000 --speed-time 60 -C - \
             -H "Authorization: Bearer $tok" "$REG/v2/$REPO/blobs/$dig" -o "$f.part"
        if [ -f "$f.part" ] && [ "$(stat -c %s "$f.part")" = "$size" ]; then
            if [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$hex" ]; then
                mv "$f.part" "$f"; echo "  ok   ${hex:0:12} $size"; return 0
            fi
            echo "  !!   ${hex:0:12} sha256 mismatch, restarting"; rm -f "$f.part"
        elif [ -f "$f.part" ] && [ "$(stat -c %s "$f.part")" -gt "$size" ]; then
            rm -f "$f.part"   # 401/错误页被写进了 blob,续传永远过不了校验
        fi
        sleep 3
    done
    echo "  FAIL ${hex:0:12} after 60 tries"; return 1
}
export -f fetch_one token; export PROXY REG REPO
xargs -P "$JOBS" -L 1 bash -c 'fetch_one "$0" "$1"' < layers.txt
missing=$(while read -r d s; do [ -f "blobs/${d#sha256:}" ] || echo "$d"; done < layers.txt | wc -l)
[ "$missing" = 0 ] || { echo "FAIL: $missing layers still missing — rerun"; exit 1; }

# docker-archive:manifest.json 列出全部层(压缩 tar,docker load 自己解压)
python3 -I - "$REPO" "$TAG" <<'PY'
import json, sys
repo, tag = sys.argv[1], sys.argv[2]
layers = ["blobs/" + l.split()[0].split(":")[1] for l in open("layers.txt")]
json.dump([{"Config": "config.json", "RepoTags": [f"nvcr.io/{repo}:{tag}"], "Layers": layers}], open("manifest.json", "w"))
PY
echo "docker load …"
tar -cf - manifest.json config.json blobs | docker load || { echo "FAIL: docker load"; exit 1; }
got=$(docker image inspect -f '{{.Id}}' "nvcr.io/$REPO:$TAG")
[ "$got" = "$cdig" ] || { echo "FAIL: loaded image ID $got != registry config $cdig"; exit 1; }
echo "DONE: nvcr.io/$REPO:$TAG = $got"
