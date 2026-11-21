import asyncio

import httpx
import pytest

from peyda.api import create_app
from peyda.orchestrator import LoopConfig
from peyda.sessions import Store
from scripted import Scripted

ALICE = {"x-decillion-user": "alice", "x-decillion-user-token": "t-alice"}
BOB = {"x-decillion-user": "bob", "x-decillion-user-token": "t-bob"}


@pytest.fixture
async def client(gateway, lexicon):
    agent = Scripted(review={"verdict": "satisfied"}, answer={"answer": "Done.", "picks": ["shopa:0"], "suggestions": ["more?"]},
                     plan={"action": "search", "query": "samsung phone"})
    app = create_app(extractor=lexicon, gateway=gateway, store=Store(":memory:"), agent_factory=lambda headers: agent, bundle=None)
    app.state.agent = agent
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        c.agent = agent
        yield c


async def finish(client, run_id, headers):
    for _ in range(200):
        r = (await client.get(f"/api/runs/{run_id}", headers=headers)).json()
        if r["status"] != "running":
            return r
        await asyncio.sleep(0.05)
    raise AssertionError("the run did not finish")


async def test_health_and_info_are_open(client):
    assert (await client.get("/healthz")).json()["extractor"]["engine"] == "lexicon"
    info = (await client.get("/api/info")).json()
    assert info["signed_in"] is False and info["services"] == 11


async def test_a_visitor_can_search_without_signing_in(client):
    r = (await client.post("/api/search", json={"q": "cheap samsung phone"})).json()
    assert r["total"] >= 2 and r["frame"]["domains"][0]["name"] == "shopping"
    assert {s["id"] for s in r["services"]} >= {"shopa", "shopb"}
    assert client.agent.calls == []                          # no agent, nothing billed


async def test_the_chat_needs_a_signed_in_person(client):
    assert (await client.get("/api/chats")).status_code == 401
    assert (await client.post("/api/chats")).json()["error"] == "Sign in to chat with Peyda"


async def test_a_conversation_continues_with_its_history(client):
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    first = await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "cheap samsung phone"})
    assert first.status_code == 202
    done = await finish(client, first.json()["run"], ALICE)
    assert done["status"] == "done" and done["message"]["text"] == "Done." and done["message"]["payload"]["cards"][0]["ref"] == "shopa:0"
    assert [e["type"] for e in done["events"]][-1] == "done"

    second = await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "and cheaper?"})
    await finish(client, second.json()["run"], ALICE)
    plan = next(c for c in client.agent.calls if c[0] == "plan")
    assert [m["content"] for m in plan[2]] == ["cheap samsung phone", "Done."]        # the first exchange, as history
    assert plan[1]["earlier_searches"][0]["query"] == "cheap samsung phone"           # and its structured memory

    full = (await client.get(f"/api/chats/{chat['id']}", headers=ALICE)).json()
    assert [m["role"] for m in full["messages"]] == ["user", "assistant", "user", "assistant"]
    assert full["title"] == "cheap samsung phone"
    assert (await client.get("/api/chats", headers=ALICE)).json()["chats"][0]["id"] == chat["id"]


async def test_one_person_never_sees_anothers_chat_or_run(client):
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "samsung phone"})).json()["run"]
    assert (await client.get(f"/api/chats/{chat['id']}", headers=BOB)).status_code == 404
    assert (await client.post(f"/api/chats/{chat['id']}/messages", headers=BOB, json={"text": "hi"})).status_code == 404
    assert (await client.get(f"/api/runs/{run}", headers=BOB)).status_code == 404
    assert (await client.get("/api/chats", headers=BOB)).json()["chats"] == []
    await finish(client, run, ALICE)
    assert (await client.delete(f"/api/chats/{chat['id']}", headers=BOB)).status_code == 404
    assert (await client.delete(f"/api/chats/{chat['id']}", headers=ALICE)).status_code == 200


async def test_polling_returns_only_new_events(client):
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "samsung phone"})).json()["run"]
    done = await finish(client, run, ALICE)
    tail = (await client.get(f"/api/runs/{run}", params={"after": done["next"] - 1}, headers=ALICE)).json()
    assert [e["type"] for e in tail["events"]] == ["done"]


async def test_a_failing_turn_ends_with_a_human_error(client, monkeypatch):
    import peyda.orchestrator as o

    async def boom(*a, **k):
        raise RuntimeError("secret internals")

    monkeypatch.setattr(o.Orchestrator, "turn", boom)
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "x"})).json()["run"]
    done = await finish(client, run, ALICE)
    assert done["status"] == "error" and "secret" not in done["error"] and done["error"].startswith("Something went wrong")


async def test_a_second_message_waits_for_the_first(client):
    gate = asyncio.Event()

    async def slow(prompt, history):
        await gate.wait()
        return '{"verdict": "satisfied", "answer": "ok"}'

    client.agent.ask = slow
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "samsung phone"})).json()["run"]
    await asyncio.sleep(0.5)
    assert (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "again"})).status_code == 409
    assert (await client.post(f"/api/runs/{run}/cancel", headers=ALICE)).json() == {"ok": True}
    gate.set()
    assert (await finish(client, run, ALICE))["status"] == "cancelled"


