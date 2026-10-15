"""The evaluator's MCP server and its callbacks over real HTTP: the node's MCP
calls in, the tool gateway (/tools/v1/runtime/host) out."""

from __future__ import annotations

import hashlib
import json
import sys
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat  # noqa: E402

from evaluator.host import Node  # noqa: E402
from evaluator.platform import Platform, PlatformError, Session  # noqa: E402
from evaluator.server import make_handler  # noqa: E402
from evaluator.service import Evaluator  # noqa: E402
from test_evaluator import FakeNode, FakePlatform, fake_crawl, fake_market, token  # noqa: E402


def serve(handler) -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


class HttpTest(unittest.TestCase):
    def setUp(self):
        fake = self.fake = FakeNode()
        self.seen_tokens = []
        test = self

        self.keys: dict[str, Ed25519PrivateKey] = {}   # account id -> identity key
        self.sessions: dict[str, str] = {}             # token -> account id
        self.nonces: set[str] = set()
        self.bad_signatures = 0

        class Gateway(BaseHTTPRequestHandler):
            def reply(self, status, out):
                raw = json.dumps(out).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def public_api(self, raw: bytes):
                """The node's /v1 gateway: auth.login, and signed requests (as the gateway verifies them)."""
                path = self.path
                body = json.loads(raw or b"{}")
                if path == "/v1/auth/login":
                    acc = fake.accounts.get(body.get("account"))
                    if not acc or acc["password"] != body.get("password"):
                        return self.reply(401, {"error": "invalid credentials", "code": "UNAUTHENTICATED"})
                    key = test.keys.setdefault(acc["id"], Ed25519PrivateKey.generate())
                    seed = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
                    pub = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
                    tok = f"session-{len(test.sessions)}"
                    test.sessions[tok] = acc["id"]
                    return self.reply(200, {"account_id": acc["id"], "handle": body["account"], "token": tok,
                                            "private_key": (seed + pub).hex()})
                account = test.sessions.get(self.headers.get("Authorization", "").removeprefix("Bearer "))
                if account is None:
                    return self.reply(401, {"error": "authentication required", "code": "UNAUTHENTICATED"})
                nonce, ts, sig = (self.headers.get(h) for h in ("X-Tradera-Nonce", "X-Tradera-Timestamp", "X-Tradera-Signature"))
                payload = "\n".join(["POST", path, nonce or "", ts or "", hashlib.sha256(raw).hexdigest()]).encode()
                try:
                    test.keys[account].public_key().verify(bytes.fromhex(sig or ""), payload)
                except Exception:
                    test.bad_signatures += 1
                    return self.reply(401, {"error": "invalid signature", "code": "UNAUTHENTICATED"})
                if nonce in test.nonces or abs(time.time() - int(ts)) > 300:
                    return self.reply(401, {"error": "replayed request nonce", "code": "UNAUTHENTICATED"})
                test.nonces.add(nonce)
                ns, action = path.split("/")[2:4]
                if ns == "auth" and action == "logout":
                    return self.reply(200, {"ok": True})
                try:
                    return self.reply(200, FakePlatform(fake).call(Session(account, "", "", ""), ns, action, body) | {})
                except PlatformError as e:
                    return self.reply(e.status, {"error": str(e), "code": e.code})

            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path.startswith("/v1/"):
                    return self.public_api(raw)
                body = json.loads(raw)
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
        self.ev = Evaluator(node=Node(gateway_url), crawl=fake_crawl, market=fake_market, analyse=llm.analyse,
                            platform=Platform(gateway_url))
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
        # It signed in as the trader with the password it made, and published their post with signed requests.
        acc = self.fake.accounts["daniel_crypto365"]
        self.assertEqual([p["author"] for p in self.fake.posts.values()], [acc["id"]])
        self.assertIn("$BTC long to 70k", next(iter(self.fake.posts.values()))["body"])
        self.assertEqual(self.bad_signatures, 0)
        creds = self.rpc("tools/call", {"name": "trader_credentials", "arguments": {"handle": "daniel_crypto365"}})[1]
        self.assertEqual(creds["result"]["structuredContent"]["password"], acc["password"])
        removed = self.rpc("tools/call", {"name": "trader_remove", "arguments": {"handle": "daniel_crypto365"}})[1]
        self.assertEqual(removed["result"]["structuredContent"]["posts_deleted"], 1)
        self.assertEqual((self.fake.posts, self.fake.accounts), ({}, {}))


if __name__ == "__main__":
    unittest.main()
