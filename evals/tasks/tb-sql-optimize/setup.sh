#!/bin/bash
set -e
python3 - <<'PY'
import random, sqlite3
random.seed(42)
db = sqlite3.connect("shop.db")
db.executescript("""
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, country TEXT);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total_cents INTEGER, status TEXT, created TEXT);
""")
countries = ["US", "DE", "FR", "JP", "BR", "IN"]
db.executemany("INSERT INTO customers VALUES (?,?,?)", [(i, f"customer-{i:05d}", random.choice(countries)) for i in range(1, 6001)])
rows = []
for i in range(1, 160001):
    rows.append((i, random.randint(1, 6000), random.randint(500, 90000), random.choice(["paid", "paid", "paid", "refunded", "pending"]),
                 f"2025-{random.randint(1,12):02d}-{random.randint(1,28):02d}"))
db.executemany("INSERT INTO orders VALUES (?,?,?,?,?)", rows)
db.commit()
PY
cat > report.sql <<'EOT'
SELECT c.country,
       c.name,
       (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id AND o.status = 'paid') AS paid_orders,
       (SELECT SUM(o.total_cents) FROM orders o WHERE o.customer_id = c.id AND o.status = 'paid') AS revenue_cents
FROM customers c
WHERE (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id AND o.status = 'paid') >= 20
ORDER BY revenue_cents DESC, c.name
LIMIT 50;
EOT
cat > run_report.py <<'EOT'
import sqlite3, sys
db = sqlite3.connect("shop.db")
for row in db.execute(open("report.sql").read()):
    print("|".join(str(v) for v in row))
EOT
