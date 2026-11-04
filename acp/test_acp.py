#!/usr/bin/env python3
"""Self-test for the ACP shim: drives a scripted ACP client over NDJSON.

Spawns tests/stub_server.py (normal mode) plus the shim, then runs
initialize -> session/new -> session/prompt x2 and asserts the update
stream. Usage: python3 acp/test_acp.py [port]
"""
import json
import os
import subprocess
import sys
import tempfile
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18924
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

env = dict(os.environ)
env["IDEFIX_BASE_URL"] = "http://127.0.0.1:%d/v1" % PORT
env["IDEFIX_MODEL"] = "test-model"
env["IDEFIX_BIN"] = os.path.join(ROOT, "idefix")
env["IDEFIX_STATE_DIR"] = tempfile.mkdtemp(prefix="idefix-acp-test-")

stub = subprocess.Popen(
    ["python3", os.path.join(ROOT, "tests", "stub_server.py"), str(PORT), "normal"],
    stderr=subprocess.DEVNULL)
time.sleep(0.6)

shim = subprocess.Popen(
    [sys.executable, os.path.join(ROOT, "acp", "idefix-acp.py")],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

fails = []


def rpc(obj):
    shim.stdin.write(json.dumps(obj) + "\n")
    shim.stdin.flush()


def read_until_id(req_id, updates):
    deadline = time.time() + 60
    while time.time() < deadline:
        line = shim.stdout.readline()
        if not line:
            break
        msg = json.loads(line)
        if msg.get("method") == "session/update":
            updates.append(msg["params"]["update"])
        if msg.get("id") == req_id:
            return msg
    return None


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + " " + name + ("" if ok else " " + str(detail)[:300]))
    if not ok:
        fails.append(name)


try:
    rpc({"jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": {"protocolVersion": 1, "clientCapabilities": {}}})
    r = read_until_id(0, [])
    check("initialize", r and r.get("result", {}).get("protocolVersion") == 1, r)

    rpc({"jsonrpc": "2.0", "id": 1, "method": "session/new",
         "params": {"cwd": tempfile.gettempdir(), "mcpServers": []}})
    r = read_until_id(1, [])
    sid = (r or {}).get("result", {}).get("sessionId")
    check("session/new", bool(sid), r)

    ups = []
    rpc({"jsonrpc": "2.0", "id": 2, "method": "session/prompt",
         "params": {"sessionId": sid,
                    "prompt": [{"type": "text", "text": "task"}]}})
    r = read_until_id(2, ups)
    check("prompt stopReason", r and r.get("result", {}).get("stopReason") == "end_turn", r)
    kinds = [u.get("sessionUpdate") for u in ups]
    tc = [u for u in ups if u.get("sessionUpdate") == "tool_call"]
    check("tool_call emitted", tc and tc[0].get("kind") == "execute"
          and tc[0].get("toolCallId") == "call_1", tc)
    tu = [u for u in ups if u.get("sessionUpdate") == "tool_call_update"]
    check("tool_call_update failed", tu and tu[0].get("status") == "failed"
          and tu[0].get("toolCallId") == "call_1", tu)
    txt = "".join(u.get("content", {}).get("text", "")
                  for u in ups if u.get("sessionUpdate") == "agent_message_chunk")
    check("final answer chunk", "Done." in txt, txt)

    ups2 = []
    rpc({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
         "params": {"sessionId": sid,
                    "prompt": [{"type": "text", "text": "again"}]}})
    r = read_until_id(3, ups2)
    check("second turn (--continue)", r and r.get("result", {}).get("stopReason") == "end_turn", r)

    rpc({"jsonrpc": "2.0", "id": 4, "method": "session/prompt",
         "params": {"sessionId": "sess_bogus",
                    "prompt": [{"type": "text", "text": "x"}]}})
    r = read_until_id(4, [])
    check("unknown session errors", r and "error" in r, r)
finally:
    shim.terminate()
    stub.terminate()

sys.exit(1 if fails else 0)
