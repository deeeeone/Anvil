python3 - <<'PY'
import csv
rows = [r for r in csv.DictReader(open("orders.csv")) if r["status"] == "active"]
rows.sort(key=lambda r: int(r["id"]))
rows.sort(key=lambda r: r["date"], reverse=True)
with open("out.csv", "w") as f:
    f.write("id,date,customer,status,amount\n")
    for r in rows:
        y, m, d = r["date"].split("-"); a = int(r["amount_cents"])
        f.write(f'{r["id"]},{d}/{m}/{y},{r["customer"]},{r["status"]},{a // 100}.{a % 100:02d}\n')
PY
