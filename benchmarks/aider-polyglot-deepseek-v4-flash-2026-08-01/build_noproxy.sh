#!/usr/bin/env bash
# Build with ~/.docker/config.json moved aside so the docker CLI cannot inject
# the xray proxy into the build env. Measured: 18 KB/s through the proxy vs
# 1.6 MB/s direct to the same Tsinghua mirror. Client-side config only -- the
# daemon is not restarted, so the running vLLM container is untouched.
set -u
CFG=~/.docker/config.json
BAK=~/.docker/config.json.bench-bak
restore() { [ -f "$BAK" ] && mv -f "$BAK" "$CFG" && echo "restored $CFG"; }
trap restore EXIT INT TERM

[ -f "$CFG" ] && cp "$CFG" "$BAK" && python3 -c "
import json,sys
p=
d=json.load(open(p))
d.pop(proxies,None)
json.dump(d,open(p,w))
print(proxies removed from client config for this build)
"
cd /home/admin/aider-bench/aider
docker build --file benchmark/Dockerfile.cn-arm -t aider-benchmark . 2>&1
echo "BUILD EXIT: $?"
