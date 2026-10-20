#!/usr/bin/env python3
"""Oracle-check every bench task: solution.patch applied to the pristine
repo must pass verify.sh without touching protected files, and the
unpatched repo must fail. Catches unsolvable tasks, false-negative
graders, and nondeterministic verifiers before they enter results."""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_matrix import check_protected, protected_globs  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(ROOT, "tasks")
VERIFY_TIMEOUT = int(os.environ.get("BENCH_VERIFY_TIMEOUT", "300"))


def run_verify(tdir, repo):
    return subprocess.run([os.path.join(tdir, "verify.sh"), repo],
                          capture_output=True, text=True, timeout=VERIFY_TIMEOUT)


def oracle_check(tdir):
    pristine = os.path.join(tdir, "repo")
    patch = os.path.join(tdir, "solution.patch")
    if not os.path.exists(patch):
        return "no solution.patch"
    work = tempfile.mkdtemp(prefix="oracle-")
    ctrl = tempfile.mkdtemp(prefix="oracle-pristine-")
    try:
        shutil.copytree(pristine, work, dirs_exist_ok=True)
        p = subprocess.run(["git", "apply", "--check", patch], cwd=work,
                           capture_output=True, text=True)
        if p.returncode != 0:
            return f"patch does not apply: {p.stderr.strip()}"
        subprocess.run(["git", "apply", patch], cwd=work, check=True)
        bad = check_protected(work, pristine, protected_globs(tdir))
        if bad:
            return f"patch touches protected files: {', '.join(bad)}"
        v = run_verify(tdir, work)
        if v.returncode != 0:
            tail = (v.stdout + v.stderr).strip().splitlines()[-3:]
            return f"verify fails on fixed repo: {' | '.join(tail)}"
        shutil.copytree(pristine, ctrl, dirs_exist_ok=True)
        v = run_verify(tdir, ctrl)
        if v.returncode == 0:
            return "verify passes on the UNPATCHED repo (grader cannot discriminate)"
        return None
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(ctrl, ignore_errors=True)


def main():
    tasks = sorted(d for d in os.listdir(TASKS)
                   if os.path.isdir(os.path.join(TASKS, d, "repo")))
    if not tasks:
        sys.exit("no tasks found under " + TASKS)
    fails = 0
    for t in tasks:
        try:
            err = oracle_check(os.path.join(TASKS, t))
        except subprocess.TimeoutExpired:
            err = f"verify timed out ({VERIFY_TIMEOUT}s)"
        if err:
            fails += 1
            print(f"FAIL {t}: {err}")
        else:
            print(f"ok   {t}")
    print(f"{len(tasks) - fails}/{len(tasks)} tasks oracle-verified")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
