#!/usr/bin/env python3
"""Tiny throttled HTTP server used by tests/e2e.sh to exercise progress + cancellation."""
import http.server
import socketserver
import sys
import time

TOTAL = 5_000_000


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/slow.mp4":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(TOTAL))
        self.end_headers()
        sent = 0
        try:
            while sent < TOTAL:
                self.wfile.write(b"\0" * 65536)
                self.wfile.flush()
                sent += 65536
                time.sleep(0.12)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8948
    Server(("127.0.0.1", port), Handler).serve_forever()
