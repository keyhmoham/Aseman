"""Tests of the planner, the agent loop and the server. Run: python3 test_app.py"""

import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ["PLANNER_QUIET"] = "1"

import agent
import planner
import server

CUR = planner.load_json("curriculum.json")
GOALS = planner.load_json("goals.json")
CONCERNS = planner.load_json("concerns.json")
WEEK = {"sat": [16, 17, 18, 19], "sun": [16, 17], "mon": [17, 18, 19, 20, 21, 22], "tue": [16, 17], "wed": [15, 16, 17], "thu": [9, 10, 15], "fri": [10, 11]}


def answers(**kw):
    a = {"grade": 11, "field": "math", "goals": ["konkur"], "concerns": [], "availability": WEEK, "start_date": "2026-11-07", "weeks": 2}
    a.update(kw)
    return a


def agent_answer(brief_text, broken=False):
    """What a well-behaved Planner agent answers to a brief: round-robin
    over the slots, never the same course twice in a row."""
    data = agent.parse_reply(brief_text.split("```json\n")[-1].split("\n```")[0])
    courses = [c["id"] for c in data["student"]["courses"]]
    slots = sorted(data["slots"], key=planner.slot_order)
    rest = None
    if data["settings"]["rest_day"]:
        rest = data["slots"][slots[-1]]["day"]
    sessions, i = [], 0
    for sid in slots:
        if data["slots"][sid]["day"] == rest:
            continue
        sessions.append({"slot": sid, "course_id": courses[i % len(courses)], "type": "learn"})
        i += 1
    resting = [c for c in courses if c not in {s["course_id"] for s in sessions}]
    if broken:
        sessions[0]["slot"] = "xyz-9"
    refs = list(data["refs"])[:2]
    return "Here is the plan.\n```json\n" + json.dumps({
        "summary": "برنامه‌ی تو آماده است.", "rest_day": rest,
        "weeks": [{"week": 1, "sessions": sessions, "resting": resting}],
        "advice": [{"title": "شروع آرام", "body": "هر روز کمی.", "tips": ["تایمر بگذار"], "refs": refs + ["made-up"]}],
    }, ensure_ascii=False) + "\n```"


