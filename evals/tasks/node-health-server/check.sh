#!/bin/bash
set -e
PORT=38211 node server.js & pid=$!
trap "kill $pid 2>/dev/null" EXIT
for i in $(seq 1 30); do curl -s localhost:38211/health >/dev/null && break; sleep 0.2; done
body=$(curl -s localhost:38211/health); ct=$(curl -s -o /dev/null -w '%{content_type}' localhost:38211/health)
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:38211/nope)
echo "$body" | python3 -c "import json,sys; assert json.load(sys.stdin)=={'status':'ok'}" || { echo "body $body"; exit 1; }
case "$ct" in application/json*) ;; *) echo "ct $ct"; exit 1;; esac
[ "$code" = "404" ] || { echo "code $code"; exit 1; }
