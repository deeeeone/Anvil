#!/bin/bash
set -e
cat > dates.py <<'EOF'
from datetime import date

def parse_iso(s):
    """Parse YYYY-MM-DD into a date."""
    y, m, d = s.split("-")
    return date(int(y), int(d), int(m))
EOF
cat > test_dates.py <<'EOF'
import unittest
from dates import parse_iso
from datetime import date

class T(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(parse_iso("2024-03-15"), date(2024, 3, 15))

if __name__ == "__main__":
    unittest.main()
EOF
