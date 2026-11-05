"""The study planner: from a student's answers to a weekly timetable, a
calendar of dated sessions, charts' numbers and evidence-based advice.

Pure functions over plain data (no I/O), so the server and the tests share
them. Times are minutes since midnight; days are keyed sat..fri, the Iranian
week.
"""

import datetime as dt
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

DAYS = ["sat", "sun", "mon", "tue", "wed", "thu", "fri"]
DAY_NAMES = {"sat": "شنبه", "sun": "یکشنبه", "mon": "دوشنبه", "tue": "سه‌شنبه",
             "wed": "چهارشنبه", "thu": "پنجشنبه", "fri": "جمعه"}
# date.weekday(): Monday is 0.
WEEKDAY_KEY = {5: "sat", 6: "sun", 0: "mon", 1: "tue", 2: "wed", 3: "thu", 4: "fri"}

TYPES = {
    "learn": "مطالعه و یادگیری",
    "practice": "تمرین و خودآزمایی",
    "review": "مرور فاصله‌دار",
    "weekly_review": "بازبینی هفتگی",
    "timed_test": "آزمون زمان‌دار",
}

EARLIEST = 6 * 60
LONG_BREAK = 15
MAX_COURSES = 30
MAX_WEEKS = 12


class PlanError(ValueError):
    """An answer the planner cannot work with; the message is for the student."""


