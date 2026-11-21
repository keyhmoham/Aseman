"""App UI (windows and gadgets), platforms of the person's own, and the whole Decillion API."""

import os
from gen_common import room, specialist, LEAD, j, go_json
import dshlib as L

TASKS = {n[5:-4]: open(os.path.join(L.ASSETS, 'appui', n), encoding='utf-8').read()
         for n in os.listdir(os.path.join(L.ASSETS, 'appui')) if n.startswith('task-')}
VERIFY = open(os.path.join(L.ASSETS, 'appui', 'verify-not-ready.txt'), encoding='utf-8').read()
API_URL = 'http://decillion:8080'
BILLING = ("Calls with a request's X-Decillion-User-Token are billed to the person using the app; background calls with "
           "DECILLION_APP_KEY to the person who asked for it.")

BRIEFS = [
    ('a habit tracker', 'Habits', 'Habit tracker for the team: add habits, check them off daily, see a 7-day streak per person. Done when people can add, check and see streaks.'),
    ('an order board', 'Orders', 'Order board for the café: open orders as cards, move them through new → making → ready, show waiting time. Done when staff can move every order and see its age.'),
    ('a reading list', 'Reading list', 'Reading list: add books, mark read, rate 1-5, filter by status. Done when a person can add, rate and filter.'),
    ('a sprint dashboard', 'Sprint', 'Sprint dashboard: tasks by status, a burndown chart and who owns what. Done when the board and chart show the current sprint.'),
]


def create_result(dir_, title, kind, ui, placement, task_key, audience='space'):
    hint = 'opens it on the desk' if kind == 'app' else f"registers it as a compact frameless gadget ({placement})"
    nxt = ("Build the app now, exactly as the task says (or hand the whole task to a developer agent of the space with this dir and TASK.md): "
           "plan, build, test, drive it end to end with decillion-elpian, write READY.json. Then call appui_publish {\"dir\": \"" + dir_ +
           "\"}: the platform verifies it and " + hint + ", or answers with what to fix.")
    out = {'state': 'building', 'builder': 'agents', 'id': dir_.rsplit('/', 1)[1], 'dir': dir_, 'title': title, 'port': 8787, 'mode': 'new',
           'ui': ui, 'kind': kind, 'placement': placement, 'audience': audience, 'task': TASKS[task_key].replace('{DIR}', dir_)[:12000],
           'next': nxt, 'server_api': {'url': API_URL, 'background': True, 'billing': BILLING}}
    return L.json.dumps(out, separators=(',', ':'), ensure_ascii=False)


def appui_build(g):
    what, title, brief = g.choice(BRIEFS)
    gadget = g.chance(0.35)
    s, w = room(g, 'appui.build_publish', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD,
                extra_tools=['appui_create', 'appui_publish', 'bash', 'write_file'] + (['create_gadget', 'list_gadgets'] if gadget else []))
    pid = g.hex(12)
    dir_ = f"/workspace/appui/{pid}"
    s.user(f"Build us {what}{' as a small gadget' if gadget else ''}.")
    if gadget:
        s.step(('list_gadgets', {}, 'No gadgets here yet.'), think='One gadget per need: check what exists.')
        s.step(('create_gadget', {'brief': brief + ' Keep the UI compact like a mobile widget.', 'title': title, 'placement': 'chat'},
                create_result(dir_, title, 'gadget', 'elpian', 'chat', 'elpian-gadget-space-new')))
    else:
        s.step(('appui_create', {'brief': brief, 'title': title}, create_result(dir_, title, 'app', 'elpian', '', 'elpian-app-space-new')),
               think='A lasting interactive UI: the App UI pipeline, Elpian by default.')
    s.step(('write_file', {'path': f"{dir_}/PLAN.md", 'content': f"# Plan\n\n1. Server: Node, JSON store, REST for {title.lower()}.\n2. Elpian frontend in elpian/src.\n3. Tests, e2e scenarios, READY.json.\n"}, f"wrote {dir_}/PLAN.md"))
    s.step(('bash', {'command': f"cd {dir_} && npm test --silent 2>&1 | tail -3 && node vendor/decillion-elpian/validate.mjs --program elpian/app.js --server http://127.0.0.1:8787 | tail -2"},
            L.bash_out(0, 'ℹ pass 11\nℹ fail 0\nℹ duration_ms 212.4\nok: 0 errors, 0 warnings\n')))
    s.step(('appui_publish', {'dir': dir_},
            ('error', 'spaces.ask: CONFLICT: appui not ready: the platform checked the app and it is not ready yet. Fix the root cause, run your tests again, rewrite READY.json and call appui_publish again.\n' + VERIFY.replace('{DIR}', dir_))))
    ready = {'ok': True, 'tested': True, 'title': title, 'port': 8787, 'start': 'node server.js', 'dir': '.', 'summary': brief.split(':')[0] + '.', 'ui': 'elpian', 'elpian': 'elpian/app.js'}
    s.step(('write_file', {'path': f"{dir_}/READY.json", 'content': L.json.dumps(ready, indent=2)}, f"wrote {dir_}/READY.json"),
           think='Not ready: READY.json was never written. Tests pass, so write it now.')
    prx = g.id()
    if gadget:
        proxy = f"/v1/proxy/{prx}/\nStarted the service with the start command; port 8787 is answering."
    else:
        from gen_common import web_window
        proxy = (f"/v1/proxy/{prx}/\nStarted the service with the start command; port 8787 is answering.\nOpened on the room desk as a card window: "
                 f"{web_window(g.hex(12), title, f'/v1/proxy/{prx}/')}. Arrange it with desk_arrange.")
    res = {'id': pid, 'dir': dir_, 'title': title, 'port': 8787, 'start': 'node server.js', 'summary': ready['summary'], 'tested': True, 'mode': 'new',
           'ui': 'elpian', 'kind': 'gadget' if gadget else 'app', 'placement': 'chat' if gadget else '', 'builder': 'agents',
           'next': 'To change this app later, call appui_create again with the same dir and a brief of the change. Build the change as its task says, then call appui_publish with the dir again.',
           'proxy': proxy, 'server_api': {'url': API_URL, 'background': True, 'billing': BILLING}}
    if gadget:
        res['gadget'] = {'id': g.id(), 'owner': w.sender['id'], 'scope': 'space', 'space_id': w.space['id'], 'name': title, 'placement': 'chat',
                         'ui': 'elpian', 'preview': f"/v1/proxy/{prx}/", 'entry': 'elpian/app.js', 'app_id': pid, 'status': 'installed',
                         'created_by': s.agent['name'], 'created_at': w.iso(9), 'updated_at': w.iso(9)}
    s.step(('appui_publish', {'dir': dir_}, go_json(res)))
    s.final(f"{title} is ready — {'pinned as a gadget over the chat' if gadget else 'open on the desk'}. Tell me what to change and I'll update it in place.")
    return s.done()


