"""Tools around the Planner agent.

  python3 plan_tool.py check BRIEF.json ANSWER.json   the app's rules on a plan
                                                        (for the agent, before it answers)
  python3 plan_tool.py selftest                       the planner end to end, offline
  python3 plan_tool.py e2e http://127.0.0.1:8080      a real plan from the running app,
                                                        made by the Planner agent
                                                        (--allow-draft: accept draft mode)
"""

import json
import sys
import time
import urllib.request
import uuid

import agent
import planner


def ctx_from_brief(data):
    st = data["student"]
    return {"answers": {"courses": st["courses"], "weeks": st["weeks"]}, "settings": data["settings"],
            "slots": data["slots"], "refs": {k: {"text": v} for k, v in data["refs"].items()}}


def cmd_check(brief_path, answer_path):
    with open(brief_path, encoding="utf-8") as f:
        raw = f.read()
    data = agent.parse_reply(raw)
    with open(answer_path, encoding="utf-8") as f:
        out = agent.parse_reply(f.read())
    errors, warnings, _ = planner.check(ctx_from_brief(data), out)
    for w in warnings:
        print("warning:", w)
    for e in errors:
        print("error:", e)
    print("plan-ok" if not errors else "plan-invalid: %d errors" % len(errors))
    return 0 if not errors else 1


SAMPLE = {
    "name": "", "grade": 11, "field": "science", "goals": ["final_exam"], "concerns": ["focus", "sleep"],
    "availability": {"sat": [16, 17, 18], "sun": [16, 17], "mon": [17, 18, 19], "tue": [16, 17], "wed": [16, 17, 18], "thu": [10, 11, 16], "fri": [10, 11]},
    "weeks": 1,
}


def cmd_selftest():
    cur, goals, concerns = planner.load_json("curriculum.json"), planner.load_json("goals.json"), planner.load_json("concerns.json")
    ctx = planner.prepare(SAMPLE, cur, goals, concerns)
    replies = iter([json.dumps(planner.draft(ctx), ensure_ascii=False)])
    out, _ = agent.plan_with_agent(ctx, lambda body: "```json\n%s\n```" % next(replies))
    plan = planner.assemble(ctx, out, "selftest")
    assert plan["stats"]["sessions"] > 0 and len(plan["calendar"]) == 7
    print("selftest ok")
    return 0


def cmd_e2e(base, allow_draft=False):
    base = base.rstrip("/")
    pid = "e2e" + uuid.uuid4().hex[:12]
    body = dict(SAMPLE, start_date=time.strftime("%Y-%m-%d"))
    req = urllib.request.Request(base + "/api/profiles/%s/plans" % pid, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    job = json.load(urllib.request.urlopen(req, timeout=30))["job"]
    deadline = time.time() + 1200
    while time.time() < deadline:
        st = json.load(urllib.request.urlopen("%s/api/jobs/%s?profile=%s" % (base, job, pid), timeout=30))
        if st["status"] == "done":
            p = json.load(urllib.request.urlopen("%s/api/profiles/%s" % (base, pid), timeout=30))["plan"]
            if p["generated_by"]["kind"] != "agent" and not allow_draft:
                print("agent-plan-failed: the plan was not made by the Planner agent (mode %s)" % p["generated_by"]["kind"])
                return 1
            print("agent-plan-ok: %d sessions, %d rounds, by %s" % (p["stats"]["sessions"], p["generated_by"].get("rounds", 0), p["generated_by"]["kind"]))
            return 0
        if st["status"] == "failed":
            print("agent-plan-failed:", st["error"])
            return 1
        time.sleep(5)
    print("agent-plan-failed: timed out")
    return 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["check"] and len(args) == 3:
        sys.exit(cmd_check(args[1], args[2]))
    if args == ["selftest"]:
        sys.exit(cmd_selftest())
    if args[:1] == ["e2e"] and len(args) in (2, 3):
        sys.exit(cmd_e2e(args[1], "--allow-draft" in args))
    print(__doc__)
    sys.exit(2)
