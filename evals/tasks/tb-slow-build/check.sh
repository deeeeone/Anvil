#!/bin/bash
set -e
[ -f dist/app.bin ] || { echo "no dist/app.bin (build didn't finish)"; exit 1; }
want=$(shasum -a 256 dist/app.bin | cut -d' ' -f1)
[ "$(tr -d '[:space:]' < answer.txt)" = "$want" ] || { echo "wrong checksum"; exit 1; }
[ "$(wc -l < dist/app.bin | tr -d ' ')" = "25" ] || { echo "artifact incomplete"; exit 1; }
