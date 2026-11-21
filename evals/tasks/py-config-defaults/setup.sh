#!/bin/bash
set -e
cat > config.py <<'EOF'
import json

DEFAULTS = {"host": "localhost", "port": 8080, "debug": False}

def load_config(path):
    with open(path) as f:
        return json.load(f)
EOF
