#!/bin/bash
set -e
[ "$(tr -d '[:space:]' < recovered.txt)" = "tok_live_9f3a7c21b8d44e0aa6c5" ] || { echo "wrong or missing token"; exit 1; }
[ -z "$(git diff --stat -- app.py)" ] || { echo "tracked file changed"; exit 1; }
