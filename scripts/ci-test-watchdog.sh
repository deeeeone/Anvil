#!/usr/bin/env bash
# Runs `swift test` and, if it prints nothing for STALL seconds, dumps every thread's stack and the process list,
# then kills it. Used by CI on Linux to find hangs. Usage: scripts/ci-test-watchdog.sh [swift test args...]
set -u
STALL=${STALL:-90}
LOG=${LOG:-test.log}
swift test "$@" > "$LOG" 2>&1 &
runner=$!
last=$(stat -c %s "$LOG" 2>/dev/null || echo 0); quiet=0
while kill -0 "$runner" 2>/dev/null; do
  sleep 5
  now=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$now" != "$last" ]; then last=$now; quiet=0; continue; fi
  quiet=$((quiet + 5))
  if [ "$quiet" -ge "$STALL" ]; then
    echo "=== no output for ${STALL}s; last lines:"; tail -8 "$LOG"
    echo "=== processes"; ps -eo pid,ppid,stat,etime,args | grep -v " ps -eo"
    for pid in $(pgrep -f '\.xctest' || true); do
      echo "=== stacks of $pid"
      gdb -p "$pid" -batch -ex "thread apply all bt 25" 2>/dev/null | grep -E "^Thread|^#[0-9]+ " \
        | grep -vE " in (__GI_|__futex|futex_|syscall|pthread_cond|__lll_|clock_nanosleep)" | head -250
    done
    pkill -9 -f '\.xctest' || true; kill -9 "$runner" 2>/dev/null || true
    grep -E "Test Case .* failed" "$LOG" | sort -u
    exit 99
  fi
done
wait "$runner"; rc=$?
grep -E "Test Case .* failed|Executed [0-9]+ tests" "$LOG" | sort -u | tail -15
exit $rc
