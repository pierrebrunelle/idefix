#!/usr/bin/env python3
"""Python reference client for mojo-max-agent. Same task loop and wire
protocol, stdlib only. Used as the comparison baseline in benchmarks."""
import json
import os
import re
import subprocess
import sys
import urllib.request

SYSTEM_PROMPT = """You are a coding agent working inside a repository on the user's machine. You have one tool: bash(command), which runs /bin/bash -c in the repository directory and returns the exit code and bounded output.

Rules:
- Act through the tool. Do not describe commands; issue them.
- Inspect before editing: read files, then change them. Write files with here-docs or scripts; verify changes with diffs or tests.
- Fix the root cause; do not skip tests or add workarounds.
- When the task is verifiably done, reply with a short summary of what changed and how it was verified. Do not call the tool again."""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "bash",
            "description": "Run a bash command in the repository directory. Returns exit code and bounded merged stdout/stderr output.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The bash command to run"}
                },
                "required": ["command"],
                "additionalProperties": False,
            },
        },
    }
]

TOOL_CALL_RE = re.compile(r"<tool_call>(.*?)</tool_call>", re.S)


def post(base, body):
    req = urllib.request.Request(
        base + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def markup_calls(content):
    """Synthesize OpenAI tool_calls from hermes <tool_call> markup."""
    calls = []
    for i, m in enumerate(TOOL_CALL_RE.finditer(content or "")):
        inner = m.group(1).strip()
        name, argstr = "", ""
        try:
            d = json.loads(inner)
            name = d.get("name", "")
            args = d.get("arguments", "")
            argstr = args if isinstance(args, str) else json.dumps(args)
        except json.JSONDecodeError:
            nl = inner.find("\n")
            if nl < 0:
                continue
            name = inner[:nl].strip()
            rest = inner[nl + 1 :].strip()
            try:
                v = json.loads(rest)
                argstr = v if isinstance(v, str) else json.dumps(v)
            except json.JSONDecodeError:
                argstr = rest.strip('"')
        if not name:
            continue
        if not argstr.startswith("{"):
            argstr = json.dumps({"command": argstr})
        calls.append(
            {
                "id": f"call_mk{i}",
                "type": "function",
                "function": {"name": name, "arguments": argstr},
            }
        )
    return calls


def main():
    repo = sys.argv[sys.argv.index("--repo") + 1]
    task = sys.argv[-1]
    base = os.environ.get("MAX_BASE_URL", "http://127.0.0.1:8000/v1")
    model = os.environ["MAX_MODEL"]
    msgs = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": task},
    ]
    requests = commands = 0
    prompt_tokens = 0
    try:
        for _ in range(15):
            body = {"model": model, "stream": False, "temperature": 0.6, "tools": TOOLS, "messages": msgs}
            resp = post(base, body)
            requests += 1
            prompt_tokens = resp.get("usage", {}).get("prompt_tokens", prompt_tokens)
            msg = resp["choices"][0]["message"]
            content = msg.get("content") or ""
            calls = msg.get("tool_calls") or markup_calls(content)
            if not calls:
                print(content)
                return
            msgs.append({"role": "assistant", "content": content or None, "tool_calls": calls})
            for call in calls:
                args = json.loads(call["function"]["arguments"])
                cmd = args.get("command", "")
                print(f"[ref] bash: {cmd[:120]}", file=sys.stderr)
                commands += 1
                try:
                    p = subprocess.run(
                        ["/bin/bash", "-c", cmd],
                        capture_output=True,
                        cwd=repo,
                        timeout=120,
                        stdin=subprocess.DEVNULL,
                    )
                    out = (p.stdout + p.stderr).decode("utf8", "replace")[:65536]
                    rc = p.returncode
                except subprocess.TimeoutExpired:
                    out, rc = "", 124
                msgs.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": json.dumps({"exit_code": rc, "output": out, "discarded_bytes": 0}),
                    }
                )
        sys.exit(2)
    finally:
        print(f"[ref] requests={requests} commands={commands} prompt_tokens={prompt_tokens}", file=sys.stderr)


if __name__ == "__main__":
    main()
