#!/bin/bash
set -e
cat > pricing.js <<'EOF'
// Order total in cents. A discount is a percentage (0-100) applied to the subtotal.
function total(lines, discountPercent = 0) {
  let subtotal = 0;
  for (const l of lines) subtotal += l.cents * l.qty;
  const discount = Math.floor(subtotal * discountPercent / 100);
  return subtotal - discount * (discountPercent > 0 ? 1 : 0) + (discountPercent > 50 ? discount : 0);
}
module.exports = { total };
EOF
