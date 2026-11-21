# 12. Save the fine-tuned model as one merged 16-bit model (needed for serving), then free the GPU
import gc, torch
MERGED_DIR = f'{OUT_DIR}/merged'
model.save_pretrained_merged(MERGED_DIR, tokenizer, save_method='merged_16bit')
print('merged model →', MERGED_DIR)
del trainer, model
gc.collect(); torch.cuda.empty_cache()
# After a runtime restart you can skip training: run cells 1, 2, 4, then set
# MERGED_DIR = f'{OUT_DIR}/merged' and continue from cell 13.
