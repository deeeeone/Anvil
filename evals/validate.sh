#!/bin/bash
# Proves every task that ships a solution.sh is well formed: its check FAILS on the untouched project and PASSES after
# the reference solution runs. Usage: evals/validate.sh [task-prefix...]
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; bad=0
for t in "$HERE"/tasks/*/; do
  name=$(basename "$t")
  [ -f "$t/solution.sh" ] || continue
  if [ $# -gt 0 ]; then ok=0; for p in "$@"; do [[ "$name" == $p* ]] && ok=1; done; [ $ok = 1 ] || continue; fi
  w=$(mktemp -d); cd "$w"
  bash "$t/setup.sh" >/dev/null 2>&1 || { echo "SETUP FAILED  $name"; bad=$((bad+1)); continue; }
  git init -q 2>/dev/null; git add -A >/dev/null 2>&1; git -c user.email=e@x -c user.name=eval commit -qm setup --allow-empty >/dev/null 2>&1
  if bash "$t/check.sh" >/dev/null 2>&1; then echo "CHECK PASSES WITHOUT A SOLUTION  $name"; bad=$((bad+1)); cd /; rm -rf "$w"; continue; fi
  bash "$t/solution.sh" >/dev/null 2>&1
  if out=$(PYTHONDONTWRITEBYTECODE=1 bash "$t/check.sh" 2>&1); then echo "ok   $name"; pass=$((pass+1)); else echo "SOLUTION REJECTED  $name: $(echo "$out" | tail -2 | tr '\n' ' ')"; bad=$((bad+1)); fi
  cd /; rm -rf "$w"
done
echo "$pass valid, $bad problems"
[ $bad = 0 ]
