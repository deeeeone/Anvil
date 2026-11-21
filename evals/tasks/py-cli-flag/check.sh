#!/bin/bash
set -e
printf 'b\na\nb\nc\n' > /tmp/anvil_eval_in.txt
out=$(python3 sortlines.py --reverse --unique /tmp/anvil_eval_in.txt | tr '\n' ',')
[ "$out" = "c,b,a," ] || { echo "got $out"; exit 1; }
out=$(python3 sortlines.py /tmp/anvil_eval_in.txt | tr '\n' ',')
[ "$out" = "a,b,b,c," ] || { echo "default broke: $out"; exit 1; }
