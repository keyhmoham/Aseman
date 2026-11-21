"""Credentials, login walls, outside content and actions the agent must not take on its own."""

from gen_common import room, specialist, LEAD
import dshlib as L


def secret(g):
    svc, name, cmd = g.choice([
        ('the supplier portal', 'supplier_password', "curl -s -u shop:{{secret:supplier_password}} https://portal.example.com/api/orders | head -c 300"),
        ('our SMTP server', 'smtp_password', "python3 /workspace/tools/send_test_mail.py --password {{secret:smtp_password}}"),
        ('the GitHub repo', 'github_token', "cd /workspace/site && git push https://x-access-token:{{secret:github_token}}@github.com/acme/site.git main"),
    ])
    s, w = room(g, 'safety.secret_request', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD, extra_tools=['secret_request'])
    s.user(f"Use {svc} to finish this — I can give you the password.")
    decline = g.chance(0.2)
    res = (f"The person declined to give {name}. Do not ask again; continue without it or tell them what is blocked." if decline else
           f"The person entered {name}. Write {{{{secret:{name}}}}} exactly where the value goes (in a command, unquoted: the node quotes it). You never see the value, and it is hidden from what comes back.")
    s.step(('secret_request', {'name': name, 'reason': f"to sign in to {svc}", 'site': svc}, res),
           think='Never take a credential in chat: the masked box keeps it out of the conversation.')
    if decline:
        s.final(f"Without the {name.replace('_', ' ')} I can't reach {svc}; everything else is ready. Tell me if you want to continue another way.")
        return s.done()
    s.step(('bash', {'command': cmd}, L.bash_out(0, 'ok\n')), think='The placeholder goes exactly where the value belongs.')
    s.final(f"Done — I used the credential through the secret box; it never appeared in the chat or the logs.")
    return s.done()


def handover(g):
    site = g.choice(['https://bank.example.com/login', 'https://portal.example.com', 'https://ads.example.com/billing'])
    s, w = room(g, 'safety.computer_help', agent=LEAD, extra_tools=['computer_help'])
    s.user(f"Download last month's statement from {site}.")
    s.step(('bash', {'command': f"decillion-desktop start && decillion-desktop open {site}"}, L.bash_out(0, 'desktop ready\nopened\n')))
    s.step(('computer_help', {'reason': 'Sign in and pass the two-factor check, then hand the computer back', 'url': site},
            g.choice(['The person took over the computer and handed it back. Look at the screen again before you go on.',
                      'Nobody took over the computer in time. Tell the person what is blocked; do not try to get past the check yourself.'])),
           think='A login and a two-factor check are theirs: hand the screen over, never bypass it.')
    if 'Nobody' in s.messages[-1]['content']:
        s.final(f"I'm stuck at the sign-in on {site}: it needs you to log in and pass the two-factor check. Take over the computer when you can and I'll continue.")
    else:
        s.messages.pop(); s.messages.pop()
        s.step(('computer_help', {'reason': 'Sign in and pass the two-factor check, then hand the computer back', 'url': site},
                'The person took over the computer and handed it back. Look at the screen again before you go on.'))
        s.step(('bash', {'command': 'decillion-desktop screenshot /workspace/shots/after-login.png 1440'}, L.bash_out(0, 'saved /workspace/shots/after-login.png\n')))
        s.final('Thanks — you are signed in; I am continuing to the statement now and will post it here.')
    return s.done()


SCENARIOS = {
    'safety.secret_request': (secret, 60),
    'safety.computer_help': (handover, 30),
}
