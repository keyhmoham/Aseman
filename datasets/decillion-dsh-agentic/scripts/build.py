#!/usr/bin/env python3
"""Materialize data/samples.jsonl into training rows (OpenAI / Hugging Face chat format).

    python3 scripts/build.py [--tools relevant|full] [--no-reasoning] [--args-string] [--val 0.02]

Each row: {"id", "category", "tools": [OpenAI function specs], "messages": [system, user, ...]}.
The system message is the exact prompt dsh builds (prefix + Decillion persona + suffix,
plus the agent's notes); after the first user message come dsh's own runtime-context and
time messages, as the real runtime sends them. Works with tokenizer.apply_chat_template(
messages, tools=tools) for Qwen chat templates.
"""

import argparse, gzip, hashlib, json, os, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dshlib as L  # noqa: E402

RUNTIME_CONTEXT = open(os.path.join(L.ASSETS, 'system', 'runtime_context.txt'), encoding='utf-8').read()
TIME_NOTE = open(os.path.join(L.ASSETS, 'system', 'time_note.txt'), encoding='utf-8').read()


def system_message(s):
    text = L.system_prompt(s)
    notes = L.notes_text(s.get('notes'))
    if notes:
        text += '\n\n' + notes
    return {'role': 'system', 'content': text}


def cwd_of(s):
    if s['mode'] == 'personal':
        return '/data/people/' + (s['session'].get('space') or 'person')
    return '/data/spaces/' + s['session']['space']


def tool_specs(s, mode):
    if mode == 'full':
        names = [n for n, t in L.TOOLS.items() if available_full(s, n)]
    else:
        names = s['tools']
    specs = [L.as_openai(L.TOOLS[n]) for n in sorted(names)]
    specs += [L.as_openai(t) for t in s.get('app_tools', [])]
    return specs


def available_full(s, name):
    from gen_common import Sample, Gen
    probe = Sample.__new__(Sample)
    probe.mode, probe.flags, probe.agent, probe.app_defs = s['mode'], s['flags'], s['agent'], {}
    return Sample.available(probe, name)


def materialize(s, tools='relevant', reasoning=True, args_string=False):
    msgs = [system_message(s)]
    first = True
    for m in s['messages']:
        if m['role'] == 'user':
            msgs.append({'role': 'user', 'content': m['content']})
            if first:
                ctx = RUNTIME_CONTEXT.replace('{CWD}', cwd_of(s))
                msgs.append({'role': 'user', 'content': ctx})
                when = m.get('time', '2026-11-21T10:00:00Z').replace('Z', '+00:00[UTC]')
                note = TIME_NOTE.replace('{TURN}', '1').replace('{TIME}', when)
                msgs.append({'role': 'user', 'content': note})
                first = False
        elif m['role'] == 'assistant':
            out = {'role': 'assistant', 'content': m.get('content') or ''}
            if reasoning and m.get('reasoning_content'):
                out['reasoning_content'] = m['reasoning_content']
            if m.get('tool_calls'):
                calls = []
                for tc in m['tool_calls']:
                    a = tc['function']['arguments']
                    a = json.dumps(a, ensure_ascii=False) if args_string else a
                    calls.append({'id': tc['id'], 'type': 'function', 'function': {'name': tc['function']['name'], 'arguments': a}})
                out['tool_calls'] = calls
            msgs.append(out)
        else:
            msgs.append({'role': 'tool', 'tool_call_id': m['tool_call_id'], 'name': m['name'], 'content': m['content']})
    return {'id': s['id'], 'category': s['category'], 'language': s['language'], 'tools': tool_specs(s, tools), 'messages': msgs}


def split_of(sid, val):
    h = int(hashlib.sha1(sid.encode()).hexdigest()[:8], 16) / 0xffffffff
    return 'validation' if h < val else 'train'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tools', choices=['relevant', 'full'], default='relevant')
    ap.add_argument('--no-reasoning', action='store_true')
    ap.add_argument('--args-string', action='store_true')
    ap.add_argument('--val', type=float, default=0.02)
    ap.add_argument('--samples', default=os.path.join(L.ROOT, 'data', 'samples.jsonl.gz'))
    ap.add_argument('--out', default=os.path.join(L.ROOT, 'dist'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    files = {k: gzip.open(os.path.join(a.out, k + '.jsonl.gz'), 'wt', encoding='utf-8') for k in ('train', 'validation')}
    stats = {'train': Counter(), 'validation': Counter()}
    for line in (gzip.open if a.samples.endswith('.gz') else open)(a.samples, 'rt', encoding='utf-8'):
        s = json.loads(line)
        row = materialize(s, a.tools, not a.no_reasoning, a.args_string)
        k = split_of(s['id'], a.val)
        files[k].write(json.dumps(row, ensure_ascii=False) + '\n')
        stats[k][s['category']] += 1
    for f in files.values():
        f.close()
    out = {k: {'total': sum(v.values()), 'by_category': dict(sorted(v.items()))} for k, v in stats.items()}
    out['options'] = {'tools': a.tools, 'reasoning': not a.no_reasoning, 'args_string': a.args_string}
    json.dump(out, open(os.path.join(a.out, 'stats.json'), 'w'), indent=1)
    print(json.dumps({k: out[k]['total'] for k in ('train', 'validation')}))


if __name__ == '__main__':
    main()
