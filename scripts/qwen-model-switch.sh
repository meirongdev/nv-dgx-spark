#!/usr/bin/env bash
# Switch the Qwen Code CLI boot default between the two DGX Spark stacks.
#
#   qwen-model-switch.sh v4flash   -> DeepSeek-V4-Flash, dual-node k3s, :8000
#   qwen-model-switch.sh qwen38    -> Qwen3.8-27B-NVFP4, single-node S1, :8888
#   qwen-model-switch.sh status    -> show what each config file currently says
#
# Why a script rather than "just edit settings.json": the CLI's boot path NEVER
# consults `modelProviders` (those are reachable only from interactive /model),
# so the boot default lives in several places that must agree — and the
# load-bearing endpoint is `security.auth.baseUrl`, NOT `model.baseUrl` (the
# latter is only picker-disambiguation metadata; getting this wrong makes the
# CLI fall through to Alibaba DashScope and 401).
#
# Switching *within* a running session needs none of this — both models are in
# modelProviders, so `/model` flips them live.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBAL="$HOME/.qwen/settings.json"
REPO_SETTINGS="$REPO/.qwen/settings.json"
REPO_ENV="$REPO/.qwen/.env"

# contextWindowSize MUST travel with the model, not be a fixed constant:
#   - V4-Flash: native 1M. The CLI matches `deepseek-v4*` and RESERVES 384000
#     output tokens (contextLimit = max(0, contextWindowSize - 384000)), so any
#     value below ~384k clamps the hard threshold to 0 and EVERY request fails
#     with "hard limit: 0" — even a 4k prompt. Hence 1000000, not a smaller
#     "safe" number.
#   - Qwen3.8-27B: serves native 262144 (the YaRN-extended 1M was dropped
#     2026-08-15 to avoid its short-context quality penalty). Advertising 1M
#     here would let the CLI send prompts the server then rejects.
case "${1:-}" in
  v4flash) MODEL=deepseek-v4-flash; URL=http://100.97.87.120:8000/v1; CTXWIN=1000000 ;;
  qwen38)  MODEL=qwen38-27b;        URL=http://100.97.87.120:8888/v1; CTXWIN=262144  ;;
  status)
    for f in "$GLOBAL" "$REPO_SETTINGS"; do
      [ -f "$f" ] && python3 -c "
import json,sys
d=json.load(open('$f'))
m=d.get('model',{}); a=d.get('security',{}).get('auth',{})
ctx=(m.get('generationConfig') or {}).get('contextWindowSize','-')
print('%-46s model=%-20s ctx=%-9s auth.baseUrl=%s' % ('$f'.replace('$HOME','~'), m.get('name','-'), ctx, a.get('baseUrl','(inherits)')))"
    done
    [ -f "$REPO_ENV" ] && grep -E '^OPENAI_(MODEL|BASE_URL)=' "$REPO_ENV" | sed 's/^/  .env  /'
    exit 0 ;;
  *) echo "usage: $(basename "$0") {v4flash|qwen38|status}" >&2; exit 1 ;;
esac

# Global settings: boot default. All four fields must agree.
python3 - "$GLOBAL" "$MODEL" "$URL" "$CTXWIN" <<'PY'
import json, sys
path, model, url, ctx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = json.load(open(path))
d.setdefault("model", {})["name"] = model
d["model"]["baseUrl"] = url                                   # picker metadata
d["model"].setdefault("generationConfig", {})["contextWindowSize"] = ctx
d.setdefault("security", {}).setdefault("auth", {})["baseUrl"] = url  # load-bearing
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print("global   -> %s @ %s (ctx %d)" % (model, url, ctx))
PY

# Repo-level settings override the global one inside this repo — including
# contextWindowSize, so it must be flipped here too or the repo value wins and
# reintroduces the hard-limit-0 trap.
if [ -f "$REPO_SETTINGS" ]; then
  python3 - "$REPO_SETTINGS" "$MODEL" "$CTXWIN" <<'PY'
import json, sys
path, model, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path))
d.setdefault("model", {})["name"] = model
d["model"].setdefault("generationConfig", {})["contextWindowSize"] = ctx
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print("repo     -> %s (ctx %d)" % (model, ctx))
PY
fi

# Repo .env (gitignored) is the fallback when settings.json is overridden.
if [ -f "$REPO_ENV" ]; then
  sed -i '' -e "s|^OPENAI_MODEL=.*|OPENAI_MODEL=$MODEL|" \
            -e "s|^OPENAI_BASE_URL=.*|OPENAI_BASE_URL=$URL|" "$REPO_ENV"
  echo "repo .env-> $MODEL @ $URL"
fi

echo
echo "Boot default is now '$MODEL'. Restart any running qwen session to pick it up."
echo "(In-session switching between the two needs no restart: use /model.)"
