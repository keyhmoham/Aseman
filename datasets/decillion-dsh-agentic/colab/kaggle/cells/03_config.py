# 3. Configuration: the only cell you normally edit. It writes run_config.json, which every script reads.
import json, os, glob

MODEL_ID = 'Qwen/Qwen3.5-4B'
REPO = 'https://github.com/keyhmoham/Aseman.git'
BRANCH = 'main'                      # the branch that holds datasets/decillion-dsh-agentic

WORK = '/kaggle/working'             # saved with the notebook output (20 GB): results only
TMP = '/tmp/decillion'               # not saved: repository, dataset, vLLM, secrets
OUT_DIR = f'{WORK}/decillion-qwen35-4b'
CONFIG = f'{WORK}/run_config.json'
SCRIPTS = f'{WORK}/scripts'
REPO_DIR = f'{TMP}/Aseman'
DATA_DIR = f'{REPO_DIR}/datasets/decillion-dsh-agentic'
DIST_DIR = f'{TMP}/dist'
PREPARED_DIR = f'{TMP}/prepared'
MERGED_DIR = f'{OUT_DIR}/merged'
for d in (OUT_DIR, SCRIPTS, TMP):
    os.makedirs(d, exist_ok=True)

TOOLS_MODE = 'relevant'              # 'full' makes rows ~30k tokens: too long for a T4
MAX_SEQ_LEN = 16384                  # keeps ~99% of rows; rows that do not fit are dropped, never truncated
TRAIN_ROWS = 1500                    # rows per epoch; check the smoke test's estimate of what fits the time budget
SINGLE_TURN_SHARE = 0.5              # share of single-turn families (sampled evenly across families) vs sessions
EVAL_ROWS = 48
EPOCHS = 1

LOAD_IN_4BIT = True                  # fp16 base weights (~9 GB) leave too little of a T4 for 16k-token activations
LORA_R, LORA_ALPHA, LORA_DROPOUT = 32, 64, 0.0
LEARNING_RATE = 1e-4
GRAD_ACCUM = 8                       # x 2 GPUs x 1 row = 16 rows per optimizer step
WARMUP_RATIO = 0.05
SAVE_EVERY_EPOCH = 0.05              # write a checkpoint every 5% of an epoch (rounded to whole optimizer steps)
KEEP_CHECKPOINTS = 3                 # only the newest 3 stay on disk; older ones are deleted after each save
EVAL_EVERY = 25
TIME_BUDGET_HOURS = 9.5              # training stops with a checkpoint after this; leaves time to merge and save
SEED = 3407

# Resuming in a new session: either attach this notebook's earlier output as an input (found automatically
# below), or set HF_REPO_ID (a private model repo) and add a Kaggle secret HF_TOKEN: checkpoints are pushed there.
HF_REPO_ID = ''                      # e.g. 'your-name/decillion-qwen35-4b-lora'
try:
    from kaggle_secrets import UserSecretsClient
    os.environ['HF_TOKEN'] = UserSecretsClient().get_secret('HF_TOKEN')
    print('HF_TOKEN loaded from Kaggle secrets')
except Exception:
    print('no HF_TOKEN secret: downloads are anonymous' + (' and HF_REPO_ID cannot be used' if HF_REPO_ID else ''))
    if HF_REPO_ID:
        raise RuntimeError('HF_REPO_ID is set but the Kaggle secret HF_TOKEN is missing')
earlier = sorted(glob.glob('/kaggle/input/**/decillion-qwen35-4b/checkpoints', recursive=True))
RESUME_FROM = earlier[-1] if earlier else None
print('resume from attached input:', RESUME_FROM)

cfg = dict(model_id=MODEL_ID, out_dir=OUT_DIR, dist_dir=DIST_DIR, prepared_dir=PREPARED_DIR, merged_dir=MERGED_DIR,
           max_seq_len=MAX_SEQ_LEN, train_rows=TRAIN_ROWS, single_turn_share=SINGLE_TURN_SHARE, eval_rows=EVAL_ROWS,
           epochs=EPOCHS, load_in_4bit=LOAD_IN_4BIT, lora_r=LORA_R, lora_alpha=LORA_ALPHA, lora_dropout=LORA_DROPOUT,
           learning_rate=LEARNING_RATE, grad_accum=GRAD_ACCUM, warmup_ratio=WARMUP_RATIO, save_every_epoch=SAVE_EVERY_EPOCH,
           keep_checkpoints=KEEP_CHECKPOINTS,
           eval_every=EVAL_EVERY, time_budget_hours=TIME_BUDGET_HOURS, seed=SEED, hf_repo_id=HF_REPO_ID,
           resume_from=RESUME_FROM, num_proc=max(1, (os.cpu_count() or 2)))
json.dump(cfg, open(CONFIG, 'w'), indent=1)
print(json.dumps(cfg, indent=1))

import re, subprocess, sys
LOGS = f'{OUT_DIR}/logs'
os.makedirs(LOGS, exist_ok=True)

def run(cmd, name):
    """Run a shell command, stream its output here and into logs/<name>.log. On failure, show the first real error
    (the Python traceback from whichever process crashed) instead of whatever the next line trips over."""
    log_path = f'{LOGS}/{name}.log'
    for old in glob.glob(f'{OUT_DIR}/error_rank*.txt'):
        os.remove(old)
    print('$', cmd, '\n  log →', log_path, flush=True)
    lines = []
    with open(log_path, 'w') as log, subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                                                      stderr=subprocess.STDOUT, text=True, bufsize=1) as p:
        for line in p.stdout:
            log.write(line)
            lines.append(line)
            if not re.search(r'\d+%\|', line):      # keep progress bars out of the notebook output
                print(line, end='', flush=True)
    if p.returncode == 0:
        return
    errors = sorted(glob.glob(f'{OUT_DIR}/error_rank*.txt'))
    if errors:
        detail = open(errors[0]).read()
    else:
        text = ''.join(lines)
        start = text.find('Traceback (most recent call last)')
        detail = text[start:start + 6000] if start >= 0 else text[-6000:]
    print('\n' + '=' * 30 + f' {name} FAILED (exit {p.returncode}) ' + '=' * 30)
    print(detail)
    if 'OutOfMemoryError' in detail or 'CUDA out of memory' in detail:
        print('Out of GPU memory: lower MAX_SEQ_LEN in cell 3 (e.g. 12288), then rerun cells 3, 6 and this one.')
    raise RuntimeError(f'{name} failed (exit {p.returncode}); the error is printed above, full log in {log_path}')
