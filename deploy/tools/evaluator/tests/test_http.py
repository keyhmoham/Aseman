"""The evaluator's MCP server and its callbacks over real HTTP: the node's MCP
calls in, the tool gateway (/tools/v1/runtime/host) out."""

from __future__ import annotations

import json
import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from evaluator.host import Node  # noqa: E402
from evaluator.server import make_handler  # noqa: E402
from evaluator.service import Evaluator  # noqa: E402
from test_evaluator import FakeNode, fake_crawl, fake_market, token  # noqa: E402


def serve(handler) -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


class HttpTest(unittest.TestCase):
    def setUp(self):
        fake = self.fake = FakeNode()
        self.seen_tokens = []
        test = self

        class Gateway(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                test.seen_tokens.append(self.headers["Authorization"])
                from evaluator.host import HostError, Scope
                sc = Scope(token=self.headers["Authorization"].removeprefix("Bearer "), space="space-1")
                try:
                    out, status = fake.call(sc, body["namespace"], body["action"], body["body"]), 200
                except HostError as e:
                    out, status = {"error": {"code": e.code or "PERMISSION", "message": str(e)}}, e.status or 403
                raw = json.dumps(out).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, *a):
                pass

        self.gateway, gateway_url = serve(Gateway)
        from evaluator import llm
        self.ev = Evaluator(node=Node(gateway_url), crawl=fake_crawl, market=fake_market, analyse=llm.analyse)
        handler = make_handler(self.ev, "runtime-token")
        handler.log_message = lambda *a: None
        self.server, self.url = serve(handler)

    def tearDown(self):
        self.ev.stop()
        self.server.shutdown()
        self.gateway.shutdown()

    def rpc(self, method, params=None, space="space-1", tok="runtime-token"):
        req = urllib.request.Request(self.url + "/mcp", method="POST",
                                     data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode(),
                                     headers={"Content-Type": "application/json", "X-Tradera-Token": tok,
                                              "X-Tradera-Scope": token(), "X-Tradera-Space": space,
                                              "X-Tradera-Actor": "admin-1", "X-Tradera-Tool": "tool-1"})
        try:
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_round_trip(self):
        self.assertEqual(self.rpc("tools/list", tok="wrong")[0], 401)
        status, body = self.rpc("tools/call", {"name": "trader_add", "arguments": {
            "profile_link": "https://coinmarketcap.com/community/profile/daniel_crypto365/"}})
        self.assertEqual(status, 200, body)
        self.assertFalse(body["result"]["isError"], body)
        # The background worker evaluates it with the scope it was given.
        for _ in range(50):
            board = self.rpc("tools/call", {"name": "leaderboard", "arguments": {}}, space="")[1]["result"]["structuredContent"]
            if board["evaluated"]:
                break
            threading.Event().wait(0.1)
        self.assertEqual(board["traders"][0]["scores"]["overall_score"], 82, board)
        self.assertEqual(self.fake.asks[0]["bot"], "lead-bot")
        self.assertTrue(all(t.startswith("Bearer ") for t in self.seen_tokens))


if __name__ == "__main__":
    unittest.main()
