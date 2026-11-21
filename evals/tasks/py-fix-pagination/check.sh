#!/bin/bash
set -e
python3 - <<'EOF'
from pager import paginate
xs = list(range(10))
assert paginate(xs, 1, 3) == [0, 1, 2]
assert paginate(xs, 4, 3) == [9]
assert paginate(xs, 5, 3) == []
EOF
