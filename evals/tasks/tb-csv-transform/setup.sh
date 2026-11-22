#!/bin/bash
python3 - <<'PY'
import random
random.seed(7)
with open("orders.csv", "w") as f:
    f.write("id,date,customer,status,amount_cents,notes\n")
    for i in range(1, 400001):
        f.write(f"{i},2025-{random.randint(1,12):02d}-{random.randint(1,28):02d},cust{random.randint(1,900)},{random.choice(['active','active','closed','hold'])},{random.randint(100,500000)},note {i}\n")
PY
