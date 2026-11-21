"""The space's agents as a team (delegate, hire, recruit) and dsh's own parallelism (teammates, tasks, goals, workflows)."""

from gen_common import room, specialist, LEAD, SPECIALISTS, j
import dshlib as L

WORK = {
    'researcher': ('Compare the three cheapest EU hosts for a small Postgres app; report with sources in /workspace/research/hosting/report.md',
                   'Hetzner, Scaleway and OVH compared; Hetzner is cheapest for 2 vCPU. Report with 7 sources: /workspace/research/hosting/report.md.'),
    'engineer': ('Add GET /health to the API in /workspace/api returning {"ok": true}, with a test',
                 'Added GET /health in /workspace/api/main.py; curl returns 200 {"ok": true} and the new test passes (9 passed).'),
    'tester': ('Test the checkout flow on the running preview like a real customer and list any bugs with steps',
               'Ran 12 checkout journeys: 11 pass; a coupon code with a trailing space is rejected. Steps in /workspace/qa/checkout.md.'),
    'designer': ('Design a pricing section for the landing page in /workspace/site, responsive down to 360px',
                 'Pricing section in /workspace/site/src/components/Pricing.astro, three tiers, checked at 360px and 1440px.'),
    'analyst': ('From /workspace/data/sales.csv, find which product categories grew most last quarter; save a chart',
                'Home goods grew most (+34%), then kitchen (+18%). Chart: /workspace/analysis/q3_growth.png.'),
    'writer': ('Write release notes for 2.4 from /workspace/CHANGELOG.md in plain language, into /workspace/docs/release-2.4.md',
               'Release notes in /workspace/docs/release-2.4.md: 5 highlights and 9 fixes.'),
    'marketer': ('Draft a two-week launch plan for the loyalty program into /workspace/marketing/loyalty-launch.md',
                 'Plan in /workspace/marketing/loyalty-launch.md: teaser week, launch day, two follow-up emails and 6 social posts.'),
    'seo': ('Audit the site at /workspace/site for on-page SEO problems; list fixes by impact',
            '14 issues; top 3: missing meta descriptions on 9 pages, duplicate H1 on /menu, no sitemap. List: /workspace/seo/audit.md.'),
    'product': ('Turn the idea "table reservations in the app" into user stories with acceptance criteria',
                '8 user stories with acceptance criteria in /workspace/product/reservations.md, scoped to a 2-week first version.'),
    'finance': ('Build a 12-month cash-flow forecast from /workspace/finance/2026.xlsx assumptions',
                'Forecast in /workspace/finance/cashflow-2027.xlsx; cash stays positive, lowest in March (about 4,200).'),
    'presenter': ('Make a 10-slide investor update from /workspace/docs/q3-summary.md',
                  '10 slides in /workspace/decks/q3-update.pptx with the revenue chart on slide 3.'),
    'reviewer': ('Review the contract draft /workspace/legal/msa-draft.md for errors and gaps',
                 '6 findings in /workspace/legal/msa-review.md; the most important: no liability cap and an undefined "Services" term.'),
}

GOALS = [
    ('Get the new menu page live: content, design and a preview I can share.', ['writer', 'designer', 'engineer']),
    ('Prepare the quarterly report: numbers, a short write-up and slides.', ['analyst', 'writer', 'presenter']),
    ('Launch the loyalty program next week.', ['product', 'marketer', 'engineer']),
    ('Check the site is ready for launch: bugs, SEO and copy.', ['tester', 'seo', 'reviewer']),
    ('Research hosting and set up the health check before we migrate.', ['researcher', 'engineer']),
]


def _team_line(a):
    return f"- {a['name']}: {a['description'][:300]}"


