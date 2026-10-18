#!/usr/bin/env python3
"""Benchmark matrix: clients x tasks x reps -> results.jsonl + transcripts.

Each run copies the task repo to a temp dir, runs the client with a
watchdog timeout, records pass/fail via the task's independent verify.sh,
and captures the child process peak RSS via wait4 rusage.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TASKS_DIR = os.path.join(ROOT, "bench", "tasks")
RESULTS = os.path.join(ROOT, "bench", "results.jsonl")
LOGS = os.path.join(ROOT, "bench", "logs")
TIMEOUT_S = int(os.environ.get("BENCH_TIMEOUT", "420"))
AGENT_MAX_SECONDS = TIMEOUT_S - 20  # inner budget must fire before watchdog


def run_client(client, repo, task_text, transcript_path):
    if client == "mojo":
        cmd = [
            os.path.join(ROOT, "agent"),
            "--repo", repo,
            "--max-requests", "15",
            "--max-seconds", str(AGENT_MAX_SECONDS),
            "--temperature", "0.6",
            "--transcript", transcript_path,
            task_text,
        ]
    else:
        cmd = [
            sys.executable,
            os.path.join(ROOT, "tests", "ref_client.py"),
            "--repo", repo,
            task_text,
        ]
    start = time.time()
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=os.environ
    )
    chunks = []

    def drain():
        while True:
            b = proc.stdout.read(8192)
            if not b:
                break
            chunks.append(b)

    t = threading.Thread(target=drain)
    t.start()
    deadline = start + TIMEOUT_S
    killed = False
    ru = None
    status = 0
    while True:
        pid, status, ru = os.wait4(proc.pid, os.WNOHANG)
        if pid == proc.pid:
            break
        if time.time() > deadline:
            # SIGTERM so the agent's shim can kill the child process group
            proc.terminate()
            pid, status, ru = os.wait4(proc.pid, 0)
            killed = True
            break
        time.sleep(0.1)
    t.join()
    wall = time.time() - start
    return {
        "log": b"".join(chunks).decode("utf8", "replace"),
        "exit": os.waitstatus_to_exitcode(status),
        "wall_s": round(wall, 1),
        "maxrss_mb": round(ru.ru_maxrss / 1e6, 1) if ru else None,
        "timeout": killed,
    }


def stat(log, key):
    m = re.findall(key + r"=(\d+)", log)
    return int(m[-1]) if m else None


def main():
    reps = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    tasks = sorted(d for d in os.listdir(TASKS_DIR) if os.path.isdir(os.path.join(TASKS_DIR, d)))
    os.makedirs(LOGS, exist_ok=True)
    for task in tasks:
        tdir = os.path.join(TASKS_DIR, task)
        task_text = open(os.path.join(tdir, "task.txt")).read().strip()
        for rep in range(1, reps + 1):
            for client in ("mojo", "ref"):
                repo = tempfile.mkdtemp(prefix=f"bench-{task}-")
                shutil.copytree(os.path.join(tdir, "repo"), repo, dirs_exist_ok=True)
                transcript = os.path.join(repo, "transcript.json")
                print(f"[{client} {task} rep{rep}] running...", flush=True)
                r = run_client(client, repo, task_text, transcript)
                vf = subprocess.run(
                    [os.path.join(tdir, "verify.sh"), repo],
                    capture_output=True,
                )
                row = {
                    "client": client,
                    "task": task,
                    "rep": rep,
                    "model": os.environ.get("MAX_MODEL", ""),
                    "pass": vf.returncode == 0,
                    "requests": stat(r["log"], "requests"),
                    "commands": stat(r["log"], "commands"),
                    "prompt_tokens": stat(r["log"], "prompt_tokens"),
                    "wall_s": r["wall_s"],
                    "maxrss_mb": r["maxrss_mb"],
                    "exit": r["exit"],
                    "timeout": r["timeout"],
                }
                with open(RESULTS, "a") as f:
                    f.write(json.dumps(row) + "\n")
                with open(os.path.join(LOGS, f"{client}-{task}-{rep}.log"), "w") as f:
                    f.write(r["log"])
                if os.path.exists(transcript):
                    shutil.copy(
                        transcript,
                        os.path.join(LOGS, f"{client}-{task}-{rep}.json"),
                    )
                print(f"  -> pass={row['pass']} reqs={row['requests']} wall={r['wall_s']}s rss={r['maxrss_mb']}MB", flush=True)
                shutil.rmtree(repo, ignore_errors=True)
    print("done")


if __name__ == "__main__":
    main()
