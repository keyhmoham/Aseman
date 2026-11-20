#!/usr/bin/env python3
"""The whole stack once, in-process, with the real model and the real servers:
GLiNER2 reads Persian and English queries into frames, the gateway asks the
routed iran-mcp servers, and a chat turn runs the agentic loop (with a scripted
agent, so nothing is billed). The sites may be unreachable from where this runs
(many accept only Iranian addresses): that is reported per service and is not a
failure. What must hold is the reading and the plumbing.

    python scripts/smoke_engine.py
"""
import asyncio
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import httpx  # noqa: E402

from peyda.api import create_app  # noqa: E402
from peyda.extractor import HybridExtractor  # noqa: E402
from peyda.sessions import Store  # noqa: E402

CASES = [  # query, a domain it must be routed to, slots it must carry
    ("ارزان‌ترین گوشی سامسونگ زیر ۲۰ میلیون تومان", "shopping", {"price_max_toman": 20_000_000}),
    ("بلیط پرواز تهران به مشهد فردا", "travel_tickets", {"origin": None, "destination": None, "date": None}),
    ("دکتر پوست در اصفهان", "health", {"city": None}),
    ("cheapest pizza near Saadat Abad", "food", {}),
]


class Analyst:
    """Accepts every round and answers from the data it was given."""

    async def ask(self, prompt, history):
        if "TASK: review" in prompt:
            return json.dumps({"verdict": "satisfied", "reason": "smoke"})
        if "TASK: answer" in prompt:
            return json.dumps({"answer": "smoke answer", "picks": [], "suggestions": []})
        return json.dumps({"action": "search", "query": "x"})


async def main() -> int:
    extractor = HybridExtractor()
    extractor.start()
    t = time.time()
    while not extractor.gliner.ready:
        if extractor.gliner._error:
            print("FAIL the model did not load:", extractor.gliner._error)
            return 1
        if time.time() - t > 600:
            print("FAIL the model did not load in 10 minutes")
            return 1
        await asyncio.sleep(1)
    print(f"model ready in {time.time() - t:.0f}s: {extractor.status()['model']}")

    app = create_app(extractor=extractor, store=Store(":memory:"), agent_factory=lambda h: Analyst())
    failures = 0
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t", timeout=180) as client:
        for query, domain, slots in CASES:
            r = (await client.post("/api/search", json={"q": query})).json()
            frame = r["frame"]
            answered = [s["id"] for s in r["services"] if s["status"] == "ok"]
            states = ", ".join(f"{s['id']}={s['status']}" for s in r["services"])
            print(f"\n{query}\n  engine={frame['source']} domains={[d['name'] for d in frame['domains']]} slots={json.dumps(frame['slots'], ensure_ascii=False)}\n  {states or 'no service routed'}")
            ok = frame["source"] == "gliner2" and domain in [d["name"] for d in frame["domains"]] and r["services"]
            ok = ok and all(k in frame["slots"] and (v is None or frame["slots"][k] == v) for k, v in slots.items())
            if not ok:
                failures += 1
                print("  FAIL: not read as expected")
            elif answered:
                print(f"  answered by: {', '.join(answered)}")

        user = {"x-decillion-user": "smoke", "x-decillion-user-token": "t"}
        chat = (await client.post("/api/chats", headers=user)).json()
        run = (await client.post(f"/api/chats/{chat['id']}/messages", headers=user, json={"text": CASES[0][0]})).json()["run"]
        for _ in range(600):
            state = (await client.get(f"/api/runs/{run}", headers=user)).json()
            if state["status"] != "running":
                break
            await asyncio.sleep(0.5)
        if state["status"] != "done" or state["message"]["text"] != "smoke answer":
            failures += 1
            print("FAIL the chat turn did not finish:", state["status"], state.get("error"))
        else:
            print("\nchat turn: done,", len([e for e in state["events"] if e["type"] == "service"]), "service answers")
    print("\npeyda smoke:", "FAILED" if failures else "ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
