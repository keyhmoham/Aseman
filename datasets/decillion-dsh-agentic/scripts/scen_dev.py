"""Development on the space's shared computer: inspecting, fixing, writing and running code."""

from gen_common import room, specialist, LEAD, j, web_window
import dshlib as L

# --------------------------------------------------------------------------------------------- bug cases

BUGS = [
    dict(
        path='/workspace/shop/pricing.py', lang='python', symbol='apply_discount',
        ask=['Orders of exactly 100 are not getting the 10% discount. Can you fix it?',
             'The discount should start at 100, but a 100 total pays full price. Fix please.'],
        ask_fa='سفارش‌هایی که دقیقاً ۱۰۰ هستند تخفیف ۱۰٪ نمی‌گیرند. می‌شه درستش کنی؟',
        content='DISCOUNT_FROM = 100\n\n\ndef apply_discount(total):\n    """10% off orders of DISCOUNT_FROM or more."""\n    if total > DISCOUNT_FROM:\n        return round(total * 0.9, 2)\n    return total\n',
        old='    if total > DISCOUNT_FROM:', new='    if total >= DISCOUNT_FROM:',
        test='cd /workspace/shop && python -m pytest -q',
        fail='F..                                                                      [100%]\n=================================== FAILURES ===================================\n___________________________ test_discount_at_limit ____________________________\n\n    def test_discount_at_limit():\n>       assert apply_discount(100) == 90\nE       assert 100 == 90\nE        +  where 100 = apply_discount(100)\n\ntests/test_pricing.py:9: AssertionError\n=========================== short test summary info ============================\nFAILED tests/test_pricing.py::test_discount_at_limit - assert 100 == 90\n1 failed, 2 passed in 0.04s\n',
        passed='...                                                                      [100%]\n3 passed in 0.02s\n',
        cause='the check used `>` so a total of exactly 100 was excluded',
        cause_fa='شرط از `>` استفاده می‌کرد و مبلغ دقیقاً ۱۰۰ را حساب نمی‌کرد',
        grep='def apply_discount', include='*.py'),
    dict(
        path='/workspace/site/src/cart.js', lang='js', symbol='cartTotal',
        ask=['The cart total ignores quantities — 3 mugs cost the same as 1. Please fix.',
             'Checkout shows the wrong total when someone buys more than one of an item.'],
        ask_fa='جمع سبد خرید تعداد رو حساب نمی‌کنه؛ ۳ تا لیوان قیمت یکی رو داره. درستش کن.',
        content="export function cartTotal(items) {\n  return items.reduce((sum, item) => sum + item.price, 0)\n}\n\nexport function formatTotal(cents) {\n  return `$${(cents / 100).toFixed(2)}`\n}\n",
        old='  return items.reduce((sum, item) => sum + item.price, 0)', new='  return items.reduce((sum, item) => sum + item.price * item.quantity, 0)',
        test='cd /workspace/site && npm test --silent',
        fail='✔ formatTotal formats cents (0.61ms)\n✖ cartTotal multiplies price by quantity (1.07ms)\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n\n  1200 !== 3600\n\nℹ tests 2\nℹ suites 0\nℹ pass 1\nℹ fail 1\nℹ cancelled 0\nℹ skipped 0\nℹ todo 0\nℹ duration_ms 48.2\n',
        passed='✔ formatTotal formats cents (0.58ms)\n✔ cartTotal multiplies price by quantity (0.33ms)\nℹ tests 2\nℹ suites 0\nℹ pass 2\nℹ fail 0\nℹ cancelled 0\nℹ skipped 0\nℹ todo 0\nℹ duration_ms 45.9\n',
        cause='the reducer added `item.price` once per line instead of `price × quantity`',
        cause_fa='جمع فقط `item.price` را یک بار برای هر ردیف اضافه می‌کرد، نه قیمت × تعداد',
        grep='cartTotal', include='*.js'),
    dict(
        path='/workspace/api/page.go', lang='go', symbol='Page',
        ask=['The orders endpoint returns 11 items per page instead of 10.', 'Pagination is off by one: every page has an extra row. Can you fix it?'],
        ask_fa='صفحه‌بندی یکی اضافه برمی‌گردونه؛ هر صفحه ۱۱ تا آیتم داره به جای ۱۰.',
        content='package api\n\n// Page returns the items of page n (1-based), size items per page.\nfunc Page[T any](items []T, n, size int) []T {\n\tstart := (n - 1) * size\n\tif start >= len(items) {\n\t\treturn nil\n\t}\n\tend := start + size\n\tif end > len(items) {\n\t\tend = len(items) - 1\n\t}\n\treturn items[start : end+1]\n}\n',
        old='\tif end > len(items) {\n\t\tend = len(items) - 1\n\t}\n\treturn items[start : end+1]', new='\tif end > len(items) {\n\t\tend = len(items)\n\t}\n\treturn items[start:end]',
        test='cd /workspace/api && go test ./...',
        fail='--- FAIL: TestPage (0.00s)\n    page_test.go:12: page 1: got 11 items, want 10\nFAIL\nFAIL\texample.com/api\t0.005s\nFAIL\n',
        passed='ok  \texample.com/api\t0.004s\n',
        cause='the slice used an inclusive end (`end+1`), so each page took one extra item',
        cause_fa='برش آرایه انتهای بازه را هم شامل می‌کرد (`end+1`) و هر صفحه یک آیتم اضافه داشت',
        grep='func Page', include='*.go'),
    dict(
        path='/workspace/crm/contacts.py', lang='python', symbol='mailing_list',
        ask=['The newsletter export crashes with KeyError: \'email\'. Some contacts have no email; skip them.',
             'Export of the mailing list fails. Contacts without an email should just be left out.'],
        ask_fa='خروجی لیست ایمیل با خطای KeyError: \'email\' کرش می‌کنه. مخاطب‌های بدون ایمیل رو رد کن.',
        content='def mailing_list(contacts):\n    """Addresses of the contacts who opted in."""\n    return [c["email"] for c in contacts if c.get("opt_in")]\n',
        old='    return [c["email"] for c in contacts if c.get("opt_in")]', new='    return [c["email"] for c in contacts if c.get("opt_in") and c.get("email")]',
        test='cd /workspace/crm && python -m pytest -q',
        fail='.F                                                                       [100%]\n=================================== FAILURES ===================================\n_________________________ test_skips_missing_email ___________________________\n\n    def test_skips_missing_email():\n>       assert mailing_list([{"opt_in": True}]) == []\n\ntests/test_contacts.py:8: \n_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _\n\n>   return [c["email"] for c in contacts if c.get("opt_in")]\nE   KeyError: \'email\'\n\ncontacts.py:3: KeyError\n=========================== short test summary info ============================\nFAILED tests/test_contacts.py::test_skips_missing_email - KeyError: \'email\'\n1 failed, 1 passed in 0.03s\n',
        passed='..                                                                       [100%]\n2 passed in 0.02s\n',
        cause='the list read `c["email"]` for every opted-in contact, even ones without an address',
        cause_fa='برای هر مخاطب `c["email"]` خوانده می‌شد، حتی وقتی ایمیل نداشت',
        grep='def mailing_list', include='*.py'),
    dict(
        path='/workspace/scripts/backup.sh', lang='sh', symbol='backup',
        ask=['The backup script fails on the folder "Client Files". Fix it?', 'backup.sh breaks when a path has a space in it.'],
        ask_fa='اسکریپت بکاپ روی پوشه "Client Files" خطا می‌ده. درستش کن.',
        content='#!/usr/bin/env bash\nset -euo pipefail\nSRC="$1"\nDEST=/workspace/backups/$(date +%F)\nmkdir -p "$DEST"\ntar -czf "$DEST/backup.tar.gz" -C $SRC .\necho "saved $DEST/backup.tar.gz"\n',
        old='tar -czf "$DEST/backup.tar.gz" -C $SRC .', new='tar -czf "$DEST/backup.tar.gz" -C "$SRC" .',
        test="mkdir -p '/workspace/data/Client Files' && echo hi > '/workspace/data/Client Files/a.txt' && bash /workspace/scripts/backup.sh '/workspace/data/Client Files'",
        fail_code=2,
        fail='tar: /workspace/data/Client: Cannot open: No such file or directory\ntar: Error is not recoverable: exiting now\n',
        passed='saved /workspace/backups/2026-11-{DAY}/backup.tar.gz\n',
        cause='`$SRC` was unquoted, so the shell split "Client Files" into two words',
        cause_fa='متغیر `$SRC` داخل کوتیشن نبود و شل مسیر "Client Files" را دو تکه می‌کرد',
        grep='tar -czf', include='*.sh'),
    dict(
        path='/workspace/web/src/money.ts', lang='ts', symbol='formatPrice',
        ask=['Prices show as 19.9 instead of 19.90 on the product page.', 'Our price labels drop the trailing zero (12.5 instead of 12.50).'],
        ask_fa='قیمت‌ها به‌جای 19.90 به شکل 19.9 نمایش داده می‌شن.',
        content="export function formatPrice(value: number): string {\n  return String(Math.round(value * 100) / 100)\n}\n",
        old='  return String(Math.round(value * 100) / 100)', new='  return (Math.round(value * 100) / 100).toFixed(2)',
        test='cd /workspace/web && npx vitest run',
        fail=' ❯ src/money.test.ts (2 tests | 1 failed) 4ms\n   × formatPrice keeps two decimals 3ms\n     → expected \'19.9\' to be \'19.90\' // Object.is equality\n\n Test Files  1 failed (1)\n      Tests  1 failed | 1 passed (2)\n',
        passed=' ✓ src/money.test.ts (2 tests) 2ms\n\n Test Files  1 passed (1)\n      Tests  2 passed (2)\n',
        cause='`String()` of the rounded number drops trailing zeros',
        cause_fa='`String()` صفرهای انتهایی را حذف می‌کرد',
        grep='formatPrice', include='*.ts'),
]


