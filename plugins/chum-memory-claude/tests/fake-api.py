"""Fake / proxying chum-mem API for the hook tests (test-only; the hooks never need python).

usage: python3 -I fake-api.py <port> <state-dir> [upstream-url]

Every request is logged as "<METHOD> <path>" to <state-dir>/requests.log.
Behaviour is switched at run time by files in <state-dir>:
  health-down   GET /health answers 503
  start-503     POST /v1/ingest/session/start answers 503
  mcp-500       POST /mcp (the docs search) answers 500
  search.json   body returned by POST /api/search      (default {"hits": []})
  docs.json     body returned by POST /mcp             (default: no nodes)
  delay-ms      sleep this many milliseconds before every answer (tunnel latency)
Anything else is forwarded to [upstream-url] when given, else answered with a
canned success.
"""
import http.server
import json
import os
import sys
import time
import urllib.error
import urllib.request

PORT = int(sys.argv[1])
STATE = sys.argv[2]
UPSTREAM = sys.argv[3].rstrip("/") if len(sys.argv) > 3 else ""
FAKE_SID = "11111111-1111-4111-8111-111111111111"


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


def read_json(name, default):
    try:
        with open(os.path.join(STATE, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _delay(self):
        try:
            with open(os.path.join(STATE, "delay-ms")) as fh:
                time.sleep(int(fh.read().strip() or 0) / 1000.0)
        except (OSError, ValueError):
            pass

    def _log(self):
        with open(os.path.join(STATE, "requests.log"), "a") as fh:
            fh.write("%s %s\n" % (self.command, self.path))

    def _send(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _proxy(self, body):
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command)
        for key in ("Content-Type", "Accept", "X-Chum-Token"):
            if self.headers.get(key):
                req.add_header(key, self.headers[key])
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                code, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            code, raw = err.code, err.read()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._log()
        self._delay()
        if self.path.startswith("/health"):
            return self._send(503 if flag("health-down") else 200, {"status": "ok"})
        if UPSTREAM:
            return self._proxy(None)
        self._send(200, {})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._log()
        self._delay()
        if self.path.startswith("/v1/ingest/session/start") and flag("start-503"):
            return self._send(503, {"error": "database restarting"})
        if self.path.startswith("/mcp") and flag("mcp-500"):
            return self._send(500, {"error": "boom"})
        if self.path.startswith("/api/search") and (not UPSTREAM or flag("search.json")):
            return self._send(200, read_json("search.json", {"hits": []}))
        if self.path.startswith("/mcp") and (not UPSTREAM or flag("docs.json")):
            return self._send(200, read_json("docs.json", {"jsonrpc": "2.0", "id": 1, "result": {"structuredContent": {"nodes": []}}}))
        if UPSTREAM:
            return self._proxy(body)
        if self.path.startswith("/v1/ingest/session/start"):
            return self._send(200, {"sessionId": FAKE_SID, "status": "active"})
        if self.path.startswith("/v1/projects/resolve"):
            return self._send(200, json.loads(body or b"{}"))
        self._send(200, {"eventId": FAKE_SID, "duplicate": False})


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
