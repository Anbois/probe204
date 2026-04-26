#!/usr/bin/env python3
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("PROBE204_HOST", "0.0.0.0")
PORT = int(os.environ.get("PROBE204_PORT", "18080"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/generate_204":
            self.send_response(204)
            self.end_headers()
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.serve_forever()
