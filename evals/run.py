#!/usr/bin/env python3
"""Anvil eval runner.

Runs every task in evals/tasks against one or more models with the headless agent, checks the result with each
task's hidden check.sh, and prints pass rate, steps, time and cost per model.

  python3 evals/run.py                                  # default model, all tasks
  python3 evals/run.py --models glm-5.3-flash-uncensored,gpt-6-luna,gemini-auto
  python3 evals/run.py --tasks py-,js-csv --parallel 4 -- --no-review    # extra args go to the agent

Keys come from Peep's Keychain entries (never printed). Results are appended to evals/results/<timestamp>.jsonl.
"""
import argparse, concurrent.futures as cf, json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
APP = os.path.join(ROOT, "build/Build/Products/Debug/Anvil.app/Contents/MacOS/Anvil")


def keychain(service, account):
    r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def run_one(model, task, work, env, extra, timeout):
    tdir = os.path.join(HERE, "tasks", task)
    proj = os.path.join(work, model, task)
    shutil.rmtree(proj, ignore_errors=True)
    os.makedirs(proj)
    subprocess.run(["bash", os.path.join(tdir, "setup.sh")], cwd=proj, check=True, capture_output=True)
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=e@x", "-c", "user.name=eval", "commit", "-qm", "setup", "--allow-empty"]):
        subprocess.run(cmd, cwd=proj, capture_output=True)
    prompt = open(os.path.join(tdir, "prompt.txt")).read().strip()
    summary = os.path.join(work, model, task + ".summary.json")
    log = os.path.join(work, model, task + ".log")
    args = [APP, "--headless", "--project", proj, "--prompt", prompt, "--mode", "bypass", "--model", model,
            "--json-summary", summary, "--timeout", str(timeout), "--max-steps", "40"] + extra
    t0 = time.time()
    with open(log, "w") as f:
        try:
            subprocess.run(args, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=timeout + 60)
        except subprocess.TimeoutExpired:
            f.write("\n[runner timeout]\n")
    secs = time.time() - t0
    s = {}
    if os.path.exists(summary):
        s = json.load(open(summary))
    cenv = dict(os.environ, ANVIL_ANSWER=s.get("answer", ""), PYTHONDONTWRITEBYTECODE="1")
    c = subprocess.run(["bash", os.path.join(tdir, "check.sh")], cwd=proj, capture_output=True, text=True, env=cenv, timeout=120)
    return {"model": model, "task": task, "pass": c.returncode == 0, "agent_ok": s.get("ok", False), "steps": s.get("steps", 0),
            "seconds": round(s.get("seconds", secs), 1), "cost": s.get("cost", 0.0), "calls": s.get("calls", 0),
            "check": (c.stdout + c.stderr).strip()[-300:], "log": log}


def main():
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="glm-5.3-flash-uncensored")
    ap.add_argument("--tasks", default="", help="comma-separated name prefixes")
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--label", default="")
    a = ap.parse_args(argv)
    if not os.path.exists(APP):
        sys.exit("build the app first: xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build build")

    tasks = sorted(os.listdir(os.path.join(HERE, "tasks")))
    if a.tasks:
        pre = a.tasks.split(",")
        tasks = [t for t in tasks if any(t.startswith(p) for p in pre)]
    models = a.models.split(",")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    work = os.path.join("/tmp", "anvil-evals", stamp)
    os.makedirs(work, exist_ok=True)
    env = dict(os.environ, ANVIL_API_KEY=keychain("com.diwan.peep", "primaryKey"), ANVIL_GEMINI_KEY=keychain("com.diwan.peep", "apiKey"),
               ANVIL_SUPPORT_DIR=os.path.join(work, "support"))
    for m in models:
        os.makedirs(os.path.join(work, m), exist_ok=True)

    jobs = [(m, t) for m in models for t in tasks]
    print(f"{len(jobs)} runs ({len(models)} models x {len(tasks)} tasks), {a.parallel} at a time; work dir {work}")
    results = []
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out_path = os.path.join(HERE, "results", f"{stamp}{'-' + a.label if a.label else ''}.jsonl")
    with cf.ThreadPoolExecutor(a.parallel) as ex, open(out_path, "w") as out:
        futs = {ex.submit(run_one, m, t, work, env, extra, a.timeout): (m, t) for m, t in jobs}
        for f in cf.as_completed(futs):
            r = f.result()
            r["extra"] = " ".join(extra)
            results.append(r)
            out.write(json.dumps(r) + "\n"); out.flush()
            print(f"  {'PASS' if r['pass'] else 'FAIL'}  {r['model']:<32} {r['task']:<24} {r['steps']:>2} steps {r['seconds']:>6.1f}s ${r['cost']:.4f}"
                  + ("" if r["pass"] else f"   {r['check'][-120:]!r}"))

    print("\nmodel                              pass    avg steps  avg time   total cost")
    for m in models:
        rs = [r for r in results if r["model"] == m]
        p = sum(r["pass"] for r in rs)
        print(f"{m:<34} {p:>2}/{len(rs):<4} {sum(r['steps'] for r in rs)/len(rs):>8.1f} {sum(r['seconds'] for r in rs)/len(rs):>8.1f}s  ${sum(r['cost'] for r in rs):.4f}")
    print(f"\nresults: {out_path}")


if __name__ == "__main__":
    main()
