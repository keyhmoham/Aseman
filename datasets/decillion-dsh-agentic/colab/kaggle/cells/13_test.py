# 13. Test the public API end to end, the way the Decillion LLM gateway uses it
import gzip, json, os, time
import requests
from jsonschema import validate
from openai import OpenAI
from transformers import AutoTokenizer

SHOW_SECRETS = False   # True prints the API key in the output (outputs are saved with the notebook)
SERVE_JSON = f'{TMP}/secrets/serve.json'
SERVE = json.load(open(SERVE_JSON))
assert 'base_url_public' in SERVE, 'run cell 12 first: the public URL is missing'
BASE, KEY, MODEL = SERVE['base_url_public'].rstrip('/'), SERVE['api_key'], SERVE['model']
client = OpenAI(base_url=BASE, api_key=KEY, timeout=600, max_retries=1)
HEADERS = {'Authorization': f'Bearer {KEY}'}
tok = AutoTokenizer.from_pretrained(SERVE['merged_dir'])
REPLY_BUDGET = 1024

results = []
def check(name, ok, detail=''):
    results.append((name, bool(ok)))
    print(('PASS' if ok else 'FAIL'), '|', name, ('— ' + detail if detail else ''))

# 1. The OpenAI surface the gateway expects, with and without the key.
r = requests.get(f'{BASE}/models', timeout=30)
check('refuses requests without the key', r.status_code == 401, f'HTTP {r.status_code}')
r = requests.get(f'{BASE}/models', headers=HEADERS, timeout=30)
ids = [m.get('id') for m in r.json().get('data', [])] if r.status_code == 200 else []
check('/v1/models lists the fine-tuned model', ids == [MODEL], str(ids))

# 2. A plain completion.
resp = client.chat.completions.create(
    model=MODEL, messages=[{'role': 'user', 'content': 'Reply with exactly: DECILLION-OK'}],
    temperature=0, max_tokens=64, extra_body={'chat_template_kwargs': {'enable_thinking': False}})
text = (resp.choices[0].message.content or '').strip()
check('a chat completion comes back', 'DECILLION-OK' in text, repr(text[:80]))

# 3. The gateway's own probe shape: streaming, with usage, timed.
t0 = time.time()
first = usage = None
streamed = reasoned = ''
body = {'model': MODEL, 'stream': True, 'stream_options': {'include_usage': True},
        'messages': [{'role': 'user', 'content': 'In about 60 words, explain why the sky is blue.'}],
        'max_tokens': 600}
with requests.post(f'{BASE}/chat/completions', json=body, stream=True, timeout=300,
                   headers={**HEADERS, 'Accept': 'text/event-stream'}) as r:
    r.raise_for_status()
    for line in r.iter_lines(decode_unicode=True):
        if not line or not line.startswith('data:'):
            continue
        payload = line[5:].strip()
        if payload == '[DONE]':
            break
        chunk = json.loads(payload)
        if chunk.get('usage'):
            usage = chunk['usage']
        for choice in chunk.get('choices', []):
            delta = choice.get('delta') or {}
            reasoning = delta.get('reasoning_content') or delta.get('reasoning') or ''
            if first is None and (delta.get('content') or reasoning or delta.get('tool_calls')):
                first = time.time() - t0
            streamed += delta.get('content') or ''
            reasoned += reasoning
check('streams tokens and reports usage for metering',
      first is not None and (streamed.strip() or reasoned.strip()) and usage
      and usage.get('prompt_tokens', 0) > 0 and usage.get('completion_tokens', 0) > 0,
      f'first token {first and round(first, 2)}s, {usage and usage.get("completion_tokens")} completion tokens')
print('   sample:', repr((streamed.strip() or reasoned.strip())[:160]))

# 4. Held-out validation rows: does the served model behave like the dsh agent?
path = f'{DIST_DIR}/validation.jsonl.gz'
if not os.path.exists(path):
    path = f'{DATA_DIR}/dist/validation.jsonl.gz'
rows = [json.loads(line) for line in gzip.open(path, 'rt', encoding='utf-8')]

def first_expected(row):
    for i, message in enumerate(row['messages']):
        if message['role'] == 'assistant':
            calls = message.get('tool_calls') or []
            return i, (calls[0]['function']['name'] if calls else None)
    return None, None

def fits(messages, tools):
    text = tok.apply_chat_template(messages, tools=tools, add_generation_prompt=True, tokenize=False)
    n = len(tok(text, add_special_tokens=False)['input_ids'])
    return n + REPLY_BUDGET <= SERVE['max_model_len']

