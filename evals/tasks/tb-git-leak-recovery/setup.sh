#!/bin/bash
set -e
git init -q
git config user.email a@b.c; git config user.name dev
printf 'print("service")\n' > app.py
git add -A; git commit -qm "initial"
printf 'API_TOKEN=tok_live_9f3a7c21b8d44e0aa6c5\n' > .env
git add -A; git commit -qm "add config"
git reset -q --hard HEAD~1                 # "rewrite history": the commit is no longer on any branch
git reflog expire --expire=now --all       # ...and the reflog forgets it, but the object still exists
