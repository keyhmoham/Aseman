"""The sample builder and the pools scenarios draw from.

A sample is one dsh Session as the model sees it: one or more Decillion turns, each a
composed user message (turns.js composeMessage) followed by the agent's steps —
tool calls with the exact results the runtime returns — and its final answer.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import random

import dshlib as L

AGENTS = json.load(open(os.path.join(L.ASSETS, 'agents.json'), encoding='utf-8'))


def lead_def():
    import re
    spec = AGENTS['lead']
    get = lambda k: re.search(rf"^{k}: (.*)$", spec, re.M).group(1).strip()
    desc = get('description').strip("'").replace("''", "'")
    return {'name': get('name'), 'description': desc, 'instructions': get('instructions'), 'role': 'lead', 'lead': True}


LEAD = lead_def()
SPECIALISTS = {s['Username']: {'name': s['Name'], 'handle': s['Username'], 'description': s['Description'],
                               'instructions': s['Instructions'], 'role': 'specialist', 'lead': False}
               for s in AGENTS['samples']}

# ------------------------------------------------------------------------------------------- pools

PEOPLE = ['sara', 'omid', 'lena', 'kenji', 'amara', 'diego', 'nika', 'farhad', 'mina', 'ali', 'chen', 'priya', 'jonas',
          'zeynep', 'maria', 'tomas', 'yara', 'reza', 'leila', 'sam', 'noah', 'aylin', 'kofi', 'ines', 'hana', 'arash',
          'sofia', 'marco', 'elena', 'darius', 'nadia', 'lucas', 'mei', 'ravi', 'olga', 'tara', 'babak', 'emma', 'ivan', 'shirin']
SPACES = [
    ('Café Rasht', 'A small café chain: menus, orders and the website'),
    ('Peyda', 'Search platform for local shops'),
    ('Acme Labs', 'Product team building the Acme app'),
    ('Nomad Robotics', 'Firmware and fleet tooling'),
    ('Green Leaf Bakery', 'Online orders and delivery for the bakery'),
    ('Atlas Travel', 'Trip planning service'),
    ('Orbit Analytics', 'Dashboards and data pipelines for clients'),
    ('Kaveh Studio', 'Design studio projects'),
    ('Helix Health', 'Clinic scheduling and patient reminders'),
    ('Tabriz Rugs', 'E-commerce store for handmade rugs'),
    ('Northwind Ops', 'Internal operations and reporting'),
    ('Sepid Edu', 'Online courses and student support'),
    ('Pixel Forge', 'Indie game studio'),
    ('Bluefin Logistics', 'Shipments, routes and warehouse data'),
    ('Mehr Charity', 'Volunteers, donations and campaigns'),
    ('Lumen Legal', 'Contracts and client intake for a small law firm'),
    ('Thesis Lab', "A PhD student's research workspace"),
    ('Home', ''),
]
ROOMS = [('general', ''), ('backend', 'API and services'), ('launch', 'Product launch'), ('design', 'UI and brand'),
         ('support', 'Customer questions'), ('data', 'Reports and pipelines'), ('website', 'The public site'),
         ('ops', 'Daily operations'), ('research', ''), ('marketing', 'Campaigns'), ('mobile', 'The Android app'),
         ('finance', 'Budgets and invoices')]
TIMEZONES = ['Europe/London', 'Asia/Tehran', 'America/New_York', 'Asia/Tokyo', 'Europe/Berlin', 'America/Sao_Paulo',
             'Asia/Kolkata', 'Australia/Sydney', 'Africa/Lagos', 'America/Los_Angeles', 'Europe/Istanbul', 'Asia/Dubai']
TZ_OFFSETS = {'Europe/London': 0, 'Asia/Tehran': 3.5, 'America/New_York': -5, 'Asia/Tokyo': 9, 'Europe/Berlin': 1,
              'America/Sao_Paulo': -3, 'Asia/Kolkata': 5.5, 'Australia/Sydney': 11, 'Africa/Lagos': 1,
              'America/Los_Angeles': -8, 'Europe/Istanbul': 3, 'Asia/Dubai': 4}  # November offsets
CITIES = ['Rasht', 'Tehran', 'Berlin', 'Lisbon', 'Tokyo', 'Nairobi', 'Toronto', 'Istanbul', 'Bogotá', 'Pune', 'Oslo', 'Tabriz']
PLATFORM_INSTRUCTIONS = ['Answer in the language the person writes in.', 'Never share customer personal data outside the project.',
                         'Be concise.']


class Gen:
    """Deterministic randomness, ids and clocks for one sample."""

    def __init__(self, seed):
        self.r = random.Random(seed)
        self.n = 0

    def choice(self, xs):
        return self.r.choice(xs)

    def sample(self, xs, k):
        return self.r.sample(xs, k)

    def chance(self, p):
        return self.r.random() < p

    def randint(self, a, b):
        return self.r.randint(a, b)

    def hex(self, n):
        return ''.join(self.r.choice('0123456789abcdef') for _ in range(n))

    def id(self):
        # identity.ID: <node 16 hex><entity 16 hex>; one node per sample.
        if not hasattr(self, 'node'):
            self.node = '00000000' + self.hex(8)
        return self.node + self.hex(16)

    def call_id(self):
        self.n += 1
        return f"call_{self.hex(8)}_{self.n}"


class World:
    """The space, room, people and agents a room turn happens in."""

    def __init__(self, g: Gen, space=None, room=None, n_people=None, agents=None, apps=None, tz=True, direct=False):
        self.g = g
        name, desc = space or g.choice(SPACES[:-1])
        self.space = {'id': g.id(), 'name': name, 'description': desc if g.chance(0.8) else ''}
        rname, topic = room or g.choice(ROOMS)
        self.room = {'id': g.id(), 'name': rname, 'topic': topic}
        handles = g.sample(PEOPLE, n_people or g.randint(1, 3))
        self.people = [{'handle': h, 'id': g.id(), 'role': 'owner' if i == 0 else g.choice(['member', 'member', 'admin'])}
                       for i, h in enumerate(handles)]
        self.sender = self.people[0]
        self.agents = []
        for a in (agents or []):
            d = dict(a)
            d['id'] = g.id()
            d['account_id'] = g.id()
            self.agents.append(d)
        self.apps = apps or []
        self.tz = g.choice(TIMEZONES) if tz else ''
        day = g.randint(2, 27)
        self.now_utc = dt.datetime(2026, 11, day, g.randint(6, 20), g.randint(0, 59), g.randint(0, 59), tzinfo=dt.timezone.utc)
        self.platform_instructions = g.choice(PLATFORM_INSTRUCTIONS) if g.chance(0.12) else ''
        self.direct = direct
        self.computer_id = g.id() if direct else ''
        self.windows = []

    def local(self):
        if not self.tz:
            return None
        return self.now_utc + dt.timedelta(hours=TZ_OFFSETS[self.tz])

    def clock(self):
        loc = self.local()
        return L.sender_clock(self.tz, f"{loc.strftime('%A')} {loc.day} {loc.strftime('%B %Y, %H:%M')}") if loc else ''

    def context(self, me=None):
        others = [a for a in self.agents if a['name'] != (me or {}).get('name')]
        return L.agent_context(self.space, self.room, self.people, others,
                               [{'name': a['name'], 'id': a['bot_id'], 'description': a.get('description') or ''} for a in self.apps],
                               self.platform_instructions, self.direct, self.computer_id)

    def note(self):
        parts = [p for p in [self.clock(), L.desk_summary(windows=self.windows, free=self.g.chance(0.8))] if p]
        return '\n'.join(parts)

    def iso(self, minutes=0):
        return (self.now_utc + dt.timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%M:%SZ')


# ------------------------------------------------------------------------------------------ the sample

ROOM_CORE = ['bash', 'read_file', 'write_file', 'edit_file', 'list_files', 'grep', 'glob', 'post_message', 'ask_user',
             'decillion_api_search', 'decillion_api_call', 'todo_write', 'remember', 'recall', 'show_card', 'ui_present',
             'file_send', 'list_team', 'delegate_task', 'jev_decide']
LEAD_ONLY = {'recruit_agent', 'hire_agent'}
ROOM_ONLY = {'post_message', 'read_messages', 'search_messages', 'send_dm', 'read_dm', 'list_team', 'delegate_task',
             'recruit_agent', 'hire_agent', 'timeline_search', 'timeline_entry', 'load_skill'}
PERSONAL_CORE = ['decillion_api_search', 'decillion_api_call', 'ask_user', 'remember', 'recall', 'show_card', 'show_chart',
                 'list_rooms', 'show_rooms', 'todo_write', 'read_webpage', 'remember_person', 'find_people', 'remind_me']
SANDBOX = {'bash', 'read_file', 'write_file', 'edit_file', 'list_files', 'glob', 'grep', 'read_image'}
MEMORY = {'remember', 'recall', 'rewrite_notes'}
DISTRACTORS = [n for n, t in L.TOOLS.items() if not t.get('avoid')]


class Sample:
    def __init__(self, g: Gen, category: str, mode='room', agent=None, world: World | None = None, lang='en',
                 flags=None, extra_tools=(), notes=None, tags=()):
        self.g, self.category, self.mode, self.lang = g, category, mode, lang
        self.world = world
        self.agent = dict(agent or (LEAD if mode == 'room' else {'name': 'Decillion', 'personal': True, 'system': ''}))
        self.agent.setdefault('context_window', g.choice([128000, 128000, 200000, 64000, 1000000]))
        self.flags = {'no_memory': False, 'timeline': mode == 'room', 'no_sandbox': False, 'with_tools': True,
                      'computer': True, **(flags or {})}
        self.notes = notes
        self.messages = []
        self.tags = list(tags)
        self.app_defs = {t['name']: t for t in L.app_tools(world.apps if world else [])}
        self.offered = set()
        core = ROOM_CORE if mode == 'room' else PERSONAL_CORE
        for n in core:
            self._offer(n, strict=False)
        for n in extra_tools:
            self._offer(n)
        for n in g.sample(DISTRACTORS, g.randint(3, 7)):
            self._offer(n, strict=False)
        self.turns = 0

    # --- availability (turns.js applyTools) ------------------------------------------------
    def available(self, name):
        f = self.flags
        if name in self.app_defs:
            return True
        t = L.TOOLS.get(name)
        if not t:
            return False
        if self.mode == 'personal':
            if name in ROOM_ONLY:
                return False
            if name == 'hand_to_workspace':
                return f['with_tools']
            if name in SANDBOX:
                return f['computer']
        else:
            if name == 'hand_to_workspace':
                return False
            if name in LEAD_ONLY and not self.agent.get('lead'):
                return False
            if name in ('timeline_search', 'timeline_entry') and not (f['timeline'] and not f['no_memory']):
                return False
            if name == 'load_skill' and not self.agent.get('skills'):
                return False
        if name in MEMORY and f['no_memory']:
            return False
        return True

    def _offer(self, name, strict=True):
        if self.available(name):
            self.offered.add(name)
        elif strict:
            raise ValueError(f"{self.category}: tool {name} is not offered in this mode/flags")

    # --- turns --------------------------------------------------------------------------------
    def user(self, message, sender=None, memories='', attachments=None, continuation='', context=True, earlier=None):
        self.turns += 1
        if self.mode == 'room':
            w = self.world
            text = L.compose_message(sender or w.sender['handle'], message, context=w.context(self.agent) if context else '',
                                     memories=memories, note=w.note(), attachments=attachments, continuation=continuation)
            when = w.iso(self.turns * 3)
        else:
            history = (earlier or []) + [{'role': 'user', 'content': message}]
            text = L.personal_message(history, memories) if not continuation else continuation
            when = (self.world.iso(self.turns * 3) if self.world else '2026-11-21T10:00:00Z')
        self.messages.append({'role': 'user', 'content': text, 'time': when})
        return self

    def step(self, *calls, think=None, text=''):
        """calls: (name, args, result). result is the exact tool text; an Exception-like ('error', msg) renders as dsh does."""
        tcs, results = [], []
        for name, args, result in calls:
            if not self.available(name):
                raise ValueError(f"{self.category}: {name} not available")
            self.offered.add(name)
            cid = self.g.call_id()
            tcs.append({'id': cid, 'type': 'function', 'function': {'name': name, 'arguments': args}})
            if isinstance(result, tuple) and result[0] == 'error':
                content = f"Error: {result[1]}"
            else:
                content = result
            results.append({'role': 'tool', 'tool_call_id': cid, 'name': name, 'content': content})
        msg = {'role': 'assistant', 'content': text, 'tool_calls': tcs}
        if think:
            msg['reasoning_content'] = think
        self.messages.append(msg)
        self.messages.extend(results)
        return self

    def final(self, text, think=None):
        msg = {'role': 'assistant', 'content': text}
        if think:
            msg['reasoning_content'] = think
        self.messages.append(msg)
        return self

    def done(self):
        last = self.messages[-1]
        # A turn ends with the agent's answer, or with ask_user / an approval request (which conclude it).
        if last['role'] == 'tool':
            assert last['name'] == 'ask_user' or last['content'].startswith('Not run yet:'), self.category
        apps = [t for n, t in self.app_defs.items() if n in self.offered]
        return {
            'id': None, 'category': self.category, 'mode': self.mode, 'language': self.lang, 'tags': self.tags,
            'agent': {k: v for k, v in self.agent.items() if k in ('name', 'description', 'instructions', 'skills', 'lead', 'role', 'context_window', 'interrupt_on', 'system')},
            'flags': self.flags,
            'notes': self.notes,
            'session': {'space': self.world.space['id'] if self.world else '', 'room': self.world.room['id'] if self.world else ''},
            'tools': sorted(n for n in self.offered if n not in self.app_defs),
            'app_tools': apps,
            'messages': self.messages,
        }


def room(g, category, agent=None, lang='en', world_kw=None, **kw):
    world = World(g, **(world_kw or {}))
    return Sample(g, category, 'room', agent=agent, world=world, lang=lang, **kw), world


def personal(g, category, lang='en', **kw):
    world = World(g, space=('Home', ''), tz=True)
    return Sample(g, category, 'personal', world=world, lang=lang, **kw), world


def specialist(g, handle=None):
    return dict(SPECIALISTS[handle or g.choice(list(SPECIALISTS))])


def team_agents(g, k=None, exclude=()):
    pool = [h for h in SPECIALISTS if h not in exclude]
    return [dict(SPECIALISTS[h]) for h in g.sample(pool, k or g.randint(1, 4))]


def j(obj):
    return json.dumps(obj, ensure_ascii=False)


def web_window(wid, title, page, x=16, y=16, w=760, h=520):
    """desk_tools.go windowJSON of a DeskWeb window (Go marshals map keys sorted)."""
    return json.dumps({'frontend': 'web', 'h': h, 'id': wid, 'page': page, 'title': title, 'tool': 'Web pages', 'w': w, 'x': x, 'y': y},
                      sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def go_json(obj):
    """encoding/json Marshal of a map: sorted keys, compact."""
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
