#!/bin/bash
set -e
python3 - <<'EOF'
from report import average_scores, best
s = [{"name": "a", "scores": []}, {"name": "b", "scores": [2, 4]}]
assert average_scores(s) == {"a": 0, "b": 3}
assert best(s) == "b"
assert best([]) is None
EOF
