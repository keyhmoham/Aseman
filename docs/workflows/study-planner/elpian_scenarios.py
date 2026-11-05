"""Writes the Elpian frontend's end-to-end scenarios (app/elpian/e2e/*.json).

The platform replays them against the running server before it opens the
app (appui_publish). The catalogs and the curriculum come from the server for
real; the person's plan, the agent's job and the calendar are mocked with a
plan the deterministic planner makes here, so a check never asks the Planner
agent (it would cost the person a plan each time).

    python3 docs/workflows/study-planner/elpian_scenarios.py
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "app")
sys.path.insert(0, APP)

import planner  # noqa: E402

OUT = os.path.join(APP, "elpian", "e2e")


def fixture():
    cur, goals, concerns = planner.load_json("curriculum.json"), planner.load_json("goals.json"), planner.load_json("concerns.json")
    av = {"sat": [16, 17, 18], "sun": [16, 17, 18], "mon": [16, 17, 18, 20], "tue": [16, 17, 18], "wed": [16, 17, 18], "thu": [9, 10, 11], "fri": [10, 11]}
    plan = planner.build_plan({"grade": 11, "field": "math", "goals": ["konkur"], "concerns": ["adhd", "sleep"], "availability": av,
                               "start_date": "2026-11-07", "weeks": 2, "name": "سارا"}, cur, goals, concerns, plan_id="pe2e")
    plan["generated_by"] = {"kind": "agent", "agent": "Planner", "rounds": 2}
    plan["summary"] = "برنامه‌ات بر پایه‌ی مرور فاصله‌دار و جلسه‌های کوتاه ۲۵ دقیقه‌ای چیده شده است."
    calendar = plan.pop("calendar")
    first = next(d for d in sorted(calendar) if calendar[d])
    sessions = calendar[first]
    base = planner.dt.date.fromisoformat(first)
    planned, done = [0, 50, 75, 0, 100, 50, day_minutes(sessions)], [0, 50, 50, 0, 75, 25, 0]
    last7 = [{"date": (base - planner.dt.timedelta(days=6 - i)).isoformat(), "sessions": None, "minutes": planned[i], "done_minutes": done[i]} for i in range(7)]
    day = {"date": first, "sessions": sessions, "minutes": day_minutes(sessions), "done_minutes": 0, "last7": last7}
    return plan, calendar, day


def day_minutes(sessions):
    return sum(x["minutes"] for x in sessions)


def plan_mocks(plan, calendar, day, first_exists=True):
    one = day["sessions"][0]
    mocks = [
        {"path": "api/profiles/me", "method": "GET", "json": {"exists": True, "plan": plan}},
        {"path": "api/profiles/me/day/*", "method": "GET", "json": day},
        {"path": "api/profiles/me/calendar", "method": "GET", "json": {"days": calendar}},
        {"path": "api/profiles/me/sessions/*", "method": "PATCH", "json": dict(one, done=True)},
    ]
    if not first_exists:
        mocks.append({"path": "api/profiles/me", "method": "GET", "times": 1, "json": {"exists": False}})
    return mocks


def wizard_steps(grade_key, field_key=None):
    steps = [{"expect": {"text": "در چه پایه‌ای درس می‌خوانی؟"}}, {"do": "tap", "target": {"key": grade_key}}]
    if field_key:
        steps += [{"expect": {"text": "رشته‌ات چیست؟"}}, {"do": "tap", "target": {"key": field_key}}]
    return steps


def main():
    os.makedirs(OUT, exist_ok=True)
    plan, calendar, day = fixture()
    one = day["sessions"][0]

    full = {
        "name": "wizard to an agent-made plan, the calendar and today",
        "viewport": "phone",
        "mocks": plan_mocks(plan, calendar, day, first_exists=False) + [
            {"path": "api/profiles/me/plans", "method": "POST", "json": {"job": "job_e2e", "status": "queued"}},
            {"path": "api/jobs/job_e2e", "method": "GET", "json": {"id": "job_e2e", "status": "done", "round": 2, "plan_id": "pe2e"}},
        ],
        "steps": wizard_steps("grade_11", "field_math") + [
            {"expect": {"text": "منبع رسمی", "request": {"method": "GET", "path": "api/curriculum"}}},
            {"do": "tap", "target": {"key": "star_physics"}},
            {"do": "tap", "target": {"key": "weight_physics"}},
            {"do": "tap", "target": {"key": "remove_lab"}},
            {"expect": {"noText": "آزمایشگاه علوم تجربی ۲"}},
            {"do": "type", "target": {"key": "new_course"}, "text": "ریاضی تقویتی"},
            {"do": "tap", "target": {"key": "add_course"}},
            {"expect": {"text": "ریاضی تقویتی"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"expect": {"text": "هدفت از این برنامه چیست؟"}},
            {"do": "tap", "target": {"key": "goal_konkur"}},
            {"do": "type", "target": {"key": "goal_note"}, "text": "معدل ۱۹"},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"expect": {"text": "اختلال نقص توجه/بیش‌فعالی (ADHD)"}},
            {"do": "tap", "target": {"key": "concern_adhd"}},
            {"do": "tap", "target": {"key": "concern_sleep"}},
            {"do": "type", "target": {"key": "concern_note"}, "text": "عصرها خسته‌ام"},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"expect": {"text": "چه ساعت‌هایی در هفته آزادی؟"}},
            {"do": "tap", "target": {"key": "preset_afternoon"}},
            {"do": "tap", "target": {"key": "cell_fri_10"}},
            {"do": "tap", "target": {"key": "hour_20"}},
            {"expect": {"text": "۲۳ ساعت آزاد در هفته"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"expect": {"text": "آماده‌ای؟"}},
            {"do": "type", "target": {"key": "student_name"}, "text": "سارا"},
            {"do": "select", "target": {"key": "weeks"}, "value": "۲ هفته"},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"expect": {"text": "مشاور هوشمند در حال برنامه‌ریزی است", "request": {"method": "POST", "path": "api/profiles/me/plans"}}},
            {"do": "wait", "ms": 5000},
            {"expect": {"text": "پیام مشاور"}},
            {"expect": {"text": "مشاوره و توصیه‌ها"}},
            {"do": "select", "target": {"key": "nav"}, "value": "تقویم"},
            {"expect": {"text": "تقویم مطالعه"}},
            {"do": "tap", "target": {"key": "cal_next"}},
            {"do": "tap", "target": {"key": "cal_prev"}},
            {"do": "tap", "target": {"key": "cal_today"}},
            {"do": "select", "target": {"key": "nav"}, "value": "امروز"},
            {"expect": {"text": "برنامه‌ی امروز"}},
            {"expect": {"text": one["course"]}},
            {"do": "toggle", "target": {"key": "today_" + one["id"]}, "on": True},
            {"expect": {"request": {"method": "PATCH", "path": "api/profiles/me/sessions/" + one["id"]}}},
        ],
    }

    failing = {
        "name": "the agent cannot make the plan: a human error, then back",
        "viewport": "phone",
        "mocks": [
            {"path": "api/profiles/me", "method": "GET", "json": {"exists": False}},
            {"path": "api/profiles/me/plans", "method": "POST", "json": {"job": "job_fail", "status": "queued"}},
            {"path": "api/jobs/job_fail", "method": "GET", "json": {"id": "job_fail", "status": "failed", "error": "مشاور در دسترس نیست؛ کمی بعد دوباره امتحان کن."}},
        ],
        "steps": wizard_steps("grade_7") + [
            {"expect": {"text": "منبع رسمی"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "tap", "target": {"key": "goal_habit"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "tap", "target": {"key": "preset_weekend"}},
            {"do": "tap", "target": {"key": "preset_clear"}},
            {"expect": {"text": "دست‌کم یک ساعت انتخاب کن"}},
            {"do": "tap", "target": {"key": "preset_evening"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "tap", "target": {"key": "wiz_back"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "tap", "target": {"key": "wiz_next"}},
            {"do": "wait", "ms": 5000},
            {"expect": {"text": "برنامه ساخته نشد"}},
            {"expect": {"text": "مشاور در دسترس نیست؛ کمی بعد دوباره امتحان کن."}},
            {"do": "tap", "target": {"key": "think_back"}},
            {"expect": {"text": "آماده‌ای؟"}},
            {"do": "tap", "target": {"key": "wiz_close"}},
            {"expect": {"text": "هنوز برنامه‌ای نداری"}},
        ],
    }

    desk = {
        "name": "a desk window: the plan, the calendar and today side by side",
        "viewport": "desk",
        "mocks": plan_mocks(plan, calendar, day),
        "steps": [
            {"expect": {"text": "برنامه‌ی امروز"}},
            {"do": "select", "target": {"key": "topnav"}, "value": "برنامه"},
            {"expect": {"text": "جدول هفتگی"}},
            {"expect": {"text": "سهم هر درس"}},
            {"do": "select", "target": {"key": "topnav"}, "value": "تقویم"},
            {"expect": {"text": "تقویم مطالعه"}},
            {"do": "select", "target": {"key": "topnav"}, "value": "برنامه‌ی تازه"},
            {"expect": {"text": "در چه پایه‌ای درس می‌خوانی؟"}},
            {"do": "tap", "target": {"key": "wiz_close"}},
            {"expect": {"text": "برنامه‌ی امروز"}},
            {"do": "env", "theme": "dark"},
            {"expect": {"text": "پیشرفت امروز"}},
        ],
    }

    for name, sc in (("01-wizard-to-plan", full), ("02-agent-fails", failing), ("03-desk", desk)):
        with open(os.path.join(OUT, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(sc, f, ensure_ascii=False, indent=1)
            f.write("\n")
    print("wrote 3 scenarios to", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
