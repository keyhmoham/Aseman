# 6. Choose the mix, render it with Qwen3.5's chat template, tokenize once and compute the loss labels.
# Runs as a separate process so the ~1 GB train file never stays in this kernel's memory.
!python3 {SCRIPTS}/prepare_data.py --config {CONFIG}