def _bug_answer(b, g, lang, verified_line):
    if lang == 'fa':
        return f"درست شد: {b['cause_fa']}. تغییر در `{b['path']}` است و تست‌ها پاس شدند (`{b['test'].split('&&')[-1].strip()}`)."
    opts = [
        f"Fixed: {b['cause']}. The change is in `{b['path']}`, and {verified_line}.",
        f"Done — {b['cause']}; I corrected it in `{b['path']}` and {verified_line}.",
    ]
    return g.choice(opts)


def bugfix(g):
    b = dict(g.choice(BUGS))
    day = None
    lang = 'fa' if g.chance(0.15) else 'en'
    as_specialist = g.chance(0.45)
    agent = specialist(g, 'engineer') if as_specialist else LEAD
    s, w = room(g, 'dev.bugfix', agent=agent, lang=lang)
    passed = b['passed'].replace('{DAY}', f"{w.now_utc.day:02d}")
    ask = b['ask_fa'] if lang == 'fa' else g.choice(b['ask'])
    s.user(ask)
    flow = g.choice(['test-first', 'grep-first', 'grep-first', 'edit-retry'])
    if g.chance(0.35):
        s.step(('todo_write', {'todos': [{'content': 'Reproduce the failure', 'status': 'in_progress'},
                                         {'content': 'Fix the cause', 'status': 'pending'},
                                         {'content': 'Run the tests again', 'status': 'pending'}]},
                'Updated todo list: 2 pending, 1 in progress, 0 completed.'),
               think='Several steps: plan them so people can follow.')
    fail_code = b.get('fail_code', 1)
    if flow == 'test-first':
        s.step(('bash', {'command': b['test']}, L.bash_out(fail_code, b['fail'])), think='Reproduce it with the tests first.')
        s.step(('read_file', {'path': b['path']}, L.numbered(b['content'])))
    else:
        root = b['path'].rsplit('/', 1)[0].rsplit('/', 1)[0] if b['path'].count('/') > 3 else '/workspace'
        line = next(i for i, l in enumerate(b['content'].split('\n')) if b['grep'] in l) + 1
        hit = f"{b['path']}:{line}:{b['content'].split(chr(10))[line - 1]}\n"
        s.step(('grep', {'pattern': b['grep'], 'path': root, 'include': b['include']}, hit), think='Find where it is defined.')
        s.step(('read_file', {'path': b['path']}, L.numbered(b['content'])))
    if flow == 'edit-retry':
        wrong = b['old'].replace('    ', '  ', 1) if '    ' in b['old'] else b['old'].replace('\t', '    ', 1)
        if wrong == b['old']:
            wrong = b['old'] + ' '
        s.step(('edit_file', {'path': b['path'], 'old_string': wrong, 'new_string': b['new']},
                ('error', 'old_string was not found in the file; read it again and copy the text exactly')))
        s.step(('read_file', {'path': b['path'], 'offset': 0, 'limit': 40}, L.numbered(b['content'], 0, 40)),
               think='The indentation did not match; copy it exactly from the file.')
    text, count = L.apply_edit(b['content'], b['old'], b['new'])
    s.step(('edit_file', {'path': b['path'], 'old_string': b['old'], 'new_string': b['new']}, L.edited(b['path'], count)),
           think=f"Cause: {b['cause']}.")
    s.step(('bash', {'command': b['test']}, L.bash_out(0, passed)), think='Verify with the same command.')
    if flow == 'test-first' or g.chance(0.5):
        verified = f"`{b['test'].split('&&')[-1].strip()}` now passes"
    else:
        verified = 'the tests pass'
    s.final(_bug_answer(b, g, lang, verified))
    return s.done()


