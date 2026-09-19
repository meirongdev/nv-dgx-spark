#!/usr/bin/env bash
# Switch the Qwen Code CLI boot default between the DGX stacks and the Mac-local
# omlx server.
#
#   qwen-model-switch.sh <target>  -> 切换启动默认(目标来自 stacks/ 注册表)
#   qwen-model-switch.sh status    -> 打印三处配置现在各指向哪
#   qwen-model-switch.sh --help    -> 列出所有可选目标(即注册表)
#
# ⚠️ 这里**没有一张目标表**了。目标 = stacks/<id>/stack.env 的 STACK_CLIENT_ALIAS,
#    model / URL / contextWindowSize 三者都从同一份 stack.env 读 —— 加模型不用改本文件,
#    也不可能再出现"别名对了但 ctx 写的是另一个栈的"这种半对半错的状态。
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
# --- 目标从**注册表**来,不再是这里的一张表 ---------------------------------
# 别名 = stacks/<id>/stack.env 里的 STACK_CLIENT_ALIAS(没写就用栈 id)。
# 加一个模型时这个文件**不用动**。
#
# contextWindowSize 必须跟着模型走,不能是固定常数 —— 它住在 STACK_CTXWIN:
#   · V4-Flash 原生 1M。CLI 对 `deepseek-v4*` **预留 384000** 输出 token
#     (contextLimit = max(0, ctxWin - 384000)),低于 ~384k 的值会把硬阈值钳到 0,
#     于是**每一个请求**都报 "hard limit: 0",哪怕 prompt 只有 4k。所以是 1000000,
#     不是某个看起来更"安全"的小数字。
#   · Qwen3.8-27B / Flash-Next / 27B-Uncensored 都是原生 262144;报 1M 会让 CLI
#     发出服务端随后拒绝的 prompt。
#   ⚠️ `qwen3.8-27b-sglang` **带点**,与 `qwen38-*` 不同形,所以"不命中 384k 预留"
#     这条不能照搬 —— 2026-09-19 切换后是**实测发过真实请求**验的,不是看配置。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../stacks/_lib/common.sh"

# 别名 → 栈 id
resolve_alias(){
  local want="$1" id
  for id in $(stack_ids); do
    [ "$id" = "$want" ] && { echo "$id"; return 0; }
    [ "$(stack_field "$id" STACK_CLIENT_ALIAS)" = "$want" ] && { echo "$id"; return 0; }
  done
  return 1
}
usage(){
  local id a
  echo "usage: $(basename "$0") <target>|status" >&2
  echo "  可选目标(来自 stacks/):" >&2
  for id in $(stack_ids); do
    a=$(stack_field "$id" STACK_CLIENT_ALIAS); [ -n "$a" ] || a="$id"
    printf '    %-11s %s @ %s:%s\n' "$a" "$(stack_field "$id" STACK_MODEL)" \
      "$(stack_field "$id" STACK_HEAD)" "$(stack_field "$id" STACK_PORT)" >&2
  done
}

case "${1:-}" in
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
  "" | -h | --help) usage; exit 1 ;;
  *)
    SW_ID=$(resolve_alias "$1") || { echo "未知目标 '$1'" >&2; usage; exit 1; }
    load_stack "$SW_ID"
    MODEL="$STACK_MODEL"
    URL="http://$STACK_HEAD:$STACK_PORT/v1"
    CTXWIN="${STACK_CTXWIN:?stacks/$SW_ID/stack.env 没写 STACK_CTXWIN —— 见本文件开头关于 hard-limit-0 的说明}"
    # ⚠️ 端口 8000 在两处都用:100.97.87.120:8000 是 DGX,127.0.0.1:8000 是 Mac
    #    本地的 omlx。**主机名才是区分点**。2026-09-02 发现全局配置曾处于
    #    baseUrl=127.0.0.1:8000(omlx)+ model=deepseek-v4-flash(DGX)的自相矛盾
    #    状态 —— omlx 不提供那个模型,启动即 404。URL 整条从注册表来就不会再发生。
    ;;
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
echo "(In-session switching needs no restart: use /model — modelProviders 里有"
echo " qwen38-flash-next / Qwen3.6-35B / Gemma-4 三个,DGX 和本地都能实时跳。)"
