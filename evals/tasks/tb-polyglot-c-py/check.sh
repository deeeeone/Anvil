#!/bin/bash
set -e
[ -f poly.c ] || { echo "no poly.c"; exit 1; }
cc poly.c -o /tmp/poly_c_$$ 2>/dev/null || { echo "doesn't compile as C"; exit 1; }
a=$(/tmp/poly_c_$$); rm -f /tmp/poly_c_$$
b=$(python3 poly.c)
[ "$a" = "fib(15)=610" ] || { echo "C printed: $a"; exit 1; }
[ "$b" = "fib(15)=610" ] || { echo "Python printed: $b"; exit 1; }
grep -q 'fib' poly.c
[ "$(grep -c 'fib' poly.c)" -ge 4 ] || { echo "looks hard-coded"; exit 1; }
