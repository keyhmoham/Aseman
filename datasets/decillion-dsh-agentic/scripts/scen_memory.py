"""Memory (notes, remember, recall), the project timeline and dsh session search."""

from gen_common import room, specialist, LEAD, PEOPLE, j
import dshlib as L

FACTS = [
    ('From now on, deploys only happen on Fridays.', 'Deploys happen only on Fridays.', True),
    ('Remember that I prefer answers in Persian.', '{who} prefers answers in Persian.', False),
    ('Our brand color is #0F766E, keep using it.', 'Brand color is #0F766E.', True),
    ('Note that the staging database is at db-staging.internal.', 'Staging database host: db-staging.internal.', True),
    ('I like short summaries with bullet points.', '{who} likes short summaries with bullet points.', False),
    ('The client is called Noor Foods; their contact is Mina.', 'Client: Noor Foods, contact Mina.', True),
    ('Invoices go out on the 1st of each month.', 'Invoices go out on the 1st of each month.', True),
]


def remember(g):
    ask, fact, shared = g.choice(FACTS)
    s, w = room(g, 'memory.remember', agent=LEAD if g.chance(0.6) else specialist(g))
    who = w.sender['handle']
    s.user(ask)
    s.step(('remember', {'text': fact.format(who=who), 'shared': shared}, 'remembered'),
           think='A team convention: shared for every agent.' if shared else 'A personal preference: keep it as mine.')
    s.final(g.choice(['Noted — I\'ll keep that in mind.', 'Got it, remembered.', 'Saved; I\'ll follow it from now on.']))
    return s.done()


def recall(g):
    ask, fact, shared = g.choice(FACTS)
    s, w = room(g, 'memory.recall', agent=LEAD if g.chance(0.5) else specialist(g))
    q = g.choice([('When are we allowed to deploy?', 'deploy schedule', 'Deploys happen only on Fridays.', 'Only on Fridays.'),
                  ("What's our brand color again?", 'brand color', 'Brand color is #0F766E.', '#0F766E.'),
                  ('Who is the contact at the client?', 'client contact', 'Client: Noor Foods, contact Mina.', 'Mina, at Noor Foods.'),
                  ('When do invoices go out?', 'invoice schedule', 'Invoices go out on the 1st of each month.', 'On the 1st of each month.')])
    s.user(q[0])
    if g.chance(0.5):
        s.step(('recall', {'query': q[1]}, f"- {q[2]}"), think='Look it up in memory.')
        s.final(q[3])
    else:
        s.messages.pop()
        s.turns -= 1
        s.user(q[0], memories=f"- {q[2]}")
        s.final(q[3])
        s.tags.append('memory_in_context')
    return s.done()


def recall_miss(g):
    s, w = room(g, 'memory.recall_miss', agent=LEAD)
    q = g.choice(['What did we decide about the refund policy?', 'Which hosting plan did we pick?', 'What is the wifi password at the office?'])
    s.user(q)
    s.step(('recall', {'query': q.lower().rstrip('?')}, 'Nothing in memory about that.'))
    s.step(('search_messages', {'query': q.split()[-2].strip('?')}, '(no messages)'))
    s._offer('search_messages')
    s.final("I don't have that: nothing in memory or in this space's messages. If you tell me, I'll remember it.")
    return s.done()


def notes(g):
    s, w = room(g, 'memory.rewrite_notes', agent=LEAD, notes={'space': 'Deploys: Fridays only.\nStaging: db-staging.internal', 'own': ''})
    s.user('We moved staging to db-stage-2.internal; update the team notes.')
    new = 'Deploys: Fridays only.\nStaging: db-stage-2.internal'
    s.step(('rewrite_notes', {'content': new, 'shared': True}, 'notes updated'), think='Notes are short and current: replace the old host.')
    s.final('Updated the shared notes: staging is now db-stage-2.internal.')
    return s.done()


def no_memory(g):
    s, w = room(g, 'memory.disabled', agent=LEAD, flags={'no_memory': True})
    s.user('Remember that the launch is on the 12th.')
    s.final("Memory is turned off for this request, so I can't save it. Ask again in a normal message (or put it in the room's notes) and I'll keep it.")
    return s.done()


def timeline(g):
    s, w = room(g, 'memory.timeline', agent=LEAD, extra_tools=['timeline_search', 'timeline_entry'])
    topic = g.choice([('the last deploy', 'deploy', 'Deployed site v2.3 to production by Engineer; checks passed.'),
                      ('the invoice export', 'invoice export', 'Routine "invoice-export" ran; 41 invoices written to /workspace/finance/2026-10.csv.'),
                      ('when Sara joined', 'member joined', 'sara joined the space as member.')])
    s.user(f"When was {topic[0]}?")
    day = w.now_utc.day - g.randint(1, 3)
    line = f"undefined [timeline] 2026-11-{day:02d} 16:20 — {topic[2]}"
    s.step(('timeline_search', {'query': topic[1], 'since': f"2026-11-{max(1, day - 7):02d}"}, L.wrap('project timeline', line)),
           think='A question about time: search the project timeline.')
    s.final(f"On 2026-11-{day:02d} at 16:20 — {topic[2]}")
    return s.done()


def session_search(g):
    s, w = room(g, 'memory.session_search', agent=specialist(g, 'engineer'))
    s.user('How did we fix the CORS error last time? Do the same here.')
    sid = '-'.join([g.hex(8), g.hex(4), g.hex(4), g.hex(4), g.hex(12)])
    out = (f"Session search results (1):\n\n1. Session decillion-room-{g.hex(32)} — fix CORS on api\n   Created: 2026-11-{w.now_utc.day - 4:02d}T10:12:03.511Z\n"
           f"   Availability: persisted\n   Best match: seq 41 | assistant/message | current | 2026-11-{w.now_utc.day - 4:02d}T10:31:47.208Z\n"
           "   Snippet: Added the preview origin to CORS_ORIGINS in /workspace/api/.env and restarted; preflight returns 204.")
    s.step(('session_search', {'query': 'CORS'}, out), think='An earlier conversation has it: search sessions.')
    s.step(('bash', {'command': 'grep -n CORS_ORIGINS /workspace/api/.env'}, L.bash_out(0, '3:CORS_ORIGINS=http://localhost:3000\n')))
    s.final('Last time the fix was adding the preview origin to `CORS_ORIGINS` in `/workspace/api/.env`. Here it only allows localhost:3000 — tell me the origin to add, or say "the preview" and I\'ll add it and restart.')
    return s.done()


SCENARIOS = {
    'memory.remember': (remember, 120),
    'memory.recall': (recall, 120),
    'memory.recall_miss': (recall_miss, 30),
    'memory.rewrite_notes': (notes, 10),
    'memory.disabled': (no_memory, 10),
    'memory.timeline': (timeline, 60),
    'memory.session_search': (session_search, 20),
}
