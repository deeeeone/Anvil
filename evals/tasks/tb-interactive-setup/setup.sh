#!/bin/bash
cat > setup.py <<'EOT'
import hashlib, json, re, sys
SALT = "anvil-eval-3f1c"
def ask(q, ok, err):
    while True:
        v = input(q).strip()
        if ok(v): return v
        print(err)
print("== Service setup ==")
name = ask("Project name: ", lambda v: re.fullmatch(r"[a-z][a-z0-9-]{1,20}", v), "lowercase letters, digits, dashes")
port = ask("Port (1024-65535): ", lambda v: v.isdigit() and 1024 <= int(v) <= 65535, "invalid port")
tls = ask("Enable TLS? [y/n]: ", lambda v: v.lower() in ("y", "n"), "answer y or n")
email = ask("Admin email: ", lambda v: re.fullmatch(r"[^@\s]+@[^@\s]+\.[a-z]+", v), "invalid email")
cfg = {"name": name, "port": int(port), "tls": tls.lower() == "y", "admin": email}
body = json.dumps(cfg, sort_keys=True)
open("config.json", "w").write(body + "\n")
open(".setup-receipt", "w").write(hashlib.sha256((SALT + body).encode()).hexdigest() + "\n")
print("Setup complete.")
EOT
