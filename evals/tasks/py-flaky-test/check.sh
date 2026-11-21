#!/bin/bash
set -e
grep -q "deal(" test_shuffle.py && grep -qE "assert.*hands" test_shuffle.py || { echo "the dealing check was removed"; exit 1; }
grep -qiE "skip|expectedFailure" test_shuffle.py && { echo "skipped"; exit 1; }
for i in $(seq 1 15); do python3 -m unittest -q test_shuffle 2>/dev/null || { echo "flaky run $i"; exit 1; }; done
python3 -c '
from shuffle import deal
seen = {tuple(deal(range(8), 2)[0]) for _ in range(40)}
assert len(seen) > 1, "deal is no longer random by default"
'
