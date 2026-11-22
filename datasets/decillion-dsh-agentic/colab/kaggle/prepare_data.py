#!/usr/bin/env python3
"""Pick the training mix, render it with the model's chat template and write token ids + loss labels.

Run as its own process (not inside the notebook kernel) so the ~1 GB train file and the rendered text
never stay resident in the kernel while the GPUs train:

    python3 prepare_data.py --config /kaggle/working/run_config.json

What it does:
  * Two streaming passes over train.jsonl.gz: the first records only (line number, category), the second
    keeps just the selected lines, so memory stays small.
  * Single-turn families are sampled round-robin by category (rare families are not drowned out);
    multi-turn sessions are sampled at random. The mix is set by train_rows / single_turn_share.
  * Each row is rendered with the tokenizer's own chat template (tools included) and tokenized once.
    Rows longer than max_seq_len are dropped, never truncated (truncation would cut the answer off).
  * Loss labels cover only the assistant turns after the last real user message, from just after
    "<|im_start|>assistant\\n" through "<|im_end|>". Qwen3.5's template renders <think> only for those turns
    and strips the reasoning (and the <think> block) from earlier ones, so training earlier turns would
    teach a format that inference (which always opens with "<think>\\n") never uses. Earlier turns stay in
    the context, exactly as the model will see them in production.
"""
import argparse, gzip, json, os, random, re, sys, time
from collections import Counter, defaultdict
from multiprocessing import Pool

IM_START, IM_END = '<|im_start|>', '<|im_end|>'
USER_HDR, ASSIST_HDR = IM_START + 'user\n', IM_START + 'assistant\n'
CAT = re.compile(r'"category":\s*"([^"]+)"')


def assistant_spans(text):
    """Character spans of the assistant turns that should carry loss (see module docstring)."""
    starts = [m.start() for m in re.finditer(re.escape(IM_START), text)]
    last_query = -1
    for p in starts:
        if text.startswith(USER_HDR, p) and not text.startswith('<tool_response>', p + len(USER_HDR)):
            last_query = p
    spans = []
    for p in starts:
        if p > last_query and text.startswith(ASSIST_HDR, p):
            b = p + len(ASSIST_HDR)
            e = text.find(IM_END, b)
            if e < 0:
                continue
            spans.append((b, e + len(IM_END)))
    return spans


def encode_text(text, tok, max_len):
    """-> (input_ids, labels, reason). reason is None when the row is usable."""
    enc = tok(text, add_special_tokens=False, return_offsets_mapping=True)
    ids = enc['input_ids']
    if len(ids) > max_len:
        return None, None, 'too_long'
    spans = assistant_spans(text)
    labels = [-100] * len(ids)
    j = 0
    for k, (s, e) in enumerate(enc['offset_mapping']):
        while j < len(spans) and spans[j][1] <= s:
            j += 1
        if j < len(spans) and e > s and s >= spans[j][0] and e <= spans[j][1]:
            labels[k] = ids[k]
    if not any(l != -100 for l in labels):
        return None, None, 'no_assistant_tokens'
    return ids, labels, None


_TOK = None
_MAX = None


def _init(model_id, max_len):
    global _TOK, _MAX
    from transformers import AutoTokenizer
    _TOK = AutoTokenizer.from_pretrained(model_id)
    _MAX = max_len


def _work(line):
    try:
        row = json.loads(line)
        text = _TOK.apply_chat_template(row['messages'], tools=row.get('tools'), tokenize=False)
        ids, labels, reason = encode_text(text, _TOK, _MAX)
    except Exception as exc:  # a broken row must not kill the whole run
        return {'reason': 'error', 'error': f'{type(exc).__name__}: {exc}'[:300]}
    if reason:
        return {'reason': reason}
    return {'reason': None, 'id': row.get('id', ''), 'category': row.get('category', ''),
            'input_ids': ids, 'labels': labels}


def round_robin(by_cat, rng):
    """Interleave categories so any prefix of the result is as balanced as possible."""
    pools = {c: rng.sample(v, len(v)) for c, v in by_cat.items()}
    cats = sorted(pools)
    rng.shuffle(cats)
    out = []
    while any(pools.values()):
        for c in cats:
            if pools[c]:
                out.append(pools[c].pop())
    return out


def scan_categories(path):
    cats = []
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        for line in f:
            m = CAT.search(line[:400])
            cats.append(m.group(1) if m else '?')
    return cats


def read_lines(path, wanted):
    wanted = set(wanted)
    got = {}
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        for i, line in enumerate(f):
            if i in wanted:
                got[i] = line
    return got


