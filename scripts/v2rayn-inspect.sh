#!/bin/bash
# TEMP: inspect v2rayN saved nodes + test reachability (no secrets printed).
D=/home/admin/v2rayN/v2rayN-linux-arm64/guiConfigs
echo "=== guiConfigs ==="; ls -la "$D" 2>/dev/null
DB="$D/guiNDB.db"
echo "=== DB present? $DB ==="; ls -la "$DB" 2>/dev/null || echo "no guiNDB.db"
python3 - "$DB" "$D/guiNConfig.json" <<'PY'
import sys, os, socket, json
db, jcfg = sys.argv[1], sys.argv[2]
def reach(addr, port):
    try:
        if not addr or not port: return "no-addr"
        s = socket.create_connection((addr, int(port)), timeout=4); s.close(); return "OPEN"
    except Exception as e:
        return "closed(%s)" % type(e).__name__
if os.path.exists(db):
    import sqlite3
    c = sqlite3.connect(db); cur = c.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    print("tables:", [r[0] for r in cur.fetchall()])
    try:
        cur.execute("SELECT configType,address,port,remarks FROM ProfileItem")
        rows = cur.fetchall()
        print("profiles:", len(rows))
        seen=set()
        for ct, addr, port, rem in rows:
            key=(addr,port)
            if key in seen: continue
            seen.add(key)
            print("  type=%s server=%s:%s reach=%s remark=%r" % (ct, addr, port, reach(addr,port), (rem or '')[:28]))
    except Exception as e:
        print("ProfileItem err:", e)
else:
    print("no DB; guiNConfig.json keys:")
    try:
        d=json.load(open(jcfg)); print(list(d.keys()))
    except Exception as e:
        print("json err:", e)
PY
