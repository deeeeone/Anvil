#!/bin/bash
set -e
[ -x count_ext.sh ] || { echo "not executable"; exit 1; }
out=$(./count_ext.sh sample | tr -s ' ' | tr '\n' ';')
[ "$out" = "py 3;(none) 1;md 1;txt 1;" ] || { echo "got $out"; exit 1; }
