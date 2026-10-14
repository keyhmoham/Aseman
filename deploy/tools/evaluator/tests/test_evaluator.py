"""The evaluator against an in-memory node (no browser, network or model).

    cd deploy/tools/evaluator && python3 -m unittest discover -s tests
"""

from __future__ import annotations

import base64
import json
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from evaluator import crawler, market, scoring  # noqa: E402
from evaluator.host import HostError, Scope, token_expiry  # noqa: E402
from evaluator.prompt import build_objective  # noqa: E402
from evaluator.server import handle  # noqa: E402
from evaluator.service import Evaluator, ToolError  # noqa: E402
from evaluator.store import SESSION, handle_of  # noqa: E402


def token(exp_in: float = 900) -> str:
    body = base64.urlsafe_b64encode(json.dumps({"bot": "b", "exp": int(time.time() + exp_in)}).encode()).decode().rstrip("=")
    return body + ".sig"


def scope(space: str = "space-1", exp_in: float = 900) -> Scope:
    return Scope(token=token(exp_in), tool="tool-1", actor="admin-1", space=space, room="room-1" if space else "",
                 exp=time.time() + exp_in)


class FakeNode:
    """The tool gateway: the tool's KV store and the space's members/agent."""

    url = "http://node"

    def __init__(self):
        self.kv: dict[str, str] = {}
        self.asks: list[dict] = []
        self.reply = json.dumps({"overall_score": 82, "technical_score": 88, "fundamental_score": 61,
                                 "historical_accuracy": 70, "consistency": 75, "risk_management": 55,
                                 "timing": 64, "confidence": 58, "strengths": ["clear invalidation"],
                                 "weaknesses": ["no stops"], "warnings": []})

    def call(self, sc, namespace, action, body=None, timeout=None):
        if not sc or not sc.token:
            raise HostError("no scope")
        body = body or {}
        name = f"{namespace}.{action}"
        if name == "bots.kv_get":
            if body["key"] not in self.kv:
                raise HostError("kv key missing", status=404, code="NOT_FOUND")
            return {"key": body["key"], "value": self.kv[body["key"]]}
        if name == "bots.kv_set":
            json.loads(body["value"])  # the node keeps JSONB
            self.kv[body["key"]] = body["value"]
            return {"ok": True}
        if name == "bots.kv_delete":
            self.kv.pop(body["key"], None)
            return {"ok": True}
        if name == "bots.kv_list":
            items = [{"key": k, "value": v} for k, v in self.kv.items()]
            off, lim = body.get("offset", 0), body.get("limit", 50)
            return {"items": items[off:off + lim]}
        if name == "spaces.members_list":
            if not sc.space:
                raise HostError("not from a space", status=403)
            return {"members": [{"handle": "node-a", "kind": "user"},
                                {"handle": "tradera", "kind": "bot", "bot_id": "lead-bot"}]}
        if name == "spaces.ask":
            self.asks.append(body)
            return {"bot_id": body["bot"], "reply": "Here is the report:\n```json\n" + self.reply + "\n```"}
        raise HostError(f"{name} not allowed", status=403)


POST_TIME = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)


def fake_crawl(url, handle, session, proxy, scrolls=8):
    return {"url": url, "analyst": {"username": handle, "followers": 1200, "total_posts": 3},
            "posts": [{"id": "p1", "text": "$BTC long to 70k, stop 58k", "timestamp": POST_TIME.isoformat(), "symbols": ["BTC"]}],
            "page_text": "", "errors": [], "logged_out_or_missing": False}


def fake_market(posts):
    return {"posts": {"p1": {"BTC": {"return_7d_pct": 4.2}}}}


