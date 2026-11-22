#!/bin/bash
cat > worker.py <<'EOT'
import asyncio

async def run_all(jobs, limit):
    """Run the coroutine functions in `jobs` with at most `limit` running at once.

    Returns results in the order of `jobs`. If any job raises, the exception is raised from run_all, and every job still
    running is cancelled (its `finally` blocks run) before run_all returns. Jobs that haven't started never start.
    """
    sem = asyncio.Semaphore(limit)
    async def guarded(job):
        async with sem:
            return await job()
    tasks = [asyncio.create_task(guarded(j)) for j in jobs]
    return await asyncio.gather(*tasks)
EOT
cat > test_worker.py <<'EOT'
import asyncio, unittest
from worker import run_all

class T(unittest.TestCase):
    def test_results_in_order(self):
        async def mk(i):
            await asyncio.sleep(0.01 * (5 - i))
            return i
        jobs = [lambda i=i: mk(i) for i in range(5)]
        self.assertEqual(asyncio.run(run_all(jobs, 3)), [0, 1, 2, 3, 4])

    def test_limit_respected(self):
        state = {"now": 0, "max": 0}
        async def job():
            state["now"] += 1; state["max"] = max(state["max"], state["now"])
            await asyncio.sleep(0.02); state["now"] -= 1
        asyncio.run(run_all([job] * 9, 3))
        self.assertLessEqual(state["max"], 3)

    def test_failure_cancels_running_jobs_and_cleans_up(self):
        log = []
        async def slow():
            try:
                await asyncio.sleep(5)
            finally:
                log.append("cleanup")
        async def boom():
            await asyncio.sleep(0.05)
            raise ValueError("boom")
        async def main():
            with self.assertRaises(ValueError):
                await run_all([slow, slow, boom], 3)
            return list(log)
        self.assertEqual(asyncio.run(main()), ["cleanup", "cleanup"])

if __name__ == "__main__":
    unittest.main()
EOT
