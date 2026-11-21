#!/bin/bash
set -e
mkdir -p app
cat > app/__init__.py <<'EOF'
EOF
cat > app/models.py <<'EOF'
from dataclasses import dataclass

@dataclass
class User:
    name: str
EOF
cat > app/serialize.py <<'EOF'
from .models import User

def to_dict(u: User) -> dict:
    return {"name": u.name}

def from_dict(d: dict) -> User:
    return User(name=d["name"])
EOF