# --------------------------------------------------------------------------------------------- quick inspections

INSPECT = [
    ('Which Python and Node versions are on the computer?', 'کدوم نسخه پایتون و نود روی کامپیوتر نصبه؟', 'python3 --version && node --version',
     'Python 3.12.3\nv22.11.0\n', 'Python 3.12.3 and Node v22.11.0.', 'پایتون 3.12.3 و نود v22.11.0.'),
    ('How much disk space is left on the computer?', 'چقدر فضای دیسک روی کامپیوتر مونده؟', 'df -h /workspace',
     'Filesystem      Size  Used Avail Use% Mounted on\n/dev/vdb         20G  6.1G   13G  32% /workspace\n',
     '13 GB free of 20 GB on /workspace (32% used).', '۱۳ گیگابایت از ۲۰ گیگ روی /workspace آزاد است (۳۲٪ پر).'),
    ('How many orders are in orders.csv?', 'توی orders.csv چند تا سفارش هست؟', "wc -l < /workspace/data/orders.csv && head -1 /workspace/data/orders.csv",
     '1285\norder_id,date,customer,total\n', '1,284 orders (1,285 lines minus the header).', '۱٬۲۸۴ سفارش (۱٬۲۸۵ خط منهای سطر عنوان).'),
    ('Is anything listening on port 3000?', 'روی پورت ۳۰۰۰ چیزی در حال اجراست؟', "ss -ltnp | grep ':3000' || echo 'nothing on 3000'",
     'LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*    users:(("node",pid=4121,fd=21))\n',
     'Yes — a node process (pid 4121) is listening on 0.0.0.0:3000.', 'بله، یک پروسه node (pid 4121) روی 0.0.0.0:3000 گوش می‌دهد.'),
    ('What branch is the site repo on, and is it clean?', 'ریپوی سایت روی کدوم برنچه و تغییر commit‌نشده داره؟', 'cd /workspace/site && git status -sb',
     '## main...origin/main [ahead 2]\n M src/pages/index.astro\n?? notes.md\n',
     '`main`, 2 commits ahead of origin, with one modified file (`src/pages/index.astro`) and one untracked (`notes.md`).',
     'روی `main` است، دو commit جلوتر از origin، با یک فایل تغییرکرده (`src/pages/index.astro`) و یک فایل جدید (`notes.md`).'),
    ('How big is the uploads folder?', 'پوشه uploads چقدر حجم داره؟', 'du -sh /workspace/uploads',
     '2.3G\t/workspace/uploads\n', 'The uploads folder is 2.3 GB.', 'پوشه uploads حدود ۲٫۳ گیگابایت است.'),
    ('What does the README say about running the project?', 'README درباره اجرای پروژه چی می‌گه؟', "grep -n -A4 -i '^## run' /workspace/README.md",
     '12:## Run\n13-\n14-npm install\n15-npm run dev -- --host 0.0.0.0\n16-\n',
     '`npm install`, then `npm run dev -- --host 0.0.0.0`.', 'اول `npm install` و بعد `npm run dev -- --host 0.0.0.0`.'),
]


