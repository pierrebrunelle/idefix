#!/usr/bin/env python3
"""Benchmark matrix: harnesses x tasks x reps -> results.jsonl + logs.

Each run copies the task repo to a temp dir, runs the harness with a
watchdog timeout, records pass/fail via the task's independent verify.sh,
and captures the child process peak RSS via wait4 rusage.

Before the harness runs, every file matching the task's meta.json
"protected" globs (default ["test_*"]) is sha256-snapshotted; a changed
or deleted protected file marks the row tampered and fails it. Rows carry
run_id, ts and bench_version so batches stay distinguishable.
"""
import fnmatch
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TASKS_DIR = os.path.join(ROOT, "bench", "tasks")
RESULTS = os.environ.get("BENCH_RESULTS", os.path.join(ROOT, "bench", "results.jsonl"))
GEN_DIR = os.path.join(ROOT, "bench", ".generated")
TIMEOUT_S = int(os.environ.get("BENCH_TIMEOUT", "420"))
AGENT_MAX_SECONDS = TIMEOUT_S - 20  # inner budget must fire before watchdog
MODEL = os.environ.get("MAX_MODEL", "")
BASE = os.environ.get("MAX_BASE_URL", "http://127.0.0.1:8000/v1")
# pi and dsh use native OpenAI tool calling; bench/toolcall_proxy.py
# translates Qwen's Hermes <tool_call> text into structured tool_calls.
TOOLCALL_BASE = os.environ.get("BENCH_TOOLCALL_BASE", "http://127.0.0.1:8001/v1")
BENCH_VERSION = 1


def model_slug():
    return re.sub(r"[^a-z0-9]+", "-", (MODEL.split("/")[-1] or "model").lower()).strip("-") or "model"


LOGS = os.environ.get("BENCH_LOGS", os.path.join(ROOT, "bench", f"logs-{model_slug()}"))


def mojo_cmd(repo, task_text, transcript):
    return [
        os.path.join(ROOT, "max"),
        "--repo", repo,
        "--max-requests", "15",
        "--max-seconds", str(AGENT_MAX_SECONDS),
        "--temperature", "0.6",
        "--transcript", transcript,
        "--bare",  # disable product features so the wire protocol matches ref_client
        task_text,
    ], {}


def maxv2_cmd(repo, task_text, transcript):
    # same arm as mojo minus --bare: journal, compaction and retries stay on
    cmd, env = mojo_cmd(repo, task_text, transcript)
    cmd.remove("--bare")
    return cmd, {"MAX_STATE_DIR": os.path.join(repo, ".max-state")}


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
    for dirpath, _, files in os.walk(repo):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            (readonly if f.startswith("test_") else editable).append(p)
    cmd = [
        "uv", "tool", "run", "--python", "3.12", "--from", "aider-chat==0.86.2", "aider",
        "--model", f"openai/{MODEL}",
        "--openai-api-base", BASE,
        "--model-settings-file", os.path.join(GEN_DIR, "aider-model-settings.yml"),
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
    ], {"PI_CODING_AGENT_DIR": os.path.join(GEN_DIR, "pi-agent")}


def opencode_cmd(repo, task_text, transcript):
    return [
        "opencode", "run", "--format", "json",
        "-m", f"max/{MODEL}",
        task_text,
    ], {"OPENCODE_CONFIG": os.path.join(GEN_DIR, "opencode.json")}


def dsh_cmd(repo, task_text, transcript):
    return [
        "dsh", "--profile", "headless",
        "--patch", os.path.join(GEN_DIR, "dsh-max.patch.yml"),
        "--json",
        task_text,
    ], {
        "DSH_MAX_API_KEY": "dummy",
        "DSH_HOME": os.path.join(ROOT, "bench", "dsh-home"),
    }


HARNESS = {"mojo": mojo_cmd, "maxv2": maxv2_cmd, "ref": ref_cmd, "aider": aider_cmd,
           "pi": pi_cmd, "dsh": dsh_cmd, "opencode": opencode_cmd}


def configure_backends():
    """Render provider configs for MODEL into bench/.generated/ (gitignored);
    committed templates stay untouched and unpinned."""
    os.makedirs(GEN_DIR, exist_ok=True)
    # aider: extra_params lands verbatim in litellm.completion for all models
    with open(os.path.join(GEN_DIR, "aider-model-settings.yml"), "w") as f:
        f.write("- name: aider/extra_params\n  extra_params:\n    temperature: 0.6\n")
    # pi: copy the agent dir (auth.json, models-store.json), rewrite models.json
    src = os.path.join(ROOT, "bench", "pi-agent")
    dst = os.path.join(GEN_DIR, "pi-agent")
    shutil.copytree(src, dst, dirs_exist_ok=True)
    pj = os.path.join(dst, "models.json")
    cfg = json.load(open(pj))
    cfg["providers"]["max"]["models"] = [
        {"id": MODEL, "samplingParams": {"temperature": 0.6}}]
    with open(pj, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    # dsh: patch overlay; samplingParams lives in the committed template
    txt = open(os.path.join(ROOT, "bench", "dsh-max.patch.yml")).read()
    txt = re.sub(r"(\n\s+- id: ).+", rf"\g<1>{MODEL}", txt)
    txt = re.sub(r"(    model: ).+", rf"\g<1>{MODEL}", txt)
    with open(os.path.join(GEN_DIR, "dsh-max.patch.yml"), "w") as f:
        f.write(txt)
    oc = json.load(open(os.path.join(ROOT, "bench", "opencode.json")))
    oc["provider"]["max"]["models"] = {MODEL: {"temperature": 0.6}}
    with open(os.path.join(GEN_DIR, "opencode.json"), "w") as f:
        json.dump(oc, f, indent=2)
        f.write("\n")


def preflight(harnesses):
    """Abort before the loop when a required endpoint is unreachable."""
    checks = [("MAX server", BASE)]
    if {"pi", "dsh", "opencode"} & set(harnesses):
        checks.append(("toolcall_proxy", TOOLCALL_BASE))
    down = []
    for label, base in checks:
        try:
            urllib.request.urlopen(base + "/models", timeout=5).close()
        except Exception:
            down.append(f"{label} ({base}/models)")
    if down:
        sys.exit("preflight: unreachable: " + ", ".join(down))


def make_run_id():
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        sha = "nogit"
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + sha


def protected_globs(tdir):
    meta = os.path.join(tdir, "meta.json")
    if os.path.exists(meta):
        return json.load(open(meta)).get("protected", ["test_*"])
    return ["test_*"]


def snapshot_protected(repo, globs):
    snap = {}
    for dirpath, _, files in os.walk(repo):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), repo)
            if any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(name, g) for g in globs):
                with open(os.path.join(dirpath, name), "rb") as f:
                    snap[rel] = hashlib.sha256(f.read()).hexdigest()
    return snap


