"""Rules helpers for Persian Rails Empire's platform server.
Pure functions shared by the server and tests.
"""

import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(HERE, "data", "map")

AI_RATING = {1: 900, 2: 1200, 3: 1500}
START_RATING = 1200
K_FACTOR = 32

SAFE_NAME = re.compile(r"^[\w\u0600-\u06FF\s\-_.]{1,40}$")


def load_json(name):
    import json
    with open(os.path.join(MAP, name), encoding="utf-8") as f:
        return json.load(f)


def elo(r_a, r_b, score_a, k=K_FACTOR):
    """score_a: 1 win, 0.5 draw, 0 loss."""
    exp = 1.0 / (1.0 + 10 ** ((r_b - r_a) / 400.0))
    return round(r_a + k * (score_a - exp))


def outcome_score(outcome):
    return {"win": 1.0, "draw": 0.5, "loss": 0.0}.get(outcome, 0.0)


def believable_result(body, level, elapsed_s):
    """Lightweight anti-cheat: outcome, scores, duration bounds."""
    if not isinstance(body, dict):
        return False, "bad body"
    outcome = body.get("outcome")
    if outcome not in ("win", "loss", "draw"):
        return False, "bad outcome"
    if int(body.get("level", level)) != int(level):
        return False, "level mismatch"
    score = body.get("score")
    ai_score = body.get("ai_score")
    if not isinstance(score, int) or not isinstance(ai_score, int):
        return False, "scores"
    if score < -80 or score > 250 or ai_score < -80 or ai_score > 250:
        return False, "score bounds"
    if outcome == "win" and score < ai_score:
        return False, "win without higher score"
    if outcome == "loss" and score > ai_score:
        return False, "loss with higher score"
    claimed = 0
    if isinstance(body.get("duration_s"), (int, float)):
        claimed = float(body["duration_s"])
    wall = float(elapsed_s or 0)
    if max(wall, claimed) < 15 and outcome == "win":
        return False, "too fast"
    moves = body.get("moves")
    if isinstance(moves, int) and moves < 3 and outcome != "draw":
        return False, "too few moves"
    return True, "ok"


def xp_for_result(outcome, level):
    base = {"win": 40, "draw": 18, "loss": 10}.get(outcome, 10)
    return base * int(level)


def level_from_xp(xp):
    # soft curve
    lvl = 1
    need = 50
    left = xp
    while left >= need and lvl < 50:
        left -= need
        lvl += 1
        need = int(need * 1.25)
    return {"level": lvl, "into": left, "span": need}


def sanitize_name(name, fallback="بازیکن"):
    name = (name or "").strip() or fallback
    if not SAFE_NAME.match(name):
        return fallback
    return name[:40]