def inspect(g):
    q, qfa, cmd, out, ans, ansfa = g.choice(INSPECT)
    lang = 'fa' if g.chance(0.18) else 'en'
    agent = LEAD if g.chance(0.6) else specialist(g, g.choice(['engineer', 'analyst']))
    s, w = room(g, 'sandbox.inspect', agent=agent, lang=lang)
    s.user(qfa if lang == 'fa' else q)
    s.step(('bash', {'command': cmd}, L.bash_out(0, out)), think='One command answers this.')
    s.final(ansfa if lang == 'fa' else ans)
    return s.done()


def list_and_find(g):
    """list_files / glob / grep to answer where something is."""
    s, w = room(g, 'sandbox.find', agent=LEAD if g.chance(0.5) else specialist(g, 'engineer'))
    kind = g.choice(['glob', 'list', 'grep'])
    if kind == 'glob':
        s.user(g.choice(['Where are the test files in the project?', 'Find every test file we have.']))
        files = ['/workspace/app/tests/test_api.py', '/workspace/app/tests/test_models.py', '/workspace/app/tests/conftest.py']
        s.step(('glob', {'pattern': '**/test_*.py', 'path': '/workspace/app'}, '\n'.join(files[:2])), think='Search by name pattern.')
        s.final('Two test files, both in `/workspace/app/tests`: `test_api.py` and `test_models.py`.')
    elif kind == 'list':
        s.user(g.choice(['What is in the workspace right now?', 'Show me what the project folder holds.']))
        items = [('app', 'dir', 4096), ('data', 'dir', 4096), ('notes.md', 'file', 1834), ('README.md', 'file', 2210)]
        s.step(('list_files', {'path': '/workspace'}, L.list_files_out(items)))
        s.final('`/workspace` has two folders, `app/` and `data/`, plus `README.md` and `notes.md`.')
    else:
        term = g.choice(['STRIPE_KEY', 'API_URL', 'DATABASE_URL'])
        s.user(f"Which files read {term}?")
        hits = f"/workspace/app/config.py:7:{term} = os.environ[\"{term}\"]\n/workspace/app/payments.py:3:from config import {term}\n"
        s.step(('grep', {'pattern': term, 'path': '/workspace'}, hits), think='A content search finds the uses.')
        s.final(f"Two: `app/config.py` reads `{term}` from the environment (line 7) and `app/payments.py` imports it from there.")
    return s.done()


