"""MCP over HTTP for the node (JSON-RPC 2.0: initialize, notifications/initialized,
ping, tools/list, tools/call), on $PORT at /mcp.

Only the node may call: every request must carry its runtime credential
(X-Tradera-Token == $TRADERA_TOOL_TOKEN). Each call's execution scope comes in
the X-Tradera-* headers.
"""

from __future__ import annotations

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .host import Scope
from .service import TOOLS, Evaluator, ToolError

PROTOCOL_VERSION = "2025-06-18"


def tool_result(value) -> dict:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    out = {"content": [{"type": "text", "text": text}], "isError": False}
    if isinstance(value, dict):
        out["structuredContent"] = value
    return out


def handle(evaluator: Evaluator, token: str, headers, message: dict) -> tuple[int, dict | None]:
    mid = message.get("id") if isinstance(message, dict) else None
    if token and not hmac.compare_digest(str(headers.get("X-Tradera-Token") or ""), token):
        return 401, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32001, "message": "unauthorized"}}
    method = message.get("method") if isinstance(message, dict) else None

    def reply(result):
        return 200, {"jsonrpc": "2.0", "id": mid, "result": result}

    if method == "initialize":
        return reply({"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {}},
                      "serverInfo": {"name": "tradera-evaluator", "version": "1.0.0"}})
    if method == "notifications/initialized":
        return 202, None
    if method == "ping":
        return reply({})
    if method == "tools/list":
        return reply({"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params") or {}
        try:
            value = evaluator.call(params.get("name") or "", params.get("arguments") or {}, Scope.from_headers(headers))
            return reply(tool_result(value))
        except Exception as exc:  # a failing microtool is a result the caller reads
            text = str(exc) if isinstance(exc, ToolError) else f"{type(exc).__name__}: {exc}"
            return reply({"content": [{"type": "text", "text": text}], "isError": True})
    if mid is None:
        return 202, None
    return 200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}


def make_handler(evaluator: Evaluator, token: str, path: str = "/mcp"):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, status: int, body: dict | None) -> None:
            raw = json.dumps(body).encode() if body is not None else b""
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):  # health
            self._send(200 if self.path in ("/", "/health") else 404, {"ok": True, "tool": "evaluator"})

        def do_POST(self):
            if self.path.split("?", 1)[0] != path:
                return self._send(404, {"error": "not found"})
            size = int(self.headers.get("Content-Length") or 0)
            try:
                message = json.loads(self.rfile.read(size) or b"{}")
            except Exception:
                return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            status, body = handle(evaluator, token, self.headers, message)
            self._send(status, body)

        def log_message(self, fmt, *args):
            sys.stderr.write("[evaluator] " + (fmt % args) + "\n")

    return Handler


def main() -> None:
    port = int(os.environ.get("PORT") or 8080)
    token = os.environ.get("TRADERA_TOOL_TOKEN") or ""
    if not token:
        print("[evaluator] warning: no TRADERA_TOOL_TOKEN, every caller is accepted", flush=True)
    evaluator = Evaluator()
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(evaluator, token))
    print(f"[evaluator] MCP on :{port}/mcp, node {evaluator.node.url}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