wanted = ['dev.bugfix', 'people.ask_user', 'memory.remember', 'team.delegate_parallel']
picked = []
for category in wanted:
    for row in rows:
        ai, expected = first_expected(row)
        if row['category'] == category and expected and fits(row['messages'][:ai], row['tools']):
            picked.append((row, ai, expected))
            break
check('held-out validation rows are available', len(picked) == len(wanted), f'{len(picked)}/{len(wanted)}')

matched = 0
for row, ai, expected in picked:
    tools = row['tools']
    try:
        resp = client.chat.completions.create(model=MODEL, messages=row['messages'][:ai], tools=tools,
                                              tool_choice='auto', temperature=0, max_tokens=REPLY_BUDGET)
    except Exception as exc:
        check(f'{row["category"]}: calls {expected}', False, str(exc)[:140])
        continue
    message = resp.choices[0].message
    call = (message.tool_calls or [None])[0]
    got = call.function.name if call else None
    args_ok = False
    if call:
        schema = next((t.get('function', t).get('parameters') for t in tools
                       if t.get('function', t).get('name') == got), None)
        try:
            validate(json.loads(call.function.arguments), schema)
            args_ok = True
        except Exception:
            args_ok = False
    matched += got == expected
    check(f'{row["category"]}: calls {expected}', got == expected and args_ok, f'got {got}, arguments valid={args_ok}')
check('behaves like the dsh agent (3 of 4 held-out tool choices)', matched >= 3, f'{matched}/{len(picked)}')

# 5. Tool calls also have to stream as deltas (what dsh consumes).
if picked:
    row, ai, expected = picked[0]
    body = {'model': MODEL, 'messages': row['messages'][:ai], 'tools': row['tools'], 'tool_choice': 'auto',
            'temperature': 0, 'max_tokens': REPLY_BUDGET, 'stream': True, 'stream_options': {'include_usage': True}}
    name = arguments = ''
    with requests.post(f'{BASE}/chat/completions', json=body, stream=True, timeout=600,
                       headers={**HEADERS, 'Accept': 'text/event-stream'}) as r:
        r.raise_for_status()
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith('data:'):
                continue
            payload = line[5:].strip()
            if payload == '[DONE]':
                break
            for choice in json.loads(payload).get('choices', []):
                for call in (choice.get('delta') or {}).get('tool_calls') or []:
                    fn = call.get('function') or {}
                    name += fn.get('name') or ''
                    arguments += fn.get('arguments') or ''
    check('tool calls stream as OpenAI deltas', name == expected and arguments.lstrip().startswith('{'),
          f'name={name!r} arguments={arguments[:80]!r}')

# 6. The fine-tune, not base Qwen: the dsh persona is in the weights.
system = next((m['content'] for m in rows[0]['messages'] if m['role'] == 'system'), '')
resp = client.chat.completions.create(
    model=MODEL, messages=[{'role': 'system', 'content': system},
                           {'role': 'user', 'content': 'In one short sentence, who are you?'}],
    temperature=0, max_tokens=REPLY_BUDGET)
message = resp.choices[0].message
extra = message.model_extra or {}
reasoning = getattr(message, 'reasoning_content', None) or extra.get('reasoning_content') or extra.get('reasoning') or ''
answer = ((message.content or '') + ' ' + reasoning).strip()
check('answers as decillion, not as base Qwen', 'decillion' in answer.lower(), repr(answer[:140]))

# 7. The provider to paste into Decillion (Admin → AI → Providers → Add → Custom). It holds the key, so it is
# written under /tmp, not to the saved notebook output.
gateway = {'name': 'Decillion dsh Qwen3.5-4B (Kaggle vLLM)', 'kind': 'custom', 'base_url': BASE,
           'api_key': KEY, 'enabled': True,
           'models': [{'id': MODEL, 'name': 'Decillion dsh Qwen3.5-4B', 'context_window': SERVE['max_model_len'],
                       'capabilities': ['chat'], 'input_price': 0, 'output_price': 0}]}
provider_path = f'{TMP}/secrets/decillion_gateway_provider.json'
json.dump(gateway, open(provider_path, 'w'), indent=1)
shown = gateway if SHOW_SECRETS else {**gateway, 'api_key': KEY[:14] + '…'}
print(f'\nprovider for Decillion (full version in {provider_path}; set SHOW_SECRETS = True to print the key):')
print(json.dumps(shown, indent=1))

failed = [name for name, ok in results if not ok]
print(f'\n{len(results) - len(failed)}/{len(results)} checks passed')
if failed:
    raise AssertionError('failed: ' + '; '.join(failed))
print('The fine-tuned model is served correctly. Keep this session (and cloudflared) alive while the provider is in')
print('use; after a disconnect rerun cells 11-12 and update the base URL.')
