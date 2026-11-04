#!/usr/bin/env python3
"""Tiny LAN upload endpoint so a phone/head unit can push probe reports into the repo.

Run on the workstation:
  UPLOAD_TOKEN=$(openssl rand -hex 16) python3 scripts/upload_server.py
  # or: python3 scripts/upload_server.py   (token printed on stdout)

Receiver side (Termux / any curl):
  curl -T probe.md "http://HOST:8765/upload?token=...&name=probe.md"

Writes into ./incoming/ (gitignored). No authentication beyond a shared random token, only
listens on the LAN, caps uploads at 20 MB, and never touches anything else.
"""
import http.server
import os
import urllib.parse
from pathlib import Path

PORT = int(os.environ.get("UPLOAD_PORT", "8765"))
INCOMING = Path(os.environ.get("INCOMING_DIR", "incoming"))
TOKEN = os.environ.get("UPLOAD_TOKEN") or os.urandom(16).hex()
MAX_BYTES = 20 * 1024 * 1024
SAFE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if q.get("token", [""])[0] != TOKEN:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"bad token\n")
            return
        name = "".join(c for c in q.get("name", ["probe.md"])[0] if c in SAFE)[:80] or "probe.md"
        length = int(self.headers.get("Content-Length", "0"))
        if length > MAX_BYTES:
            self.send_response(413)
            self.end_headers()
            self.wfile.write(b"too large\n")
            return
        INCOMING.mkdir(parents=True, exist_ok=True)
        dest = INCOMING / name
        with dest.open("wb") as fh:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"saved {dest} ({length} bytes)\n".encode())
        print(f"{self.client_address[0]} -> {dest} ({length} bytes)")

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"upload endpoint ready; POST/PUT with ?token=&name=\n")

    # curl -T sends PUT; curl -X POST -T sends POST. Accept both.
    do_PUT = do_POST

    def log_message(self, fmt, *args):
        pass


def main():
    INCOMING.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"listening on 0.0.0.0:{PORT}, writing to {INCOMING.resolve()}")
    print(f"TOKEN={TOKEN}")
    print("phone/unit side:  curl -T probe.md 'http://<this-host-ip>:%s/upload?token=%s&name=probe.md'" % (PORT, TOKEN))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
