# 8. Render each row with the model's own chat template (tools included) and drop rows that do not fit
from datasets import Dataset
tok = getattr(tokenizer, "tokenizer", tokenizer)

def render(line):
    row = json.loads(line)
    return tokenizer.apply_chat_template(row["messages"], tools=row["tools"], tokenize=False)

def rows(lines):
    for line in lines:
        text = render(line)
        if len(tok(text, add_special_tokens=False).input_ids) <= MAX_SEQ_LEN:
            yield {"text": text}

train_ds = Dataset.from_generator(rows, gen_kwargs={"lines": train_lines})
val_ds = Dataset.from_generator(rows, gen_kwargs={"lines": val_lines})
print('train', len(train_ds), 'of', len(train_lines), '| validation', len(val_ds), 'of', len(val_lines))
print(train_ds[0]["text"][-1500:])
