#!/bin/bash
set -e
[ -z "$(git status --porcelain)" ] || { echo "files changed"; git status --porcelain; exit 1; }
python3 - "$ANVIL_ANSWER" <<'EOF'
import sys
a = sys.argv[1].lower()
assert "5" in a or "five" in a, a
assert "sliding" in a or "rolling" in a, a
EOF