def process(order, lines, quota, pool, label):
    """Encode candidates in `order` until `quota` usable rows are collected."""
    kept, reasons, errors = [], Counter(), []
    pos, chunk = 0, max(64, quota // 4)
    t0 = time.time()
    while len(kept) < quota and pos < len(order):
        batch = order[pos:pos + chunk]
        pos += chunk
        for res in pool.imap(_work, (lines[i] for i in batch), chunksize=4):
            if res['reason']:
                reasons[res['reason']] += 1
                if res['reason'] == 'error' and len(errors) < 5:
                    errors.append(res['error'])
                continue
            if len(kept) < quota:
                kept.append(res)
        print(f'  {label}: {len(kept)}/{quota} kept, {sum(reasons.values())} dropped '
              f'({dict(reasons)}), {time.time() - t0:.0f}s', flush=True)
    for e in errors:
        print('  error:', e)
    return kept, reasons


def save(rows, path):
    from datasets import Dataset, Features, Sequence, Value
    feats = Features({'id': Value('string'), 'category': Value('string'),
                      'input_ids': Sequence(Value('int32')), 'labels': Sequence(Value('int32'))})
    cols = {k: [r[k] for r in rows] for k in feats}
    Dataset.from_dict(cols, features=feats).save_to_disk(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', required=True)
    cfg = json.load(open(ap.parse_args().config))
    rng = random.Random(cfg['seed'])
    train_path = os.path.join(cfg['dist_dir'], 'train.jsonl.gz')
    val_path = os.path.join(cfg['dist_dir'], 'validation.jsonl.gz')
    max_len, n_train = cfg['max_seq_len'], cfg['train_rows']
    n_single = round(n_train * cfg['single_turn_share'])
    n_multi = n_train - n_single
    over = 1.25  # candidates beyond the quota, to replace rows that are too long

    print('scanning categories…', flush=True)
    cats = scan_categories(train_path)
    single, multi = defaultdict(list), []
    for i, c in enumerate(cats):
        (multi.append(i) if c.startswith('session.') else single[c].append(i))
    single_order = round_robin(single, rng)
    multi_order = rng.sample(multi, len(multi))
    if len(single_order) < n_single:  # not enough single-turn rows: give the rest to sessions
        n_multi += n_single - len(single_order)
        n_single = len(single_order)
    single_cand = single_order[:int(n_single * over) + 8]
    multi_cand = multi_order[:int(n_multi * over) + 8]
    print(f'{len(cats)} train rows: {sum(map(len, single.values()))} single-turn in {len(single)} '
          f'families, {len(multi)} sessions; want {n_single} single + {n_multi} sessions', flush=True)
    lines = read_lines(train_path, single_cand + multi_cand)

    val_by_cat = defaultdict(list)
    val_lines = {}
    with gzip.open(val_path, 'rt', encoding='utf-8') as f:
        for i, line in enumerate(f):
            m = CAT.search(line[:400])
            val_by_cat[m.group(1) if m else '?'].append(i)
            val_lines[i] = line
    val_order = round_robin(val_by_cat, rng)

    with Pool(cfg.get('num_proc') or os.cpu_count() or 2, initializer=_init,
              initargs=(cfg['model_id'], max_len)) as pool:
        s_rows, s_why = process(single_cand, lines, n_single, pool, 'single-turn')
        m_rows, m_why = process(multi_cand, lines, n_multi, pool, 'sessions')
        e_rows, e_why = process(val_order, val_lines, cfg['eval_rows'], pool, 'validation')

    train = s_rows + m_rows
    rng.shuffle(train)
    if not train or not e_rows:
        sys.exit(f'no usable rows (train {len(train)}, eval {len(e_rows)}): check max_seq_len={max_len} '
                 f'and the drop reasons above')
    out = cfg['prepared_dir']
    os.makedirs(out, exist_ok=True)
    save(train, os.path.join(out, 'train'))
    save(e_rows, os.path.join(out, 'eval'))

    def summary(rows):
        lens = sorted(len(r['input_ids']) for r in rows)
        lab = sum(sum(1 for x in r['labels'] if x != -100) for r in rows)
        return {'rows': len(rows), 'tokens': sum(lens), 'label_tokens': lab,
                'len_min': lens[0], 'len_median': lens[len(lens) // 2], 'len_max': lens[-1]}

    stats = {'max_seq_len': max_len, 'train': summary(train), 'eval': summary(e_rows),
             'dropped': {'single': dict(s_why), 'sessions': dict(m_why), 'eval': dict(e_why)},
             'train_categories': dict(Counter(r['category'] for r in train).most_common())}
    json.dump(stats, open(os.path.join(out, 'stats.json'), 'w'), indent=1)
    print(json.dumps({k: stats[k] for k in ('train', 'eval', 'dropped')}, indent=1))
    if len(train) < n_train:
        print(f'WARNING: only {len(train)} of {n_train} wanted training rows fit in {max_len} tokens')


if __name__ == '__main__':
    main()