def delegate_parallel(g):
    goal, roles = g.choice(GOALS)
    picked = g.sample(roles, g.randint(2, len(roles)))
    others = [r for r in SPECIALISTS if r not in picked]
    agents = [SPECIALISTS[r] for r in picked] + [SPECIALISTS[r] for r in g.sample(others, g.randint(0, 2))]
    s, w = room(g, 'team.delegate_parallel', agent=LEAD, world_kw={'agents': agents})
    s.user(goal)
    s.step(('list_team', {}, '\n'.join(_team_line(a) for a in agents)), think='See who is in the space before handing out work.')
    if g.chance(0.6):
        s.step(('todo_write', {'todos': [{'content': f"{SPECIALISTS[r]['name']}: {WORK[r][0][:60]}", 'status': 'in_progress'} for r in picked] +
                [{'content': 'Integrate and report', 'status': 'pending'}]},
                f"Updated todo list: 1 pending, {len(picked)} in progress, 0 completed."))
    calls = [('delegate_task', {'agent': SPECIALISTS[r]['name'], 'task': WORK[r][0] + '. Reply with what you made, where it is and how you verified it.'},
              f"{SPECIALISTS[r]['name']}: {WORK[r][1]}") for r in picked]
    s.step(*calls, think='Independent pieces: delegate them together so they run in parallel; each task says everything the agent needs.')
    summary = ' '.join(f"{SPECIALISTS[r]['name']}: {WORK[r][1].split(';')[0].split('. ')[0]}." for r in picked)
    s.final(f"Done. {summary}")
    return s.done()


def delegate_unknown(g):
    """Delegating to someone who is not there → list_team → hire from the marketplace → delegate."""
    role = g.choice(list(WORK))
    want = SPECIALISTS[role]
    present = [SPECIALISTS[r] for r in g.sample([r for r in SPECIALISTS if r != role], g.randint(1, 2))]
    s, w = room(g, 'team.hire_missing', agent=LEAD, world_kw={'agents': present})
    s.user(f"Ask the {want['name'].lower()} to: {WORK[role][0][0].lower() + WORK[role][0][1:]}.")
    s.step(('delegate_task', {'agent': want['name'], 'task': WORK[role][0]},
            ('error', f"no agent {j(want['name'])} in this space: see list_team, or recruit_agent / hire_agent")))
    s.step(('list_team', {}, '\n'.join(_team_line(a) for a in present)))
    listing = g.id()
    price = g.choice([0, 5, 10, 25])
    s.step(('hire_agent', {'query': want['name'].lower()},
            f"- {want['name']} (listing {listing}, price {price}): {want['description'][:200]}"),
           think='Nobody here fits: look in the marketplace before writing a new agent.')
    bot = g.id()
    s.step(('hire_agent', {'listing': listing}, f"hired {want['name']} (bot {bot}). Hand it work with delegate_task."))
    s.step(('delegate_task', {'agent': want['name'], 'task': WORK[role][0] + '. Reply with the result, where it is and how you verified it.'},
            f"{want['name']}: {WORK[role][1]}"))
    s.final(f"There was no {want['name']} in the space, so I hired one from the marketplace (price {price}). {WORK[role][1]}")
    return s.done()


RECRUITS = [
    ('Persian copy editor', 'Edits Persian marketing copy for tone, grammar and right-to-left layout.',
     'You edit Persian text. Keep the meaning, fix grammar and punctuation (Persian comma ، and half-spaces), and keep a warm, simple tone. Return the edited text and a short list of changes.',
     'Edit /workspace/site/fa/home.md for grammar and tone.', 'Edited /workspace/site/fa/home.md: 23 fixes (mostly half-spaces and punctuation); list of changes at the end of the file.'),
    ('GTFS data checker', 'Validates public-transit GTFS feeds and reports errors.',
     'You validate GTFS feeds with gtfs-validator on the shared computer and explain each error in plain words, with the file and line.',
     'Validate the feed in /workspace/transit/gtfs.zip.', 'Validated /workspace/transit/gtfs.zip: 2 errors (stop_times.txt has 14 trips with times out of order) and 5 warnings; report at /workspace/transit/report.html.'),
    ('Shopify theme fixer', 'Fixes Liquid templates and CSS in a Shopify theme repo.',
     'You work in the theme repo under /workspace/theme. Read the template, change only what the task needs, and check with `shopify theme check`.',
     'The product page hides the size selector on mobile; fix it.', 'Fixed sections/product.liquid: the selector was hidden below 480px by a stray display:none; theme check passes.'),
]