class EvaluatorTest(unittest.TestCase):
    def setUp(self):
        self.node = FakeNode()
        from evaluator import llm
        self.ev = Evaluator(node=self.node, crawl=fake_crawl, market=fake_market, analyse=llm.analyse)
        self.ev.ensure_worker = lambda: None  # run the worker by hand

    def add(self, link="https://coinmarketcap.com/community/profile/Daniel_Crypto365"):
        return self.ev.call("trader_add", {"profile_link": link}, scope())

    def test_add_requires_admins_space_and_valid_link(self):
        with self.assertRaises(ToolError):
            self.ev.call("trader_add", {"profile_link": "https://coinmarketcap.com/community/profile/x/"}, scope(space=""))
        with self.assertRaises(ToolError):
            self.ev.call("trader_add", {"profile_link": "https://example.com/profile/x"}, scope())
        out = self.add()
        self.assertTrue(out["created"])
        self.assertEqual(out["trader"]["handle"], "daniel_crypto365")
        self.assertEqual(out["trader"]["profile_link"], "https://coinmarketcap.com/community/profile/Daniel_Crypto365/")
        self.assertEqual(self.ev.queue, ["daniel_crypto365"])
        self.assertFalse(self.add()["created"])  # upsert, no duplicate
        self.assertEqual(json.loads(self.node.kv["evaluator/traders"]), ["daniel_crypto365"])

    def test_evaluation_stores_scores_and_leaderboard_reads_them(self):
        self.add()
        self.add("https://coinmarketcap.com/community/profile/second/")
        self.assertEqual(self.ev.run_due(), 2)
        self.assertEqual(self.node.asks[0]["bot"], "lead-bot")
        prompt = self.node.asks[0]["body"]
        self.assertIn("institutional-grade Financial Intelligence AI", prompt)
        self.assertIn("https://coinmarketcap.com/community/profile/Daniel_Crypto365/", prompt)
        self.assertIn("$BTC long to 70k", prompt)
        self.assertIn("return_7d_pct", prompt)

        board = self.ev.call("leaderboard", {"board": "technical"}, scope(space=""))  # a public read
        self.assertEqual(board["evaluated"], 2)
        first = board["traders"][0]
        self.assertEqual(first["scores"]["technical_score"], 88)
        self.assertEqual(first["rating"], "Advanced")
        self.assertEqual(first["rank"], 1)
        self.assertEqual(first["followers"], 1200)

        profile = self.ev.call("trader_get", {"handle": "@Second"}, scope(space=""))
        self.assertEqual(profile["report"]["weaknesses"], ["no stops"])
        self.assertEqual(len(profile["history"]), 1)

        # Evaluated again: history grows and the change is reported.
        self.node.reply = self.node.reply.replace('"overall_score": 82', '"overall_score": 85')
        self.ev.call("evaluate_now", {"handle": "second"}, scope())
        self.ev.run_due()
        entry = [t for t in self.ev.call("leaderboard", {}, scope(space=""))["traders"] if t["handle"] == "second"][0]
        self.assertEqual(entry["change"], 3.0)

    def test_nothing_is_due_until_the_interval_passes(self):
        self.add()
        self.ev.run_due()
        self.assertIsNone(self.ev.next_due())
        self.ev.clock = lambda: time.time() + 13 * 3600
        self.assertEqual(self.ev.next_due(), "daniel_crypto365")

    def test_failures_are_recorded(self):
        self.add()
        self.node.reply = "I could not do it"
        self.ev.run_due()
        rec = self.ev.call("trader_get", {"handle": "daniel_crypto365"}, scope(space=""))
        self.assertEqual(rec["status"], "error")
        self.assertIn("Final JSON", rec["last_error"])
        self.assertIsNone(self.ev.next_due())
        self.ev.clock = lambda: time.time() + 3601  # retried within the hour
        self.assertEqual(self.ev.next_due(), "daniel_crypto365")

    def test_a_trader_left_running_is_picked_up_again(self):
        self.add()
        self.ev.queue.clear()
        rec = json.loads(self.node.kv["evaluator/trader/daniel_crypto365"])
        rec.update({"status": "running", "last_attempt_at": datetime.now(timezone.utc).isoformat()})
        self.node.kv["evaluator/trader/daniel_crypto365"] = json.dumps(rec)
        self.assertEqual(self.ev.next_due(), "daniel_crypto365")

    def test_worker_needs_a_space_scope_to_ask_the_agent(self):
        self.add()
        self.ev.scopes.space_scope = Scope()  # only a public read's scope left
        self.ev.scopes.offer(scope(space=""))
        self.ev.run_due()
        rec = self.ev.call("trader_get", {"handle": "daniel_crypto365"}, scope(space=""))
        self.assertIn("tick", rec["last_error"])

    def test_session_and_config(self):
        state = {"cookies": [{"name": "Authorization", "value": "Bearer x", "domain": ".coinmarketcap.com", "path": "/", "expires": 1893456000}],
                 "origins": [{"origin": "https://coinmarketcap.com", "localStorage": []}]}
        out = self.ev.call("set_session", {"storage_state": json.dumps(state)}, scope())
        self.assertTrue(out["logged_in"])
        self.assertEqual(json.loads(self.node.kv[SESSION])["cookies"][0]["value"], "Bearer x")
        cfg = self.ev.call("configure", {"interval_hours": 6, "llm_api_key": "secret"}, scope())
        self.assertEqual(cfg["interval_hours"], 6.0)
        self.assertNotIn("llm_api_key", cfg)
        status = self.ev.call("status", {}, scope(space=""))
        self.assertTrue(status["config"]["llm_api_key_set"])
        self.assertNotIn("Bearer", json.dumps(status))

    def test_remove(self):
        self.add()
        self.ev.call("trader_remove", {"handle": "daniel_crypto365"}, scope())
        self.assertEqual(self.ev.call("leaderboard", {}, scope(space=""))["total"], 0)


