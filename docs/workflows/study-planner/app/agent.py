"""Asks the Planner agent — the custom agent the workflow made in the
product's Aseman space — for a student's plan.

The app does not decide the plan: it hands the agent a brief (the student,
the free slots it may use, the evidence it may cite and the answer's shape),
holds the answer to the rules (planner.check), and when the answer breaks
one, sends the agent the list of what is wrong and asks again. The agent is
reached through the developer API's platform door:
POST {ASEMAN_DEVELOPER_API_URL}/platform/spaces/ask, as the key's person.
"""

import json
import re
import urllib.error
import urllib.request

import planner

ANSWER_SHAPE = {
    "summary": "پیام مشاور به دانش‌آموز: ۳ تا ۶ جمله‌ی فارسی، گرم و مشخص، درباره‌ی منطق برنامه",
    "rest_day": "sat | sun | mon | tue | wed | thu | fri | null",
    "weeks": [{
        "week": 1,
        "sessions": [{"slot": "<a slot id from slots>", "course_id": "<a course id>", "type": "learn | practice | review | weekly_review | timed_test",
                      "topic": "اختیاری: چه کاری در این جلسه (مثلاً «حل مسئله‌های فصل ۲»)", "note": "اختیاری"}],
        "resting": ["<course ids with no session this week, only when the slots are too few>"],
    }],
    "advice": [{"title": "عنوان کوتاه", "body": "مشاوره‌ی شخصی فارسی", "tips": ["گام عملی"], "refs": ["<ids from refs only>"]}],
}

RULES = [
    "Use only slot ids from `slots`; each slot at most once. You may leave slots empty — fewer, better sessions beat a full grid.",
    "Use only course ids from `student.courses`; types learn, practice, review for a course; weekly_review and timed_test are special sessions with no course.",
    "Every course needs at least one session in some week; when the slots are too few, list the courses that rest in a week's `resting` and rotate them across weeks.",
    "A day may not hold more minutes than `settings.daily_cap`; slots already respect bedtime (`settings.latest_end`) and the session length.",
    "If `settings.rest_day` is true, choose a `rest_day` and put nothing on that day.",
    "Spread each course over days apart (spaced practice); alternate courses within a day (interleaving); never the same course twice in a row.",
    "Order a course's sessions in a week: learn first, then practice (retrieval, self-testing), then review; give practice about `settings.practice_share` and review about `settings.review_share` of a course's sessions.",
    "Give starred (`weak: true`) and exam (`exam: true`) courses more time, as the goals ask; heavy courses earlier in a day, light ones later.",
    "If `settings.starter` is true, each day starts with a short, easy session. If `settings.weekly_review` / `settings.timed_tests` are true, add one weekly_review / timed_test session a week.",
    "One week is enough when the same week repeats; give more weeks only when they differ (rotation, a rising share of practice before exams). At most `student.weeks` weeks.",
    "Advice: 3 to 6 cards in Persian, personal to this student's goals and concerns, practical steps a teenager can follow. Cite only ids from `refs`; never invent a study or a statistic. Do not diagnose; for distress, point to the school counselor.",
    "Answer with the JSON object only, in one ```json block.",
]


class AgentError(Exception):
    pass


def brief(ctx, problems=None, previous=None):
    a, s = ctx["answers"], ctx["settings"]
    data = {
        "task": "study_plan",
        "student": {
            "name": a["name"] or None,
            "grade": a["grade"], "grade_name": ctx["grade_name"], "field": ctx["field_name"],
            "courses": [{k: c[k] for k in ("id", "name", "weight", "category", "exam", "weak")} for c in a["courses"]],
            "goals": [{"id": g["id"], "title": g["title"], "desc": g["desc"]} for g in a["goals"]],
            "goal_note": a["goal_note"] or None,
            "concerns": [{"id": c["id"], "title": c["title"], "evidence": c["why"], "proven_tips": c["tips"]} for c in a["concerns"]],
            "concern_note": a["concern_note"] or None,
            "weeks": a["weeks"], "start_date": a["start"].isoformat(),
        },
        "settings": dict((k, v) for k, v in s.items() if k not in ("exam_boost", "weak_boost")),
        "slots": ctx["slots"],
        "refs": {k: v["text"] for k, v in ctx["refs"].items()},
        "answer_shape": ANSWER_SHAPE,
        "rules": RULES,
    }
    data["settings"]["latest_end"] = planner.hm(s["latest_end"])
    head = ("You are asked by the study-planner app for a student's weekly study plan and counsel. "
            "Read the brief, plan, check your plan against the rules, and answer with JSON only.\n")
    if problems:
        head = ("Your previous plan broke these rules; fix them and answer with the whole corrected JSON object only.\n- "
                + "\n- ".join(problems[:40]) + "\n\nYour previous answer:\n```json\n" + json.dumps(previous, ensure_ascii=False)[:20000] + "\n```\n\n")
    return head + "```json\n" + json.dumps(data, ensure_ascii=False) + "\n```"


def parse_reply(text):
    """The JSON object in an agent's reply: a ```json block, or the
    outermost braces."""
    if isinstance(text, dict):
        return text
    text = str(text or "")
    for block in re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S):
        try:
            return json.loads(block)
        except ValueError:
            pass
    a, b = text.find("{"), text.rfind("}")
    if a >= 0 and b > a:
        try:
            return json.loads(text[a:b + 1])
        except ValueError:
            pass
    raise AgentError("the agent's reply holds no JSON object")


class Client:
    """The Planner agent behind the developer API."""

    def __init__(self, api_url, key, space, bot, room="", timeout=900):
        self.api_url, self.key, self.space, self.bot, self.room, self.timeout = api_url.rstrip("/"), key, space, bot, room, timeout

    @property
    def ready(self):
        return bool(self.api_url and self.key and self.space and self.bot)

    def ask(self, body):
        payload = {"space": self.space, "bot": self.bot, "body": body, "temp_thread": True}
        if self.room:
            payload["room"] = self.room
        req = urllib.request.Request(self.api_url + "/platform/spaces/ask", data=json.dumps(payload).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                out = json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            raise AgentError("the agent could not be reached (%s): %s" % (e.code, detail))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise AgentError("the agent could not be reached: %s" % e)
        reply = out.get("reply")
        if not reply:
            raise AgentError("the agent gave no reply")
        return reply


def plan_with_agent(ctx, ask, rounds=3, progress=None):
    """Asks, checks, and asks again with what was wrong, up to `rounds`
    times. Returns (accepted answer, log of the rounds)."""
    log, problems, previous = [], None, None
    for n in range(1, rounds + 1):
        if progress:
            progress("thinking" if n == 1 else "repairing", n)
        reply = ask(brief(ctx, problems, previous))
        if progress:
            progress("checking", n)
        try:
            out = parse_reply(reply)
        except AgentError as e:
            problems, previous = [str(e) + "; answer with one ```json block"], {"reply": str(reply)[:4000]}
            log.append({"round": n, "errors": problems, "warnings": []})
            continue
        errors, warnings, norm = planner.check(ctx, out)
        log.append({"round": n, "errors": errors, "warnings": warnings})
        if not errors:
            return norm, log
        problems, previous = errors, out
    raise AgentError("the agent's plan still broke the rules after %d rounds: %s" % (rounds, "; ".join(problems or [])[:500]))
