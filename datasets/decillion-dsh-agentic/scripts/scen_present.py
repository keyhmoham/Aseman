"""Presenting: show_card / show_chart, ui_present, the desk and its whiteboard."""

from gen_common import room, specialist, LEAD, j
import dshlib as L

CARDS = [
    ('How did sales do this week?', "cd /workspace/data && python3 -c \"import pandas as pd; d=pd.read_csv('orders.csv',parse_dates=['date']); w=d[d.date>='2026-11-16']; print(len(w), round(w.total.sum(),2), round(w.total.mean(),2))\"",
     '312 18420.5 59.04\n', {'type': 'stats', 'title': 'This week', 'items': [{'title': 'Orders', 'value': '312'}, {'title': 'Revenue', 'value': '18,420.50'}, {'title': 'Average order', 'value': '59.04'}]},
     '312 orders brought in 18,420.50 this week, about 59 per order.'),
    ('Which pages are slowest?', "cat /workspace/perf/lighthouse.tsv", 'page\tscore\n/menu\t41\n/shop\t58\n/about\t77\n',
     {'type': 'list', 'title': 'Slowest pages', 'subtitle': 'Lighthouse performance', 'items': [{'title': '/menu', 'value': '41', 'tone': 'bad'}, {'title': '/shop', 'value': '58', 'tone': 'warn'}, {'title': '/about', 'value': '77'}]},
     '/menu is the one to fix first at 41.'),
    ('Compare the two hosting plans we shortlisted.', "cat /workspace/research/hosting/shortlist.md", '| plan | vCPU | RAM | price |\n| Hetzner CX22 | 2 | 4 GB | 4.51 |\n| Scaleway DEV1-S | 2 | 2 GB | 6.42 |\n',
     {'type': 'table', 'title': 'Hosting shortlist', 'columns': ['Plan', 'vCPU', 'RAM', 'Price / month'], 'rows': [['Hetzner CX22', '2', '4 GB', '€4.51'], ['Scaleway DEV1-S', '2', '2 GB', '€6.42']]},
     'Hetzner CX22 gives twice the memory for less.'),
    ("What's left before launch?", "cat /workspace/launch/checklist.md", '- [x] Copy review\n- [x] Payment test\n- [ ] DNS switch\n- [ ] Announce\n',
     {'type': 'steps', 'title': 'Launch checklist', 'items': [{'title': 'Copy review', 'done': True}, {'title': 'Payment test', 'done': True}, {'title': 'DNS switch'}, {'title': 'Announce'}]},
     'Two steps left: the DNS switch, then the announcement.'),
]


def card(g):
    q, cmd, out, card, take = g.choice(CARDS)
    s, w = room(g, 'present.show_card', agent=LEAD if g.chance(0.5) else specialist(g, 'analyst'))
    s.user(q)
    s.step(('bash', {'command': cmd}, L.bash_out(0, out)))
    s.step(('show_card', card, f"showing the {card['type']} card under your answer: now say the point in a sentence"),
           think='The answer has a shape: a card, then one sentence.')
    s.final(take)
    return s.done()


def chart(g):
    data = g.choice([('Signups per week', [('W44', 120), ('W45', 154), ('W46', 149), ('W47', 201)], 'line', 'Signups jumped to 201 last week, the best so far.'),
                     ('Spend by channel', [('Search', 4200), ('Social', 2600), ('Email', 800)], 'donut', 'Search takes over half the spend.'),
                     ('Tickets by day', [('Mon', 31), ('Tue', 22), ('Wed', 18), ('Thu', 25), ('Fri', 40)], 'bar', 'Fridays are the busiest day for support.')])
    s, w = room(g, 'present.show_chart', agent=specialist(g, 'analyst'), extra_tools=['show_chart'])
    s.user(f"Chart the {data[0].lower()}.")
    csv = 'label,value\n' + ''.join(f"{a},{b}\n" for a, b in data[1])
    s.step(('bash', {'command': f"cat /workspace/data/{data[0].lower().replace(' ', '_')}.csv"}, L.bash_out(0, csv)))
    s.step(('show_chart', {'title': data[0], 'points': [{'label': a, 'value': b} for a, b in data[1]], 'style': data[2]}, 'showing the chart under your answer'))
    s.final(data[3])
    return s.done()


