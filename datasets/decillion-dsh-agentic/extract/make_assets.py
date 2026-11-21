#!/usr/bin/env python3
"""Turn the captures of a real dsh runtime boot (extract/*.mjs) into the dataset's assets.

Inputs (a scratch directory): captured.json (capture.mjs), persona_parts.json (persona.mjs),
builtins.json / person.json (the Go catalogs), metas.json / policy.json (actions + agent policy).
"""
import json, sys, os, re

S, D = sys.argv[1], sys.argv[2]
A = os.path.join(D, 'assets')
cap = json.load(open(os.path.join(S, 'captured.json')))
parts = json.load(open(os.path.join(S, 'persona_parts.json')))
builtins = {t['name']: t for t in json.load(open(os.path.join(S, 'builtins.json')))}
person = {t['name']: t for t in json.load(open(os.path.join(S, 'person.json')))}

# --- system prompt: dsh prefix + Decillion persona + dsh suffix ---------------------------
chk = parts['checks']
assert all(v['found'] for v in chk.values())
prefix = chk['lead']['prefix']
assert prefix == chk['specialist']['prefix'] == chk['personal']['prefix']
suffix = chk['lead']['suffix']
assert suffix == chk['specialist']['suffix'] == chk['personal']['suffix']
prefix_t = prefix.replace('decillion-128k', '{MODEL}')
assert '{MODEL}' in prefix_t
open(os.path.join(A, 'system', 'prefix.txt'), 'w').write(prefix_t)
open(os.path.join(A, 'system', 'suffix.txt'), 'w').write(suffix)
for k, v in parts['sections'].items():
    open(os.path.join(A, 'system', 'sections', k + '.md'), 'w').write(v)
json.dump({'room': parts['reference'], 'personal': parts['reference_personal']},
          open(os.path.join(A, 'system', 'persona_reference.json'), 'w'), indent=1, ensure_ascii=False)

# --- tools ----------------------------------------------------------------------------------
RUNTIME = {
 'bash': 'sandbox', 'read_file': 'sandbox', 'write_file': 'sandbox', 'edit_file': 'sandbox', 'list_files': 'sandbox',
 'glob': 'sandbox', 'grep': 'sandbox', 'read_image': 'sandbox',
 'post_message': 'messaging', 'read_messages': 'messaging', 'search_messages': 'messaging', 'send_dm': 'messaging',
 'read_dm': 'messaging', 'ask_user': 'messaging',
 'decillion_api_search': 'api', 'decillion_api_call': 'api',
 'list_team': 'team', 'delegate_task': 'team', 'recruit_agent': 'team', 'hire_agent': 'team',
 'remember': 'memory', 'recall': 'memory', 'rewrite_notes': 'memory',
 'timeline_search': 'timeline', 'timeline_entry': 'timeline',
 'jev_decide': 'decide', 'create_gadget': 'creator', 'list_gadgets': 'creator',
 'load_skill': 'skills', 'hand_to_workspace': 'workspace',
}
DSH = {'todo_write', 'create_goal', 'get_goal', 'update_goal', 'spawn_teammate', 'send_message', 'list_agents',
       'wait_agent', 'interrupt_agent', 'team_task_create', 'team_task_list', 'team_task_get', 'team_task_update',
       'workflow', 'session_search', 'session_event_search', 'session_trace', 'session_event_trace',
       'session_event_read', 'present', 'ask_user_question', 'plugin_manager'}
AVOID = {
 'present': "dsh's own deliverable card points at the runtime's machine, not the space computer: deliver files with file_send.",
 'ask_user_question': "dsh's own question tool has no answerer in Decillion (fails closed): use ask_user.",
 'plugin_manager': "changes the runtime's dsh profile for every session; never part of a Decillion task.",
 'message_send': 'posts as the platform (decillion); speak in the room with post_message.',
}
seen = {}
for key in ('lead', 'specialist', 'personal'):
    for t in cap[key]['body']['tools']:
        f = t['function']
        seen.setdefault(f['name'], {'name': f['name'], 'description': f['description'], 'parameters': f['parameters'], 'offered_to': []})
        if key not in seen[f['name']]['offered_to']:
            seen[f['name']]['offered_to'].append(key)
for example in ('weather__forecast', 'translator'):
    seen.pop(example, None)  # the capture's example apps; real apps are per space (see example_apps.json)
out = []
for name in sorted(seen):
    t = seen[name]
    if name in RUNTIME:
        t['origin'], t['group'] = 'decillion-runtime', RUNTIME[name]
    elif name in DSH:
        t['origin'], t['group'] = 'dsh', 'dsh'
    elif name in builtins:
        t['origin'], t['group'] = 'platform-builtin', 'platform'
    elif name in person:
        t['origin'], t['group'] = 'platform-person', 'person'
    else:
        raise SystemExit('unclassified tool ' + name)
    if name in AVOID:
        t['avoid'] = AVOID[name]
    out.append(t)
json.dump(out, open(os.path.join(A, 'tools', 'dsh_tools.json'), 'w'), indent=1, ensure_ascii=False)
print('tools', len(out))

# --- the API catalog (decillion_api_search / decillion_api_call) ------------------------------
metas = json.load(open(os.path.join(S, 'metas.json')))
pol = json.load(open(os.path.join(S, 'policy.json')))
schemas = json.load(open(sys.argv[3]))
cat = []
for k in sorted(metas):
    room, personal = pol[k]
    if not personal:
        continue
    ns, a = k.split('.', 1)
    cat.append({'namespace': ns, 'name': a, 'summary': metas[k], 'input': schemas.get(k), 'room_agent': room, 'personal': personal})
json.dump(cat, open(os.path.join(A, 'api', 'catalog.json'), 'w'), indent=1, ensure_ascii=False)
print('actions', len(cat), 'room', sum(c['room_agent'] for c in cat))
