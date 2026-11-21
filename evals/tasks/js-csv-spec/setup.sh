#!/bin/bash
set -e
cat > README.md <<'EOF'
# csv

`parseCSV(text)` in csv.js returns an array of rows (arrays of strings).
- Fields are separated by commas, rows by newlines (\n or \r\n). A trailing newline does not create an empty row.
- A field may be wrapped in double quotes; inside quotes, commas and newlines are literal and "" means one quote.
EOF
cat > csv.js <<'EOF'
function parseCSV(text) {
  // TODO
}
module.exports = { parseCSV };
EOF
