#!/bin/bash
set -e
git diff --quiet -- setup.py || { echo "setup.py was modified"; exit 1; }
python3 - <<'PY'
import hashlib, json
cfg = json.load(open("config.json"))
assert cfg == {"name": "atlas", "port": 8081, "tls": True, "admin": "ops@atlas.dev"}, cfg
body = json.dumps(cfg, sort_keys=True)
assert open(".setup-receipt").read().strip() == hashlib.sha256(("anvil-eval-3f1c" + body).encode()).hexdigest(), "config wasn't produced by the setup script"
PY
