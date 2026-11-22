#!/bin/bash
set -e
python3 - <<'PY'
import hashlib, sqlite3
db = sqlite3.connect("shop.db")
n = db.execute("select count(*) from orders").fetchone()[0]
assert n == 160000, f"data changed: {n} orders"
s = db.execute("select sum(total_cents) from orders").fetchone()[0]
assert s == 7240494653, "data changed"
PY
start=$(python3 -c 'import time; print(time.time())')
out=$(python3 run_report.py)
end=$(python3 -c 'import time; print(time.time())')
python3 - "$start" "$end" "$out" <<'PY'
import hashlib, sys
secs = float(sys.argv[2]) - float(sys.argv[1])
h = hashlib.sha256(sys.argv[3].encode()).hexdigest()
assert h == "f3cd4b4774649760a0cd01e59cccd01f4b7c40442b8794e4d6c35dd8d6b1c0fa", f"output differs from the original report ({h[:12]})"
assert secs < 3.0, f"too slow: {secs:.1f}s"
PY
