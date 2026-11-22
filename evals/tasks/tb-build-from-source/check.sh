#!/bin/bash
set -e
git diff --quiet -- tests || { echo "tests were modified"; exit 1; }
make clean >/dev/null 2>&1 || true
make test >/dev/null 2>&1 || { echo "make test fails"; exit 1; }
printf 'a b c\n\nd' > /tmp/tb_extra_$$.txt
[ "$(./build/wc2 /tmp/tb_extra_$$.txt)" = "words=4 lines=3" ] || { echo "last line without newline not counted"; exit 1; }
rm -f /tmp/tb_extra_$$.txt