def load_json(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- curriculum

def courses_for(curriculum, grade, field=None):
    """The official courses of a grade (and field, from grade 10)."""
    g = curriculum["grades"].get(str(grade))
    if g is None:
        raise PlanError("پایه‌ی تحصیلی نامعتبر است.")
    if "fields" in g:
        if not field:
            raise PlanError("برای این پایه باید رشته را انتخاب کنی.")
        if field not in g["fields"]:
            raise PlanError("این رشته برای این پایه تعریف نشده است.")
        return [dict(c) for c in g.get("common", [])] + [dict(c) for c in g["fields"][field]]
    return [dict(c) for c in g["courses"]]


def needs_field(curriculum, grade):
    g = curriculum["grades"].get(str(grade)) or {}
    return "fields" in g


def merge_overrides(curriculum, overrides):
    """Applies a reviewed correction file: whole course lists per grade or
    per grade and field, and a note on what was checked."""
    if not overrides:
        return curriculum
    out = json.loads(json.dumps(curriculum))
    for grade, g in (overrides.get("grades") or {}).items():
        target = out["grades"].get(str(grade))
        if target is None or not isinstance(g, dict):
            continue
        if isinstance(g.get("courses"), list) and "courses" in target:
            target["courses"] = g["courses"]
        if isinstance(g.get("common"), list) and "common" in target:
            target["common"] = g["common"]
        for field, courses in (g.get("fields") or {}).items():
            if isinstance(courses, list) and field in target.get("fields", {}):
                target["fields"][field] = courses
    if overrides.get("reviewed"):
        out["source"]["reviewed"] = overrides["reviewed"]
    return out


# ---------------------------------------------------------------- time

def hm(minutes):
    return "%02d:%02d" % (minutes // 60, minutes % 60)


def parse_hm(text):
    h, m = str(text).split(":")
    v = int(h) * 60 + int(m)
    if not 0 <= v <= 24 * 60:
        raise PlanError("ساعت نامعتبر: %s" % text)
    return v


def windows_of(cells):
    """Free time of one day as merged [start, end) windows in minutes.
    Accepts hour cells (8 means 08:00–09:00) or ["16:00", "18:30"] pairs."""
    spans = []
    for c in cells or []:
        if isinstance(c, bool):
            raise PlanError("زمان آزاد نامعتبر است.")
        if isinstance(c, (int, float)):
            h = int(c)
            if not 0 <= h <= 23:
                raise PlanError("ساعت نامعتبر: %s" % c)
            spans.append((h * 60, h * 60 + 60))
        elif isinstance(c, (list, tuple)) and len(c) == 2:
            a, b = parse_hm(c[0]), parse_hm(c[1])
            if b > a:
                spans.append((a, b))
        else:
            raise PlanError("زمان آزاد نامعتبر است.")
    spans.sort()
    merged = []
    for a, b in spans:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged


# ---------------------------------------------------------------- settings

def stage_defaults(grade):
    if grade <= 3:
        return {"focus": 20, "break": 10, "cap": 60, "latest": 20 * 60}
    if grade <= 6:
        return {"focus": 30, "break": 10, "cap": 90, "latest": 20 * 60 + 30}
    if grade <= 9:
        return {"focus": 40, "break": 10, "cap": 150, "latest": 22 * 60}
    return {"focus": 45, "break": 10, "cap": 240, "latest": 23 * 60}


def settings_for(grade, goals, concerns):
    """How sessions are cut and how much a day holds, from the stage, the
    goals and the concerns the student chose."""
    d = stage_defaults(grade)
    ge = [g.get("effects", {}) for g in goals]
    ce = [c.get("effects", {}) for c in concerns]

    focus = min([d["focus"]] + [e["focus"] for e in ce if "focus" in e])
    brk = max([e["break"] for e in ce if "break" in e], default=d["break"])
    every = min([e["long_break_every"] for e in ce if "long_break_every" in e], default=0)
    cap = d["cap"] * max([e.get("cap_factor", 1.0) for e in ge], default=1.0)
    for e in ce:
        cap *= e.get("cap_factor", 1.0)
    latest = min([d["latest"]] + [parse_hm(e["latest_end"]) for e in ce if "latest_end" in e])
    practice = max([e.get("practice_share", 0.25) for e in ge], default=0.25)
    practice += sum(e.get("practice_bonus", 0) for e in ce)
    review = max([e.get("review_share", 0.2) for e in ge], default=0.2)
    review += sum(e.get("review_bonus", 0) for e in ce)
    weak = max([1.3] + [e.get("weak_boost", 1.0) for e in ge + ce])
    return {
        "focus": int(focus),
        "break": int(brk),
        "long_break_every": int(every),
        "daily_cap": max(int(round(cap / 5.0) * 5), focus),
        "latest_end": latest,
        "practice_share": min(practice, 0.6),
        "review_share": min(review, 0.4),
        "exam_boost": max([e.get("exam_boost", 1.0) for e in ge], default=1.0),
        "weak_boost": weak,
        "rest_day": any(e.get("rest_day") for e in ce),
        "weekly_review": any(e.get("weekly_review") for e in ce) or any(g["id"] in ("final_exam", "konkur", "catch_up") for g in goals),
        "timed_tests": any(e.get("timed_tests") for e in ge),
        "starter": any(e.get("starter") for e in ce),
        "referral": any(e.get("referral") for e in ce),
    }


# ---------------------------------------------------------------- slots

def day_slots(windows, s):
    """Session start/end times that fit a day's windows, its cap and its
    bedtime limit."""
    out, used = [], 0
    for a, b in windows:
        a, b = max(a, EARLIEST), min(b, s["latest_end"])
        t, run = a, 0
        while t + s["focus"] <= b and used + s["focus"] <= s["daily_cap"]:
            out.append((t, t + s["focus"]))
            used += s["focus"]
            run += 1
            t += s["focus"] + s["break"]
            if s["long_break_every"] and run % s["long_break_every"] == 0:
                t += max(LONG_BREAK - s["break"], 0)
    return out


def week_slots(availability, s, apply_rest=True):
    slots = {d: day_slots(windows_of(availability.get(d)), s) for d in DAYS}
    rest = None
    if apply_rest and s["rest_day"] and sum(1 for d in DAYS if slots[d]) > 1:
        rest = "fri" if slots["fri"] else min((d for d in DAYS if slots[d]), key=lambda d: (len(slots[d]), -DAYS.index(d)))
        slots[rest] = []
    return slots, rest


# ---------------------------------------------------------------- allocation

def score(c, s):
    v = float(c.get("weight", 2))
    if c.get("exam"):
        v *= s["exam_boost"]
    if c.get("weak"):
        v *= s["weak_boost"]
    return v


def allocate(courses, total, s, week):
    """Blocks per course for one week: everyone gets one when there is room,
    the rest goes by score (largest remainder). With fewer blocks than
    courses, the strongest half stays and the others take turns by week."""
    if total <= 0 or not courses:
        return {}, []
    ranked = sorted(courses, key=lambda c: (-score(c, s), c["id"]))
    if total < len(ranked):
        fixed = total // 2
        rest = ranked[fixed:]
        k = total - fixed
        start = (week * k) % len(rest) if rest else 0
        chosen = ranked[:fixed] + [rest[(start + i) % len(rest)] for i in range(k)]
        ids = {c["id"] for c in chosen}
        return {c["id"]: 1 for c in chosen}, [c["id"] for c in ranked if c["id"] not in ids]
    alloc = {c["id"]: 1 for c in ranked}
    extra = total - len(ranked)
    weights = {c["id"]: score(c, s) for c in ranked}
    whole = sum(weights.values())
    shares = {i: extra * w / whole for i, w in weights.items()}
    for i, v in shares.items():
        alloc[i] += int(math.floor(v))
    left = total - sum(alloc.values())
    order = sorted(ranked, key=lambda c: (-(shares[c["id"]] - math.floor(shares[c["id"]])), -weights[c["id"]], c["id"]))
    for c in order[:left]:
        alloc[c["id"]] += 1
    return alloc, []


def types_for(n, s):
    """learn, then practice, then spaced review, across a course's week."""
    if n <= 1:
        return ["learn"] * n
    practice = int(round(n * s["practice_share"]))
    review = int(round(n * s["review_share"]))
    if n >= 3:
        review = max(review, 1)
        practice = max(practice, 1)
    learn = max(n - practice - review, 1)
    while learn + practice + review > n:
        if practice > review:
            practice -= 1
        else:
            review -= 1
    return ["learn"] * learn + ["practice"] * practice + ["review"] * review


def circular_gap(a, b):
    d = abs(a - b)
    return min(d, 7 - d)


def build_week(courses, availability, s, week=0):
    """One week's timetable: {day: [session]}, the courses resting this week
    and the rest day."""
    slots, rest = week_slots(availability, s)
    flat = [(d, i) for d in DAYS for i in range(len(slots[d]))]
    if not flat:
        raise PlanError("در زمان‌هایی که انتخاب کردی جلسه‌ای جا نمی‌شود؛ زمان آزاد بیشتری انتخاب کن یا ساعت‌ها را قبل از وقت خواب بگذار.")
    reserved = {}
    if s["weekly_review"] and len(flat) >= len(courses) + 2:
        reserved[flat[-1]] = "weekly_review"
    if s["timed_tests"] and len(flat) >= len(courses) + 3:
        last_day = flat[-1][0]
        earlier = [x for x in flat if x[0] != last_day and x not in reserved]
        pick = earlier[-1] if earlier else next(x for x in reversed(flat) if x not in reserved)
        reserved[pick] = "timed_test"
    free = {d: len(slots[d]) - sum(1 for x in reserved if x[0] == d) for d in DAYS}
    alloc, resting = allocate(courses, sum(free.values()), s, week)
    by_id = {c["id"]: c for c in courses}

    # Spread each course's blocks over days far apart (spaced practice).
    placed = {d: [] for d in DAYS}
    for cid in sorted(alloc, key=lambda i: (-alloc[i], -score(by_id[i], s), i)):
        days_used = []
        for _ in range(alloc[cid]):
            cands = [d for d in DAYS if free[d] > 0]
            def key(d):
                gap = min([circular_gap(DAYS.index(d), DAYS.index(u)) for u in days_used], default=7)
                return (-gap, -free[d], DAYS.index(d))
            d = min(cands, key=key)
            free[d] -= 1
            placed[d].append(cid)
            days_used.append(d)

    week_plan = {}
    for d in DAYS:
        items = placed[d]
        order = []
        pool = sorted(items, key=lambda i: (-score(by_id[i], s), i))
        if s["starter"] and pool:
            light = min(pool, key=lambda i: (score(by_id[i], s), i))
            pool.remove(light)
            order.append(light)
        while pool:
            last = order[-1] if order else None
            nxt = next((i for i in pool if i != last), pool[0])
            pool.remove(nxt)
            order.append(nxt)
        sessions, k = [], 0
        for idx, (a, b) in enumerate(slots[d]):
            kind = reserved.get((d, idx))
            if kind:
                sessions.append({"start": hm(a), "end": hm(b), "course_id": "_" + kind, "course": TYPES[kind], "type": kind, "category": "special"})
                continue
            cid = order[k]
            k += 1
            c = by_id[cid]
            sessions.append({"start": hm(a), "end": hm(b), "course_id": cid, "course": c["name"], "type": None, "category": c.get("category", "custom"), "weak": bool(c.get("weak"))})
        week_plan[d] = sessions

    # Types follow each course's sessions in time order.
    for cid, n in alloc.items():
        mine = [x for d in DAYS for x in week_plan[d] if x["course_id"] == cid]
        for x, t in zip(mine, types_for(n, s)):
            x["type"] = t
    for d in DAYS:
        for x in week_plan[d]:
            x["type_label"] = TYPES[x["type"]]
            x["minutes"] = parse_hm(x["end"]) - parse_hm(x["start"])
    return week_plan, resting, rest


# ---------------------------------------------------------------- plan

def validate_answers(a, curriculum, goals_cat, concerns_cat):
    if not isinstance(a, dict):
        raise PlanError("درخواست نامعتبر است.")
    try:
        grade = int(a.get("grade"))
    except (TypeError, ValueError):
        raise PlanError("پایه‌ی تحصیلی را انتخاب کن.")
    if not 1 <= grade <= 12:
        raise PlanError("پایه‌ی تحصیلی نامعتبر است.")
    field = a.get("field") or None
    official = courses_for(curriculum, grade, field)
    if not needs_field(curriculum, grade):
        field = None
    raw = a.get("courses")
    if raw is None:
        raw = official
    if not isinstance(raw, list) or not raw:
        raise PlanError("دست‌کم یک درس لازم است.")
    if len(raw) > MAX_COURSES:
        raise PlanError("حداکثر %d درس." % MAX_COURSES)
    known = {c["id"]: c for c in official}
    courses, seen = [], set()
    for i, c in enumerate(raw):
        if not isinstance(c, dict):
            raise PlanError("درس نامعتبر است.")
        name = str(c.get("name") or "").strip()[:60]
        cid = str(c.get("id") or "").strip()[:40] or "custom_%d" % i
        if not name:
            raise PlanError("نام درس خالی است.")
        if cid in seen:
            cid = "%s_%d" % (cid, i)
        seen.add(cid)
        base = known.get(cid, {})
        try:
            weight = int(c.get("weight", base.get("weight", 2)))
        except (TypeError, ValueError):
            weight = 2
        courses.append({
            "id": cid, "name": name, "weight": min(max(weight, 1), 3),
            "category": base.get("category") or (c.get("category") if c.get("category") in curriculum["categories"] else "custom"),
            "exam": bool(base.get("exam", c.get("exam", False))),
            "weak": bool(c.get("weak")),
        })
    goal_by = {g["id"]: g for g in goals_cat["goals"]}
    concern_by = {c["id"]: c for c in concerns_cat["concerns"]}
    goals = [goal_by[g] for g in (a.get("goals") or []) if g in goal_by]
    concerns = [concern_by[c] for c in (a.get("concerns") or []) if c in concern_by]
    goal_note = str(a.get("goal_note") or "").strip()[:300]
    concern_note = str(a.get("concern_note") or "").strip()[:300]
    if not goals and not goal_note:
        raise PlanError("یک هدف انتخاب کن یا هدفت را بنویس.")
    av = a.get("availability")
    if not isinstance(av, dict):
        raise PlanError("زمان آزادت را مشخص کن.")
    availability = {d: av.get(d) or [] for d in DAYS}
    for d in DAYS:
        windows_of(availability[d])
    try:
        weeks = int(a.get("weeks", 4))
    except (TypeError, ValueError):
        weeks = 4
    weeks = min(max(weeks, 1), MAX_WEEKS)
    try:
        start = dt.date.fromisoformat(str(a.get("start_date") or dt.date.today().isoformat()))
    except ValueError:
        raise PlanError("تاریخ شروع نامعتبر است.")
    return {
        "grade": grade, "field": field, "courses": courses, "goals": goals, "concerns": concerns,
        "goal_note": goal_note, "concern_note": concern_note, "availability": availability,
        "weeks": weeks, "start": start, "name": str(a.get("name") or "").strip()[:40],
    }


def free_minutes(availability):
    return sum(b - a for d in DAYS for a, b in windows_of(availability.get(d)))




# ---------------------------------------------------------------- the agent's ground
#
# The plan itself is the Planner agent's work (agent.py asks it). This part
# is the ground it stands on and the rules it is held to: the free slots it
# may use, the references it may cite, a deterministic draft (its tool, and
# the planner of the tests), the check of what it answers, and turning an
# accepted answer into the timetable, the calendar and the charts' numbers.

def prepare(answers, curriculum, goals_cat, concerns_cat):
    """Everything the agent and the checks need for one student."""
    a = validate_answers(answers, curriculum, goals_cat, concerns_cat)
    s = settings_for(a["grade"], a["goals"], a["concerns"])
    slots, _ = week_slots(a["availability"], s, apply_rest=False)
    catalog = {}
    for d in DAYS:
        for i, (x, y) in enumerate(slots[d]):
            catalog["%s-%d" % (d, i)] = {"day": d, "start": hm(x), "end": hm(y), "minutes": y - x}
    if not catalog:
        raise PlanError("در زمان‌هایی که انتخاب کردی جلسه‌ای جا نمی‌شود؛ زمان آزاد بیشتری انتخاب کن یا ساعت‌ها را قبل از وقت خواب بگذار.")
    refs = {}
    for c in a["concerns"]:
        for n, src in enumerate(c["sources"]):
            refs["concern:%s:%d" % (c["id"], n)] = src
    for n, x in enumerate(concerns_cat.get("study_science", [])):
        refs["science:%d" % n] = x["source"]
    field_name = (curriculum["fields"].get(a["field"]) or {}).get("name") if a["field"] else None
    return {"answers": a, "settings": s, "slots": catalog, "refs": refs,
            "grade_name": curriculum["grades"][str(a["grade"])]["name"], "field_name": field_name,
            "concerns_cat": concerns_cat}


def slot_order(sid):
    d, i = sid.split("-")
    return (DAYS.index(d), int(i))


def draft(ctx):
    """A deterministic plan in the agent's answer format: the agent's tool
    (plan_tool.py draft) and the planner of the tests and of local mode."""
    a, s = ctx["answers"], ctx["settings"]
    weeks = []
    for w in range(a["weeks"]):
        wp, resting, rest = build_week(a["courses"], a["availability"], s, w)
        sessions = []
        for d in DAYS:
            starts = {v["start"]: k for k, v in ctx["slots"].items() if v["day"] == d}
            for x in wp[d]:
                sessions.append({"slot": starts[x["start"]], "course_id": x["course_id"], "type": x["type"]})
        weeks.append({"week": w + 1, "sessions": sessions, "resting": resting})
        if not resting:
            break
    advice = []
    for c in a["concerns"]:
        advice.append({"title": c["title"], "body": c["why"], "tips": c["tips"][:3],
                       "refs": ["concern:%s:%d" % (c["id"], n) for n in range(len(c["sources"]))]})
    return {"summary": "برنامه بر پایه‌ی مرور فاصله‌دار، خودآزمایی و تمرین درهم چیده شده است.",
            "rest_day": rest, "weeks": weeks, "advice": advice}


def check(ctx, out):
    """Holds the agent's answer to the rules. Returns (errors, warnings,
    normalized answer); with errors, the answer is not used."""
    errors, warnings = [], []
    if not isinstance(out, dict):
        return ["the answer is not a JSON object"], [], None
    a, s = ctx["answers"], ctx["settings"]
    courses = {c["id"]: c for c in a["courses"]}
    weeks_in = out.get("weeks")
    if weeks_in is None and isinstance(out.get("sessions"), list):
        weeks_in = [{"week": 1, "sessions": out["sessions"]}]
    if not isinstance(weeks_in, list) or not weeks_in:
        return ["`weeks` must be a non-empty list of {week, sessions}"], [], None
    if len(weeks_in) > a["weeks"]:
        warnings.append("only the first %d weeks are used" % a["weeks"])
        weeks_in = weeks_in[:a["weeks"]]
    rest = out.get("rest_day")
    if rest is not None and rest not in DAYS:
        errors.append("rest_day must be one of %s or null" % ", ".join(DAYS))
        rest = None
    weeks, seen_courses = [], set()
    for wi, w in enumerate(weeks_in):
        sess = w.get("sessions") if isinstance(w, dict) else None
        if not isinstance(sess, list) or not sess:
            errors.append("week %d has no sessions" % (wi + 1))
            continue
        used, clean, per_day = set(), [], {}
        for k, x in enumerate(sess):
            where = "week %d session %d" % (wi + 1, k + 1)
            if not isinstance(x, dict):
                errors.append(where + ": not an object")
                continue
            sid, cid, typ = x.get("slot"), x.get("course_id"), x.get("type")
            if sid not in ctx["slots"]:
                errors.append("%s: unknown slot %r (use only the given slot ids)" % (where, sid))
                continue
            if sid in used:
                errors.append("%s: slot %s is used twice" % (where, sid))
                continue
            if typ in ("weekly_review", "timed_test"):
                cid = "_" + typ
            elif typ not in ("learn", "practice", "review"):
                errors.append("%s: type %r is not one of learn, practice, review, weekly_review, timed_test" % (where, typ))
                continue
            elif cid not in courses:
                errors.append("%s: unknown course_id %r" % (where, cid))
                continue
            used.add(sid)
            seen_courses.add(cid)
            day = ctx["slots"][sid]["day"]
            if rest and day == rest:
                errors.append("%s: %s is the rest day" % (where, rest))
                continue
            per_day[day] = per_day.get(day, 0) + ctx["slots"][sid]["minutes"]
            clean.append({"slot": sid, "course_id": cid, "type": typ,
                          "topic": str(x.get("topic") or "").strip()[:120],
                          "note": str(x.get("note") or "").strip()[:160]})
        for d, m in per_day.items():
            if m > s["daily_cap"]:
                errors.append("week %d: %s holds %d minutes, over the daily cap of %d" % (wi + 1, d, m, s["daily_cap"]))
        clean.sort(key=lambda x: slot_order(x["slot"]))
        for p, q in zip(clean, clean[1:]):
            if p["course_id"] == q["course_id"] and p["slot"].split("-")[0] == q["slot"].split("-")[0] and not p["course_id"].startswith("_"):
                warnings.append("week %d: %s twice in a row on %s" % (wi + 1, p["course_id"], p["slot"].split("-")[0]))
        weeks.append({"week": wi + 1, "sessions": clean,
                      "resting": [r for r in (w.get("resting") or []) if r in courses]})
    if s["rest_day"] and not rest and len({v["day"] for v in ctx["slots"].values()}) > 1:
        errors.append("the student needs a rest day: set rest_day and leave that day empty")
    missing = [cid for cid in courses if cid not in seen_courses and not any(cid in w["resting"] for w in weeks)]
    if missing:
        errors.append("these courses have no session in any week and are not listed as resting: " + ", ".join(missing))
    advice = []
    for card in out.get("advice") or []:
        if not isinstance(card, dict) or not str(card.get("title") or "").strip():
            continue
        refs = [r for r in (card.get("refs") or []) if r in ctx["refs"]]
        dropped = [r for r in (card.get("refs") or []) if r not in ctx["refs"]]
        if dropped:
            warnings.append("unknown refs dropped: " + ", ".join(map(str, dropped)))
        advice.append({"title": str(card["title"]).strip()[:120], "body": str(card.get("body") or "").strip()[:1200],
                       "tips": [str(t).strip()[:300] for t in (card.get("tips") or []) if str(t).strip()][:6], "refs": refs})
    if not advice:
        warnings.append("no advice cards")
    norm = {"summary": str(out.get("summary") or "").strip()[:1500], "rest_day": rest, "weeks": weeks, "advice": advice}
    return errors, warnings, (None if errors else norm)


def assemble(ctx, out, plan_id="plan", generated_by=None, now=None):
    """An accepted answer as the stored plan: the week's timetable, every
    dated session of the calendar, the charts' numbers and the advice."""
    a, s = ctx["answers"], ctx["settings"]
    courses = {c["id"]: c for c in a["courses"]}

    def timetable(week):
        t = {d: [] for d in DAYS}
        for x in week["sessions"]:
            slot = ctx["slots"][x["slot"]]
            c = courses.get(x["course_id"])
            t[slot["day"]].append({
                "start": slot["start"], "end": slot["end"], "minutes": slot["minutes"],
                "course_id": x["course_id"], "course": c["name"] if c else TYPES[x["type"]],
                "category": c.get("category", "custom") if c else "special", "weak": bool(c and c.get("weak")),
                "type": x["type"], "type_label": TYPES[x["type"]], "topic": x.get("topic", ""), "note": x.get("note", "")})
        for d in DAYS:
            t[d].sort(key=lambda x: x["start"])
        return t

    tables = [timetable(w) for w in out["weeks"]]
    calendar = {}
    for i in range(a["weeks"] * 7):
        day = a["start"] + dt.timedelta(days=i)
        w = i // 7
        table = tables[w % len(tables)]
        rows = []
        for n, x in enumerate(table[WEEKDAY_KEY[day.weekday()]]):
            x = dict(x, id="%s-%s-%d" % (plan_id, day.isoformat(), n), done=False, week=w + 1)
            if w >= len(tables) and x["type"] == "learn" and not x["note"]:
                x["note"] = "۵ دقیقه‌ی اول: مرور جلسه‌ی قبلِ همین درس"
            rows.append(x)
        calendar[day.isoformat()] = rows

    first = tables[0]
    per_course, per_type = {}, {}
    for d in DAYS:
        for x in first[d]:
            p = per_course.setdefault(x["course_id"], {"id": x["course_id"], "name": x["course"], "category": x["category"], "minutes": 0, "sessions": 0})
            p["minutes"] += x["minutes"]
            p["sessions"] += 1
            per_type[x["type"]] = per_type.get(x["type"], 0) + x["minutes"]
    total = sum(p["minutes"] for p in per_course.values())
    for p in per_course.values():
        p["share"] = round(p["minutes"] / total, 4) if total else 0
    stats = {
        "week_minutes": total,
        "sessions": sum(len(first[d]) for d in DAYS),
        "free_minutes": free_minutes(a["availability"]),
        "slot_minutes": sum(v["minutes"] for v in ctx["slots"].values()),
        "study_days": sum(1 for d in DAYS if first[d]),
        "per_course": sorted(per_course.values(), key=lambda p: -p["minutes"]),
        "per_day": [{"day": d, "name": DAY_NAMES[d], "minutes": sum(x["minutes"] for x in first[d])} for d in DAYS],
        "per_type": [{"type": t, "label": TYPES[t], "minutes": m} for t, m in sorted(per_type.items(), key=lambda kv: -kv[1])],
    }
    resting = [[courses[i]["name"] for i in w["resting"] if i in courses] for w in out["weeks"]]
    end = a["start"] + dt.timedelta(days=a["weeks"] * 7 - 1)
    return {
        "id": plan_id,
        "created_at": (now or dt.datetime.now(dt.timezone.utc)).isoformat(timespec="seconds"),
        "start_date": a["start"].isoformat(),
        "end_date": end.isoformat(),
        "weeks": a["weeks"],
        "generated_by": generated_by or {"kind": "draft"},
        "profile": {
            "name": a["name"], "grade": a["grade"], "grade_name": ctx["grade_name"],
            "field": a["field"], "field_name": ctx["field_name"],
            "goals": [g["id"] for g in a["goals"]], "goal_titles": [g["title"] for g in a["goals"]], "goal_note": a["goal_note"],
            "concerns": [c["id"] for c in a["concerns"]], "concern_titles": [c["title"] for c in a["concerns"]], "concern_note": a["concern_note"],
            "courses": a["courses"], "availability": a["availability"],
        },
        "settings": dict(s, latest_end=hm(s["latest_end"])),
        "rest_day": out["rest_day"],
        "summary": out["summary"],
        "timetable": first,
        "weeks_detail": tables,
        "stats": stats,
        "resting": resting,
        "advice": advise(ctx, out, stats, resting),
        "calendar": calendar,
    }


def build_plan(answers, curriculum, goals_cat, concerns_cat, plan_id="plan", now=None):
    """The deterministic path end to end (tests, local mode)."""
    ctx = prepare(answers, curriculum, goals_cat, concerns_cat)
    errors, _, out = check(ctx, draft(ctx))
    if errors:
        raise PlanError("; ".join(errors))
    return assemble(ctx, out, plan_id, {"kind": "draft"}, now)


def fa_num(n):
    return str(n).translate(str.maketrans("0123456789", "۰۱۲۳۴۵۶۷۸۹"))


def advise(ctx, out, stats, resting):
    """The agent's counsel with its citations resolved, framed by what the
    numbers say and, when a concern calls for it, where to find help (the
    help card never depends on the agent)."""
    a, s, cat = ctx["answers"], ctx["settings"], ctx["concerns_cat"]
    hours = stats["week_minutes"] / 60.0
    summary = "هر هفته حدود %s ساعت مطالعه در %s جلسه‌ی %s دقیقه‌ای با %s دقیقه استراحت بین جلسه‌ها." % (
        fa_num(round(hours, 1)).replace(".", "٫"), fa_num(stats["sessions"]), fa_num(s["focus"]), fa_num(s["break"]))
    cards = [{"kind": "summary", "title": "برنامه‌ی تو در یک نگاه", "body": summary, "tips": [], "sources": []}]
    if s["referral"]:
        cards.append({"kind": "help", "title": "کمک گرفتن نشانه‌ی قدرت است", "body": cat["disclaimer"],
                      "tips": ["%s: %s" % (h["name"], h["phone"]) for h in cat.get("help", [])], "sources": []})
    warn = []
    if any(resting):
        names = sorted({n for week in resting for n in week})
        warn.append("زمان آزادت برای همه‌ی دروس در یک هفته کافی نیست؛ این دروس هفته‌به‌هفته نوبتی می‌آیند: " + "، ".join(names) + ".")
    if out["rest_day"]:
        warn.append("%s روز استراحت توست؛ استراحت بخشی از برنامه است." % DAY_NAMES[out["rest_day"]])
    if stats["study_days"] <= 2:
        warn.append("فقط %s روز در هفته درس داری؛ پخش کردن مطالعه در روزهای بیشتر به ماندگاری کمک می‌کند." % fa_num(stats["study_days"]))
    if warn:
        cards.append({"kind": "notice", "title": "نکته‌های برنامه", "body": "", "tips": warn, "sources": []})
    for card in out["advice"]:
        cards.append({"kind": "counsel", "title": card["title"], "body": card["body"], "tips": card["tips"],
                      "sources": [ctx["refs"][r] for r in card["refs"]]})
    for g in a["goals"]:
        cards.append({"kind": "goal", "title": "هدف: " + g["title"], "body": g["desc"], "tips": g.get("tips", []), "sources": []})
    for n, x in enumerate(cat.get("study_science", [])):
        cards.append({"kind": "science", "title": x["title"], "body": x["body"], "tips": [], "sources": [x["source"]]})
    return cards
