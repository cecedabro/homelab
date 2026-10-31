"""Wake-on-LAN relay. Runs with hostNetwork so the broadcast reaches the LAN.

POST /wake  (header X-Waker-Token)  -> sends the magic packet to PC_MAC
GET  /healthz                        -> ok

Originally from github.com/cecedabro/local-ai-agent (k8s/waker). Lives here now because it is
cluster infrastructure. Changes: binds to BIND (the node's LAN IP) instead of 0.0.0.0, so it is not
exposed on the node's Tailscale interface, and broadcasts to the LAN subnet instead of
255.255.255.255 (that one leaves through whatever interface the default route picks).
"""
import hmac
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAC = os.environ["PC_MAC"].replace(":", "").replace("-", "").lower()
BROADCAST = os.environ.get("BROADCAST", "255.255.255.255")
TOKEN = os.environ["WAKER_TOKEN"]
BIND = os.environ.get("BIND", "0.0.0.0")
PORT = int(os.environ.get("PORT", "9009"))

if len(MAC) != 12:
    raise SystemExit(f"bad PC_MAC: {os.environ['PC_MAC']!r}")
if len(TOKEN) < 32:
    raise SystemExit("WAKER_TOKEN too short (use openssl rand -hex 32)")
PACKET = b"\xff" * 6 + bytes.fromhex(MAC) * 16


def send_magic() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for port in (9, 7):
            s.sendto(PACKET, (BROADCAST, port))


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code: int, body: str) -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        self._reply(200, "ok\n") if self.path == "/healthz" else self._reply(404, "not found\n")

    def do_POST(self) -> None:
        if self.path != "/wake":
            return self._reply(404, "not found\n")
        if not hmac.compare_digest(self.headers.get("X-Waker-Token", ""), TOKEN):
            return self._reply(403, "forbidden\n")
        send_magic()
        self._reply(202, "sent\n")


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
