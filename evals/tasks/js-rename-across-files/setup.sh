#!/bin/bash
set -e
mkdir -p lib
cat > lib/math.js <<'EOF'
function calc(items) { return items.reduce((s, i) => s + i.price * i.qty, 0); }
module.exports = { calc };
EOF
cat > lib/cart.js <<'EOF'
const { calc } = require("./math");
function summary(items) { return "Total: " + calc(items).toFixed(2); }
module.exports = { summary };
EOF
cat > index.js <<'EOF'
const { calc } = require("./lib/math");
const { summary } = require("./lib/cart");
const items = [{ price: 2.5, qty: 2 }, { price: 1, qty: 3 }];
console.log(calc(items), summary(items));
EOF
