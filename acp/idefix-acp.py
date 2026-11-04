#!/usr/bin/env python3
"""ACP (Agent Client Protocol) shim for idefix.

Speaks newline-delimited JSON-RPC 2.0 on stdio. Each ACP session maps to a
per-session idefix state dir; each prompt turn is one `idefix --events`
invocation (with --continue after the first turn), so turn context survives
via journal replay and cancellation is just killing the process.

Env: IDEFIX_BIN (idefix path, default "idefix" on PATH); IDEFIX_BASE_URL,
IDEFIX_MODEL and the rest of the idefix env contract pass through.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import uuid

IDEFIX = os.environ.get("IDEFIX_BIN", "idefix")

write_lock = threading.Lock()
sessions = {}  # session_id -> {"repo": str, "state_dir": str, "proc": Popen|None}
pending_cancel = {}  # session_id -> prompt response id waiting on a killed proc


def send(obj):
    with write_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def respond(req_id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": req_id}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    send(msg)


def notify(session_id, update):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": session_id, "update": update}})


def chunk(session_id, text, thought=False):
    notify(session_id, {"sessionUpdate": "agent_thought_chunk" if thought else "agent_message_chunk",
                        "content": {"type": "text", "text": text}})


def translate(session_id, line):
    """One idefix --events NDJSON line -> zero or more session/update notifications."""
    try:
        ev = json.loads(line)
    except ValueError:
        return
    kind = ev.get("ev")
    if kind == "msg":
        m = ev.get("m", {})
        role = m.get("role")
        if role == "assistant":
            if m.get("content"):
                chunk(session_id, m["content"])
            for tc in m.get("tool_calls") or []:
                fn = tc.get("function", {})
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except ValueError:
                    args = {}
                cmd = args.get("command", "")
                notify(session_id, {
                    "sessionUpdate": "tool_call",
                    "toolCallId": tc.get("id", str(uuid.uuid4())),
                    "title": cmd.split("\n", 1)[0][:120] or "bash",
                    "kind": "execute",
                    "status": "in_progress",
                    "rawInput": args,
                })
        elif role == "tool":
            try:
                inner = json.loads(m.get("content") or "{}")
            except ValueError:
                inner = {}
            out = inner.get("output", m.get("content", ""))
            ec = inner.get("exit_code")
            parts = []
            if out:
                parts.append({"type": "content", "content": {"type": "text", "text": out}})
            extra = []
            if inner.get("changed_files"):
                extra.append("changed_files: " + inner["changed_files"])
            if inner.get("discarded_bytes"):
                extra.append("discarded_bytes: " + str(inner["discarded_bytes"]))
            if inner.get("spilled_to"):
                extra.append("spilled_to: " + inner["spilled_to"])
            if extra:
                parts.append({"type": "content", "content": {"type": "text", "text": "\n".join(extra)}})
            notify(session_id, {
                "sessionUpdate": "tool_call_update",
                "toolCallId": m.get("tool_call_id", ""),
                "status": "completed" if ec == 0 else "failed",
                "content": parts,
                "rawOutput": inner or None,
            })
    elif kind == "compact":
        chunk(session_id, "[context compacted: %s bytes cleared]" % ev.get("cleared", "?"))
    elif kind == "no_final":
        chunk(session_id, "(no final answer)")


def prompt_text(blocks):
    out = []
    for b in blocks or []:
        if b.get("type") == "text":
            out.append(b.get("text", ""))
        elif b.get("type") == "resource":
            r = b.get("resource", {})
            if r.get("text"):
                out.append(r["text"])
    return "\n".join(t for t in out if t)


def run_prompt(req_id, session_id, text):
    sess = sessions.get(session_id)
    if sess is None:
        respond(req_id, error={"code": -32602, "message": "unknown sessionId"})
        return
    state_dir = sess["state_dir"]
    args = [IDEFIX, "--events", "--repo", sess["repo"],
            "--state-dir", state_dir]
    if os.path.exists(os.path.join(state_dir, "journal.jsonl")):
        args.append("--continue")
    args += ["--", text]
    try:
        proc = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, start_new_session=True)
    except OSError as e:
        respond(req_id, error={"code": -32603, "message": "idefix spawn failed: %s" % e})
        return
    sess["proc"] = proc
    stop = "end_turn"
    for line in proc.stdout:
        line = line.strip()
        if line:
            translate(session_id, line)
    rc = proc.wait()
    sess["proc"] = None
    if pending_cancel.pop(session_id, None) is not None:
        stop = "cancelled"
    elif rc == 2:
        stop = "max_turn_requests"
    elif rc != 0:
        stop = "end_turn"
        chunk(session_id, "[idefix exited %d]" % rc)
    respond(req_id, {"stopReason": stop})


def handle(msg):
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        respond(req_id, {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": False,
                "promptCapabilities": {"image": False, "audio": False, "embeddedContext": False},
            },
            "authMethods": [],
            "agentInfo": {"name": "idefix", "title": "idefix", "version": "1"},
        })
    elif method == "session/new":
        repo = params.get("cwd") or os.getcwd()
        sid = "sess_" + uuid.uuid4().hex[:16]
        sessions[sid] = {"repo": repo,
                         "state_dir": tempfile.mkdtemp(prefix="idefix-acp-"),
                         "proc": None}
        respond(req_id, {"sessionId": sid})
    elif method == "session/prompt":
        sid = params.get("sessionId")
        threading.Thread(target=run_prompt,
                         args=(req_id, sid, prompt_text(params.get("prompt"))),
                         daemon=True).start()
    elif method == "session/cancel":
        sess = sessions.get(params.get("sessionId"))
        if sess and sess.get("proc"):
            pending_cancel[params["sessionId"]] = True
            try:
                os.killpg(sess["proc"].pid, signal.SIGTERM)
            except OSError:
                pass
    elif method in ("session/load", "session/set_mode", "session/set_model",
                    "authenticate", "logout"):
        if req_id is not None:
            respond(req_id, error={"code": -32601, "message": method + " not supported"})
    else:
        if req_id is not None:
            respond(req_id, error={"code": -32601, "message": "method not found: %s" % method})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            handle(json.loads(line))
        except Exception as e:
            sys.stderr.write("idefix-acp: %s\n" % e)


if __name__ == "__main__":
    main()
