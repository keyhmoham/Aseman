#!/usr/bin/env python3
"""Validate the dataset: persona parity with the real runtime, tool calls against their exact schemas, API actions against the catalog and policy, conversation structure."""

import json, os, sys
from collections import Counter
import jsonschema
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dshlib as L  # noqa: E402

AVOID = {n for n, t in L.TOOLS.items() if t.get("avoid")}
errors = Counter()
examples = {}


def err(kind, sid, msg):
    errors[kind] += 1
    examples.setdefault(kind, f"{sid}: {msg}")


def persona_parity():
    ref = json.load(open(os.path.join(L.ASSETS, "system", "persona_reference.json"), encoding="utf-8"))
    for r in ref["room"]:
        if L.persona_for(r["agent"]) != r["persona"]:
            err("persona_mismatch", r["agent"]["name"], "persona_for differs from the runtime")
    for r in ref["personal"]:
        if L.personal_persona(r["system"]) != r["persona"]:
            err("persona_mismatch", "personal", "personal_persona differs from the runtime")


def check_call(s, name, args, result, schemas):
    sid = s["id"]
    if name not in schemas:
        return err("tool_not_offered", sid, name)
    if name in AVOID:
        err("avoided_tool_used", sid, name)
    try:
        jsonschema.validate(args, schemas[name])
    except jsonschema.ValidationError as e:
        err("bad_arguments", sid, f"{name}: {e.message}")
    if name == "decillion_api_call":
        full = str(args.get('namespace')) + '.' + str(args.get('action'))
        scope = "personal" if s["mode"] == "personal" else "room"
        if not L.api_lookup(scope, full) and not result.startswith("Error:"):
            err("api_action_not_allowed", sid, full)
        if not result.startswith("Error:") and not result.startswith(L.NOTICE):
            err("api_result_not_enveloped", sid, full)
    if name == "decillion_api_search":
        scope = "personal" if s["mode"] == "personal" else "room"
        if result != L.api_search_out(scope, args["query"], args.get("namespace")):
            err("api_search_mismatch", sid, args["query"])


CONCLUDES = ("Asked. Your work pauses here", "Not run yet:")


def check_sample(s):
    sid = s["id"]
    schemas = {n: L.TOOLS[n]["parameters"] for n in s["tools"] if n in L.TOOLS}
    apps = {t["name"]: t for t in s.get("app_tools", [])}
    schemas.update({n: t["parameters"] for n, t in apps.items()})
    unknown = [n for n in s["tools"] if n not in L.TOOLS]
    if unknown:
        err("unknown_tool", sid, unknown)
    msgs = s["messages"]
    if not msgs or msgs[0]["role"] != "user":
        err("structure", sid, "must start with a user message")
    ids = set()
    i = 0
    while i < len(msgs):
        m = msgs[i]
        if m["role"] == "assistant" and m.get("tool_calls"):
            calls = m["tool_calls"]
            results = msgs[i + 1:i + 1 + len(calls)]
            if len(results) != len(calls) or any(r["role"] != "tool" for r in results):
                err("structure", sid, "tool calls without their results")
                return
            concluded = False
            for tc, r in zip(calls, results):
                if tc["id"] in ids or r["tool_call_id"] != tc["id"] or r["name"] != tc["function"]["name"]:
                    err("call_ids", sid, tc["id"])
                ids.add(tc["id"])
                name, args = tc["function"]["name"], tc["function"]["arguments"]
                check_call(s, name, args, r["content"], schemas)
                if name in apps and not r["content"].startswith("Error:") and not r["content"].startswith(L.NOTICE):
                    err("app_result_not_enveloped", sid, name)
                if r["content"].startswith(CONCLUDES):
                    concluded = True
            i += 1 + len(calls)
            if concluded and i < len(msgs) and msgs[i]["role"] != "user":
                err("turn_not_concluded", sid, "the agent kept going after ask_user / an approval request")
            continue
        if m["role"] == "tool":
            err("structure", sid, "a tool result without its call")
        i += 1
    last = msgs[-1]
    ok_end = (last["role"] == "assistant" and not last.get("tool_calls")) or (last["role"] == "tool" and last["content"].startswith(CONCLUDES))
    if not ok_end:
        err("structure", sid, "must end with a final answer or a concluding question")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(L.ROOT, "data", "samples.jsonl.gz")
    persona_parity()
    n = 0
    import gzip
    for line in (gzip.open if path.endswith(".gz") else open)(path, "rt", encoding="utf-8"):
        check_sample(json.loads(line))
        n += 1
    print(f"checked {n} samples")
    for k, v in sorted(errors.items()):
        print(f"  {k}: {v}  e.g. {examples[k][:300]}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
