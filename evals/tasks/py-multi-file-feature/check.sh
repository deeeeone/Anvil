#!/bin/bash
set -e
python3 - <<'EOF'
from app.models import User
from app.serialize import to_dict, from_dict
u = from_dict({"name": "A", "email": "a@x.io"})
assert u.email == "a@x.io"
assert to_dict(u) == {"name": "A", "email": "a@x.io"}
try:
    from_dict({"name": "B", "email": "nope"})
    raise SystemExit("no ValueError")
except ValueError:
    pass
EOF
