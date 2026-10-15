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
from evaluator.platform import PlatformError, Session, username_for  # noqa: E402
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
        self.accounts: dict[str, dict] = {}  # handle -> {id, password}
        self.posts: dict[str, dict] = {}     # post id -> {author, body, tags, source_id}
        self.imports: list[dict] = []
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
        if name == "users.account_create":
            if not sc.space:
                raise HostError("only in the admins space", status=403, code="PERMISSION")
            if body["handle"] in self.accounts:
                raise HostError("handle taken", status=409, code="ALREADY_EXISTS")
            acc = {"id": f"acc-{len(self.accounts) + 1}", "password": body["password"], "name": body.get("display_name")}
            self.accounts[body["handle"]] = acc
            return {"id": acc["id"], "handle": body["handle"]}
        if name == "users.account_delete":
            handle = next((h for h, a in self.accounts.items() if a["id"] == body["account"]), None)
            if handle is None:
                raise HostError("no account", status=404, code="NOT_FOUND")
            del self.accounts[handle]
            return {"ok": True}
        if name == "posts.post_import":
            if not sc.space:
                raise HostError("only in the admins space", status=403, code="PERMISSION")
            if body["author"] not in {a["id"] for a in self.accounts.values()}:
                raise HostError("not a managed account", status=403, code="PERMISSION")
            self.imports.append(body)
            results = []
            for item in body["posts"]:
                pid = next((k for k, p in self.posts.items()
                            if p["author"] == body["author"] and p.get("source_id") == item["source_id"]), None)
                if pid is None:
                    pid = f"post-{len(self.posts) + len(self.imports) * 100}"
                    media = [base64.b64decode(m["data"]) and m["name"] for m in item.get("media") or []]
                    self.posts[pid] = {"author": body["author"], "body": item["body"], "tags": item.get("tags"),
                                       "source_id": item["source_id"], "at": item.get("at"), "media": media}
                    results.append({"source_id": item["source_id"], "post_id": pid, "created": True, "media": media})
                else:
                    results.append({"source_id": item["source_id"], "post_id": pid, "created": False})
            created = sum(r["created"] for r in results)
            return {"ok": True, "created": created, "existing": len(results) - created, "failed": 0, "posts": results}
        if name == "spaces.ask":
            self.asks.append(body)
            return {"bot_id": body["bot"], "reply": "Here is the report:\n```json\n" + self.reply + "\n```"}
        raise HostError(f"{name} not allowed", status=403)


class FakePlatform:
    """The node's public API as a signed-in trader: auth and posts."""

    def __init__(self, node: FakeNode):
        self.node = node
        self.logins: list[str] = []
        self.calls: list[tuple[str, str]] = []
        self.seq = 0

    def login(self, handle, password):
        acc = self.node.accounts.get(handle)
        if not acc or acc["password"] != password:
            raise PlatformError("invalid credentials", status=401, code="UNAUTHENTICATED")
        self.logins.append(handle)
        return Session(acc["id"], handle, "tok", "00" * 64)

    def logout(self, session):
        pass

    def call(self, session, namespace, action, body):
        self.calls.append((namespace, action))
        posts = self.node.posts
        if action == "post_create":
            self.seq += 1
            pid = f"post-{self.seq}"
            posts[pid] = {"author": session.account_id, "body": body["body"], "tags": body.get("tags")}
            return {"post_id": pid, "ok": True}
        if action in ("post_get", "post_delete"):
            if body["post"] not in posts:
                raise PlatformError("post not found", status=404, code="NOT_FOUND")
            if action == "post_delete":
                del posts[body["post"]]
            return {"ok": True}
        raise PlatformError(f"{namespace}.{action}?", status=400)


POST_TIME = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)


def fake_crawl(url, handle, session, proxy, scrolls=8):
    return {"url": url, "analyst": {"username": handle, "followers": 1200, "total_posts": 3},
            "posts": [{"id": "p1", "text": "$BTC long to 70k, stop 58k", "timestamp": POST_TIME.isoformat(), "symbols": ["BTC"]}],
            "page_text": "", "errors": [], "logged_out_or_missing": False}


def fake_market(posts):
    return {"posts": {"p1": {"BTC": {"return_7d_pct": 4.2}}}}


class Harness(unittest.TestCase):
    def setUp(self):
        self.node = FakeNode()
        from evaluator import llm
        self.platform = FakePlatform(self.node)
        self.ev = Evaluator(node=self.node, crawl=fake_crawl, market=fake_market, analyse=llm.analyse,
                            platform=self.platform)
        self.ev.ensure_worker = lambda: None  # run the worker by hand

    def add(self, link="https://coinmarketcap.com/community/profile/Daniel_Crypto365"):
        return self.ev.call("trader_add", {"profile_link": link}, scope())