def ui_question(g):
    s, w = room(g, 'present.ui_present_chat', agent=LEAD, extra_tools=['ui_present'])
    s.user(g.choice(['Help me pick a theme color for the app.', 'Which layout should the menu page use? Show me options.']))
    root = {'c': 'Choices', 'p': {'question': 'Pick one', 'options': ['Teal', 'Indigo', 'Amber']}}
    s.step(('ui_present', {'placement': 'chat', 'title': 'Options', 'root': root},
            'showing it with your answer: say the takeaway in a sentence or two and do not repeat the card'),
           think='A small choice the person makes in the message: a chat surface.')
    s.final('Pick one of the three and I\'ll apply it.')
    return s.done()


def desk_report(g):
    s, w = room(g, 'present.desk_show', agent=specialist(g, 'analyst'), extra_tools=['desk_show'])
    s.user('Put the quarterly numbers on the desk so the team can look at them during the call.')
    root = {'c': 'Column', 'children': [{'c': 'Stat', 'p': {'label': 'Revenue', 'value': '$1.2M'}},
                                         {'c': 'Chart', 'p': {'type': 'bar', 'data': [{'x': 'Jul', 'y': 380}, {'x': 'Aug', 'y': 402}, {'x': 'Sep', 'y': 418}], 'x': 'x', 'y': 'y'}}]}
    wid = g.hex(12)
    s.step(('desk_show', {'ui': 'agui', 'title': 'Q3 numbers', 'root': root}, f"Opened \"Q3 numbers\" on this room's desk (window={wid}, agui)."),
           think='A report people look at together: a desk window on this room; no room argument.')
    s.final('The Q3 numbers are open on the desk: revenue $1.2M, rising each month.')
    return s.done()


def desk_tidy(g):
    s, w = room(g, 'present.desk_arrange', agent=LEAD, extra_tools=['desk_state', 'desk_arrange', 'desk_close'])
    a, b, c = g.hex(12), g.hex(12), g.hex(12)
    w.windows = [(a, 'Sales dashboard', 'web page /v1/proxy/x/', 300, 200, 640, 480), (b, 'Old report', 'web report', 40, 40, 500, 400), (c, 'Checklist', 'AG-UI surface', 200, 300, 400, 300)]
    s.user('The desk is a mess. Close the old report and put the other two side by side.')
    after_close = L.desk_summary(windows=[w.windows[0], w.windows[2]])
    s.step(('desk_close', {'ids': [b]}, after_close), think='Window ids are in the turn note.')
    arranged = L.desk_summary(windows=[(a, 'Sales dashboard', 'web page /v1/proxy/x/', 16, 16, 640, 480), (c, 'Checklist', 'AG-UI surface', 672, 16, 400, 480)])
    s.step(('desk_arrange', {'windows': [{'id': a, 'x': 16, 'y': 16, 'w': 640, 'h': 480}, {'id': c, 'x': 672, 'y': 16, 'w': 400, 'h': 480}]}, arranged))
    s.final('Closed the old report; the dashboard and the checklist are now side by side.')
    return s.done()


def mindmap(g):
    topic = g.choice([('Launch', ['Design', 'Marketing', 'Engineering']), ('Café menu', ['Drinks', 'Food', 'Seasonal']), ('Thesis', ['Literature', 'Method', 'Results'])])
    s, w = room(g, 'present.board_mindmap', agent=LEAD, extra_tools=['board_mindmap'])
    s.user(f"Sketch a mind map of the {topic[0].lower()} plan on the whiteboard.")
    root = {'text': topic[0], 'children': [{'text': t} for t in topic[1]]}
    rid = g.hex(12)
    s.step(('board_mindmap', {'root': root}, f"Drew a mind map of {1 + len(topic[1])} ideas centred at x 600, y 320 (root {rid})."))
    s.final(f"The mind map is on the whiteboard: {topic[0]} with {', '.join(topic[1])}.")
    return s.done()


def board_notes(g):
    s, w = room(g, 'present.board_add', agent=LEAD, extra_tools=['board_add'])
    s.user('Put the three steps of onboarding on the whiteboard with arrows between them.')
    items = [{'key': 'a', 'kind': 'note', 'text': 'Sign up', 'color': 'yellow'}, {'key': 'b', 'kind': 'note', 'text': 'Pick a plan', 'color': 'blue'},
             {'key': 'c', 'kind': 'note', 'text': 'First order', 'color': 'green'}, {'kind': 'arrow', 'from': 'a', 'to': 'b'}, {'kind': 'arrow', 'from': 'b', 'to': 'c'}]
    ids = [g.hex(12) for _ in items]
    out = f"Added {len(items)} item(s) to the whiteboard:" + ''.join(f"\n- {i} ({it['kind']})" for i, it in zip(ids, items))
    s.step(('board_add', {'items': items}, out), think='Keys let the arrows refer to notes from the same call.')
    s.final('Onboarding is on the whiteboard: Sign up → Pick a plan → First order.')
    return s.done()