def recruit(g):
    name, desc, instr, task, reply = g.choice(RECRUITS)
    present = [SPECIALISTS[r] for r in g.sample(list(SPECIALISTS), g.randint(1, 3))]
    s, w = room(g, 'team.recruit', agent=LEAD, world_kw={'agents': present})
    s.user(task)
    s.step(('list_team', {}, '\n'.join(_team_line(a) for a in present)))
    s.step(('hire_agent', {'query': name.lower()}, 'No published agent matches.'), think='Check the marketplace first.')
    bot = g.id()
    s.step(('recruit_agent', {'name': name, 'description': desc, 'instructions': instr},
            f"recruited {name} (bot {bot}). Hand it work with delegate_task."),
           think='Nothing fits: write a focused specialist.')
    s.step(('delegate_task', {'agent': name, 'task': task + ' Reply with what you changed and how you checked it.'}, f"{name}: {reply}"))
    s.final(f"No agent fit, so I recruited a {name}. {reply}")
    return s.done()


def delegate_self(g):
    role = g.choice(list(WORK))
    me = SPECIALISTS[role]
    s, w = room(g, 'team.delegate_self', agent=dict(me), world_kw={'agents': [me]})
    s.user(WORK[role][0] + '.')
    s.step(('delegate_task', {'agent': me['name'], 'task': WORK[role][0]}, ('error', 'that is you: do the work yourself, or use a subagent')))
    s.step(('todo_write', {'todos': [{'content': WORK[role][0][:70], 'status': 'in_progress'}]}, 'Updated todo list: 0 pending, 1 in progress, 0 completed.'),
           think='The task is mine; do it here.')
    s.final(f"I'm on it myself — I'll report back with the result.")
    return s.done()


def teammates(g):
    """dsh Agent Teams: spawn teammates, wait, collect their closing messages."""
    parts = g.choice([
        (['parse-csv', 'Parse /workspace/import/raw/*.csv into one table', 'parsed 6 files into /workspace/import/all.parquet (48,210 rows)'],
         ['geo-lookup', 'Geocode the addresses in /workspace/import/addresses.txt', 'geocoded 1,204 of 1,230 addresses; misses in /workspace/import/geo_misses.txt']),
        (['api-tests', 'Write tests for /workspace/api/routes/orders.py', 'added 14 tests in /workspace/api/tests/test_orders.py, all pass'],
         ['docs-api', 'Document the orders endpoints in /workspace/api/README.md', 'documented 5 endpoints with examples in /workspace/api/README.md']),
        (['images-resize', 'Resize /workspace/site/photos/*.jpg to 1600px wide WebP', 'converted 37 photos to WebP in /workspace/site/photos/web (61% smaller)'],
         ['alt-text', 'Write alt text for each photo in /workspace/site/photos into alt.json', 'wrote alt text for 37 photos in /workspace/site/photos/alt.json']),
    ])
    s, w = room(g, 'team.teammates', agent=LEAD if g.chance(0.6) else specialist(g, 'engineer'))
    s.user(g.choice(['Do both of these in parallel: ', 'Split this up and run it at once: ']) + parts[0][1].lower() + ', and ' + parts[1][1].lower() + '.')
    calls = []
    for name, task, _ in parts:
        member = {'member': {'target': name, 'role': 'teammate', 'status': 'inactive', 'description': task, 'provider': 'spawn', 'context': 'fresh',
                             'model': L.model_for(s.agent['context_window']), 'diagnostics': []}}
        calls.append(('spawn_teammate', {'name': name, 'description': task, 'prompt': task + '. Report what you made and where.', 'context': 'fresh'},
                      j(member).replace(', ', ',').replace(': ', ':')))
    s.step(*calls, think='Two independent jobs on the same computer: two fresh teammates, disjoint folders.')
    for name, task, result in parts:
        sid = '-'.join([g.hex(8), g.hex(4), g.hex(4), g.hex(4), g.hex(12)])
        s.messages.append({'role': 'user', 'content': f"Background subagent {sid} finished and will do no further work unless you send it more.Its closing message:{result}", 'time': w.iso(5)})
    s.final(f"Both done: {parts[0][2]}; {parts[1][2]}.")
    return s.done()


