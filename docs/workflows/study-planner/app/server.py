"""The study planner's server: the curriculum and catalogs, the students'
plans and calendars, and the jobs that ask the Planner agent for a plan.

Standard library only. Settings come from config.json beside this file
(written by the workflow), then the environment; the developer key is read
from the secrets file the workflow wrote, never from config.json.
"""

import datetime as dt
import json
import os
import re
import secrets as rnd
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import agent
import planner

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLIC = os.path.join(HERE, "public")
PID = re.compile(r"^[a-zA-Z0-9_-]{8,64}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".svg": "image/svg+xml", ".json": "application/json", ".png": "image/png", ".ico": "image/x-icon", ".webmanifest": "application/manifest+json"}


def read_env_file(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return out


def load_config():
    cfg = {"product": "آسمان‌درس", "port": 8080, "data_dir": os.path.join(HERE, ".data"), "mode": "agent", "rounds": 3,
           "api_url": "", "space": "", "planner_bot": "", "room": "", "secrets_file": "", "academic_year": ""}
    try:
        with open(os.path.join(HERE, "config.json"), encoding="utf-8") as f:
            cfg.update({k: v for k, v in json.load(f).items() if v not in (None, "")})
    except (OSError, ValueError):
        pass
    for key, env in (("port", "PORT"), ("data_dir", "DATA_DIR"), ("mode", "PLANNER_MODE"), ("api_url", "ASEMAN_DEVELOPER_API_URL"),
                     ("space", "PLANNER_SPACE"), ("planner_bot", "PLANNER_BOT"), ("room", "PLANNER_ROOM"), ("secrets_file", "SECRETS_FILE")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    secret = read_env_file(cfg["secrets_file"]) if cfg["secrets_file"] else {}
    cfg["key"] = os.environ.get("ASEMAN_DEVELOPER_KEY") or secret.get("ASEMAN_DEVELOPER_KEY", "")
    if not cfg["api_url"]:
        cfg["api_url"] = secret.get("ASEMAN_DEVELOPER_API_URL", "")
    cfg["port"] = int(cfg["port"])
    cfg["rounds"] = int(cfg["rounds"])
    return cfg


class Store:
    """One JSON file under the data folder (kept across reinstalls)."""

    def __init__(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, "db.json")
        self.lock = threading.Lock()
        try:
            with open(self.path, encoding="utf-8") as f:
                self.db = json.load(f)
        except (OSError, ValueError):
            self.db = {"profiles": {}}

    def _save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.db, f, ensure_ascii=False)
        os.replace(tmp, self.path)

    def profile(self, pid):
        return self.db["profiles"].get(pid)

    def save_plan(self, pid, plan):
        """The plan becomes the active one and its days replace the calendar
        from its first day on; earlier days (and their ticks) stay."""
        with self.lock:
            p = self.db["profiles"].setdefault(pid, {"plans": [], "calendar": {}})
            cal = {d: v for d, v in p["calendar"].items() if d < plan["start_date"]}
            cal.update(plan["calendar"])
            p["calendar"] = cal
            stored = {k: v for k, v in plan.items() if k != "calendar"}
            p["plans"] = [x for x in p["plans"] if x["id"] != plan["id"]][-9:] + [stored]
            p["active"] = plan["id"]
            p["updated_at"] = plan["created_at"]
            self._save()

    def set_done(self, pid, sid, done):
        with self.lock:
            p = self.db["profiles"].get(pid) or {}
            for day in p.get("calendar", {}).values():
                for x in day:
                    if x["id"] == sid:
                        x["done"] = bool(done)
                        x["done_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds") if done else None
                        self._save()
                        return x
        return None


class App:
    def __init__(self, cfg=None, client=None):
        self.cfg = cfg or load_config()
        self.curriculum_base = planner.load_json("curriculum.json")
        self.goals = planner.load_json("goals.json")
        self.concerns = planner.load_json("concerns.json")
        self.store = Store(self.cfg["data_dir"])
        self.client = client or agent.Client(self.cfg["api_url"], self.cfg["key"], self.cfg["space"], self.cfg["planner_bot"], self.cfg["room"])
        self.jobs = {}
        self.jobs_lock = threading.Lock()

    @property
    def curriculum(self):
        overrides = None
        path = os.path.join(self.cfg["data_dir"], "curriculum.overrides.json")
        try:
            with open(path, encoding="utf-8") as f:
                overrides = json.load(f)
        except (OSError, ValueError):
            pass
        return planner.merge_overrides(self.curriculum_base, overrides)

    @property
    def agent_ready(self):
        return self.cfg["mode"] == "draft" or self.client.ready

    # ------------------------------------------------------------ jobs

    def start_job(self, pid, answers):
        ctx = planner.prepare(answers, self.curriculum, self.goals, self.concerns)
        if not self.agent_ready:
            raise planner.PlanError("مشاور هوشمند برنامه‌ریز هنوز به این اپ وصل نشده است.")
        job = {"id": "job_" + rnd.token_hex(8), "profile": pid, "status": "queued", "round": 0, "created": time.time(),
               "stages": [], "plan_id": None, "error": None}
        with self.jobs_lock:
            for old in [k for k, v in self.jobs.items() if time.time() - v["created"] > 3600]:
                del self.jobs[old]
            self.jobs[job["id"]] = job
        threading.Thread(target=self._run_job, args=(job, ctx), daemon=True).start()
        return job

    def _run_job(self, job, ctx):
        def progress(stage, n):
            job["status"], job["round"] = stage, n
            job["stages"].append({"stage": stage, "round": n, "at": time.time()})
        try:
            plan_id = "p" + dt.datetime.now().strftime("%y%m%d%H%M%S") + rnd.token_hex(2)
            if self.cfg["mode"] == "draft":
                progress("thinking", 1)
                out, log, by = planner.draft(ctx), [], {"kind": "draft"}
                errors, _, out = planner.check(ctx, out)
                if errors:
                    raise agent.AgentError("; ".join(errors))
            else:
                out, log = agent.plan_with_agent(ctx, self.client.ask, self.cfg["rounds"], progress)
                by = {"kind": "agent", "agent": "Planner", "space": self.cfg["space"], "bot": self.cfg["planner_bot"], "rounds": len(log)}
            job["status"] = "saving"
            plan = planner.assemble(ctx, out, plan_id, dict(by, log=log))
            self.store.save_plan(job["profile"], plan)
            job["plan_id"], job["status"] = plan_id, "done"
        except agent.AgentError as e:
            job["status"], job["error"] = "failed", str(e)
        except Exception as e:  # noqa: BLE001 — the job reports, the server lives on
            traceback.print_exc()
            job["status"], job["error"] = "failed", "internal error: %s" % e

    # ------------------------------------------------------------ views

    def active_plan(self, p):
        for x in reversed(p.get("plans", [])):
            if x["id"] == p.get("active"):
                return x
        return None

    def day_view(self, p, date):
        sessions = (p or {}).get("calendar", {}).get(date, [])
        minutes = sum(x["minutes"] for x in sessions)
        done = sum(x["minutes"] for x in sessions if x.get("done"))
        return {"date": date, "sessions": sessions, "minutes": minutes, "done_minutes": done}


class Handler(BaseHTTPRequestHandler):
    app = None
    server_version = "StudyPlanner/1.0"

    def log_message(self, fmt, *args):
        if os.environ.get("PLANNER_QUIET") != "1":
            super().log_message(fmt, *args)

    def send(self, code, body, kind="application/json; charset=utf-8", cache="no-store"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def fail(self, code, message):
        self.send(code, {"error": message})

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 256 * 1024:
            raise planner.PlanError("درخواست بیش از حد بزرگ است.")
        try:
            return json.loads(self.rfile.read(n).decode() or "{}")
        except ValueError:
            raise planner.PlanError("درخواست نامعتبر است.")

    def route(self, method):
        app = self.app
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/healthz":
            return self.send(200, {"ok": True, "agent": app.agent_ready, "mode": app.cfg["mode"]})
        if not parts or parts[0] != "api":
            return self.static(url.path) if method in ("GET", "HEAD") else self.fail(405, "method not allowed")
        api = parts[1:]
        if method == "GET" and api == ["meta"]:
            cur = app.curriculum
            return self.send(200, {"product": app.cfg["product"], "academic_year": app.cfg["academic_year"] or cur["source"]["year"],
                                   "stages": cur["stages"], "fields": cur["fields"], "grades": {k: {"name": v["name"], "nick": v.get("nick"), "needs_field": "fields" in v} for k, v in cur["grades"].items()},
                                   "categories": cur["categories"], "source": cur["source"], "agent": app.agent_ready, "mode": app.cfg["mode"]})
        if method == "GET" and api == ["curriculum"]:
            cur = app.curriculum
            grade = q.get("grade", "")
            courses = planner.courses_for(cur, int(grade) if grade.isdigit() else 0, q.get("field"))
            g = cur["grades"][str(int(grade))]
            return self.send(200, {"grade": int(grade), "grade_name": g["name"], "field": q.get("field") if "fields" in g else None,
                                   "field_name": (cur["fields"].get(q.get("field")) or {}).get("name") if "fields" in g else None,
                                   "courses": courses, "source": cur["source"]})
        if method == "GET" and api == ["goals"]:
            grade = int(q["grade"]) if q.get("grade", "").isdigit() else None
            return self.send(200, {"goals": [g for g in app.goals["goals"] if grade is None or grade in g["grades"]]})
        if method == "GET" and api == ["concerns"]:
            return self.send(200, app.concerns)
        if len(api) >= 2 and api[0] == "jobs" and method == "GET":
            job = app.jobs.get(api[1])
            if not job or job["profile"] != q.get("profile"):
                return self.fail(404, "no such job")
            return self.send(200, {k: v for k, v in job.items() if k != "profile"})
        if len(api) >= 2 and api[0] == "profiles":
            pid = api[1]
            if not PID.match(pid):
                return self.fail(400, "invalid profile id")
            rest = api[2:]
            p = app.store.profile(pid)
            if method == "GET" and rest == []:
                if not p:
                    return self.send(200, {"exists": False})
                return self.send(200, {"exists": True, "plan": app.active_plan(p), "updated_at": p.get("updated_at")})
            if method == "POST" and rest == ["plans"]:
                job = app.start_job(pid, self.body())
                return self.send(202, {"job": job["id"], "status": job["status"]})
            if method == "GET" and rest == ["calendar"]:
                a, b = q.get("from", ""), q.get("to", "")
                if not (DATE.match(a) and DATE.match(b)):
                    return self.fail(400, "from and to are YYYY-MM-DD")
                cal = (p or {}).get("calendar", {})
                return self.send(200, {"days": {d: v for d, v in cal.items() if a <= d <= b}})
            if method == "GET" and len(rest) == 2 and rest[0] == "day":
                if not DATE.match(rest[1]):
                    return self.fail(400, "date is YYYY-MM-DD")
                view = app.day_view(p, rest[1])
                week = []
                base = dt.date.fromisoformat(rest[1])
                for i in range(-6, 1):
                    d = (base + dt.timedelta(days=i)).isoformat()
                    week.append(dict(app.day_view(p, d), sessions=None))
                view["last7"] = week
                return self.send(200, view)
            if method == "PATCH" and len(rest) == 2 and rest[0] == "sessions":
                x = app.store.set_done(pid, rest[1], self.body().get("done"))
                return self.send(200, x) if x else self.fail(404, "no such session")
        return self.fail(404, "not found")

    def static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        full = os.path.normpath(os.path.join(PUBLIC, path.lstrip("/")))
        if not full.startswith(PUBLIC + os.sep) or not os.path.isfile(full):
            full = os.path.join(PUBLIC, "index.html")
        with open(full, "rb") as f:
            data = f.read()
        self.send(200, data, TYPES.get(os.path.splitext(full)[1], "application/octet-stream"), "no-cache")

    def handle_method(self, method):
        try:
            self.route(method)
        except planner.PlanError as e:
            self.fail(400, str(e))
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            self.fail(500, "internal error")

    def do_GET(self):
        self.handle_method("GET")

    def do_HEAD(self):
        self.handle_method("HEAD")

    def do_POST(self):
        self.handle_method("POST")

    def do_PATCH(self):
        self.handle_method("PATCH")


def make_server(app, host="0.0.0.0", port=None):
    handler = type("BoundHandler", (Handler,), {"app": app})
    return ThreadingHTTPServer((host, app.cfg["port"] if port is None else port), handler)


if __name__ == "__main__":
    application = App()
    httpd = make_server(application)
    print("study planner on :%d (mode %s, agent %s)" % (application.cfg["port"], application.cfg["mode"], "ready" if application.agent_ready else "not configured"), flush=True)
    httpd.serve_forever()