# --------------------------------------------------------------------------------------------- scripts that deliver files

SCRIPTS = [
    dict(ask='Make me a CSV of monthly sales totals from /workspace/data/orders.csv.', ask_fa='از /workspace/data/orders.csv یک CSV از جمع فروش هر ماه بساز.',
         path='/workspace/reports/monthly_sales.py',
         code='import csv\nfrom collections import defaultdict\n\ntotals = defaultdict(float)\nwith open("/workspace/data/orders.csv", newline="") as f:\n    for row in csv.DictReader(f):\n        totals[row["date"][:7]] += float(row["total"])\n\nwith open("/workspace/reports/monthly_sales.csv", "w", newline="") as f:\n    w = csv.writer(f)\n    w.writerow(["month", "total"])\n    for month in sorted(totals):\n        w.writerow([month, f"{totals[month]:.2f}"])\nprint(len(totals), "months")\n',
         run='python3 /workspace/reports/monthly_sales.py && cat /workspace/reports/monthly_sales.csv', out='3 months\nmonth,total\n2026-09,18240.50\n2026-10,21975.00\n2026-11,9630.25\n',
         deliver='/workspace/reports/monthly_sales.csv', name='monthly_sales.csv',
         chart=[('2026-09', 18240.5), ('2026-10', 21975.0), ('2026-11', 9630.25)],
         ans='Here is the CSV: October was the strongest month at 21,975.00; November so far is 9,630.25.',
         ans_fa='فایل CSV ارسال شد: اکتبر با ۲۱٬۹۷۵ بیشترین فروش را داشت و نوامبر تا اینجا ۹٬۶۳۰٫۲۵ است.'),
    dict(ask='Convert /workspace/data/products.json to a spreadsheet I can open.', ask_fa='فایل /workspace/data/products.json رو به یک فایل اکسل‌خوان (CSV) تبدیل کن.',
         path='/workspace/tools/json_to_csv.py',
         code='import csv, json\n\nrows = json.load(open("/workspace/data/products.json"))\nfields = sorted({k for r in rows for k in r})\nwith open("/workspace/data/products.csv", "w", newline="") as f:\n    w = csv.DictWriter(f, fieldnames=fields)\n    w.writeheader()\n    w.writerows(rows)\nprint(len(rows), "rows,", len(fields), "columns")\n',
         run='python3 /workspace/tools/json_to_csv.py', out='42 rows, 5 columns\n',
         deliver='/workspace/data/products.csv', name='products.csv', chart=None,
         ans='Sent `products.csv`: 42 products, 5 columns — it opens in any spreadsheet app.',
         ans_fa='فایل `products.csv` ارسال شد: ۴۲ محصول در ۵ ستون، در هر برنامه صفحه‌گسترده باز می‌شود.'),
    dict(ask='Count how many words each chapter in /workspace/book has and give me the list as a file.', ask_fa='تعداد کلمات هر فصل در /workspace/book رو بشمار و به صورت فایل بده.',
         path='/workspace/tools/wordcount.sh',
         code='#!/usr/bin/env bash\nset -euo pipefail\nfor f in /workspace/book/*.md; do\n  printf "%s\\t%s\\n" "$(basename "$f")" "$(wc -w < "$f")"\ndone > /workspace/book/wordcount.tsv\ncat /workspace/book/wordcount.tsv\n',
         run='bash /workspace/tools/wordcount.sh', out='01-intro.md\t1840\n02-roots.md\t4212\n03-river.md\t3977\n04-return.md\t2650\n',
         deliver='/workspace/book/wordcount.tsv', name='wordcount.tsv',
         chart=[('01-intro', 1840), ('02-roots', 4212), ('03-river', 3977), ('04-return', 2650)],
         ans='Sent `wordcount.tsv`: four chapters, 12,679 words in all; chapter 2 is the longest.',
         ans_fa='فایل `wordcount.tsv` ارسال شد: چهار فصل و در مجموع ۱۲٬۶۷۹ کلمه؛ فصل ۲ از همه طولانی‌تر است.'),
]


