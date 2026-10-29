#!/usr/bin/env python3
"""Tiny stand-in for Uptime Kuma's push endpoint, for tests.

Usage: stub-server.py <port> <request-log> [valid-token]

Appends the request path of every GET to <request-log>. Answers 200
{"ok":true} on /api/push/<valid-token> (any token if omitted), else 404.
"""
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(LOG, "a") as f:
            f.write(self.path + "\n")
        ok = self.path.startswith("/api/push/" + (TOKEN or ""))
        body = b'{"ok":true}' if ok else b'{"ok":false,"msg":"Monitor not found or not active."}'
        self.send_response(200 if ok else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    PORT, LOG = int(sys.argv[1]), sys.argv[2]
    TOKEN = sys.argv[3] if len(sys.argv) > 3 else ""
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