def offer_ui(g):
    """Not asked for a UI: answer first, then offer."""
    s, w = room(g, 'appui.offer_first', agent=LEAD)
    s.user('How many open support tickets do we have per category?')
    s.step(('bash', {'command': "cut -d, -f3 /workspace/support/tickets.csv | tail -n +2 | sort | uniq -c"}, L.bash_out(0, '     14 billing\n      9 delivery\n      4 login\n')))
    s.step(('show_card', {'type': 'list', 'title': 'Open tickets', 'items': [{'title': 'Billing', 'value': '14'}, {'title': 'Delivery', 'value': '9'}, {'title': 'Login', 'value': '4'}]},
            'showing the list card under your answer: now say the point in a sentence'))
    s.step(('ask_user', {'question': 'Want a live ticket tracker for this?', 'options': ['Create it', 'Not now']}, 'Asked. Your work pauses here; the conversation continues with their answer.'),
           think='They asked a question, not for an interface: answer, then offer.')
    return s.done()


ROOMS_NEW = [('support', 'Customer questions'), ('launch-week', 'Everything for launch week'), ('hiring', 'Candidates and interviews'),
             ('design-review', 'Weekly design critique'), ('invoices', 'Billing and invoices'), ('mobile', 'The Android app')]


def api_room_create(g):
    name, topic = g.choice(ROOMS_NEW)
    s, w = room(g, 'api.search_call', agent=LEAD)
    s.user(g.choice([f"Make a new room called {name} for {topic.lower()}.", f"Create a {name} room, topic: {topic.lower()}."]))
    q = g.choice(['room create', 'create room', 'new room space'])
    s.step(('decillion_api_search', {'query': q, 'namespace': 'spaces'}, L.api_search_out('room', q, 'spaces')),
           think='No dedicated tool for rooms: find the platform action, then call it.')
    rid = g.id()
    s.step(('decillion_api_call', {'namespace': 'spaces', 'action': 'room_create', 'body': {'space': w.space['id'], 'name': name, 'topic': topic}},
            L.api_call_out('spaces', 'room_create', {'room_id': rid})))
    s.final(f"Created the **{name}** room ({topic.lower()}).")
    return s.done()


def api_denied(g):
    s, w = room(g, 'api.policy_denied', agent=LEAD)
    act, ask = g.choice([('admin.logs', "Show me the node's server logs."), ('finance.transfer', 'Send 50 credits to Omid.'),
                         ('auth.login', 'Log in as Sara and check her inbox.')])
    ns, a = act.split('.')
    s.user(ask)
    s.step(('decillion_api_call', {'namespace': ns, 'action': a, 'body': {}},
            ('error', f"{act}: PERMISSION_DENIED: {act} is not part of the agent platform API")))
    reason = {'admin': 'node administration', 'finance': 'moving money', 'auth': "signing in as someone"}[ns]
    s.final(f"I can't do that: {reason} is never open to agents on Decillion. That's something you do yourself in the app.")
    return s.done()


def api_other_space(g):
    s, w = room(g, 'api.confined', agent=LEAD)
    other = g.id()
    s.user(f"List the rooms of our other project (space {other}).")
    s.step(('decillion_api_call', {'namespace': 'spaces', 'action': 'room_list', 'body': {'space': other}},
            ('error', 'spaces.room_list: PERMISSION_DENIED: an agent acts only inside the space of its turn: PERMISSION_DENIED: this works only inside its own space')))
    s.final("I can only work inside this space, so I can't read that project's rooms. Ask its own agent there, or your personal Decillion, which acts across your account.")
    return s.done()


SCENARIOS = {
    'appui.build_publish': (appui_build, 120),
    'appui.offer_first': (offer_ui, 10),
    'api.search_call': (api_room_create, 80),
    'api.policy_denied': (api_denied, 30),
    'api.confined': (api_other_space, 20),
}