def script_deliver(g):
    sc = g.choice(SCRIPTS)
    lang = 'fa' if g.chance(0.15) else 'en'
    s, w = room(g, 'dev.script_deliver', agent=LEAD if g.chance(0.5) else specialist(g, g.choice(['engineer', 'analyst'])), lang=lang)
    s.user(sc['ask_fa'] if lang == 'fa' else sc['ask'])
    s.step(('write_file', {'path': sc['path'], 'content': sc['code']}, f"wrote {sc['path']}"), think='Write a small script, run it, deliver the file.')
    s.step(('bash', {'command': sc['run']}, L.bash_out(0, sc['out'])))
    fid = g.id()
    calls = [('file_send', {'path': sc['deliver'], 'caption': sc['name']}, f"Sent {sc['name']} to the chat (file id {fid})")]
    if sc['chart'] and g.chance(0.6):
        unit = 'words' if 'word' in sc['name'] else ''
        args = {'title': 'Monthly sales' if 'sales' in sc['name'] else 'Words per chapter', 'points': [{'label': a, 'value': v} for a, v in sc['chart']], 'style': 'bar'}
        if unit:
            args['unit'] = unit
        calls.append(('show_chart', args, 'showing the chart under your answer'))
        s._offer('show_chart')
    s.step(*calls, think='Writing a path in a message does not deliver it: file_send does.')
    s.final(sc['ans_fa'] if lang == 'fa' else sc['ans'])
    return s.done()


