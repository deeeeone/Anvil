cat > worker.py <<'EOT'
import asyncio

async def run_all(jobs, limit):
    """Run the coroutine functions in `jobs` with at most `limit` running at once.

    Returns results in the order of `jobs`. If any job raises, the exception is raised from run_all, and every job still
    running is cancelled (its `finally` blocks run) before run_all returns. Jobs that haven't started never start.
    """
    sem = asyncio.Semaphore(limit)
    failed = False
    async def guarded(job):
        nonlocal failed
        async with sem:
            if failed:
                raise asyncio.CancelledError()
            try:
                return await job()
            except BaseException:
                failed = True      # set before the semaphore is released, so waiting jobs never start
                raise
    tasks = [asyncio.create_task(guarded(j)) for j in jobs]
    try:
        pending = set(tasks)
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for t in done:
                if not t.cancelled() and t.exception() is not None:
                    failed = True
                    raise t.exception()
        return [t.result() for t in tasks]
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
EOT
