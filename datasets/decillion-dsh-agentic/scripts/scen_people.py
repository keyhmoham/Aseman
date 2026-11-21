"""Talking with people: room messages, questions that pause the turn, approvals, direct messages."""

from gen_common import room, specialist, LEAD, PEOPLE, CITIES
import dshlib as L

ASKED = 'Asked. Your work pauses here; the conversation continues with their answer.'

# ------------------------------------------------------------------------------- ask_user and its answer

CHOICES = [
    dict(ask='Write a launch email for the new {thing}.', q='Who is the email for?', opts=['Existing customers', 'New sign-ups', 'Press and partners'],
         why='The audience changes the whole email and nothing in the room says which.', pick=0,
         after='Drafted for existing customers: a short subject, what is new in the {thing}, and one call to action. It is in `/workspace/drafts/launch-email.md`.',
         path='/workspace/drafts/launch-email.md', body='Subject: The new {thing} is here\n\nHi {{first_name}},\n\nThe {thing} you asked for is live today...\n'),
    dict(ask='Set up a database for the {thing}.', q='Which database should it use?', opts=['SQLite (simplest, one file)', 'Postgres (shared, scales)'],
         why='Both fit; the choice is theirs and changes the setup.', pick=1,
         after='Postgres it is: the schema is in `/workspace/{slug}/db/schema.sql` and the app reads `DATABASE_URL`.',
         path='/workspace/{slug}/db/schema.sql', body='CREATE TABLE items (\n  id serial PRIMARY KEY,\n  name text NOT NULL,\n  created_at timestamptz DEFAULT now()\n);\n'),
    dict(ask='Make a logo for the {thing}.', q='What style should the logo have?', opts=['Minimal wordmark', 'Playful icon', 'Classic emblem'],
         why='Style is a taste decision only they can make.', pick=1, after=None, path=None, body=None),
    dict(ask='Translate the {thing} page.', q='Which language should I translate it into?', opts=['Persian', 'Spanish', 'German', 'French'],
         why='No target language was given.', pick=0,
         after='Translated into Persian: `/workspace/site/fa/{slug}.md`, right-to-left layout kept.',
         path='/workspace/site/fa/{slug}.md', body='# {thing}\n\n...\n'),
]
THINGS = [('pricing page', 'pricing'), ('mobile app', 'mobile'), ('loyalty program', 'loyalty'), ('booking form', 'booking'),
          ('newsletter', 'newsletter'), ('menu', 'menu'), ('dashboard', 'dashboard'), ('store', 'store')]


def ask_then_answer(g):
    c = g.choice(CHOICES)
    thing, slug = g.choice(THINGS)
    agent = LEAD if g.chance(0.5) else specialist(g, g.choice(['writer', 'engineer', 'designer']))
    s, w = room(g, 'people.ask_user', agent=agent)
    s.user(c['ask'].format(thing=thing))
    s.step(('ask_user', {'question': c['q'], 'options': c['opts']}, ASKED), think=c['why'])
    if c['after'] is None or g.chance(0.25):
        return s.done()  # the turn concluded with the question
    s.tags.append('continuation')
    pick = c['opts'][c['pick']]
    who = w.sender['handle']
    s.user('', continuation=f"Answer to your question \"{c['q']}\" — {who}: {pick}")
    path = c['path'].format(slug=slug)
    s.step(('write_file', {'path': path, 'content': c['body'].format(thing=thing)}, f"wrote {path}"))
    s.final(c['after'].format(thing=thing, slug=slug))
    return s.done()


def find_out_first(g):
    """Look before asking: the answer is on the computer."""
    s, w = room(g, 'people.find_before_asking', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD)
    port = g.choice([3000, 5173, 8080, 8787])
    s.user(g.choice(['Start the app.', 'Run the app so I can try it.', 'Get the app running again.']))
    s.step(('read_file', {'path': '/workspace/app/package.json'}, L.numbered(
        '{\n  "name": "app",\n  "scripts": {\n    "dev": "vite --host 0.0.0.0 --port ' + str(port) + '",\n    "build": "vite build"\n  }\n}\n')),
        think='Which command and port? The project says; no need to ask.')
    pid = g.id()
    from gen_common import web_window
    out = (f"/v1/proxy/{pid}/\nStarted the service with the start command; port {port} is answering."
           f"\nOpened on the room desk as a card window: {web_window(g.hex(12), 'App', f'/v1/proxy/{pid}/')}. Arrange it with desk_arrange.")
    s._offer('proxy_create')
    s.step(('proxy_create', {'port': port, 'title': 'App', 'start': 'npm --prefix /workspace/app run dev'}, out))
    s.final(f"It's running on port {port} and open on the desk: /v1/proxy/{pid}/")
    return s.done()


