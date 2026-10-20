#!/usr/bin/env python3
"""Stub OpenAI-compatible endpoint for agent tests. Not shipped.

Usage: stub_server.py PORT MODE
Modes: normal | badargs | malformed | batch | sleep | length
       | flaky | bigusage | ctxerr | loop
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[2] if len(sys.argv) > 2 else "normal"
STATE = {"fired": False}


def tool_call(call_id, command):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": "bash", "arguments": json.dumps({"command": command})},
    }


def msg_response(content=None, calls=None, finish="stop", usage=None):
    m = {"role": "assistant", "content": content}
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
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        msgs = body["messages"]
        n_tool = sum(1 for m in msgs if m.get("role") == "tool")
        sys.stderr.write("STUB sys: %s\n" % msgs[0].get("content", ""))
        sys.stderr.write("STUB user: %s\n" % msgs[-1].get("content", "")[:500])
        sys.stderr.write("STUB temp: %s\n" % body.get("temperature"))
        if MODE == "flaky" and not STATE["fired"]:
            STATE["fired"] = True
            reply(self, 500, {"error": {"message": "boom"}})
            return
        if MODE == "ctxerr" and n_tool > 0 and not STATE["fired"]:
            STATE["fired"] = True
            reply(self, 400, {"error": {"message": "context length exceeded"}})
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
                    calls=[tool_call("call_s", "(sleep 30 &) ; exec sleep 30")],
                    finish="tool_calls",
                )
            elif MODE == "bigusage":
                resp = msg_response(
                    calls=[tool_call("call_1", "echo big")],
                    finish="tool_calls",
                    usage={"prompt_tokens": 60000, "completion_tokens": 8},
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
