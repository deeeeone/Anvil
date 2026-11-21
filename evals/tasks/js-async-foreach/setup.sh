#!/bin/bash
set -e
cat > fetchAll.js <<'EOF'
// Resolves the value of every id with the given async loader, in order.
async function fetchAll(ids, load) {
  const results = [];
  ids.forEach(async (id) => {
    results.push(await load(id));
  });
  return results;
}
module.exports = { fetchAll };
EOF