async def test_the_bundle_route_is_honest_when_unbuilt(client):
    assert (await client.get("/elpian/app.js")).status_code in (200, 503)
    assert (await client.get("/")).status_code == 200


async def test_a_held_poll_returns_when_something_happens(client):
    gate = asyncio.Event()

    async def slow(prompt, history):
        await gate.wait()
        return '{"verdict": "satisfied", "answer": "ok"}'

    client.agent.ask = slow
    chat = (await client.post("/api/chats", headers=ALICE)).json()
    run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=ALICE, json={"text": "samsung phone"})).json()["run"]
    for _ in range(100):  # until the run is parked on the agent's review
        first = (await client.get(f"/api/runs/{run}", headers=ALICE)).json()
        if any(e["type"] == "stage" and e["name"] == "review" for e in first["events"]):
            break
        await asyncio.sleep(0.05)
    held = asyncio.create_task(client.get(f"/api/runs/{run}", params={"after": first["next"], "wait": 10}, headers=ALICE))
    await asyncio.sleep(0.4)
    assert not held.done()                       # nothing new yet: the request is held
    gate.set()
    got = (await held).json()
    assert got["events"] and got["next"] > first["next"]


def test_the_sdk_is_found_where_the_computer_installs_it(tmp_path, monkeypatch):
    import sys
    from peyda import agent
    (tmp_path / "decillion_server.py").write_text("class Decillion:\n    marker = 'found'\n")
    monkeypatch.setattr(sys, "path", list(sys.path))  # the lookup adds the SDK's folder; undo that afterwards
    monkeypatch.setenv("DECILLION_SDK_DIR", str(tmp_path))
    monkeypatch.setattr(agent, "ROOT", tmp_path / "app")  # an app built by appui_create has its own vendor/decillion-sdk, which would win
    monkeypatch.delitem(sys.modules, "decillion_server", raising=False)
    assert agent._decillion_class().marker == "found"
    sys.modules.pop("decillion_server", None)


def test_a_wrong_app_api_url_from_the_node_is_corrected():
    from peyda.agent import normalize_api_url
    assert normalize_api_url("http://decillion:8080/deepagents/v1/llm/appapi/v1") == "http://decillion:8080/appapi/v1"
    assert normalize_api_url("https://node.example.com/harness/v1/llm/appapi/v1/") == "https://node.example.com/appapi/v1"
    assert normalize_api_url("http://decillion:8080/appapi/v1") == "http://decillion:8080/appapi/v1"
    assert normalize_api_url("https://api.example.com/custom") == "https://api.example.com/custom"  # not ours: left alone
    assert normalize_api_url("") == ""


def test_a_configured_node_url_replaces_the_one_the_node_hands_out(monkeypatch):
    from peyda.agent import normalize_api_url
    monkeypatch.setenv("PEYDA_NODE_URL", "https://node.example.com/")
    assert normalize_api_url("http://decillion:8080/appapi/v1") == "https://node.example.com/appapi/v1"
    assert normalize_api_url("") == "https://node.example.com/appapi/v1"
    monkeypatch.setenv("PEYDA_NODE_URL", "")  # unset: the node's own address is used
    assert normalize_api_url("http://decillion:8080/appapi/v1") == "http://decillion:8080/appapi/v1"


def test_calls_to_the_node_carry_a_real_user_agent(monkeypatch):
    """Cloudflare refuses urllib's default User-Agent (error 1010), which the SDK reports as a bare Forbidden."""
    import threading, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from peyda import agent
    seen = []

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.headers.get("User-Agent"))
            self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
        def log_message(self, *a): pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    monkeypatch.setattr(urllib.request, "_opener", None)  # undo the process-wide opener afterwards
    monkeypatch.setattr(agent, "_identified", False)
    try:
        agent.identify_to_the_node()
        urllib.request.urlopen(f"http://127.0.0.1:{srv.server_port}/", timeout=10).read()
    finally:
        srv.shutdown()
    assert seen == [agent.USER_AGENT] and not seen[0].startswith("Python-urllib")


def test_the_analyst_calls_the_corrected_url(tmp_path, monkeypatch):
    import sys
    from peyda import agent
    (tmp_path / "decillion_server.py").write_text(
        "class Decillion:\n"
        "    seen = None\n"
        "    @classmethod\n"
        "    def from_headers(cls, headers):\n"
        "        cls.seen = dict(headers); return cls()\n"
    )
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setenv("DECILLION_SDK_DIR", str(tmp_path))
    monkeypatch.setattr(agent, "ROOT", tmp_path / "app")  # an app built by appui_create has its own vendor/decillion-sdk, which would win
    monkeypatch.delitem(sys.modules, "decillion_server", raising=False)
    agent.DecillionAnalyst({"X-Decillion-Api": "http://decillion:8080/deepagents/v1/llm/appapi/v1", "X-Decillion-User-Token": "t"})
    import decillion_server
    assert decillion_server.Decillion.seen["x-decillion-api"] == "http://decillion:8080/appapi/v1"
    assert decillion_server.Decillion.seen["x-decillion-user-token"] == "t"
    sys.modules.pop("decillion_server", None)
