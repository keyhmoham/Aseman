# 8. Train on both T4s: one process per GPU. Stops by itself before TIME_BUDGET_HOURS with a checkpoint.
# Rerun this cell (in this or a new session) to resume from the newest checkpoint it can find.
import glob, json, os
if HF_REPO_ID and not glob.glob(f'{OUT_DIR}/checkpoints/checkpoint-*'):
    from huggingface_hub import snapshot_download
    try:
        hub = snapshot_download(HF_REPO_ID, allow_patterns=['last-checkpoint/*'], local_dir=f'{TMP}/hub')
        if os.path.exists(f'{hub}/last-checkpoint/trainer_state.json'):
            cfg = json.load(open(CONFIG))
            cfg['resume_from'] = f'{hub}/last-checkpoint'
            json.dump(cfg, open(CONFIG, 'w'), indent=1)
            print('resuming from the Hub checkpoint', HF_REPO_ID)
    except Exception as exc:
        print('no checkpoint on the Hub yet:', str(exc)[:200])
!torchrun --standalone --nnodes=1 --nproc_per_node={NUM_GPUS} {SCRIPTS}/train_lora.py --config {CONFIG}
