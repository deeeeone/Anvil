#!/bin/bash
set -e
grep -q 'date(2024, 3, 15)' test_dates.py || { echo "test changed"; exit 1; }
python3 -m unittest -q test_dates
python3 -c 'from dates import parse_iso; from datetime import date; assert parse_iso("1999-12-01") == date(1999,12,1)'
