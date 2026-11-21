#!/bin/bash
set -e
mkdir -p src
cat > src/rate.js <<'EOF'
const WINDOW_MS = 60000;
const LIMIT = 5;
const hits = new Map();
function allow(user, now = Date.now()) {
  const list = (hits.get(user) || []).filter(t => now - t < WINDOW_MS);
  if (list.length >= LIMIT) { hits.set(user, list); return false; }
  list.push(now); hits.set(user, list); return true;
}
module.exports = { allow };
EOF
