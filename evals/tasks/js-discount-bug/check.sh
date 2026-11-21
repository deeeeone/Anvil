#!/bin/bash
set -e
node -e '
const { total } = require("./pricing.js");
const t = [[[{cents:1000,qty:2}],0,2000],[[{cents:1000,qty:2}],10,1800],[[{cents:999,qty:1}],60,400],[[{cents:333,qty:3}],100,0],[[{cents:150,qty:1}],33,101]];
for (const [l,d,w] of t) { const g = total(l,d); if (g !== w) { console.error(d, g, w); process.exit(1) } }
'