# more card cases: (question, command, output, card, takeaway)
CARDS += [
    ('What are our top 5 products by revenue?', "python3 /workspace/tools/top_products.py 5", 'Rug Tabriz 2x3,4120\nKilim runner,3380\nWool cushion,2210\nSilk mini,1990\nJute mat,1430\n',
     {'type': 'list', 'title': 'Top products', 'subtitle': 'Revenue, this month', 'items': [{'title': 'Rug Tabriz 2x3', 'value': '4,120'}, {'title': 'Kilim runner', 'value': '3,380'}, {'title': 'Wool cushion', 'value': '2,210'}, {'title': 'Silk mini', 'value': '1,990'}, {'title': 'Jute mat', 'value': '1,430'}]},
     'The Tabriz 2x3 rug leads by a clear margin.'),
    ('Give me the key facts about the new server.', "cat /workspace/infra/server.yaml", 'host: app-2\nregion: eu-central\ncpu: 4\nram: 8GB\nos: Ubuntu 24.04\n',
     {'type': 'facts', 'title': 'app-2', 'items': [{'title': 'Region', 'value': 'eu-central'}, {'title': 'CPU', 'value': '4 vCPU'}, {'title': 'RAM', 'value': '8 GB'}, {'title': 'OS', 'value': 'Ubuntu 24.04'}]},
     'app-2 is a 4-vCPU, 8 GB Ubuntu 24.04 box in eu-central.'),
    ('Is anything wrong with the backups?', "tail -3 /workspace/backups/backup.log", '2026-11-19 ok 2.1G\n2026-11-20 FAILED disk full\n2026-11-21 FAILED disk full\n',
     {'type': 'callout', 'title': 'Backups failing', 'tone': 'danger', 'body': 'The last two nightly backups failed: the backup disk is full.'},
     'Backups have failed two nights running because the disk is full; freeing space or adding a disk fixes it.'),
    ('Send me links to the docs we use most.', "cat /workspace/docs/links.txt", 'https://docs.example.com/api\nhttps://docs.example.com/deploy\nhttps://status.example.com\n',
     {'type': 'links', 'title': 'Docs', 'items': [{'title': 'API reference', 'url': 'https://docs.example.com/api'}, {'title': 'Deploy guide', 'url': 'https://docs.example.com/deploy'}, {'title': 'Status page', 'url': 'https://status.example.com'}]},
     'Those are the three we open most.'),
    ('How is the support queue today?', "python3 /workspace/support/stats.py today", 'open 23\nanswered 41\nmedian_first_reply_min 12\n',
     {'type': 'stats', 'title': 'Support today', 'items': [{'title': 'Open', 'value': '23', 'tone': 'warn'}, {'title': 'Answered', 'value': '41', 'tone': 'good'}, {'title': 'First reply', 'value': '12 min'}]},
     '41 answered and 23 still open, with a 12-minute median first reply.'),
    ('Compare this month with last month.', "python3 /workspace/tools/compare_months.py", 'metric,last,this\norders,1180,1312\nrevenue,61200,70450\nrefunds,22,15\n',
     {'type': 'table', 'title': 'Month over month', 'columns': ['Metric', 'Last month', 'This month'], 'rows': [['Orders', '1,180', '1,312'], ['Revenue', '61,200', '70,450'], ['Refunds', '22', '15']]},
     'More orders and revenue, and fewer refunds than last month.'),
    ('What did we ship this week?', "cd /workspace/app && git log --since='7 days ago' --pretty=%s", 'Add dark mode\nFix login redirect\nFaster search\n',
     {'type': 'steps', 'title': 'Shipped this week', 'items': [{'title': 'Dark mode', 'done': True}, {'title': 'Login redirect fix', 'done': True}, {'title': 'Faster search', 'done': True}]},
     'Three changes shipped this week.'),
]


SCENARIOS = {
    'present.show_card': (card, 120),
    'present.show_chart': (chart, 60),
    'present.ui_present_chat': (ui_question, 20),
    'present.desk_show': (desk_report, 20),
    'present.desk_arrange': (desk_tidy, 20),
    'present.board_mindmap': (mindmap, 30),
    'present.board_add': (board_notes, 15),
}
