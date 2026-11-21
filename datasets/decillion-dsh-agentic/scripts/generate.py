#!/usr/bin/env python3
"""Generate the compact samples (data/samples.jsonl) from every scenario family.

    python3 scripts/generate.py [--seed 7] [--scale 1.0] [--only family,...]

Deterministic for a seed. Each family has a target count (scaled); duplicates
(same messages) are dropped, so families with little variation yield fewer.
"""

import argparse
import hashlib
import importlib
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_common import Gen  # noqa: E402

MODULES = ['scen_dev', 'scen_people', 'scen_team', 'scen_memory', 'scen_present', 'scen_apps', 'scen_platform',
           'scen_personal', 'scen_safety', 'scen_session']


def families():
    out = {}
    for m in MODULES:
        try:
            mod = importlib.import_module(m)
        except ModuleNotFoundError as e:
            if e.name == m:
                continue
            raise
        for k, v in mod.SCENARIOS.items():
            assert k not in out, k
            out[k] = v
    return out


def fingerprint(sample):
    msgs = [{k: v for k, v in m.items() if k not in ('time', 'tool_call_id')} for m in sample['messages']]
    msgs = json.loads(json.dumps(msgs))
    import re as _re
    for m in msgs:
        if m['role'] == 'user':
            # the room around the turn varies freely; the conversation itself must differ
            m['content'] = _re.sub(r'<(where_you_are|now)>.*?</\1>', '', m['content'], flags=_re.S)
            m['content'] = _re.sub(r'(^|\n)[a-z]+: ', r'\1P: ', m['content'])
    for m in msgs:
        for tc in m.get('tool_calls', []):
            tc.pop('id', None)
    # ids and clocks differ per sample; strip 32/12-hex ids so near-identical samples collapse
    import re
    from gen_common import PEOPLE
    names = re.compile(r'\b(' + '|'.join(PEOPLE) + r')\b')
    for m in msgs:
        if isinstance(m.get('content'), str):
            m['content'] = names.sub('P', m['content'])
    text = json.dumps([msgs, sample['agent'].get('name')], sort_keys=True, ensure_ascii=False)
    text = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', 'U', text)
    text = re.sub(r'\b[0-9a-f]{12,32}\b', 'ID', text)
    text = re.sub(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', 'T', text)
    text = re.sub(r'call_[0-9a-f]{8}_\d+', 'C', text)
    text = re.sub(r'\d', '0', text)
    return hashlib.sha1(text.encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--scale', type=float, default=1.0)
    ap.add_argument('--only', default='')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'data', 'samples.jsonl.gz'))
    args = ap.parse_args()
    fams = families()
    only = [x for x in args.only.split(',') if x]
    seen, rows, counts = set(), [], Counter()
    for name in sorted(fams):
        if only and name not in only:
            continue
        fn, target = fams[name]
        want = max(1, int(target * args.scale))
        tries = 0
        while counts[name] < want and tries < want * 6:
            tries += 1
            seed = int(hashlib.sha1(f"{args.seed}:{name}:{tries}".encode()).hexdigest()[:12], 16)
            sample = fn(Gen(seed))
            fp = fingerprint(sample)
            if fp in seen:
                continue
            seen.add(fp)
            counts[name] += 1
            sample['id'] = f"dsh-{name}-{counts[name]:04d}"
            rows.append(sample)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    import gzip
    opener = gzip.open if args.out.endswith('.gz') else open
    with opener(args.out, 'wt', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    for k in sorted(counts):
        print(f"{k:40s} {counts[k]:5d} / {max(1, int(fams[k][1] * args.scale))}")
    print('total', len(rows), '->', args.out)


if __name__ == '__main__':
    main()
