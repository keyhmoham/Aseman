# 10. Merge a LoRA adapter into a 16-bit model for vLLM (on the CPU; about 10 GB of RAM and disk, 10-20 minutes).
# By default this merges the final adapter. To serve an earlier checkpoint instead, set MERGE_FROM to one of the
# folders listed below, run this cell, then rerun cell 11 (vLLM restarts on the new weights; the tunnel URL stays).
import glob, json, os

MERGE_FROM = None   # e.g. f'{OUT_DIR}/checkpoints/checkpoint-40'; None = the final adapter in {OUT_DIR}/adapter

print('checkpoints on disk (eval loss = the latest evaluation at or before that step):')
for ck in sorted(glob.glob(f'{OUT_DIR}/checkpoints/checkpoint-*'), key=lambda p: int(p.rsplit('-', 1)[1])):
    state = json.load(open(f'{ck}/trainer_state.json'))
    evals = [(h['step'], h['eval_loss']) for h in state.get('log_history', []) if 'eval_loss' in h]
    note = f' | eval loss {evals[-1][1]:.4f} at step {evals[-1][0]}' if evals else ''
    print(f'  {ck}  (step {state["global_step"]}, epoch {state.get("epoch", 0):.2f}{note})')

adapter = MERGE_FROM or f'{OUT_DIR}/adapter'
assert os.path.exists(f'{adapter}/adapter_config.json'), f'no LoRA adapter in {adapter}'
print('merging', adapter)
run(f'python3 {SCRIPTS}/merge_lora.py --config {CONFIG} --adapter {adapter}', 'merge')
assert os.path.exists(f'{MERGED_DIR}/config.json'), 'no merged model: see the output above'
json.dump({'adapter': adapter}, open(f'{MERGED_DIR}/merged_from.json', 'w'))
print('merged model now comes from', adapter)
