#!/usr/bin/env bash
# One A/B arm, run ON THE HEAD (S1) against localhost — the 09-30 lesson: over Tailscale the
# prompt upload rides DERP and inflates TTFT. Same three measurements for every arm:
#   1. ladder.py, thinking off, the 09-28/09-30 request body verbatim (12 levels, c1 → c64)
#   2. ladder.py, thinking on, c1/c2/c4 — closer to how the clients actually call it
#   3. prefill.py, cold, 8K / 32K / 128K, two shots each (first-of-shape + warm), memory sampled on both boxes
# Usage (on S1):  MODEL=<served name> TAG=<arm> bash run-ab.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${MODEL:?missing MODEL}" "${TAG:?missing TAG}"
URL=http://localhost:8000/v1/chat/completions
served=$(curl -s -m 10 http://localhost:8000/v1/models | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"][0]["id"])')
[ "$served" = "$MODEL" ] || { echo "served '$served' != MODEL '$MODEL' — wrong stack"; exit 1; }
mem(){ for h in local 192.168.200.102; do
  if [ $h = local ]; then awk '/MemAvailable/{a=$2}/MemTotal/{t=$2}END{printf "S1 %.2f GiB (%.1f%%)  ", a/1048576, a*100/t}' /proc/meminfo
  else ssh -o BatchMode=yes $h "awk '/MemAvailable/{a=\$2}/MemTotal/{t=\$2}END{printf \"S2 %.2f GiB (%.1f%%)\", a/1048576, a*100/t}' /proc/meminfo"; fi; done; echo; }
echo "### $TAG  $(date '+%F %T %z')  model=$MODEL"; echo -n "mem before: "; mem
URL=$URL MODEL=$MODEL THINK_OFF='{"chat_template_kwargs":{"enable_thinking":false}}' \
  LEVELS="1 2 4 6 8 12 16 20 24 32 48 64" TAG=$TAG-off python3 ladder.py
echo -n "mem after ladder: "; mem
URL=$URL MODEL=$MODEL THINK_OFF='{"chat_template_kwargs":{"enable_thinking":true}}' \
  LEVELS="1 1 2 4" TAG=$TAG-think python3 ladder.py
BASE=http://localhost:8000 MODEL=$MODEL SIZES="8000 32000 128000" NODES="local 192.168.200.102" \
  TAG=$TAG python3 prefill.py
echo -n "mem after prefill: "; mem
echo "### $TAG done $(date '+%T')"