class FakeDeveloperAPI(BaseHTTPRequestHandler):
    """POST /dev/v1/platform/spaces/ask: the first answer breaks a rule,
    the repaired one is right."""
    calls = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeDeveloperAPI.calls.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        if self.path != "/dev/v1/platform/spaces/ask" or self.headers.get("Authorization") != "Bearer dk_test":
            self.send_response(404)
            self.end_headers()
            return
        first = len(FakeDeveloperAPI.calls) % 2 == 1
        reply = agent_answer(body["body"], broken=first)
        data = json.dumps({"bot_id": body["bot"], "reply": reply}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve(handler):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, "http://127.0.0.1:%d" % httpd.server_address[1]


class Curriculum(unittest.TestCase):
    def test_every_grade_and_field_has_courses(self):
        for g in range(1, 13):
            grade = CUR["grades"][str(g)]
            fields = grade.get("fields", {None: None})
            for f in fields:
                courses = planner.courses_for(CUR, g, f)
                self.assertGreater(len(courses), 3, (g, f))
                ids = [c["id"] for c in courses]
                self.assertEqual(len(ids), len(set(ids)), (g, f))
                for c in courses:
                    self.assertIn(c["category"], CUR["categories"])
                    self.assertIn(c["weight"], (1, 2, 3))

    def test_field_is_asked_from_grade_ten(self):
        self.assertFalse(planner.needs_field(CUR, 9))
        self.assertTrue(planner.needs_field(CUR, 10))
        with self.assertRaises(planner.PlanError):
            planner.courses_for(CUR, 11, None)
        names = [c["name"] for c in planner.courses_for(CUR, 12, "science")]
        self.assertIn("زیست‌شناسی ۳", names)
        self.assertNotIn("حسابان ۲", names)

    def test_overrides_replace_a_list(self):
        cur = planner.merge_overrides(CUR, {"grades": {"7": {"courses": [{"id": "x", "name": "X", "weight": 2, "category": "math"}]}}, "reviewed": "1404"})
        self.assertEqual([c["id"] for c in planner.courses_for(cur, 7)], ["x"])
        self.assertEqual(len(planner.courses_for(CUR, 7)), 12)


class Planner(unittest.TestCase):
    def plan(self, **kw):
        return planner.build_plan(answers(**kw), CUR, GOALS, CONCERNS)

    def test_sessions_stay_in_free_time_and_never_overlap(self):
        p = self.plan(concerns=["sleep"])
        for d, sessions in p["timetable"].items():
            windows = planner.windows_of(WEEK[d])
            last = -1
            for x in sessions:
                a, b = planner.parse_hm(x["start"]), planner.parse_hm(x["end"])
                self.assertTrue(any(w[0] <= a and b <= w[1] for w in windows), (d, x))
                self.assertGreaterEqual(a, last)
                self.assertLessEqual(b, planner.parse_hm("21:30"))
                last = b

    def test_adhd_means_short_sessions(self):
        p = self.plan(concerns=["adhd"])
        self.assertEqual(p["settings"]["focus"], 25)
        self.assertTrue(all(x["minutes"] == 25 for d in p["timetable"].values() for x in d))

    def test_daily_cap_and_rest_day(self):
        p = self.plan(concerns=["burnout"], goals=["habit"])
        cap = p["settings"]["daily_cap"]
        for d in p["stats"]["per_day"]:
            self.assertLessEqual(d["minutes"], cap)
        self.assertEqual(p["rest_day"], "fri")
        self.assertEqual(p["timetable"]["fri"], [])

    def test_every_course_has_time_and_spacing(self):
        p = self.plan()
        names = {x["course_id"] for d in p["timetable"].values() for x in d}
        for c in planner.courses_for(CUR, 11, "math"):
            self.assertIn(c["id"], names)
        for sessions in p["timetable"].values():
            for a, b in zip(sessions, sessions[1:]):
                if not a["course_id"].startswith("_"):
                    self.assertNotEqual(a["course_id"], b["course_id"])

    def test_calendar_dates_follow_the_week(self):
        p = self.plan()
        self.assertEqual(len(p["calendar"]), 14)
        self.assertEqual(p["calendar"]["2026-11-07"][0]["start"], p["timetable"]["sat"][0]["start"])  # a Saturday
        self.assertEqual(len(p["calendar"]["2026-11-13"]), len(p["timetable"]["fri"]))
        ids = [x["id"] for d in p["calendar"].values() for x in d]
        self.assertEqual(len(ids), len(set(ids)))

    def test_few_slots_rotate_courses(self):
        p = planner.build_plan({"grade": 7, "goals": ["habit"], "availability": {"sat": [17]}, "weeks": 3, "start_date": "2026-11-07"}, CUR, GOALS, CONCERNS)
        self.assertTrue(any(p["resting"]))
        firsts = [p["calendar"][d][0]["course_id"] for d in ("2026-11-07", "2026-11-14", "2026-11-21")]
        self.assertGreater(len(set(firsts)), 1)

    def test_bad_answers(self):
        for bad in ({"grade": 13}, answers(field=None), answers(goals=[]), answers(availability={"sat": []}), answers(availability={"sat": [30]})):
            with self.assertRaises(planner.PlanError):
                planner.build_plan(bad, CUR, GOALS, CONCERNS)

    def test_referral_card_for_low_mood(self):
        p = self.plan(concerns=["low_mood"])
        self.assertTrue(any(c["kind"] == "help" and any("۱۲۳" in t for t in c["tips"]) for c in p["advice"]))


class AgentLoop(unittest.TestCase):
    def ctx(self, **kw):
        return planner.prepare(answers(**kw), CUR, GOALS, CONCERNS)

    def test_check_catches_what_breaks_the_rules(self):
        ctx = self.ctx(concerns=["stress"])
        out = {"weeks": [{"sessions": [{"slot": "sat-0", "course_id": "physics", "type": "learn"},
                                       {"slot": "sat-0", "course_id": "nope", "type": "learn"},
                                       {"slot": "sun-0", "course_id": "physics", "type": "cram"}]}]}
        errors, _, norm = planner.check(ctx, out)
        text = " | ".join(errors)
        self.assertIsNone(norm)
        for part in ("used twice", "type 'cram'", "rest day", "no session in any week"):
            self.assertIn(part, text)

    def test_the_agent_is_asked_again_with_what_was_wrong(self):
        ctx = self.ctx(concerns=["adhd"])
        asked = []

        def ask(body):
            asked.append(body)
            return agent_answer(body, broken=len(asked) == 1)

        out, log = agent.plan_with_agent(ctx, ask)
        self.assertEqual(len(asked), 2)
        self.assertIn("unknown slot 'xyz-9'", asked[1])
        self.assertEqual(log[0]["errors"][0][:9], "week 1 se")
        self.assertEqual(log[1]["errors"], [])
        plan = planner.assemble(ctx, out, "t1", {"kind": "agent"})
        counsel = [c for c in plan["advice"] if c["kind"] == "counsel"]
        self.assertEqual(counsel[0]["title"], "شروع آرام")
        self.assertTrue(all("text" in s for s in counsel[0]["sources"]))  # made-up ref dropped

    def test_an_agent_that_never_gets_it_right_fails(self):
        ctx = self.ctx()
        with self.assertRaises(agent.AgentError):
            agent.plan_with_agent(ctx, lambda body: "I cannot do that", rounds=2)

    def test_brief_carries_the_contract(self):
        b = agent.brief(self.ctx(concerns=["test_anxiety"]))
        data = agent.parse_reply(b)
        self.assertEqual(data["task"], "study_plan")
        self.assertIn("sat-0", data["slots"])
        self.assertTrue(any(k.startswith("concern:test_anxiety") for k in data["refs"]))


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.dev, dev_url = serve(FakeDeveloperAPI)
        cfg = {"product": "Test", "port": 0, "data_dir": cls.tmp, "mode": "agent", "rounds": 3, "api_url": dev_url + "/dev/v1",
               "key": "dk_test", "space": "sp1", "planner_bot": "bot1", "room": "", "academic_year": ""}
        cls.app = server.App(cfg)
        cls.httpd = server.make_server(cls.app, "127.0.0.1", 0)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.dev.shutdown()
        shutil.rmtree(cls.tmp)

    def get(self, path):
        return json.load(urllib.request.urlopen(self.base + path))

    def send(self, method, path, body):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), method=method, headers={"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req))

    def test_catalogs(self):
        self.assertTrue(self.get("/healthz")["agent"])
        meta = self.get("/api/meta")
        self.assertTrue(meta["grades"]["10"]["needs_field"])
        cur = self.get("/api/curriculum?grade=10&field=humanities")
        self.assertIn("منطق", [c["name"] for c in cur["courses"]])
        self.assertIn("chap.sch.ir", cur["source"]["url"])
        self.assertNotIn("konkur", [g["id"] for g in self.get("/api/goals?grade=8")["goals"]])
        self.assertGreater(len(self.get("/api/concerns")["concerns"]), 10)
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get("/api/curriculum?grade=11")
        self.assertEqual(e.exception.code, 400)

    def test_the_agent_makes_the_plan_and_the_calendar_holds_it(self):
        pid = "student_abc123"
        FakeDeveloperAPI.calls.clear()
        start = dt.date.today().isoformat()
        job = self.send("POST", "/api/profiles/%s/plans" % pid, answers(start_date=start, weeks=1, concerns=["focus"]))["job"]
        for _ in range(100):
            st = self.get("/api/jobs/%s?profile=%s" % (job, pid))
            if st["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
        self.assertEqual(st["status"], "done", st)
        self.assertEqual(len(FakeDeveloperAPI.calls), 2)  # asked, then asked to repair
        call = FakeDeveloperAPI.calls[0]["body"]
        self.assertEqual((call["space"], call["bot"], call["temp_thread"]), ("sp1", "bot1", True))
        plan = self.get("/api/profiles/%s" % pid)["plan"]
        self.assertEqual(plan["generated_by"]["kind"], "agent")
        self.assertEqual(plan["generated_by"]["rounds"], 2)
        today = self.get("/api/profiles/%s/day/%s" % (pid, start))
        self.assertEqual(len(today["last7"]), 7)
        cal = self.get("/api/profiles/%s/calendar?from=%s&to=%s" % (pid, start, plan["end_date"]))["days"]
        self.assertEqual(len(cal), 7)
        some = next(x for d in cal.values() for x in d)
        self.assertTrue(self.send("PATCH", "/api/profiles/%s/sessions/%s" % (pid, some["id"]), {"done": True})["done"])
        reloaded = server.Store(self.tmp).db["profiles"][pid]["calendar"]
        self.assertTrue(next(x for d in reloaded.values() for x in d if x["id"] == some["id"])["done"])

    def test_the_aseman_person_is_me(self):
        req = urllib.request.Request(self.base + "/api/profiles/me", headers={"X-Aseman-User": "acc_42abc"})
        self.assertEqual(json.load(urllib.request.urlopen(req)), {"exists": False})
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get("/api/profiles/me")  # no person named by the gateway
        self.assertEqual(e.exception.code, 400)
        self.assertEqual(self.app.store.profile("u_acc_42abc"), None)

    def test_elpian_bundle_is_served_as_is(self):
        if not os.path.isfile(server.ELPIAN):
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(self.base + "/elpian/app.js")
            self.assertEqual(e.exception.code, 404)
            return
        r = urllib.request.urlopen(self.base + "/elpian/app.js")
        self.assertIn("javascript", r.headers["Content-Type"])
        with open(server.ELPIAN, "rb") as f:
            self.assertEqual(r.read(), f.read())

    def test_static_and_bad_ids(self):
        page = urllib.request.urlopen(self.base + "/").read().decode()
        self.assertIn('dir="rtl"', page)
        self.assertIn("app.js", urllib.request.urlopen(self.base + "/../server.py").read().decode())  # no escape: index served
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get("/api/profiles/../x")
        self.assertIn(e.exception.code, (400, 404))


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    if result.wasSuccessful():
        print("%d passed" % result.testsRun)
        sys.exit(0)
    print("%d failed" % (len(result.failures) + len(result.errors)))
    sys.exit(1)
