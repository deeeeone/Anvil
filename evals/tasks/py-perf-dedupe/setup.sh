#!/bin/bash
set -e
cat > dedupe.py <<'EOF'
def dedupe(items):
    """Remove duplicates, keeping the first occurrence order."""
    out = []
    for x in items:
        if x not in out:
            out.append(x)
    return out
EOF
