"""The person's own Decillion (personal chat): their rooms, money, reminders, channels and long work."""

from gen_common import personal, j, go_json, SPACES, TZ_OFFSETS, TIMEZONES
import dshlib as L
import datetime as dt


def rooms(g):
    s, w = personal(g, 'personal.rooms', extra_tools=['list_rooms', 'show_rooms'])
    picks = g.sample(SPACES[:-1], g.randint(3, 6))
    rows = [{'id': g.id(), 'name': n, 'owner': g.chance(0.6), 'readable': g.chance(0.8)} for n, _ in picks]
    target = g.choice(rows)
    s.user(g.choice([f"Open my {target['name']} room.", f"Where is the {target['name']} project?"]))
    s.step(('list_rooms', {}, L.json.dumps(rows, separators=(',', ':'), ensure_ascii=False)))
    s.step(('show_rooms', {'rooms': [target['id']]}, 'showing 1 room card(s) under your answer'))
    s.final(f"Here's {target['name']} — tap the card to open it.")
    return s.done()


def wallet(g):
    s, w = personal(g, 'personal.wallet', extra_tools=['wallet_balance'])
    bal = g.randint(50, 900000) / 100
    s.user(g.choice(['How many credits do I have left?', 'What is my balance?', 'موجودی اعتبارم چقدره؟']))
    s.step(('wallet_balance', {}, f"{bal:.2f} credits available"))
    fa = any('؀' <= c <= 'ۿ' for c in s.messages[0]['content'])
    s.lang = 'fa' if fa else 'en'
    s.final(f"{bal:,.2f} اعتبار داری (هر اعتبار = ۱ سنت)." if fa else f"You have {bal:,.2f} credits (about ${bal / 100:,.2f}).")
    return s.done()


def reminder(g):
    tz = g.choice(TIMEZONES)
    known = g.chance(0.6)
    s, w = personal(g, 'personal.remind_me', extra_tools=['remind_me'])
    what, hh = g.choice([('call the dentist', 9), ('send the invoice to Noor Foods', 10), ('water the plants', 18), ('pay rent', 8)])
    mem = f"- The person's timezone is {tz}." if known else ''
    s.user(f"Remind me tomorrow at {hh}:00 to {what}.", memories=mem)
    if not known:
        s.step(('ask_user', {'question': 'Which time zone are you in?', 'options': ['Europe/London', 'Asia/Tehran', 'America/New_York']},
                'Asked. Your work pauses here; the conversation continues with their answer.'),
               think='The time is local to them and I do not know their zone.')
        return s.done()
    off = TZ_OFFSETS[tz]
    loc = (w.now_utc + dt.timedelta(hours=off)).replace(hour=hh, minute=0, second=0) + dt.timedelta(days=1)
    sign = '+' if off >= 0 else '-'
    hrs = abs(off)
    at = loc.strftime('%Y-%m-%dT%H:%M:%S') + f"{sign}{int(hrs):02d}:{int(round((hrs % 1) * 60)):02d}"
    utc = (loc - dt.timedelta(hours=off)).strftime('%Y-%m-%dT%H:%M:%SZ')
    rid = g.id()
    s.step(('remind_me', {'at': at, 'text': what[0].upper() + what[1:]}, f"reminder {rid} set for {utc}"))
    s.final(f"Done — I'll remind you tomorrow at {hh}:00 to {what}.")
    return s.done()


def hand_off(g):
    s, w = personal(g, 'personal.hand_to_workspace', extra_tools=['hand_to_workspace'])
    req = g.choice(['Research the five best-reviewed coworking spaces in Lisbon with prices, and make me a comparison doc.',
                    'Build me a simple website for my bakery with a menu page and opening hours.',
                    'Go through my exported bank CSVs and categorize this year\'s spending.'])
    s.user(req)
    sid = g.id()
    s.step(('hand_to_workspace', {'request': req + ' Deliver the result as a file and a short summary.'},
            f"Started in Home (space {sid}). The result will be written in this chat when the team finishes: say so; do not wait for it."),
           think='Long, multi-step work: hand it to their workspace team.')
    s.final("It's under way with your workspace team; the result will show up here when they finish.")
    return s.done()


def channel(g):
    s, w = personal(g, 'personal.connect_channel', extra_tools=['connect_channel'])
    s.user(g.choice(['Connect my Telegram so I can talk to you there.', 'I want to use you from Telegram.']))
    s.step(('connect_channel', {'app': 'telegram'}, 'the one-time link is shown under your answer: tell them to tap it and press Start'))
    s.final('Tap the link under this message and press **Start** in Telegram — it works once, for ten minutes.')
    return s.done()


def retry(g):
    """'Tools that failed before': call again in this turn, report what it returns now."""
    s, w = personal(g, 'personal.retry_tool', extra_tools=['wallet_balance'])
    earlier = [{'role': 'user', 'content': 'What is my balance?'}, {'role': 'assistant', 'content': "I couldn't reach your wallet just now."}]
    s.user('try again', earlier=earlier)
    bal = g.randint(100, 50000) / 100
    s.step(('wallet_balance', {}, f"{bal:.2f} credits available"), think='Errors are often fixed between messages: call it again now.')
    s.final(f"It works now: you have {bal:,.2f} credits.")
    return s.done()


SCENARIOS = {
    'personal.rooms': (rooms, 60),
    'personal.wallet': (wallet, 30),
    'personal.remind_me': (reminder, 80),
    'personal.hand_to_workspace': (hand_off, 15),
    'personal.connect_channel': (channel, 4),
    'personal.retry_tool': (retry, 20),
}
