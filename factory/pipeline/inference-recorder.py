#!/usr/bin/env python3
"""inference-recorder.py — what every model call cost, measured on the wire.

Phase 4 task 13 (amendment, 2026-10-04). The line logs totals: a step took 40
minutes, an audit took 230 seconds. It cannot say WHERE those seconds went, and
every inference change on the parking lot — prompt order for prefix caching,
batch sizes, keeping the judge resident — is a claim about where they go. On
2026-10-04 eleven audits were fitted, by hand, to ~96 tok/s prefill and roughly
all of the judge's wall time spent in prefill. That fit is the best number this
project has about inference, and it was a regression over totals, not a
measurement.

ollama already measures it. Every final response carries prompt_eval_count,
prompt_eval_duration, eval_count, eval_duration and load_duration, in tokens and
nanoseconds. judge.sh reads two of those numbers and throws the rest away; the
developer's calls, which go through pi, are read by nobody. So this sits between
the line and the server, forwards every byte, and writes those numbers down —
one JSON line per model call, tagged with the bean, role and step it served.

    inference-recorder.py serve --listen 127.0.0.1:<port> --upstream 127.0.0.1:11434 \\
        --log <calls.jsonl> [--requests-dir <dir>] [--tags-file <json>] \\
        [--port-file <file>] [--parent-pid <pid>]

The rule this program is built around: it must never change what the line
receives. A measurement that alters the thing measured is not one, and a proxy
that buffers a streamed response turns a model that is thinking into a model
that is silent — pi's idle timeout has already killed four spec turns that way
(run-step.sh, 2026-09-22). So:

  * bytes are relayed as they arrive, one recv at a time, before anything looks
    at them; parsing happens on a copy, afterwards;
  * the response is relayed byte-for-byte: status line, headers, chunk framing,
    all of it. Nothing is re-encoded, because nothing is decoded on the relay
    path — a small incremental parser only follows the framing to know where a
    response ends, so a kept-alive client connection can carry the next request;
  * every recording step is inside a try. A metrics bug costs a record, never a
    response: the failure goes to stderr and the bytes keep flowing.

Two deliberate departures from "a wire", both invisible to a client:

  * one upstream connection per request. The client's connection is kept alive
    (pi's HTTP client reuses it), but upstream is localhost and a fresh connect
    costs microseconds, where a stale pooled one costs a failed POST that
    nothing retries;
  * `Expect: 100-continue` is answered here and not forwarded. curl sends it for
    large bodies and then waits for permission before sending the body; this
    program wants the whole body before it connects upstream. The client sees
    the same `100 Continue` the server would have sent.

Which calls are recorded: POST to /api/chat, /api/generate, /v1/chat/completions
and /v1/completions. Everything else (/api/ps, /api/tags, /api/show, ...) is
forwarded the same way and not written down — it is not inference.

Tags. Every record carries `tags`, merged in this order, later wins:
  1. FACTORY_BEAN / FACTORY_ROLE / FACTORY_STEP in this process's environment at
     start (bean, role, step);
  2. --tags-file, re-read on every call: a small JSON object the controller
     rewrites before each step. A pi worker reaches the server through a byte
     forwarder and cannot add a header, so the controller says what it is
     running instead of the caller;
  3. any `X-Factory-<Name>` request header, as tag `<name>` (lower case, `-`
     to `_`): X-Factory-Bean, X-Factory-Role, X-Factory-Step, and anything else
     a caller wants to carry, such as the replay's X-Factory-Label.

Stdlib only, like every pipeline tool.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import socketserver
import sys
import threading
import time
from datetime import datetime, timezone

MODEL_PATHS = ("/api/chat", "/api/generate", "/v1/chat/completions", "/v1/completions")
MAX_HEAD = 256 * 1024
# The response body is kept for parsing only when it is not streamed (a single
# JSON object at the end). A judge answer is tens of kilobytes; this bound is
# there so a pathological body costs a record, not the box's memory.
MAX_KEEP = 64 * 1024 * 1024


def log(msg: str) -> None:
    print(f"inference-recorder: {msg}", file=sys.stderr, flush=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# --------------------------------------------------------------- request side
class Reader:
    """Buffered reads from the client socket. The request side is read whole
    before it is forwarded, so blocking reads are fine here."""

    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.buf = b""

    def _fill(self) -> None:
        d = self.sock.recv(65536)
        if not d:
            raise EOFError
        self.buf += d

    def until(self, sep: bytes, limit: int) -> bytes:
        while sep not in self.buf:
            if len(self.buf) > limit:
                raise ValueError("header section too large")
            self._fill()
        i = self.buf.index(sep) + len(sep)
        out, self.buf = self.buf[:i], self.buf[i:]
        return out

    def exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out


def parse_headers(head: bytes) -> tuple[str, list[tuple[str, str]]]:
    lines = head.decode("latin-1").split("\r\n")
    hdrs = []
    for ln in lines[1:]:
        if not ln:
            continue
        k, _, v = ln.partition(":")
        hdrs.append((k.strip(), v.strip()))
    return lines[0], hdrs


def hget(hdrs, name: str) -> str | None:
    name = name.lower()
    for k, v in hdrs:
        if k.lower() == name:
            return v
    return None


def read_request(r: Reader):
    """-> (head_bytes, method, target, version, headers). The body is read
    separately, after any `Expect: 100-continue` has been answered."""
    head = r.until(b"\r\n\r\n", MAX_HEAD)
    start, hdrs = parse_headers(head)
    parts = start.split(" ")
    if len(parts) != 3:
        raise ValueError(f"not an HTTP request line: {start[:80]!r}")
    method, target, version = parts
    return head, method, target, version, hdrs


def read_request_body(r: Reader, hdrs) -> tuple[bytes, bytes]:
    te = (hget(hdrs, "Transfer-Encoding") or "").lower()
    if "chunked" in te:
        raw, body = b"", b""
        while True:
            line = r.until(b"\r\n", MAX_HEAD)
            raw += line
            size = int(line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while True:  # trailers, then the empty line
                    t = r.until(b"\r\n", MAX_HEAD)
                    raw += t
                    if t == b"\r\n":
                        return raw, body
            data = r.exact(size + 2)
            raw += data
            body += data[:size]
    n = int(hget(hdrs, "Content-Length") or 0)
    data = r.exact(n) if n else b""
    return data, data


# -------------------------------------------------------------- response side
class Metrics:
    """Reads the response BODY (de-framed) as it goes by, on a copy.

    Streaming is recognised by the response's content type rather than the
    request's `stream` flag: ollama's native endpoints default to streaming when
    the flag is absent and the /v1 ones do not, and the content type is what
    actually arrived."""

    def __init__(self, t0: float):
        self.t0 = t0
        self.kind = None          # ndjson | sse | json
        self.pending = b""
        self.kept = b""
        self.ttft = None
        self.final = None          # native: the object with done=true
        self.usage = None          # /v1: the usage object, when sent
        self.done_reason = None
        self.broken = False

    def set_content_type(self, ct: str | None) -> None:
        ct = (ct or "").lower()
        if "ndjson" in ct:
            self.kind = "ndjson"
        elif "event-stream" in ct:
            self.kind = "sse"
        else:
            self.kind = "json"

    def feed(self, data: bytes) -> None:
        if self.broken or not data:
            return
        try:
            if self.kind == "json":
                if len(self.kept) < MAX_KEEP:
                    self.kept += data
                return
            self.pending += data
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                self._line(line.strip())
        except Exception as e:  # noqa: BLE001 — a record lost, never a response
            self.broken = True
            log(f"metrics stopped for this call: {e!r}")

    def finish(self) -> None:
        try:
            if self.kind == "json":
                self._object(json.loads(self.kept or b"null"), streamed=False)
            elif self.pending.strip():
                self._line(self.pending.strip())
        except (ValueError, TypeError):
            pass  # a malformed body is recorded as having no metrics
        except Exception as e:  # noqa: BLE001
            log(f"metrics could not finish: {e!r}")

    def _line(self, line: bytes) -> None:
        if not line:
            return
        if self.kind == "sse":
            if not line.startswith(b"data:"):
                return
            line = line[5:].strip()
            if line == b"[DONE]":
                return
        try:
            obj = json.loads(line)
        except ValueError:
            return
        self._object(obj, streamed=True)

    def _object(self, obj, streamed: bool) -> None:
        if not isinstance(obj, dict):
            return
        if streamed and self.ttft is None and has_token(obj):
            self.ttft = time.monotonic() - self.t0
        if obj.get("done") is True or ("prompt_eval_count" in obj or "eval_count" in obj):
            self.final = obj
        if isinstance(obj.get("usage"), dict):
            self.usage = obj["usage"]
        dr = obj.get("done_reason")
        if dr is None and isinstance(obj.get("choices"), list) and obj["choices"]:
            c0 = obj["choices"][0]
            dr = c0.get("finish_reason") if isinstance(c0, dict) else None
        if dr:
            self.done_reason = dr


def has_token(obj: dict) -> bool:
    """A chunk that carries something the model generated: answer, reasoning or
    a tool call. Reasoning counts — it is decode time on the GPU, and a TTFT that
    ignored it would report a thinking model as slow to prefill."""
    msg = obj.get("message")
    if isinstance(msg, dict) and (msg.get("content") or msg.get("thinking") or msg.get("tool_calls")):
        return True
    if obj.get("response") or obj.get("thinking"):
        return True
    for c in obj.get("choices") or []:
        if not isinstance(c, dict):
            continue
        if c.get("text"):
            return True
        d = c.get("delta") or {}
        if isinstance(d, dict) and (d.get("content") or d.get("reasoning")
                                    or d.get("reasoning_content") or d.get("tool_calls")):
            return True
    return False


class Framing:
    """Follows HTTP/1.1 response framing incrementally, to know when a response
    has ended and to hand the de-framed body to Metrics. It never produces the
    bytes the client gets — those are relayed before this sees them."""

    def __init__(self, method: str, on_head, on_body):
        self.method = method
        self.on_head, self.on_body = on_head, on_body
        self.state = "head"
        self.pending = b""
        self.remaining = 0
        self.done = False
        self.status = None
        self.headers = []
        self.until_close = False

    def feed(self, data: bytes) -> None:
        self.pending += data
        while not self.done:
            if self.state == "head":
                i = self.pending.find(b"\r\n\r\n")
                if i < 0:
                    if len(self.pending) > MAX_HEAD:
                        raise ValueError("response header section too large")
                    return
                head, self.pending = self.pending[:i + 4], self.pending[i + 4:]
                start, hdrs = parse_headers(head)
                try:
                    status = int(start.split(" ")[1])
                except (IndexError, ValueError):
                    raise ValueError(f"not an HTTP status line: {start[:80]!r}")
                if 100 <= status < 200:
                    continue  # an interim response; the real one follows
                self.status, self.headers = status, hdrs
                self.on_head(status, hdrs)
                te = (hget(hdrs, "Transfer-Encoding") or "").lower()
                cl = hget(hdrs, "Content-Length")
                if self.method == "HEAD" or status in (204, 304):
                    self.done = True
                elif "chunked" in te:
                    self.state = "size"
                elif cl is not None:
                    self.remaining = int(cl)
                    self.state = "length"
                    if self.remaining == 0:
                        self.done = True
                else:
                    self.state = "close"
                    self.until_close = True
            elif self.state == "length":
                take = self.pending[:self.remaining]
                self.pending = self.pending[len(take):]
                self.remaining -= len(take)
                self.on_body(take)
                if self.remaining == 0:
                    self.done = True
                else:
                    return
            elif self.state == "size":
                i = self.pending.find(b"\r\n")
                if i < 0:
                    return
                line, self.pending = self.pending[:i], self.pending[i + 2:]
                size = int(line.split(b";")[0].strip(), 16)
                if size == 0:
                    self.state = "trailer"
                else:
                    self.remaining, self.state = size, "data"
            elif self.state == "data":
                take = self.pending[:self.remaining]
                self.pending = self.pending[len(take):]
                self.remaining -= len(take)
                self.on_body(take)
                if self.remaining:
                    return
                self.state = "crlf"
            elif self.state == "crlf":
                if len(self.pending) < 2:
                    return
                self.pending = self.pending[2:]
                self.state = "size"
            elif self.state == "trailer":
                i = self.pending.find(b"\r\n")
                if i < 0:
                    return
                line, self.pending = self.pending[:i], self.pending[i + 2:]
                if not line:
                    self.done = True
            elif self.state == "close":
                self.on_body(self.pending)
                self.pending = b""
                return


# ------------------------------------------------------------------ recording
def ns_to_s(v):
    return round(v / 1e9, 6) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def rate(count, seconds):
    if isinstance(count, (int, float)) and seconds:
        return round(count / seconds, 3)
    return None


def build_record(path: str, req: dict | None, req_bytes: int, tags: dict, status, wall: float,
                 m: Metrics, error: str | None) -> dict:
    req = req if isinstance(req, dict) else {}
    native = path.startswith("/api/")
    stream = req.get("stream")
    if not isinstance(stream, bool):
        stream = True if native else False  # ollama's own defaults per API
    rec = {
        "ts": None, "seq": None, "path": path, "model": req.get("model"), "tags": tags,
        "request_bytes": req_bytes, "stream": stream, "status": status,
        "wall_s": round(wall, 6),
        "ttft_s": round(m.ttft, 6) if (stream and m.ttft is not None) else None,
        "prompt_eval_count": None, "prompt_eval_duration_s": None,
        "eval_count": None, "eval_duration_s": None,
        "load_duration_s": None, "total_duration_s": None,
        "prefill_tok_s": None, "decode_tok_s": None,
        "done_reason": m.done_reason, "metrics_source": None,
    }
    f = m.final
    if isinstance(f, dict) and ("prompt_eval_count" in f or "eval_count" in f or "total_duration" in f):
        rec.update(
            prompt_eval_count=f.get("prompt_eval_count"),
            prompt_eval_duration_s=ns_to_s(f.get("prompt_eval_duration")),
            eval_count=f.get("eval_count"),
            eval_duration_s=ns_to_s(f.get("eval_duration")),
            load_duration_s=ns_to_s(f.get("load_duration")),
            total_duration_s=ns_to_s(f.get("total_duration")),
            metrics_source="native",
        )
        rec["prefill_tok_s"] = rate(rec["prompt_eval_count"], rec["prompt_eval_duration_s"])
        rec["decode_tok_s"] = rate(rec["eval_count"], rec["eval_duration_s"])
    elif isinstance(m.usage, dict):
        # The OpenAI shape has counts and no durations. Splitting wall time into
        # prefill and decode from TTFT would be an estimate dressed as a
        # measurement, so the durations stay null and say so.
        rec.update(prompt_eval_count=m.usage.get("prompt_tokens"),
                   eval_count=m.usage.get("completion_tokens"), metrics_source="usage")
    if error:
        rec["error"] = error
    return rec


class Recorder:
    def __init__(self, log_path: str, requests_dir: str | None, tags_file: str | None):
        self.log_path = log_path
        self.requests_dir = requests_dir
        self.tags_file = tags_file
        self.lock = threading.Lock()
        self.base_tags = {k: os.environ[e] for k, e in
                          (("bean", "FACTORY_BEAN"), ("role", "FACTORY_ROLE"), ("step", "FACTORY_STEP"))
                          if os.environ.get(e)}
        os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
        self.seq = 0
        if requests_dir:
            os.makedirs(requests_dir, exist_ok=True)
            # A resumed run appends; numbering carries on rather than overwriting.
            for n in os.listdir(requests_dir):
                mo = re.match(r"(\d+)-", n)
                if mo:
                    self.seq = max(self.seq, int(mo.group(1)))

    def tags_for(self, hdrs) -> dict:
        tags = dict(self.base_tags)
        if self.tags_file:
            try:
                with open(self.tags_file) as fh:
                    t = json.load(fh)
                if isinstance(t, dict):
                    tags.update({str(k): v for k, v in t.items() if v not in (None, "")})
            except FileNotFoundError:
                pass
            except Exception as e:  # noqa: BLE001
                log(f"tags file unreadable, ignored: {e!r}")
        for k, v in hdrs:
            if k.lower().startswith("x-factory-") and len(k) > 10:
                tags[k[10:].lower().replace("-", "_")] = v
        return tags

    def write(self, rec: dict, body: bytes) -> None:
        with self.lock:
            self.seq += 1
            rec["seq"] = self.seq
            rec["ts"] = rec.get("ts") or now_iso()
            if self.requests_dir:
                role = re.sub(r"[^A-Za-z0-9_.-]", "_", str(rec["tags"].get("role") or "unknown"))
                stem = os.path.join(self.requests_dir, f"{self.seq:05d}-{role}")
                with open(stem + ".request.json", "wb") as fh:
                    fh.write(body)  # the body as sent, byte for byte: what a replay sends
                with open(stem + ".meta.json", "w") as fh:
                    json.dump({"path": rec["path"], "tags": rec["tags"], "ts": rec["ts"]}, fh)
                    fh.write("\n")
                rec["request_file"] = os.path.basename(stem) + ".request.json"
            with open(self.log_path, "a") as fh:
                fh.write(json.dumps(rec, separators=(",", ":")) + "\n")


# ---------------------------------------------------------------- the server
class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        client: socket.socket = self.request
        try:
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        r = Reader(client)
        while True:
            try:
                head, method, target, version, hdrs = read_request(r)
            except (EOFError, ConnectionError, OSError):
                return  # the client is done with this connection
            except ValueError as e:
                log(f"unreadable request, connection dropped: {e}")
                return
            srv: Server = self.server  # type: ignore[assignment]
            with srv.busy_lock:
                srv.busy += 1
            try:
                keep = self.one(client, r, head, method, target, version, hdrs)
            finally:
                with srv.busy_lock:
                    srv.busy -= 1
            if not keep:
                return

    def one(self, client, r, head, method, target, version, hdrs) -> bool:
        """Forward one request and relay its response. -> keep the connection?"""
        srv: Server = self.server  # type: ignore[assignment]
        if (hget(hdrs, "Expect") or "").lower() == "100-continue":
            client.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            head = re.sub(rb"(?im)^expect:[^\r\n]*\r\n", b"", head)
        try:
            raw_body, body = read_request_body(r, hdrs)
        except (EOFError, ConnectionError, OSError, ValueError):
            return False
        t0 = time.monotonic()
        path = target.split("?", 1)[0]
        record = method == "POST" and path in MODEL_PATHS
        m = Metrics(t0)
        ctype = {}

        def on_head(status, rh):
            ctype["ct"] = hget(rh, "Content-Type")
            m.set_content_type(ctype["ct"])

        fr = Framing(method, on_head, m.feed if record else (lambda b: None))
        error = None
        keep = True
        try:
            up = socket.create_connection(srv.upstream)
        except OSError as e:
            msg = f"upstream {srv.upstream[0]}:{srv.upstream[1]} unreachable: {e}".encode()
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n"
                           b"Content-Length: " + str(len(msg)).encode() + b"\r\n"
                           b"Connection: close\r\n\r\n" + msg)
            log(msg.decode())
            if record:
                self.record(path, body, hdrs, 502, t0, m, f"upstream unreachable: {e}")
            return False
        try:
            up.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            up.sendall(head + raw_body)
            parse_ok = True
            while True:
                data = up.recv(65536)
                if not data:
                    break
                # Relay FIRST. Whatever the parser makes of these bytes, the
                # client already has them.
                try:
                    client.sendall(data)
                except OSError:
                    error = "client went away before the response finished"
                    keep = False
                    break
                if parse_ok:
                    try:
                        fr.feed(data)
                    except Exception as e:  # noqa: BLE001
                        parse_ok = False
                        keep = False  # framing unknown: relay to EOF and close
                        error = f"response not followable: {e}"
                        log(error)
                if parse_ok and fr.done:
                    break
            if not fr.done and not fr.until_close and error is None:
                error = "upstream closed before the response was complete"
                keep = False
        except OSError as e:
            error = f"forwarding failed: {e}"
            keep = False
        finally:
            try:
                up.close()
            except OSError:
                pass
        if fr.until_close:
            keep = False
        conn_hdrs = ((hget(hdrs, "Connection") or "") + "," + (hget(fr.headers, "Connection") or "")).lower()
        if "close" in conn_hdrs or version == "HTTP/1.0":
            keep = False
        if record:
            m.finish()
            self.record(path, body, hdrs, fr.status, t0, m, error)
        if not keep:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        return keep

    def record(self, path, body, hdrs, status, t0, m, error) -> None:
        srv: Server = self.server  # type: ignore[assignment]
        try:
            try:
                req = json.loads(body) if body else None
            except ValueError:
                req = None
            rec = build_record(path, req, len(body), srv.recorder.tags_for(hdrs), status,
                               time.monotonic() - t0, m, error)
            srv.recorder.write(rec, body)
        except Exception as e:  # noqa: BLE001 — never the forwarding's problem
            log(f"could not record a call to {path}: {e!r}")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, listen, upstream, recorder):
        self.upstream = upstream
        self.recorder = recorder
        # Requests between "read" and "recorded". The client has its response
        # a moment before the record is written, so a stop that does not wait
        # for this loses the last call of a replay.
        self.busy = 0
        self.busy_lock = threading.Lock()
        super().__init__(listen, Handler)


def hostport(s: str, what: str) -> tuple[str, int]:
    s = re.sub(r"^https?://", "", s).rstrip("/")
    h, _, p = s.rpartition(":")
    if not h or not p.isdigit():
        raise SystemExit(f"{what} must be host:port, got {s!r}")
    return h, int(p)


def cmd_serve(a) -> int:
    rec = Recorder(a.log, a.requests_dir, a.tags_file)
    srv = Server(hostport(a.listen, "--listen"), hostport(a.upstream, "--upstream"), rec)
    host, port = srv.server_address[:2]
    if a.port_file:
        tmp = a.port_file + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(f"{port}\n")
        os.replace(tmp, a.port_file)
    log(f"{host}:{port} -> {a.upstream}, recording to {a.log}")

    def stop(*_):
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if a.parent_pid:
        # Ends with the run that started it, however that run ends. orchestrate
        # leaves through a dozen `exit`s and a signal handler; following its pid
        # covers all of them, a kill -9 included, without touching any of them.
        def watch():
            while True:
                time.sleep(1)
                try:
                    os.kill(a.parent_pid, 0)
                except ProcessLookupError:
                    log(f"parent {a.parent_pid} is gone; stopping")
                    stop()
                    return
                except PermissionError:
                    pass
        threading.Thread(target=watch, daemon=True).start()
    srv.serve_forever(poll_interval=0.2)
    srv.server_close()
    # Let a call that has its response finish writing its record — briefly. A
    # call still waiting on the model is abandoned with the run that made it.
    deadline = time.monotonic() + 3
    while srv.busy and time.monotonic() < deadline:
        time.sleep(0.05)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve", help="forward and record")
    p.add_argument("--listen", required=True, help="host:port to listen on (port 0: pick one)")
    p.add_argument("--upstream", required=True, help="host:port of the model server")
    p.add_argument("--log", required=True, help="JSONL file, one line per model call (appended)")
    p.add_argument("--requests-dir", help="save each request body here, for replay")
    p.add_argument("--tags-file", help="JSON object of tags, re-read on every call")
    p.add_argument("--port-file", help="write the port actually bound here")
    p.add_argument("--parent-pid", type=int, help="stop when this process exits")
    a = ap.parse_args()
    return {"serve": cmd_serve}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
