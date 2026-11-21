#!/bin/bash
set -e
node -e '
const { parseCSV } = require("./csv.js");
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const cases = [
  ["a,b\n1,2\n", [["a","b"],["1","2"]]],
  ["x,\"y,z\"\r\n\"he said \"\"hi\"\"\",2", [["x","y,z"],["he said \"hi\"","2"]]],
  ["\"multi\nline\",3", [["multi\nline","3"]]],
  ["a,,c", [["a","","c"]]],
];
for (const [inp, want] of cases) { const got = parseCSV(inp); if (!eq(got, want)) { console.error(JSON.stringify(inp), JSON.stringify(got)); process.exit(1) } }
'
