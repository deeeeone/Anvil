#!/bin/bash
set -e
cat > sortlines.py <<'EOF'
import argparse, sys

def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("file")
    a = p.parse_args(argv)
    with open(a.file) as f:
        lines = [l.rstrip("\n") for l in f]
    for l in sorted(lines):
        print(l)

if __name__ == "__main__":
    main()
EOF
printf 'banana\napple\ncherry\n' > fruits.txt
