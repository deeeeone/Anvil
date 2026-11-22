#!/bin/bash
set -e
git diff --quiet -- test_worker.py || { echo "tests modified"; exit 1; }
python3 -m unittest -q test_worker 2>&1 | tail -3
cat > /tmp/hidden_$$.py <<'EOT'
import asyncio, sys, time, unittest
sys.path.insert(0, ".")
from worker import run_all
class H(unittest.TestCase):
    def test_unstarted_jobs_never_start_after_failure(self):
        started = []
        async def boom():
            raise RuntimeError("x")
        def mk(i):
            async def j():
                started.append(i); await asyncio.sleep(0.05)
            return j
        async def main():
            with self.assertRaises(RuntimeError):
                await run_all([boom] + [mk(i) for i in range(6)], 1)
        asyncio.run(main())
        self.assertEqual(started, [])
    def test_outer_cancellation_cleans_up(self):
        log = []
        async def slow():
            try: await asyncio.sleep(10)
            finally: log.append("c")
        async def main():
            t = asyncio.create_task(run_all([slow, slow], 2))
            await asyncio.sleep(0.05); t.cancel()
            with self.assertRaises(asyncio.CancelledError): await t
            await asyncio.sleep(0.05)
            return list(log)
        self.assertEqual(asyncio.run(main()), ["c", "c"])
    def test_first_error_wins_and_returns_quickly(self):
        async def slow(): await asyncio.sleep(5)
        async def boom(): await asyncio.sleep(0.02); raise KeyError("k")
        async def main():
            t0 = time.time()
            with self.assertRaises(KeyError): await run_all([slow, boom, slow], 3)
            return time.time() - t0
        self.assertLess(asyncio.run(main()), 1.0)
unittest.main(argv=["x"], exit=True)
EOT
python3 /tmp/hidden_$$.py 2>&1 | tail -4; rc=${PIPESTATUS[0]}; rm -f /tmp/hidden_$$.py; exit $rc
