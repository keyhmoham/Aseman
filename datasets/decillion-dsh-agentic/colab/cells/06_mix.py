# 6. Choose the training mix (rows stay raw JSON lines to save memory)
import gzip, json, random, re
from collections import Counter
random.seed(SEED)
CAT = re.compile(r"\"category\": \"([^\"]+)\"")
single, multi = [], []
for line in gzip.open('/content/dist/train.jsonl.gz', 'rt', encoding='utf-8'):
    cat = CAT.search(line[:300]).group(1)
    (multi if cat.startswith('session.') else single).append(line)
random.shuffle(multi)
if MAX_MULTI_TURN:
    multi = multi[:MAX_MULTI_TURN]
train_lines = single * SINGLE_TURN_REPEAT + multi
random.shuffle(train_lines)
val_lines = gzip.open('/content/dist/validation.jsonl.gz', 'rt', encoding='utf-8').read().splitlines()
print(f'single-turn {len(single)} x{SINGLE_TURN_REPEAT}, multi-turn {len(multi)} -> train {len(train_lines)}, validation {len(val_lines)}')
