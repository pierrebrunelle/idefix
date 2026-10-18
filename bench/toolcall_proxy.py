"""OpenAI-compatible proxy that converts Hermes <tool_call> text into
structured tool_calls. The MAX serve build used for this benchmark ships
only "echo" and "llama" tool parsers, neither of which understands Qwen's
<tool_call>{"name": ..., "arguments": {...}}</tool_call> output. Harnesses
with native function calling (pi, dsh) point at this proxy on :8001; the
proxy forwards to the MAX server on :8000 and rewrites responses, the same
post-processing vLLM's hermes parser performs server-side.
"""

import json
import os
import re
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("PROXY_UPSTREAM", "http://127.0.0.1:8000")
LISTEN_PORT = int(os.environ.get("PROXY_PORT", "8001"))
# When set, every chat/completions request gets chat_template_kwargs merged in
# (e.g. PROXY_TEMPLATE_KWARGS='{"enable_thinking": false}') so hybrid-thinking
# models run non-thinking without touching per-harness request builders.
TEMPLATE_KWARGS = json.loads(os.environ.get("PROXY_TEMPLATE_KWARGS", "{}"))
# PROXY_REWRITE=0 disables <tool_call> rewriting: mojo and the python ref
# client parse Hermes tool-call text natively, so they only need kwargs
# injection (thinking off), not the structured-tool_calls transform.
REWRITE = os.environ.get("PROXY_REWRITE", "1") != "0"

TOOL_CALL_RE = re.compile(r"<tool_call>\s*(.*?)\s*</tool_call>", re.S)


def rewrite_response(body):
    try:
        resp = json.loads(body)
    except ValueError:
        return body
    for choice in resp.get("choices", []):
        msg = choice.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content") or ""
        calls = TOOL_CALL_RE.findall(content)
        if not calls:
            continue
        parsed = []
        for i, raw in enumerate(calls):
            try:
                call = json.loads(raw)
            except ValueError:
                continue
            parsed.append({
                "id": f"call_{i}",
                "type": "function",
                "function": {
                    "name": call.get("name"),
                    "arguments": json.dumps(call.get("arguments", {})),
                },
            })
        if not parsed:
            continue
        msg["tool_calls"] = parsed
        remainder = TOOL_CALL_RE.sub("", content).strip()
        msg["content"] = remainder or None
        choice["finish_reason"] = "tool_calls"
    return json.dumps(resp).encode()


def to_sse(resp_json):
    resp = json.loads(resp_json)
    out = []
    for i, choice in enumerate(resp.get("choices", [])):
        msg = choice.get("message", {})
        delta = {"role": "assistant"}
        if msg.get("content"):
            delta["content"] = msg["content"]
        if msg.get("tool_calls"):
            delta["tool_calls"] = msg["tool_calls"]
        chunk = {"id": resp.get("id"), "object": "chat.completion.chunk",
                 "created": resp.get("created"), "model": resp.get("model"),
                 "choices": [{"index": i, "delta": delta, "finish_reason": None}]}
        out.append(f"data: {json.dumps(chunk)}\n\n")
        end = {"id": resp.get("id"), "object": "chat.completion.chunk",
               "created": resp.get("created"), "model": resp.get("model"),
               "choices": [{"index": i, "delta": {},
                            "finish_reason": choice.get("finish_reason", "stop")}],
               "usage": resp.get("usage")}
        out.append(f"data: {json.dumps(end)}\n\n")
    out.append("data: [DONE]\n\n")
    return "".join(out).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _upstream(self, body):
        req = urllib.request.Request(
            UPSTREAM + self.path, data=body, method=self.command,
            headers={"Content-Type": "application/json"})
        return urllib.request.urlopen(req, timeout=600)

    def do_GET(self):
        self._proxy(None)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self._proxy(self.rfile.read(n) if n else None)

    def _proxy(self, body):
        wants_stream = False
        if body and self.path.rstrip("/").endswith("chat/completions"):
            try:
                req_json = json.loads(body)
                wants_stream = bool(req_json.get("stream"))
                if wants_stream:
                    req_json["stream"] = False
                if TEMPLATE_KWARGS:
                    req_json.setdefault("chat_template_kwargs", {}).update(TEMPLATE_KWARGS)
                body = json.dumps(req_json).encode()
            except ValueError:
                pass
        try:
            resp = self._upstream(body)
            upstream_body = resp.read()
            status, headers = resp.status, resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            upstream_body, status, headers = e.read(), e.code, "application/json"
        if body and self.path.rstrip("/").endswith("chat/completions") and status == 200 and REWRITE:
            upstream_body = rewrite_response(upstream_body)
        if wants_stream and status == 200:
            payload = to_sse(upstream_body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(status)
        self.send_header("Content-Type", headers)
        self.send_header("Content-Length", str(len(upstream_body)))
        self.end_headers()
        self.wfile.write(upstream_body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
