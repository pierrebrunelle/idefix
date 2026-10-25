#!/usr/bin/env python3
"""Stub OpenAI-compatible endpoint for idefix tests. Not shipped.

Usage: stub_server.py PORT MODE
Modes: normal | badargs | malformed | batch | sleep | sednoop | sbx | length | medit | ediff
       | flaky | bigusage | ctxerr | ctxbig | loop | weirdname | binout
       | chunked | envdump | cfdiff | badmarkup | injname | redirnoop
       | flood | many | markup | think | finalans | stall | detach | writefinal
       | writefinal2 | resultloop | reasoning | thinkleak
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[2] if len(sys.argv) > 2 else "normal"
STATE = {"fired": False}


def _is_json(s):
    try:
        json.loads(s)
        return True
    except Exception:
        return False


def tool_call(call_id, command):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": "bash", "arguments": json.dumps({"command": command})},
    }


def msg_response(content=None, calls=None, finish="stop", usage=None, reasoning=None):
    m = {"role": "assistant", "content": content}
    if reasoning is not None:
        m["reasoning"] = reasoning
    if calls is not None:
        m["tool_calls"] = calls
    return {
        "id": "r",
        "choices": [{"finish_reason": finish, "message": m}],
        "usage": usage or {"prompt_tokens": 20, "completion_tokens": 8},
    }


def reply(handler, status, data):
    data = json.dumps(data).encode() if not isinstance(data, bytes) else data
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith("/models"):
            body = json.dumps(
                {"data": [{"id": os.environ.get("IDEFIX_MODEL", os.environ.get("MAX_MODEL", "test-model"))}]}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        msgs = body["messages"]
        n_tool = sum(1 for m in msgs if m.get("role") == "tool")
        sys.stderr.write("STUB sys: %s\n" % msgs[0].get("content", ""))
        sys.stderr.write("STUB user: %s\n" % msgs[-1].get("content", "")[:500])
        sys.stderr.write(
            "STUB users: %s\n"
            % [m.get("content") for m in msgs if m.get("role") == "user"]
        )
        sys.stderr.write("STUB temp: %s\n" % body.get("temperature"))
        sys.stderr.write("STUB body: %s\n" % json.dumps(body.get("messages", []))[:4000])
        if MODE == "flaky" and not STATE["fired"]:
            STATE["fired"] = True
            reply(self, 500, {"error": {"message": "boom"}})
            return
        if MODE == "ctxerr" and n_tool > 0 and not STATE["fired"]:
            STATE["fired"] = True
            reply(self, 400, {"error": {"message": "context length exceeded"}})
            return
        if MODE == "ctxbig" and n_tool > 0 and not STATE["fired"]:
            STATE["fired"] = True
            reply(self, 400, {"error": {"message": "Context Window Exceeded"}})
            return
        if MODE == "stall":
            # never answers inside a --max-seconds window; client must time out
            time.sleep(30)
            reply(self, 200, msg_response(content="too late"))
            return
        if MODE == "loop":
            reply(
                self,
                200,
                msg_response(
                    calls=[tool_call("call_l", "echo same-loop")],
                    finish="tool_calls",
                ),
            )
            return
        if MODE == "resultloop":
            # different command text each turn, identical outcome: the
            # consecutive-repeat guard can't see it, --loop-digest can
            cmd = "echo R" if n_tool % 2 == 0 else "printf 'R\\n'"
            reply(
                self,
                200,
                msg_response(calls=[tool_call("call_rl", cmd)], finish="tool_calls"),
            )
            return
        if MODE == "chunked" and n_tool == 0:
            # No Content-Length: --max-http-bytes must still cap the body.
            # Client aborts mid-stream -> EPIPE here.
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                head = b'{"id":"r","choices":[{"message":{"role":"assistant","content":"'
                self.wfile.write(b"%x\r\n" % len(head) + head + b"\r\n")
                chunk = b"x" * 8192
                for _ in range(8):
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if MODE == "badmarkup" and n_tool == 0 and not STATE["fired"]:
            # tool-call markup the server failed to structure: agent should
            # re-ask rather than finish. Fires once, then default flow.
            STATE["fired"] = True
            reply(
                self,
                200,
                msg_response(
                    content='Let me fix it.\n<tool_call>{"name":"bash",'
                    '"arguments":{"command":"echo never-ran"}'
                ),
            )
            return
        if MODE == "malformed" and n_tool == 0:
            data = b'{"id":"r","choices":[{invalid json'
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if MODE == "length" and n_tool == 0:
            resp = msg_response(content="partial ans", finish="length")
        elif n_tool == 0:
            if MODE == "badargs":
                resp = msg_response(
                    calls=[
                        {
                            "id": "call_bad",
                            "type": "function",
                            "function": {"name": "bash", "arguments": "{not json"},
                        }
                    ],
                    finish="tool_calls",
                )
            elif MODE == "batch":
                resp = msg_response(
                    calls=[
                        tool_call("call_a", "echo A"),
                        tool_call("call_b", "echo B; exit 4"),
                    ],
                    finish="tool_calls",
                )
            elif MODE == "sleep":
                resp = msg_response(
                    calls=[tool_call("call_s", "(sleep 37 &) ; exec sleep 37")],
                    finish="tool_calls",
                )
            elif MODE == "bigusage":
                resp = msg_response(
                    calls=[tool_call("call_1", "echo big")],
                    finish="tool_calls",
                    usage={"prompt_tokens": 60000, "completion_tokens": 8},
                )
            elif MODE == "binout":
                resp = msg_response(
                    calls=[tool_call("call_o", "printf '\\377\\376bin'")],
                    finish="tool_calls",
                )
            elif MODE == "envdump":
                resp = msg_response(
                    calls=[tool_call("call_e", "env")],
                    finish="tool_calls",
                )
            elif MODE == "sednoop":
                resp = msg_response(
                    calls=[tool_call("call_n", "sed -i '' 's/zzznope/yyy/' README.md")],
                    finish="tool_calls",
                )
            elif MODE == "sbx":
                resp = msg_response(
                    calls=[tool_call("call_x", "touch \"$HOME/.sbx-denied-xyz\" ; touch .sbx-ok")],
                    finish="tool_calls",
                )
            elif MODE == "cfdiff":
                resp = msg_response(
                    calls=[tool_call("call_c", "echo cf > cf-out.txt")],
                    finish="tool_calls",
                )
            elif MODE == "writefinal":
                # one write-shaped command, then plain text forever: the
                # done-gate should nudge once, the baseline should not
                resp = msg_response(
                    calls=[tool_call("call_w", "touch gate-wrote.txt")],
                    finish="tool_calls",
                )
            elif MODE == "writefinal2":
                # first write; the n_tool>0 branch issues a second write
                # after gate nudge #1, so a two-strike gate can fire twice
                resp = msg_response(
                    calls=[tool_call("call_w1", "touch gate2-wrote.txt")],
                    finish="tool_calls",
                )
            elif MODE == "injname":
                # single quotes make the filename literal; if the diff-echo
                # interpolates it unquoted, touch pwned.txt executes
                resp = msg_response(
                    calls=[tool_call("call_i", "touch './x$(touch pwned.txt)'")],
                    finish="tool_calls",
                )
            elif MODE == "redirnoop":
                # 2>&1 is fd duplication, not a file write: must not warn
                resp = msg_response(
                    calls=[tool_call("call_r", "echo hi 2>&1 | tail -1")],
                    finish="tool_calls",
                )
            elif MODE == "flood":
                resp = msg_response(
                    calls=[tool_call("call_f", "seq 1 30000")],
                    finish="tool_calls",
                )
            elif MODE == "many":
                resp = msg_response(
                    calls=[
                        tool_call("call_m%d" % i, "echo m%d" % i)
                        for i in range(10)
                    ],
                    finish="tool_calls",
                )
            elif MODE == "markup":
                # well-formed hermes markup in content, no tool_calls field:
                # the client should rescue it into a real call
                resp = msg_response(
                    content='<tool_call>{"name":"bash","arguments":'
                    '{"command":"echo markup-ok"}}</tool_call>'
                )
            elif MODE == "think":
                resp = msg_response(
                    content="<think>internal reasoning</think>Done."
                )
            elif MODE == "finalans":
                resp = msg_response(content="Done.")
            elif MODE == "reasoning":
                # thinking-mode server shape: answer lives in `reasoning`,
                # content empty -> the fallback must surface it
                resp = msg_response(
                    content="", reasoning="Reasoned answer.")
            elif MODE == "thinkleak":
                resp = msg_response(content="</think>Leaked answer.")
            elif MODE == "detach":
                resp = msg_response(
                    calls=[tool_call("call_d", "(sleep 29 &); exit 0")],
                    finish="tool_calls",
                )
            elif MODE == "medit":
                resp = msg_response(
                    calls=[tool_call(
                        "call_e",
                        "printf 'x = 1\n' > e.py\n"
                        "idefix edit e.py <<'EOF'\n"
                        "<<<<<<< SEARCH\nx = 1\n=======\nx = 9\n>>>>>>> REPLACE\n"
                        "EOF\ncat e.py",
                    )],
                    finish="tool_calls",
                )
            elif MODE == "ediff":
                resp = msg_response(
                    calls=[tool_call("call_d", "printf 'a\nb\nc\n' > d.txt")],
                    finish="tool_calls",
                )
            elif MODE == "weirdname":
                resp = msg_response(
                    calls=[
                        {
                            "id": "call_w",
                            "type": "function",
                            "function": {
                                "name": 'weird"name',
                                "arguments": "{}",
                            },
                        }
                    ],
                    finish="tool_calls",
                )
            else:
                resp = msg_response(
                    calls=[tool_call("call_1", "echo spike-ok && exit 3")],
                    finish="tool_calls",
                )
        else:
            asst = [m for m in msgs if m.get("tool_calls")][-1]
            ids = {c["id"] for c in asst["tool_calls"]}
            got = {m["tool_call_id"] for m in msgs if m.get("role") == "tool"}
            ok = ids <= got
            sys.stderr.write(
                "STUB pairing: %s expected=%s got=%s\n" % (ok, sorted(ids), sorted(got))
            )
            tool_contents = [
                m["content"] for m in msgs if m.get("role") == "tool"
            ]
            sys.stderr.write("STUB tool results: %s\n" % tool_contents)
            sys.stderr.write(
                "STUB tool json ok: %s\n" % all(_is_json(c) for c in tool_contents)
            )
            if MODE == "writefinal2" and n_tool == 1 and ok and sum(
                    1 for m in msgs if m.get("role") == "user") == 2:
                # gate nudge #1 landed and the model "complied" by writing
                # again instead of checking; strike 2 must echo evidence
                resp = msg_response(
                    calls=[tool_call("call_w2", "echo more >> gate2-wrote.txt")],
                    finish="tool_calls",
                )
            else:
                resp = msg_response(
                    content="Done." if ok else "PROTOCOL VIOLATION: unmatched tool results"
                )
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18923
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
