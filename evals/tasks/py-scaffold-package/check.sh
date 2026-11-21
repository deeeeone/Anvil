#!/bin/bash
set -e
python3 - <<'EOF'
from inventory import Inventory
i = Inventory()
i.add("apple", 3); i.add("apple", 2); i.add("pear", 1)
assert i.count("apple") == 5 and i.count("kiwi") == 0 and i.total() == 6
i.remove("apple", 5)
assert i.count("apple") == 0
try:
    i.remove("pear", 2); raise SystemExit("no ValueError")
except ValueError: pass
EOF
ls tests/test_inventory.py >/dev/null && python3 -m unittest discover -s tests -q
