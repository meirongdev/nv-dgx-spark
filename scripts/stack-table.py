#!/usr/bin/env python3
# ============================================================
# stack-table.py —— 把 stacks/ 注册表渲染成文档里的表格,并校验它们没过期。
#
# 为什么存在:换主力栈这件事,最贵的一次代价不是改错了某个参数,而是
# **一份文档都没改**(091b6e4 改了 13 个文件、0 份文档)。CLAUDE.md 是每个
# session 全量载入的索引,它错一天,就有一天所有判断建立在错误前提上 ——
# 2026-09-03 clock-cap 的静默失效正是这么来的。
#
# 人工"记得改文档"已经被证明不可靠三次了,所以这里把它机械化:
#   python3 scripts/stack-table.py --write    # 重新生成(make stack-table)
#   python3 scripts/stack-table.py --check    # 只校验,不一致就非 0(make stack-check)
#
# 文档里用注释标出可生成区间,区间外的散文不碰:
#   <!-- BEGIN generated:stacks --> ... <!-- END generated:stacks -->
# ============================================================
import pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STACKS = ROOT / "stacks"

def read_env(p):
    """stack.env 是 shell 片段,交给 shell 自己解析 —— 不要在这里手写解析器,
    那样注册表和运行时会有两套语义,而分歧只会在出事那天才暴露。"""
    out = subprocess.run(
        ["bash", "-c", f'set -a; . "{p}"; set +a; '
         'for v in ${!STACK_@}; do printf "%s=%s\\n" "$v" "${!v}"; done'],
        capture_output=True, text=True)
    d = {}
    for line in out.stdout.splitlines():
        k, _, v = line.partition("=")
        d[k] = v
    return d

def registry():
    rs = {}
    for d in sorted(STACKS.iterdir()):
        if d.name.startswith("_") or not (d / "stack.env").is_file():
            continue
        rs[d.name] = read_env(d / "stack.env")
    return rs

def primary():
    return (STACKS / "PRIMARY").read_text().strip().splitlines()[0].strip()

# --- 注册表自身的一致性 ------------------------------------------------------
def validate(rs, prim):
    errs = []
    if prim not in rs:
        errs.append(f"stacks/PRIMARY 指向 '{prim}',但没有这个栈")
    for sid, s in rs.items():
        if s.get("STACK_ID") != sid:
            errs.append(f"{sid}: STACK_ID='{s.get('STACK_ID')}' 与目录名不符")
        for f in ("STACK_NAME", "STACK_RUNTIME", "STACK_MODEL", "STACK_PORT", "STACK_HEAD"):
            if not s.get(f):
                errs.append(f"{sid}: 缺必填字段 {f}")
        if s.get("STACK_RUNTIME") == "k3s" and len(s.get("STACK_DEPLOYS", "").split()) != 2:
            errs.append(f"{sid}: k3s 栈的 STACK_DEPLOYS 必须是成对的两个 rank(gotcha #1)")
        if s.get("STACK_RUNTIME") == "docker" and not s.get("STACK_STOP_CMD"):
            errs.append(f"{sid}: docker 栈必须有 STACK_STOP_CMD,否则看门狗停不掉它")
    # served name 必须全局唯一 —— 它是栈的身份,重名等于身份不可判定
    for field, label in (("STACK_MODEL", "served-model-name"),
                         ("STACK_CLIENT_ALIAS", "客户端别名")):
        seen = {}
        for sid, s in rs.items():
            v = s.get(field)
            if not v:
                continue
            if v in seen:
                errs.append(f"{label} '{v}' 被 {seen[v]} 和 {sid} 同时占用")
            seen[v] = sid
    return errs

# --- 表格 --------------------------------------------------------------------
def t_stacks(rs, prim):
    rows = ["| 栈 | 节点 | 端点 | 引擎 / 运行时 | 状态 |", "|---|---|---|---|---|"]
    for sid, s in sorted(rs.items(), key=lambda kv: (kv[0] != prim, kv[0])):
        if s.get("STACK_RUNTIME") == "external":
            continue
        name = f"**{s['STACK_NAME']}**" if sid == prim else s["STACK_NAME"]
        st = f"**{s.get('STACK_STATUS','')}**" if sid == prim else s.get("STACK_STATUS", "")
        rows.append(f"| {name}<br>`STACK={sid}` | {s.get('STACK_NODES','?')} | "
                    f"`:{s['STACK_PORT']}` `{s['STACK_MODEL']}` | "
                    f"{s.get('STACK_ENGINE','?')} / {s['STACK_RUNTIME']} | {st} |")
    return "\n".join(rows)

def t_clients(rs, prim):
    rows = ["| 栈 | 端点 | served name | 关思考的 kwarg | CoT 字段 | ctxWindow |",
            "|---|---|---|---|---|---|"]
    for sid, s in sorted(rs.items(), key=lambda kv: (kv[0] != prim, kv[0])):
        name = f"**{sid}(主)**" if sid == prim else sid
        off = "`" + (s.get("STACK_THINK_OFF") or "—") + "`"
        if s.get("STACK_THINK_CAN_DISABLE") == "0":
            off += " ⚠️ **关不掉**,这是最低档"
        rows.append(f"| {name} | `{s['STACK_HEAD']}:{s['STACK_PORT']}` | "
                    f"`{s['STACK_MODEL']}` | {off} | "
                    f"`{s.get('STACK_COT_FIELD','—')}` | {s.get('STACK_CTXWIN','—')} |")
    rows.append("")
    rows.append("> ⚠️ **关思考的 kwarg 和 CoT 字段逐栈都不同,而且写错都是静默的**"
                "(gotcha #9)。\n> 上表由 `make stack-table` 从 `stacks/*/stack.env` 生成 —— "
                "不要手改这里,改注册表。")
    return "\n".join(rows)

TABLES = {"stacks": t_stacks, "clients": t_clients}
TARGETS = [("CLAUDE.md", "stacks"), ("README.md", "stacks"), ("docs/clients-cn.md", "clients")]

def apply(write):
    rs, prim = registry(), primary()
    errs = validate(rs, prim)
    if errs:
        print("注册表自身不一致:", file=sys.stderr)
        for e in errs:
            print(f"  ✗ {e}", file=sys.stderr)
        return 1
    stale = []
    for rel, kind in TARGETS:
        p = ROOT / rel
        if not p.is_file():
            continue
        s = p.read_text()
        pat = re.compile(rf"(<!-- BEGIN generated:{kind} -->\n)(.*?)(<!-- END generated:{kind} -->)",
                         re.S)
        m = pat.search(s)
        if not m:
            print(f"  · {rel}: 没有 generated:{kind} 标记区,跳过")
            continue
        want = TABLES[kind](rs, prim) + "\n"
        if m.group(2) == want:
            print(f"  ✓ {rel}")
            continue
        stale.append(rel)
        if write:
            p.write_text(pat.sub(lambda mm: mm.group(1) + want + mm.group(3), s, count=1))
            print(f"  ↻ {rel} 已更新")
        else:
            print(f"  ✗ {rel} 与注册表不一致", file=sys.stderr)
    if stale and not write:
        print(f"\n{len(stale)} 份文档已过期。跑 `make stack-table` 重新生成。", file=sys.stderr)
        return 1
    print(f"\nPRIMARY = {prim}   已注册 {len(rs)} 个栈")
    return 0

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    sys.exit(apply(write=(mode == "--write")))