def task_board(g):
    s, w = room(g, 'team.task_board', agent=LEAD)
    s.user('Track the launch checklist as tasks: copy review, then the final deploy (after the review).')
    t1 = {'id': 'task-1', 'revision': 1, 'subject': 'Copy review', 'description': 'Review all page copy for typos and tone; done when the reviewer signs off.',
          'status': 'pending', 'blockedBy': [], 'writeScopes': ['site/content'], 'ready': True, 'writeScopeWarnings': []}
    t2 = {'id': 'task-2', 'revision': 1, 'subject': 'Final deploy', 'description': 'Deploy the site after the copy review; done when the live URL answers 200.',
          'status': 'pending', 'blockedBy': ['task-1'], 'writeScopes': [], 'ready': False, 'writeScopeWarnings': []}
    c = lambda o: j(o).replace(', ', ',').replace(': ', ':')
    s.step(('team_task_create', {'subject': t1['subject'], 'description': t1['description'], 'write_scopes': ['site/content']}, c(t1)))
    s.step(('team_task_create', {'subject': t2['subject'], 'description': t2['description'], 'blocked_by': ['task-1']}, c(t2)),
           think='The deploy waits for the review: record the dependency.')
    s.final('Two tasks on the board: "Copy review" (ready) and "Final deploy", blocked until the review completes.')
    return s.done()


GOAL_OBJ = ['Migrate every test in /workspace/app from Jest to Vitest and keep them green',
            'Translate all 40 help articles in /workspace/help into Persian',
            'Bring the site\'s Lighthouse performance score above 90 on every page']


def goal(g):
    obj = g.choice(GOAL_OBJ)
    s, w = room(g, 'team.goal', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD)
    s.user(obj + '. Keep going until it is all done.')
    gid = 'goal-' + '-'.join([g.hex(8), g.hex(4), g.hex(4), g.hex(4), g.hex(12)])
    res = {'goal': {'id': gid, 'revision': 1, 'objective': obj, 'phase': 'active', 'roundsStarted': 0, 'maxGoalRounds': 256}, 'activation': 'armed'}
    s.step(('create_goal', {'objective': obj}, j(res).replace(', ', ',').replace(': ', ':')), think='A long objective over many rounds: a goal keeps it going.')
    s.final('Goal set; I will keep working through it across rounds and report as parts finish.')
    return s.done()


def workflow(g):
    """Only when the person explicitly asks for a workflow / large fan-out."""
    s, w = room(g, 'team.workflow', agent=LEAD)
    files = g.sample(['auth.py', 'orders.py', 'payments.py', 'users.py', 'search.py', 'admin.py', 'export.py'], g.randint(3, 5))
    s.user(f"Run a workflow that reviews each of these modules in /workspace/api for security issues in parallel: {', '.join(files)}.")
    script = ("phase('Review')\n"
              "const results = await pipeline(args.files, (prev, f) => agent(`Review /workspace/api/${f} for security issues. "
              "Reply with the single most serious issue, or none.`, { label: f, phase: 'Review' }))\n"
              "return { results: args.files.map((f, i) => ({ file: f, finding: results[i] })) }")
    finds = [g.choice(['none', 'SQL built with string formatting in a query', 'no rate limit on the login route', 'token compared with == instead of a constant-time compare'])
             for _ in files]
    ret = {'results': [{'file': f, 'finding': x} for f, x in zip(files, finds)]}
    out = f"workflow \"review-api-security\" completed ({len(files)} agents).\nReturn value:\n" + L.json.dumps(ret, indent=2)
    s.step(('workflow', {'meta': {'name': 'review-api-security', 'description': 'Security review of API modules, one agent per file'},
                         'args': {'files': files}, 'script': script}, out),
           think='They asked for a workflow over many independent files: one script fans it out.')
    bad = [(f, x) for f, x in zip(files, finds) if x != 'none']
    if bad:
        s.final(f"Reviewed {len(files)} modules: {len(bad)} need attention — " + '; '.join(f"`{f}`: {x}" for f, x in bad) + '.')
    else:
        s.final(f"Reviewed {len(files)} modules in parallel; none had a serious security issue.")
    return s.done()


SCENARIOS = {
    'team.delegate_parallel': (delegate_parallel, 320),
    'team.hire_missing': (delegate_unknown, 200),
    'team.recruit': (recruit, 60),
    'team.delegate_self': (delegate_self, 40),
    'team.teammates': (teammates, 60),
    'team.task_board': (task_board, 20),
    'team.goal': (goal, 40),
    'team.workflow': (workflow, 120),
}
