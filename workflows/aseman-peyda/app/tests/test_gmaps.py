"""Google Maps: the kit's engine client, the MCP server in front of it, and the
service in plain and agentic search. A fake engine (the kit's job API, on a
local port) stands in for the kit and Google."""
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest

from peyda.api import create_app
from peyda.catalog import Catalog
from peyda.gateway import Gateway, default_launcher, module_params
from peyda.gmaps import Engine, EngineError, keyword_for, place
from peyda.sessions import Store
from scripted import Scripted

ROWS = [
    {"title": "کافه لمیز", "link": "https://www.google.com/maps/search/?api=1&query=Lamiz&query_place_id=ChIJ1",
     "category": "کافه", "address": "تهران، خیابان ولیعصر", "phone": "021 2222 3333", "website": "https://lamiz.example",
     "review_rating": "4.6", "review_count": "1,204", "latitude": "35.7575", "longitude": "51.4105", "place_id": "ChIJ1",
     "thumbnail": "", "status": ""},
    {"title": "Cafe Ritual", "link": "https://www.google.com/maps/place/Ritual", "category": "Coffee shop",
     "address": "Tehran", "phone": "", "website": "", "review_rating": "", "review_count": "", "latitude": "", "longitude": ""},
]


class FakeEngine(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, rows=ROWS, finish_after=2, fail=""):
        self.rows, self.finish_after, self.fail = rows, finish_after, fail
        self.jobs, self.posted, self.deleted, self.polls = {}, [], [], 0
        super().__init__(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        s = self.server
        if self.path == "/api/v1/jobs":
            return self.reply(200, None)
        parts = self.path.split("?")[0].strip("/").split("/")
        jid = parts[3] if len(parts) > 3 else ""
        if jid not in s.jobs:
            return self.reply(404, {"message": "job not found"})
        if len(parts) == 5 and parts[4] == "download":
            return self.reply(200, s.rows)
        s.polls += 1
        status = "failed" if s.fail else ("ok" if s.polls >= s.finish_after else "working")
        return self.reply(200, {"ID": jid, "Status": status, "Error": s.fail})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.posted.append(body)
        jid = f"job{len(self.server.posted)}"
        self.server.jobs[jid] = body
        self.reply(201, {"id": jid})

    def do_DELETE(self):
        self.server.deleted.append(self.path.rsplit("/", 1)[-1])
        self.reply(200, {"message": "deleted"})


@pytest.fixture
def engine():
    srv = FakeEngine()
    yield srv
    srv.shutdown()


# -- the client -----------------------------------------------------------

def test_a_search_is_one_job_polled_downloaded_and_deleted(engine):
    rows = Engine(engine.url, proxy="http://u:p@proxy.example:3128").search("کافه تهران", max_seconds=20, poll=0.01)
    assert [r["title"] for r in rows] == ["کافه لمیز", "Cafe Ritual"]
    (job,) = engine.posted
    assert job["keywords"] == ["کافه تهران"] and job["lang"] == "fa" and job["country"] == "ir"
    assert job["email"] is False and job["max_time"] == 20 and job["proxies"] == ["http://u:p@proxy.example:3128"]
    assert engine.deleted == ["job1"]


def test_at_the_deadline_the_rows_so_far_are_kept_and_the_job_dropped():
    srv = FakeEngine(finish_after=10**9)
    try:
        rows = Engine(srv.url).search("cafe in Tehran", max_seconds=0, poll=0.05)  # never finishes
        assert len(rows) == 2 and srv.posted[0]["lang"] == "en" and srv.deleted == ["job1"]
    finally:
        srv.shutdown()


def test_a_failed_search_with_no_rows_is_an_error():
    srv = FakeEngine(rows=[], fail="Google refused the keyword")
    try:
        with pytest.raises(EngineError, match="Google refused"):
            Engine(srv.url).search("x", max_seconds=5, poll=0.01)
    finally:
        srv.shutdown()


def test_an_engine_that_is_neither_running_nor_installed_says_so(tmp_path):
    with pytest.raises(EngineError, match="not installed"):
        Engine("http://127.0.0.1:9", kit_dir=str(tmp_path)).ensure()


def test_a_row_becomes_a_compact_place():
    p = place(ROWS[0])
    assert p["title"] == "کافه لمیز" and p["url"].startswith("https://www.google.com/maps/")
    assert p["subtitle"] == "کافه" and p["description"] == "★ 4.6 (1,204) · 021 2222 3333"
    assert p["rating"] == 4.6 and p["reviews"] == 1204 and p["lat"] == 35.7575 and "image" not in p
    assert place(ROWS[1]) == {"title": "Cafe Ritual", "url": "https://www.google.com/maps/place/Ritual",
                              "subtitle": "Coffee shop", "address": "Tehran"}


def test_the_city_is_added_only_when_the_query_lacks_it():
    assert keyword_for("کافه", "تهران") == "کافه تهران"
    assert keyword_for("کافه در تهران", "تهران") == "کافه در تهران"
    assert keyword_for("dentist", "") == "dentist"


# -- the catalog ----------------------------------------------------------

def test_google_maps_is_in_the_shipped_catalog_and_can_be_switched_off(monkeypatch):
    s = Catalog.load().services["gmaps"]
    assert s.module == "peyda.gmaps_mcp" and s.timeout == 60 and "maps" in s.domains and "food" in s.domains
    assert module_params(s).args == ["-m", "peyda.gmaps_mcp"]
    monkeypatch.setenv("PEYDA_GMAPS", "0")
    cat = Catalog.load()
    assert "gmaps" not in cat.services and "gmaps" not in [i for lead in cat.lead.values() for i in lead if i in cat.services]


def test_a_module_server_gets_its_settings_and_not_the_rest_of_the_environment(monkeypatch):
    s = Catalog.load().services["gmaps"]
    p = module_params(s, {"PEYDA_GMAPS_URL": "http://127.0.0.1:1", "HTTPS_PROXY": "http://p:3128", "SECRET_TOKEN": "x"})
    assert p.env["PEYDA_GMAPS_URL"] == "http://127.0.0.1:1" and p.env["HTTPS_PROXY"] == "http://p:3128"
    assert "SECRET_TOKEN" not in p.env and p.env["PYTHONPATH"]


# -- the service, end to end: the real MCP server over stdio ---------------

def gmaps_catalog() -> Catalog:
    full = Catalog.load()
    return Catalog([full.services["gmaps"]], {"maps": ["gmaps"]})


@pytest.fixture
async def gm_gateway(engine, monkeypatch):
    monkeypatch.setenv("PEYDA_GMAPS_URL", engine.url)
    monkeypatch.setenv("PEYDA_DEFAULT_CITY", "تهران")
    gw = Gateway(gmaps_catalog(), default_launcher(), tool_timeout=20, startup_timeout=60, idle_seconds=60)
    yield gw
    await gw.close()


@pytest.fixture
async def gm_client(gm_gateway, lexicon):
    agent = Scripted(review={"verdict": "satisfied", "reason": "good"},
                     answer=lambda d: {"answer": "Lamiz is rated 4.6.", "picks": [d["results"]["services"][0]["hits"][0]["ref"]]},
                     plan={"action": "search", "query": "کافه"})
    app = create_app(extractor=lexicon, gateway=gm_gateway, store=Store(":memory:"), agent_factory=lambda h: agent)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t", timeout=60) as c:
        c.agent = agent
        yield c


async def test_plain_search_asks_google_maps_through_its_mcp_server(gm_client, engine):
    r = (await gm_client.post("/api/search", json={"q": "کافه"})).json()
    (svc,) = r["services"]
    assert svc["id"] == "gmaps" and svc["status"] == "ok" and svc["tool"] == "gm_search"
    assert svc["args"]["query"] == "کافه" and svc["hits"][0]["title"] == "کافه لمیز"
    assert "021 2222 3333" in svc["hits"][0]["detail"] and svc["hits"][0]["url"].startswith("https://www.google.com/maps/")
    assert engine.posted[0]["keywords"] == ["کافه تهران"]  # no city named: the default city
    assert gm_client.agent.calls == []


async def test_the_agentic_loop_reviews_and_answers_from_google_maps(gm_client):
    user = {"x-decillion-user": "alice", "x-decillion-user-token": "t"}
    chat = (await gm_client.post("/api/chats", headers=user)).json()
    run = (await gm_client.post(f"/api/chats/{chat['id']}/messages", headers=user, json={"text": "کافه خوب"})).json()["run"]
    for _ in range(400):
        state = (await gm_client.get(f"/api/runs/{run}", headers=user)).json()
        if state["status"] != "running":
            break
        await asyncio.sleep(0.05)
    assert state["status"] == "done" and state["message"]["text"] == "Lamiz is rated 4.6."
    assert state["message"]["payload"]["cards"][0]["source"] == "Google Maps"
    review = next(d for t, d, _ in gm_client.agent.calls if t == "review")
    assert review["results"]["services"][0]["id"] == "gmaps" and review["results"]["services"][0]["hits"][0]["title"] == "کافه لمیز"
    assert any(e["type"] == "service" and e["id"] == "gmaps" and e["status"] == "ok" for e in state["events"])


async def test_an_unreachable_engine_is_one_service_error_not_a_failed_search(monkeypatch, lexicon, tmp_path):
    monkeypatch.setenv("PEYDA_GMAPS_URL", "http://127.0.0.1:9")
    monkeypatch.setenv("PEYDA_GMAPS_KIT", str(tmp_path))
    gw = Gateway(gmaps_catalog(), default_launcher(), tool_timeout=20, startup_timeout=60, idle_seconds=60)
    try:
        result = await gw.search(lexicon.extract("کافه در تهران"))
        (run,) = result.runs
        assert run.status == "error"
    finally:
        await gw.close()