def stale_question(g):
    """The room moved on while the agent waited: the question closed with the new message."""
    s, w = room(g, 'people.stale_question', agent=LEAD)
    city = g.choice(CITIES)
    s.user(f"Plan a team offsite in {city}.")
    s.step(('ask_user', {'question': 'How many people and for how many days?'}, ASKED), think='Headcount and length decide everything.')
    who = w.sender['handle']
    s.user('', continuation=f"No answer to your question yet. Meanwhile {who} wrote: actually just send me a list of 3 venues first")
    s.final(f"Sure — I'll put together three venues in {city} first; tell me headcount and days when you know them and I'll size the plan.")
    return s.done()


# ------------------------------------------------------------------------------- approvals (interrupt_on)

GUARDED = [
    ('bash', {'command': 'rm -rf /workspace/tmp/build-cache'}, 'exit 0\n', 'Clear the old build cache.', 'Cleared `/workspace/tmp/build-cache`.'),
    ('bash', {'command': 'cd /workspace/site && git push origin main'}, 'exit 0\nTo github.com:acme/site.git\n   4f2c1a9..b81e0d2  main -> main\n', 'Push the site changes.', 'Pushed `main` (4f2c1a9..b81e0d2).'),
    ('write_file', {'path': '/workspace/config/prod.env', 'content': 'LOG_LEVEL=info\nFEATURE_CHECKOUT=on\n'}, 'wrote /workspace/config/prod.env', 'Turn the new checkout on in production config.', 'Updated `/workspace/config/prod.env`: checkout is on.'),
]


def approval(g):
    name, args, result, ask, done = g.choice(GUARDED)
    agent = dict(specialist(g, 'engineer'))
    agent['interrupt_on'] = ['execute' if name == 'bash' else 'file_write']
    s, w = room(g, 'people.approval', agent=agent)
    s.user(ask)
    pending = f"Not run yet: {name} needs a person's approval. Your work pauses here; the conversation continues with their answer."
    s.step((name, args, pending), think=f"{name} is guarded for me: the call becomes an approval request.")
    who = w.sender['handle']
    calls = f"- `{name}` {L.json.dumps(args, ensure_ascii=False, separators=(',', ':'))[:600]}"
    if g.chance(0.6):
        msg = g.choice(['yes', 'ok go ahead', 'approve', 'sure'])
        s.user('', continuation=f"{who} approved: \"{msg}\". Run these calls again now, with exactly the same arguments, and carry on:\n{calls}")
        s.step((name, args, result), think='Same call, same arguments: it runs once now.')
        s.final(done)
    else:
        msg = g.choice(['no, not yet', 'reject', 'wait until Monday'])
        s.user('', continuation=f"{who} did not approve: \"{msg}\". Do not run these calls, and do not try to get the same effect another way:\n{calls}\nSay what you did not do, and ask what they want instead.")
        s.final(f"Understood — I did not run it ({ask.lower().rstrip('.')}). What would you like instead: wait, or a different approach?\n<replies>Wait | Try another way</replies>")
    return s.done()


# ------------------------------------------------------------------------------- the room

