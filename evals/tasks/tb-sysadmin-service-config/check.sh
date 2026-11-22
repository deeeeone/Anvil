#!/bin/bash
set -e
git diff --quiet -- validate.sh || { echo "validate.sh modified"; exit 1; }
./validate.sh | tail -1 | grep -qx OK