def edit_multi(g):
    """edit_file: several occurrences → replace_all, or more context."""
    s, w = room(g, 'dev.edit_replace_all', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD)
    old_name, new_name = g.choice([('Acme Inc', 'Acme Labs'), ('support@old.example', 'help@acme.example'), ('v1/api', 'v2/api')])
    path = g.choice(['/workspace/site/src/footer.html', '/workspace/site/config.yaml', '/workspace/docs/guide.md'])
    content = f"<!-- {old_name} -->\n<p>&copy; 2026 {old_name}</p>\n<a href=\"mailto:x\">Contact {old_name}</a>\n" if path.endswith('.html') else \
        f"name: {old_name}\nfooter: Made by {old_name}\nlegal: {old_name} — all rights reserved\n"
    s.user(f"Replace \"{old_name}\" with \"{new_name}\" everywhere in {path.split('/')[-1]}.")
    s.step(('edit_file', {'path': path, 'old_string': old_name, 'new_string': new_name},
            ('error', 'old_string occurs 3 times; add surrounding lines to make it unique, or set replace_all')))
    text, count = L.apply_edit(content, old_name, new_name, True)
    s.step(('edit_file', {'path': path, 'old_string': old_name, 'new_string': new_name, 'replace_all': True}, L.edited(path, count)),
           think='They asked for every occurrence: replace_all is right here.')
    s.step(('grep', {'pattern': old_name.replace('.', '\\.'), 'path': path}, 'no match'), think='Confirm nothing is left.')
    s.final(f"Replaced all 3 occurrences in `{path}`; none of \"{old_name}\" remain.")
    return s.done()


def long_file(g):
    """read_file pages through a long log with offset/limit."""
    s, w = room(g, 'dev.read_long_file', agent=specialist(g, 'engineer') if g.chance(0.6) else LEAD)
    s.user(g.choice(['Why did last night\'s import job fail? The log is /workspace/logs/import.log.',
                     'Check /workspace/logs/import.log and tell me what went wrong.']))
    lines = [f"2026-11-{w.now_utc.day - 1:02d}T02:{i // 60:02d}:{i % 60:02d}Z INFO imported batch {i}" for i in range(1, 2400)]
    lines += [f"2026-11-{w.now_utc.day - 1:02d}T02:40:01Z ERROR batch 2400: duplicate key value violates unique constraint \"orders_pkey\" (order_id=88213)",
              f"2026-11-{w.now_utc.day - 1:02d}T02:40:01Z INFO import stopped after 2399 batches"]
    text = '\n'.join(lines) + '\n'
    s.step(('grep', {'pattern': 'ERROR|WARN', 'path': '/workspace/logs/import.log'}, f"{len(lines) - 1}:{lines[-2]}\n"),
           think='The log is long: search for errors instead of reading all of it.')
    s.step(('read_file', {'path': '/workspace/logs/import.log', 'offset': len(lines) - 5, 'limit': 5}, L.numbered(text, len(lines) - 5, 5)))
    s.final('It stopped at batch 2400: order 88213 was already in the database, so the insert hit the `orders_pkey` unique constraint and the job quit after 2,399 batches. Skipping or upserting existing orders would let it finish.')
    return s.done()


# --------------------------------------------------------------------------------------------- previews

