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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _upstream(self, body):
        req = urllib.request.Request(
            UPSTREAM + self.path, data=body, method=self.command,
            headers={"Content-Type": "application/json"})
        return urllib.request.urlopen(req, timeout=600)

    def _sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def _emit(self, payload):
        self.wfile.write(payload)
        self.wfile.flush()

    def _stream_passthrough(self, resp):
        """REWRITE=0: relay upstream SSE bytes verbatim (keeps client header
        timeouts alive on slow generations)."""
        self._sse_start()
        for line in resp:
            self._emit(line)
        self._emit(b"data: [DONE]\n\n")

    def _stream_rewrite(self, resp):
        """REWRITE=1: forward content deltas live; when <tool_call> text
        starts, hold it back and emit structured tool_calls at the end."""
        self._sse_start()
        content = b""
        emitted = 0
        sentinel = b"<tool_call"
        tail = len(sentinel)
        saw_tool = False
        final_choice = None
        for line in resp:
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                continue
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {})
                piece = delta.get("content") or ""
                if piece:
                    content += piece.encode() if isinstance(piece, str) else piece
                if choice.get("finish_reason"):
                    final_choice = choice
                # flush the safe prefix of accumulated content
                idx = content.find(sentinel)
                if idx >= 0:
                    saw_tool = True
                    safe = idx
                else:
                    safe = max(emitted, len(content) - tail)
                if not saw_tool and safe > emitted:
                    out = dict(chunk)
                    out["choices"] = [{"index": choice.get("index", 0),
                                       "delta": {"content": content[emitted:safe].decode("utf8", "replace")},
                                       "finish_reason": None}]
                    self._emit(f"data: {json.dumps(out)}\n\n".encode())
                    emitted = safe
        # end of upstream: emit tool_calls or leftover content, then finish
        if saw_tool:
            parsed = []
            for i, raw in enumerate(TOOL_CALL_RE.findall(content.decode("utf8", "replace"))):
                try:
                    call = json.loads(raw)
                except ValueError:
                    continue
                parsed.append({"id": f"call_{i}", "type": "function",
                               "function": {"name": call.get("name"),
                                            "arguments": json.dumps(call.get("arguments", {}))}})
            if parsed:
                self._emit(f"data: {json.dumps({'choices': [{'index': 0, 'delta': {'tool_calls': parsed}, 'finish_reason': None}]})}\n\n".encode())
            finish = "tool_calls" if parsed else (final_choice or {}).get("finish_reason") or "stop"
        else:
            if len(content) > emitted:
                self._emit(f"data: {json.dumps({'choices': [{'index': 0, 'delta': {'content': content[emitted:].decode('utf8', 'replace')}, 'finish_reason': None}]})}\n\n".encode())
            finish = (final_choice or {}).get("finish_reason") or "stop"
        self._emit(f"data: {json.dumps({'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]})}\n\n".encode())
        self._emit(b"data: [DONE]\n\n")

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
                if TEMPLATE_KWARGS:
                    req_json.setdefault("chat_template_kwargs", {}).update(TEMPLATE_KWARGS)
                body = json.dumps(req_json).encode()
            except ValueError:
                pass
        try:
            resp = self._upstream(body)
            status = resp.status
        except urllib.error.HTTPError as e:
            upstream_body, status = e.read(), e.code
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(upstream_body)))
            self.end_headers()
            self.wfile.write(upstream_body)
            return
        is_chat = self.path.rstrip("/").endswith("chat/completions")
        if wants_stream and status == 200 and is_chat:
            (self._stream_rewrite if REWRITE else self._stream_passthrough)(resp)
            return
        upstream_body = resp.read()
        headers = resp.headers.get("Content-Type", "application/json")
        if is_chat and status == 200 and REWRITE:
            upstream_body = rewrite_response(upstream_body)
        self.send_response(status)
        self.send_header("Content-Type", headers)
        self.send_header("Content-Length", str(len(upstream_body)))
        self.end_headers()
        self.wfile.write(upstream_body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
