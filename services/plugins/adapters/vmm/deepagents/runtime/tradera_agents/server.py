"""The runtime's HTTP API, called only by the node's deepagents VMM adapter.

    GET  /healthz                     → {"ok": true}
    POST /v1/turns                    run a turn         → {reply, status, answered, error}
    POST /v1/answers                  answer a question  → {reply, status, answered, error}
    GET  /v1/questions?vm=&space=     open questions     → {questions: [...]}

Every request carries the runtime secret the node started the runtime with
(``X-Tradera-Runtime``). A turn's own access to the platform is the turn
token in its body, valid only while the node waits on that turn.
"""

from __future__ import annotations

import asyncio
import hmac
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from .agent import Outcome, Runner
from .store import Store

log = logging.getLogger("tradera.agents")


def create_app(runner_factory: Any = None, *, secret: str | None = None, data_dir: str | None = None) -> FastAPI:
    secret = secret if secret is not None else os.environ.get("TRADERA_RUNTIME_SECRET", "")
    data = Path(data_dir or os.environ.get("TRADERA_DATA_DIR", "/data"))

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        data.mkdir(parents=True, exist_ok=True)
        store = Store(str(data / "runtime.db"))
        if runner_factory is not None:
            app.state.runner = runner_factory(store)
            yield
            return
        from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

        from . import improve

        async with AsyncSqliteSaver.from_conn_string(str(data / "checkpoints.db")) as saver:
            app.state.runner = Runner(store, saver, improver=improve.from_env(data, secret))
            yield
            # Turns still being committed to OpenViking, and agents still
            # improving their playbook, finish first.
            await app.state.runner.recorder.drain()
            if app.state.runner.improver is not None:
                await app.state.runner.improver.drain()

    app = FastAPI(title="tradera deep agents runtime", lifespan=lifespan)

    def authorize(request: Request) -> None:
        given = request.headers.get("X-Tradera-Runtime", "")
        if secret and not hmac.compare_digest(given, secret):
            raise HTTPException(status_code=401, detail="bad runtime secret")

    @app.get("/healthz")
    async def healthz(request: Request) -> dict[str, Any]:
        authorize(request)
        return {"ok": True}

    async def serve(request: Request, run: Any) -> JSONResponse:
        authorize(request)
        body = await request.json()
        if not body.get("token") or not body.get("gateway"):
            raise HTTPException(status_code=400, detail="token and gateway are required")
        task = asyncio.create_task(run(body))
        # The node cancels a turn by dropping the request.
        while not task.done():
            done, _ = await asyncio.wait({task}, timeout=1.0)
            if not done and await request.is_disconnected():
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
                return JSONResponse(Outcome(reply="", status="cancelled").json())
        try:
            outcome: Outcome = task.result()
        except Exception as exc:  # noqa: BLE001
            log.exception("turn crashed")
            outcome = Outcome(reply="", status="failed", error=f"{type(exc).__name__}: {exc}")
        return JSONResponse(outcome.json())

    @app.post("/v1/turns")
    async def turns(request: Request) -> JSONResponse:
        return await serve(request, request.app.state.runner.prompt)

    @app.post("/v1/answers")
    async def answers(request: Request) -> JSONResponse:
        return await serve(request, request.app.state.runner.answer)

    @app.get("/v1/questions")
    async def questions(request: Request, vm: str = "", space: str = "") -> dict[str, Any]:
        authorize(request)
        return {"questions": request.app.state.runner.questions(vm, space)}

    @app.exception_handler(HTTPException)
    async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    return app


def main() -> None:
    import uvicorn

    logging.basicConfig(level=os.environ.get("TRADERA_LOG_LEVEL", "INFO"))
    port = int(os.environ.get("TRADERA_RUNTIME_PORT", "8000"))
    uvicorn.run(create_app(), host="0.0.0.0", port=port, log_level="info", timeout_keep_alive=75)
