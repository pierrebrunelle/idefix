#!/usr/bin/env python3
"""Benchmark matrix: harnesses x tasks x reps -> results.jsonl + logs.

Each run copies the task repo to a temp dir, runs the harness with a
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
RESULTS = os.environ.get("BENCH_RESULTS", os.path.join(ROOT, "bench", "results.jsonl"))
LOGS = os.environ.get("BENCH_LOGS", os.path.join(ROOT, "bench", "logs"))
TIMEOUT_S = int(os.environ.get("BENCH_TIMEOUT", "420"))
AGENT_MAX_SECONDS = TIMEOUT_S - 20  # inner budget must fire before watchdog
MODEL = os.environ.get("MAX_MODEL", "")
BASE = os.environ.get("MAX_BASE_URL", "http://127.0.0.1:8000/v1")
# pi and dsh use native OpenAI tool calling; bench/toolcall_proxy.py
# translates Qwen's Hermes <tool_call> text into structured tool_calls.
TOOLCALL_BASE = os.environ.get("BENCH_TOOLCALL_BASE", "http://127.0.0.1:8001/v1")


def mojo_cmd(repo, task_text, transcript):
    return [
        os.path.join(ROOT, "agent"),
        "--repo", repo,
        "--max-requests", "15",
        "--max-seconds", str(AGENT_MAX_SECONDS),
        "--temperature", "0.6",
        "--transcript", transcript,
        task_text,
    ], {}


def ref_cmd(repo, task_text, transcript):
    return [
        sys.executable,
        os.path.join(ROOT, "tests", "ref_client.py"),
        "--repo", repo,
        task_text,
    ], {}


def aider_cmd(repo, task_text, transcript):
    # source files editable, test files read-only so the tests cannot be gamed
    editable, readonly = [], []
    for f in sorted(os.listdir(repo)):
        p = os.path.join(repo, f)
        if not os.path.isfile(p):
            continue
        (readonly if f.startswith("test_") else editable).append(p)
    cmd = [
        "uv", "tool", "run", "--python", "3.12", "--from", "aider-chat", "aider",
        "--model", f"openai/{MODEL}",
        "--openai-api-base", BASE,
        "--yes", "--no-git", "--no-show-model-warnings", "--no-pretty",
    ]
    cmd += sum((["--file", f] for f in editable), [])
    cmd += sum((["--read", f] for f in readonly), [])
    cmd += ["--message", task_text]
    return cmd, {"OPENAI_API_KEY": "dummy"}


def pi_cmd(repo, task_text, transcript):
    return [
        "pi", "-p",
        "--model", f"max/{MODEL}",
        "--mode", "json",
        "--no-context-files", "--no-extensions", "--no-mcp", "--no-session",
        task_text,
    ], {"PI_CODING_AGENT_DIR": os.path.join(ROOT, "bench", "pi-agent")}


def dsh_cmd(repo, task_text, transcript):
    return [
        "dsh", "--profile", "headless",
        "--patch", os.path.join(ROOT, "bench", "dsh-max.patch.yml"),
        "--json",
        task_text,
    ], {
        "DSH_MAX_API_KEY": "dummy",
        "DSH_HOME": os.path.join(ROOT, "bench", "dsh-home"),
    }


HARNESS = {"mojo": mojo_cmd, "ref": ref_cmd, "aider": aider_cmd, "pi": pi_cmd, "dsh": dsh_cmd}


def run_harness(name, repo, task_text, transcript_path):
    cmd, extra_env = HARNESS[name](repo, task_text, transcript_path)
    env = dict(os.environ, **extra_env)
    start = time.time()
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env, cwd=repo,
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


def stats_for(name, log):
    if name == "aider":
        toks = re.findall(r"Tokens: ([\d,]+) sent", log)
        return {
            "requests": len(toks) or None,
            "commands": len(re.findall(r"^\s*/?run\b|Running ", log, re.M)) or None,
            "prompt_tokens": int(toks[-1].replace(",", "")) if toks else None,
        }
    if name == "pi":
        events = []
        for line in log.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        usage = [
            e["usage"] for e in events
            if e.get("type") == "message_update" and isinstance(e.get("usage"), dict)
        ]
        return {
            "requests": sum(
                1 for e in events
                if e.get("type") == "message_start"
                and e.get("message", {}).get("role") == "assistant"
            ) or None,
            "commands": sum(
                1 for e in events
                if e.get("type") == "tool_execution_start"
                and e.get("toolName") in ("bash", "run")
            ) or None,
            "prompt_tokens": (usage[-1]["input"] + usage[-1].get("cacheRead", 0))
            if usage else None,
        }
    if name == "dsh":
        events = []
        for line in log.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        steps = [
            e for e in events
            if e.get("type") == "status" and e.get("phase") == "step_end"
        ]
        usage = [e["usage"] for e in steps if isinstance(e.get("usage"), dict)]
        return {
            "requests": len(steps) or None,
            "commands": sum(
                1 for e in events
                if (e.get("type") in ("tool_call", "tool_start")
                    or e.get("phase") == "tool_start")
                and "bash" in str(e.get("name") or e.get("toolName") or e.get("tool") or "")
            ) or None,
            "prompt_tokens": (
                usage[-1]["inputTokens"] + usage[-1].get("cacheReadTokens", 0)
            ) if usage else None,
        }
    out = {}
    for key in ("requests", "commands", "prompt_tokens"):
        m = re.findall(key + r"=(\d+)", log)
        out[key] = int(m[-1]) if m else None
    return out


def main():
    reps = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    harnesses = sys.argv[2].split(",") if len(sys.argv) > 2 else list(HARNESS)
    tasks = sorted(d for d in os.listdir(TASKS_DIR) if os.path.isdir(os.path.join(TASKS_DIR, d)))
    os.makedirs(LOGS, exist_ok=True)
    for task in tasks:
        tdir = os.path.join(TASKS_DIR, task)
        task_text = open(os.path.join(tdir, "task.txt")).read().strip()
        for rep in range(1, reps + 1):
            for client in harnesses:
                repo = tempfile.mkdtemp(prefix=f"bench-{task}-")
                shutil.copytree(os.path.join(tdir, "repo"), repo, dirs_exist_ok=True)
                transcript = os.path.join(repo, "transcript.json")
                print(f"[{client} {task} rep{rep}] running...", flush=True)
                r = run_harness(client, repo, task_text, transcript)
                vf = subprocess.run(
                    [os.path.join(tdir, "verify.sh"), repo],
                    capture_output=True,
                )
                row = {
                    "client": client,
                    "task": task,
                    "rep": rep,
                    "model": MODEL,
                    "pass": vf.returncode == 0,
                    **stats_for(client, r["log"]),
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
