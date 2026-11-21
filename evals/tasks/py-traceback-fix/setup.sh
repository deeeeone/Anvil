#!/bin/bash
set -e
cat > report.py <<'EOF'
def average_scores(students):
    totals = {}
    for s in students:
        totals[s["name"]] = sum(s["scores"]) / len(s["scores"])
    return totals

def best(students):
    avgs = average_scores(students)
    return max(avgs, key=avgs.get)
EOF
