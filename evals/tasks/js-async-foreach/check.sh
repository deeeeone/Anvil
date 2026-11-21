#!/bin/bash
set -e
node -e '
const { fetchAll } = require("./fetchAll.js");
const load = (id) => new Promise(r => setTimeout(() => r(id * 10), 30 - id));
fetchAll([1,2,3], load).then(r => { if (JSON.stringify(r) !== "[10,20,30]") { console.error(r); process.exit(1) } });
'