PREVIEW = [
    ('site', 3000, 'npm --prefix /workspace/site start -- -p 3000 -H 0.0.0.0', 'Landing page'),
    ('api', 8000, 'cd /workspace/api && .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000', 'Orders API docs'),
    ('dashboard', 5173, 'npm --prefix /workspace/dashboard run preview -- --host 0.0.0.0 --port 5173', 'Sales dashboard'),
]


def preview(g):
    name, port, start, title = g.choice(PREVIEW)
    s, w = room(g, 'web.preview', agent=specialist(g, 'engineer') if g.chance(0.5) else LEAD, extra_tools=['proxy_create', 'proxy_list'])
    s.user(g.choice([f"Can I see the {name} you built? Open a preview.", f"Put the {name} somewhere I can click on it.", f"Show me the {name} running."]))
    s.step(('proxy_list', {}, '[]'), think='Check for an existing preview before creating one.')
    pid = g.id()
    wid = g.hex(12)
    out = (f"/v1/proxy/{pid}/\nStarted the service with the start command; port {port} is answering."
           f"\nOpened on the room desk as a card window: {web_window(wid, title, f'/v1/proxy/{pid}/')}. Arrange it with desk_arrange.")
    s.step(('proxy_create', {'port': port, 'title': title, 'start': start}, out),
           think='Pass the start command: the platform starts it and brings it back after the computer sleeps.')
    s.final(f"It's open on the desk, and here: /v1/proxy/{pid}/ — the preview stays up for about 30 minutes and restarts itself when someone opens it.")
    return s.done()


def preview_fail(g):
    name, port, start, title = g.choice(PREVIEW)
    s, w = room(g, 'web.preview_fix', agent=specialist(g, 'engineer'), extra_tools=['proxy_create'])
    s.user(f"Open the {name} preview please.")
    pid = g.id()
    log = "Error: Cannot find module '/workspace/" + name + "/dist/server.js'\n"
    out = (f"/v1/proxy/{pid}/\nThe start command was saved, but port {port} did not answer within 75 seconds of running it. "
           f"Fix what it reports (build first if the app needs it) and call proxy_create again:\n{log}")
    s.step(('proxy_create', {'port': port, 'title': title, 'start': start}, out))
    s.step(('bash', {'command': f"cd /workspace/{name} && npm run build 2>&1 | tail -5"}, L.bash_out(0, '✓ built in 2.41s\n')),
           think='The build output is missing: build, then create the preview again.')
    wid = g.hex(12)
    out2 = (f"/v1/proxy/{pid}/\nStarted the service with the start command; port {port} is answering."
            f"\nOpened on the room desk as a card window: {web_window(wid, title, f'/v1/proxy/{pid}/')}. Arrange it with desk_arrange.")
    s.step(('proxy_create', {'port': port, 'title': title, 'start': start}, out2))
    s.final(f"The first start failed because the app was never built; I built it and the preview now answers at /v1/proxy/{pid}/ (also open on the desk).")
    return s.done()


def no_sandbox(g):
    """The request runs without the computer: say so instead of pretending."""
    s, w = room(g, 'sandbox.disabled', agent=LEAD, flags={'no_sandbox': True})
    s.user('Run the test suite and tell me if it passes.')
    s.step(('bash', {'command': 'cd /workspace/app && npm test --silent'}, ('error', 'the computer is disabled for this request')))
    s.final("I can't run anything for this request: the project's computer is turned off for it. Ask again without that restriction (or start the computer) and I'll run the suite.")
    return s.done()


SCENARIOS = {
    'dev.bugfix': (bugfix, 520),
    'sandbox.inspect': (inspect, 220),
    'sandbox.find': (list_and_find, 120),
    'dev.script_deliver': (script_deliver, 220),
    'dev.edit_replace_all': (edit_multi, 90),
    'dev.read_long_file': (long_file, 80),
    'web.preview': (preview, 120),
    'web.preview_fix': (preview_fail, 70),
    'sandbox.disabled': (no_sandbox, 40),
}
