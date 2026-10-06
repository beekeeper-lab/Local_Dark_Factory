#!/usr/bin/env python3
"""fake-ollama.py — a model server that answers the way ollama does, for tests.

The inference recorder sits on the line's only route to the GPU, and while it is
being tested a real bean may be using that GPU. So nothing in its tests talks to
:11434: this imitates the parts of ollama the recorder reads, on a port of its
own, with numbers chosen so the arithmetic is checkable by eye.

    fake-ollama.py --port-file <file> [--seen <jsonl>] [--tags <model,...>]

Shapes served:
  POST /api/chat, /api/generate   native: one JSON object (stream:false), or
                                   NDJSON chunks ending in done:true (stream
                                   absent or true), metrics in nanoseconds
  POST /v1/chat/completions        OpenAI: one JSON object with `usage`, or SSE
                                   `data:` chunks and `[DONE]`; the usage chunk
                                   only when stream_options.include_usage is set,
                                   which is what the real server does
  GET  /api/ps, /api/version,      small JSON, for the not-recorded path
       /api/tags

The request's `model` picks a behaviour:
  slow      first chunk, then a 2 s pause, then the rest (incremental relay)
  abort     headers and one chunk, then the connection is dropped mid-response
  garbage   a 200 whose streamed body is not JSON
  anything else: a normal answer

Date and Server headers are fixed, so a response read directly and one read
through the recorder can be compared byte for byte.

--seen appends every request body received, so a test can see what arrived.
--tags names the models /api/tags lists (`ollama list` against this server),
with a digest derived from the name, so a suite that checks a model is pulled
can run without asking the real server.
"""
import argparse
import hashlib
import http.server
import json
import os
import socketserver
import time

METRICS = {"total_duration": 4_000_000_000, "load_duration": 1_500_000_000,
           "prompt_eval_count": 1000, "prompt_eval_duration": 2_000_000_000,
           "eval_count": 50, "eval_duration": 500_000_000}
SEEN = None
TAGS: list[str] = []


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def version_string(self):
        return "fake-ollama"

    def date_time_string(self, timestamp=None):
        return "Tue, 06 Oct 2026 00:00:00 GMT"

    def log_message(self, *a):
        pass

    def _json(self, obj, status=200):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def _chunk(self, b: bytes):
        self.wfile.write(b"%x\r\n" % len(b) + b + b"\r\n")
        self.wfile.flush()

    def do_HEAD(self):
        # The ollama CLI's heartbeat, before every command.
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/":
            out = b"Ollama is running"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        elif self.path == "/api/ps":
            self._json({"models": [{"name": "fake:1b"}]})
        elif self.path == "/api/version":
            self._json({"version": "0.0.0-fake"})
        elif self.path == "/api/tags":
            self._json({"models": [
                {"name": t, "model": t, "modified_at": "2026-10-06T00:00:00Z", "size": 1,
                 "digest": hashlib.sha256(t.encode()).hexdigest(), "details": {}} for t in TAGS]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        if SEEN:
            with open(SEEN, "a") as fh:
                fh.write(json.dumps({"path": self.path, "body": body.decode()}) + "\n")
        try:
            req = json.loads(body)
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        model = req.get("model", "")
        if self.path in ("/api/chat", "/api/generate"):
            return self.native(req, model)
        if self.path in ("/v1/chat/completions", "/v1/completions"):
            return self.openai(req, model)
        self._json({"error": "not found"}, 404)

    def native(self, req, model):
        chat = self.path == "/api/chat"

        def piece(text, done=False):
            o = {"model": model, "created_at": "2026-10-06T00:00:00Z", "done": done}
            if chat:
                o["message"] = {"role": "assistant", "content": text}
            else:
                o["response"] = text
            if done:
                o.update(done_reason="stop", **METRICS)
            return o

        if req.get("stream") is False:
            o = piece("hello world", done=True)
            return self._json(o)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if model == "garbage":
            self._chunk(b"this is not json\n")
            self._chunk(b"{nor is this\n")
            self._chunk(b"")
            return
        # A first chunk with no token in it, as ollama sends while thinking
        # starts: TTFT is the first chunk that CARRIES something.
        first = piece("")
        self._chunk((json.dumps(first) + "\n").encode())
        if model == "slow":
            time.sleep(0.3)
        self._chunk((json.dumps(piece("hello")) + "\n").encode())
        if model == "abort":
            self.wfile.flush()
            self.connection.shutdown(2)
            self.close_connection = True
            return
        if model == "slow":
            time.sleep(2)
        self._chunk((json.dumps(piece(" world")) + "\n").encode())
        self._chunk((json.dumps(piece("", done=True)) + "\n").encode())
        self._chunk(b"")

    def openai(self, req, model):
        usage = {"prompt_tokens": 321, "completion_tokens": 12, "total_tokens": 333}
        if not req.get("stream"):
            return self._json({"id": "x", "object": "chat.completion", "model": model,
                               "choices": [{"index": 0, "finish_reason": "stop",
                                            "message": {"role": "assistant", "content": "hi"}}],
                               "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def ev(o):
            self._chunk(b"data: " + json.dumps(o).encode() + b"\n\n")

        base = {"id": "x", "object": "chat.completion.chunk", "model": model}
        ev(dict(base, choices=[{"index": 0, "delta": {"role": "assistant", "content": ""}}]))
        ev(dict(base, choices=[{"index": 0, "delta": {"content": "hi"}}]))
        ev(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}]))
        if (req.get("stream_options") or {}).get("include_usage"):
            ev(dict(base, choices=[], usage=usage))
        self._chunk(b"data: [DONE]\n\n")
        self._chunk(b"")


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    global SEEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--seen")
    ap.add_argument("--tags", default="", help="comma-separated model names /api/tags lists")
    a = ap.parse_args()
    SEEN = a.seen
    TAGS[:] = [t for t in a.tags.split(",") if t]
    srv = S(("127.0.0.1", 0), H)
    with open(a.port_file + ".tmp", "w") as fh:
        fh.write(f"{srv.server_address[1]}\n")
    os.replace(a.port_file + ".tmp", a.port_file)
    srv.serve_forever()


if __name__ == "__main__":
    main()
