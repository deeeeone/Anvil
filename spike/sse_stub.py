#!/usr/bin/env python3
"""Stdlib-only OpenAI-style SSE stub for the anvil-spike sse check.

Usage: python3 sse_stub.py [PORT]   (default 8765, binds 127.0.0.1)
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 chunked, like real OpenAI-compatible providers.
    protocol_version = "HTTP/1.1"

    def _chunk(self, b):
        self.wfile.write(b"%x\r\n" % len(b) + b + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        sys.stderr.write("stub: headers %r\n" % dict(self.headers)); sys.stderr.flush()
        if self.headers.get("Expect", "").lower() == "100-continue":
            self.send_response_only(100); self.end_headers()
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            while True:  # drain a chunked request body
                size = int(self.rfile.readline().strip() or b"0", 16)
                self.rfile.read(size + 2)
                if size == 0:
                    break
        else:
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length:
                self.rfile.read(length)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for n in range(1, 6):
            chunk = '{"choices":[{"delta":{"content":"tok %d"}}]}' % n
            self._chunk(("data: %s\n\n" % chunk).encode("utf-8"))
            time.sleep(0.2)
        self._chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write("stub: " + (fmt % args) + "\n")


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    Server(("127.0.0.1", port), Handler).serve_forever()