def progress_then_result(g):
    """Long work: one progress post, then the result as the reply."""
    s, w = room(g, 'people.progress_post', agent=specialist(g, g.choice(['analyst', 'researcher'])))
    n = g.randint(3, 9)
    s.user(g.choice([f'Clean the {n} supplier sheets in /workspace/suppliers and merge them.', f'Merge the {n} supplier CSVs into one clean file.']))
    s.step(('bash', {'command': 'ls /workspace/suppliers/*.csv | wc -l && head -2 /workspace/suppliers/*.csv | head -8'},
            L.bash_out(0, f"{n}\n==> /workspace/suppliers/a.csv <==\nname,phone,city\nNoor Foods,+98 13 3322 1100,Rasht\n")))
    s.step(('post_message', {'text': f"Found {n} sheets with the same columns; merging and removing duplicates now."}, 'sent'),
           think='This takes a few steps: tell the room where it stands.')
    rows = g.randint(120, 900)
    dup = g.randint(5, 40)
    s.step(('bash', {'command': "cd /workspace/suppliers && python3 -c \"import pandas as pd,glob; d=pd.concat(pd.read_csv(f) for f in glob.glob('*.csv')); n=len(d); d=d.drop_duplicates(subset=['name','phone']); d.to_csv('/workspace/suppliers/merged.csv', index=False); print(n, len(d))\""},
            L.bash_out(0, f"{rows + dup} {rows}\n")))
    fid = g.id()
    s.step(('file_send', {'path': '/workspace/suppliers/merged.csv', 'caption': 'Merged supplier list'}, f"Sent merged.csv to the chat (file id {fid})"))
    s.final(f"Merged {n} sheets into `merged.csv`: {rows} suppliers after removing {dup} duplicates.")
    return s.done()


def catch_up(g):
    s, w = room(g, 'people.read_room', agent=LEAD, extra_tools=['read_messages'])
    s.user(g.choice(['What did I miss here today?', 'Catch me up on this room.', 'Summarize the discussion so far.']))
    rows = [(w.iso(-180), 'Can we move the release to Thursday?'), (w.iso(-150), 'Thursday works if QA signs off by Wednesday.'),
            (w.iso(-90), 'QA found two checkout bugs, fixing now.'), (w.iso(-30), 'Both fixed and retested.')]
    s.step(('read_messages', {'limit': 30}, L.format_room_messages(rows)), think='Read the room before summarizing.')
    s.final('The release moved to Thursday, pending QA. QA found two checkout bugs this morning; both are fixed and retested, so Thursday is on track.')
    return s.done()


def search_room(g):
    s, w = room(g, 'people.search_messages', agent=LEAD, extra_tools=['search_messages'])
    term = g.choice(['invoice', 'domain', 'logo', 'API key rotation', 'refund'])
    s.user(f"When did we last talk about the {term}?")
    rows = [(w.iso(-60 * 24 * 3), f"The {term} is on hold until the client replies."), (w.iso(-60 * 24 * 9), f"First draft of the {term} is up.")]
    s.step(('search_messages', {'query': term}, L.format_room_messages(rows)))
    s.final(f"Three days ago: the {term} was put on hold until the client replies. Before that, the first draft went up nine days ago.")
    return s.done()


def dm(g):
    s, w = room(g, 'people.send_dm', agent=LEAD, extra_tools=['send_dm'])
    other = g.choice([p for p in PEOPLE if p != w.sender['handle']])
    s.user(f"Let {other} know the report is ready, privately.")
    s.step(('send_dm', {'to': other, 'text': 'Hi! The report is ready in the room\'s files whenever you want to look.'}, 'sent'))
    s.final(f"Sent {other} a direct message.")
    return s.done()


GREET = [('hi!', 'Hi! What can I help with today?'), ('thanks, that was great', "Glad it helped!"),
         ('سلام', 'سلام! چه کمکی از دستم برمی‌آد؟'), ('good morning team', 'Good morning! What are we working on today?'),
         ('ممنون، عالی بود', 'خواهش می‌کنم، خوشحالم که به کار اومد!')]


def greeting(g):
    q, a = g.choice(GREET)
    s, w = room(g, 'people.plain_reply', agent=LEAD if g.chance(0.6) else specialist(g), lang='fa' if any('؀' <= ch <= 'ۿ' for ch in q) else 'en')
    s.user(q)
    s.final(a)
    return s.done()


SCENARIOS = {
    'people.ask_user': (ask_then_answer, 260),
    'people.find_before_asking': (find_out_first, 60),
    'people.stale_question': (stale_question, 60),
    'people.approval': (approval, 200),
    'people.progress_post': (progress_then_result, 200),
    'people.read_room': (catch_up, 40),
    'people.search_messages': (search_room, 60),
    'people.send_dm': (dm, 60),
    'people.plain_reply': (greeting, 30),
}