class PartsTest(unittest.TestCase):
    def test_prompt_is_decifis(self):
        text = build_objective("https://coinmarketcap.com/community/profile/a", datetime(2026, 10, 14, tzinfo=timezone.utc))
        self.assertTrue(text.startswith("Today's real-world date is Wednesday, 14 October 2026"))
        self.assertIn("naviagte to the trader's coin market cap profile at https://coinmarketcap.com/community/profile/a/ and do", text)
        self.assertIn("Confidence %\n", text)
        self.assertIn('"overall_score":0', text)

    def test_handle_of(self):
        self.assertEqual(handle_of("https://coinmarketcap.com/community/profile/Vlad_Anderson/?tab=posts"), "vlad_anderson")
        self.assertEqual(handle_of("https://coinmarketcap.com/currencies/bitcoin/"), "")

    def test_token_expiry(self):
        self.assertAlmostEqual(token_expiry(token(100)), time.time() + 100, delta=2)
        self.assertEqual(token_expiry("garbage"), 0.0)

    def test_extract_json_and_normalize(self):
        reply = 'Report {"note": "x"} then {"overall_score": "91.5", "technical_score": {"score": 0.8}, "confidence": 140, "strengths": "x"}'
        report, summary = scoring.normalize(scoring.extract_json(reply))
        self.assertEqual(summary["overall_score"], 91.5)
        self.assertEqual(summary["technical_score"], 80.0)
        self.assertEqual(summary["confidence"], 100.0)
        self.assertEqual(summary["rating"], "Professional")
        self.assertEqual(report["strengths"], [])
        self.assertIsNone(scoring.extract_json("no json here"))
        self.assertEqual(scoring.rating(39.9), "Unreliable")

    def test_extract_posts_from_gravity_responses(self):
        payload = {"data": {"list": [
            {"gravityId": "1", "textContent": "Buying $ETH here, target 4k #Bitcoin", "postTime": "1756728000000",
             "owner": {"handle": "abc"}, "likeCount": "4",
             "originalContent": json.dumps([[{"type": "text", "content": "Buying "},
                                            {"type": "token", "content": {"symbol": "SOL", "slug": "solana"}}]])},
            {"gravityId": "2", "textContent": "gm", "postTime": "1756728000000", "owner": {"handle": "abc"}},
            {"gravityId": "3", "textContent": "Someone else's pinned post about $DOGE", "postTime": "1756728000000",
             "owner": {"handle": "CoinMarketCap"}},
        ], "owner": {"handle": "abc", "followers": 99, "postCount": 12}}}
        posts = crawler.extract_posts([payload], "ABC")
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["symbols"], ["ETH", "SOL"])
        self.assertTrue(posts[0]["timestamp"].startswith("2025-09-01"))
        analyst = crawler.extract_analyst([payload], "abc")
        self.assertEqual((analyst["followers"], analyst["total_posts"]), (99, 12))

    def test_session_formats(self):
        jar = [{"name": "Authorization", "value": "t", "domain": ".coinmarketcap.com", "path": "/"}]
        self.assertEqual(crawler.load_session(jar), (None, jar))
        self.assertEqual(crawler.load_session(json.dumps({"cookies": jar}))[0], {"cookies": jar})

    def test_market_outcomes(self):
        start = datetime(2026, 1, 1, tzinfo=timezone.utc)
        rows = [[(start + timedelta(days=i)).timestamp() * 1000, 100 + i, 105 + i, 95 + i, 100 + i, 1] for i in range(40)]

        def fetch(url):
            if "klines" in url:
                return rows if "BTCUSDT" in url and "binance.vision" in url else []
            return {"data": [{"timestamp": str(int((start + timedelta(days=3)).timestamp())), "value": "20", "value_classification": "Extreme Fear"}]}

        posts = [{"id": "p", "timestamp": (start + timedelta(days=3, hours=2)).isoformat(), "symbols": ["BTC", "NOPE"]}]
        ctx = market.market_context(posts, fetch=fetch)
        o = ctx["posts"]["p"]["BTC"]
        self.assertEqual(o["price_at_post"], 103)
        self.assertEqual(o["return_7d_pct"], round(7 / 103 * 100, 2))
        self.assertEqual(o["max_down_7d_pct"], round((99 - 103) / 103 * 100, 2))
        self.assertEqual(ctx["posts"]["p"]["fear_greed_at_post"]["value"], 20)
        self.assertIn("unavailable", ctx["symbols"]["NOPE"])


class McpTest(unittest.TestCase):
    def test_protocol_and_credential(self):
        ev = Evaluator(node=FakeNode())
        status, body = handle(ev, "tok", {"X-Tradera-Token": "bad"}, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.assertEqual(status, 401)
        h = {"X-Tradera-Token": "tok", "X-Tradera-Scope": token(), "X-Tradera-Space": ""}
        _, body = handle(ev, "tok", h, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(body["result"]["protocolVersion"], "2025-06-18")
        _, body = handle(ev, "tok", h, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertIn("leaderboard", [t["name"] for t in body["result"]["tools"]])
        _, body = handle(ev, "tok", h, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "leaderboard", "arguments": {}}})
        self.assertEqual(body["result"]["structuredContent"]["traders"], [])
        _, body = handle(ev, "tok", h, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "trader_add", "arguments": {}}})
        self.assertTrue(body["result"]["isError"])
        self.assertIn("admins space", body["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
