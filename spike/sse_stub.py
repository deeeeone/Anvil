#!/usr/bin/env python3
"""Stdlib-only OpenAI-style SSE stub for the anvil-spike sse check.

Usage: python3 sse_stub.py [PORT]   (default 8765, binds 127.0.0.1)
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 close-delimited body: no Content-Length, no chunked encoding.
    protocol_version = "HTTP/1.0"

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)  # consume the request body first

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for n in range(1, 6):
            chunk = '{"choices":[{"delta":{"content":"tok %d"}}]}' % n
            self.wfile.write(("data: %s\n\n" % chunk).encode("utf-8"))
            self.wfile.flush()
            time.sleep(0.2)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write("stub: " + (fmt % args) + "\n")


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    Server(("127.0.0.1", port), Handler).serve_forever()
