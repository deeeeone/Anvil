#!/bin/bash
set -e
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open("orders.csv")))
keep = [r for r in rows if r["status"] == "active"]
keep.sort(key=lambda r: int(r["id"]))
keep.sort(key=lambda r: r["date"], reverse=True)      # stable: date descending, then id ascending
exp = ["id,date,customer,status,amount"]
for r in keep:
    y, m, d = r["date"].split("-")
    a = int(r["amount_cents"])
    exp.append(f'{r["id"]},{d}/{m}/{y},{r["customer"]},{r["status"]},{a // 100}.{a % 100:02d}')
got = open("out.csv").read().rstrip("\n").split("\n")
assert got[0] == exp[0], f"header: {got[0]!r}"
assert len(got) == len(exp), f"{len(got)} lines, expected {len(exp)}"
for i, (g, e) in enumerate(zip(got, exp)):
    assert g == e, f"line {i}: {g!r} != {e!r}"
assert len(rows) == 400000
PY
