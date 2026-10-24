#!/usr/bin/env python3
"""Benchmark matrix: harnesses x tasks x reps -> results.jsonl + logs.

Each run copies the task repo to a temp dir, runs the harness with a
watchdog timeout, records pass/fail via the task's independent verify.sh,
and captures the child process peak RSS via wait4 rusage.

After each run, files matching the task's meta.json "protected" globs
(default ["test_*"]) are compared against the task's pristine repo/; a
changed, deleted or added protected file marks the row tampered and fails
it. The protected list is appended to the task prompt so the constraint
is never invisible. Rows carry run_id, ts and bench_version; logs land
under logs-<model>/<run_id>/.
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
# external arms (aider, pi, dsh, opencode) read provider configs from
# EXT_DIR; those files live in pierrebrunelle/max-results/compare/
EXT_DIR = os.environ.get("BENCH_EXT_DIR", os.path.join(ROOT, "bench"))
BENCH_VERSION = 2
TEMPERATURE = 0.6
DEFAULT_PROTECTED = ["test_*"]
USAGE = ("usage: run_matrix.py [reps] [harness,...]\n"
         "  harnesses: mojo, max, ref, aider, pi, dsh, opencode\n"
         "  env: MAX_MODEL (required), MAX_BASE_URL, BENCH_TOOLCALL_BASE,\n"
         "       BENCH_RESULTS, BENCH_LOGS, BENCH_TIMEOUT, BENCH_TASKS,\n"
         "       BENCH_MAX_REQ, BENCH_EXT_DIR")


def model_slug():
    return re.sub(r"[^a-z0-9]+", "-", (MODEL.split("/")[-1] or "model").lower()).strip("-") or "model"


LOGS = os.environ.get("BENCH_LOGS", os.path.join(ROOT, "bench", f"logs-{model_slug()}"))


def mojo_cmd(repo, task_text, transcript, globs):
    return [
        os.path.join(ROOT, "max"),
        "--repo", repo,
        "--max-requests", os.environ.get("BENCH_MAX_REQ", "15"),
        "--max-seconds", str(AGENT_MAX_SECONDS),
        "--temperature", str(TEMPERATURE),
        "--transcript", transcript,
        "--bare",  # disable product features so the wire protocol matches ref_client
        task_text,
    ], {}


def max_cmd(repo, task_text, transcript, globs):
    # same arm as mojo minus --bare: journal, compaction and retries stay on
    cmd, env = mojo_cmd(repo, task_text, transcript, globs)
    cmd.remove("--bare")
    return cmd, dict(env, MAX_STATE_DIR=os.path.join(repo, ".max-state"))


def ref_cmd(repo, task_text, transcript, globs):
    return [
        sys.executable,
        os.path.join(ROOT, "tests", "ref_client.py"),
        "--repo", repo,
        task_text,
    ], {}


def aider_cmd(repo, task_text, transcript, globs):
    # task-protected files are read-only so they cannot be gamed
    editable, readonly = [], []
    for dirpath, _, files in os.walk(repo):
        for f in files:
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, repo)
            if protected_matches(rel, f, globs):
                readonly.append(p)
            else:
                editable.append(p)
    editable.sort()
    readonly.sort()
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


def pi_cmd(repo, task_text, transcript, globs):
    return [
        "pi", "-p",
        "--model", f"max/{MODEL}",
        "--mode", "json",
        "--no-context-files", "--no-extensions", "--no-mcp", "--no-session",
        task_text,
    ], {"PI_CODING_AGENT_DIR": os.path.join(GEN_DIR, "pi-agent")}


def opencode_cmd(repo, task_text, transcript, globs):
    return [
        "opencode", "run", "--format", "json",
        "-m", f"max/{MODEL}",
        task_text,
    ], {"OPENCODE_CONFIG": os.path.join(GEN_DIR, "opencode.json")}


def dsh_cmd(repo, task_text, transcript, globs):
    return [
        "dsh", "--profile", "headless",
        "--patch", os.path.join(GEN_DIR, "dsh-max.patch.yml"),
        "--json",
        task_text,
    ], {
        "DSH_MAX_API_KEY": "dummy",
        "DSH_HOME": os.path.join(GEN_DIR, "dsh-home"),
    }


HARNESS = {"mojo": mojo_cmd, "max": max_cmd, "ref": ref_cmd, "aider": aider_cmd,
           "pi": pi_cmd, "dsh": dsh_cmd, "opencode": opencode_cmd}


def configure_backends(harnesses):
    """Render provider configs for MODEL into bench/.generated/ (gitignored);
    committed templates stay untouched and unpinned."""
    os.makedirs(GEN_DIR, exist_ok=True)
    if "aider" in harnesses:
        # aider/extra_params lands verbatim in litellm.completion for all models
        with open(os.path.join(GEN_DIR, "aider-model-settings.yml"), "w") as f:
            f.write(f"- name: aider/extra_params\n  extra_params:\n    temperature: {TEMPERATURE}\n")
    if "pi" in harnesses:
        # copy the agent dir (auth.json, models-store.json), rewrite models.json
        src = os.path.join(EXT_DIR, "pi-agent")
        dst = os.path.join(GEN_DIR, "pi-agent")
        shutil.copytree(src, dst, dirs_exist_ok=True)
        pj = os.path.join(dst, "models.json")
        with open(pj) as f:
            cfg = json.load(f)
        cfg["providers"]["max"]["models"] = [
            {"id": MODEL, "samplingParams": {"temperature": TEMPERATURE}}]
        with open(pj, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
    if "dsh" in harnesses:
        # dsh needs a profile home; render the skeleton under .generated so
        # nothing per-run is tracked
        home = os.path.join(GEN_DIR, "dsh-home", "profiles", "headless")
        os.makedirs(home, exist_ok=True)
        for name, body in {
            "cordis.yml": "[]\n",
            "cordis.patch.yml": "[]\n",
            "pnpm-workspace.yaml": "packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n",
            "package.json": json.dumps({
                "name": "dsh-profile-headless", "private": True,
                "dependencies": {},
                "dsh": {"profile": {"bundles": [
                    "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-headless"]}},
            }, indent=2) + "\n",
        }.items():
            with open(os.path.join(home, name), "w") as f:
                f.write(body)
        # patch overlay; samplingParams lives in the committed template. The
        # patterns anchor on the indented model entries so column-0 patch ids
        # can never match, even across a blank line.
        txt = open(os.path.join(EXT_DIR, "dsh-max.patch.yml")).read()
        txt = re.sub(r"(\n +- id: ).+", rf"\g<1>{MODEL}", txt)
        txt = re.sub(r"(\n    model: ).+", rf"\g<1>{MODEL}", txt)
        with open(os.path.join(GEN_DIR, "dsh-max.patch.yml"), "w") as f:
            f.write(txt)
    if "opencode" in harnesses:
        oc = json.load(open(os.path.join(EXT_DIR, "opencode.json")))
        # model-entry "temperature" is a boolean capability flag, not a value;
        # the sampling value belongs under options (opencode rejects a float)
        oc["provider"]["max"]["models"] = {
            MODEL: {"name": MODEL.split("/")[-1], "temperature": True,
                    "options": {"temperature": TEMPERATURE}}}
        with open(os.path.join(GEN_DIR, "opencode.json"), "w") as f:
            json.dump(oc, f, indent=2)
            f.write("\n")


def preflight(harnesses):
    """Abort before the loop when a required endpoint is unreachable or
    the MAX server is not serving MODEL."""
    checks = [("MAX server", BASE, True)]
    if {"pi", "dsh", "opencode"} & set(harnesses):
        checks.append(("toolcall_proxy", TOOLCALL_BASE, False))
    problems = []
    if {"aider", "pi", "dsh", "opencode"} & set(harnesses) and not os.path.isdir(
            os.path.join(EXT_DIR, "pi-agent")):
        problems.append(
            f"external-harness files not found in BENCH_EXT_DIR={EXT_DIR}\n"
            "  (clone pierrebrunelle/max-results and point BENCH_EXT_DIR at its compare/ dir)")

    for label, base, check_model in checks:
        try:
            data = json.loads(urllib.request.urlopen(base + "/models", timeout=5).read())
        except Exception:
            problems.append(f"{label} unreachable ({base}/models)")
            continue
        if check_model:
            ids = [m.get("id") for m in data.get("data", [])]
            if MODEL not in ids:
                problems.append(f"{MODEL} not served (have: {', '.join(ids) or 'none'})")
    if problems:
        sys.exit("preflight failed:\n  " + "\n  ".join(problems))


def make_run_id():
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        sha = "nogit"
    try:
        if subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=ROOT, capture_output=True, text=True,
        ).stdout.strip():
            sha += "-dirty"
    except Exception:
        pass
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + sha


def protected_globs(tdir):
    meta = os.path.join(tdir, "meta.json")
    if not os.path.exists(meta):
        return list(DEFAULT_PROTECTED)
    globs = json.load(open(meta)).get("protected", DEFAULT_PROTECTED)
    if not isinstance(globs, list) or not all(isinstance(g, str) for g in globs):
        sys.exit(f"{meta}: 'protected' must be a list of glob strings")
    return globs


def protected_matches(rel, name, globs):
    # a glob matches a file's repo-relative path or its basename, so `test_*`
    # covers nested test files and `data/*` covers everything under data/
    return any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(name, g) for g in globs)


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def check_protected(repo, pristine, globs):
    """Protected files changed, deleted, or added relative to the task's
    pristine repo/ — additions count, so a new test_*.py or data/x.csv is
    flagged. Dotdirs (.max-state) and the harness transcript are skipped."""
    bad = []
    for dirpath, _, files in os.walk(pristine):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), pristine)
            if not protected_matches(rel, name, globs):
                continue
            try:
                got = sha256_file(os.path.join(repo, rel))
            except OSError:
                bad.append(rel + " (deleted)")
                continue
            if got != sha256_file(os.path.join(dirpath, name)):
                bad.append(rel)
    for dirpath, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "__pycache__"]
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), repo)
            if rel == "transcript.json":
                continue
            if protected_matches(rel, name, globs) and not os.path.exists(
                    os.path.join(pristine, rel)):
                bad.append(rel + " (added)")
    return bad


def kill_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except OSError:
        pass


def run_harness(name, repo, task_text, transcript_path, globs):
    cmd, extra_env = HARNESS[name](repo, task_text, transcript_path, globs)
    env = dict(os.environ, **extra_env)
    start = time.time()
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env, cwd=repo, start_new_session=True,
        )
    except OSError as e:
        return {"log": f"[bench] failed to launch {cmd[0]}: {e}\n",
                "exit": 127, "wall_s": 0.0, "maxrss_mb": None, "timeout": False}
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
            # escalate whether or not the leader was reaped: group members
            # may have ignored SIGTERM and still be running
            kill_group(proc.pid, signal.SIGKILL)
            if pid != proc.pid:
                pid, status, ru = os.wait4(proc.pid, 0)
            break
        time.sleep(0.1)
    t.join(timeout=5)
    if t.is_alive():
        chunks.append(b"\n[bench] log truncated: output pipe still open\n")
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
    if len(sys.argv) > 3 or (len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help")):
        sys.exit(USAGE)
    try:
        reps = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    except ValueError:
        sys.exit(USAGE)
    if reps < 1:
        sys.exit(USAGE)
    harnesses = sys.argv[2].split(",") if len(sys.argv) > 2 else list(HARNESS)
    bad = [h for h in harnesses if h not in HARNESS]
    if bad:
        sys.exit(f"unknown harness: {', '.join(bad)} (have: {', '.join(HARNESS)})")
    if not MODEL:
        sys.exit("MAX_MODEL is not set (the model id to request, e.g. Qwen/Qwen3-14B)")
    tasks = sorted(d for d in os.listdir(TASKS_DIR) if os.path.isdir(os.path.join(TASKS_DIR, d)))
    if os.environ.get("BENCH_TASKS"):
        wanted = set(os.environ["BENCH_TASKS"].split(","))
        tasks = [t for t in tasks if t in wanted]
    if not tasks:
        sys.exit("no tasks matched" +
                 (" BENCH_TASKS" if os.environ.get("BENCH_TASKS") else ""))
    preflight(harnesses)
    configure_backends(harnesses)
    run_id = make_run_id()
    log_dir = os.path.join(LOGS, run_id)
    os.makedirs(log_dir, exist_ok=True)
    n = 0
    for task in tasks:
        tdir = os.path.join(TASKS_DIR, task)
        pristine = os.path.join(tdir, "repo")
        task_text = open(os.path.join(tdir, "task.txt")).read().strip()
        globs = protected_globs(tdir)
        if globs:
            task_text += ("\n\nDo not modify or delete files matching these "
                          "patterns: " + ", ".join(globs))
        for rep in range(1, reps + 1):
            for client in harnesses:
                repo = tempfile.mkdtemp(prefix=f"bench-{task}-")
                shutil.copytree(pristine, repo, dirs_exist_ok=True)
                transcript = os.path.join(repo, "transcript.json")
                print(f"[{client} {task} rep{rep}] running...", flush=True)
                r = run_harness(client, repo, task_text, transcript, globs)
                tampered = check_protected(repo, pristine, globs)
                if tampered:
                    r["log"] += "\n[bench] tamper guard: protected files changed: " \
                        + ", ".join(tampered) + "\n"
                try:
                    vf = subprocess.run(
                        [os.path.join(tdir, "verify.sh"), repo],
                        capture_output=True, timeout=300,
                    )
                    verified = vf.returncode == 0
                except subprocess.TimeoutExpired:
                    verified = False
                    r["log"] += "\n[bench] verify.sh timed out\n"
                row = {
                    "client": client,
                    "task": task,
                    "rep": rep,
                    "model": MODEL,
                    "run_id": run_id,
                    "ts": int(time.time()),
                    "bench_version": BENCH_VERSION,
                    "pass": verified and not tampered,
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
                with open(os.path.join(log_dir, f"{client}-{task}-{rep}.log"), "w") as f:
                    f.write(r["log"])
                if os.path.exists(transcript):
                    shutil.copy(
                        transcript,
                        os.path.join(log_dir, f"{client}-{task}-{rep}.json"),
                    )
                print(f"  -> pass={row['pass']} reqs={row['requests']} wall={r['wall_s']}s rss={r['maxrss_mb']}MB", flush=True)
                shutil.rmtree(repo, ignore_errors=True)
                n += 1
    print(f"done: {n} rows")


if __name__ == "__main__":
    main()
