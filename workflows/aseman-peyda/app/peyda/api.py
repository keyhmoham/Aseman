"""Peyda's HTTP surface: the search page, the chat, and the Elpian bundle.

Signed-out visitors can search (no agent, nothing billed). The agentic chat
needs a signed-in person: their token is what reaches the Peyda Analyst.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from pathlib import Path
from typing import Any, Callable, Mapping

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from .agent import DecillionAnalyst, signed_in
from .catalog import Catalog
from .extractor import make_extractor
from .gateway import Gateway
from .orchestrator import AgentPort, Cancelled, Orchestrator, Run
from .sessions import Store

log = logging.getLogger("peyda.api")
ROOT = Path(__file__).resolve().parent.parent

AgentFactory = Callable[[Mapping[str, str]], AgentPort]


class SearchBody(BaseModel):
    q: str = Field(min_length=1, max_length=400)
    limit: int = Field(default=6, ge=1, le=20)
    domains: list[str] | None = None


class MessageBody(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class ChatBody(BaseModel):
    title: str = ""


def create_app(
    *,
    extractor: Any = None,
    gateway: Gateway | None = None,
    store: Store | None = None,
    agent_factory: AgentFactory | None = None,
    bundle: Path | None = None,
) -> FastAPI:
    app = FastAPI(title="Peyda", docs_url=None, redoc_url=None)
    extractor = extractor or make_extractor()
    catalog = gateway.catalog if gateway else Catalog.load()
    gateway = gateway or Gateway(catalog)
    store = store or Store(os.environ.get("PEYDA_DB", str(ROOT / "data" / "peyda.sqlite3")))
    orchestrator = Orchestrator(extractor, gateway)
    make_agent: AgentFactory = agent_factory or (lambda headers: DecillionAnalyst(headers))
    runs: dict[str, Run] = {}
    tasks: set[asyncio.Task] = set()
    started = time.time()

    def lower(request: Request) -> dict[str, str]:
        return {k.lower(): v for k, v in request.headers.items()}

    def person(request: Request) -> str:
        h = lower(request)
        if not signed_in(h):
            raise HTTPException(401, "Sign in to chat with Peyda")
        return h["x-decillion-user"]

    def prune() -> None:
        for rid in [r for r, run in runs.items() if run.status != "running" and time.time() - run.created > 3600]:
            runs.pop(rid, None)

    # The Decillion SDKs read an error's text from `error`.
    @app.exception_handler(HTTPException)
    async def _http_error(_: Request, exc: HTTPException) -> JSONResponse:
        return JSONResponse({"error": str(exc.detail)}, status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def _bad_request(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse({"error": "That request was not valid."}, status_code=422)

    @app.on_event("shutdown")
    async def _shutdown() -> None:
        await gateway.close()

    # -- health and facts -------------------------------------------------
    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"ok": True, "uptime": int(time.time() - started), "extractor": extractor.status(), "gateway": gateway.status()}

    @app.get("/api/info")
    async def info(request: Request) -> dict[str, Any]:
        h = lower(request)
        return {
            "platform": h.get("x-decillion-platform-name") or "Peyda",
            "signed_in": signed_in(h),
            "services": len(catalog.services),
            "sites": [s["title"] for s in catalog.describe()][:12],
            "extractor": extractor.status(),
            "max_rounds": orchestrator.cfg.max_rounds,
        }

    # -- plain search ------------------------------------------------------
    @app.post("/api/search")
    async def search(body: SearchBody) -> dict[str, Any]:
        result = await orchestrator.search(body.q, limit=body.limit, domains=body.domains)
        return result.to_dict()

    # -- chats ------------------------------------------------------------
    @app.get("/api/chats")
    async def chats(request: Request) -> dict[str, Any]:
        return {"chats": store.list_chats(person(request))}

    @app.post("/api/chats")
    async def new_chat(request: Request, body: ChatBody | None = None) -> dict[str, Any]:
        return store.create_chat(person(request), (body.title if body else ""))

    @app.get("/api/chats/{chat_id}")
    async def chat(request: Request, chat_id: str) -> dict[str, Any]:
        user = person(request)
        c = store.get_chat(user, chat_id)
        if c is None:
            raise HTTPException(404, "No such chat")
        return {**{k: v for k, v in c.items() if k != "memory"}, "messages": store.messages(user, chat_id)}

    @app.delete("/api/chats/{chat_id}")
    async def delete_chat(request: Request, chat_id: str) -> dict[str, Any]:
        if not store.delete_chat(person(request), chat_id):
            raise HTTPException(404, "No such chat")
        return {"ok": True}

    @app.post("/api/chats/{chat_id}/messages")
    async def send(request: Request, chat_id: str, body: MessageBody) -> JSONResponse:
        user = person(request)
        c = store.get_chat(user, chat_id)
        if c is None:
            raise HTTPException(404, "No such chat")
        if any(r.chat_id == chat_id and r.status == "running" for r in runs.values()):
            raise HTTPException(409, "Peyda is still answering the last message")
        history = store.history(user, chat_id)
        user_msg = store.add_message(user, chat_id, "user", body.text.strip())
        if c["title"] == "New chat":
            store.rename(user, chat_id, body.text.strip())
        run = Run(chat_id=chat_id, user=user)
        runs[run.id] = run
        prune()
        agent = make_agent(lower(request))
        task = asyncio.create_task(_drive(run, user, chat_id, body.text.strip(), history, c["memory"], agent))
        tasks.add(task)  # a task nobody holds can be collected mid-turn
        task.add_done_callback(tasks.discard)
        return JSONResponse({"run": run.id, "message": user_msg}, status_code=202)

    async def _drive(run: Run, user: str, chat_id: str, text: str, history: list[dict[str, str]],
                     memory: list[dict[str, Any]], agent: AgentPort) -> None:
        try:
            out = await asyncio.wait_for(orchestrator.turn(run, text, history, memory, agent), orchestrator.cfg.turn_timeout)
            state = out.pop("state", None)
            payload = {k: out[k] for k in ("cards", "suggestions", "rounds", "degraded", "degraded_reason") if k in out}
            run.message = store.add_message(user, chat_id, "assistant", out["text"], payload)
            if state:
                store.remember(user, chat_id, state)
            run.status = "done"
            run.emit("done")
        except Cancelled:
            run.status = "cancelled"
            run.emit("cancelled")
        except asyncio.TimeoutError:
            run.status, run.error = "error", "Peyda took too long to answer. Try a narrower question."
            run.emit("error", error=run.error)
        except Exception as e:  # noqa: BLE001 - the page shows a human message, the log has the rest
            log.exception("turn failed")
            run.status, run.error = "error", "Something went wrong while answering. Please try again."
            run.emit("error", error=run.error, detail=f"{type(e).__name__}: {e}"[:200])

    @app.get("/api/runs/{run_id}")
    async def poll(request: Request, run_id: str, after: int = 0, wait: float = 0) -> dict[str, Any]:
        """The run's events after `after`. With `wait` (seconds, at most 25) the
        request is held until there is something new or the run ends, so the
        page follows a turn live without a timer (Elpian timers tick at 5 s)."""
        user = person(request)
        run = runs.get(run_id)
        if run is None or run.user != user:
            raise HTTPException(404, "No such run")
        after = max(0, after)
        deadline = time.monotonic() + min(max(wait, 0.0), 25.0)
        while run.status == "running" and len(run.events) <= after and time.monotonic() < deadline:
            await asyncio.sleep(0.1)
        return run.view(after)

    @app.post("/api/runs/{run_id}/cancel")
    async def cancel(request: Request, run_id: str) -> dict[str, Any]:
        user = person(request)
        run = runs.get(run_id)
        if run is None or run.user != user:
            raise HTTPException(404, "No such run")
        run.cancelled = True
        return {"ok": True}

    # -- the app ---------------------------------------------------------
    @app.get("/elpian/app.js")
    async def elpian_bundle() -> FileResponse:
        path = bundle or ROOT / "elpian" / "app.js"
        if not path.exists():
            raise HTTPException(503, "The frontend is not built yet")
        return FileResponse(path, media_type="application/javascript", headers={"Cache-Control": "no-cache"})

    @app.get("/", response_class=HTMLResponse)
    async def home() -> str:
        return "<!doctype html><meta charset=utf-8><title>Peyda</title><p>Peyda runs inside the Decillion client.</p>"

    return app
