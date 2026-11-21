#!/bin/bash
set -e
python3 - <<'EOF'
import time
from dedupe import dedupe
assert dedupe([3, 1, 3, 2, 1]) == [3, 1, 2]
assert dedupe([]) == []
xs = list(range(150000)) * 2
t = time.time(); r = dedupe(xs); dt = time.time() - t
assert r == list(range(150000))
assert dt < 1.0, dt
EOF