def check_protected(repo, snap):
    """Return the list of protected files changed or deleted since snapshot."""
    bad = []
    for rel, want in snap.items():
        try:
            with open(os.path.join(repo, rel), "rb") as f:
                got = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            bad.append(rel + " (deleted)")
            continue
        if got != want:
            bad.append(rel)
    return bad


def kill_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def run_harness(name, repo, task_text, transcript_path):
    cmd, extra_env = HARNESS[name](repo, task_text, transcript_path)
    env = dict(os.environ, **extra_env)
    start = time.time()
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env, cwd=repo, start_new_session=True,
    )
    chunks = []

    def drain():
        while True:
            b = proc.stdout.read(8192)
            if not b:
                break
            chunks.append(b)

    t = threading.Thread(target=drain, daemon=True)
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
            killed = True
            kill_group(proc.pid, signal.SIGTERM)
            for _ in range(50):  # ~5s grace for the group to exit
                pid, status, ru = os.wait4(proc.pid, os.WNOHANG)
                if pid == proc.pid:
                    break
                time.sleep(0.1)
            else:
                kill_group(proc.pid, signal.SIGKILL)
                pid, status, ru = os.wait4(proc.pid, 0)
            break
        time.sleep(0.1)
    t.join(timeout=5)
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
    if name == "opencode":
        events = []
        for line in log.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        def walk(o):
            # usage objects live under step_finish payloads at varying depth
            if isinstance(o, dict):
                if "tokens" in o and isinstance(o["tokens"], dict):
                    yield o["tokens"]
                for v in o.values():
                    yield from walk(v)
            elif isinstance(o, list):
                for v in o:
                    yield from walk(v)
        usages = []
        for e in events:
            if e.get("type") == "step_finish":
                usages.extend(walk(e))
        last = usages[-1] if usages else {}
        inp = (last.get("input") or 0) + (last.get("cache", {}).get("read") or 0)
        return {
            "requests": sum(1 for e in events if e.get("type") == "step_start") or None,
            "commands": sum(
                1 for e in events
                if e.get("type") == "tool_use"
                and "bash" in str(e.get("part", {}).get("tool", e.get("tool", "")))
            ) or None,
            "prompt_tokens": inp or None,
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
    bad = [h for h in harnesses if h not in HARNESS]
    if bad:
        sys.exit(f"unknown harness: {', '.join(bad)} (have: {', '.join(HARNESS)})")
    tasks = sorted(d for d in os.listdir(TASKS_DIR) if os.path.isdir(os.path.join(TASKS_DIR, d)))
    if os.environ.get("BENCH_TASKS"):
        wanted = set(os.environ["BENCH_TASKS"].split(","))
        tasks = [t for t in tasks if t in wanted]
    preflight(harnesses)
    if {"aider", "pi", "dsh", "opencode"} & set(harnesses):
        configure_backends()
    os.makedirs(LOGS, exist_ok=True)
    batch = make_run_id()
    for task in tasks:
        tdir = os.path.join(TASKS_DIR, task)
        task_text = open(os.path.join(tdir, "task.txt")).read().strip()
        globs = protected_globs(tdir)
        for rep in range(1, reps + 1):
            for client in harnesses:
                repo = tempfile.mkdtemp(prefix=f"bench-{task}-")
                shutil.copytree(os.path.join(tdir, "repo"), repo, dirs_exist_ok=True)
                transcript = os.path.join(repo, "transcript.json")
                snap = snapshot_protected(repo, globs)
                print(f"[{client} {task} rep{rep}] running...", flush=True)
                r = run_harness(client, repo, task_text, transcript)
                tampered = check_protected(repo, snap)
                if tampered:
                    r["log"] += "\n[bench] tamper guard: protected files changed: " \
                        + ", ".join(tampered) + "\n"
                vf = subprocess.run(
                    [os.path.join(tdir, "verify.sh"), repo],
                    capture_output=True,
                )
                row = {
                    "client": client,
                    "task": task,
                    "rep": rep,
                    "model": MODEL,
                    "run_id": batch,
                    "ts": int(time.time()),
                    "bench_version": BENCH_VERSION,
                    "pass": vf.returncode == 0 and not tampered,
                    **stats_for(client, r["log"]),
                    "wall_s": r["wall_s"],
                    "maxrss_mb": r["maxrss_mb"],
                    "exit": r["exit"],
                    "timeout": r["timeout"],
                }
                if tampered:
                    row["tampered"] = True
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
