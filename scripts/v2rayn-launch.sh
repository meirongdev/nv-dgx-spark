#!/bin/bash
# Revive the proxy headless: build an xray config from a reachable v2rayN
# shadowsocks node and run it as the SOCKS upstream (127.0.0.1:10808) that
# privoxy (172.17.0.1:10809) forwards to. Secrets are not printed.
set -uo pipefail
ROOT=/home/admin/v2rayN/v2rayN-linux-arm64
DB="$ROOT/guiConfigs/guiNDB.db"
XRAY=$(find "$ROOT/bin/xray" -maxdepth 1 -name xray -type f 2>/dev/null | head -1)
echo "xray binary: ${XRAY:-NOT-FOUND}"
[ -x "$XRAY" ] || { echo "xray not executable"; exit 1; }

python3 - "$DB" > /home/admin/xray-fix.json <<'PY'
import sqlite3, sys, json
db = sys.argv[1]; c = sqlite3.connect(db); cur = c.cursor()
# Use cursor.description (guaranteed aligned with row values) instead of PRAGMA.
cur.execute("SELECT * FROM ProfileItem WHERE configType=3")
cols = [d[0] for d in cur.description]
# Column names are PascalCase (Address/Port/Password/Security/Id) -> lowercase them.
rows = [{k.lower(): v for k, v in zip(cols, r)} for r in cur.fetchall()]
assert rows, "no shadowsocks (configType=3) rows"
node = next((r for r in rows if r.get("address") == "104.224.156.253"), rows[0])
_masked = {k: ("***" if k in ("password", "id") and v else v) for k, v in node.items()}
sys.stderr.write("NODE_FIELDS: %s\n" % json.dumps(_masked, default=str))
method = node.get("security") or node.get("method")
if not method and node.get("protoextra"):
    try:
        method = json.loads(node["protoextra"]).get("SsMethod")
    except Exception:
        pass
pw = node.get("password") or node.get("id")
sys.stderr.write("NODE %s:%s method=%s pw_present=%s\n" % (
    node.get("address"), node.get("port"), method, bool(pw)))
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks-in", "listen": "127.0.0.1", "port": 10808,
                "protocol": "socks", "settings": {"udp": True, "auth": "noauth"}}],
  "outbounds": [{"protocol": "shadowsocks", "settings": {"servers": [{
      "address": node.get("address"), "port": int(node.get("port")),
      "method": method, "password": pw}]}}],
}
json.dump(cfg, sys.stdout)
PY
RC=$?
echo "--- config gen rc=$RC, size=$(wc -c < /home/admin/xray-fix.json 2>/dev/null) bytes ---"

tmux kill-session -t xrayfix 2>/dev/null || true
tmux new-session -d -s xrayfix "$XRAY run -c /home/admin/xray-fix.json 2>&1 | tee /tmp/xray-fix.log"
sleep 5
echo "--- 10808 SOCKS listening? ---"; ss -ltn 2>/dev/null | grep -E ":10808" || echo "10808 NOT up"
echo "--- xray log tail ---"; tail -6 /tmp/xray-fix.log 2>/dev/null
echo "--- test via SOCKS 127.0.0.1:10808 ---"; curl -s -x socks5h://127.0.0.1:10808 -o /dev/null -w "github-socks=%{http_code} t=%{time_total}s\n" --max-time 20 https://github.com 2>&1 || echo "socks failed"
echo "--- test via privoxy 172.17.0.1:10809 ---"; curl -s -x http://172.17.0.1:10809 -o /dev/null -w "github-privoxy=%{http_code}\n" --max-time 20 https://github.com 2>&1 || echo "privoxy failed"
