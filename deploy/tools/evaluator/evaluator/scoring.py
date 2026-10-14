"""Turns the model's reply into the stored reliability report and its summary."""

from __future__ import annotations

import json
import re
from typing import Any

# The headline scores of the prompt's Final JSON (STEP 15), all 0-100.
SCORE_KEYS = ("overall_score", "technical_score", "fundamental_score", "historical_accuracy",
              "consistency", "risk_management", "timing", "confidence")

# The leaderboards the client can rank by, and the score each one ranks on.
BOARDS = {
    "overall": "overall_score", "technical": "technical_score", "fundamental": "fundamental_score",
    "accuracy": "historical_accuracy", "consistency": "consistency", "risk": "risk_management",
    "timing": "timing",
}


def rating(score: float | None) -> str:
    """STEP 13 — Analyst Rating."""
    if score is None:
        return "Unrated"
    if score >= 95:
        return "Elite Institutional"
    if score >= 90:
        return "Professional"
    if score >= 80:
        return "Advanced"
    if score >= 70:
        return "Intermediate"
    if score >= 60:
        return "Average"
    if score >= 40:
        return "Weak"
    return "Unreliable"


def extract_json(text: str) -> dict | None:
    """The report object in a reply: a fenced block, else the largest {...} that parses."""
    if not isinstance(text, str):
        return text if isinstance(text, dict) else None
    for block in re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S):
        try:
            value = json.loads(block)
            if isinstance(value, dict):
                return value
        except Exception:
            pass
    starts = [i for i, c in enumerate(text) if c == "{"]
    for start in starts:
        depth, in_str, esc = 0, False, False
        for j in range(start, len(text)):
            c = text[j]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
                continue
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        value = json.loads(text[start:j + 1])
                    except Exception:
                        break
                    if isinstance(value, dict) and any(k in value for k in SCORE_KEYS):
                        return value
                    break
    return None


def _num(v: Any) -> float | None:
    if isinstance(v, dict):  # {"score": 72, "confidence": 60}
        v = v.get("score", v.get("value"))
    if isinstance(v, str):
        m = re.search(r"-?\d+(\.\d+)?", v)
        v = float(m.group()) if m else None
    if isinstance(v, (int, float)):
        if 0 < v <= 1 and not float(v).is_integer():
            v = v * 100  # a fraction
        return round(max(0.0, min(100.0, float(v))), 1)
    return None


def normalize(report: dict) -> tuple[dict, dict]:
    """(the report with clamped headline scores, the summary the leaderboard ranks on)."""
    report = dict(report)
    summary: dict[str, Any] = {}
    for key in SCORE_KEYS:
        value = _num(report.get(key))
        if value is not None:
            report[key] = value
        summary[key] = value
    summary["rating"] = rating(summary.get("overall_score"))
    report.setdefault("analyst_rating", summary["rating"])
    for key in ("strengths", "weaknesses", "warnings"):
        items = report.get(key)
        report[key] = [str(i) for i in items][:12] if isinstance(items, list) else []
    return report, summary