class EvaluatorTest(Harness):
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


def crawl_with(posts):
    def crawl(url, handle, session, proxy, scrolls=8):
        return {"url": url, "analyst": {"username": handle, "followers": 10}, "posts": [dict(p) for p in posts],
                "page_text": "", "errors": [], "logged_out_or_missing": False}
    return crawl


def cmc_posts(n, start=POST_TIME):
    return [{"id": str(1000 + i), "text": f"$BTC call number {i}: long, stop below support",
             "timestamp": (start + timedelta(hours=i)).isoformat(), "symbols": ["BTC"]} for i in range(n)]


class AccountsTest(Harness):
    def test_adding_a_trader_makes_their_account(self):
        out = self.add()
        acc = self.node.accounts["daniel_crypto365"]
        self.assertEqual(out["trader"]["platform_account"], {"id": acc["id"], "handle": "daniel_crypto365"})
        self.assertGreaterEqual(len(acc["password"]), 20)
        creds = self.ev.call("trader_credentials", {"handle": "daniel_crypto365"}, scope())
        self.assertEqual((creds["username"], creds["password"]), ("daniel_crypto365", acc["password"]))
        # Nothing public shows the password.
        for name, args in (("leaderboard", {}), ("trader_get", {"handle": "daniel_crypto365"}), ("traders_list", {})):
            self.assertNotIn(acc["password"], json.dumps(self.ev.call(name, args, scope(space=""))), name)
        with self.assertRaises(ToolError):  # an admin microtool
            self.ev.call("trader_credentials", {"handle": "daniel_crypto365"}, scope(space=""))
        # Adding them again keeps the account.
        self.assertFalse(self.add()["created"])
        self.assertEqual(len(self.node.accounts), 1)

    def test_custom_and_taken_usernames(self):
        link = "https://coinmarketcap.com/community/profile/vlad_anderson/"
        with self.assertRaises(ToolError):
            self.ev.call("trader_add", {"profile_link": link, "username": "bad name!"}, scope())
        self.node.accounts["vlad_anderson"] = {"id": "someone-else", "password": "x"}
        with self.assertRaises(ToolError) as taken:
            self.ev.call("trader_add", {"profile_link": link}, scope())
        self.assertIn("another `username`", str(taken.exception))
        self.assertEqual(self.ev.call("leaderboard", {}, scope(space=""))["total"], 0)  # not listed
        out = self.ev.call("trader_add", {"profile_link": link, "username": "vlad.trades", "name": "Vlad A"}, scope())
        self.assertEqual(out["trader"]["platform_account"]["handle"], "vlad.trades")
        self.assertEqual(self.node.accounts["vlad.trades"]["name"], "Vlad A")

    def test_each_round_publishes_the_ten_latest_posts_as_the_trader(self):
        self.add()
        posts = cmc_posts(12)
        self.ev.crawl = crawl_with(posts)
        self.ev.run_due()
        acc = self.node.accounts["daniel_crypto365"]
        self.assertEqual(self.platform.logins, [])  # through the gateway, not by signing in
        self.assertEqual(self.node.imports[0]["author"], acc["id"])
        mine = [p for p in self.node.posts.values() if p["author"] == acc["id"]]
        self.assertEqual(len(mine), 10)
        bodies = "\n".join(p["body"] for p in mine)
        self.assertNotIn("call number 0:", bodies)  # the two oldest are not among the latest ten
        self.assertNotIn("call number 1:", bodies)
        self.assertIn("call number 11:", bodies)
        self.assertIn("https://coinmarketcap.com/community/post/1011/", bodies)
        self.assertEqual(mine[0]["tags"], ["btc", "coinmarketcap"])
        self.assertEqual({i["source"] for i in self.node.imports[0]["posts"]}, {"coinmarketcap"})
        rec = self.ev.call("trader_get", {"handle": "daniel_crypto365"}, scope(space=""))
        self.assertEqual(rec["posts_sync"]["created"], 10)

        # Next round: a new post is published; the ones already there are left
        # exactly as they are, even one edited at the source.
        before = {k: dict(v) for k, v in self.node.posts.items()}
        posts[11]["text"] = "$BTC call number 11, edited: target hit"
        posts.append(cmc_posts(13)[12])
        self.ev.call("evaluate_now", {"handle": "daniel_crypto365"}, scope())
        self.ev.run_due()
        sync = self.ev.call("trader_get", {"handle": "daniel_crypto365"}, scope(space=""))["posts_sync"]
        self.assertEqual((sync["created"], sync["existing"]), (1, 9))
        for pid, p in before.items():
            self.assertEqual(self.node.posts[pid], p)
        self.assertFalse(any("edited: target hit" in p["body"] for p in self.node.posts.values()))
        stored = json.loads(self.node.kv["evaluator/trader/daniel_crypto365"])
        self.assertEqual(len(stored["platform_posts"]), 11)

    def test_a_new_post_carries_all_its_content_and_media(self):
        self.add()
        post = cmc_posts(1)[0]
        post.update({"rich_text": "Long $BTC, chart below @alice #macro (https://example.com/a)",
                     "media": [{"url": "https://s3.coinmarketcap.com/a.png", "kind": "image"},
                               {"url": "https://s3.coinmarketcap.com/b.mp4", "kind": "video"},
                               {"url": "https://s3.coinmarketcap.com/too-big.png", "kind": "image"}],
                     "link": {"url": "https://example.com/news", "title": "BTC ETF flows", "description": "Record week"},
                     "quote": {"author": "bob", "id": "77", "text": "BTC to 100k", "media": []},
                     "poll": ["Up", "Down"]})
        fetched = []

        def fetch(url, kind, proxy=""):
            fetched.append(url)
            if "too-big" in url:
                return None
            return {"name": url.rsplit("/", 1)[1], "mime": "video/mp4" if kind == "video" else "image/png",
                    "data": base64.b64encode(b"bytes").decode()}

        self.ev.fetch_media = fetch
        self.ev.crawl = crawl_with([post])
        self.ev.run_due()
        (published,) = self.node.posts.values()
        self.assertEqual(published["media"], ["a.png", "b.mp4"])
        body = published["body"]
        for part in ("Long $BTC, chart below @alice #macro (https://example.com/a)", "Poll:\n• Up\n• Down",
                     "BTC ETF flows", "https://example.com/news", "Quoting @bob:\n> BTC to 100k",
                     "https://coinmarketcap.com/community/post/77/",
                     "Media:\nhttps://s3.coinmarketcap.com/too-big.png", "Posted on CoinMarketCap"):
            self.assertIn(part, body)
        sync = self.ev.call("trader_get", {"handle": "daniel_crypto365"}, scope(space=""))["posts_sync"]
        self.assertEqual((sync["created"], sync["media"]), (1, 2))
        # A post already published is not downloaded or sent with media again.
        fetched.clear()
        self.ev.call("evaluate_now", {"handle": "daniel_crypto365"}, scope())
        self.ev.run_due()
        self.assertEqual(fetched, [])
        self.assertEqual(len(self.node.posts), 1)

    def test_a_long_post_fits_the_node_limit(self):
        from evaluator import platform as platform_mod
        post = cmc_posts(1)[0]
        post["text"] = "x" * 5000
        body = platform_mod.post_body(post)
        self.assertLessEqual(len(body), platform_mod.MAX_BODY)
        self.assertIn("Posted on CoinMarketCap", body)

    def test_without_the_admins_space_scope_posts_wait(self):
        self.add()
        self.ev.scopes.space_scope = Scope()
        self.ev.crawl = crawl_with(cmc_posts(3))
        self.ev.sync_platform_posts(json.loads(self.node.kv["evaluator/trader/daniel_crypto365"]), cmc_posts(3))
        self.assertEqual(self.node.posts, {})

    def test_a_trader_added_before_accounts_gets_one_on_evaluation(self):
        self.add()
        stored = json.loads(self.node.kv["evaluator/trader/daniel_crypto365"])
        stored.pop("account")
        self.node.kv["evaluator/trader/daniel_crypto365"] = json.dumps(stored)
        self.node.accounts.clear()
        self.ev.run_due()
        self.assertIn("daniel_crypto365", self.node.accounts)
        self.assertEqual(self.ev.call("trader_credentials", {"handle": "daniel_crypto365"}, scope())["username"], "daniel_crypto365")

    def test_removing_a_trader_deletes_their_posts_and_account(self):
        self.add()
        self.ev.crawl = crawl_with(cmc_posts(3))
        self.ev.run_due()
        self.assertEqual(len(self.node.posts), 3)
        out = self.ev.call("trader_remove", {"handle": "daniel_crypto365"}, scope())
        self.assertEqual((out["posts_deleted"], out["account_deleted"]), (3, "daniel_crypto365"))
        self.assertEqual((self.node.posts, self.node.accounts), ({}, {}))
        self.assertEqual(self.ev.call("leaderboard", {}, scope(space=""))["total"], 0)

    def test_removing_a_trader_can_keep_the_account(self):
        self.add()
        password = self.node.accounts["daniel_crypto365"]["password"]
        out = self.ev.call("trader_remove", {"handle": "daniel_crypto365", "keep_account": True}, scope())
        self.assertEqual(out["kept_account"]["password"], password)
        self.assertIn("daniel_crypto365", self.node.accounts)
        self.assertEqual(self.ev.call("leaderboard", {}, scope(space=""))["total"], 0)

    def test_usernames_from_cmc_handles(self):
        self.assertEqual(username_for("Daniel_Crypto365"), "daniel_crypto365")
        self.assertEqual(username_for("ab"), "ab_trader")
        self.assertEqual(username_for("_x.y-"), "x.y")
        self.assertEqual(username_for("_x-"), "x_trader")
        self.assertEqual(len(username_for("a" * 40)), 30)
        self.assertEqual(username_for("crypto king!"), "crypto_king")


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
        self.assertEqual(posts[0]["media"], [])
        self.assertEqual(posts[0]["symbols"], ["ETH", "SOL"])
        self.assertTrue(posts[0]["timestamp"].startswith("2025-09-01"))
        analyst = crawler.extract_analyst([payload], "abc")
        self.assertEqual((analyst["followers"], analyst["total_posts"]), (99, 12))

    def test_extract_a_posts_whole_content(self):
        payload = {"data": {"list": [{
            "gravityId": "9", "postTime": "1756728000000", "owner": {"handle": "abc"},
            "textContent": "Long BTC here, see chart and the news link",
            "originalContent": json.dumps([
                [{"type": "text", "content": "Long "}, {"type": "token", "content": {"symbol": "BTC"}},
                 {"type": "text", "content": " here, cc "}, {"type": "mention", "content": {"handle": "alice"}},
                 {"type": "text", "content": " "}, {"type": "hashtag", "content": "macro"}],
                [{"type": "link", "content": "the news", "url": "https://example.com/n"}],
                [{"type": "image", "content": {"url": "https://s3.coinmarketcap.com/inline.png"}}]]),
            "images": ["https://s3.coinmarketcap.com/chart.png", {"url": "https://s3.coinmarketcap.com/chart2.jpg"}],
            "video": {"videoUrl": "https://s3.coinmarketcap.com/clip.mp4"},
            "linkCard": {"url": "https://example.com/n", "title": "News"},
            "repostOriginal": {"gravityId": "5", "textContent": "BTC to 100k soon", "owner": {"handle": "bob"},
                               "images": ["https://s3.coinmarketcap.com/q.png"]},
            "poll": {"options": [{"text": "Up"}, {"text": "Down"}]},
        }]}}
        (post,) = [p for p in crawler.extract_posts([payload], "abc") if p["id"] == "9"]
        self.assertEqual(post["rich_text"], "Long $BTC here, cc @alice #macro\nthe news (https://example.com/n)")
        self.assertEqual([(m["url"].rsplit("/", 1)[1], m["kind"]) for m in post["media"]],
                         [("chart.png", "image"), ("chart2.jpg", "image"), ("clip.mp4", "video"), ("inline.png", "image")])
        self.assertEqual(post["link"]["title"], "News")
        self.assertEqual((post["quote"]["author"], post["quote"]["text"]), ("bob", "BTC to 100k soon"))
        self.assertEqual(post["quote"]["media"][0]["url"], "https://s3.coinmarketcap.com/q.png")
        self.assertEqual(post["poll"], ["Up", "Down"])

    def test_fetch_media(self):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from evaluator import platform as platform_mod

        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                kind, body = {"/a.png": ("image/png", b"png"), "/page": ("text/html", b"<html>"),
                              "/big.png": ("image/png", b"x" * 64)}[self.path]
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_port}"
        try:
            got = platform_mod.fetch_media(base + "/a.png", "image")
            self.assertEqual((got["name"], got["mime"], base64.b64decode(got["data"])), ("a.png", "image/png", b"png"))
            self.assertIsNone(platform_mod.fetch_media(base + "/page", "image"))  # not a medium
            limits = dict(platform_mod.MAX_MEDIA_BYTES)
            platform_mod.MAX_MEDIA_BYTES["image"] = 10
            try:
                self.assertIsNone(platform_mod.fetch_media(base + "/big.png", "image"))  # too large
            finally:
                platform_mod.MAX_MEDIA_BYTES.update(limits)
        finally:
            srv.shutdown()
            srv.server_close()

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
