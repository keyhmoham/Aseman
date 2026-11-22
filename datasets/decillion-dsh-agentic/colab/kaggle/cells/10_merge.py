# 10. Merge the LoRA adapter into a 16-bit model for vLLM (on the CPU; about 10 GB of RAM and disk, 10-20 minutes).
run(f'python3 {SCRIPTS}/merge_lora.py --config {CONFIG}', 'merge')
import os
assert os.path.exists(f'{MERGED_DIR}/config.json'), 'no merged model: see the output above'
