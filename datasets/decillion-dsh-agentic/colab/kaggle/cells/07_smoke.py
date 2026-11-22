# 7. Smoke test: two training steps per GPU on the LONGEST prepared rows. It proves that memory fits at
# MAX_SEQ_LEN and the loss is finite, and measures the real speed, before you spend hours on the full run.
import json
run(f'torchrun --standalone --nnodes=1 --nproc_per_node={NUM_GPUS} {SCRIPTS}/train_lora.py --config {CONFIG} --smoke',
    'smoke')
smoke = json.load(open(f'{OUT_DIR}/smoke.json'))
print(json.dumps(smoke, indent=1))
need = TRAIN_ROWS * EPOCHS
fit = smoke['rows_that_fit_time_budget']
print(f'peak GPU memory {smoke["peak_gib"]} GiB of ~14.5 | {smoke["sec_per_row_all_gpus"]} s per row (longest rows)')
if fit < need:
    print(f'NOTE: about {fit} rows fit in {TIME_BUDGET_HOURS} h, but {need} are planned. Either lower TRAIN_ROWS in '
          f'cell 3 and rerun cells 3 and 6, or keep it: training stops with a checkpoint and resumes next session.')
else:
    print(f'about {fit} rows fit in the time budget; {need} are planned.')
