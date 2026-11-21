"""Several turns of one room thread in one dsh Session: the agent keeps its earlier context."""

import gen_common as GC
import dshlib as L
import scen_dev, scen_present, scen_memory, scen_apps, scen_platform, scen_people, scen_safety, scen_personal

POOL = [
    (scen_dev, scen_dev.inspect), (scen_dev, scen_dev.list_and_find), (scen_dev, scen_dev.script_deliver), (scen_dev, scen_dev.bugfix),
    (scen_present, scen_present.card), (scen_present, scen_present.chart), (scen_memory, scen_memory.remember),
    (scen_memory, scen_memory.recall), (scen_memory, scen_memory.timeline), (scen_apps, scen_apps.app_function),
    (scen_apps, scen_apps.routine), (scen_platform, scen_platform.api_room_create), (scen_apps, scen_apps.app_plain),
    (scen_dev, scen_dev.edit_multi), (scen_dev, scen_dev.long_file), (scen_dev, scen_dev.preview), (scen_dev, scen_dev.preview_fail),
    (scen_people, scen_people.progress_then_result), (scen_people, scen_people.catch_up), (scen_people, scen_people.search_room),
    (scen_people, scen_people.dm), (scen_people, scen_people.find_out_first), (scen_present, scen_present.desk_report),
    (scen_present, scen_present.mindmap), (scen_present, scen_present.board_notes), (scen_present, scen_present.ui_question),
    (scen_apps, scen_apps.image), (scen_apps, scen_apps.app_injection), (scen_apps, scen_apps.mcp_flow),
    (scen_safety, scen_safety.secret), (scen_platform, scen_platform.api_denied), (scen_memory, scen_memory.session_search),
    (scen_memory, scen_memory.recall_miss), (scen_apps, scen_apps.file_without_intent),
]
# may close a session (the turn concludes with a question): only as the last turn
LAST = [(scen_people, scen_people.ask_then_answer), (scen_platform, scen_platform.offer_ui)]


def multi_turn(g):
    k = g.randint(2, 3)
    picks = g.sample(POOL, k)
    if g.chance(0.25):
        picks.append(g.choice(LAST))
    world = GC.World(g, apps=[a for a in L.EXAMPLE_APPS if a['name'] in ('Weather', 'Translator', 'Exa')])
    agent = GC.LEAD
    sample = GC.Sample(g, 'session.multi_turn', 'room', agent=agent, world=world, lang='en')
    sample.tags.append('multi_turn')
    shared = {'sample': sample}

    def bound_room(g2, category, agent=None, lang='en', world_kw=None, extra_tools=(), flags=None, **kw):
        for t in extra_tools:
            sample._offer(t)
        if lang != 'en':
            sample.lang = 'mixed'
        return sample, world

    saved = []
    try:
        for mod in {m for m, _ in picks}:
            saved.append((mod, mod.room))
            mod.room = bound_room
        for mod, fn in picks:
            fn(g)
    finally:
        for mod, r in saved:
            mod.room = r
    return sample.done()


PERSONAL = [scen_personal.rooms, scen_personal.wallet, scen_personal.hand_off, scen_personal.channel]


def personal_multi(g):
    world = GC.World(g, space=('Home', ''), tz=True)
    sample = GC.Sample(g, 'session.personal_multi_turn', 'personal', world=world, lang='en')
    sample.tags.append('multi_turn')

    def bound(g2, category, lang='en', extra_tools=(), **kw):
        for t in extra_tools:
            sample._offer(t)
        return sample, world
    saved = scen_personal.personal
    scen_personal.personal = bound
    try:
        for fn in g.sample(PERSONAL, g.randint(2, 3)):
            fn(g)
        if g.chance(0.4):
            scen_personal.reminder(g)
    finally:
        scen_personal.personal = saved
    return sample.done()


SCENARIOS = {'session.multi_turn': (multi_turn, 60000), 'session.personal_multi_turn': (personal_multi, 6000)}
