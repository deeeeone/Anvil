#!/bin/bash
set -e
if grep -rn --include=*.js -E '\bcalc\b' . ; then echo "calc still referenced"; exit 1; fi
out=$(node index.js)
[ "$out" = "8 Total: 8.00" ] || { echo "got $out"; exit 1; }
