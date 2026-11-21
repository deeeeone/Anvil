#!/bin/bash
set -e
python3 - <<'EOF'
import json, os, tempfile
import config
d = dict(config.DEFAULTS)
p = os.path.join(tempfile.mkdtemp(), "c.json")
json.dump({"port": 9000}, open(p, "w"))
c = config.load_config(p)
assert c == {"host": "localhost", "port": 9000, "debug": False}, c
c["host"] = "x"
assert config.DEFAULTS == d
assert config.load_config("/nonexistent/x.json") == d
EOF
